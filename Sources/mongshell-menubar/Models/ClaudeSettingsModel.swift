import SwiftUI
import Combine

/// The subset of `~/.claude/settings.json` this app edits.
///
/// Empty string means "키 없음" — the setting is absent from the file and Claude
/// Code's own default applies. That's deliberately distinct from writing the
/// default value out explicitly.
struct ClaudeSettings: Equatable {
    var model: String = ""
    var effortLevel: String = ""
    var fallbackPrimary: String = ""
    var fallbackSecondary: String = ""
    /// Claude Code defaults this to true, so `true` is stored as key-absent and
    /// only the non-default `false` is written out.
    var autoCompact: Bool = true
    var permissionMode: String = ""
}

/// Owns the live view of Claude Code's settings file.
///
/// Deliberately **not** backed by `@AppStorage`: unlike `Preferences`, these
/// values belong to Claude Code and the CLI edits them too, so mirroring them
/// into UserDefaults would create a second, silently-diverging copy. The file
/// is the only authority; we read it, write it, and watch it.
@MainActor
final class ClaudeSettingsModel: ObservableObject {
    static let shared = ClaudeSettingsModel()

    @Published private(set) var settings = ClaudeSettings()
    @Published private(set) var isInstalled = false
    /// Last read/write failure, surfaced in the settings UI. nil when healthy.
    @Published private(set) var lastError: String?

    private var watcher: ClaudeSettingsWatcher?
    private var reloadTask: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    /// Loads the file and starts watching it. A no-op when Claude Code isn't
    /// installed, mirroring how `OpenClawModel` parks without a status URL.
    func start() {
        // Tear down any previous watch first, mirroring `OpenClawModel.start()`.
        watcher?.stop()
        watcher = nil
        reloadTask?.cancel()

        isInstalled = ClaudeSettingsStore.isInstalled
        guard isInstalled else { return }

        reload()

        let w = ClaudeSettingsWatcher(url: ClaudeSettingsStore.fileURL) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        w.start()
        watcher = w
    }

    /// Coalesces watcher events. Reading parses the file on the main actor, and
    /// a writer that touches the file several times in a row (or our own save,
    /// which the watcher also sees) would otherwise mean one parse per event.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// Re-reads the file into `settings`. Never writes — this is the path the
    /// watcher takes when the CLI (`/effort`, `/fast`, permission grants) edits
    /// the file behind us, so it must not bounce a save back.
    func reload() {
        do {
            settings = Self.parse(try ClaudeSettingsStore.load())
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Bindings

    /// Binding that saves on every change. Reads go through `settings`, which
    /// `reload()` owns, so an external edit wins the moment it lands.
    func binding<V>(_ keyPath: WritableKeyPath<ClaudeSettings, V>) -> Binding<V> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.save(keyPath, newValue) }
        )
    }

    // MARK: Persistence

    /// Applies the one setting the user just changed.
    ///
    /// The value written for every *other* key is re-derived from the file
    /// inside the write, never from `settings`. That matters because our
    /// in-memory copy can be stale: the file watcher can miss a window, and
    /// `permissions.defaultMode` is a tool-approval gate. Saving the whole
    /// snapshot would let flipping an unrelated toggle here quietly revert a
    /// change made in the CLI a moment ago.
    ///
    /// The write is synchronous, so `settings` is published once, from what
    /// actually landed on disk. On failure it isn't published at all and the
    /// control snaps back to the file's value.
    private func save<V>(_ keyPath: WritableKeyPath<ClaudeSettings, V>, _ newValue: V) {
        do {
            let written = try ClaudeSettingsStore.mutate { dict in
                Self.applyChange(keyPath, newValue, to: &dict)
            }
            settings = Self.parse(written)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            reload() // roll the UI back to the truth on disk
        }
    }

    // MARK: JSON ↔ struct

    /// The write half of a save, kept out of `save` so the tests exercise the
    /// shipping path rather than a re-creation of it.
    ///
    /// Note what it is handed and what it isn't: everything except `keyPath`
    /// comes from `dict` — the file as it exists right now — so no other
    /// setting can change *meaning* here. Their spelling can still change,
    /// because the round trip normalises: a `fallbackModel` with duplicates
    /// comes back deduplicated, and a key spelling out Claude Code's own
    /// default (`"autoCompactEnabled": true`) comes back absent. Both are
    /// behaviour-preserving; neither is a value the user loses.
    nonisolated static func applyChange<V>(_ keyPath: WritableKeyPath<ClaudeSettings, V>,
                                           _ newValue: V,
                                           to dict: inout [String: Any]) {
        var fresh = parse(dict)
        fresh[keyPath: keyPath] = newValue
        apply(fresh, to: &dict)
    }

    /// Pure, and deliberately `nonisolated` + internal: the JSON mapping is the
    /// part worth exercising directly, and it has no business needing the main
    /// actor to do it.
    nonisolated static func parse(_ dict: [String: Any]) -> ClaudeSettings {
        var s = ClaudeSettings()
        s.model = dict["model"] as? String ?? ""
        s.effortLevel = dict["effortLevel"] as? String ?? ""

        let fallback = dict["fallbackModel"] as? [String] ?? []
        s.fallbackPrimary = fallback.count > 0 ? fallback[0] : ""
        s.fallbackSecondary = fallback.count > 1 ? fallback[1] : ""

        s.autoCompact = dict["autoCompactEnabled"] as? Bool ?? true

        let permissions = dict["permissions"] as? [String: Any]
        s.permissionMode = permissions?["defaultMode"] as? String ?? ""
        return s
    }

    /// Each `understood` predicate mirrors the cast `parse` uses for that key,
    /// so a value we couldn't read is never mistaken for one the user cleared.
    nonisolated static func apply(_ s: ClaudeSettings, to dict: inout [String: Any]) {
        ClaudeSettingsStore.set(&dict, "model",
                                s.model.isEmpty ? nil : s.model) { $0 is String }
        ClaudeSettingsStore.set(&dict, "effortLevel",
                                s.effortLevel.isEmpty ? nil : s.effortLevel) { $0 is String }

        // Order carries meaning (1차 then 2차), so a blank 1차 promotes 2차
        // rather than leaving a hole. Duplicates would be dead entries.
        //
        // The UI only shows two slots but the key accepts three, and anything
        // past the second is kept: overwriting the array with just what we
        // display would delete an entry the user can't even see here.
        let tail = Array((dict["fallbackModel"] as? [String] ?? []).dropFirst(2))
        var chain = [s.fallbackPrimary, s.fallbackSecondary].filter { !$0.isEmpty } + tail
        chain = chain.reduce(into: [String]()) { acc, m in if !acc.contains(m) { acc.append(m) } }
        ClaudeSettingsStore.set(&dict, "fallbackModel",
                                chain.isEmpty ? nil : chain) { $0 is [String] }

        // true is Claude Code's default — leave the key out rather than writing
        // a value that only restates it.
        ClaudeSettingsStore.set(&dict, "autoCompactEnabled",
                                s.autoCompact ? nil : false) { $0 is Bool }

        ClaudeSettingsStore.setNested(&dict, "permissions", "defaultMode",
                                      s.permissionMode.isEmpty ? nil : s.permissionMode) {
            $0 is String
        }
    }
}

