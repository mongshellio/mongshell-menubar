import Foundation

/// Append-only diagnostic log for the OAuth token path (`Config.authDebugLogURL`).
///
/// Exists so that the next time the login lapses, "how long after sign-in" and
/// "when did the last refresh succeed" can be read off the file instead of
/// reconstructed from network captures. Never write a token or auth code here.
enum AuthDebugLog {
    static func write(_ message: String) {
        let line = "\(iso(Date())) \(message)\n"
        let url = Config.authDebugLogURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// `signed_in=<ISO> age=<N>d<H>h` for a token, or `signed_in=unknown` for
    /// one saved before sign-in time was recorded.
    static func session(_ token: OAuthToken, now: Date = Date()) -> String {
        guard let signedInAt = token.signedInAt else { return "signed_in=unknown" }
        return "signed_in=\(iso(signedInAt)) age=\(age(from: signedInAt, to: now))"
    }

    /// Local time with offset, to the second — e.g. `2026-10-06T20:05:00+09:00`.
    static func iso(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `3d14h` — whole days and the remaining whole hours.
    static func age(from start: Date, to end: Date) -> String {
        let hours = max(0, Int(end.timeIntervalSince(start)) / 3600)
        return "\(hours / 24)d\(hours % 24)h"
    }
}
