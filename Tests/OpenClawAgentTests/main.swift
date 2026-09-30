import Foundation

// Tests for the server-side openclaw agent (Sources/mongshell-openclaw-agent).
//
// Each case pins a rule whose mutation would silently change what the menubar
// clients see or make the agent restart the wrong thing: probe verdict order,
// heal timing, the self-label exclusion, the host thresholds, and the
// status-file wire format.
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

// MARK: - 공개 detail 필터

print("▸ 공개 detail 필터")
do {
    // The status file is public; a bot handle must never reach it verbatim,
    // and filtering must not change the verdict itself.
    let bot = verdict("Gateway reachable.\n- @mongshell_bot: running\n")
    check("봇 계정명 → 개수만", bot == .ok(detail: "채널 1개"), "\(bot)")
    let mixed = verdict("Gateway reachable.\n- Telegram default: stopped\n- me@example.com: stopped\n")
    check("허용 이름만 노출 + 나머지 개수", mixed == .degraded(detail: "Telegram default 외 1개"), "\(mixed)")
    let long = String(repeating: "a", count: Probe.maxPublicNameLength + 1)
    let tooLong = verdict("Gateway reachable.\n- \(long): running\n")
    check("32자 초과 → 개수만", tooLong == .ok(detail: "채널 1개"), "\(tooLong)")
    let edge = String(repeating: "a", count: Probe.maxPublicNameLength)
    let atLimit = verdict("Gateway reachable.\n- \(edge): running\n")
    check("32자 → 그대로", atLimit == .ok(detail: edge), "\(atLimit)")
    let hangul = verdict("Gateway reachable.\n- 텔레그램 기본_1.x-y: running\n")
    check("한글·허용 기호 → 그대로", hangul == .ok(detail: "텔레그램 기본_1.x-y"), "\(hangul)")
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

    // An explicit label naming the agent itself would make it kickstart
    // itself on every heal; it must fall through to discovery instead.
    let selfExplicit = Launchd.gatewayLabel(explicit: selfLabel, selfLabel: selfLabel, in: dir)
    check("--gateway-label == self → 무시하고 탐색", selfExplicit == "com.zzz.claw-gateway", selfExplicit)

    let missing = Launchd.gatewayLabel(
        explicit: nil, selfLabel: selfLabel, in: root.appendingPathComponent("nope"))
    check("디렉토리 없음 → 기본값", missing == Launchd.defaultGatewayLabel, missing)
}

// MARK: - 호스트 판정

print("▸ 호스트 전원 판정")
do {
    func power(pluggedIn: Bool, percent: Int?) -> HostLevel {
        HostRules.level(for: PowerReading(pluggedIn: pluggedIn, charging: false, batteryPercent: percent))
    }
    // The adapter rule comes first: a nearly empty battery that is plugged in
    // is charging, not dying.
    check("어댑터 연결 + 5% → ok", power(pluggedIn: true, percent: 5) == .ok)
    check("배터리 구동 21% → warning", power(pluggedIn: false, percent: 21) == .warning)
    check("배터리 구동 20% → critical", power(pluggedIn: false, percent: 20) == .critical)
    check("배터리 구동 + 잔량 불명 → warning", power(pluggedIn: false, percent: nil) == .warning)
}

print("▸ 호스트 디스크 판정")
do {
    func disk(_ bytes: Int64) -> HostLevel {
        HostRules.level(for: DiskReading(availableBytes: bytes))
    }
    // Literal byte counts, not the rule's own constants: a GiB/GB mix-up in
    // the constants must fail here.
    check("20GB 정각 → ok", disk(20_000_000_000) == .ok)
    check("20GB - 1바이트 → warning", disk(19_999_999_999) == .warning)
    check("5GB 정각 → warning", disk(5_000_000_000) == .warning)
    check("5GB - 1바이트 → critical", disk(4_999_999_999) == .critical)
}

