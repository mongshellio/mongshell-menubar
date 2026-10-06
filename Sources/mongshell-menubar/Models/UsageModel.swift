import Foundation
import SwiftUI
import UserNotifications

/// Owns the usage snapshot + connection state and drives polling.
/// Shared singleton so the AppKit status item and SwiftUI views agree.
@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    @Published private(set) var snapshot: UsageSnapshot = .sample
    @Published private(set) var loadState: LoadState = .signedOut

    private let api = UsageAPIClient()
    private let auth = AuthService()
    private var pollTask: Task<Void, Never>?
    private var backoff: Int = 0
    private var lastNotifiedLevel = 0
    /// The refresh token is single-use and rotates on every refresh, so two
    /// overlapping `refreshOnce` runs (poll loop + the popover's "새로고침")
    /// can each spend it and sign the user out. `@MainActor` makes this plain
    /// flag a sufficient guard within this process only; a race with another
    /// instance (a stale dev build left running after `make_app.sh`) is
    /// stopped by `ownTokenStillCurrent` instead.
    private var refreshInFlight = false
    /// A refresh asked for while one was running. Dropping it would leave
    /// stale state on screen until the next poll — e.g. the expired-session
    /// banner after `signIn()` succeeded mid-poll — so the running refresh
    /// goes round once more instead.
    private var refreshRequested = false
    /// The "login lapsed" notice is showing and the user has not acted on it.
    /// Kept apart from `loadState`, which tracks the current connection:
    /// folding the two into one enum was why a single 429 or transport error
    /// could overwrite the notice and let the next CLI 401 downgrade it to a
    /// plain `signedOut`.
    private var sessionExpiredUnresolved = false

    // MARK: Lifecycle

    func start() {
        if Preferences.shared.notifyThresholds { requestNotificationAuth() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func refreshNow() {
        Task { await refreshOnce() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            let base = max(Config.minPollInterval, Preferences.shared.pollIntervalSeconds)
            let wait = backoff > 0 ? min(base * (1 << backoff), 3600) : base
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    // MARK: Token resolution

    private func currentToken() -> (OAuthToken, DataSource)? {
        if let own = CredentialStore.loadOwnToken() { return (own, .oauthLogin) }
        if let cli = CredentialStore.loadClaudeCodeToken() { return (cli, .claudeCodeCLI) }
        return nil
    }

    // MARK: Refresh

    /// Satisfies one refresh request. Requests that arrive while a refresh is
    /// in flight are coalesced into a single follow-up run, however many
    /// there were.
    private func refreshOnce() async {
        guard !refreshInFlight else { refreshRequested = true; return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested
    }

    private func performRefresh() async {
        guard let (initialToken, source) = currentToken() else {
            markSignedOut()
            snapshot = .sample
            return
        }
        var token = initialToken
        if case .signedOut = loadState { loadState = .loading }

        // Refresh our own expired token up front.
        if source == .oauthLogin, token.isExpired {
            switch await renewOwnToken(token) {
            case .renewed(let renewed):
                guard ownTokenStillCurrent(token) else { return }
                CredentialStore.saveOwnToken(renewed)
                token = renewed
            case .sessionExpired:
                expireSession(token)
                return
            case .transientFailure:
                break
            }
        }

        do {
            let snap = try await api.fetch(token: token)
            markLoaded(snap, source: source)
            maybeNotify(percent: snap.fiveHourPercent)
        } catch APIError.unauthorized {
            AuthDebugLog.write("usage 401 source=\(source)")
            // Own token: try one refresh. CLI token: re-read (Claude Code may have rotated it).
            if source == .oauthLogin {
                switch await renewOwnToken(token) {
                case .renewed(let renewed):
                    guard ownTokenStillCurrent(token) else { return }
                    CredentialStore.saveOwnToken(renewed)
                    if let snap = try? await api.fetch(token: renewed) {
                        markLoaded(snap, source: source)
                        return
                    }
                case .sessionExpired:
                    expireSession(token)
                    return
                case .transientFailure:
                    break
                }
            }
            markSignedOut()
        } catch APIError.rateLimited(let retry) {
            backoff = min(backoff + 1, 4)
            loadState = .rateLimited(retryAfter: retry)
        } catch {
            loadState = .error("사용량을 불러오지 못했습니다")
        }
    }

    /// A successful fetch is the one thing that resolves a lapsed login on
    /// its own: it proves whichever token we hold now works.
    private func markLoaded(_ snap: UsageSnapshot, source: DataSource) {
        snapshot = snap
        loadState = .loaded(source)
        backoff = 0
        sessionExpiredUnresolved = false
    }

    private enum OwnTokenRenewal {
        case renewed(OAuthToken)
        /// The server rejected the refresh token for good — keeping it only
        /// buys a 400 every poll and blocks the CLI-token fallback.
        case sessionExpired
        /// Network or server trouble; the token may still be fine, so keep it.
        case transientFailure
    }

    private func renewOwnToken(_ token: OAuthToken) async -> OwnTokenRenewal {
        do {
            return .renewed(try await auth.refresh(token))
        } catch AuthError.invalidGrant {
            return .sessionExpired
        } catch {
            return .transientFailure
        }
    }

    /// Drops the dead own token so the next poll falls through to the CLI
    /// token (or to signed-out), and tells the user once. No repeat guard is
    /// needed: with the token gone, nothing can reach this path again until
    /// the user signs in anew.
    private func expireSession(_ token: OAuthToken) {
        guard ownTokenStillCurrent(token) else { return }
        AuthDebugLog.write("own token discarded (invalid_grant) \(AuthDebugLog.session(token))")
        CredentialStore.clearOwnToken()
        snapshot = .sample
        sessionExpiredUnresolved = true
        loadState = .sessionExpired
        notifySessionExpired()
    }

    /// Guards every write to the own token. The poll may be renewing or
    /// discarding a token that `signIn()` — or another instance of this app —
    /// has replaced in the meantime; acting on the stale one would overwrite
    /// or delete the fresh login. When the Keychain has moved on the caller
    /// leaves it alone and the next poll re-reads it.
    private func ownTokenStillCurrent(_ token: OAuthToken) -> Bool {
        if CredentialStore.loadOwnToken()?.refreshToken == token.refreshToken { return true }
        AuthDebugLog.write("own token changed elsewhere; kept")
        return false
    }

    /// `sessionExpired` outranks `signedOut`: the banner that explains why the
    /// numbers went back to sample must survive the polls that follow (no
    /// token at all, or a CLI token that 401s) until the user acts. Only
    /// restores the state — the notification was sent once in `expireSession`.
    private func markSignedOut() {
        loadState = sessionExpiredUnresolved ? .sessionExpired : .signedOut
    }

    // MARK: Sign in / out

    func signIn() async {
        do {
            let token = try await auth.signIn()
            CredentialStore.saveOwnToken(token)
            sessionExpiredUnresolved = false
            await refreshOnce()
        } catch {
            loadState = .error((error as? LocalizedError)?.errorDescription ?? "로그인 실패")
        }
    }

    func signOut() {
        CredentialStore.clearOwnToken()
        sessionExpiredUnresolved = false
        loadState = .signedOut
        snapshot = .sample
    }

    // MARK: Notifications

    /// UserNotifications requires a real app bundle; guard so an unbundled
    /// `swift run` dev launch doesn't crash.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationAuth() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Not tied to `notifyThresholds`: that toggle is about usage levels, and
    /// this is a rare, action-required event of a different kind. Asks for
    /// permission on the spot in case the threshold prompt never ran.
    private func notifySessionExpired() {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude 로그인이 만료되었습니다"
        content.body = "메뉴바 아이콘을 눌러 다시 로그인하세요."
        let request = UNNotificationRequest(identifier: "mongshell-menubar-session-expired",
                                            content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    private func maybeNotify(percent: Int) {
        guard Preferences.shared.notifyThresholds, notificationsAvailable else { return }
        let thresholds = [90, 75, 50, 25]
        let level = thresholds.first(where: { percent >= $0 }) ?? 0
        guard level > lastNotifiedLevel else {
            if percent < 25 { lastNotifiedLevel = 0 } // reset after window resets
            return
        }
        lastNotifiedLevel = level
        let content = UNMutableNotificationContent()
        content.title = "Claude 사용량 \(level)% 도달"
        content.body = level >= 90 ? "곧 한도에 도달합니다." : "사용량이 \(percent)%입니다."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "mongshell-menubar-\(level)", content: content, trigger: nil)
        )
    }
}
