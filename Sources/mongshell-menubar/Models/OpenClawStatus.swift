import Foundation

/// One successfully read status document from the server agent
/// (`mongshell-openclaw-agent`, schema 1): the openclaw verdict and, since
/// Decision #31, the server host's own signals. Only what the client uses is
/// kept; anything the agent adds later is ignored by the parser.
struct OpenClawStatus: Equatable, Sendable {
    /// When the agent last probed, on the *server's* clock — see
    /// `OpenClawReading.lastCheckedAt` for the value freshness is judged on.
    let checkedAt: Date
    /// The server's verdict — only `.ok` / `.degraded` / `.down` come from here.
    let health: OpenClawHealth
    /// The agent's probe interval; drives the staleness threshold. nil = absent.
    let intervalSeconds: Int?
    /// Whether the agent auto-heals. nil = absent (shown as unknown).
    let autoHeal: Bool?
    let lastHeal: OpenClawHealEvent?
    /// The server host's power and disk verdicts. nil = the agent sent none
    /// (an older agent, or no signal could be read).
    let host: ServerHost?
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
/// Both dots — openclaw and the server host — come out of the same document,
/// so they share that rule.
///
/// Freshness is judged solely on the last success's `checkedAt` (Decision #25).
/// A single failed request therefore doesn't flip a dot — as long as the last
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
    /// `lastSuccess.checkedAt` on our clock: never later than when we first
    /// received that `checkedAt`. A server clock running ahead would otherwise
    /// make a dead agent's last write look fresh until real time caught up
    /// with it; pinning to the first receipt starts the stale countdown from
    /// the last time the value actually changed. A server clock running
    /// *behind* by S is not correctable from here — the countdown then ends
    /// S early.
    private(set) var lastCheckedAt: Date?
    /// Why the most recent request failed; cleared by the next success.
    private(set) var lastFailure: String?

    /// Keeps `status` as the latest answer — unless it's older than the one we
    /// have: polls can overlap (a manual refresh during a slow poll), and a
    /// late reply must not roll the state back.
    ///
    /// A step back wider than the staleness threshold is not a late reply —
    /// one of those trails by a request timeout at most — but the server clock
    /// having been set back. Ignoring it would drop every answer until the
    /// clock caught up again, so it's taken as the new baseline instead.
    /// Returns whether that happened, so the caller can re-baseline whatever
    /// else it compares on the server's clock (the command/query exception
    /// in code-standards).
    @discardableResult
    mutating func recordSuccess(_ status: OpenClawStatus, receivedAt: Date) -> Bool {
        var clockWentBack = false
        if let last = lastSuccess, status.checkedAt < last.checkedAt {
            let stepBack = last.checkedAt.timeIntervalSince(status.checkedAt)
            guard stepBack > Self.staleAfter(intervalSeconds: status.intervalSeconds) else { return false }
            clockWentBack = true
        }
        if status.checkedAt != lastSuccess?.checkedAt {
            lastCheckedAt = min(status.checkedAt, receivedAt)
        }
        lastSuccess = status
        lastFailure = nil
        return clockWentBack
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

    /// The last success, for as long as it's still fresh.
    private func freshSuccess(now: Date) -> OpenClawStatus? {
        guard let success = lastSuccess, let checkedAt = lastCheckedAt else { return nil }
        let age = now.timeIntervalSince(checkedAt)
        return age <= Self.staleAfter(intervalSeconds: success.intervalSeconds) ? success : nil
    }

    func health(now: Date) -> OpenClawHealth {
        if let fresh = freshSuccess(now: now) { return fresh.health }
        if lastSuccess != nil {
            // Requests may still succeed while the agent has stopped writing —
            // then there's no failure reason, but the answer is still stale.
            return .unreachable(detail: lastFailure ?? "서버 에이전트가 갱신을 멈췄습니다")
        }
        if let lastFailure { return .unreachable(detail: lastFailure) }
        return .unknown
    }

    /// The host dot, judged on the same freshness as `health(now:)` but
    /// otherwise independent of it: a down gateway on a healthy server is red
    /// above green. A stale document keeps the last figures for display —
    /// unless it never carried a `host`, in which case there's nothing to grey.
    func hostHealth(now: Date) -> ServerHostHealth {
        if let fresh = freshSuccess(now: now) {
            return fresh.host.map { .reported($0) } ?? .absent
        }
        return lastSuccess?.host.map { .unreachable(last: $0) } ?? .absent
    }
}

/// Decides when the server's `lastHeal` is news worth a notification.
///
/// The first response after launch (or after the URL changes) only sets the
/// baseline — a heal from hours ago must not notify every time the app starts.
/// After that, a `lastHeal.at` later than any seen so far is a new heal — an
/// older one is a late reply from an overlapping poll, already announced.
struct OpenClawHealWatch: Equatable, Sendable {
    private var hasBaseline = false
    private var lastSeenAt: Date?

    /// Records `heal` and returns it when it's later than every heal seen so
    /// far (nil otherwise). Returns a value so the caller decides
    /// whether to notify — the command/query exception in code-standards.
    mutating func observe(_ heal: OpenClawHealEvent?) -> OpenClawHealEvent? {
        let hadBaseline = hasBaseline
        hasBaseline = true
        guard let heal, heal.at > (lastSeenAt ?? .distantPast) else { return nil }
        lastSeenAt = heal.at
        return hadBaseline ? heal : nil
    }

    /// Forgets what was seen, so the next `observe` only sets a baseline —
    /// for when the server clock went back and `lastHeal.at` values on either
    /// side of the jump can no longer be ordered. A heal that happened across
    /// the jump then goes unannounced: missing one notification is safer than
    /// announcing an old heal as new.
    mutating func resetBaseline() {
        self = OpenClawHealWatch()
    }
}
