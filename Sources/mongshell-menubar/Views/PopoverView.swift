import SwiftUI

/// Apple-style light popover reproducing the mongshell-menubar handoff (308px wide).
struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var openClaw: OpenClawModel
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private var snap: UsageSnapshot { model.snapshot }
    private var fiveMeter: Meter { Meter(usedPercent: snap.fiveHourPercent, showRemaining: prefs.showRemaining) }
    /// Explicit label (both modes) so it's never ambiguous whether the
    /// numbers/graphs show consumed vs remaining amount.
    private var modeSuffix: String { prefs.showRemaining ? " · 남은 양" : " · 사용량" }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            stateBanner
            primaryGauge
            hairline
            weeklySection
            if prefs.showsOpenClaw {
                hairline
                openClawSection
                if let host = openClaw.hostHealth.host {
                    hairline
                    serverHostSection(host)
                }
                serverCheckedRow
            }
            hairline
            footer
        }
        .frame(width: 308)
        .background(Palette.popoverBG)
        .environment(\.colorScheme, .light)
    }

    // MARK: openclaw (unified section)

    private var openClawSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                Text("openclaw")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                Circle()
                    .fill(openClaw.health.dotColor)
                    .frame(width: 7, height: 7)
                Text(openClaw.health.shortLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }

            if let detail = openClaw.health.detailText {
                // Remote text: already flattened and capped by the client, and
                // capped again here so it can never push the section around.
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, openClaw.hostHealth.host == nil ? 0 : Self.serverSectionBottomPadding)
    }

    // MARK: Server host (Decision #31)

    /// Space under a server section that another section follows. The last
    /// one is followed by `serverCheckedRow` instead, which brings its own.
    private static let serverSectionBottomPadding: CGFloat = 16

    /// The server's own signals, under the service that runs on it. Rows the
    /// server didn't send (no battery → no power row) leave no gap.
    private func serverHostSection(_ host: ServerHost) -> some View {
        // Once the server has gone quiet the figures are only the last ones
        // known: greyed, and no row is pointed at as the cause.
        let stale: Bool
        if case .unreachable = openClaw.hostHealth { stale = true } else { stale = false }
        let powerText = host.power?.lineText
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                Text("서버")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                if let dotColor = openClaw.hostHealth.dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Text(openClaw.hostHealth.shortLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }

            if powerText != nil || host.disk != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let power = host.power, let powerText {
                        serverHostRow(glyph: "bolt.fill", text: powerText,
                                      level: power.level, stale: stale)
                    }
                    if let disk = host.disk {
                        serverHostRow(glyph: "internaldrive.fill", text: disk.lineText,
                                      level: disk.level, stale: stale)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
    }

    /// One figure. The glyph takes the signal's level color when that signal
    /// is a reason for the header's verdict; the text stays readable.
    private func serverHostRow(glyph: String, text: String, level: ServerHostLevel,
                               stale: Bool) -> some View {
        let flagged = !stale && level != .ok
        return HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(flagged ? level.color : Palette.textTertiary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(stale ? Palette.textTertiary : Palette.textPrimary)
        }
    }

    /// When the status document was last read, and a way to read it again.
    /// Both server sections come from that one document, so this sits once,
    /// under the last of them. Read-only by design (Decision #25): restarts
    /// happen on the server.
    private var serverCheckedRow: some View {
        HStack(spacing: 8) {
            Text(openClaw.checkedClockText.map { "서버 확인 \($0)" } ?? "서버 확인 기록 없음")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 8)
            Button("새로고침") { openClaw.refreshNow() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            RingView(percent: fiveMeter.displayPercent, color: fiveMeter.color, lineWidth: 3, diameter: 18)
            Text("mongshell-menubar")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            Circle().fill(statusBadge.color).frame(width: 7, height: 7)
            Text(statusBadge.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            overflowMenu
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    /// Real connection status (replaces the old fabricated Off-peak label —
    /// the usage endpoint provides no peak-window data). Freshness is shown
    /// separately in the footer, so this only conveys the connection state.
    private var statusBadge: (color: Color, text: String) {
        switch model.loadState {
        case .loaded:      return (Palette.onlineDot, "연결됨")
        case .loading:     return (Palette.textTertiary, "동기화 중")
        case .signedOut:   return (Palette.textTertiary, "샘플")
        case .rateLimited: return (Palette.amber, "제한됨")
        case .error:       return (Palette.red, "오류")
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("새로고침") { model.refreshNow() }
            Button("설정…") { onOpenSettings() }
            if case .loaded(.oauthLogin) = model.loadState {
                Button("로그아웃") { model.signOut() }
            }
            Divider()
            Button("mongshell-menubar 종료") { onQuit() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(Palette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22)
    }

    // MARK: Connection banner (only when not cleanly loaded)

    @ViewBuilder private var stateBanner: some View {
        switch model.loadState {
        case .signedOut:
            banner(text: "샘플 데이터 표시 중 — 로그인하면 실제 사용량이 보여요",
                   tint: Palette.amber) {
                Button("로그인") { Task { await model.signIn() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        case .loading:
            banner(text: "불러오는 중…", tint: Palette.textSecondary) { EmptyView() }
        case .rateLimited:
            banner(text: "요청이 제한되었습니다 (잠시 후 자동 재시도)",
                   tint: Palette.amber) { EmptyView() }
        case .error(let msg):
            banner(text: msg, tint: Palette.red) {
                Button("재시도") { model.refreshNow() }
                    .controlSize(.small)
            }
        case .loaded(let source):
            if source == .claudeCodeCLI {
                banner(text: "Claude Code 계정 사용 중", tint: Palette.onlineDot) { EmptyView() }
            } else {
                EmptyView()
            }
        }
    }

    private func banner<Trailing: View>(text: String, tint: Color,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(tint.opacity(0.06))
    }

    // MARK: Primary 5-hour gauge

    private var primaryGauge: some View {
        VStack(spacing: 0) {
            ZStack {
                RingView(percent: fiveMeter.displayPercent, color: fiveMeter.color, lineWidth: 8, diameter: 132)
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text("\(fiveMeter.displayPercent)")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .tracking(-1)
                    Text("%")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 132, height: 132)
            .padding(.bottom, 12)

            Text("5시간 한도" + modeSuffix)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .padding(.bottom, 3)
            Text(snap.fiveHourResetText)
                .font(.system(size: 14))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: Weekly limits

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("7일 한도" + modeSuffix)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(snap.weeklyResetText)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.bottom, 14)

            usageBar(meter: Meter(usedPercent: snap.weeklyAllPercent, showRemaining: prefs.showRemaining),
                     label: "전체 모델", color: nil)

            ForEach(snap.models) { m in
                Spacer().frame(height: 16)
                usageBar(meter: Meter(usedPercent: m.percent, showRemaining: prefs.showRemaining),
                         label: m.name, color: Palette.fablePurple)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 18)
    }

    /// `color` nil = use the meter's risk color; non-nil = fixed brand color
    /// (e.g. Fable purple). Fill width + number follow the display mode.
    private func usageBar(meter: Meter, label: String, color: Color?) -> some View {
        let pct = meter.displayPercent
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.trackBar)
                    Capsule().fill(color ?? meter.color)
                        .frame(width: max(0, geo.size.width * CGFloat(pct) / 100))
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let credits = snap.creditsText {
                Text(credits)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Text(TimeText.updatedClock(snap.lastUpdated))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

/// A progress ring drawn with SwiftUI trim (top-start, clockwise).
struct RingView: View {
    let percent: Int
    let color: Color
    var lineWidth: CGFloat
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}
