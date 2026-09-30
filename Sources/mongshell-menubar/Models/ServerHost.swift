import SwiftUI

/// How bad a server host signal is, as the server agent judged it
/// (Decision #31). The app holds no thresholds — it only shows these.
/// Declaration order is severity order; the synthesized `Comparable` is what
/// "worse than" relies on.
enum ServerHostLevel: Comparable, Sendable {
    case ok
    case warning
    case critical
}

/// The server's internal battery and adapter. Every figure is optional: the
/// document is read leniently, and the agent's verdict (`level`) stands even
/// when a figure next to it can't be used.
struct ServerHostPower: Equatable, Sendable {
    let level: ServerHostLevel
    let pluggedIn: Bool?
    let charging: Bool?
    /// 0...100.
    let batteryPercent: Int?
}

/// Free space on the server's home volume.
struct ServerHostDisk: Equatable, Sendable {
    let level: ServerHostLevel
    let availableBytes: Int64
}

/// The `host` part of one status document. A signal the server didn't send
/// (`power` on a mac without a battery) is nil.
struct ServerHost: Equatable, Sendable {
    /// The agent's overall verdict — what the menu-bar dot shows.
    let level: ServerHostLevel
    let power: ServerHostPower?
    let disk: ServerHostDisk?
}

/// The server host as the menu bar shows it. Same split as `OpenClawHealth`:
/// a colored dot means the server said so, grey means we can't hear the server.
enum ServerHostHealth: Equatable, Sendable {
    /// The server sends no `host`, or nothing has been read yet — render nothing.
    case absent
    /// The verdict of a fresh document.
    case reported(ServerHost)
    /// A `host` was read once, but the document has gone stale since.
    case unreachable(last: ServerHost)
}

// MARK: - Display

extension ServerHostLevel {
    var color: Color {
        switch self {
        case .ok:       return Palette.green
        case .warning:  return Palette.amber
        case .critical: return Palette.red
        }
    }
}

extension ServerHostHealth {
    /// The host figures to show — for `.unreachable`, the last ones known.
    var host: ServerHost? {
        switch self {
        case .absent: return nil
        case .reported(let host), .unreachable(let host): return host
        }
    }

    /// The host of a fresh document only — what the alert watch is fed. A
    /// stale document's figures are for display, not for judging: requests
    /// keep succeeding after the agent stops (the funnel serves the last file),
    /// and an alert put off by the cooldown would otherwise go out on those
    /// old figures while the popover says the server is unreachable.
    var reportedHost: ServerHost? {
        if case .reported(let host) = self { return host }
        return nil
    }

    /// Menu-bar dot color; nil when there is nothing to render.
    var dotColor: Color? {
        switch self {
        case .absent:             return nil
        case .reported(let host): return host.level.color
        case .unreachable:        return Palette.textTertiary
        }
    }

    /// Short status word for the popover header. `.absent` never renders.
    var shortLabel: String {
        switch self {
        case .absent:             return ""
        case .reported(let host): return host.shortLabel
        case .unreachable:        return "서버 연락 두절"
        }
    }
}

extension ServerHost {
    /// Names the signal behind the overall level — the worse one, power on a
    /// tie. When no signal we know accounts for the level (the agent judged
    /// something this build doesn't read), only the level itself is named.
    var shortLabel: String {
        if let power, power.level == level, level != .ok {
            return power.shortLabel
        }
        if let disk, disk.level == level, level != .ok {
            return level == .critical ? "디스크 거의 가득" : "디스크 여유 부족"
        }
        switch level {
        case .ok:       return "정상"
        case .warning:  return "주의"
        case .critical: return "위험"
        }
    }
}

extension ServerHostPower {
    /// Known to run on battery. The words that name a cause ("어댑터 분리",
    /// "배터리 부족") are true of this case alone: a level can also be bad
    /// because the app couldn't read the agent's verdict, next to figures
    /// that say "충전 중".
    var isOnBattery: Bool { pluggedIn == false }

    /// Status word for a power level above `ok`: the cause when on battery,
    /// otherwise only the level.
    fileprivate var shortLabel: String {
        if isOnBattery { return level == .critical ? "배터리 부족" : "어댑터 분리" }
        return level == .critical ? "전원 위험" : "전원 주의"
    }

    /// "배터리 82% · 방전 중". A part the document didn't give is left out; nil
    /// when neither part is known.
    var lineText: String? {
        let charge = batteryPercent.map { "배터리 \($0)%" }
        guard let supplyText else { return charge }
        return "\(charge ?? "배터리") · \(supplyText)"
    }

    /// Where the power comes from. Without `pluggedIn` there's no telling, and
    /// `charging` alone isn't shown: it only qualifies a connected adapter.
    private var supplyText: String? {
        guard let pluggedIn else { return nil }
        guard pluggedIn else { return "방전 중" }
        return charging == true ? "충전 중" : "어댑터 연결"
    }
}

extension ServerHostDisk {
    /// "디스크 여유 32GB".
    var lineText: String { "디스크 여유 \(ServerHostText.bytes(availableBytes))" }
}

enum ServerHostText {
    /// Decimal, like Finder and the agent's thresholds — not GiB.
    private static let bytesPerMB: Int64 = 1_000_000
    private static let bytesPerGB: Int64 = 1_000_000_000
    /// From here up the fraction is noise.
    private static let wholeGBFrom: Int64 = 10 * bytesPerGB
    private static let tenthsPerGB: Int64 = 10

    /// "32GB" / "4.2GB" / "850MB". Always rounded down: free space shown
    /// larger than it is would hide how close the disk is to full.
    static func bytes(_ count: Int64) -> String {
        let count = max(0, count)
        if count >= wholeGBFrom { return "\(count / bytesPerGB)GB" }
        if count >= bytesPerGB {
            let tenths = count / (bytesPerGB / tenthsPerGB)
            return "\(tenths / tenthsPerGB).\(tenths % tenthsPerGB)GB"
        }
        return "\(count / bytesPerMB)MB"
    }
}
