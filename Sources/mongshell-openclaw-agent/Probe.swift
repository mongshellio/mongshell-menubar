import Foundation

/// The agent's verdict on the gateway. SwiftUI-free on purpose — this target
/// runs headless on the server mac and must not drag in the app's view types.
enum ProbeVerdict: Equatable {
    case ok(detail: String)
    case degraded(detail: String)
    case down
    /// No openclaw binary at any known path. Kept distinct from `.down` because
    /// restarting the gateway can't fix a missing install — the heal tracker
    /// treats it as a non-failure. Reported to clients as `down` (see StatusFile).
    case notInstalled
}

/// What one probe told the agent. Only `.observed` carries a verdict, and only
/// a verdict can go into the status file (`AgentStatus.verdict` is a
/// `ProbeVerdict`) — so a probe the agent failed to hear can never be published
/// or counted toward a heal.
enum ProbeObservation: Equatable {
    case observed(ProbeVerdict)
    /// The agent got nothing to judge — a failure on the agent's side, not a
    /// statement about the gateway.
    case unobserved(reason: String)
}

/// The single home of the openclaw health rules (Decision #25). Originally
/// ported from the app's local probe; the app now only reads the verdict this
/// agent publishes, so a rule change lands here alone.
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

    /// SIGTERM → SIGKILL grace on timeout.
    static let killGrace: TimeInterval = 1
    /// Extra wait after the SIGKILL for output still in flight. Past it, the
    /// read is abandoned even if something still holds the pipe open.
    static let readGrace: TimeInterval = 1
    /// How often the runner wakes to check for exit and the deadlines.
    private static let tick: TimeInterval = 0.01
    private static let readChunkSize = 4096

    /// Runs `path args…` with stdout+stderr merged into one pipe and stdin on
    /// /dev/null. Returns within about `timeout + killGrace + readGrace`
    /// seconds whatever the child and its descendants do.
    ///
    /// - The child leads a new process group, so on timeout the whole group is
    ///   SIGTERM'd, then SIGKILL'd after `killGrace` — openclaw re-executes
    ///   itself with inherited stdio, and the real worker is a grandchild that
    ///   a kill of the direct child alone leaves running (and holding the pipe).
    /// - Once the direct child has exited, whatever is left of its group is
    ///   SIGKILL'd, so stragglers neither hold up the read nor pile up across
    ///   runs.
    /// - Output is read without blocking, against the overall deadline: a
    ///   descendant that left the group (setsid) and still holds the pipe can
    ///   only cost the rest of the deadline, not stop the agent.
    ///
    /// `exitCode` is the exit status, or the signal number if the child was
    /// killed by one (as `Process.terminationStatus` reports it); -1 with empty
    /// `stdout` when the launch itself failed. Every fd opened here is closed on
    /// every path — the agent runs for weeks, and one fd leaked per probe once
    /// hit the fd limit, after which every probe read empty output.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> RunResult {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return RunResult(stdout: "", exitCode: -1, timedOut: false) }
        let (readFD, writeFD) = (fds[0], fds[1])
        defer { close(readFD) }

        let pid = spawnInNewGroup(path, args, output: writeFD)
        // The child holds its own copy; ours must go or EOF never arrives.
        close(writeFD)
        guard let pid else { return RunResult(stdout: "", exitCode: -1, timedOut: false) }

        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)

        let start = ProcessInfo.processInfo.systemUptime
        let termAt = start + timeout
        let killAt = termAt + killGrace
        let giveUpAt = killAt + readGrace

        var output = Data()
        var reachedEOF = false
        var exited = false
        var timedOut = false
        var killSent = false
        while true {
            if !reachedEOF { reachedEOF = readAvailable(readFD, into: &output) }
            if !exited && hasExited(pid) {
                exited = true
                // Stragglers left in the group could hold the pipe and stall
                // EOF; the child's own output is complete by now.
                killGroup(of: pid)
            }
            if exited && reachedEOF { break }

            let now = ProcessInfo.processInfo.systemUptime
            if now >= giveUpAt { break }
            if !exited && now >= termAt && !timedOut {
                timedOut = true
                kill(-pid, SIGTERM)
            }
            if !exited && now >= killAt && !killSent {
                killSent = true
                killGroup(of: pid)
            }

            if reachedEOF {
                Thread.sleep(forTimeInterval: tick)
            } else {
                var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, Int32(tick * 1000))
            }
        }

        // Not exited even after the SIGKILL (stuck in the kernel): it's left
        // unreaped rather than risk a blocking wait.
        let exitCode = exited ? reap(pid) : -1
        return RunResult(stdout: String(decoding: output, as: UTF8.self),
                         exitCode: exitCode, timedOut: timedOut)
    }

    /// posix_spawn with the child as leader of a new process group, stdin on
    /// /dev/null, stdout+stderr on `output`, and no other fd inherited. Signal
    /// dispositions and mask are reset to defaults, as `Process` does. nil when
    /// the spawn fails.
    private static func spawnInNewGroup(_ path: String, _ args: [String], output: Int32) -> pid_t? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0) // 0: a new group whose id is the child's pid
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO)

        // Give the child a real PATH so anything openclaw shells out to resolves.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attr, argv, envp) == 0 else { return nil }
        return pid
    }

    /// Appends whatever the pipe has right now. Returns true once the pipe is
    /// at EOF (or unreadable) — nothing more will come.
    private static func readAvailable(_ fd: Int32, into output: inout Data) -> Bool {
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { output.append(chunk, count: n); continue }
            if n == 0 { return true }
            if errno == EINTR { continue }
            return errno != EAGAIN
        }
    }

    /// Whether `pid` has exited, without reaping it: an unreaped child keeps
    /// its pid — and so its process group id — from being reused, which is
    /// what makes `killGroup` safe to call after the exit.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    /// Best-effort: SIGKILLs every process still in the group `pid` leads.
    private static func killGroup(of pid: pid_t) {
        kill(-pid, SIGKILL)
    }

    /// Reaps the exited child; returns its exit status (or terminating signal).
    private static func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    // MARK: Probe + parse

    /// Live health probe. `run` is nil when no binary was found (then the
    /// observation is `.notInstalled`); it's returned so the caller can log a
    /// timeout, which the verdict alone (`down`) doesn't tell apart.
    static func probe() -> (run: RunResult?, observation: ProbeObservation) {
        guard let bin = binaryPath() else { return (nil, .observed(.notInstalled)) }
        let result = run(bin, ["channels", "status", "--probe"], timeout: probeTimeout)
        return (result, parseProbe(result))
    }

    /// Turns `openclaw channels status --probe` output into an observation, per
    /// the hard-won domain rules. Kept pure (no I/O) so it's trivially testable.
    static func parseProbe(_ result: RunResult) -> ProbeObservation {
        // A hung/killed probe means the gateway isn't answering.
        if result.timedOut { return .observed(.down) }

        // openclaw always says something when it finishes — even "not
        // reachable" is output. Nothing at all means the agent didn't get to
        // hear it (spawn failed, fds exhausted), and judging that `down` once
        // made a healthy gateway restart every 10 minutes.
        if result.stdout.allSatisfy(\.isWhitespace) {
            let reason = result.exitCode == -1 ? "openclaw 실행 실패" : "probe 출력 없음 (exit \(result.exitCode))"
            return .unobserved(reason: reason)
        }
        return .observed(verdict(fromOutput: result))
    }

    /// The verdict rules proper, for a probe that finished and said something.
    private static func verdict(fromOutput result: RunResult) -> ProbeVerdict {
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
            return .degraded(detail: publicDetail(degraded.map(channelName), fallback: "채널 오류"))
        }

        // 🟢 if at least one channel is running and nothing above tripped.
        // NOTE: `disconnected` alone is normal between polls — never DOWN on it.
        let running = channelLines.filter { $0.lowercased().contains("running") }
        if !running.isEmpty {
            return .ok(detail: publicDetail(running.map(channelName), fallback: "정상"))
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

    // MARK: Public detail

    /// Longest channel name we publish verbatim. Real names are short
    /// ("Telegram default"); anything longer smells like a token or an id.
    static let maxPublicNameLength = 32

    /// Joins channel names for the status file, which is public behind only an
    /// unguessable path. openclaw's output format is not ours, so a "name" may
    /// be a bot handle, an email or a token fragment — only names made of
    /// letters (ASCII or Hangul), digits and ` ._-` go out verbatim; the rest
    /// are only counted. Display text only: the verdict is decided before this.
    static func publicDetail(_ names: [String], fallback: String) -> String {
        let named = names.filter { !$0.isEmpty }
        guard !named.isEmpty else { return fallback }
        let shown = named.filter(isPublishableName)
        let hidden = named.count - shown.count
        if hidden == 0 { return shown.joined(separator: ", ") }
        if shown.isEmpty { return "채널 \(hidden)개" }
        return "\(shown.joined(separator: ", ")) 외 \(hidden)개"
    }

    static func isPublishableName(_ name: String) -> Bool {
        guard (1...maxPublicNameLength).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { s in
            switch s.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true // ASCII alnum
            case 0xAC00...0xD7A3: return true // Hangul syllables
            case 0x20, 0x2E, 0x5F, 0x2D: return true // space . _ -
            default: return false
            }
        }
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
