import Foundation

// Regression tests for the OAuth token path.
//
// Pinned here: the token-endpoint classification that decides whether a dead
// refresh token is discarded (invalid_grant) or kept (anything else). Getting
// this wrong either leaves a dead token retrying every poll (the bug this
// pins) or throws away a live token on a transient error. Also the Keychain
// decoding of tokens saved before `signedInAt` existed, and the age format
// the diagnostic log prints.
//
// Run with `./scripts/test.sh`, which compiles this against the real sources.

var failures: [String] = []

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

func body(_ s: String) -> Data { Data(s.utf8) }

// MARK: invalid_grant classification

do {
    let err = AuthError.tokenError(
        status: 400,
        body: body(#"{"error":"invalid_grant","error_description":"Refresh token expired"}"#))
    if case .invalidGrant(let desc) = err {
        check("400 invalid_grant → invalidGrant", true)
        check("invalidGrant carries error_description", desc == "Refresh token expired", desc)
    } else {
        check("400 invalid_grant → invalidGrant", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: 400, body: body(#"{"error":"invalid_grant"}"#))
    if case .invalidGrant(let desc) = err {
        check("invalid_grant without description → empty description", desc.isEmpty, desc)
    } else {
        check("invalid_grant without description → invalidGrant", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: 400, body: body(#"{"error":"invalid_request"}"#))
    if case .tokenExchangeFailed(let detail) = err {
        check("400 other error → tokenExchangeFailed (token kept)", true)
        check("detail names status and error field only",
              detail == "status=400 error=invalid_request", detail)
    } else {
        check("400 other error → tokenExchangeFailed (token kept)", false, "\(err)")
    }
}

do {
    // Only a 400 says the grant itself is dead; a 5xx echoing the same word is
    // not a verdict on our token.
    let err = AuthError.tokenError(status: 503, body: body(#"{"error":"invalid_grant"}"#))
    if case .tokenExchangeFailed = err {
        check("503 with invalid_grant body → tokenExchangeFailed (token kept)", true)
    } else {
        check("503 with invalid_grant body → tokenExchangeFailed (token kept)", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: 400, body: body("<html>bad gateway</html>"))
    if case .tokenExchangeFailed(let detail) = err {
        check("non-JSON body → tokenExchangeFailed", true)
        check("non-JSON detail carries status", detail.contains("400"), detail)
    } else {
        check("non-JSON body → tokenExchangeFailed", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: -1, body: Data())
    if case .tokenExchangeFailed = err {
        check("empty body → tokenExchangeFailed", true)
    } else {
        check("empty body → tokenExchangeFailed", false, "\(err)")
    }
}

check("invalidGrant has a Korean user message",
      AuthError.invalidGrant("x").errorDescription?.contains("다시 로그인") == true)

check("invalidGrant log summary names the error and description",
      AuthError.invalidGrant("Refresh token expired").logSummary
          == "status=400 error=invalid_grant (Refresh token expired)")

// MARK: OAuthToken Keychain decoding

do {
    // A token saved by a build that predates `signedInAt`.
    let legacy = body(#"{"accessToken":"a","refreshToken":"r","expiresAt":1000}"#)
    let token = try? JSONDecoder().decode(OAuthToken.self, from: legacy)
    check("legacy token without signedInAt still decodes", token != nil)
    check("legacy token has nil signedInAt", token?.signedInAt == nil)
    check("legacy token keeps its fields", token?.accessToken == "a" && token?.refreshToken == "r")
}

do {
    let signedIn = Date(timeIntervalSince1970: 1_700_000_000)
    let original = OAuthToken(accessToken: "a", refreshToken: "r", expiresAt: nil, signedInAt: signedIn)
    let data = try! JSONEncoder().encode(original)
    let decoded = try? JSONDecoder().decode(OAuthToken.self, from: data)
    check("signedInAt survives an encode/decode round trip", decoded == original)
}

// MARK: Diagnostic log formatting

do {
    let start = Date(timeIntervalSince1970: 0)
    check("age 0 → 0d0h", AuthDebugLog.age(from: start, to: start) == "0d0h")
    check("age 1d3h", AuthDebugLog.age(from: start, to: start.addingTimeInterval(27 * 3600)) == "1d3h")
    check("age rounds hours down",
          AuthDebugLog.age(from: start, to: start.addingTimeInterval(27 * 3600 + 3599)) == "1d3h")
    check("age never negative", AuthDebugLog.age(from: start.addingTimeInterval(60), to: start) == "0d0h")

    let token = OAuthToken(accessToken: "a", refreshToken: nil, expiresAt: nil, signedInAt: nil)
    check("session without signedInAt says unknown", AuthDebugLog.session(token) == "signed_in=unknown")
    var dated = token
    dated.signedInAt = start
    let line = AuthDebugLog.session(dated, now: start.addingTimeInterval(49 * 3600))
    check("session line carries signed_in and age",
          line.hasPrefix("signed_in=") && line.hasSuffix(" age=2d1h"), line)
    check("session line never contains the token", !line.contains("a\"") && !line.contains("accessToken"))
}

// MARK: result

if failures.isEmpty {
    print("\nAuth tests: all passed")
    exit(0)
} else {
    print("\nAuth tests: \(failures.count) failed")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