// MARK: - Choices

/// A single Picker choice: the value written to JSON plus its Korean label.
struct ClaudeChoice: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

enum ClaudeChoices {
    /// Model aliases rather than pinned IDs — aliases keep tracking the current
    /// generation instead of going stale on the next release.
    static let models: [ClaudeChoice] = [
        .init(value: "opus", label: "Opus (가장 강력)"),
        .init(value: "sonnet", label: "Sonnet (균형)"),
        .init(value: "haiku", label: "Haiku (가장 빠름)"),
        .init(value: "fable", label: "Fable"),
    ]

    static let efforts: [ClaudeChoice] = [
        .init(value: "low", label: "낮음 (low)"),
        .init(value: "medium", label: "보통 (medium)"),
        .init(value: "high", label: "높음 (high)"),
        .init(value: "xhigh", label: "매우 높음 (xhigh)"),
    ]

    /// `allow`(전부 허용) is intentionally absent: a mis-click in a GUI that
    /// silently grants every tool call is a worse trade than the convenience.
    /// Anyone who wants it can still set it in the file by hand.
    static let permissionModes: [ClaudeChoice] = [
        .init(value: "ask", label: "매번 확인 (ask)"),
        .init(value: "auto", label: "자동 분류 (auto)"),
        .init(value: "deny", label: "전부 차단 (deny)"),
    ]

    /// Prepends the "key absent" choice and, when the file holds a value we
    /// don't know (a pinned model ID, a mode we don't list), appends it so the
    /// Picker shows the truth instead of going blank — and so merely opening
    /// the window can't silently rewrite it.
    static func options(_ known: [ClaudeChoice],
                        current: String,
                        emptyLabel: String) -> [ClaudeChoice] {
        var all = [ClaudeChoice(value: "", label: emptyLabel)] + known
        if !current.isEmpty && !known.contains(where: { $0.value == current }) {
            all.append(ClaudeChoice(value: current,
                                    label: "\(displayable(current)) (직접 설정한 값)"))
        }
        return all
    }

    /// The value is arbitrary file content, and it's about to name a row in a
    /// picker. Bidi overrides could make a row read as a different setting than
    /// the one it selects, and an unbounded string blows out the layout — so
    /// strip formatting controls and cap the length. Only the *label* is
    /// touched; the value written back stays byte-for-byte.
    private static func displayable(_ value: String) -> String {
        let stripped = String(String.UnicodeScalarView(
            value.unicodeScalars.filter { !unsafeForDisplay.contains($0) }
        ))
        return stripped.count > 64 ? stripped.prefix(64) + "…" : stripped
    }

    private static let unsafeForDisplay: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.formUnion(CharacterSet(charactersIn: "\u{200E}"..."\u{200F}")) // LRM/RLM
        set.formUnion(CharacterSet(charactersIn: "\u{202A}"..."\u{202E}")) // bidi embedding
        set.formUnion(CharacterSet(charactersIn: "\u{2066}"..."\u{2069}")) // bidi isolates
        return set
    }()
}
