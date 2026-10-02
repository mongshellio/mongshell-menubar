import Foundation

// Server-side openclaw watchdog. Runs under launchd on the always-on mac:
// probe the gateway → maybe hard-restart it → judge the host's own signals
// (power, disk) → write the verdicts to a JSON file that `tailscale funnel`
// serves to the menubar clients. No network listener of our own — funnel does
// the serving.

// MARK: Options

struct Options {
    static let defaultInterval = 60
    /// A probe takes up to 10s (8s timeout + kill and read grace) and a heal
    /// adds 3s + a re-probe; below this the loop would spend most of its time
    /// probing.
    static let minimumInterval = 15
    /// A day. Clients derive their "server unreachable" threshold from
    /// 3×interval, so an unbounded value would mean a dead agent is never
    /// noticed (and the product could overflow).
    static let maximumInterval = 86_400
    static let defaultSelfLabel = "com.mongshell.openclaw-agent"

    var statusFile: URL
    var gatewayLabel: String?
    var interval = defaultInterval
    var autoHeal = true
    var selfLabel = defaultSelfLabel
}

let usage = """
    사용법: mongshell-openclaw-agent --status-file <path> [옵션]
      --status-file <path>     판정 결과 JSON 을 쓸 경로 (필수)
      --gateway-label <label>  재시작할 게이트웨이 launchd 레이블 (기본: 자동 탐색)
      --interval <sec>         probe 주기, 초 (기본 \(Options.defaultInterval), \(Options.minimumInterval)~\(Options.maximumInterval))
      --no-auto-heal           자동복구 끄기
      --self-label <label>     이 에이전트의 launchd 레이블 (기본 \(Options.defaultSelfLabel))
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("오류: \(message)\n\n\(usage)\n".utf8))
    exit(64) // EX_USAGE
}

func parseOptions(_ args: [String]) -> Options {
    var statusFile: URL?
    var gatewayLabel: String?
    var interval = Options.defaultInterval
    var autoHeal = true
    var selfLabel = Options.defaultSelfLabel

    var it = args.makeIterator()
    func value(for flag: String) -> String {
        guard let v = it.next(), !v.hasPrefix("--") else { fail("\(flag) 에 값이 필요합니다") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--status-file":
            statusFile = URL(fileURLWithPath: value(for: arg)).standardizedFileURL
        case "--gateway-label":
            gatewayLabel = value(for: arg)
        case "--interval":
            let raw = value(for: arg)
            guard let n = Int(raw) else { fail("--interval 은 정수여야 합니다: \(raw)") }
            interval = min(max(n, Options.minimumInterval), Options.maximumInterval)
        case "--no-auto-heal":
            autoHeal = false
        case "--self-label":
            selfLabel = value(for: arg)
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("알 수 없는 인자: \(arg)")
        }
    }
    guard let statusFile else { fail("--status-file 은 필수입니다") }
    return Options(statusFile: statusFile, gatewayLabel: gatewayLabel,
                   interval: interval, autoHeal: autoHeal, selfLabel: selfLabel)
}

// MARK: Logging

/// launchd redirects stdout to a log file; line-buffer it so entries land as
/// they happen instead of in 4KB bursts.
setvbuf(stdout, nil, _IOLBF, 0)

/// Formatter built per call: logging is rare (state changes and heals only),
/// and a shared top-level instance would be main-actor isolated under Swift 6.
func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
}

func describe(_ verdict: ProbeVerdict) -> String {
    verdict.detailText.map { "\(verdict.healthName) (\($0))" } ?? verdict.healthName
}

func describe(_ host: HostStatus?) -> String {
    guard let host else { return "읽을 신호 없음" }
    let power = host.power.map { "전원 \($0.level.healthName)" } ?? "전원 없음"
    let disk = host.disk.map { "디스크 \($0.level.healthName)" } ?? "디스크 없음"
    return "\(host.level.healthName) (\(power), \(disk))"
}

// MARK: Loop

/// Gives launchd a moment to bring the gateway back before re-probing.
let postHealSettle: TimeInterval = 3
/// EX_TEMPFAIL: the agent exits after a probe it couldn't hear (see below), and
/// launchd's KeepAlive starts a fresh process.
let unobservedExitCode: Int32 = 75

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
var lastHeal = StatusFile.readLastHeal(from: options.statusFile)
var tracker = HealTracker(lastHealAt: lastHeal?.at)
var lastLogged: ProbeVerdict?
/// nil: nothing logged yet.
var lastLoggedHostLevels: HostSignalLevels?
/// Timeout is logged on the first of a run of timed-out probes only.
var lastProbeTimedOut = false

log("시작 — status-file=\(options.statusFile.path) interval=\(options.interval)s autoHeal=\(options.autoHeal)")
if options.gatewayLabel == options.selfLabel {
    log("경고: --gateway-label 이 자기 레이블(\(options.selfLabel))이라 무시하고 자동 탐색합니다")
}

/// One probe, with a log line when it timed out.
@MainActor func probeGateway() -> ProbeObservation {
    let (run, observation) = Probe.probe()
    let timedOut = run?.timedOut ?? false
    if timedOut && !lastProbeTimedOut {
        log("probe 시간 초과 — \(Int(Probe.probeTimeout))초 안에 끝나지 않아 프로세스 그룹을 종료")
    }
    lastProbeTimedOut = timedOut
    return observation
}

/// A probe the agent couldn't hear says nothing about the gateway, so it is
/// neither published nor counted toward a heal. The cause is usually in this
/// process (an exhausted fd table once made every probe read empty), so rather
/// than retry in place the agent waits one interval — launchd would otherwise
/// restart it in a tight loop — and exits for a fresh start.
@MainActor func restartAfterUnobserved(_ reason: String) -> Never {
    log("probe 결과를 받지 못함 — \(reason). 게시·복구 없이 \(options.interval)초 뒤 재시작")
    Thread.sleep(forTimeInterval: TimeInterval(options.interval))
    exit(unobservedExitCode)
}

/// Judges the host signals and writes the status file, logging changes.
@MainActor func publish(_ verdict: ProbeVerdict, checkedAt: Date) {
    let host = HostRules.judge(power: HostProbe.readPower(), disk: HostProbe.readDisk())

    let status = AgentStatus(
        checkedAt: checkedAt, verdict: verdict, intervalSeconds: options.interval,
        autoHeal: options.autoHeal, lastHeal: lastHeal, host: host)
    do {
        try StatusFile.write(status, to: options.statusFile)
    } catch {
        log("상태 파일 쓰기 실패 — \(error.localizedDescription)")
    }

    if verdict != lastLogged {
        log("상태: \(describe(verdict))")
        lastLogged = verdict
    }
    // Per signal, not the overall level: power going bad while the disk
    // already holds the overall level at warning is still a line.
    let hostLevels = HostSignalLevels(host)
    if hostLevels != lastLoggedHostLevels {
        log("호스트: \(describe(host))")
        lastLoggedHostLevels = hostLevels
    }
}

while true {
    // Top-level code has no run loop to drain autoreleased Foundation objects,
    // so each iteration drains its own pool.
    autoreleasepool {
        var verdict: ProbeVerdict
        switch probeGateway() {
        case .observed(let v): verdict = v
        case .unobserved(let reason): restartAfterUnobserved(reason)
        }
        var checkedAt = Date()

        if options.autoHeal {
            tracker.record(verdict)
            if tracker.isHealDue(now: checkedAt) {
                let label = Launchd.gatewayLabel(
                    explicit: options.gatewayLabel, selfLabel: options.selfLabel,
                    in: Launchd.userLaunchAgentsDir)
                let ok = Launchd.kickstart(label: label)
                tracker.markHealed(at: checkedAt)
                lastHeal = HealRecord(at: checkedAt, ok: ok, reason: verdict.healthName)
                log("복구 시도 — \(label) kickstart \(ok ? "성공" : "실패") (원인: \(describe(verdict)))")

                Thread.sleep(forTimeInterval: postHealSettle)
                switch probeGateway() {
                case .observed(let v):
                    verdict = v
                    checkedAt = Date()
                    // Counted like any probe (as the app's post-heal refresh
                    // is); the cooldown just set keeps it from triggering
                    // another heal.
                    tracker.record(verdict)
                case .unobserved(let reason):
                    // The heal must still reach the file: the next process
                    // takes its cooldown from `lastHeal` there. Published with
                    // the pre-heal verdict and the time it was observed.
                    publish(verdict, checkedAt: checkedAt)
                    restartAfterUnobserved(reason)
                }
            }
        }

        publish(verdict, checkedAt: checkedAt)
        Thread.sleep(forTimeInterval: TimeInterval(options.interval))
    }
}
