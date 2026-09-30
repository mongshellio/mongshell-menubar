import Foundation

// Tests for the menubar app's openclaw status client (Decision #25) and the
// server host signals read from the same document (Decision #31).
//
// Each case pins a rule whose mutation would change what a dot says: the
// wire keys shared with the server agent, the unreachable threshold, the
// grey-vs-red split, URL validation, when a server heal is announced, the
// clock text shown next to it, and how the host signals are read and worded.
//
// Run with `./scripts/test.sh`, which compiles this against the real app
// sources *and* the agent's `Probe.swift` / `HostProbe.swift` /
// `StatusFile.swift`, so the round-trip cases encode with the agent's actual
// encoder.

var failures: [String] = []
var caseCount = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    caseCount += 1
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

func parse(_ json: String) -> Result<OpenClawStatus, OpenClawStatusError> {
    do { return .success(try OpenClawStatusClient.parse(data: Data(json.utf8))) }
    catch { return .failure(error) }
}

func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

func reading(checkedSecondsAgo age: TimeInterval, interval: Int? = 60, now: Date,
             health: OpenClawHealth = .ok(detail: "Telegram default"),
             host: ServerHost? = nil) -> OpenClawReading {
    var r = OpenClawReading()
    r.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-age), health: health,
                                   intervalSeconds: interval, autoHeal: true, lastHeal: nil,
                                   host: host),
                    receivedAt: now)
    return r
}

// Whole seconds: the agent's ISO-8601 encoding drops fractions.
let now = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - 왕복 (에이전트 인코더 → 앱 파서)

print("▸ 에이전트 StatusFile 왕복")
do {
    let heal = HealRecord(at: now.addingTimeInterval(-600), ok: false, reason: "down")
    let status = AgentStatus(checkedAt: now.addingTimeInterval(-5),
                             verdict: .degraded(detail: "Telegram default"),
                             intervalSeconds: 120, autoHeal: false, lastHeal: heal, host: nil)
    let data = try! StatusFile.encode(status)
    switch Result(catching: { try OpenClawStatusClient.parse(data: data) }) {
    case .success(let s):
        check("checkedAt 왕복", s.checkedAt == now.addingTimeInterval(-5), "\(s.checkedAt)")
        check("health·detail 왕복", s.health == .degraded(detail: "Telegram default"), "\(s.health)")
        check("intervalSeconds 왕복", s.intervalSeconds == 120)
        check("autoHeal 왕복", s.autoHeal == false)
        check("lastHeal 왕복",
              s.lastHeal == OpenClawHealEvent(at: heal.at, ok: false, reason: "down"),
              "\(String(describing: s.lastHeal))")
    case .failure(let e):
        check("에이전트 문서 파싱", false, "\(e)")
    }

    let okData = try! StatusFile.encode(AgentStatus(
        checkedAt: now, verdict: .ok(detail: "Slack main"), intervalSeconds: 60,
        autoHeal: true, lastHeal: nil, host: nil))
    let okStatus = try? OpenClawStatusClient.parse(data: okData)
    check("ok + lastHeal null 왕복",
          okStatus?.health == .ok(detail: "Slack main") && okStatus?.lastHeal == nil)

    let downData = try! StatusFile.encode(AgentStatus(
        checkedAt: now, verdict: .down, intervalSeconds: 60, autoHeal: true, lastHeal: nil,
        host: nil))
    let downHealth = (try? OpenClawStatusClient.parse(data: downData))?.health
    check("down(detail null) 왕복", downHealth == .down(detail: ""), "\(String(describing: downHealth))")
    check("down detail 없음 → 표시 문구는 라벨만",
          downHealth?.detailText == nil && downHealth?.settingsLabel == "게이트웨이 다운",
          "\(String(describing: downHealth?.settingsLabel))")

    // The agent reports a missing binary as `down` + a reason; the reason must
    // reach the popover, or the operator can't tell it from a crashed gateway.
    let missingData = try! StatusFile.encode(AgentStatus(
        checkedAt: now, verdict: .notInstalled, intervalSeconds: 60, autoHeal: true, lastHeal: nil,
        host: nil))
    let missing = (try? OpenClawStatusClient.parse(data: missingData))?.health
    check("down + detail 왕복 (바이너리 없음)",
          missing == .down(detail: "openclaw 바이너리 없음")
              && missing?.detailText == "openclaw 바이너리 없음"
              && missing?.settingsLabel == "게이트웨이 다운 — openclaw 바이너리 없음",
          "\(String(describing: missing))")
    check("down + detail 도 빨강·같은 라벨",
          missing?.dotColor == OpenClawHealth.down(detail: "").dotColor
              && missing?.shortLabel == OpenClawHealth.down(detail: "").shortLabel)
}

// MARK: - 관대한 디코딩

