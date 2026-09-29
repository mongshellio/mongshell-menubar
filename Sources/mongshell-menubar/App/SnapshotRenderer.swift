import SwiftUI
import AppKit

/// Offscreen PNG rendering for visual QA (no screen-recording permission
/// needed). Triggered by the MONGSHELL_SNAPSHOT=<dir> env var; renders reference
/// images then exits.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["MONGSHELL_SNAPSHOT"] else { return false }
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // openclaw: a fixture URL + canned readings, so the images show the
        // section without a server and never carry a real token or state.
        // The argument domain is volatile — nothing is written to disk.
        UserDefaults.standard.setVolatileDomain([
            "openClawStatusURL": "https://openclaw-server.example.ts.net:8443/0123456789abcdef0123456789abcdef",
            "menuBarTarget": MenuBarTarget.claudeAndOpenClaw.rawValue,
        ], forName: UserDefaults.argumentDomain)
        let now = Date()
        OpenClawModel.shared.presentForSnapshot(.snapshotOK(now: now), now: now)

        write(MenuBarStrip(scheme: .dark).frame(width: 700, height: 44)
                .environment(\.colorScheme, .dark),
              to: base, "menubar_strip_dark", scale: 3)
        write(MenuBarStrip(scheme: .light).frame(width: 700, height: 44)
                .environment(\.colorScheme, .light),
              to: base, "menubar_strip_light", scale: 3)
        write(PopoverPreview(), to: base, "popover", scale: 2)
        OpenClawModel.shared.presentForSnapshot(.snapshotUnreachable(now: now), now: now)
        write(PopoverPreview(), to: base, "popover_openclaw_unreachable", scale: 2)
        OpenClawModel.shared.presentForSnapshot(.snapshotDown(now: now), now: now)
        write(PopoverPreview(), to: base, "popover_openclaw_down", scale: 2)
        writeWindowed(OpenClawSectionPreview(), size: NSSize(width: 380, height: 420),
                      to: base, "settings_openclaw_down")
        OpenClawModel.shared.presentForSnapshot(.snapshotOK(now: now), now: now)

        // The Claude Code section renders whatever settings file it is pointed
        // at, so default to a fixture: reference images must never carry the
        // operator's own model choice or permission mode. An explicit
        // MONGSHELL_CLAUDE_SETTINGS still wins.
        if ProcessInfo.processInfo.environment["MONGSHELL_CLAUDE_SETTINGS"] == nil {
            let fixture = base.appendingPathComponent("claude-settings-fixture.json")
            let json = #"{"model":"opus","effortLevel":"high","permissions":{"defaultMode":"auto"}}"#
            try? json.write(to: fixture, atomically: true, encoding: .utf8)
            setenv("MONGSHELL_CLAUDE_SETTINGS", fixture.path, 1)
        }
        ClaudeSettingsModel.shared.start()
        writeWindowed(SettingsPreview(), size: NSSize(width: 380, height: 700),
                      to: base, "settings")
        writeWindowed(ClaudeSectionPreview(), size: NSSize(width: 380, height: 560),
                      to: base, "settings_claude")
        writeWindowed(OpenClawSectionPreview(), size: NSSize(width: 380, height: 420),
                      to: base, "settings_openclaw")

        return true
    }

    /// `Form` is AppKit-backed and comes out blank through `ImageRenderer`, so
    /// form-based views are hosted in an off-screen window and captured with
    /// `cacheDisplay`. Still headless — the window is parked far off any screen
    /// and never becomes key.
    private static func writeWindowed<V: View>(_ view: V, size: NSSize,
                                               to dir: URL, _ name: String) {
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled], backing: .buffered, defer: false)
        // Programmatic NSWindow defaults to isReleasedWhenClosed == true, so
        // close() below would have AppKit release the window on top of ARC's
        // own release of `win` — an over-release that crashes in the launch
        // Apple Event's autorelease-pool drain (SIGSEGV after all PNGs are
        // written).
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(rootView: view)
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        defer { win.close() }

        guard let content = win.contentView else {
            report("\(name): no content view")
            return
        }
        content.layoutSubtreeIfNeeded()
        // SwiftUI populates the form on the next runloop passes; capturing
        // immediately yields an empty view.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            report("\(name): capture failed")
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            report("\(name): PNG encode failed")
            return
        }
        do {
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        } catch {
            // A silently missing reference image reads as "nothing changed".
            report("\(name): \(error)")
        }
    }

    private static func write<V: View>(_ view: V, to dir: URL, _ name: String, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            report("\(name): render failed")
            return
        }
        do {
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        } catch {
            report("\(name): \(error)")
        }
    }

    /// A silently missing reference image reads as "nothing changed", so every
    /// failure path says so on stderr.
    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("snapshot \(message)\n".utf8))
    }
}

