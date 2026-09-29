import Foundation

/// One successfully read status document from the server agent
/// (`mongshell-openclaw-agent`, schema 1). Only what the client uses is kept;
/// anything the agent adds later is ignored by the parser.
struct OpenClawStatus: Equatable, Sendable {
    /// When the agent last probed, already clamped to the time we received it
    /// (see `OpenClawStatusClient.parse`) so a server clock running ahead can't
    /// keep a dead agent looking fresh.
    let checkedAt: Date
    /// The server's verdict — only `.ok` / `.degraded` / `.down` come from here.
    let health: OpenClawHealth
    /// The agent's probe interval; drives the staleness threshold. nil = absent.
    let intervalSeconds: Int?
    /// Whether the agent auto-heals. nil = absent (shown as unknown).
    let autoHeal: Bool?
    let lastHeal: OpenClawHealEvent?
}

/// The agent's most recent hard-restart attempt.
struct OpenClawHealEvent: Equatable, Sendable {
    let at: Date
    let ok: Bool
    /// The verdict that triggered it (`down` / `degraded`), when present.
    let reason: String?
}

/// What the client knows about the server across polls, and the one rule that
/// turns that into a health: *is the last successful response still fresh?*
///
/// Freshness is judged solely on the last success's `checkedAt` (Decision #25).
/// A single failed request therefore doesn't flip the dot — as long as the last
/// good answer is recent, it stands. Kept a pure value type so the rule is
/// testable without the model's polling and notifications.
struct OpenClawReading: Equatable, Sendable {
    /// Floor on the staleness threshold — below 3 missed polls of the default
    /// 60s interval we'd flag a merely slow network.
    static let minimumStaleAfter: TimeInterval = 180
    /// Missed agent intervals tolerated before we call the server unreachable.
    static let staleIntervalMultiple = 3.0
    /// Assumed when the document omits `intervalSeconds` (the agent's default).
    static let fallbackIntervalSeconds = 60

    private(set) var lastSuccess: OpenClawStatus?
    /// Why the most recent request failed; cleared by the next success.
    private(set) var lastFailure: String?

    mutating func recordSuccess(_ status: OpenClawStatus) {
        lastSuccess = status
        lastFailure = nil
    }

    /// Remembers why the latest request failed. A cancellation is ignored: we
    /// dropped that request ourselves, so it says nothing about the server.
    mutating func recordFailure(_ error: OpenClawStatusError) {
        guard error != .cancelled else { return }
        lastFailure = error.detail
    }

    /// `max(180s, 3 × interval)`.
    static func staleAfter(intervalSeconds: Int?) -> TimeInterval {
        let interval = intervalSeconds.flatMap { $0 > 0 ? $0 : nil } ?? fallbackIntervalSeconds
        return max(minimumStaleAfter, staleIntervalMultiple * Double(interval))
    }

    func health(now: Date) -> OpenClawHealth {
        if let success = lastSuccess {
            // A checkedAt in the future (clock skew) counts as age 0.
            let age = max(0, now.timeIntervalSince(success.checkedAt))
            if age <= Self.staleAfter(intervalSeconds: success.intervalSeconds) {
                return success.health
            }
            // Requests may still succeed while the agent has stopped writing —
            // then there's no failure reason, but the answer is still stale.
            return .unreachable(detail: lastFailure ?? "서버 에이전트가 갱신을 멈췄습니다")
        }
        if let lastFailure { return .unreachable(detail: lastFailure) }
        return .unknown
    }
}

/// Decides when the server's `lastHeal` is news worth a notification.
///
/// The first response after launch (or after the URL changes) only sets the
/// baseline — a heal from hours ago must not notify every time the app starts.
/// After that, a `lastHeal.at` different from the last one seen is a new heal.
struct OpenClawHealWatch: Equatable, Sendable {
    private var hasBaseline = false
    private var lastSeenAt: Date?

    /// Records `heal` and returns it when it's a new event since the previous
    /// observation (nil otherwise). Returns a value so the caller decides
    /// whether to notify — the command/query exception in code-standards.
    mutating func observe(_ heal: OpenClawHealEvent?) -> OpenClawHealEvent? {
        defer {
            hasBaseline = true
            if let heal { lastSeenAt = heal.at }
        }
        guard hasBaseline, let heal, heal.at != lastSeenAt else { return nil }
        return heal
    }
}
