import Foundation
import Security

/// A bearer token plus optional refresh material.
struct OAuthToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// When the user signed in through the app's own OAuth; carried across
    /// refreshes so a lapsed login can be dated. Optional so Keychain items
    /// written before this field existed still decode. nil for CLI tokens.
    var signedInAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60) // 60s slack
    }
}

/// Reads/writes tokens. Priority for reads:
///   1. our own OAuth token (Keychain)
///   2. Claude Code CLI token (Keychain "Claude Code-credentials", else file)
enum CredentialStore {

    // MARK: Own OAuth token (read/write)

    static func saveOwnToken(_ token: OAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
            kSecAttrAccount as String: Config.ownKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func loadOwnToken() -> OAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
            kSecAttrAccount as String: Config.ownKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let token = try? JSONDecoder().decode(OAuthToken.self, from: data)
        else { return nil }
        return token
    }

    static func clearOwnToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
            kSecAttrAccount as String: Config.ownKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Claude Code CLI token (read-only fallback)

    /// Attempts to read the Claude Code OAuth access token from the Keychain,
    /// falling back to ~/.claude/.credentials.json. Returns nil if neither is
    /// present or readable (e.g. the user denies the Keychain prompt).
    static func loadClaudeCodeToken() -> OAuthToken? {
        if let t = readClaudeCodeKeychain() { return t }
        return readClaudeCodeFile()
    }

    private static func readClaudeCodeKeychain() -> OAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.claudeCodeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return parseClaudeCodeJSON(data)
    }

    private static func readClaudeCodeFile() -> OAuthToken? {
        guard let data = try? Data(contentsOf: Config.claudeCodeCredentialsFile) else { return nil }
        return parseClaudeCodeJSON(data)
    }

    /// Claude Code stores `{ "claudeAiOauth": { accessToken, refreshToken, expiresAt } }`.
    /// `expiresAt` is epoch milliseconds. Decoded defensively.
    private static func parseClaudeCodeJSON(_ data: Data) -> OAuthToken? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int {
            expires = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return OAuthToken(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }
}
