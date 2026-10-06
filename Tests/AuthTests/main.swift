import Foundation

// Regression tests for the OAuth token path.
//
// Pinned here: the token-endpoint classification that decides whether a dead
// refresh token is discarded (invalid_grant) or kept (anything else). Getting
// this wrong either leaves a dead token retrying every poll (the bug this
// pins) or throws away a live token on a transient error.
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
    if case .tokenExchangeFailed = err {
        check("400 other error → tokenExchangeFailed (token kept)", true)
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

// MARK: result

if failures.isEmpty {
    print("\nAuth tests: all passed")
    exit(0)
} else {
    print("\nAuth tests: \(failures.count) failed")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