print("▸ 관대한 디코딩")
do {
    let base = #""checkedAt":"\#(iso(now))","intervalSeconds":60"#

    if case .failure(let e) = parse(#"{"schema":1,"health":"ok","detail":"x"}"#) {
        check("checkedAt 누락 → missingCheckedAt", e == .missingCheckedAt, "\(e)")
    } else { check("checkedAt 누락 → 실패", false) }
    if case .failure(let e) = parse(#"{"checkedAt":"어제쯤","health":"ok"}"#) {
        check("checkedAt 해석 불가 → missingCheckedAt", e == .missingCheckedAt, "\(e)")
    } else { check("checkedAt 해석 불가 → 실패", false) }

    var r = OpenClawReading()
    r.recordFailure(.missingCheckedAt)
    check("checkedAt 누락 → unreachable",
          r.health(now: now) == .unreachable(detail: "상태 파일에 확인 시각이 없습니다"),
          "\(r.health(now: now))")

    let weird = try? parse(#"{\#(base),"health":"rebooting"}"#).get()
    check("모르는 health → degraded",
          weird?.health == .degraded(detail: "알 수 없는 상태: rebooting"),
          "\(String(describing: weird?.health))")

    let future = try? parse(#"{"schema":2,\#(base),"health":"ok","detail":"d","newKey":{"a":1}}"#).get()
    check("schema 2 + 모르는 키도 읽힘", future?.health == .ok(detail: "d"),
          "\(String(describing: future))")

    let boolInterval = try? parse(#"{"checkedAt":"\#(iso(now))","health":"ok","intervalSeconds":true}"#).get()
    check("intervalSeconds 가 bool → 누락 취급", boolInterval != nil && boolInterval?.intervalSeconds == nil,
          "\(String(describing: boolInterval?.intervalSeconds))")

    if case .failure(let e) = parse("[1,2]") {
        check("객체가 아닌 JSON → badResponse", e == .badResponse)
    } else { check("객체가 아닌 JSON → 실패", false) }

}

// MARK: - 원격 문자열·응답 크기

print("▸ 원격 문자열 정화 · 응답 크기")
do {
    func detail(_ raw: String, health: String = "ok") -> String? {
        let doc: [String: Any] = ["checkedAt": iso(now), "health": health, "detail": raw]
        let data = try! JSONSerialization.data(withJSONObject: doc)
        return (try? OpenClawStatusClient.parse(data: data))?.health.detailText
    }
    check("detail 개행·제어문자 → 공백",
          detail("a\nb\tc\u{7}d\r\n") == "a b c d", "\(String(describing: detail("a\nb\tc\u{7}d\r\n")))")
    let long = detail(String(repeating: "가", count: 500))
    check("detail 120자로 자름", long?.count == OpenClawStatusClient.detailDisplayLimit,
          "\(String(describing: long?.count))")
    let separators = detail("a\u{2028}b\u{2029}c\u{85}d")
    check("detail U+2028/2029·NEL → 공백", separators == "a b c d", "\(String(describing: separators))")
    // One character with 50 combining marks: short in characters, not in scalars.
    let zalgo = detail(String(repeating: "a" + String(repeating: "\u{0301}", count: 50), count: 20))
    let zalgoScalars = zalgo?.unicodeScalars.count ?? .max
    check("detail 결합 문자 누적 → 스칼라 480 이하, 글자 단위로 자름",
          zalgoScalars <= OpenClawStatusClient.displayScalarLimit && zalgo?.count == 9,
          "\(zalgoScalars) scalars, \(String(describing: zalgo?.count)) chars")
    let downDetail = detail("바이너리\n없음\t" + String(repeating: "가", count: 500), health: "down")
    check("down detail 도 한 줄·120자로 정화",
          downDetail?.hasPrefix("바이너리 없음") == true && downDetail?.contains("\n") == false
              && downDetail?.count == OpenClawStatusClient.detailDisplayLimit,
          "\(String(describing: downDetail?.prefix(12))), \(String(describing: downDetail?.count))")
    let odd = detail("", health: "re\nbooting")
    check("모르는 health 도 한 줄로", odd == "알 수 없는 상태: re booting", "\(String(describing: odd))")

    check("64KB 정확히 → 허용", !OpenClawStatusClient.exceedsSizeLimit(64 * 1024))
    check("64KB + 1 → 초과", OpenClawStatusClient.exceedsSizeLimit(64 * 1024 + 1))
    check("길이 모름(-1) → 스트리밍으로 판정", !OpenClawStatusClient.exceedsSizeLimit(-1))
}

// MARK: - HTTP

print("▸ HTTP 상태 코드")
do {
    func interpret(_ code: Int) -> OpenClawStatusError? {
        do { _ = try OpenClawStatusClient.interpret(statusCode: code, data: Data()); return nil }
        catch { return error }
    }
    check("404 → notFound", interpret(404) == .notFound)
    var r = OpenClawReading()
    r.recordFailure(.notFound)
    check("404 → unreachable + 토큰 문구",
          r.health(now: now) == .unreachable(detail: "주소 또는 토큰이 맞지 않습니다"))
    check("500 → http(500)", interpret(500) == .http(500))
    check("302(리다이렉트 거부 결과) → http(302)", interpret(302) == .http(302))
    // Non-200 bodies are never read, so a large error page can't hit the size
    // cap and hide its status code (404 → token hint) behind badResponse.
    check("200 만 본문 읽음", OpenClawStatusClient.readsBody(statusCode: 200))
    check("404·500 은 본문 안 읽음",
          !OpenClawStatusClient.readsBody(statusCode: 404) && !OpenClawStatusClient.readsBody(statusCode: 500))

    check("URLError.cancelled → cancelled", OpenClawStatusError.transport(.cancelled) == .cancelled)
    check("URLError.timedOut → timedOut", OpenClawStatusError.transport(.timedOut) == .timedOut)
    check("오프라인 → offline", OpenClawStatusError.transport(.notConnectedToInternet) == .offline)
    check("그 밖의 전송 오류 → network", OpenClawStatusError.transport(.cannotFindHost) == .network)
    var cancelled = OpenClawReading()
    cancelled.recordFailure(.cancelled)
    check("취소는 실패로 기록하지 않음", cancelled.health(now: now) == .unknown,
          "\(cancelled.health(now: now))")
}

// MARK: - 연락 두절 판정

print("▸ 연락 두절 판정")
do {
    let fresh = reading(checkedSecondsAgo: 60, now: now).health(now: now)
    check("60초 전 → 정상", fresh == .ok(detail: "Telegram default"), "\(fresh)")

    check("180초 정각 → 아직 정상 (경계 포함)",
          reading(checkedSecondsAgo: 180, now: now).health(now: now) == .ok(detail: "Telegram default"))
    let stale = reading(checkedSecondsAgo: 181, now: now).health(now: now)
    if case .unreachable = stale { check("181초 전 → unreachable", true) }
    else { check("181초 전 → unreachable", false, "\(stale)") }

    let skew = reading(checkedSecondsAgo: -600, now: now).health(now: now)
    check("미래 시각 → 정상 (나이 0)", skew == .ok(detail: "Telegram default"), "\(skew)")

    // Server clock ahead: the same future checkedAt re-read later must age from
    // when we first saw it, or a dead agent stays green for the whole skew.
    var ahead = reading(checkedSecondsAgo: -3600, now: now)
    let sameDoc = ahead.lastSuccess!
    ahead.recordSuccess(sameDoc, receivedAt: now.addingTimeInterval(181))
    check("미래 checkedAt 재수신 → 첫 수신 시각 기준으로 두절",
          ahead.lastCheckedAt == now && ahead.health(now: now.addingTimeInterval(181)) != sameDoc.health,
          "\(String(describing: ahead.lastCheckedAt))")

    check("interval 120 → 임계 360초", OpenClawReading.staleAfter(intervalSeconds: 120) == 360)
    check("interval 120, 359초 전 → 정상",
          reading(checkedSecondsAgo: 359, interval: 120, now: now).health(now: now)
              == .ok(detail: "Telegram default"))
    if case .unreachable = reading(checkedSecondsAgo: 361, interval: 120, now: now).health(now: now) {
        check("interval 120, 361초 전 → unreachable", true)
    } else { check("interval 120, 361초 전 → unreachable", false) }
    check("interval 누락 → 임계 180초", OpenClawReading.staleAfter(intervalSeconds: nil) == 180)

    let down = reading(checkedSecondsAgo: 10, now: now, health: .down(detail: "")).health(now: now)
    check("서버가 down 보고 → down (빨강)", down == .down(detail: ""))
    var gone = OpenClawReading()
    gone.recordFailure(.offline)
    let offline = gone.health(now: now)
    check("응답 없음 → down 이 아니라 unreachable",
          offline == .unreachable(detail: "네트워크 연결 없음"), "\(offline)")
    check("unreachable 은 빨강이 아님",
          OpenClawHealth.unreachable(detail: "").dotColor != OpenClawHealth.down(detail: "").dotColor)

    var blip = reading(checkedSecondsAgo: 30, now: now)
    blip.recordFailure(.timedOut)
    check("일시 실패 + 신선한 마지막 성공 → 상태 유지",
          blip.health(now: now) == .ok(detail: "Telegram default"), "\(blip.health(now: now))")
    let later = blip.health(now: now.addingTimeInterval(200))
    check("실패가 이어져 오래되면 → unreachable(실패 이유)",
          later == .unreachable(detail: "응답 시간 초과"), "\(later)")

    check("응답 전 → unknown", OpenClawReading().health(now: now) == .unknown)

    var overlap = reading(checkedSecondsAgo: 10, now: now, health: .down(detail: ""))
    overlap.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-70), health: .ok(detail: "old"),
                                         intervalSeconds: 60, autoHeal: true, lastHeal: nil,
                                         host: nil),
                          receivedAt: now)
    check("늦게 도착한 옛 응답 → 상태 역행 없음", overlap.health(now: now) == .down(detail: ""),
          "\(overlap.health(now: now))")

    // Server clock set back: a step back beyond the stale threshold can't be
    // a late reply, so it becomes the new baseline instead of being dropped
    // until the clock catches up.
    var smallStep = reading(checkedSecondsAgo: 0, now: now, health: .down(detail: ""))
    let kept = smallStep.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-180),
                                                      health: .ok(detail: "old"), intervalSeconds: 60,
                                                      autoHeal: true, lastHeal: nil, host: nil),
                                       receivedAt: now)
    check("임계(180초) 이내 역행 → 무시", !kept && smallStep.health(now: now) == .down(detail: ""),
          "\(smallStep.health(now: now))")
    var clockBack = reading(checkedSecondsAgo: 0, now: now, health: .down(detail: ""))
    clockBack.recordFailure(.timedOut)
    let reset = clockBack.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-3600),
                                                       health: .ok(detail: "new"), intervalSeconds: 60,
                                                       autoHeal: true, lastHeal: nil, host: nil),
                                        receivedAt: now.addingTimeInterval(60))
    check("임계 넘는 역행 → 새 기준으로 수용 (실패 이유 해제)",
          reset && clockBack.lastFailure == nil && clockBack.lastCheckedAt == now.addingTimeInterval(-3600)
              && clockBack.health(now: now.addingTimeInterval(-3600)) == .ok(detail: "new"),
          "\(String(describing: clockBack.lastCheckedAt))")
    let next = clockBack.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-3540),
                                                      health: .ok(detail: "next"), intervalSeconds: 60,
                                                      autoHeal: true, lastHeal: nil, host: nil),
                                       receivedAt: now.addingTimeInterval(120))
    check("재기준 후 다음 응답 → 정상 갱신",
          !next && clockBack.lastSuccess?.health == .ok(detail: "next"))
}

