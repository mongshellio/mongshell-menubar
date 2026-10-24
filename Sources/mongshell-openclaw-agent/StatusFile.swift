import Foundation

/// One hard-restart attempt, as recorded in the status file.
struct HealRecord: Codable, Equatable {
    let at: Date
    let ok: Bool
    /// The health that triggered it (`down` / `degraded`).
    let reason: String
}

/// The JSON document `tailscale funnel` serves to the menubar clients.
/// Deliberately small: no PID, no raw probe output — this is public over HTTPS
/// (behind only an unguessable path), so it carries the verdicts and the
/// figures they were judged from (battery percent, free bytes), the agent's
/// own build version (Decision #81), and nothing that identifies the machine:
/// no host name, no path, no openclaw or OS version.
struct AgentStatus: Encodable {
    /// Stays 1 when keys are added (`host`, Decision #31; `host.runners`,
    /// #75; `agentVersion`, #81) — clients ignore keys they don't know.
    static let schemaVersion = 1

    /// Longest build version published.
    static let maxVersionLength = 32

    /// `raw` when it looks like what `install.sh` derives from git
    /// (`v1.2.0`, `v1.2.0+3`), else nil. It comes from the command line and
    /// the document is public, so only `[0-9A-Za-z.+-]` goes out.
    static func publishableVersion(_ raw: String?) -> String? {
        guard let raw, (1...maxVersionLength).contains(raw.count) else { return nil }
        let allowed = raw.unicodeScalars.allSatisfy { s in
            switch s.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true // ASCII alnum
            case 0x2B, 0x2D, 0x2E: return true // + - .
            default: return false
            }
        }
        return allowed ? raw : nil
    }

    let checkedAt: Date
    let verdict: ProbeVerdict
    let intervalSeconds: Int
    let autoHeal: Bool
    let lastHeal: HealRecord?
    /// nil when no host signal could be read.
    let host: HostStatus?
    /// The build `install.sh` stamped (already through `publishableVersion`);
    /// nil when it couldn't tell, or for a binary run by hand.
    var agentVersion: String? = nil

    private enum CodingKeys: String, CodingKey {
        case schema, checkedAt, health, detail, intervalSeconds, autoHeal, lastHeal, host,
             agentVersion
    }

    /// Hand-written so `detail` / `lastHeal` / `host` / `agentVersion` are emitted as explicit
    /// `null` instead of being dropped — clients see a stable key set.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schema)
        try c.encode(checkedAt, forKey: .checkedAt)
        try c.encode(verdict.healthName, forKey: .health)
        try c.encode(verdict.detailText, forKey: .detail)
        try c.encode(intervalSeconds, forKey: .intervalSeconds)
        try c.encode(autoHeal, forKey: .autoHeal)
        try c.encode(lastHeal, forKey: .lastHeal)
        try c.encode(host, forKey: .host)
        try c.encode(agentVersion, forKey: .agentVersion)
    }
}

extension ProbeVerdict {
    /// Wire value of `health`. A missing binary and a timed-out probe are
    /// reported as `down`: from a client's point of view the gateway isn't
    /// answering, whatever the reason — `detail` says which.
    var healthName: String {
        switch self {
        case .ok: return "ok"
        case .degraded: return "degraded"
        case .down, .timedOut, .notInstalled: return "down"
        }
    }

    var detailText: String? {
        switch self {
        case .ok(let d), .degraded(let d): return d
        case .down: return nil
        case .timedOut: return "응답 지연 · \(Int(Probe.probeTimeout))초 초과"
        case .notInstalled: return "openclaw 바이너리 없음"
        }
    }
}

extension HostLevel {
    /// Wire value of every `health` under `host` — the only strings there.
    var healthName: String {
        switch self {
        case .ok: return "ok"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

/// Hand-written for the same reason as `AgentStatus`: a signal that couldn't
/// be read (`power` on a mac without a battery) goes out as explicit `null`.
extension HostStatus: Encodable {
    private enum CodingKeys: String, CodingKey {
        case health, power, disk, runners
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level.healthName, forKey: .health)
        try c.encode(power, forKey: .power)
        try c.encode(disk, forKey: .disk)
        try c.encode(runners, forKey: .runners)
    }
}

extension HostStatus.Power: Encodable {
    private enum CodingKeys: String, CodingKey {
        case health, pluggedIn, charging, batteryPercent
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level.healthName, forKey: .health)
        try c.encode(reading.pluggedIn, forKey: .pluggedIn)
        try c.encode(reading.charging, forKey: .charging)
        try c.encode(reading.batteryPercent, forKey: .batteryPercent)
    }
}

extension HostStatus.Disk: Encodable {
    private enum CodingKeys: String, CodingKey {
        case health, availableBytes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level.healthName, forKey: .health)
        try c.encode(reading.availableBytes, forKey: .availableBytes)
    }
}

/// Counts only: runner labels, the user they run as and their paths stay on
/// the server (Admission Criteria 5).
extension HostStatus.Runners: Encodable {
    private enum CodingKeys: String, CodingKey {
        case health, running, total
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level.healthName, forKey: .health)
        try c.encode(reading.running, forKey: .running)
        try c.encode(reading.total, forKey: .total)
    }
}

enum StatusFile {
    /// World-readable: tailscaled (root) serves it and nothing secret is inside.
    /// Pinned explicitly so a restrictive umask can't change what gets served.
    static let permissions: Int16 = 0o644

    static func encode(_ status: AgentStatus) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601 // UTC, e.g. 2026-09-29T03:12:45Z
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(status)
    }

    /// Atomic replace (temp file + rename) so funnel never serves a half-written
    /// document, then pins the mode — the temp file's mode follows the umask.
    static func write(_ status: AgentStatus, to url: URL) throws {
        try encode(status).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    /// `lastHeal` from a previous run's file, so a restart doesn't forget the
    /// cooldown. Lenient: any read/parse problem (first run, old schema, junk)
    /// just means "no history".
    static func readLastHeal(from url: URL) -> HealRecord? {
        struct Partial: Decodable { let lastHeal: HealRecord? }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Partial.self, from: data))?.lastHeal
    }
}
