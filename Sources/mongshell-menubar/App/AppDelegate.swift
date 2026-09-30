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
    /// Invisible, click-through window laid exactly over the status item while
    /// the hover summary is up; the summary is anchored to it rather than to
    /// the button. A popover anchored to the button makes the system draw the
    /// item as selected — right for the click popover, wrong for a hover.
    private var hoverAnchor: NSWindow?
    /// Closes the hover summary if the cursor is no longer over the icon — see
    /// `showHoverSummary`. Set while the summary is shown; if something other
    /// than `hideHoverSummary` closes the summary, it clears itself on its
    /// next tick.
    private var hoverWatchdog: Timer?
    /// How often the watchdog looks. A missed mouseExited is rare, so this only
    /// bounds how long a stray summary can stay up.
    private static let hoverWatchdogInterval: TimeInterval = 0.5
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
        // delay. The tracking-area callbacks below drive the normal show/close.
        //
        // Not .transient: AppKit dismisses a transient popover on a click
        // outside it and swallows that click, so the first click on the icon
        // only closed the summary and `togglePopover` never ran — the full
        // popover took a second click. With .applicationDefined the click
        // reaches the button, and we close the summary ourselves.
        //
        // What changes: the summary now stays for as long as the cursor is over
        // the icon, app switches included (.transient closed it on those). The
        // watchdog in `showHoverSummary` only cleans up the case where the
        // cursor has left but mouseExited never arrived.
        hoverPopover = NSPopover()
        hoverPopover.behavior = .applicationDefined
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
        // The server host indicator appearing or going away swaps the single
        // openclaw indicator for the stacked pair, which isn't the same width.
        openClaw.$hostHealth.map { $0 == .absent }.removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeStatusItem() }
            }.store(in: &cancellables)

        resizeStatusItem()
        model.start()

        // Parks in .notConfigured (no polling) when no status URL is set.
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
        guard !popover.isShown, !hoverPopover.isShown,
              let frame = statusItemFrameOnScreen else { return }
        let anchor = hoverAnchor ?? Self.makeHoverAnchor()
        hoverAnchor = anchor
        anchor.setFrame(frame, display: false)
        anchor.orderFrontRegardless()
        guard let anchorView = anchor.contentView else { return }
        hoverPopover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        // mouseExited normally closes the summary. If that event is ever
        // missed, nothing else would close an .applicationDefined popover, so
        // check the cursor position while the summary is up.
        hoverWatchdog?.invalidate()
        let watchdog = Timer(timeInterval: Self.hoverWatchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.hoverPopover.isShown || !self.isCursorOverStatusItem {
                    self.hideHoverSummary()
                }
            }
        }
        // .common: keep checking while the run loop is in an event-tracking
        // mode (a drag in the settings window), not only in .default.
        RunLoop.main.add(watchdog, forMode: .common)
        hoverWatchdog = watchdog
    }

    private func hideHoverSummary() {
        hoverWatchdog?.invalidate()
        hoverWatchdog = nil
        hoverPopover.performClose(nil)
        hoverAnchor?.orderOut(nil)
    }

    /// Borderless and fully transparent, and it ignores mouse events, so the
    /// icon beneath still gets the hover tracking and the click.
    private static func makeHoverAnchor() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        return window
    }

    private var statusItemFrameOnScreen: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var isCursorOverStatusItem: Bool {
        statusItemFrameOnScreen?.contains(NSEvent.mouseLocation) ?? false
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

    /// Also the target of the app's ⌘, command (`MongshellMenubarApp`).
    func openSettings() {
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
