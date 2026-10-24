import SwiftUI
import AppKit

/// A titled window that stays where it is put. AppKit constrains a titled
/// window's frame onto a screen when it is ordered front, so a window parked at
/// (-20000, -20000) would be dragged to the bottom-left corner of a display and
/// flash there for every settings capture.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

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
        // Floored to an even second: the running-check dot blinks on the
        // clock's parity, and the run's wall time would otherwise pick the frame.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 2).rounded(.down) * 2)
        OpenClawModel.shared.presentForSnapshot(.snapshotOK(now: now), now: now)

        write(MenuBarStrip(scheme: .dark).frame(width: 700, height: 44)
                .environment(\.colorScheme, .dark),
              to: base, "menubar_strip_dark", scale: 3)
        write(MenuBarStrip(scheme: .light).frame(width: 700, height: 44)
                .environment(\.colorScheme, .light),
              to: base, "menubar_strip_light", scale: 3)
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            write(MenuBarHostStrip(scheme: scheme).frame(width: 900, height: 44)
                    .environment(\.colorScheme, scheme),
                  to: base, "menubar_host_strip_\(name)", scale: 3)
        }
        write(PopoverPreview(), to: base, "popover", scale: 2)
        UsageModel.shared.presentForSnapshot(.snapshotExtraLimit(now: now), state: .loaded(.oauthLogin))
        write(PopoverPreview(), to: base, "popover_extra_limit", scale: 2)
        UsageModel.shared.presentForSnapshot(.sample, state: .signedOut)
        OpenClawModel.shared.presentForSnapshot(
            .snapshotOK(now: now, host: .snapshotOnBattery), now: now)
        write(PopoverPreview(), to: base, "popover_host_on_battery", scale: 2)
        OpenClawModel.shared.presentForSnapshot(
            .snapshotOK(now: now, host: .snapshotDiskCritical), now: now)
        write(PopoverPreview(), to: base, "popover_host_disk_critical", scale: 2)
        OpenClawModel.shared.presentForSnapshot(
            .snapshotOK(now: now, host: .snapshotRunnersPartial), now: now)
        write(PopoverPreview(), to: base, "popover_host_runners_partial", scale: 2)
        OpenClawModel.shared.presentForSnapshot(
            .snapshotUnreachable(now: now, host: .snapshotOnBattery), now: now)
        write(PopoverPreview(), to: base, "popover_host_unreachable", scale: 2)
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

        renderGitHub(to: base, now: now)

        return true
    }

    /// The GitHub region (Decision #45) on canned PRs. The region stays off
    /// for every image above, so those stay as they were; here the model is
    /// shown a sample snapshot directly, with no network and no Keychain.
    private static func renderGitHub(to base: URL, now: Date) {
        let github = GitHubModel(prefs: .shared)
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            write(GitHubMenuBarStrip(scheme: scheme, count: 3, dot: .red)
                    .frame(width: 320, height: 44).environment(\.colorScheme, scheme),
                  to: base, "github_menubar_strip_\(name)", scale: 3)
        }
        write(GitHubMenuBarStrip(scheme: .dark, count: 0, dot: .green)
                .frame(width: 320, height: 44).environment(\.colorScheme, .dark),
              to: base, "github_menubar_strip_zero_dark", scale: 3)
        // Nothing blocked, a check still running: amber, still no number.
        write(GitHubMenuBarStrip(scheme: .dark, count: 0, dot: .amber)
                .frame(width: 320, height: 44).environment(\.colorScheme, .dark),
              to: base, "github_menubar_strip_ci_dark", scale: 3)
        // A mergeable PR of mine turns the glyph into the green merge arrow
        // (Decision #52) in the same slot — compare with `_zero_dark`: the
        // region must not move by a pixel.
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            write(GitHubMenuBarStrip(scheme: scheme, count: 0, dot: .green, mergeReady: true)
                    .frame(width: 320, height: 44).environment(\.colorScheme, scheme),
                  to: base, "github_menubar_strip_merge_\(name)", scale: 3)
        }

        github.presentForSnapshot(.sample(now: now), state: .loaded(.ghCLI(account: "mongshellio")), now: now)
        write(GitHubHoverPreview(github: github), to: base, "github_hover", scale: 2)
        write(GitHubPopoverPreview(github: github), to: base, "github_popover", scale: 2)
        // The squash merge control on the CLEAN row (Decision #49) after
        // GitHub refused the merge; `github_popover` has it at rest.
        let sample = GitHubSnapshot.sample(now: now)
        if let mergeable = sample.mine.first(where: { GitHubMergePolicy.canOffer($0, section: .mine) }) {
            github.presentForSnapshot(sample, state: .loaded(.ghCLI(account: "mongshellio")), now: now,
                                      mergeActivity: [mergeable.id: .failed(
                                        GitHubMergeResult.notMergeable("Required status check \"build\" is expected.")
                                            .failureReason ?? "")])
            write(GitHubPopoverPreview(github: github), to: base, "github_popover_merge_failed", scale: 2)
        } else {
            report("github_popover_merge_failed: no mergeable row in the sample")
        }
        github.presentForSnapshot(.sampleOverflow(now: now), state: .loaded(.pat), now: now)
        write(GitHubPopoverPreview(github: github), to: base, "github_popover_overflow", scale: 2)
        github.presentForSnapshot(nil, state: .noToken, now: now)
        write(GitHubPopoverPreview(github: github), to: base, "github_popover_no_token", scale: 2)
        github.presentForSnapshot(nil, state: .unauthorized, now: now)
        write(GitHubPopoverPreview(github: github), to: base, "github_popover_unauthorized", scale: 2)

        // The section's rows only appear with the region on; switch it on in
        // the volatile argument domain for this one image and off again, so
        // `settings` above and the real preference are untouched.
        github.presentForSnapshot(.sample(now: now), state: .loaded(.ghCLI(account: "mongshellio")), now: now)
        let domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(domain.merging(["githubEnabled": true]) { $1 },
                                               forName: UserDefaults.argumentDomain)
        writeWindowed(GitHubSectionPreview(github: github), size: NSSize(width: 380, height: 420),
                      to: base, "settings_github")
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// `Form` is AppKit-backed and comes out blank through `ImageRenderer`, so
    /// form-based views are hosted in an off-screen window and captured with
    /// `cacheDisplay`. Still headless — the window is parked far off any screen
    /// and never becomes key.
    private static func writeWindowed<V: View>(_ view: V, size: NSSize,
                                               to dir: URL, _ name: String) {
        let win = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size),
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
    static func snapshotOK(now: Date, host: ServerHost? = nil) -> OpenClawReading {
        var reading = OpenClawReading()
        reading.recordSuccess(OpenClawStatus(
            checkedAt: now.addingTimeInterval(-40), health: .ok(detail: "Telegram default"),
            intervalSeconds: 60, autoHeal: true, lastHeal: nil, host: host,
            agentVersion: "v1.2.0+3"), receivedAt: now)
        return reading
    }

    /// The server reports the gateway down and says why. Sent no version, as
    /// an older agent does — the version line is left out.
    static func snapshotDown(now: Date) -> OpenClawReading {
        var reading = OpenClawReading()
        reading.recordSuccess(OpenClawStatus(
            checkedAt: now.addingTimeInterval(-40), health: .down(detail: "openclaw 바이너리 없음"),
            intervalSeconds: 60, autoHeal: true, lastHeal: nil, host: nil), receivedAt: now)
        return reading
    }

    /// Last good answer 23 minutes ago, and the latest request failed.
    static func snapshotUnreachable(now: Date, host: ServerHost? = nil) -> OpenClawReading {
        var reading = OpenClawReading()
        reading.recordSuccess(OpenClawStatus(
            checkedAt: now.addingTimeInterval(-23 * 60), health: .ok(detail: "Telegram default"),
            intervalSeconds: 60, autoHeal: true, lastHeal: nil, host: host,
            agentVersion: "v1.2.0+3"), receivedAt: now)
        reading.recordFailure(.offline)
        return reading
    }
}

