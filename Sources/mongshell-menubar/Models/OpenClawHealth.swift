import SwiftUI

/// Health verdict for the remote openclaw gateway, as the menu bar shows it.
///
/// A gateway can answer HTTP 200 while its channel workers (Telegram, …) are
/// dead, so `.degraded` exists as a distinct state between fully OK and fully
/// DOWN. `.down` and `.unreachable` are deliberately different colors: red means
/// the *server* reported the gateway dead; grey means we can't hear the server
/// at all — which is usually this laptop being offline, and must not raise a
/// false alarm (Decision #25).
enum OpenClawHealth: Equatable, Sendable {
    /// No status URL set — hide everything, act like the plain app.
    case notConfigured
    /// URL set, but no response has come back yet.
    case unknown
    /// Gateway + channels healthy (🟢).
    case ok(detail: String)
    /// Gateway OK but one or more channels are stopped/errored (🟡).
    case degraded(detail: String)
    /// The server agent reported the gateway itself down (🔴).
    case down
    /// No fresh word from the server agent (⚪️) — network, funnel, or the agent
    /// itself. Says nothing about the gateway.
    case unreachable(detail: String)
}

extension OpenClawHealth {
    /// Menu-bar dot color. `.notConfigured` never renders, so its color is moot.
    var dotColor: Color {
        switch self {
        case .ok:                     return Palette.green
        case .degraded:               return Palette.amber
        case .down:                   return Palette.red
        case .unknown, .unreachable:  return Palette.textTertiary
        case .notConfigured:          return .clear
        }
    }

    /// Short status word for the popover header / settings row.
    var shortLabel: String {
        switch self {
        case .ok:            return "정상"
        case .degraded:      return "채널 이상"
        case .down:          return "게이트웨이 다운"
        case .unreachable:   return "서버 연락 두절"
        case .unknown:       return "확인 중…"
        case .notConfigured: return "미설정"
        }
    }

    /// The channel summary or the reason we lost the server, when there is one.
    var detailText: String? {
        switch self {
        case .ok(let d), .degraded(let d), .unreachable(let d):
            return d.isEmpty ? nil : d
        default:
            return nil
        }
    }

    /// One-line label for the Settings status row (status + detail).
    var settingsLabel: String {
        if let detail = detailText { return "\(shortLabel) — \(detail)" }
        return shortLabel
    }
}
