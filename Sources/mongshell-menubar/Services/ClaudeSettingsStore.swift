import Foundation

/// All I/O against Claude Code's user-scope settings file
/// (`~/.claude/settings.json`) lives here, isolated from the model the same way
/// `OpenClawStatusClient` isolates the openclaw status-URL reads.
///
/// That file — not UserDefaults — is the single source of truth for these
/// values. Claude Code watches it and hot-reloads, so a save here lands in an
/// already-running session for every key except `model`.
///
/// The file is **shared with the CLI**, which writes it too (`/effort`, `/fast`,
/// permission grants). So every save re-reads immediately before writing and
/// replaces only the keys we own; everything else survives byte-for-byte.
enum ClaudeSettingsStore {
    /// `~/.claude/settings.json`, overridable via `MONGSHELL_CLAUDE_SETTINGS`
    /// so development and QA never touch the real file.
    /// Symlinks are resolved because an atomic write replaces whatever sits at
    /// the path — dotfile setups that symlink this file into a repo would end
    /// up with the link swapped for a plain file.
    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["MONGSHELL_CLAUDE_SETTINGS"],
           !override.isEmpty {
            return resolving(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        return resolving(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"))
    }

    /// `resolvingSymlinksInPath()` gives up the moment a link's target doesn't
    /// exist, so the remaining hops are followed by hand. Without this, a
    /// dangling link — a dotfile repo mid-restow, a renamed target — reads as
    /// "no file yet" and the atomic write replaces the link with a plain file,
    /// silently detaching the user's real settings.
    private static func resolving(_ url: URL) -> URL {
        var current = url.resolvingSymlinksInPath()
        for _ in 0..<8 {
            guard let target = try? FileManager.default
                .destinationOfSymbolicLink(atPath: current.path) else { break }
            current = URL(fileURLWithPath: target,
                          relativeTo: current.deletingLastPathComponent()).standardizedFileURL
        }
        return current
    }

    /// `attributesOfItem` doesn't follow links, so this reports on the entry
    /// itself rather than its target.
    private static func isSymlink(_ url: URL) -> Bool {
        let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type]
            as? FileAttributeType
        return type == .typeSymbolicLink
    }

    /// Claude Code is "installed" iff its config directory exists. We key off the
    /// directory, not the file: a fresh install has `~/.claude` but may not have
    /// written `settings.json` yet, and we're happy to create it.
    static var isInstalled: Bool {
        var isDir: ObjCBool = false
        let dir = fileURL.deletingLastPathComponent()
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    enum StoreError: LocalizedError {
        case notInstalled
        case unreadable
        case malformed
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude Code 설정 폴더(~/.claude)를 찾을 수 없습니다."
            case .unreadable:   return "settings.json 을 열 수 없습니다 (권한 또는 디스크 오류)."
            case .malformed:    return "settings.json 을 읽을 수 없습니다 (JSON 형식 오류)."
            case .tooLarge:     return "settings.json 이 너무 큽니다 (5MB 초과)."
            }
        }
    }

    /// Parsing happens on the main actor, so an implausibly large file would
    /// freeze the UI rather than merely being slow.
    private static let maxBytes = 5 * 1024 * 1024

    // MARK: Read

    /// The whole file as a dictionary.
    ///
    /// Only a genuinely absent file is an empty dictionary. Every other
    /// failure — unreadable, truncated, unparseable — throws, because callers
    /// use this result as the base for the next write: handing back `[:]` for a
    /// file we simply failed to read would turn the next save into a wipe of
    /// every setting we can't see.
    static func load() throws -> [String: Any] {
        try load(from: fileURL)
    }

