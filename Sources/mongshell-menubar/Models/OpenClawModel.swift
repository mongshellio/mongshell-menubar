import Foundation
import SwiftUI
import UserNotifications

/// Owns the openclaw health as read from the server agent's status URL, and
/// drives its own polling loop (Decision #25). Read-only: restarts, auto-heal
/// and logs all live on the server now; the app only watches and announces.
///
/// Shared singleton so the AppKit status item and SwiftUI views agree. With no
/// status URL this parks in `.notConfigured` and never polls, so the app is
/// byte-for-byte the plain Claude meter.
@MainActor
final class OpenClawModel: ObservableObject {
    static let shared = OpenClawModel()

    /// Floor on the poll interval — the agent itself probes at ≥15s, so polling
    /// faster only re-reads the same file.
    static let minimumPollSeconds = 15

    @Published private(set) var health: OpenClawHealth = .notConfigured
    /// Everything known across polls; `lastSuccess` feeds the "서버 확인" time
    /// and the read-only auto-heal row.
    @Published private(set) var reading = OpenClawReading()

    /// "서버 확인 HH:mm", with its age appended once the reading is stale.
    var checkedClockText: String? {
        let stale: Bool
        if case .unreachable = health { stale = true } else { stale = false }
        return TimeText.checkedClock(reading.lastSuccess?.checkedAt, stale: stale)
    }

    private let client = OpenClawStatusClient()
    private var healWatch = OpenClawHealWatch()
    private var pollTask: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    func start() {
        restartPolling()
    }

    func refreshNow() {
        guard let url = Preferences.shared.openClawStatusURLValue else { return }
        Task { await refreshOnce(url) }
    }

    /// Validates, saves, and switches to a new status URL (empty = clear). A new
    /// URL may be a different server, so everything learned from the old one —
    /// last success, heal baseline — is dropped, then one read happens at once.
    func applyStatusURL(_ raw: String) throws(OpenClawURLError) {
        let url = try OpenClawStatusClient.validatedURL(raw)
        Preferences.shared.openClawStatusURL = url?.absoluteString ?? ""
        reading = OpenClawReading()
        healWatch = OpenClawHealWatch()
        restartPolling()
    }

    /// Snapshot hook: shows a given reading without any network, so reference
    /// images are deterministic and never carry a real server's state.
    func presentForSnapshot(_ reading: OpenClawReading, now: Date) {
        pollTask?.cancel()
        pollTask = nil
        self.reading = reading
        health = reading.health(now: now)
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard let url = Preferences.shared.openClawStatusURLValue else {
            health = .notConfigured
            return
        }
        health = reading.health(now: Date())
        requestNotificationAuth()
        pollTask = Task { [weak self] in await self?.pollLoop(url) }
    }

    private func pollLoop(_ url: URL) async {
        while !Task.isCancelled {
            await refreshOnce(url)
            let secs = max(Self.minimumPollSeconds, Preferences.shared.openClawPollSeconds)
            try? await Task.sleep(for: .seconds(secs))
        }
    }

    // MARK: Refresh

    /// The request itself is async URLSession work, off the main thread; only
    /// the result lands back here.
    private func refreshOnce(_ url: URL) async {
        let outcome: Result<OpenClawStatus, OpenClawStatusError>
        do {
            outcome = .success(try await client.fetch(url))
        } catch {
            outcome = .failure(error)
        }
        // The URL may have been changed or cleared while the request was in
        // flight — its answer is about a server we no longer watch.
        guard url == Preferences.shared.openClawStatusURLValue else { return }

        switch outcome {
        case .success(let status):
            reading.recordSuccess(status)
            if let heal = healWatch.observe(status.lastHeal) { notifyHeal(heal) }
        case .failure(let error):
            reading.recordFailure(error.detail)
        }
        health = reading.health(now: Date())
    }

    // MARK: Notifications

    /// UserNotifications requires a real app bundle; guard so an unbundled dev
    /// launch doesn't crash. (Same pattern as `UsageModel`.)
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationAuth() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyHeal(_ heal: OpenClawHealEvent) {
        // `Claude만` means no openclaw trace anywhere — notifications included.
        guard notificationsAvailable, Preferences.shared.showsOpenClaw else { return }
        let content = UNMutableNotificationContent()
        content.title = heal.ok ? "openclaw 자동 재시작됨 (서버)" : "openclaw 자동 재시작 실패 (서버)"
        let cause: String
        switch heal.reason {
        case "down":     cause = "게이트웨이 다운 감지"
        case "degraded": cause = "채널 이상 감지"
        default:         cause = "이상 감지"
        }
        content.body = heal.ok
            ? "\(cause) — 서버에서 하드 재시작했습니다."
            : "\(cause) — 서버에서 재시작을 시도했지만 실패했습니다."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "openclaw-heal", content: content, trigger: nil)
        )
    }
}