// MARK: - URL 검증

print("▸ URL 검증")
do {
    func validate(_ raw: String) -> Result<URL?, OpenClawURLError> {
        do { return .success(try OpenClawStatusClient.validatedURL(raw)) } catch { return .failure(error) }
    }
    let token = "0123456789abcdef0123456789abcdef"
    if case .success(let url?) = validate("  https://srv.example.ts.net:8443/\(token)\n") {
        check("https 허용 + 공백 제거", url.absoluteString == "https://srv.example.ts.net:8443/\(token)")
    } else { check("https 허용", false) }
    check("http:// 거부", validate("http://srv.example.ts.net:8443/\(token)") == .failure(.notHTTPS))
    check("빈 URL → nil (미설정)", validate("   ") == .success(nil))
    check("호스트 없음 거부", validate("https:///x") == .failure(.malformed))
    check("userinfo 거부", validate("https://u:p@h/x") == .failure(.malformed))
    check("tailnet 처럼 보이는 userinfo 거부", validate("https://a.ts.net@evil.com/x") == .failure(.malformed))
}

// MARK: - 자동복구 알림 판정

print("▸ 자동복구 알림 판정")
do {
    let h1 = OpenClawHealEvent(at: now.addingTimeInterval(-3600), ok: true, reason: "down")
    let h2 = OpenClawHealEvent(at: now.addingTimeInterval(-60), ok: false, reason: "degraded")
    var watch = OpenClawHealWatch()
    check("첫 응답은 기준점 — 알림 없음", watch.observe(h1) == nil)
    check("같은 시각 재수신 — 알림 없음", watch.observe(h1) == nil)
    check("lastHeal.at 변경 — 알림", watch.observe(h2) == h2)
    check("변경 후 재수신 — 알림 없음", watch.observe(h2) == nil)
    check("lastHeal 사라짐 — 알림 없음", watch.observe(nil) == nil)
    check("사라졌다 같은 값 복귀 — 알림 없음", watch.observe(h2) == nil)

    var empty = OpenClawHealWatch()
    check("첫 응답 lastHeal null — 알림 없음", empty.observe(nil) == nil)
    check("그 뒤 첫 복구 — 알림", empty.observe(h1) == h1)

    var late = OpenClawHealWatch()
    _ = late.observe(nil)
    check("새 복구 — 알림", late.observe(h2) == h2)
    check("옛 복구가 늦게 도착 — 알림 없음", late.observe(h1) == nil)
    check("그 뒤 최신 복구 재수신 — 알림 없음", late.observe(h2) == nil)

    // Server clock set back: heals on the new clock are all "older" than h2.
    let h3 = OpenClawHealEvent(at: now.addingTimeInterval(-7200), ok: true, reason: "down")
    let h4 = OpenClawHealEvent(at: now.addingTimeInterval(-7100), ok: true, reason: "down")
    late.resetBaseline()
    check("시계 역행 후 재기준 — 알림 없음", late.observe(h3) == nil)
    check("재기준 뒤 새 복구 — 알림", late.observe(h4) == h4)
}

// MARK: - 서버 호스트 (Decision #31)

