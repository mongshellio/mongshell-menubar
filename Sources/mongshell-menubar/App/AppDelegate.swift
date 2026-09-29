import SwiftUI
import AppKit
import Combine

/// An NSHostingView that lets mouse events fall through to the status-item
/// button underneath (so the button's click action still fires while the
/// SwiftUI icon keeps animating, e.g. the ≥90% pulse), while tracking cursor
/// enter/exit over the icon to drive the instant hover summary.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var hoverTracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // .inVisibleRect keeps the area glued to the (dynamically resized) icon
        // bounds with no manual recompute. hitTest returning nil above doesn't
        // affect tracking-area enter/exit delivery to this owner.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hoverPopover: NSPopover!
    private var settingsWindow: NSWindow?
    private var hostingView: PassthroughHostingView<MenuBarIconView>!
    private var cancellables = Set<AnyCancellable>()

    private let model = UsageModel.shared
    private let prefs = Preferences.shared
    private let openClaw = OpenClawModel.shared
    private let claude = ClaudeSettingsModel.shared
    // Not a singleton: only the settings window observes it (Models/CLAUDE.md —
    // 그 이유가 없는 상태는 소유자에게 주입).
    private let loginItem = LoginItemModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // QA hook: render reference PNGs offscreen, then exit.
        if SnapshotRenderer.runIfRequested() {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = MenuBarIconView(model: model, prefs: prefs, openClaw: openClaw)
        hostingView = PassthroughHostingView(rootView: icon)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        if let button = statusItem.button {
            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                hostingView.centerXAnchor.constraint(equalTo: button.centerXAnchor)
            ])
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover.behavior = .transient
        let content = PopoverView(
            model: model, prefs: prefs, openClaw: openClaw,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hc = NSHostingController(rootView: content)
        hc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hc

        // Instant hover summary: a lightweight popover shown the moment the
        // cursor enters the icon and closed when it leaves — no native-tooltip
        // delay. .transient lets AppKit also dismiss it on app switch / outside
        // interaction, so it can't linger if mouseExited never fires (e.g.
        // Cmd-Tab away without moving the cursor); the tracking-area callbacks
        // below drive the normal show/close.
        hoverPopover = NSPopover()
        hoverPopover.behavior = .transient
        hoverPopover.animates = false
        let hoverHC = NSHostingController(rootView: HoverSummaryView(model: model, prefs: prefs))
        hoverHC.sizingOptions = [.preferredContentSize]
        hoverPopover.contentViewController = hoverHC
        hostingView.onMouseEntered = { [weak self] in self?.showHoverSummary() }
        hostingView.onMouseExited = { [weak self] in self?.hideHoverSummary() }

        // Keep the status-item width in sync with icon content.
        model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in self?.resizeStatusItem() }
            .store(in: &cancellables)
        prefs.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            // menuBarTarget may have flipped, which shows/hides the unified
            // openclaw indicator and changes the bar width — resize to match.
            DispatchQueue.main.async { self?.resizeStatusItem() }
        }.store(in: &cancellables)

        resizeStatusItem()
        model.start()

        // No-op internally if openclaw isn't installed.
        openClaw.start()

        // Loads ~/.claude/settings.json and watches it, so the settings window
        // is already truthful when opened and tracks CLI-side edits live.
        // No-op if Claude Code isn't installed.
        claude.start()
    }

    private func resizeStatusItem() {
        hostingView.layoutSubtreeIfNeeded()
        let w = max(24, hostingView.fittingSize.width)
        statusItem.length = w
    }

    /// Show the instant hover summary below the icon. Suppressed while the full
    /// click popover is open so the two never stack.
    private func showHoverSummary() {
        guard let button = statusItem.button, !popover.isShown, !hoverPopover.isShown else { return }
        hoverPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func hideHoverSummary() {
        hoverPopover.performClose(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            hideHoverSummary() // don't stack the hover summary under the full popover
            // Freshen openclaw before showing its section in the unified popover.
            if prefs.showsOpenClaw {
                openClaw.refreshNow()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        // Re-read the login-item state on every open. The window (and its view
        // hierarchy) is retained across closes, so `.onAppear` would fire only
        // once — this is the reliable point to catch a change made directly in
        // System Settings.
        loginItem.refresh()
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(model: model, prefs: prefs, openClaw: openClaw,
                                claude: claude, loginItem: loginItem)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "mongshell-menubar 설정"
        win.contentViewController = NSHostingController(rootView: view)
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
