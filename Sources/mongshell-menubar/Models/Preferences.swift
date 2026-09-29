import SwiftUI
import Combine

/// User settings, persisted in UserDefaults. Shared singleton so both the
/// AppKit status-item host and SwiftUI views observe the same instance.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @AppStorage("colorCoding") var colorCoding: Bool = true
    @AppStorage("showPercent") var showPercent: Bool = true
    /// false = show consumed amount (기본), true = show remaining amount.
    /// Only flips the displayed number + gauge fill; color still tracks risk.
    @AppStorage("showRemaining") var showRemaining: Bool = false
    /// Polling interval in seconds. 180 (the endpoint's safe floor) is the
    /// default — usage %s change slowly, so this is the freshest safe cadence.
    /// The option exists mainly as a 429 escape valve / battery saver.
    @AppStorage("pollIntervalSeconds") var pollIntervalSeconds: Int = 180
    @AppStorage("notifyThresholds") var notifyThresholds: Bool = true
    @AppStorage("pulseWhenCritical") var pulseWhenCritical: Bool = true

    // MARK: openclaw

    /// 메뉴바에 무엇을 표시할지. openclaw 미설치 맥에서는 항상 claudeOnly로 강제된다.
    @AppStorage("menuBarTarget") var menuBarTargetRaw: String = MenuBarTarget.claudeOnly.rawValue
    var menuBarTarget: MenuBarTarget {
        get { MenuBarTarget(rawValue: menuBarTargetRaw) ?? .claudeOnly }
        set { menuBarTargetRaw = newValue.rawValue }
    }

    /// openclaw 프로브 폴링 간격(초). 사용량 폴링과 독립.
    @AppStorage("openClawPollSeconds") var openClawPollSeconds: Int = 60

    /// 🟡/🔴 감지 시 자동으로 launchctl 하드 재시작 수행 여부. 기본 꺼짐.
    @AppStorage("openClawAutoHeal") var openClawAutoHeal: Bool = false

    /// openclaw 요소(메뉴바 신호등·팝오버 섹션)를 보일지의 단일 판정. 표시 조건을
    /// 뷰마다 다시 적으면 한 곳만 바뀌어 메뉴바와 팝오버가 어긋난다.
    var showsOpenClaw: Bool {
        menuBarTarget == .claudeAndOpenClaw && OpenClawService.isInstalled
    }

    private init() {}
}

/// What the menu bar shows. openclaw는 설치돼 있을 때만 선택 가능.
enum MenuBarTarget: String, CaseIterable {
    case claudeOnly            // "Claude만"
    case claudeAndOpenClaw     // "Claude + openclaw"

    var displayName: String {
        switch self {
        case .claudeOnly:       return "Claude만"
        case .claudeAndOpenClaw: return "Claude + openclaw"
        }
    }
}
