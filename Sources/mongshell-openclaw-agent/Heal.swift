import Foundation

/// Decides *when* to hard-restart the gateway — the same rules as the app's
/// `OpenClawModel.maybeAutoHeal`: heal on the 2nd consecutive failure, at most
/// once per cooldown. Pure state; the clock is passed in so tests don't sleep.
struct HealTracker {
    /// One failed probe can be a blip between longpolls; two in a row is not.
    static let failuresBeforeHeal = 2
    /// A kickstart that didn't help won't help 60s later either — and a
    /// restart loop would hide the real problem behind constant churn.
    static let cooldown: TimeInterval = 600

    private(set) var consecutiveFailures = 0
    private(set) var lastHealAt: Date?

    init(lastHealAt: Date? = nil) {
        self.lastHealAt = lastHealAt
    }

    /// Counts a probe result. `.notInstalled` resets like `.ok` — restarting
    /// the gateway can't install a missing binary.
    mutating func record(_ verdict: ProbeVerdict) {
        switch verdict {
        case .down, .degraded: consecutiveFailures += 1
        case .ok, .notInstalled: consecutiveFailures = 0
        }
    }

    func isHealDue(now: Date) -> Bool {
        guard consecutiveFailures >= Self.failuresBeforeHeal else { return false }
        if let last = lastHealAt, now.timeIntervalSince(last) < Self.cooldown { return false }
        return true
    }

    mutating func markHealed(at now: Date) {
        lastHealAt = now
        consecutiveFailures = 0
    }
}

/// launchd side of healing: finding the gateway's label and kickstarting it.
enum Launchd {
    static let launchctlPath = "/bin/launchctl"
    static let kickstartTimeout: TimeInterval = 10
    /// The label openclaw's installer documents; used when nothing is found.
    static let defaultGatewayLabel = "ai.openclaw.gateway"

    static var userLaunchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    /// The gateway's launchd label. An explicit label wins. Otherwise: basename
    /// of the first (sorted) `*.plist` in `dir` whose name contains `claw`,
    /// **excluding `selfLabel`** — this agent's own plist name also contains
    /// "claw"; whenever it sorts first (e.g. the gateway's plist is missing or
    /// renamed) the agent would otherwise kickstart itself.
    static func gatewayLabel(explicit: String?, selfLabel: String, in dir: URL) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let match = files.sorted().lazy
            .filter { $0.hasSuffix(".plist") && $0.lowercased().contains("claw") }
            .map { String($0.dropLast(".plist".count)) }
            .first { $0 != selfLabel }
        return match ?? defaultGatewayLabel
    }

    /// OS-level hard restart — the only thing that fixes openclaw's
    /// cancel-proof longpoll hang. Returns whether launchctl reported success.
    static func kickstart(label: String) -> Bool {
        let target = "gui/\(getuid())/\(label)"
        let result = Probe.run(launchctlPath, ["kickstart", "-k", target], timeout: kickstartTimeout)
        return !result.timedOut && result.exitCode == 0
    }
}
