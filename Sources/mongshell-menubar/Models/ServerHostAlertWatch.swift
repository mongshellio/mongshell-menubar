import Foundation

/// A server host signal to announce as having got worse, with the figures to
/// say so.
enum ServerHostAlert: Equatable, Sendable {
    case power(ServerHostPower)
    case disk(ServerHostDisk)
}

extension ServerHostAlert {
    /// Fixed per signal, so a newer alert replaces the older one in
    /// Notification Center instead of piling up next to it.
    var identifier: String {
        switch self {
        case .power: return "server-host-power"
        case .disk:  return "server-host-disk"
        }
    }

    var title: String {
        switch self {
        case .power(let power):
            guard power.isOnBattery else {
                return power.level == .critical ? "서버 전원 위험" : "서버 전원 주의"
            }
            return power.level == .critical ? "서버 배터리 부족" : "서버 전원 어댑터 분리됨"
        case .disk(let disk):
            return disk.level == .critical ? "서버 디스크 거의 가득" : "서버 디스크 여유 부족"
        }
    }

    var body: String {
        switch self {
        case .power(let power):
            // Off battery (or not known to be on it) there's no cause to
            // name — only the figures the server sent.
            guard power.isOnBattery else {
                return power.lineText ?? "서버의 전원 상태를 확인하세요."
            }
            let charge = power.batteryPercent.map { "배터리 \($0)%" }
            if power.level == .critical {
                let advice = "어댑터를 연결하지 않으면 곧 꺼집니다."
                return charge.map { "\($0) — \(advice)" } ?? advice
            }
            return charge.map { "\($0)로 동작 중입니다." } ?? "배터리로 동작 중입니다."
        case .disk(let disk):
            return "여유 \(ServerHostText.bytes(disk.availableBytes))"
        }
    }
}

/// Decides when a host signal getting worse is news worth a notification
/// (Decision #31).
///
/// The first observation after launch (or after the URL changes, or after the
/// notification gate opens) only sets the baseline — a server that has been on
/// battery for hours must not notify every time the app starts. After that a
/// signal alerts when its level rises: recovery is good news the dot already
/// shows, and a server gone quiet says nothing about its signals.
///
/// A level hovering around one of the agent's thresholds (it has no
/// hysteresis) rises again and again, so a rise to a level already announced
/// waits out the cooldown. It is put off, not dropped: the first observation
/// after the cooldown that still finds the signal above `ok` announces it, at
/// the level it has then. A signal that recovered in the meantime owes
/// nothing. A rise beyond the level announced is new and goes out at once.
/// Power and disk are tracked separately.
struct ServerHostAlertWatch: Equatable, Sendable {
    /// How long a signal stays quiet about a level it has already announced.
    static let repeatCooldown: TimeInterval = 3600

    private struct Announcement: Equatable, Sendable {
        let level: ServerHostLevel
        let at: Date
    }

    private struct Signal: Equatable, Sendable {
        var lastLevel: ServerHostLevel?
        var lastAnnouncement: Announcement?
        /// A rise the cooldown kept quiet, still to be announced.
        var owesAnnouncement = false

        /// Records `level` as the last one seen — on every call, rise or not
        /// — and returns whether it is to be announced now. A value out of a
        /// mutating function for the same reason as `observe`. A signal seen
        /// for the first time is compared against `ok`.
        mutating func record(_ level: ServerHostLevel, now: Date) -> Bool {
            let previous = lastLevel ?? .ok
            lastLevel = level
            guard level > .ok else {
                owesAnnouncement = false
                return false
            }
            let rose = level > previous
            guard rose || owesAnnouncement else { return false }
            if let last = lastAnnouncement, level <= last.level,
               Self.isCoolingDown(since: last.at, now: now) {
                owesAnnouncement = true
                return false
            }
            lastAnnouncement = Announcement(level: level, at: now)
            owesAnnouncement = false
            return true
        }

        /// A negative elapsed time means this mac's clock was set back. It
        /// counts as expired: waiting for the clock to catch up would stretch
        /// the cooldown by however far it went back.
        private static func isCoolingDown(since announcedAt: Date, now: Date) -> Bool {
            let elapsed = now.timeIntervalSince(announcedAt)
            return elapsed >= 0 && elapsed < ServerHostAlertWatch.repeatCooldown
        }
    }

    private var hasBaseline = false
    private var power = Signal()
    private var disk = Signal()

    /// Records the host as last read and returns the signals to announce.
    /// Returns a value so the caller decides whether to notify — the
    /// command/query exception in code-standards. `now` is this mac's clock:
    /// the cooldown never depends on the server's.
    ///
    /// `canNotify` is whether an alert returned now would reach the user.
    /// While it can't, nothing is watched and everything known is dropped,
    /// cooldowns included: an alert counted as sent without having been shown
    /// would keep the next rise quiet for an hour. The first observation
    /// after it can again is a baseline, as after launch.
    mutating func observe(_ host: ServerHost?, now: Date, canNotify: Bool) -> [ServerHostAlert] {
        guard canNotify else {
            self = ServerHostAlertWatch()
            return []
        }
        guard hasBaseline else {
            hasBaseline = true
            power.lastLevel = host?.power?.level
            disk.lastLevel = host?.disk?.level
            return []
        }
        // A signal the document doesn't carry is no news either way: the last
        // level known stays the one to compare against.
        var alerts: [ServerHostAlert] = []
        if let reported = host?.power, power.record(reported.level, now: now) {
            alerts.append(.power(reported))
        }
        if let reported = host?.disk, disk.record(reported.level, now: now) {
            alerts.append(.disk(reported))
        }
        return alerts
    }
}
