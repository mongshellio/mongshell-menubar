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

    /// 메뉴바에 무엇을 표시할지. 상태 URL 이 없으면 무엇을 골라도 openclaw 는 보이지 않는다.
    @AppStorage("menuBarTarget") var menuBarTargetRaw: String = MenuBarTarget.claudeOnly.rawValue
    var menuBarTarget: MenuBarTarget {
        get { MenuBarTarget(rawValue: menuBarTargetRaw) ?? .claudeOnly }
        set { menuBarTargetRaw = newValue.rawValue }
    }

    /// 서버 에이전트 상태 파일 URL 확인 간격(초). 사용량 폴링과 독립.
    @AppStorage("openClawPollSeconds") var openClawPollSeconds: Int = 60

    /// 서버 에이전트 상태 파일 URL (`https://<host>.ts.net:8443/<토큰>`). 빈 문자열 =
    /// 미설정. 읽기 전용 capability URL 이고 `--rotate-token` 으로 폐기할 수 있어
    /// Keychain 이 아니라 UserDefaults 에 둔다 (Decision #25). 쓰기는
    /// `OpenClawModel.applyStatusURL` 만 — 검증을 거치지 않은 값이 들어오지 않게.
    @AppStorage("openClawStatusURL") var openClawStatusURL: String = ""

    /// 저장된 상태 URL 을 검증한 값. 형식이 깨진 값은 미설정으로 본다.
    var openClawStatusURLValue: URL? {
        try? OpenClawStatusClient.validatedURL(openClawStatusURL)
    }

    /// openclaw 요소(메뉴바 신호등·팝오버 섹션)를 보일지의 단일 판정. 표시 조건을
    /// 뷰마다 다시 적으면 한 곳만 바뀌어 메뉴바와 팝오버가 어긋난다.
    var showsOpenClaw: Bool {
        menuBarTarget == .claudeAndOpenClaw && openClawStatusURLValue != nil
    }

    private init() {}
}

/// What the menu bar shows. openclaw는 상태 URL 이 설정돼 있을 때만 의미가 있다.
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
