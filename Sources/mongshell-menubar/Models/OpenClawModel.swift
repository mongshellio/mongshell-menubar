import Foundation
import SwiftUI
import UserNotifications

/// Owns the openclaw health — and the server host's, from the same document
/// (Decision #31) — as read from the server agent's status URL, and drives its
/// own polling loop (Decision #25). Read-only: restarts, auto-heal and logs
/// all live on the server now; the app only watches and announces.
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
    /// The server host's own dot. `.absent` whenever there is nothing to show
    /// — no URL, or a server that sends no `host`.
    @Published private(set) var hostHealth: ServerHostHealth = .absent
    /// Everything known across polls; `lastSuccess` feeds the "서버 확인" time
    /// and the read-only auto-heal row.
    @Published private(set) var reading = OpenClawReading()

    /// The last check time ("오후 2:32"), with its age appended once the reading
    /// is stale.
    var checkedClockText: String? {
        let stale: Bool
        if case .unreachable = health { stale = true } else { stale = false }
        return TimeText.checkedClock(reading.lastCheckedAt, stale: stale)
    }

    private let client = OpenClawStatusClient()
    private var healWatch = OpenClawHealWatch()
    private var hostAlertWatch = ServerHostAlertWatch()
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
    /// last success, heal and host alert baselines — is dropped, then one read
    /// happens at once.
    /// Re-applying the saved URL (⏎ in an unchanged field) does nothing, so it
    /// can't wipe what we know or cancel a read in flight.
    func applyStatusURL(_ raw: String) throws(OpenClawURLError) {
        let normalized = try OpenClawStatusClient.validatedURL(raw)?.absoluteString ?? ""
        guard normalized != Preferences.shared.openClawStatusURL else { return }
        Preferences.shared.openClawStatusURL = normalized
        reading = OpenClawReading()
        healWatch = OpenClawHealWatch()
        hostAlertWatch = ServerHostAlertWatch()
        restartPolling()
    }

    /// Snapshot hook: shows a given reading without any network, so reference
    /// images are deterministic and never carry a real server's state.
    func presentForSnapshot(_ reading: OpenClawReading, now: Date) {
        pollTask?.cancel()
        pollTask = nil
        self.reading = reading
        health = reading.health(now: now)
        hostHealth = reading.hostHealth(now: now)
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard let url = Preferences.shared.openClawStatusURLValue else {
            health = .notConfigured
            hostHealth = .absent
            return
        }
        health = reading.health(now: Date())
        hostHealth = reading.hostHealth(now: Date())
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
        // A cancelled poll belongs to a loop that has been replaced, and the
        // URL may have been changed or cleared while the request was in flight
        // — either way its answer is not news about the server we watch now.
        guard !Task.isCancelled, url == Preferences.shared.openClawStatusURLValue else { return }

        let now = Date()
        switch outcome {
        case .success(let status):
            // The host alert watch is left alone when the server clock went
            // back: it compares levels, not server times, and its cooldown
            // runs on this mac's clock.
            if reading.recordSuccess(status, receivedAt: now) { healWatch.resetBaseline() }
            if let heal = healWatch.observe(status.lastHeal) { notifyHeal(heal) }
        case .failure(let error):
            reading.recordFailure(error)
        }
        health = reading.health(now: now)
        hostHealth = reading.hostHealth(now: now)
        // The watch sees what the reading kept — a late reply from an
        // overlapping poll is dropped there — and only while it is fresh: a
        // request can succeed on a document the agent stopped writing, and
        // its stale figures must not feed an alert (`reportedHost`). Only a
        // success reaches the watch, so a closed gate resets it exactly when
        // a document arrives while it can't be shown.
        if case .success = outcome {
            hostAlertWatch
                .observe(hostHealth.reportedHost, now: now, canNotify: canNotifyAboutServer)
                .forEach(notifyHostAlert)
        }
    }

    // MARK: Notifications

    /// UserNotifications requires a real app bundle; guard so an unbundled dev
    /// launch doesn't crash. (Same pattern as `UsageModel`.)
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationAuth() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The gate every server notification passes. `Claude만` means no
    /// openclaw trace anywhere — notifications included, and the host signals
    /// are part of what it hides.
    private var canNotifyAboutServer: Bool {
        notificationsAvailable && Preferences.shared.showsOpenClaw
    }

    private func notifyHeal(_ heal: OpenClawHealEvent) {
        guard canNotifyAboutServer else { return }
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

    private func notifyHostAlert(_ alert: ServerHostAlert) {
        // The watch hands out alerts only while the gate is open; checked
        // here as well because UserNotifications crashes without a bundle.
        guard canNotifyAboutServer else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil)
        )
    }
}
