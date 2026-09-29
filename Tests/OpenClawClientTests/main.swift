import Foundation

// Tests for the menubar app's openclaw status client (Decision #25).
//
// Each case pins a rule whose mutation would change what the dot says: the
// wire keys shared with the server agent, the unreachable threshold, the
// grey-vs-red split, URL validation, and when a server heal is announced.
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

    if case .failure(let e) = parse("[1,2]") {
        check("객체가 아닌 JSON → badResponse", e == .badResponse)
    } else { check("객체가 아닌 JSON → 실패", false) }

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
}

// MARK: - 연락 두절 판정

print("▸ 연락 두절 판정")
do {
    let fresh = reading(checkedSecondsAgo: 60, now: now).health(now: now)
    check("60초 전 → 정상", fresh == .ok(detail: "Telegram default"), "\(fresh)")

    let stale = reading(checkedSecondsAgo: 181, now: now).health(now: now)
    if case .unreachable = stale { check("181초 전 → unreachable", true) }
    else { check("181초 전 → unreachable", false, "\(stale)") }

    let skew = reading(checkedSecondsAgo: -600, now: now).health(now: now)
    check("미래 시각 → 정상 (나이 0)", skew == .ok(detail: "Telegram default"), "\(skew)")

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
}

print("")
if failures.isEmpty {
    print("✓ \(caseCount) cases passed")
} else {
    print("✗ \(failures.count)/\(caseCount) failed: \(failures.joined(separator: ", "))")
    exit(1)
}
