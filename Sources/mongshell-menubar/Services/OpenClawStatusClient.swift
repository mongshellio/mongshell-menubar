import Foundation

/// Why reading the status document failed. `detail` is what the UI shows — it
/// never contains the URL, because the URL's path *is* the access token.
enum OpenClawStatusError: Error, Equatable, Sendable {
    /// HTTP 404 — funnel is up but nothing is served at this path: wrong token,
    /// rotated token, or wrong host.
    case notFound
    case http(Int)
    case timedOut
    case offline
    /// Any other transport failure (DNS, TLS, refused, …).
    case network
    /// Not a JSON object.
    case badResponse
    /// No usable `checkedAt` — the document can't vouch for its own freshness.
    case missingCheckedAt
    /// The request was cancelled on our side (the poll loop was replaced). Not
    /// a fact about the server, so `OpenClawReading` never records it.
    case cancelled

    var detail: String {
        switch self {
        case .notFound:         return "주소 또는 토큰이 맞지 않습니다"
        case .http(let code):   return "서버 응답 오류 (HTTP \(code))"
        case .timedOut:         return "응답 시간 초과"
        case .offline:          return "네트워크 연결 없음"
        case .network:          return "서버에 연결할 수 없습니다"
        case .badResponse:      return "상태 파일을 읽을 수 없습니다"
        case .missingCheckedAt: return "상태 파일에 확인 시각이 없습니다"
        case .cancelled:        return "요청 취소됨"
        }
    }

    /// Transport failure → error. Fixed strings only: URLError's own
    /// description embeds the URL.
    static func transport(_ code: URLError.Code) -> OpenClawStatusError {
        switch code {
        case .cancelled: return .cancelled
        case .timedOut:  return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline
        default:         return .network
        }
    }
}

/// Why a typed-in status URL was rejected.
enum OpenClawURLError: LocalizedError, Equatable {
    case notHTTPS
    case malformed

    var errorDescription: String? {
        switch self {
        case .notHTTPS:  return "https:// 주소만 사용할 수 있습니다"
        case .malformed: return "주소 형식이 올바르지 않습니다"
        }
    }
}

/// Reads the openclaw status document that the server agent writes and
/// `tailscale funnel` serves (Decision #25). Read-only by construction: one GET,
/// no credentials, nothing written back.
struct OpenClawStatusClient: Sendable {
    /// A static file on the tailnet edge answers fast; anything slower is a
    /// network problem, and the next poll will try again.
    static let requestTimeout: TimeInterval = 10

    /// Ephemeral + no cache: every poll must see the file as it is now — a
    /// cached copy would look fresh while the agent is dead. Nothing (cookies,
    /// the token-bearing URL in a cache DB) is persisted to disk either.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: config)
    }()

    // MARK: URL

    /// Normalizes user input. Empty (after trimming) → nil, meaning "not
    /// configured". Only `https` is accepted: the path carries the token, and
    /// the agent is only ever published over HTTPS.
    static func validatedURL(_ raw: String) throws(OpenClawURLError) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme else {
            throw .malformed
        }
        guard scheme.lowercased() == "https" else { throw .notHTTPS }
        guard let host = url.host, !host.isEmpty else { throw .malformed }
        return url
    }

    // MARK: Fetch

    func fetch(_ url: URL) async throws(OpenClawStatusError) -> OpenClawStatus {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch let error as URLError {
            throw .transport(error.code)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        return try Self.interpret(statusCode: http.statusCode, data: data)
    }

    /// Status code → document or error. Split from `fetch` so the 404 mapping
    /// is testable without a server.
    static func interpret(statusCode: Int, data: Data) throws(OpenClawStatusError) -> OpenClawStatus {
        switch statusCode {
        case 200: return try parse(data: data)
        case 404: throw .notFound
        default:  throw .http(statusCode)
        }
    }

    // MARK: Tolerant decoding

    /// The agent's document (`StatusFile.swift`, schema 1):
    /// ```
    /// {"schema":1,"checkedAt":"2026-09-29T03:12:45Z","health":"ok",
    ///  "detail":"Telegram default","intervalSeconds":60,"autoHeal":true,
    ///  "lastHeal":{"at":"…","ok":true,"reason":"down"}}
    /// ```
    /// Lenient like the usage parser (Decision 2): unknown keys are ignored and
    /// a newer `schema` is still attempted. The only hard requirement is a
    /// parseable `checkedAt` — without it staleness can't be judged, and a
    /// document that can't prove it's fresh must not paint a green dot.
    /// `checkedAt` is kept as the server wrote it; `OpenClawReading` squares it
    /// with our clock.
    static func parse(data: Data) throws(OpenClawStatusError) -> OpenClawStatus {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .badResponse
        }
        guard let checkedAt = isoDate(root["checkedAt"]) else { throw .missingCheckedAt }

        return OpenClawStatus(
            checkedAt: checkedAt,
            health: health(name: root["health"], detail: root["detail"] as? String),
            intervalSeconds: positiveInt(root["intervalSeconds"]),
            autoHeal: root["autoHeal"] as? Bool,
            lastHeal: healEvent(root["lastHeal"])
        )
    }

    /// Longest unknown `health` value echoed back in the UI.
    private static let unknownHealthDisplayLimit = 32

    private static func health(name: Any?, detail: String?) -> OpenClawHealth {
        let detail = detail ?? ""
        switch name as? String {
        case "ok":       return .ok(detail: detail)
        case "degraded": return .degraded(detail: detail)
        case "down":     return .down
        case let other?:
            // Something the agent knows and we don't — not provably healthy,
            // not provably down. Amber, with the raw word so it's diagnosable.
            return .degraded(detail: "알 수 없는 상태: \(other.prefix(unknownHealthDisplayLimit))")
        case nil:
            return .degraded(detail: "알 수 없는 상태")
        }
    }

    private static func healEvent(_ any: Any?) -> OpenClawHealEvent? {
        guard let dict = any as? [String: Any], let at = isoDate(dict["at"]) else { return nil }
        // A missing `ok` reads as success: announcing a failure we can't
        // confirm would be a false alarm.
        return OpenClawHealEvent(at: at,
                                 ok: (dict["ok"] as? Bool) ?? true,
                                 reason: dict["reason"] as? String)
    }

    private static func positiveInt(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber else { return nil }
        let value = number.doubleValue
        // Bounded so `3 × interval` can't overflow downstream.
        guard value.isFinite, value > 0, value < Double(Int32.max) else { return nil }
        return Int(value)
    }

    private static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFrac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
