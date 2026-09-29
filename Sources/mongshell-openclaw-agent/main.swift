import Foundation

// Server-side openclaw watchdog. Runs under launchd on the always-on mac:
// probe the gateway → maybe hard-restart it → write the verdict to a JSON file
// that `tailscale funnel` serves to the menubar clients. No network listener of
// our own — funnel does the serving.

// MARK: Options

struct Options {
    static let defaultInterval = 60
    /// Probe takes up to 8s and heal adds 3s + a re-probe; below this the loop
    /// would spend most of its time probing.
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

// MARK: Loop

/// Gives launchd a moment to bring the gateway back before re-probing.
let postHealSettle: TimeInterval = 3

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
var lastHeal = StatusFile.readLastHeal(from: options.statusFile)
var tracker = HealTracker(lastHealAt: lastHeal?.at)
var lastLogged: ProbeVerdict?

log("시작 — status-file=\(options.statusFile.path) interval=\(options.interval)s autoHeal=\(options.autoHeal)")
if options.gatewayLabel == options.selfLabel {
    log("경고: --gateway-label 이 자기 레이블(\(options.selfLabel))이라 무시하고 자동 탐색합니다")
}

while true {
    var verdict = Probe.probe()

    if options.autoHeal {
        tracker.record(verdict)
        let now = Date()
        if tracker.isHealDue(now: now) {
            let label = Launchd.gatewayLabel(
                explicit: options.gatewayLabel, selfLabel: options.selfLabel,
                in: Launchd.userLaunchAgentsDir)
            let ok = Launchd.kickstart(label: label)
            tracker.markHealed(at: now)
            lastHeal = HealRecord(at: now, ok: ok, reason: verdict.healthName)
            log("복구 시도 — \(label) kickstart \(ok ? "성공" : "실패") (원인: \(describe(verdict)))")

            Thread.sleep(forTimeInterval: postHealSettle)
            verdict = Probe.probe()
            // Counted like any probe (as the app's post-heal refresh is); the
            // cooldown just set keeps it from triggering another heal.
            tracker.record(verdict)
        }
    }

    let status = AgentStatus(
        checkedAt: Date(), verdict: verdict, intervalSeconds: options.interval,
        autoHeal: options.autoHeal, lastHeal: lastHeal)
    do {
        try StatusFile.write(status, to: options.statusFile)
    } catch {
        log("상태 파일 쓰기 실패 — \(error.localizedDescription)")
    }

    if verdict != lastLogged {
        log("상태: \(describe(verdict))")
        lastLogged = verdict
    }

    Thread.sleep(forTimeInterval: TimeInterval(options.interval))
}
