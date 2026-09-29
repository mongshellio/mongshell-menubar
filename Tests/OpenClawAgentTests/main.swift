import Foundation

// Tests for the server-side openclaw agent (Sources/mongshell-openclaw-agent).
//
// Each case pins a rule whose mutation would silently change what the menubar
// clients see or make the agent restart the wrong thing: probe verdict order,
// heal timing, the self-label exclusion, and the status-file wire format.
//
// Run with `./scripts/test.sh`, which compiles this against the real sources
// (main.swift excluded — it's the agent's entry point).

var failures: [String] = []
var caseCount = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    caseCount += 1
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

func verdict(_ out: String, exit: Int32 = 0, timedOut: Bool = false) -> ProbeVerdict {
    Probe.parseProbe(.init(stdout: out, exitCode: exit, timedOut: timedOut))
}

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("openclaw-agent-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

// MARK: - Probe 판정

print("▸ probe 판정")
do {
    // "not reachable" contains "reachable" — if the positive test ran first
    // (or the negative one were dropped) this would read as OK.
    let v1 = verdict("Gateway not reachable.\n", exit: 0)
    check("not reachable → down", v1 == .down, "\(v1)")
    let v2 = verdict("gateway unreachable: ECONNREFUSED\n", exit: 0)
    check("unreachable → down", v2 == .down, "\(v2)")

    let v3 = verdict("Gateway reachable.\n- Telegram default: enabled, disconnected\n")
    check("disconnected 만 → ok", v3 == .ok(detail: "정상"), "\(v3)")

    let v4 = verdict("Gateway reachable.\n- Telegram default: enabled, stopped\n- Slack main: running\n")
    check("stopped → degraded + 채널 이름", v4 == .degraded(detail: "Telegram default"), "\(v4)")
    let v5 = verdict("Gateway reachable.\n- Slack main: running, error: token expired\n")
    check("error: → degraded", v5 == .degraded(detail: "Slack main"), "\(v5)")
    let v6 = verdict("Gateway reachable.\n- Discord bot: health:not-running\n")
    check("health:not-running → degraded", v6 == .degraded(detail: "Discord bot"), "\(v6)")

    let v7 = verdict("Gateway reachable.\n- Telegram default: enabled, running, connected\n")
    check("running → ok + 채널 이름", v7 == .ok(detail: "Telegram default"), "\(v7)")

    let v8 = verdict("Gateway reachable.\n- Telegram default: running\n", timedOut: true)
    check("타임아웃 → down (출력이 정상이어도)", v8 == .down, "\(v8)")

    let v9 = verdict("Gateway reachable.\n", exit: 0)
    check("채널 없음 + exit 0 + reachable → ok(채널 없음)", v9 == .ok(detail: "채널 없음"), "\(v9)")
    let v10 = verdict("Gateway reachable.\n", exit: 1)
    check("채널 없음 + exit≠0 → down", v10 == .down, "\(v10)")
    let v11 = verdict("", exit: 0)
    check("빈 출력 → down", v11 == .down, "\(v11)")
}

// MARK: - run() 타임아웃

print("▸ run() 타임아웃")
do {
    let started = Date()
    let r = Probe.run("/bin/sleep", ["5"], timeout: 0.3)
    let elapsed = Date().timeIntervalSince(started)
    check("매달린 프로세스는 timedOut", r.timedOut)
    check("데드라인 근처에서 끊김", elapsed < 3, String(format: "%.2fs", elapsed))
    let fine = Probe.run("/bin/echo", ["hi"], timeout: 5)
    check("정상 종료는 timedOut 아님", !fine.timedOut && fine.exitCode == 0 && fine.stdout == "hi\n")
}

// MARK: - HealTracker

print("▸ HealTracker")
do {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    var t = HealTracker()
    t.record(.down)
    check("1회 실패 → 복구 안 함", !t.isHealDue(now: t0))
    t.record(.degraded(detail: "x"))
    check("2회 연속 실패 → 복구", t.isHealDue(now: t0))

    t.markHealed(at: t0)
    check("복구 후 카운트 0", t.consecutiveFailures == 0)
    t.record(.down); t.record(.down)
    check("쿨다운(600s) 이내 → 복구 안 함", !t.isHealDue(now: t0.addingTimeInterval(HealTracker.cooldown - 1)))
    check("쿨다운 경과 → 복구", t.isHealDue(now: t0.addingTimeInterval(HealTracker.cooldown)))

    var r = HealTracker()
    r.record(.down); r.record(.ok(detail: "정상")); r.record(.down)
    check("성공(ok) 시 카운트 리셋", !r.isHealDue(now: t0) && r.consecutiveFailures == 1)

    var n = HealTracker()
    n.record(.down); n.record(.notInstalled); n.record(.down)
    check("바이너리 없음은 실패로 세지 않음", !n.isHealDue(now: t0))

    let restored = HealTracker(lastHealAt: t0)
    var rr = restored
    rr.record(.down); rr.record(.down)
    check("재시작 시 이어받은 lastHeal 로 쿨다운 유지", !rr.isHealDue(now: t0.addingTimeInterval(60)))
}

// MARK: - 게이트웨이 레이블 탐색

print("▸ 레이블 탐색")
do {
    let dir = root.appendingPathComponent("LaunchAgents")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func touch(_ name: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
    }
    let selfLabel = "com.mongshell.openclaw-agent"

    // Only our own plist present: must fall back, never return ourselves.
    touch("\(selfLabel).plist")
    touch("com.apple.unrelated.plist")
    let onlySelf = Launchd.gatewayLabel(explicit: nil, selfLabel: selfLabel, in: dir)
    check("자기 레이블만 있으면 기본값", onlySelf == Launchd.defaultGatewayLabel, onlySelf)

    // Self sorts before the gateway here ("com.a…" < "com.z…").
    touch("com.zzz.claw-gateway.plist")
    let found = Launchd.gatewayLabel(explicit: nil, selfLabel: selfLabel, in: dir)
    check("정렬상 먼저여도 self 제외", found == "com.zzz.claw-gateway", found)

    let explicit = Launchd.gatewayLabel(explicit: "ai.custom", selfLabel: selfLabel, in: dir)
    check("--gateway-label 우선", explicit == "ai.custom", explicit)

    let missing = Launchd.gatewayLabel(
        explicit: nil, selfLabel: selfLabel, in: root.appendingPathComponent("nope"))
    check("디렉토리 없음 → 기본값", missing == Launchd.defaultGatewayLabel, missing)
}

// MARK: - 상태 파일

print("▸ 상태 파일")
do {
    let at = Date(timeIntervalSince1970: 1_790_651_565) // 2026-09-29T03:12:45Z
    let heal = HealRecord(at: at.addingTimeInterval(-3762), ok: true, reason: "down")
    let status = AgentStatus(
        checkedAt: at, verdict: .ok(detail: "Telegram default"),
        intervalSeconds: 60, autoHeal: true, lastHeal: heal)

    let json = try! JSONSerialization.jsonObject(with: StatusFile.encode(status)) as! [String: Any]
    check("키 집합", Set(json.keys) == ["schema", "checkedAt", "health", "detail",
                                        "intervalSeconds", "autoHeal", "lastHeal"],
          "\(json.keys.sorted())")
    check("schema = 1", json["schema"] as? Int == 1)
    check("checkedAt ISO8601 UTC", json["checkedAt"] as? String == "2026-09-29T03:12:45Z",
          "\(json["checkedAt"] ?? "nil")")
    check("health/detail", json["health"] as? String == "ok"
          && json["detail"] as? String == "Telegram default")
    let lh = json["lastHeal"] as? [String: Any]
    check("lastHeal 키", lh?["at"] as? String == "2026-09-29T02:10:03Z"
          && lh?["ok"] as? Bool == true && lh?["reason"] as? String == "down", "\(lh ?? [:])")

    let bare = AgentStatus(checkedAt: at, verdict: .down, intervalSeconds: 60,
                           autoHeal: false, lastHeal: nil)
    let bareJSON = try! JSONSerialization.jsonObject(with: StatusFile.encode(bare)) as! [String: Any]
    check("이력 없음 → lastHeal 은 null 로 유지", bareJSON["lastHeal"] is NSNull)
    check("down → detail null", bareJSON["health"] as? String == "down" && bareJSON["detail"] is NSNull)

    let missing = AgentStatus(checkedAt: at, verdict: .notInstalled, intervalSeconds: 60,
                              autoHeal: true, lastHeal: nil)
    let missingJSON = try! JSONSerialization.jsonObject(with: StatusFile.encode(missing)) as! [String: Any]
    check("바이너리 없음 → down + 사유", missingJSON["health"] as? String == "down"
          && missingJSON["detail"] as? String == "openclaw 바이너리 없음")

    let file = root.appendingPathComponent("status.json")
    // A restrictive umask would leave the atomic-write temp file at 0600 and
    // funnel unable to serve it; the explicit chmod must win regardless.
    let oldMask = umask(0o077)
    try! StatusFile.write(status, to: file)
    umask(oldMask)
    let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? Int
    check("파일 권한 0644", mode == 0o644, mode.map { String($0, radix: 8) } ?? "nil")
    check("lastHeal 읽어 이어가기", StatusFile.readLastHeal(from: file) == heal)

    let junk = root.appendingPathComponent("junk.json")
    try! Data("not json".utf8).write(to: junk)
    check("깨진 파일 → lastHeal nil", StatusFile.readLastHeal(from: junk) == nil)
    check("파일 없음 → lastHeal nil",
          StatusFile.readLastHeal(from: root.appendingPathComponent("absent.json")) == nil)
}

// MARK: - 결과

try? FileManager.default.removeItem(at: root)

if failures.isEmpty {
    print("\n전부 통과 (\(caseCount)개 케이스)")
    exit(0)
} else {
    print("\n실패 \(failures.count)건:")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
