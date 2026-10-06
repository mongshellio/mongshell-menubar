import Foundation

/// One weekly per-model usage row (e.g. "Fable 5" → 25%).
struct ModelUsage: Identifiable, Equatable {
    let name: String
    let percent: Int
    var id: String { name }
}

/// Normalized usage snapshot that drives every view. Populated from the
/// oauth/usage response, or from sample data when signed out.
///
/// Note: the usage endpoint carries no peak/off-peak-pricing info, so this
/// model deliberately omits it rather than fabricating an "Off-peak" label.
struct UsageSnapshot: Equatable {
    /// 5-hour rolling window usage, 0…100.
    var fiveHourPercent: Int
    /// Human text like "3시간 8분 후 초기화".
    var fiveHourResetText: String
    /// Raw reset instant of the 5-hour window — the menu bar formats this itself.
    var fiveHourResetAt: Date?

    /// Weekly all-models usage, 0…100.
    var weeklyAllPercent: Int
    /// e.g. "일요일 21:59 초기화".
    var weeklyResetText: String
    /// Raw reset instant of the weekly window.
    var weeklyResetAt: Date?
    /// Per-model weekly rows (Opus/Fable/…).
    var models: [ModelUsage]

    /// Usage-credits status when meaningful (e.g. "$4.20 남음" / "크레딧 소진"),
    /// else nil. Derived from the response `spend`/`extra_usage`.
    var creditsText: String?

    var lastUpdated: Date

    static let sample = UsageSnapshot(
        fiveHourPercent: 19,
        fiveHourResetText: "3시간 8분 후 초기화",
        fiveHourResetAt: Date().addingTimeInterval(3 * 3600 + 8 * 60),
        weeklyAllPercent: 19,
        weeklyResetText: "일요일 21:59 초기화",
        weeklyResetAt: Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 21, minute: 59, weekday: 1),
            matchingPolicy: .nextTime),
        models: [ModelUsage(name: "Fable 5", percent: 25)],
        creditsText: nil,
        lastUpdated: .distantPast
    )
}

/// Where the current data came from — drives the popover's status/footer.
enum DataSource: Equatable {
    case sample                 // signed out; showing placeholder numbers
    case claudeCodeCLI          // token borrowed from ~/.claude / Keychain
    case oauthLogin             // signed in via the app's own OAuth
}

/// Auth/connection state for the popover.
enum LoadState: Equatable {
    case signedOut
    /// Was signed in with the app's own OAuth, but the server stopped honouring
    /// the refresh token (`invalid_grant`). Distinct from `signedOut` — "never
    /// signed in" and "the login lapsed" ask for different wording.
    case sessionExpired
    case loading
    case loaded(DataSource)
    case rateLimited(retryAfter: TimeInterval?)
    case error(String)
}
