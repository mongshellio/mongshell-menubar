import Foundation

/// Central place for the (unofficial) endpoint + OAuth parameters.
///
/// ⚠️ These target Claude's *subscription* usage, for which there is no public
/// API. Values below mirror what the Claude Code CLI uses. They are unverified
/// placeholders where noted — see Phase 0 in the plan: capture a real
/// oauth/usage response and confirm the exact client_id / headers / schema
/// before shipping. Nothing here is transmitted anywhere except Anthropic's
/// own hosts; tokens live only in the local Keychain.
enum Config {
    /// Subscription usage endpoint (same data as Claude Code `/usage`).
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The `claude-code/<version>` User-Agent is REQUIRED — without it the
    /// endpoint drops into an aggressively rate-limited bucket (persistent 429).
    static let userAgent = "claude-code/1.0.0"

    /// OAuth beta header Claude Code sends with subscription requests.
    static let anthropicBeta = "oauth-2025-04-20"

    // MARK: OAuth (Authorization Code + PKCE)
    // These are Claude Code's own OAuth parameters. Anthropic does not issue
    // client IDs to third parties, so reusing this one is a ToS grey area
    // (see README). The manual-paste redirect below is what Claude Code uses:
    // the browser lands on a console page showing `code#state` to paste back.
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthAuthorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    // Anthropic migrated console.anthropic.com → platform.claude.com; the
    // token exchange + callback now live on the new host.
    static let oauthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let oauthRedirectURI = "https://platform.claude.com/oauth/code/callback"
    static let oauthScopes = "org:create_api_key user:profile user:inference"

    // MARK: Local credential sources
    /// Keychain generic-password service name Claude Code stores its creds under.
    static let claudeCodeKeychainService = "Claude Code-credentials"
    /// Fallback file path some installs use.
    static var claudeCodeCredentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// Our own Keychain item for OAuth-login tokens.
    static let ownKeychainService = "com.mongshell.menubar.tokens"
    static let ownKeychainAccount = "oauth"

    static let minPollInterval: Int = 180

    /// Append-only OAuth diagnostics (`AuthDebugLog`). A debugging aid, not
    /// user data, so it lives in the per-user temporary directory ($TMPDIR —
    /// mode 0700, emptied on reboot) rather than the shared /tmp: that one is
    /// world-readable, and a fixed path there can be pre-planted as a symlink
    /// by any local user to redirect our appends.
    static let authDebugLogURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mongshell-menubar_auth.log")
}