    /// Takes the URL as a parameter so a caller that reads and then writes can
    /// resolve the path exactly once — `fileURL` walks symlinks on every access,
    /// and two lookups can disagree.
    static func load(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable
        }
        // A file that exists but holds nothing is the debris of an interrupted
        // write, not a fresh install.
        guard !data.isEmpty else { throw StoreError.malformed }
        guard data.count <= maxBytes else { throw StoreError.tooLarge }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw StoreError.malformed
        }
        return dict
    }

    // MARK: Write

    /// Read-modify-write. The read happens here, immediately before the write,
    /// so a key the CLI changed a moment ago is carried into the new file
    /// instead of being clobbered by a stale in-memory copy.
    ///
    /// Returns the dictionary as written, so callers can refresh their UI from
    /// what actually landed on disk rather than from what they intended.
    @discardableResult
    static func mutate(_ transform: (inout [String: Any]) -> Void) throws -> [String: Any] {
        guard isInstalled else { throw StoreError.notInstalled }

        // Resolved once and reused: every `fileURL` access re-walks symlinks, so
        // separate lookups for read, backup and write could land on different
        // files.
        let url = fileURL

        // A symlink cycle exhausts the hop limit in `resolving(_:)` and hands
        // back a link. Writing through it is exactly the failure that function
        // exists to prevent, so refuse rather than replace the link.
        if isSymlink(url) { throw StoreError.unreadable }

        var dict = try load(from: url)
        transform(&dict)

        // Keep one copy of the previous contents. Best-effort: a missing file or
        // an unwritable backup must not block the save itself.
        let backup = url.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            // copyItem carries the source mode over, but this file can hold API
            // keys via `env`/`apiKeyHelper` — state the mode rather than inherit it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: backup.path)
        }

        // `.sortedKeys` costs us the author's key order once, but makes our
        // writes deterministic and diffable. `.withoutEscapingSlashes` keeps
        // path-shaped permission rules readable.
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // `.atomic` writes a temp file and renames — a crash mid-write can never
        // leave a truncated settings.json behind.
        try data.write(to: url, options: .atomic)
        return dict
    }

    // MARK: Nested helpers

    /// Sets `dict[key] = value`, or clears the key when `value` is nil. Absent
    /// and "explicitly set to the default" are different things in a layered
    /// settings file, so we never write a placeholder.
    ///
    /// `understood` decides whether an existing value may be cleared, and must
    /// match the cast the reader uses. A key holding an unexpected type reads
    /// back as "absent" too, and deleting on that basis would throw away a
    /// setting the user never touched here — so anything we can't read is left
    /// exactly as it is.
    static func set(_ dict: inout [String: Any],
                    _ key: String,
                    _ value: Any?,
                    understood: (Any) -> Bool) {
        if let value {
            dict[key] = value
            return
        }
        guard let existing = dict[key] else { return }
        guard understood(existing) else { return }
        dict.removeValue(forKey: key)
    }

    /// Same, one level down. An object left empty by the removal is dropped too,
    /// so toggling a nested key back to default doesn't leave `{}` behind. A
    /// parent that isn't an object is left untouched for the same reason as
    /// above.
    static func setNested(_ dict: inout [String: Any],
                          _ parent: String,
                          _ key: String,
                          _ value: Any?,
                          understood: (Any) -> Bool) {
        if dict[parent] != nil && dict[parent] as? [String: Any] == nil { return }

        var child = dict[parent] as? [String: Any] ?? [:]
        set(&child, key, value, understood: understood)
        if child.isEmpty {
            dict.removeValue(forKey: parent)
        } else {
            dict[parent] = child
        }
    }
}

/// Watches the settings file and fires `onChange` when it moves underneath us.
///
/// Claude Code (like us) saves atomically, which replaces the inode rather than
/// writing through the existing one — so a plain `.write` watch goes deaf after
/// the first external save. We therefore watch for `.delete`/`.rename` as well
/// and re-arm on a fresh descriptor.
/// `source`, `pendingArm` and `stopped` are reached from the watch queue, from
/// the caller's thread, and from `deinit`, so a lock guards them rather than
/// pretending one thread owns them. `onChange` is `@Sendable` because it is
/// stored here and always invoked on `queue`, never on the caller's thread.
/// Together those are what the `@unchecked Sendable` claim rests on.
final class ClaudeSettingsWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var pendingArm: DispatchWorkItem?
    private var stopped = false
    private let queue = DispatchQueue(label: "com.mongshell.menubar.claude-settings-watch")

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        lock.lock()
        stopped = false
        lock.unlock()
        arm()
    }

    /// Tears the watch down for good. Without the `stopped` flag a scheduled
    /// re-arm would quietly resurrect it seconds later.
    func stop() {
        lock.lock()
        stopped = true
        let old = source
        let pending = pendingArm
        source = nil
        pendingArm = nil
        lock.unlock()
        pending?.cancel()
        old?.cancel()
    }

    /// Installs `new` and cancels whatever it replaced. Cancelling outside the
    /// lock keeps the cancel handler (which closes the fd) off a held lock.
    ///
    /// `stopped` is re-checked here because `arm()` releases the lock before
    /// opening the file: a `stop()` landing in that window would otherwise be
    /// undone by the source `arm()` is about to install.
    private func install(_ new: DispatchSourceFileSystemObject) {
        lock.lock()
        if stopped {
            lock.unlock()
            new.cancel()
            return
        }
        let old = source
        source = new
        lock.unlock()
        old?.cancel()
    }

    /// Arms after `delay`. `notifying` fires one extra read, but **only if the
    /// arm succeeded**: a write that landed while no descriptor was open
    /// produces no event of its own, so the gap would otherwise be silent.
    ///
    /// Gating on success matters — while the file simply doesn't exist yet the
    /// retry runs forever, and notifying on each attempt would republish the
    /// same settings every 5 seconds and re-render the window with it.
    private func scheduleArm(after delay: TimeInterval, notifying: Bool) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let armed = self.arm()
            if notifying && armed { self.onChange() }
        }
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        pendingArm?.cancel()
        pendingArm = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Returns whether a descriptor is now being watched.
    @discardableResult
    private func arm() -> Bool {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return false }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // No file yet (fresh install), or a writer is mid-rename. Keep
            // retrying, and notify once we actually get back in: a write that
            // completed while we had no descriptor open produces no event of
            // its own, and a stale in-memory copy is what lets an unrelated
            // edit overwrite someone else's change.
            scheduleArm(after: 5, notifying: true)
            return false
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        // `src` is captured weakly: a strong capture would make the source
        // retain its own handler, so it could only ever be freed by cancel.
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            self.onChange()
            // The file we held is gone — pick up its replacement. A short delay
            // lets the writer finish its rename before we reopen.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.scheduleArm(after: 0.2, notifying: true)
            }
        }
        src.setCancelHandler { close(fd) }
        // Resume before installing: a suspended source defers its cancel
        // handler, so `install` rejecting this one (stop() raced us) would leak
        // the descriptor. Events arriving before the install are harmless — the
        // handler doesn't read `source`.
        src.resume()
        install(src)
        return true
    }
}
