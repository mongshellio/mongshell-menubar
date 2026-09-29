import Foundation

/// The agent's verdict on the gateway. SwiftUI-free on purpose — this target
/// runs headless on the server mac and must not drag in the app's view types.
enum ProbeVerdict: Equatable {
    case ok(detail: String)
    case degraded(detail: String)
    case down
    /// No openclaw binary at any known path. Kept distinct from `.down` because
    /// restarting the gateway can't fix a missing install — the heal tracker
    /// treats it as a non-failure, exactly like the app's `.notInstalled`.
    case notInstalled
}

/// Copied from the app's `OpenClawService` (run / probe / parse) so the server
/// agent judges health by the identical rules. The app keeps its own copy until
/// PR-B switches it to reading this agent's status file; until then, a rule
/// change must land in both places.
enum Probe {
    /// launchd hands the agent a minimal PATH, so we never trust `which` — we
    /// probe these absolute candidates in order.
    static let binaryCandidates = [
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
    ]

    /// How long `channels status --probe` may take before we call it hung.
    static let probeTimeout: TimeInterval = 8

    /// Re-resolved per probe (not cached like the app): the agent runs for weeks
    /// and a `brew reinstall` must not require restarting it.
    static func binaryPath() -> String? {
        binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Process runner

    struct RunResult {
        let stdout: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Runs `path args…`, merging stdout+stderr, bounded by `timeout`. On
    /// timeout the process is SIGTERM'd then SIGKILL'd and `timedOut` is true.
    ///
    /// Blocking. openclaw probe output is a handful of lines, well under the
    /// pipe buffer, so reading after the process exits cannot deadlock here.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        // Give the child a real PATH so anything openclaw shells out to resolves.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return RunResult(stdout: "", exitCode: -1, timedOut: false)
        }

        // Poll for exit up to the deadline; escalate SIGTERM → SIGKILL so a
        // hung longpoll can't wedge us.
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while proc.isRunning {
            if Date() >= deadline {
                timedOut = true
                proc.terminate() // SIGTERM
                let killBy = Date().addingTimeInterval(1.0)
                while proc.isRunning && Date() < killBy {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // The write end is closed now (process dead), so this returns promptly.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return RunResult(stdout: out, exitCode: proc.terminationStatus, timedOut: timedOut)
    }

    // MARK: Probe + parse

    /// Live health probe. Returns `.notInstalled` if the binary is missing.
    static func probe() -> ProbeVerdict {
        guard let bin = binaryPath() else { return .notInstalled }
        let result = run(bin, ["channels", "status", "--probe"], timeout: probeTimeout)
        return parseProbe(result)
    }

    /// Turns `openclaw channels status --probe` output into a verdict, per the
    /// hard-won domain rules. Kept pure (no I/O) so it's trivially testable.
    static func parseProbe(_ result: RunResult) -> ProbeVerdict {
        // A hung/killed probe means the gateway isn't answering.
        if result.timedOut { return .down }

        let text = result.stdout
        let lower = text.lowercased()

        // Explicit gateway-unreachable signals → DOWN. (Checked before the
        // positive "reachable" test below, since "not reachable"/"unreachable"
        // both contain the substring "reachable".)
        if lower.contains("not reachable")
            || lower.contains("unreachable")
            || lower.contains("connection refused")
            || lower.contains("econnrefused") {
            return .down
        }

        let channelLines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isChannelLine)

        // No parseable channel state. A clean exit that still reports the
        // gateway as reachable (real output: "Gateway reachable.") but lists no
        // channels is OK-but-empty; anything else (nonzero exit, or no positive
        // reachable signal at all) is treated as the gateway being down.
        if channelLines.isEmpty {
            if result.exitCode == 0 && lower.contains("reachable") {
                return .ok(detail: "채널 없음")
            }
            return .down
        }

        // 🟡 if ANY channel is stopped / not-running / errored.
        let degraded = channelLines.filter(lineIsDegraded)
        if !degraded.isEmpty {
            let names = degraded.map(channelName).joined(separator: ", ")
            return .degraded(detail: names.isEmpty ? "채널 오류" : names)
        }

        // 🟢 if at least one channel is running and nothing above tripped.
        // NOTE: `disconnected` alone is normal between polls — never DOWN on it.
        let running = channelLines.filter { $0.lowercased().contains("running") }
        if !running.isEmpty {
            let names = running.map(channelName).joined(separator: ", ")
            return .ok(detail: names.isEmpty ? "정상" : names)
        }

        // Channels listed but only transient states (e.g. `disconnected`): the
        // gateway answered and nothing is degraded, so this is not DOWN.
        return .ok(detail: "정상")
    }

    /// A line describing a channel: the `- Telegram default: …` shape, or any
    /// line carrying a status token.
    private static func isChannelLine(_ line: String) -> Bool {
        if line.hasPrefix("-") { return true }
        let lower = line.lowercased()
        return lower.contains("running")
            || lower.contains("stopped")
            || lower.contains("health:")
            || lower.contains("error:")
            || lower.contains("disconnected")
    }

    /// The stopped/not-running/errored signals that make a channel 🟡.
    private static func lineIsDegraded(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("stopped")
            || lower.contains("health:not-running")
            || lower.contains("error:")
    }

    /// Best-effort channel name for display: text before the first `:`, sans
    /// the leading `- ` bullet.
    private static func channelName(_ line: String) -> String {
        var l = line
        if l.hasPrefix("-") {
            l.removeFirst()
            l = l.trimmingCharacters(in: .whitespaces)
        }
        if let colon = l.firstIndex(of: ":") {
            return String(l[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        return l.trimmingCharacters(in: .whitespaces)
    }
}
