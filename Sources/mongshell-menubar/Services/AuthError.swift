import Foundation

enum AuthError: LocalizedError {
    case notConfigured
    case cancelled
    case invalidCallback
    case tokenExchangeFailed(String)
    /// The server no longer honours our refresh token (expired, revoked, or
    /// already used). Carries the server's `error_description`.
    case invalidGrant(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "OAuth 설정이 없습니다."
        case .cancelled: return "로그인이 취소되었습니다."
        case .invalidCallback: return "붙여넣은 코드를 해석할 수 없습니다."
        case .tokenExchangeFailed(let detail):
            return "토큰 발급에 실패했습니다. \(detail)"
        case .invalidGrant:
            return "로그인이 만료되었습니다. 다시 로그인해 주세요."
        }
    }

    /// Classifies a non-success token-endpoint response.
    ///
    /// `400 {"error":"invalid_grant"}` is the one failure the caller must not
    /// retry: the refresh token is dead server-side and every further attempt
    /// is another 400. Everything else (network, 5xx, unknown body) is
    /// reported as a plain exchange failure so the caller keeps the token.
    static func tokenError(status: Int, body: Data) -> AuthError {
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 400, fields?["error"] as? String == "invalid_grant" {
            return .invalidGrant(fields?["error_description"] as? String ?? "")
        }
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        return .tokenExchangeFailed("(\(status)) \(bodyText.prefix(160))")
    }
}