print("▸ 호스트 종합")
do {
    let onBattery = PowerReading(pluggedIn: false, charging: false, batteryPercent: 82)
    let pluggedIn = PowerReading(pluggedIn: true, charging: true, batteryPercent: 82)
    let roomy = DiskReading(availableBytes: 32_604_813_672)
    let full = DiskReading(availableBytes: 1_000_000_000)

    let powerWorse = HostRules.judge(power: onBattery, disk: roomy)
    check("전원 warning + 디스크 ok → warning",
          powerWorse?.level == .warning && powerWorse?.power?.level == .warning
              && powerWorse?.disk?.level == .ok, "\(String(describing: powerWorse?.level))")
    let diskWorse = HostRules.judge(power: onBattery, disk: full)
    check("전원 warning + 디스크 critical → critical", diskWorse?.level == .critical,
          "\(String(describing: diskWorse?.level))")
    let diskOnly = HostRules.judge(power: nil, disk: full)
    check("전원 없음 → 디스크만으로 종합", diskOnly?.level == .critical && diskOnly?.power == nil)
    let powerOnly = HostRules.judge(power: pluggedIn, disk: nil)
    check("디스크 없음 → 전원만으로 종합", powerOnly?.level == .ok && powerOnly?.disk == nil)
    check("신호 없음 → host nil", HostRules.judge(power: nil, disk: nil) == nil)

    // What the agent's host log is keyed on: a signal changing under an
    // unchanged overall level must still read as a change.
    let lowDisk = DiskReading(availableBytes: 18_000_000_000)
    let diskOnlyBad = HostRules.judge(power: pluggedIn, disk: lowDisk)
    let bothBad = HostRules.judge(power: onBattery, disk: lowDisk)
    check("로그 키: 종합이 같아도 전원 레벨이 다르면 다른 키",
          diskOnlyBad?.level == bothBad?.level
              && HostSignalLevels(diskOnlyBad) != HostSignalLevels(bothBad))
    check("로그 키: 종합이 같아도 디스크 레벨이 다르면 다른 키",
          powerWorse?.level == bothBad?.level
              && HostSignalLevels(powerWorse) != HostSignalLevels(bothBad))
    check("로그 키: 수치만 바뀌면 같은 키",
          HostSignalLevels(powerWorse) == HostSignalLevels(HostRules.judge(
              power: PowerReading(pluggedIn: false, charging: false, batteryPercent: 81),
              disk: DiskReading(availableBytes: 32_000_000_000))))
    check("로그 키: 신호 없음(host nil)은 신호가 있는 것과 다른 키",
          HostSignalLevels(nil) != HostSignalLevels(powerOnly)
              && HostSignalLevels(nil) == HostSignalLevels(HostRules.judge(power: nil, disk: nil)))
}

// MARK: - 호스트 읽기 해석

print("▸ 전원 소스 해석")
do {
    // Literal keys and values as IOKit hands them over (`pmset -g ps` shows
    // the same names), so a wrong constant in the reader fails here.
    let battery: [String: Any] = [
        "Type": "InternalBattery", "Is Present": true, "Is Charging": false,
        "Current Capacity": 82, "Max Capacity": 100, "Power Source State": "Battery Power",
    ]
    let ups: [String: Any] = [
        "Type": "UPS", "Is Present": true, "Is Charging": false,
        "Current Capacity": 100, "Max Capacity": 100, "Power Source State": "AC Power",
    ]

    let unplugged = HostProbe.interpretPower(providing: "Battery Power", sources: [battery])
    check("배터리 구동 해석",
          unplugged == PowerReading(pluggedIn: false, charging: false, batteryPercent: 82),
          "\(String(describing: unplugged))")

    var chargingBattery = battery
    chargingBattery["Is Charging"] = true
    chargingBattery["Power Source State"] = "AC Power"
    let plugged = HostProbe.interpretPower(providing: "AC Power", sources: [chargingBattery])
    check("어댑터 연결·충전 중 해석",
          plugged == PowerReading(pluggedIn: true, charging: true, batteryPercent: 82),
          "\(String(describing: plugged))")

    let fallback = HostProbe.interpretPower(providing: nil, sources: [battery])
    check("공급원 불명 → 배터리 자체 상태로 판단", fallback?.pluggedIn == false,
          "\(String(describing: fallback))")

    var noCapacity = battery
    noCapacity["Current Capacity"] = nil
    let unknown = HostProbe.interpretPower(providing: "Battery Power", sources: [noCapacity])
    check("잔량 못 읽음 → 읽기는 있고 잔량만 nil",
          unknown == PowerReading(pluggedIn: false, charging: false, batteryPercent: nil),
          "\(String(describing: unknown))")

    var rawUnits = battery
    rawUnits["Current Capacity"] = 2_050
    rawUnits["Max Capacity"] = 5_000
    let scaled = HostProbe.interpretPower(providing: "Battery Power", sources: [rawUnits])
    check("잔량은 최대 용량 대비 퍼센트", scaled?.batteryPercent == 41,
          "\(String(describing: scaled?.batteryPercent))")

    check("전원 소스 0개 → nil", HostProbe.interpretPower(providing: "AC Power", sources: []) == nil)
    check("UPS 만 → nil", HostProbe.interpretPower(providing: "AC Power", sources: [ups]) == nil)
    var absent = battery
    absent["Is Present"] = false
    check("Is Present false → nil",
          HostProbe.interpretPower(providing: "AC Power", sources: [absent]) == nil)
    let mixed = HostProbe.interpretPower(providing: "Battery Power", sources: [ups, battery])
    check("UPS + 내장 배터리 → 내장 배터리만 읽음", mixed?.batteryPercent == 82,
          "\(String(describing: mixed))")

    var onAdapter = battery
    onAdapter["Power Source State"] = "AC Power"
    let fallbackAC = HostProbe.interpretPower(providing: nil, sources: [onAdapter])
    check("공급원 불명 + 배터리 상태 AC Power → 어댑터 연결", fallbackAC?.pluggedIn == true,
          "\(String(describing: fallbackAC))")
    // "Off Line" says the battery isn't supplying, not what is: reading it as
    // plugged in would publish an `ok` nobody measured.
    var offLine = battery
    offLine["Power Source State"] = "Off Line"
    let undetermined = HostProbe.interpretPower(providing: nil, sources: [offLine])
    check("공급원 불명 + 배터리 상태가 AC·Battery 가 아님 → 읽기 없음", undetermined == nil,
          "\(String(describing: undetermined))")

    // Out-of-range capacities must not trap: a crash here takes the whole
    // agent down, openclaw watch included.
    var extreme = battery
    extreme["Current Capacity"] = Int.max
    extreme["Max Capacity"] = 1
    let capped = HostProbe.interpretPower(providing: "Battery Power", sources: [extreme])
    check("잔량 극단값 (현재 Int.max / 최대 1) → 트랩 없이 100", capped?.batteryPercent == 100,
          "\(String(describing: capped))")
    var negative = battery
    negative["Current Capacity"] = -1
    var noMax = battery
    noMax["Max Capacity"] = 0
    let unusable = [negative, noMax].map {
        HostProbe.interpretPower(providing: "Battery Power", sources: [$0])
    }
    check("잔량 음수 · 최대 용량 0 → 잔량만 nil",
          unusable.allSatisfy { $0 != nil && $0?.batteryPercent == nil }, "\(unusable)")
}