/// Canned server host signals for the reference images.
private extension ServerHost {
    /// A laptop-as-server that lost its adapter; its CI runners are all up.
    static let snapshotOnBattery = ServerHost(
        level: .warning,
        power: ServerHostPower(level: .warning, pluggedIn: false, charging: false,
                               batteryPercent: 82),
        disk: ServerHostDisk(level: .ok, availableBytes: 32_604_813_672),
        runners: ServerHostRunners(level: .ok, running: 4, total: 4))

    /// Plugged in with room to spare, but one of four CI runners has stopped.
    static let snapshotRunnersPartial = ServerHost(
        level: .warning,
        power: ServerHostPower(level: .ok, pluggedIn: true, charging: false,
                               batteryPercent: 100),
        disk: ServerHostDisk(level: .ok, availableBytes: 32_604_813_672),
        runners: ServerHostRunners(level: .warning, running: 3, total: 4))

    /// A server without a battery, its disk nearly full.
    static let snapshotDiskCritical = ServerHost(
        level: .critical, power: nil,
        disk: ServerHostDisk(level: .critical, availableBytes: 4_200_000_000))
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

/// Menu-bar mock for the stacked indicators: no host signals first (the
/// single indicator, as a reference), then the server host dot at each level
/// and unreachable, against different openclaw dots — the two are judged
/// independently. The inner band is as thick as the real menu bar and clips,
/// so a stack that doesn't fit shows up cut off.
private struct MenuBarHostStrip: View {
    let scheme: ColorScheme
    private static let menuBarThickness: CGFloat = 22
    private let items: [(id: Int, openClaw: OpenClawHealth, host: ServerHostHealth)] = [
        (0, .ok(detail: ""), .absent),
        (1, .ok(detail: ""), .reported(ServerHost(level: .ok, power: nil, disk: nil))),
        (2, .ok(detail: ""), .reported(ServerHost(level: .warning, power: nil, disk: nil))),
        (3, .down(detail: ""), .reported(ServerHost(level: .critical, power: nil, disk: nil))),
        (4, .unreachable(detail: ""),
         .unreachable(last: ServerHost(level: .ok, power: nil, disk: nil))),
    ]
    var body: some View {
        HStack(spacing: 26) {
            ForEach(items, id: \.id) { item in
                MenuBarContent(fiveHourUsed: 12, weeklyUsed: 34,
                               showRemaining: false, colorCoding: true,
                               showPercent: true,
                               fiveHourReset: "19:00",
                               openClawDotColor: item.openClaw.dotColor,
                               serverHostDotColor: item.host.dotColor)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: Self.menuBarThickness)
        .clipped()
        .background(scheme == .dark ? Color(hex: 0x2C2C30) : Color(hex: 0xE8E6E1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme == .dark ? Color(hex: 0x1A1A1D) : Color(hex: 0xCFCDC8))
    }
}

/// The settings window as shipped. The login-item model reads live system
/// state, but the snapshot binary is unbundled and never registered, so the
/// toggle renders deterministically off.
private struct SettingsPreview: View {
    var body: some View {
        SettingsView(model: .shared, prefs: .shared,
                     openClaw: .shared, claude: .shared,
                     loginItem: LoginItemModel(), github: GitHubModel(prefs: .shared))
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
            Section("서버") {
                OpenClawSettingsSection(prefs: .shared, openClaw: .shared)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }
}

/// Canned pull requests for the reference images — the mockup's rows
/// (design/github-pr-region/mockup.html § C2), never real ones.
private extension GitHubSnapshot {
    static func sample(now: Date) -> GitHubSnapshot {
        let minute = 60.0, hour = 3600.0, day = 86_400.0
        func check(_ name: String, _ outcome: PRCheckOutcome,
                   startedAgo: TimeInterval, took: TimeInterval? = nil) -> PRCheck {
            PRCheck(name: name, outcome: outcome,
                    startedAt: now.addingTimeInterval(-startedAgo),
                    completedAt: took.map { now.addingTimeInterval(-startedAgo + $0) },
                    url: nil)
        }
        func passed(_ count: Int, total: TimeInterval) -> [PRCheck] {
            (1...count).map { i in
                check("check-\(i)", .passed, startedAgo: 20 * minute, took: i == count ? total : 30)
            }
        }
        func pr(_ repo: String, _ number: Int, _ title: String, updatedAgo: TimeInterval,
                draft: Bool = false, review: PRReviewDecision = PRReviewDecision.none,
                mergeable: PRMergeable = .mergeable, mergeState: PRMergeState = .blocked,
                rollup: PRChecksRollup,
                checks: [PRCheck], mergedAgo: TimeInterval? = nil,
                nodeID: String? = nil, headSHA: String? = nil) -> GitHubPullRequest {
            GitHubPullRequest(repository: repo, number: number, title: title,
                              url: URL(string: "https://github.com/\(repo)/pull/\(number)"),
                              isDraft: draft, reviewDecision: review, mergeable: mergeable,
                              mergeState: mergeState, checksRollup: rollup, checks: checks,
                              checksListComplete: true,
                              updatedAt: now.addingTimeInterval(-updatedAgo),
                              mergedAt: mergedAgo.map { now.addingTimeInterval(-$0) },
                              nodeID: nodeID, headSHA: headSHA)
        }
        return GitHubSnapshot(
            mine: [
                pr("mongshell/mongshell-menubar", 45, "feat: GitHub PR 영역을 메뉴바 두 번째 영역으로",
                   updatedAgo: 25 * minute, rollup: .failure, checks: [
                    check("build", .failed, startedAgo: 3 * minute, took: 48),
                    check("test", .running, startedAgo: 83),
                    check("snapshot", .passed, startedAgo: 2 * minute, took: 31),
                   ]),
                pr("mongshell/mongshell-menubar", 46, "docs: PHILOSOPHY 에 옵트인 두 번째 영역 예외 추가",
                   updatedAgo: hour, draft: true, rollup: .success,
                   checks: passed(3, total: 2 * minute + 40)),
                pr("mongshell/growdle", 121, "fix: 주간 리포트 집계가 UTC 자정에 끊기던 문제",
                   updatedAgo: 3 * hour, rollup: .pending, checks: [
                    check("static", .passed, startedAgo: 5 * minute, took: minute + 12),
                    check("test", .running, startedAgo: 83),
                    check("automerge", .skipped, startedAgo: 5 * minute, took: 1),
                    check("Vercel", .running, startedAgo: 125),
                    check("Preview Comments", .passed, startedAgo: 4 * minute, took: 4),
                   ]),
                // No review rules (reviewDecision null) but GitHub says CLEAN —
                // "머지 가능" without an approval (a solo repo), so it offers
                // the squash merge. Fixture ids, not a real PR's.
                pr("mongshell/bookdam", 57, "refactor: auth 라우트의 세션 조회를 미들웨어로",
                   updatedAgo: 2 * day, mergeState: .clean, rollup: .success,
                   checks: passed(5, total: 6 * minute + 12),
                   nodeID: "PR_snapshot57", headSHA: "57575757575757575757575757575757575757aa"),
                pr("mongshell/bookdam", 55, "feat: 대화 내보내기 (markdown)",
                   updatedAgo: 4 * day, review: .reviewRequired, rollup: .success,
                   checks: passed(4, total: 5 * minute + 58)
                        + [check("automerge", .skipped, startedAgo: 20 * minute, took: 1)]),
            ],
            recentlyMerged: [
                pr("mongshell/mongshell-menubar", 44,
                   "fix: 갱신 토큰이 서버에서 폐기되면 자체 토큰을 버리고 재로그인을 안내하며 재발 진단 로그를 남긴다",
                   updatedAgo: day, rollup: .success, checks: [], mergedAgo: day),
                pr("mongshell/mongshell-menubar", 42,
                   "fix: probe 타임아웃이 openclaw 손자 프로세스에 막혀 무력화되던 문제",
                   updatedAgo: 3 * day, rollup: .success, checks: [], mergedAgo: 3 * day),
                // Four digits on purpose: a PR number interpolated into a
                // localized Text gets a grouping separator ("#1,988").
                pr("mongshell/gambau", 1988,
                   "feat(profitability): 판매자배송 상품의 정산 예정 금액을 미리 보여준다",
                   updatedAgo: 4 * day, rollup: .success, checks: [], mergedAgo: 4 * day),
            ],
            rateLimit: GitHubRateLimit(cost: 12, remaining: 4812, limit: 5000,
                                       resetAt: now.addingTimeInterval(hour)),
            fetchedAt: now,
            tokenScopesLackRepo: nil)
    }

    /// Past the section caps: ten of my PRs (eight rows + "외 2건"), four
    /// merged (three + "외 1건").
    static func sampleOverflow(now: Date) -> GitHubSnapshot {
        var snapshot = sample(now: now)
        let template = snapshot.mine[4]
        snapshot.mine = (1...10).map { i in
            GitHubPullRequest(repository: "mongshell/bookdam", number: 100 + i,
                              title: "chore: 샘플 PR \(i)",
                              url: URL(string: "https://github.com/mongshell/bookdam/pull/\(100 + i)"),
                              isDraft: false,
                              reviewDecision: PRReviewDecision.none, mergeable: .mergeable,
                              mergeState: .blocked, checksRollup: PRChecksRollup.none, checks: [],
                              checksListComplete: true,
                              updatedAt: template.updatedAt, mergedAt: nil,
                              nodeID: nil, headSHA: nil)
        }
        snapshot.recentlyMerged.append(snapshot.recentlyMerged[0])
        return snapshot
    }
}

/// Menu-bar mock of the two regions together (mockup § A3 / A2): the Claude
/// region as shipped, then the hairline and the GitHub region.
private struct GitHubMenuBarStrip: View {
    let scheme: ColorScheme
    let count: Int
    let dot: GitHubDot
    var mergeReady = false
    var body: some View {
        HStack(spacing: 0) {
            MenuBarContent(fiveHourUsed: 34, weeklyUsed: 61,
                           showRemaining: false, colorCoding: true,
                           showPercent: true, fiveHourReset: "19:00",
                           openClawDotColor: Palette.green)
            GitHubMenuBarContent(count: count, dot: dot.color, mergeReady: mergeReady)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme == .dark ? Color(hex: 0x2C2C30) : Color(hex: 0xE8E6E1))
    }
}

/// The GitHub hover summary, on the same backdrop as the popover images.
private struct GitHubHoverPreview: View {
    @ObservedObject var github: GitHubModel
    var body: some View {
        GitHubHoverSummaryView(model: github)
            .background(Palette.popoverBG)
            .padding(24)
            .background(Color(hex: 0xE8E6E1))
    }
}

private struct GitHubPopoverPreview: View {
    @ObservedObject var github: GitHubModel
    var body: some View {
        GitHubPopoverView(model: github, prefs: .shared, onOpenSettings: {}, onQuit: {})
            .padding(24)
            .background(Color(hex: 0xE8E6E1))
    }
}

/// The GitHub section alone, switched on, for the same reason as the others.
private struct GitHubSectionPreview: View {
    @ObservedObject var github: GitHubModel
    var body: some View {
        Form {
            Section("GitHub") {
                GitHubSettingsSection(model: github, prefs: .shared)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }
}

private extension UsageSnapshot {
    /// The sample plus one limit of a kind the app does not know — what a
    /// reset/bonus from the settings page would look like. Kept out of
    /// `.sample` itself: the signed-out popover must not show a fake bonus.
    static func snapshotExtraLimit(now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot.sample
        // Pinned to a weekday + clock like `.sample.weeklyResetAt`, so the
        // caption reads "수요일 21:59 초기화" whenever the render runs.
        let resetAt = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 21, minute: 59, weekday: 4),
            matchingPolicy: .nextTime)
        snapshot.extraLimits = [ExtraLimit(
            id: "bonus", kind: "bonus", scopeModel: nil, percent: 12,
            resetAt: resetAt, resetText: TimeText.resetsAt(resetAt), isActive: true)]
        return snapshot
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
