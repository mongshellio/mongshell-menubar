import Foundation
import CryptoKit
import AppKit

/// OAuth 2.0 Authorization Code + PKCE, using Claude Code's own client.
///
/// Claude Code's registered redirect is a console callback page that displays
/// `code#state` for the user to copy — there is no custom-scheme interception.
/// So sign-in opens the browser and prompts the user to paste the code back
/// (the same flow other Claude-subscription tools use).
@MainActor
final class AuthService: NSObject {

    func signIn() async throws -> OAuthToken {
        guard !Config.oauthClientID.isEmpty else { throw AuthError.notConfigured }
        // Seamless loopback first; fall back to manual code paste if the
        // browser never returns (e.g. loopback redirect not honored).
        var token: OAuthToken
        do {
            token = try await signInLoopback()
        } catch is CancellationError {
            throw AuthError.cancelled
        } catch {
            AuthDebugLog.write("loopback failed (\(error)); falling back to manual paste")
            do {
                token = try await signInManual()
            } catch let error as AuthError {
                AuthDebugLog.write("sign-in fail \(error.logSummary)")
                throw error
            }
        }
        token.signedInAt = Date()
        AuthDebugLog.write("sign-in ok expires=\(AuthDebugLog.iso(token.expiresAt))")
        return token
    }

    private func authorizeURL(redirectURI: String, verifier: String, showCode: Bool) -> URL {
        let challenge = Self.codeChallenge(for: verifier)
        var comps = URLComponents(url: Config.oauthAuthorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            showCode ? .init(name: "code", value: "true") : nil,
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Config.oauthClientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: Config.oauthScopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Claude Code sets `state` to the SAME value as the code_verifier.
            .init(name: "state", value: verifier)
        ].compactMap { $0 }
        return comps.url!
    }

    /// Seamless flow: spin up a localhost listener, redirect the browser back
    /// to it automatically, no paste. Times out to allow the manual fallback.
    private func signInLoopback() async throws -> OAuthToken {
        let verifier = Self.randomURLSafe(32)
        let server = LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirect = "http://localhost:\(port)/callback"

        NSWorkspace.shared.open(authorizeURL(redirectURI: redirect, verifier: verifier, showCode: false))

        let callback = try await withThrowingTaskGroup(of: URL.self) { group -> URL in
            group.addTask { try await server.waitForCallback() }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw AuthError.tokenExchangeFailed("loopback timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.invalidCallback
        }
        return try await exchange(code: code, verifier: verifier, redirectURI: redirect)
    }

    /// Fallback: browser shows the code on the console callback page; paste it.
    private func signInManual() async throws -> OAuthToken {
        let verifier = Self.randomURLSafe(32)
        NSWorkspace.shared.open(authorizeURL(redirectURI: Config.oauthRedirectURI,
                                             verifier: verifier, showCode: true))
        guard let pasted = promptForCode() else { throw AuthError.cancelled }
        let code = pasted.split(separator: "#").first.map(String.init) ?? pasted
        guard !code.isEmpty else { throw AuthError.invalidCallback }
        return try await exchange(code: code, verifier: verifier, redirectURI: Config.oauthRedirectURI)
    }

    /// The renewed token inherits `signedInAt`: the endpoint only knows about
    /// this refresh, not the sign-in that started the session.
    func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refresh = token.refreshToken, !Config.oauthClientID.isEmpty else {
            throw AuthError.tokenExchangeFailed("refresh token 없음")
        }
        let session = AuthDebugLog.session(token)
        do {
            var renewed = try await postToken([
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Config.oauthClientID
            ])
            renewed.signedInAt = token.signedInAt
            AuthDebugLog.write("refresh ok expires=\(AuthDebugLog.iso(renewed.expiresAt)) \(session)")
            return renewed
        } catch let error as AuthError {
            AuthDebugLog.write("refresh fail \(error.logSummary) \(session)")
            throw error
        } catch {
            AuthDebugLog.write("refresh fail transport=\(error) \(session)")
            throw error
        }
    }

    // MARK: - Manual code entry

    private func promptForCode() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude 계정 로그인"
        alert.informativeText = "열린 브라우저에서 로그인·승인한 뒤,\n표시된 인증 코드를 아래에 붙여넣으세요."
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "인증 코드 붙여넣기"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    // MARK: - Token exchange

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthToken {
        try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Config.oauthClientID,
            "code_verifier": verifier,
            "state": verifier
        ])
    }

    private func postToken(_ body: [String: String]) async throws -> OAuthToken {
        var req = URLRequest(url: Config.oauthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1

        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            throw AuthError.tokenError(status: status, body: data)
        }

        var expires: Date?
        if let secs = json["expires_in"] as? Double { expires = Date().addingTimeInterval(secs) }
        return OAuthToken(accessToken: access,
                          refreshToken: json["refresh_token"] as? String,
                          expiresAt: expires)
    }

    // MARK: - PKCE

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