print("▸ 디스크 여유 해석")
do {
    let preferred = HostProbe.interpretDisk(importantUsage: 30_000_000_000, available: 10_000_000_000)
    check("important usage 우선", preferred == DiskReading(availableBytes: 30_000_000_000))
    let zero = HostProbe.interpretDisk(importantUsage: 0, available: 10_000_000_000)
    check("important usage 0 → 폴백", zero == DiskReading(availableBytes: 10_000_000_000),
          "\(String(describing: zero))")
    let missing = HostProbe.interpretDisk(importantUsage: nil, available: 10_000_000_000)
    check("important usage nil → 폴백", missing == DiskReading(availableBytes: 10_000_000_000))
    check("둘 다 못 읽음 → nil", HostProbe.interpretDisk(importantUsage: nil, available: nil) == nil)
    // 0 from the plain figure is a reading — the disk is full — not a failure
    // to read; only a negative count is.
    let full = HostProbe.interpretDisk(importantUsage: 0, available: 0)
    check("여유 0 은 읽기값 → critical",
          full == DiskReading(availableBytes: 0) && full.map(HostRules.level(for:)) == .critical,
          "\(String(describing: full))")
    check("여유 음수 → nil", HostProbe.interpretDisk(importantUsage: 0, available: -1) == nil)
}

// MARK: - 상태 파일

/// Every string value anywhere under a JSON value.
func strings(in value: Any) -> [String] {
    if let s = value as? String { return [s] }
    if let d = value as? [String: Any] { return d.values.flatMap(strings) }
    if let a = value as? [Any] { return a.flatMap(strings) }
    return []
}

