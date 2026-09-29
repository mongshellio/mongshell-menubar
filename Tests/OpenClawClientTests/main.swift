import Foundation

// Tests for the menubar app's openclaw status client (Decision #25).
//
// Each case pins a rule whose mutation would change what the dot says: the
// wire keys shared with the server agent, the unreachable threshold, the
// grey-vs-red split, URL validation, when a server heal is announced, and the
// clock text shown next to it.
//
// Run with `./scripts/test.sh`, which compiles this against the real app
// sources *and* the agent's `Probe.swift` / `StatusFile.swift`, so the
// round-trip case encodes with the agent's actual encoder.

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
             health: OpenClawHealth = .ok(detail: "Telegram default")) -> OpenClawReading {
    var r = OpenClawReading()
    r.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-age), health: health,
                                   intervalSeconds: interval, autoHeal: true, lastHeal: nil),
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
                             intervalSeconds: 120, autoHeal: false, lastHeal: heal)
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
        autoHeal: true, lastHeal: nil))
    let okStatus = try? OpenClawStatusClient.parse(data: okData)
    check("ok + lastHeal null 왕복",
          okStatus?.health == .ok(detail: "Slack main") && okStatus?.lastHeal == nil)

    let downData = try! StatusFile.encode(AgentStatus(
        checkedAt: now, verdict: .down, intervalSeconds: 60, autoHeal: true, lastHeal: nil))
    check("down(detail null) 왕복",
          (try? OpenClawStatusClient.parse(data: downData))?.health == .down)
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

    let down = reading(checkedSecondsAgo: 10, now: now, health: .down).health(now: now)
    check("서버가 down 보고 → down (빨강)", down == .down)
    var gone = OpenClawReading()
    gone.recordFailure(.offline)
    let offline = gone.health(now: now)
    check("응답 없음 → down 이 아니라 unreachable",
          offline == .unreachable(detail: "네트워크 연결 없음"), "\(offline)")
    check("unreachable 은 빨강이 아님",
          OpenClawHealth.unreachable(detail: "").dotColor != OpenClawHealth.down.dotColor)

    var blip = reading(checkedSecondsAgo: 30, now: now)
    blip.recordFailure(.timedOut)
    check("일시 실패 + 신선한 마지막 성공 → 상태 유지",
          blip.health(now: now) == .ok(detail: "Telegram default"), "\(blip.health(now: now))")
    let later = blip.health(now: now.addingTimeInterval(200))
    check("실패가 이어져 오래되면 → unreachable(실패 이유)",
          later == .unreachable(detail: "응답 시간 초과"), "\(later)")

    check("응답 전 → unknown", OpenClawReading().health(now: now) == .unknown)

    var overlap = reading(checkedSecondsAgo: 10, now: now, health: .down)
    overlap.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-70), health: .ok(detail: "old"),
                                         intervalSeconds: 60, autoHeal: true, lastHeal: nil),
                          receivedAt: now)
    check("늦게 도착한 옛 응답 → 상태 역행 없음", overlap.health(now: now) == .down,
          "\(overlap.health(now: now))")

    // Server clock set back: a step back beyond the stale threshold can't be
    // a late reply, so it becomes the new baseline instead of being dropped
    // until the clock catches up.
    var smallStep = reading(checkedSecondsAgo: 0, now: now, health: .down)
    let kept = smallStep.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-180),
                                                      health: .ok(detail: "old"), intervalSeconds: 60,
                                                      autoHeal: true, lastHeal: nil),
                                       receivedAt: now)
    check("임계(180초) 이내 역행 → 무시", !kept && smallStep.health(now: now) == .down,
          "\(smallStep.health(now: now))")
    var clockBack = reading(checkedSecondsAgo: 0, now: now, health: .down)
    clockBack.recordFailure(.timedOut)
    let reset = clockBack.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-3600),
                                                       health: .ok(detail: "new"), intervalSeconds: 60,
                                                       autoHeal: true, lastHeal: nil),
                                        receivedAt: now.addingTimeInterval(60))
    check("임계 넘는 역행 → 새 기준으로 수용 (실패 이유 해제)",
          reset && clockBack.lastFailure == nil && clockBack.lastCheckedAt == now.addingTimeInterval(-3600)
              && clockBack.health(now: now.addingTimeInterval(-3600)) == .ok(detail: "new"),
          "\(String(describing: clockBack.lastCheckedAt))")
    let next = clockBack.recordSuccess(OpenClawStatus(checkedAt: now.addingTimeInterval(-3540),
                                                      health: .ok(detail: "next"), intervalSeconds: 60,
                                                      autoHeal: true, lastHeal: nil),
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
