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
/// (behind only an unguessable path), so it carries the verdict and nothing more.
struct AgentStatus: Encodable {
    static let schemaVersion = 1

    let checkedAt: Date
    let verdict: ProbeVerdict
    let intervalSeconds: Int
    let autoHeal: Bool
    let lastHeal: HealRecord?

    private enum CodingKeys: String, CodingKey {
        case schema, checkedAt, health, detail, intervalSeconds, autoHeal, lastHeal
    }

    /// Hand-written so `detail` / `lastHeal` are emitted as explicit `null`
    /// instead of being dropped — clients see a stable key set.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schema)
        try c.encode(checkedAt, forKey: .checkedAt)
        try c.encode(verdict.healthName, forKey: .health)
        try c.encode(verdict.detailText, forKey: .detail)
        try c.encode(intervalSeconds, forKey: .intervalSeconds)
        try c.encode(autoHeal, forKey: .autoHeal)
        try c.encode(lastHeal, forKey: .lastHeal)
    }
}

extension ProbeVerdict {
    /// Wire value of `health`. A missing binary is reported as `down`: from a
    /// client's point of view the gateway isn't there, whatever the reason.
    var healthName: String {
        switch self {
        case .ok: return "ok"
        case .degraded: return "degraded"
        case .down, .notInstalled: return "down"
        }
    }

    var detailText: String? {
        switch self {
        case .ok(let d), .degraded(let d): return d
        case .down: return nil
        case .notInstalled: return "openclaw 바이너리 없음"
        }
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