print("▸ 상태 파일")
do {
    let at = Date(timeIntervalSince1970: 1_790_651_565) // 2026-09-29T03:12:45Z
    let heal = HealRecord(at: at.addingTimeInterval(-3762), ok: true, reason: "down")
    let host = HostRules.judge(
        power: PowerReading(pluggedIn: false, charging: false, batteryPercent: 82),
        disk: DiskReading(availableBytes: 32_604_813_672))
    let status = AgentStatus(
        checkedAt: at, verdict: .ok(detail: "Telegram default"),
        intervalSeconds: 60, autoHeal: true, lastHeal: heal, host: host)

    let json = try! JSONSerialization.jsonObject(with: StatusFile.encode(status)) as! [String: Any]
    check("키 집합", Set(json.keys) == ["schema", "checkedAt", "health", "detail",
                                        "intervalSeconds", "autoHeal", "lastHeal", "host"],
          "\(json.keys.sorted())")
    check("schema = 1", json["schema"] as? Int == 1)
    check("checkedAt ISO8601 UTC", json["checkedAt"] as? String == "2026-09-29T03:12:45Z",
          "\(json["checkedAt"] ?? "nil")")
    check("health/detail", json["health"] as? String == "ok"
          && json["detail"] as? String == "Telegram default")
    let lh = json["lastHeal"] as? [String: Any]
    check("lastHeal 키", lh?["at"] as? String == "2026-09-29T02:10:03Z"
          && lh?["ok"] as? Bool == true && lh?["reason"] as? String == "down", "\(lh ?? [:])")

    let hostJSON = json["host"] as? [String: Any]
    check("host 키 집합", hostJSON.map { Set($0.keys) } == ["health", "power", "disk"],
          "\(hostJSON?.keys.sorted() ?? [])")
    check("host.health = 최악", hostJSON?["health"] as? String == "warning")
    let powerJSON = hostJSON?["power"] as? [String: Any]
    check("host.power 키·값", powerJSON.map { Set($0.keys) }
              == ["health", "pluggedIn", "charging", "batteryPercent"]
          && powerJSON?["health"] as? String == "warning"
          && powerJSON?["pluggedIn"] as? Bool == false && powerJSON?["charging"] as? Bool == false
          && powerJSON?["batteryPercent"] as? Int == 82, "\(powerJSON ?? [:])")
    let diskJSON = hostJSON?["disk"] as? [String: Any]
    check("host.disk 키·값", diskJSON.map { Set($0.keys) } == ["health", "availableBytes"]
          && diskJSON?["health"] as? String == "ok"
          && diskJSON?["availableBytes"] as? Int64 == 32_604_813_672, "\(diskJSON ?? [:])")

    // The document is public: nothing but the three level names may appear as
    // a string under `host`, whatever the combination of signals.
    let levels: Set<String> = ["ok", "warning", "critical"]
    let combos: [(PowerReading?, DiskReading?)] = [
        (PowerReading(pluggedIn: true, charging: true, batteryPercent: 100),
         DiskReading(availableBytes: 32_604_813_672)),
        (PowerReading(pluggedIn: false, charging: false, batteryPercent: 82),
         DiskReading(availableBytes: 19_999_999_999)),
        (PowerReading(pluggedIn: false, charging: false, batteryPercent: nil),
         DiskReading(availableBytes: 4_999_999_999)),
        (PowerReading(pluggedIn: false, charging: false, batteryPercent: 20), nil),
        (nil, DiskReading(availableBytes: 0)),
    ]
    let hostStrings = combos.flatMap { power, disk -> [String] in
        let doc = AgentStatus(checkedAt: at, verdict: .down, intervalSeconds: 60, autoHeal: true,
                              lastHeal: nil, host: HostRules.judge(power: power, disk: disk))
        let parsed = try! JSONSerialization.jsonObject(with: StatusFile.encode(doc)) as! [String: Any]
        return strings(in: parsed["host"] ?? NSNull())
    }
    check("host 아래 문자열은 세 레벨 이름뿐",
          !hostStrings.isEmpty && hostStrings.allSatisfy(levels.contains)
              && Set(hostStrings) == levels,
          "\(Set(hostStrings).sorted())")

    let noBattery = AgentStatus(
        checkedAt: at, verdict: .down, intervalSeconds: 60, autoHeal: true, lastHeal: nil,
        host: HostRules.judge(power: nil, disk: DiskReading(availableBytes: 32_604_813_672)))
    let noBatteryHost = (try! JSONSerialization.jsonObject(with: StatusFile.encode(noBattery))
        as! [String: Any])["host"] as? [String: Any]
    check("배터리 없음 → power 는 null 로 유지",
          noBatteryHost?["power"] is NSNull && noBatteryHost?["disk"] is [String: Any],
          "\(noBatteryHost?.keys.sorted() ?? [])")
    let noPercent = AgentStatus(
        checkedAt: at, verdict: .down, intervalSeconds: 60, autoHeal: true, lastHeal: nil,
        host: HostRules.judge(
            power: PowerReading(pluggedIn: false, charging: false, batteryPercent: nil), disk: nil))
    let noPercentHost = (try! JSONSerialization.jsonObject(with: StatusFile.encode(noPercent))
        as! [String: Any])["host"] as? [String: Any]
    check("잔량 불명 → batteryPercent null, 디스크 없음 → disk null",
          (noPercentHost?["power"] as? [String: Any])?["batteryPercent"] is NSNull
              && noPercentHost?["disk"] is NSNull, "\(noPercentHost?.keys.sorted() ?? [])")

    let bare = AgentStatus(checkedAt: at, verdict: .down, intervalSeconds: 60,
                           autoHeal: false, lastHeal: nil, host: nil)
    let bareJSON = try! JSONSerialization.jsonObject(with: StatusFile.encode(bare)) as! [String: Any]
    check("이력 없음 → lastHeal 은 null 로 유지", bareJSON["lastHeal"] is NSNull)
    check("호스트 신호 없음 → host 는 null 로 유지", bareJSON["host"] is NSNull)
    check("down → detail null", bareJSON["health"] as? String == "down" && bareJSON["detail"] is NSNull)

    let missing = AgentStatus(checkedAt: at, verdict: .notInstalled, intervalSeconds: 60,
                              autoHeal: true, lastHeal: nil, host: nil)
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