// MARK: - Preview views

/// Canned openclaw readings for the reference images.
private extension OpenClawReading {
    static func snapshotOK(now: Date) -> OpenClawReading {
        var reading = OpenClawReading()
        reading.recordSuccess(OpenClawStatus(
            checkedAt: now.addingTimeInterval(-40), health: .ok(detail: "Telegram default"),
            intervalSeconds: 60, autoHeal: true, lastHeal: nil), receivedAt: now)
        return reading
    }

    /// The server reports the gateway down and says why.
    static func snapshotDown(now: Date) -> OpenClawReading {
        var reading = OpenClawReading()
        reading.recordSuccess(OpenClawStatus(
            checkedAt: now.addingTimeInterval(-40), health: .down(detail: "openclaw 바이너리 없음"),
            intervalSeconds: 60, autoHeal: true, lastHeal: nil), receivedAt: now)
        return reading
    }

    /// Last good answer 23 minutes ago, and the latest request failed.
    static func snapshotUnreachable(now: Date) -> OpenClawReading {
        var reading = OpenClawReading()
        reading.recordSuccess(OpenClawStatus(
            checkedAt: now.addingTimeInterval(-23 * 60), health: .ok(detail: "Telegram default"),
            intervalSeconds: 60, autoHeal: true, lastHeal: nil), receivedAt: now)
        reading.recordFailure(.offline)
        return reading
    }
}

/// Menu-bar mock: Claude mark + `5h · 7d` text at three usage-level pairs, each
/// with a different openclaw dot (ok / server unreachable / gateway down) so the
/// grey-vs-red distinction is visible side by side.
private struct MenuBarStrip: View {
    let scheme: ColorScheme
    private let items: [(five: Int, weekly: Int, openClaw: OpenClawHealth)] = [
        (12, 34, .ok(detail: "")),
        (62, 45, .unreachable(detail: "")),
        (95, 91, .down(detail: "")),
    ]
    var body: some View {
        HStack(spacing: 26) {
            ForEach(items, id: \.five) { item in
                MenuBarContent(fiveHourUsed: item.five, weeklyUsed: item.weekly,
                               showRemaining: false, colorCoding: true,
                               showPercent: true,
                               fiveHourReset: "19:00",
                               openClawDotColor: item.openClaw.dotColor)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme == .dark ? Color(hex: 0x2C2C30) : Color(hex: 0xE8E6E1))
    }
}

/// The settings window as shipped. The login-item model reads live system
/// state, but the snapshot binary is unbundled and never registered, so the
/// toggle renders deterministically off.
private struct SettingsPreview: View {
    var body: some View {
        SettingsView(model: .shared, prefs: .shared,
                     openClaw: .shared, claude: .shared,
                     loginItem: LoginItemModel())
    }
}

/// The Claude Code section alone — the window scrolls, so this is the only way
/// to see every row of it in one image.
private struct ClaudeSectionPreview: View {
    var body: some View {
        Form {
            Section("Claude Code") {
                ClaudeSettingsSection(claude: .shared)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 560)
    }
}

/// The openclaw section alone, for the same reason as the Claude Code one.
private struct OpenClawSectionPreview: View {
    var body: some View {
        Form {
            Section("openclaw") {
                OpenClawSettingsSection(prefs: .shared, openClaw: .shared)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }
}

/// The live popover with sample data.
private struct PopoverPreview: View {
    var body: some View {
        PopoverView(
            model: UsageModel.shared, prefs: Preferences.shared, openClaw: OpenClawModel.shared,
            onOpenSettings: {}, onQuit: {}
        )
        .padding(24)
        .background(Color(hex: 0xE8E6E1))
    }
}