print("▸ 서버 호스트 왕복 (에이전트 인코더 → 앱 파서)")
do {
    func roundTrip(_ host: HostStatus?) -> OpenClawStatus? {
        let data = try! StatusFile.encode(AgentStatus(
            checkedAt: now, verdict: .ok(detail: "Telegram default"), intervalSeconds: 60,
            autoHeal: true, lastHeal: nil, host: host))
        return try? OpenClawStatusClient.parse(data: data)
    }

    let onBattery = roundTrip(HostRules.judge(
        power: PowerReading(pluggedIn: false, charging: false, batteryPercent: 82),
        disk: DiskReading(availableBytes: 32_604_813_672)))
    check("배터리 있음 왕복",
          onBattery?.host == ServerHost(
              level: .warning,
              power: ServerHostPower(level: .warning, pluggedIn: false, charging: false,
                                     batteryPercent: 82),
              disk: ServerHostDisk(level: .ok, availableBytes: 32_604_813_672)),
          "\(String(describing: onBattery?.host))")

    let noBattery = roundTrip(HostRules.judge(
        power: nil, disk: DiskReading(availableBytes: 4_200_000_000)))
    check("power null 왕복 (배터리 없는 서버)",
          noBattery?.host == ServerHost(
              level: .critical, power: nil,
              disk: ServerHostDisk(level: .critical, availableBytes: 4_200_000_000)),
          "\(String(describing: noBattery?.host))")

    let unknownCharge = roundTrip(HostRules.judge(
        power: PowerReading(pluggedIn: true, charging: true, batteryPercent: nil), disk: nil))
    check("batteryPercent null·disk null 왕복",
          unknownCharge?.host == ServerHost(
              level: .ok,
              power: ServerHostPower(level: .ok, pluggedIn: true, charging: true,
                                     batteryPercent: nil),
              disk: nil),
          "\(String(describing: unknownCharge?.host))")

    let none = roundTrip(nil)
    check("host null 왕복 → host 없음, openclaw 판정은 그대로",
          none != nil && none?.host == nil && none?.health == .ok(detail: "Telegram default"),
          "\(String(describing: none))")
}

