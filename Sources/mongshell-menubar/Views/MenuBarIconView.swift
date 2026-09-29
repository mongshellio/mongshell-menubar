import SwiftUI

/// The status-bar content: Claude mark + two compact ring gauges (`◔15% ◕96%`)
/// for the 5-hour and 7-day windows. Hosted inside the NSStatusItem button via
/// NSHostingView. The mark pulses at ≥90% (per the design's alert behavior).
/// Reset times live in the popover, not the bar, to keep it short.
struct MenuBarIconView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var openClaw: OpenClawModel

    // `@State` 를 손으로 펼친 것. macOS 27 SDK 부터 `@State` 는 SwiftUIMacros
    // 플러그인이 전개하는 매크로인데, 그 플러그인은 Xcode 에만 있고 Command Line
    // Tools 에는 없다 (Decision #11-2). `State<Value>` 프로퍼티 래퍼 자체는 SDK 에
    // 그대로 남아 있어, 매크로가 만들었을 저장소와 접근자를 직접 적으면 의미가 같다.
    private var _pulsing = State(initialValue: false)
    private var pulsing: Bool {
        get { _pulsing.wrappedValue }
        nonmutating set { _pulsing.wrappedValue = newValue }
    }

    // 초기값이 있는 `private var` 저장 프로퍼티도 멤버와이즈 이니셜라이저에
    // 들어가 그 접근 수준을 private 으로 끌어내린다. 다른 파일(AppDelegate)이
    // 뷰를 만들 수 있게 이니셜라이저를 직접 적는다.
    init(model: UsageModel, prefs: Preferences, openClaw: OpenClawModel) {
        self.model = model
        self.prefs = prefs
        self.openClaw = openClaw
    }

    private var fiveHourUsed: Int { model.snapshot.fiveHourPercent }
    private var weeklyUsed: Int { model.snapshot.weeklyAllPercent }

    /// Pulse always keys off risk (consumed) of the riskier window,
    /// regardless of display mode.
    private var shouldPulse: Bool {
        prefs.pulseWhenCritical && max(fiveHourUsed, weeklyUsed) >= 90
    }

    /// openclaw traffic-light color for the unified indicator, or nil when it
    /// shouldn't show (`Preferences.showsOpenClaw` → app looks exactly like the
    /// plain build).
    private var openClawDotColor: Color? {
        prefs.showsOpenClaw ? openClaw.health.dotColor : nil
    }

    var body: some View {
        MenuBarContent(fiveHourUsed: fiveHourUsed, weeklyUsed: weeklyUsed,
                       showRemaining: prefs.showRemaining,
                       colorCoding: prefs.colorCoding,
                       showPercent: prefs.showPercent,
                       fiveHourReset: TimeText.clockShort(model.snapshot.fiveHourResetAt),
                       pulsing: pulsing,
                       openClawDotColor: openClawDotColor)
        .animation(shouldPulse
                   ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                   : .default,
                   value: pulsing)
        .onAppear { pulsing = shouldPulse }
        .onChange(of: shouldPulse) { _, now in pulsing = now }
    }
}

/// The bar's visual content, parameterized so the live menu bar and the
/// offscreen snapshot renderer share one layout.
struct MenuBarContent: View {
    let fiveHourUsed: Int
    let weeklyUsed: Int
    let showRemaining: Bool
    let colorCoding: Bool
    let showPercent: Bool
    /// 5-hour reset clock (e.g. "19:00") shown next to the 5h gauge — the 5h
    /// window's reset is easy to lose track of, so it earns the extra text.
    /// nil hides it.
    var fiveHourReset: String? = nil
    var pulsing: Bool = false
    /// Non-nil = append the unified openclaw indicator (paw + traffic-light dot)
    /// in this color. nil = hide it entirely.
    var openClawDotColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            ClaudeMarkView()
                .frame(width: 16, height: 16)
                .scaleEffect(pulsing ? 1.14 : 1.0)

            if showPercent {
                // Position conveys the window: left = 5h, right = 7d.
                // 5h shows its reset clock (easy to forget); 7d is gauge-only
                // (its weekly reset is easy to remember).
                fiveHourGauge
                ring(weeklyUsed)
            }

            if let openClawDotColor {
                openClawIndicator(color: openClawDotColor, separated: showPercent)
            }
        }
        .padding(.horizontal, 2)
        .fixedSize()
    }

    /// 5h: ring gauge + its reset clock.
    private var fiveHourGauge: some View {
        HStack(spacing: 4) {
            ring(fiveHourUsed)
            if let fiveHourReset {
                Text(fiveHourReset)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A tiny ring gauge for one window (no number). Fill follows the display
    /// mode (consumed vs remaining); color always tracks risk (consumed).
    private func ring(_ used: Int) -> some View {
        let display = showRemaining ? 100 - used : used
        let color = colorCoding ? Palette.statusColor(for: used, colorCoding: true) : Color.primary
        return MenuRing(percent: display, color: color)
            .frame(width: 13, height: 13)
    }

    /// openclaw "아이콘 + 신호등": a paw glyph followed by the health-colored dot,
    /// sitting to the right of the usage gauges in the same status item.
    private func openClawIndicator(color: Color, separated: Bool) -> some View {
        HStack(spacing: 4) {
            if separated {
                Text("·")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "pawprint.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
    }
}

/// A minimal ring gauge sized for the menu bar (top-start, clockwise fill).
private struct MenuRing: View {
    let percent: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.30), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: max(0, min(1, CGFloat(percent) / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