print("▸ 서버 호스트 관대한 디코딩")
do {
    let base = #""checkedAt":"\#(iso(now))","health":"down","intervalSeconds":60"#
    func status(host: String?) -> OpenClawStatus? {
        try? parse("{\(base)\(host.map { #","host":\#($0)"# } ?? "")}").get()
    }
    let disk = #""disk":{"health":"ok","availableBytes":32000000000}"#
    let okDisk = ServerHostDisk(level: .ok, availableBytes: 32_000_000_000)

    for (label, host) in [("키 없음 (구버전 에이전트)", nil), ("null", "null"),
                          ("문자열", #""ok""#), ("배열", "[1]"), ("빈 객체", "{}")] as [(String, String?)] {
        let s = status(host: host)
        check("host \(label) → host 없음, openclaw 판정은 그대로",
              s != nil && s?.host == nil && s?.health == .down(detail: ""),
              "\(String(describing: s))")
    }

    let strange = status(host: #"{"health":"meltdown","disk":{"health":"smoking","availableBytes":1}}"#)
    check("모르는 레벨 문자열 → warning (초록 아님)",
          strange?.host?.level == .warning && strange?.host?.disk?.level == .warning,
          "\(String(describing: strange?.host))")

    let noOverall = status(host: #"{"power":{"health":"critical","pluggedIn":false},\#(disk)}"#)
    check("host.health 없음 → 신호 중 최악", noOverall?.host?.level == .critical,
          "\(String(describing: noOverall?.host))")
    let noSignalLevel = status(host: #"{"health":"ok","disk":{"availableBytes":32000000000}}"#)
    check("신호의 health 없음 → warning (초록 아님)", noSignalLevel?.host?.disk?.level == .warning,
          "\(String(describing: noSignalLevel?.host))")

    // A verdict that is there but isn't a string is still a verdict we can't
    // read — it must not fall through to the (green) signals next to it.
    for (label, value) in [("수", "3"), ("객체", #"{"level":"ok"}"#), ("배열", #"["ok"]"#),
                           ("bool", "true")] {
        let s = status(host: #"{"health":\#(value),\#(disk)}"#)
        check("host.health 가 \(label) → warning (초록 아님), 신호는 그대로",
              s?.host == ServerHost(level: .warning, power: nil, disk: okDisk),
              "\(String(describing: s?.host))")
    }
    let nullOverall = status(
        host: #"{"health":null,"power":{"health":"critical","pluggedIn":false},\#(disk)}"#)
    check("host.health null → 신호 중 최악 (키 없음과 같음)", nullOverall?.host?.level == .critical,
          "\(String(describing: nullOverall?.host))")
    let oddSignals = status(host: #"{"health":"ok","power":{"health":3},"#
        + #""disk":{"health":{"level":"ok"},"availableBytes":32000000000}}"#)
    check("신호의 health 가 문자열 아님 → warning (초록 아님)",
          oddSignals?.host?.power == ServerHostPower(level: .warning, pluggedIn: nil, charging: nil,
                                                     batteryPercent: nil)
              && oddSignals?.host?.disk?.level == .warning,
          "\(String(describing: oddSignals?.host))")
    let nullSignal = status(host: #"{"health":"ok","power":{"health":null},\#(disk)}"#)
    check("신호의 health null 뿐 → 그 신호 없음",
          nullSignal?.host == ServerHost(level: .ok, power: nil, disk: okDisk),
          "\(String(describing: nullSignal?.host))")

    func power(_ fields: String) -> ServerHostPower? {
        status(host: #"{"health":"warning","power":{"health":"warning",\#(fields)},\#(disk)}"#)?
            .host?.power
    }
    check("batteryPercent 정상값", power(#""batteryPercent":82"#)?.batteryPercent == 82)
    check("batteryPercent 경계 0·100 허용",
          power(#""batteryPercent":0"#)?.batteryPercent == 0
              && power(#""batteryPercent":100"#)?.batteryPercent == 100)
    for bad in ["true", "150", "-1", #""82""#, "null"] {
        let p = power(#""pluggedIn":false,"batteryPercent":\#(bad)"#)
        check("batteryPercent \(bad) → nil, 나머지는 유지",
              p != nil && p?.batteryPercent == nil && p?.pluggedIn == false && p?.level == .warning,
              "\(String(describing: p))")
    }
    let notBools = power(#""pluggedIn":1,"charging":"yes","batteryPercent":82"#)
    check("pluggedIn·charging 이 Bool 아님 → nil",
          notBools?.pluggedIn == nil && notBools?.charging == nil && notBools?.batteryPercent == 82,
          "\(String(describing: notBools))")

    for bad in ["-1", "true", #""many""#, "null", "1e30"] {
        let s = status(host: #"{"health":"ok","disk":{"health":"ok","availableBytes":\#(bad)}}"#)
        check("availableBytes \(bad) → disk 없음", s?.host != nil && s?.host?.disk == nil,
              "\(String(describing: s?.host))")
    }
    check("availableBytes 0 은 실제 값 (가득 참)",
          status(host: #"{"health":"critical","disk":{"health":"critical","availableBytes":0}}"#)?
              .host?.disk == ServerHostDisk(level: .critical, availableBytes: 0))
    check("정상 disk 는 그대로", status(host: "{\(disk)}")?.host
              == ServerHost(level: .ok, power: nil, disk: okDisk))
}

print("▸ 서버 호스트 신선도 공유")
do {
    let host = ServerHost(level: .ok, power: nil,
                          disk: ServerHostDisk(level: .ok, availableBytes: 32_000_000_000))
    check("성공 응답 없음 → absent", OpenClawReading().hostHealth(now: now) == .absent)
    var failed = OpenClawReading()
    failed.recordFailure(.offline)
    check("실패만 있음 → absent (회색 점 없음)", failed.hostHealth(now: now) == .absent)

    check("신선 + host → reported",
          reading(checkedSecondsAgo: 60, now: now, host: host).hostHealth(now: now) == .reported(host))
    check("180초 정각 → 아직 reported (openclaw 와 같은 경계)",
          reading(checkedSecondsAgo: 180, now: now, host: host).hostHealth(now: now) == .reported(host))
    check("181초 전 → unreachable(마지막 값)",
          reading(checkedSecondsAgo: 181, now: now, host: host).hostHealth(now: now)
              == .unreachable(last: host))
    check("interval 120, 359초 전 → reported",
          reading(checkedSecondsAgo: 359, interval: 120, now: now, host: host).hostHealth(now: now)
              == .reported(host))

    check("신선 + host 없음 → absent",
          reading(checkedSecondsAgo: 60, now: now).hostHealth(now: now) == .absent)
    check("오래됨 + host 없었음 → absent",
          reading(checkedSecondsAgo: 181, now: now).hostHealth(now: now) == .absent)

    let split = reading(checkedSecondsAgo: 10, now: now, health: .down(detail: ""), host: host)
    check("openclaw down + host ok → 두 점 독립",
          split.health(now: now) == .down(detail: "") && split.hostHealth(now: now) == .reported(host)
              && split.health(now: now).dotColor != split.hostHealth(now: now).dotColor)
    let critical = ServerHost(level: .critical, power: nil,
                              disk: ServerHostDisk(level: .critical, availableBytes: 1))
    let reverse = reading(checkedSecondsAgo: 10, now: now, host: critical)
    check("openclaw ok + host critical → 두 점 독립",
          reverse.health(now: now) == .ok(detail: "Telegram default")
              && reverse.hostHealth(now: now) == .reported(critical))
}

print("▸ 서버 호스트 표시")
do {
    func power(_ level: ServerHostLevel, pluggedIn: Bool? = false, charging: Bool? = false,
               percent: Int? = 82) -> ServerHostPower {
        ServerHostPower(level: level, pluggedIn: pluggedIn, charging: charging, batteryPercent: percent)
    }
    func disk(_ level: ServerHostLevel, bytes: Int64 = 32_000_000_000) -> ServerHostDisk {
        ServerHostDisk(level: level, availableBytes: bytes)
    }
    func label(_ level: ServerHostLevel, _ p: ServerHostPower?, _ d: ServerHostDisk?) -> String {
        ServerHostHealth.reported(ServerHost(level: level, power: p, disk: d)).shortLabel
    }
    check("모두 ok → 정상", label(.ok, power(.ok, pluggedIn: true), disk(.ok)) == "정상")
    check("전원 warning → 어댑터 분리", label(.warning, power(.warning), disk(.ok)) == "어댑터 분리")
    check("전원 critical → 배터리 부족", label(.critical, power(.critical), disk(.ok)) == "배터리 부족")
    check("디스크 warning → 디스크 여유 부족",
          label(.warning, power(.ok, pluggedIn: true), disk(.warning)) == "디스크 여유 부족")
    check("디스크 critical → 디스크 거의 가득", label(.critical, nil, disk(.critical)) == "디스크 거의 가득")
    check("둘 다 나쁨 → 더 심각한 쪽 (디스크)",
          label(.critical, power(.warning), disk(.critical)) == "디스크 거의 가득")
    check("둘 다 나쁨 → 더 심각한 쪽 (전원)",
          label(.critical, power(.critical), disk(.warning)) == "배터리 부족")
    check("같은 레벨 → 전원", label(.warning, power(.warning), disk(.warning)) == "어댑터 분리")
    // The cause words are only true of a server known to run on battery. A
    // level the app folded to warning next to "충전 중" must not claim one.
    check("전원 warning 인데 어댑터 연결 → 전원 주의",
          label(.warning, power(.warning, pluggedIn: true, charging: true), disk(.ok)) == "전원 주의",
          label(.warning, power(.warning, pluggedIn: true, charging: true), disk(.ok)))
    check("전원 warning, pluggedIn 불명 → 전원 주의",
          label(.warning, power(.warning, pluggedIn: nil), disk(.ok)) == "전원 주의")
    check("전원 critical 인데 어댑터 연결·불명 → 전원 위험",
          label(.critical, power(.critical, pluggedIn: true), disk(.ok)) == "전원 위험"
              && label(.critical, power(.critical, pluggedIn: nil), disk(.ok)) == "전원 위험")
    check("아는 신호가 설명하지 못하는 레벨 → 레벨만",
          label(.warning, power(.ok, pluggedIn: true), disk(.ok)) == "주의"
              && label(.critical, nil, disk(.ok)) == "위험")

    let last = ServerHost(level: .critical, power: nil, disk: disk(.critical))
    let lost = ServerHostHealth.unreachable(last: last)
    check("두절 → 서버 연락 두절·회색, 마지막 값 유지",
          lost.shortLabel == "서버 연락 두절" && lost.dotColor == Palette.textTertiary && lost.host == last)
    check("absent → 점 없음", ServerHostHealth.absent.dotColor == nil && ServerHostHealth.absent.host == nil)
    check("레벨 색 (ok 초록·warning 주황·critical 빨강)",
          ServerHostHealth.reported(ServerHost(level: .ok, power: nil, disk: nil)).dotColor == Palette.green
              && ServerHostHealth.reported(ServerHost(level: .warning, power: nil, disk: nil)).dotColor
                  == Palette.amber
              && ServerHostHealth.reported(last).dotColor == Palette.red)

    check("전원 줄: 방전 중", power(.warning).lineText == "배터리 82% · 방전 중")
    check("전원 줄: 어댑터 연결",
          power(.ok, pluggedIn: true, percent: 100).lineText == "배터리 100% · 어댑터 연결")
    check("전원 줄: 충전 중",
          power(.ok, pluggedIn: true, charging: true, percent: 64).lineText == "배터리 64% · 충전 중")
    check("전원 줄: 잔량 불명 → 퍼센트 생략", power(.warning, percent: nil).lineText == "배터리 · 방전 중",
          "\(String(describing: power(.warning, percent: nil).lineText))")
    check("전원 줄: pluggedIn 불명 → 전원 상태 생략",
          power(.warning, pluggedIn: nil, charging: true).lineText == "배터리 82%")
    check("전원 줄: 어댑터 분리가 charging 보다 우선",
          power(.warning, pluggedIn: false, charging: true).lineText == "배터리 82% · 방전 중")
    check("전원 줄: 아는 것이 없음 → 줄 없음",
          power(.warning, pluggedIn: nil, charging: nil, percent: nil).lineText == nil)
    check("디스크 줄", disk(.ok, bytes: 32_604_813_672).lineText == "디스크 여유 32GB")

    check("바이트: 10GB 이상은 정수 내림", ServerHostText.bytes(32_999_999_999) == "32GB")
    check("바이트: 10GB 정각 → 10GB", ServerHostText.bytes(10_000_000_000) == "10GB")
    check("바이트: 10GB 바로 아래 → 9.9GB (올림 없음)", ServerHostText.bytes(9_999_999_999) == "9.9GB",
          ServerHostText.bytes(9_999_999_999))
    check("바이트: 소수 1자리 내림", ServerHostText.bytes(4_290_000_000) == "4.2GB")
    check("바이트: 1GB 정각 → 1.0GB", ServerHostText.bytes(1_000_000_000) == "1.0GB")
    check("바이트: 1GB 바로 아래 → MB", ServerHostText.bytes(999_999_999) == "999MB")
    check("바이트: MB 내림", ServerHostText.bytes(850_900_000) == "850MB")
    check("바이트: 0", ServerHostText.bytes(0) == "0MB")
}

// MARK: - 서버 호스트 알림 판정

extension ServerHostAlertWatch {
    /// The notification gate open — every case but the ones about the gate.
    mutating func observe(_ host: ServerHost?, now: Date) -> [ServerHostAlert] {
        observe(host, now: now, canNotify: true)
    }
}

print("▸ 서버 호스트 알림 판정")
do {
    func host(power: ServerHostLevel?, disk: ServerHostLevel?, percent: Int? = 82,
              bytes: Int64 = 18_000_000_000) -> ServerHost {
        ServerHost(
            level: max(power ?? .ok, disk ?? .ok),
            power: power.map { ServerHostPower(level: $0, pluggedIn: $0 == .ok, charging: false,
                                               batteryPercent: percent) },
            disk: disk.map { ServerHostDisk(level: $0, availableBytes: bytes) })
    }
    func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    func levels(_ alerts: [ServerHostAlert]) -> [String] {
        alerts.map {
            switch $0 {
            case .power(let p): return "power:\(p.level)"
            case .disk(let d):  return "disk:\(d.level)"
            }
        }
    }
    let cooldown = ServerHostAlertWatch.repeatCooldown
    check("쿨다운은 3600초", cooldown == 3600)

    var started = ServerHostAlertWatch()
    check("첫 관측은 기준점 — 이미 나쁜 상태여도 알림 없음",
          started.observe(host(power: .critical, disk: .warning), now: at(0)).isEmpty)
    check("기준점 뒤 같은 레벨 — 알림 없음",
          started.observe(host(power: .critical, disk: .warning), now: at(60)).isEmpty)
    check("기준점(warning) 뒤 상승 — 알림",
          levels(started.observe(host(power: .critical, disk: .critical), now: at(120)))
              == ["disk:critical"])

    var watch = ServerHostAlertWatch()
    _ = watch.observe(host(power: .ok, disk: .ok), now: at(0))
    let unplugged = watch.observe(host(power: .warning, disk: .ok), now: at(60))
    check("상승 — 알림, 수치 포함",
          unplugged == [.power(ServerHostPower(level: .warning, pluggedIn: false, charging: false,
                                               batteryPercent: 82))],
          "\(unplugged)")
    check("같은 레벨 유지 — 알림 없음",
          watch.observe(host(power: .warning, disk: .ok), now: at(120)).isEmpty)
    check("회복 — 알림 없음", watch.observe(host(power: .ok, disk: .ok), now: at(180)).isEmpty)
    check("출렁임: 쿨다운 안의 같은 레벨 재상승 — 알림 없음",
          watch.observe(host(power: .warning, disk: .ok), now: at(240)).isEmpty)
    check("격상: 쿨다운 안이어도 더 높은 레벨은 즉시",
          levels(watch.observe(host(power: .critical, disk: .ok), now: at(300))) == ["power:critical"])
    _ = watch.observe(host(power: .warning, disk: .ok), now: at(360))
    check("격상 뒤 출렁임: 쿨다운 안의 critical 재상승 — 알림 없음",
          watch.observe(host(power: .critical, disk: .ok), now: at(420)).isEmpty)
    _ = watch.observe(host(power: .ok, disk: .ok), now: at(480))
    check("쿨다운 만료 직전 (마지막 알림 +3599초) — 알림 없음",
          watch.observe(host(power: .warning, disk: .ok), now: at(300 + cooldown - 1)).isEmpty)
    _ = watch.observe(host(power: .ok, disk: .ok), now: at(300 + cooldown - 1))
    check("쿨다운 만료 (마지막 알림 +3600초) — 다시 알림",
          levels(watch.observe(host(power: .warning, disk: .ok), now: at(300 + cooldown)))
              == ["power:warning"])

    // A rise the cooldown kept quiet is owed, not dropped: the cooldown is
    // there against flapping, not to hide a state that then stays.
    let firstAlertAt: TimeInterval = 60
    func suppressedRise(to level: ServerHostLevel = .warning,
                        after announced: ServerHostLevel = .warning) -> ServerHostAlertWatch {
        var w = ServerHostAlertWatch()
        _ = w.observe(host(power: .ok, disk: .ok), now: at(0))
        _ = w.observe(host(power: announced, disk: .ok), now: at(firstAlertAt))
        _ = w.observe(host(power: .ok, disk: .ok), now: at(120))
        _ = w.observe(host(power: level, disk: .ok), now: at(180))
        return w
    }
    var held = suppressedRise()
    check("지연: 억제 뒤 유지, 쿨다운 만료 직전 — 알림 없음",
          held.observe(host(power: .warning, disk: .ok), now: at(firstAlertAt + cooldown - 1)).isEmpty)
    check("지연: 억제 뒤 유지, 쿨다운 만료 뒤 첫 관측 — 알림",
          levels(held.observe(host(power: .warning, disk: .ok), now: at(firstAlertAt + cooldown)))
              == ["power:warning"])
    check("지연: 알린 뒤 계속 유지 — 반복 없음",
          held.observe(host(power: .warning, disk: .ok), now: at(firstAlertAt + cooldown + 60)).isEmpty
              && held.observe(host(power: .warning, disk: .ok),
                              now: at(firstAlertAt + 2 * cooldown)).isEmpty)

    var recovered = suppressedRise()
    check("지연: 만료 전에 회복 — 알림 없음",
          recovered.observe(host(power: .ok, disk: .ok), now: at(240)).isEmpty
              && recovered.observe(host(power: .ok, disk: .ok),
                                   now: at(firstAlertAt + cooldown)).isEmpty)

    var escalated = suppressedRise()
    check("지연: 억제 중 더 높은 레벨로 상승 — 즉시 알림",
          levels(escalated.observe(host(power: .critical, disk: .ok), now: at(240)))
              == ["power:critical"])
    check("지연: 격상으로 알린 뒤에는 미뤄 둔 알림이 남지 않음",
          escalated.observe(host(power: .critical, disk: .ok),
                            now: at(firstAlertAt + cooldown)).isEmpty)

    var eased = suppressedRise(to: .critical, after: .critical)
    _ = eased.observe(host(power: .warning, disk: .ok), now: at(240))
    check("지연: 미뤄 둔 알림은 만료 시점의 레벨로",
          levels(eased.observe(host(power: .warning, disk: .ok), now: at(firstAlertAt + cooldown)))
              == ["power:warning"])

    // The model feeds the watch `hostHealth.reportedHost`: a stale document
    // (the funnel keeps serving the last file after the agent stops) must not
    // carry an owed alert out while the popover says the server is
    // unreachable. It goes out once the document is fresh again.
    let onBattery = host(power: .warning, disk: .ok)
    let expiry = at(firstAlertAt + cooldown)
    let staleDocument = reading(checkedSecondsAgo: 600, now: expiry, host: onBattery)
    let freshDocument = reading(checkedSecondsAgo: 0, now: at(firstAlertAt + cooldown + 60),
                                host: onBattery)
    check("두절 문서의 host 는 감시 입력이 아님 (reportedHost == nil)",
          staleDocument.hostHealth(now: expiry).reportedHost == nil
              && staleDocument.hostHealth(now: expiry) == .unreachable(last: onBattery))
    check("신선한 문서의 host 만 감시 입력",
          freshDocument.hostHealth(now: at(firstAlertAt + cooldown + 60)).reportedHost == onBattery
              && OpenClawReading().hostHealth(now: expiry).reportedHost == nil)
    var stale = suppressedRise()
    check("지연: 두절 중 쿨다운 만료 — 낡은 값으로 알리지 않음",
          stale.observe(staleDocument.hostHealth(now: expiry).reportedHost, now: expiry).isEmpty)
    check("지연: 다시 신선해진 첫 관측(같은 레벨) — 그때 미뤄 둔 알림",
          levels(stale.observe(freshDocument.hostHealth(now: at(firstAlertAt + cooldown + 60)).reportedHost,
                               now: at(firstAlertAt + cooldown + 60))) == ["power:warning"])

    var rewound = ServerHostAlertWatch()
    _ = rewound.observe(host(power: .ok, disk: .ok), now: at(2 * cooldown))
    _ = rewound.observe(host(power: .warning, disk: .ok), now: at(2 * cooldown + 60))
    _ = rewound.observe(host(power: .ok, disk: .ok), now: at(2 * cooldown + 120))
    check("이 맥의 시계가 마지막 알림보다 앞으로 되돌아감 — 쿨다운 만료로 취급",
          levels(rewound.observe(host(power: .warning, disk: .ok), now: at(0))) == ["power:warning"])

    // `Claude만` (or no app bundle): nothing can be shown, so nothing may be
    // counted as announced.
    var gated = ServerHostAlertWatch()
    _ = gated.observe(host(power: .ok, disk: .ok), now: at(0), canNotify: true)
    check("게이트 닫힘: 상승해도 알림 없음",
          gated.observe(host(power: .warning, disk: .ok), now: at(60), canNotify: false).isEmpty)
    _ = gated.observe(host(power: .ok, disk: .ok), now: at(120), canNotify: false)
    check("게이트 열린 뒤 첫 관측은 기준점 — 나쁜 상태여도 알림 없음",
          gated.observe(host(power: .warning, disk: .ok), now: at(180), canNotify: true).isEmpty)
    _ = gated.observe(host(power: .ok, disk: .ok), now: at(240), canNotify: true)
    check("게이트가 닫혀 있던 동안의 상승은 쿨다운을 만들지 않음",
          levels(gated.observe(host(power: .warning, disk: .ok), now: at(300), canNotify: true))
              == ["power:warning"])
    var reopened = suppressedRise()
    _ = reopened.observe(host(power: .warning, disk: .ok), now: at(240), canNotify: false)
    _ = reopened.observe(host(power: .warning, disk: .ok), now: at(300), canNotify: true)
    check("게이트가 닫히면 미뤄 둔 알림도 버림",
          reopened.observe(host(power: .warning, disk: .ok),
                           now: at(firstAlertAt + cooldown), canNotify: true).isEmpty)

    var independent = ServerHostAlertWatch()
    _ = independent.observe(host(power: .ok, disk: .ok), now: at(0))
    _ = independent.observe(host(power: .warning, disk: .ok), now: at(60))
    check("신호별 독립: 전원 알림 직후의 디스크 상승 — 알림",
          levels(independent.observe(host(power: .warning, disk: .warning), now: at(120)))
              == ["disk:warning"])
    _ = independent.observe(host(power: .ok, disk: .ok), now: at(180))
    check("신호별 독립: 두 신호 동시 재상승 — 둘 다 쿨다운",
          independent.observe(host(power: .warning, disk: .warning), now: at(240)).isEmpty)
    _ = independent.observe(host(power: .ok, disk: .ok), now: at(300))
    check("두 신호 동시 상승 — 전원·디스크 순으로 둘 다",
          levels(independent.observe(host(power: .critical, disk: .critical), now: at(360)))
              == ["power:critical", "disk:critical"])

    var gaps = ServerHostAlertWatch()
    _ = gaps.observe(host(power: .warning, disk: .ok), now: at(0))
    check("host 사라짐 — 알림 없음", gaps.observe(nil, now: at(60)).isEmpty)
    check("사라졌다 같은 레벨로 복귀 — 알림 없음",
          gaps.observe(host(power: .warning, disk: .ok), now: at(120)).isEmpty)
    check("신호 하나만 사라짐(power null) — 알림 없음",
          gaps.observe(host(power: nil, disk: .ok), now: at(180)).isEmpty)
    var lateHost = ServerHostAlertWatch()
    _ = lateHost.observe(nil, now: at(0))
    check("host 없이 시작한 뒤 처음 나타난 신호가 나쁨 — 알림",
          levels(lateHost.observe(host(power: nil, disk: .warning), now: at(60))) == ["disk:warning"])

    func alert(power level: ServerHostLevel, percent: Int?) -> ServerHostAlert {
        .power(ServerHostPower(level: level, pluggedIn: false, charging: false, batteryPercent: percent))
    }
    func alert(disk level: ServerHostLevel, bytes: Int64) -> ServerHostAlert {
        .disk(ServerHostDisk(level: level, availableBytes: bytes))
    }
    check("문구: 전원 warning",
          alert(power: .warning, percent: 82).title == "서버 전원 어댑터 분리됨"
              && alert(power: .warning, percent: 82).body == "배터리 82%로 동작 중입니다.")
    check("문구: 전원 critical",
          alert(power: .critical, percent: 18).title == "서버 배터리 부족"
              && alert(power: .critical, percent: 18).body
                  == "배터리 18% — 어댑터를 연결하지 않으면 곧 꺼집니다.")
    check("문구: 잔량 불명",
          alert(power: .warning, percent: nil).body == "배터리로 동작 중입니다."
              && alert(power: .critical, percent: nil).body == "어댑터를 연결하지 않으면 곧 꺼집니다.")
    func alert(power level: ServerHostLevel, pluggedIn: Bool?, charging: Bool?,
               percent: Int?) -> ServerHostAlert {
        .power(ServerHostPower(level: level, pluggedIn: pluggedIn, charging: charging,
                               batteryPercent: percent))
    }
    let foldedWarning = alert(power: .warning, pluggedIn: true, charging: true, percent: 82)
    check("문구: 전원 warning 인데 어댑터 연결 → 원인 없이 레벨과 수치만",
          foldedWarning.title == "서버 전원 주의" && foldedWarning.body == "배터리 82% · 충전 중",
          "\(foldedWarning.title) / \(foldedWarning.body)")
    let unknownSupply = alert(power: .critical, pluggedIn: nil, charging: nil, percent: 18)
    check("문구: 전원 critical, pluggedIn 불명 → 원인 없이 레벨과 수치만",
          unknownSupply.title == "서버 전원 위험" && unknownSupply.body == "배터리 18%",
          "\(unknownSupply.title) / \(unknownSupply.body)")
    let noFigures = alert(power: .warning, pluggedIn: nil, charging: nil, percent: nil)
    check("문구: 전원 수치가 하나도 없음 → 확인 안내",
          noFigures.title == "서버 전원 주의" && noFigures.body == "서버의 전원 상태를 확인하세요.",
          "\(noFigures.title) / \(noFigures.body)")
    check("문구: 디스크 warning",
          alert(disk: .warning, bytes: 18_000_000_000).title == "서버 디스크 여유 부족"
              && alert(disk: .warning, bytes: 18_000_000_000).body == "여유 18GB")
    check("문구: 디스크 critical",
          alert(disk: .critical, bytes: 4_200_000_000).title == "서버 디스크 거의 가득"
              && alert(disk: .critical, bytes: 4_200_000_000).body == "여유 4.2GB")
    check("식별자 고정 (신호별 교체)",
          alert(power: .warning, percent: 82).identifier == "server-host-power"
              && alert(power: .critical, percent: 18).identifier == "server-host-power"
              && alert(disk: .warning, bytes: 1).identifier == "server-host-disk")
}

// MARK: - 시각 표기

print("▸ 시각 표기 (TimeText)")
do {
    let cal = Calendar.current
    func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    let base = at(29, 15, 0)
    check("기록 없음 → nil", TimeText.checkedClock(nil, stale: false, now: base) == nil)
    check("같은 날 오후 → 사용량 줄과 같은 표기",
          TimeText.checkedClock(at(29, 14, 32), stale: false, now: base) == "오후 2:32",
          "\(String(describing: TimeText.checkedClock(at(29, 14, 32), stale: false, now: base)))")
    check("같은 날 오전", TimeText.checkedClock(at(29, 9, 5), stale: false, now: base) == "오전 9:05")
    check("다른 날 → 날짜 붙임",
          TimeText.checkedClock(at(28, 14, 32), stale: false, now: base) == "9/28 오후 2:32",
          "\(String(describing: TimeText.checkedClock(at(28, 14, 32), stale: false, now: base)))")

    func ago(_ minutesBefore: Int) -> String? {
        TimeText.checkedClock(base.addingTimeInterval(-Double(minutesBefore) * 60), stale: true, now: base)?
            .components(separatedBy: " · ").last
    }
    check("오래됨 59분 → 분", ago(59) == "59분 전", "\(String(describing: ago(59)))")
    check("오래됨 60분 → 시간", ago(60) == "1시간 전", "\(String(describing: ago(60)))")
    check("오래됨 23시간 59분 → 시간", ago(24 * 60 - 1) == "23시간 전", "\(String(describing: ago(24 * 60 - 1)))")
    check("오래됨 24시간 → 일", ago(24 * 60) == "1일 전", "\(String(describing: ago(24 * 60)))")
    check("오래됨 표기 전체", TimeText.checkedClock(at(29, 14, 37), stale: true, now: base) == "오후 2:37 · 23분 전")
    check("오래되지 않으면 나이 없음", TimeText.checkedClock(at(29, 14, 37), stale: false, now: base) == "오후 2:37")
}

print("")
if failures.isEmpty {
    print("✓ \(caseCount) cases passed")
} else {
    print("✗ \(failures.count)/\(caseCount) failed: \(failures.joined(separator: ", "))")
    exit(1)
}
