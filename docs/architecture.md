---
role: "Tech Stack·데이터 흐름·인증·배포 인프라 사양의 단일 권위 — 각 선택을 왜 그렇게 했는지(대안·결과)는 다루지 않음."
kind: reference
non_goals:
  - "각 선택의 근거·대안·결과 (docs/architecture-decisions.md)"
  - "프로덕트 범위 판단 (docs/PHILOSOPHY.md)"
  - "빌드/테스트 명령 (docs/development.md)"
---

# Architecture

## Tech Stack

| 층 | 사용 기술 |
|---|---|
| 언어 / 빌드 | Swift 6, SwiftPM (`swift-tools-version: 6.0`), executable 타깃 2개 — 메뉴바 앱 `mongshell-menubar` + 서버 에이전트 `mongshell-openclaw-agent` |
| 최소 플랫폼 | macOS 26 (Decision #40) |
| UI | SwiftUI 뷰 + AppKit 호스팅 (`NSStatusItem`, `NSPopover`, `NSWindow`) |
| 동시성 | Swift Concurrency (`@MainActor` 격리, `Task`, `async/await`) |
| 네트워크 | `URLSession` (Foundation). HTTPS 클라이언트(사용량·OAuth 토큰·openclaw 상태·GitHub)는 `BoundedHTTP` 를 공유한다 — ephemeral 세션, 리다이렉트 거부, 바이트 캡 |
| GitHub PR (선택 기능) | GitHub GraphQL API (`POST https://api.github.com/graphql`, 공식 API) — `URLSession` 위 `BoundedHTTP` (Decision #45) |
| 로컬 리스너 | `Network.framework` (`NWListener`) — OAuth 루프백 |
| 자격증명 | Security.framework Keychain (generic password) |
| 설정 영속화 | `UserDefaults` (`@AppStorage`) |
| 알림 | UserNotifications (앱 번들 필수) |
| 로그인 항목 | ServiceManagement (`SMAppService.mainApp`) |
| 외부 프로세스 | `posix_spawn` (새 프로세스 그룹, 마감 있는 non-blocking 읽기) — `openclaw` CLI, `launchctl` (게이트웨이 재시작·CI 러너 상태 조회. 서버 에이전트 전용 — 메뉴바 앱은 셸아웃하지 않는다) |
| 호스트 신호 읽기 (서버 에이전트) | IOKit (`IOKit.ps` — 전원 공급원·내장 배터리), Foundation `URL` 리소스 값 (홈 볼륨 여유 공간), `/Library/LaunchDaemons` 목록 + `launchctl print system/<레이블>` (CI 러너, sudo 불필요) |
| 상태 공개 (서버 에이전트) | Tailscale Funnel — 오픈소스판 `tailscaled` 가 상태 파일을 정적 서빙 (포트 8443) |
| 외부 패키지 의존성 | **없음** |

DB·백엔드 서비스가 없다. 메뉴바 앱은 단일 프로세스 클라이언트다. 예외는 선택 기능인 openclaw 감시로, 사용자가 운영하는 서버 맥에 헤드리스 에이전트(`mongshell-openclaw-agent`)를 둔다 — openclaw 게이트웨이와 서버 맥 자체의 신호(전원·디스크·CI 러너)를 판정해 네트워크 리스너 없이 상태 파일만 쓰고, 공개는 tailscaled 가 한다.

## Data Flow

### 1. 사용량 폴링 (주 경로)

```
UsageModel.pollLoop()  ──(@MainActor, Task)
   └─ CredentialStore.token()      ← Keychain (자체 토큰 → Claude Code 토큰 순)
   └─ AuthService.refresh(_:)      ← 자체 토큰이 만료됐을 때, 그리고 사용량 401 뒤 한 번
        └─ POST https://platform.claude.com/v1/oauth/token   (OAuthTokenClient · BoundedHTTP: 타임아웃 30초, 리다이렉트 거부, 200·400·401 만 본문을 64KB 까지 읽음)
   └─ UsageAPIClient.fetch(token:)
        └─ GET https://api.anthropic.com/api/oauth/usage   (BoundedHTTP: 타임아웃 30초, 리다이렉트 거부, 200 만 본문을 1MB 까지 읽음)
             Authorization: Bearer …
             User-Agent: claude-code/<version>      ← 필수
             anthropic-beta: oauth-2025-04-20
        └─ parse() → UsageSnapshot
   └─ @Published snapshot 갱신
        ├─ MenuBarIconView   (상태바 링 게이지 + 초기화 시각)
        ├─ HoverSummaryView  (hover 즉시 팝오버)
        ├─ PopoverView       (클릭 팝오버)
        └─ 임계 알림 (UserNotifications)
```

- 폴링 주기는 사용자 설정값과 `Config.minPollInterval` 중 큰 값. 기본이자 하한이 180초다.
- `429` 응답 시 지수 백오프 (`base * 2^n`, 상한 3600초).
- 응답 스키마가 비공개라 `parse()` 는 후보 키 경로를 여러 개 탐색하고 채울 수 있는 것만 채운다.
- `limits` 의 모르는 `kind` 는 버리지 않고 `extraLimits` 로 실어 팝오버의 7일 한도 아래에 그리고(설정 화면의 제한 초기화/보너스가 이 경로로 보인다), 최상위의 모르는 객체 키는 `unknownTopLevel` 로 실어 디버그 로그에만 남긴다 — 모르는 것의 집합이 바뀔 때 한 줄. 필터 규칙 셋: (1) 최상위 키 중 값이 null 인 것과 모양을 아는 것(`seven_day_breakdown`·`weekly_scoped_shares`·`member_dashboard_available`)은 세지 않고, 모르는 **객체** 키만 `unknownTopLevel` 에 든다. (2) 로그 줄은 kind·percent·resets_at(과 is_active·scope 모델명·utilization)만 담고 토큰·금액은 넣지 않는다. (3) 응답에서 온 문자열(`kind`·모델명·키 이름)은 `parse()` 에서 한 줄로 평탄화하고 글자 수 상한을 두며, `extraLimits`·`unknownTopLevel` 은 각각 개수 상한까지만 싣고 초과분은 버린다 — 상한값은 `Config`(`usageDisplayTextLimit`·`usageExtraLimitsCap`·`usageUnknownTopLevelCap`)가 권위다.
- 토큰이 없으면 네트워크를 타지 않고 `UsageSnapshot.sample` 로 렌더한다.
- 자체 토큰 갱신이 `400` + `invalid_grant` 로 실패하면 자체 토큰을 버린다 — 다음 폴링은 Claude Code 토큰으로, 없으면 로그아웃 상태로 넘어간다. 그 밖의 실패(전송 오류·5xx·거부된 3xx·응답 크기 상한 초과)는 토큰을 유지하고 다음 폴링에 다시 시도한다.

### 2. Claude Code 설정 편집 (양방향)

```
~/.claude/settings.json  ←→  ClaudeSettingsStore  ←→  ClaudeSettingsModel  ←→  ClaudeSettingsSection
        │                          │
        │                          └─ DispatchSource 파일 감시 (150ms 디바운스)
        └─ 저장: 디스크 재읽기 → 해당 키 하나만 반영(applyChange) → 원자적 쓰기
```

- 저장은 **read-modify-write** 다. 인메모리 스냅샷을 통째로 쓰지 않는다 — 앱이 모르는 키(권한 규칙·플러그인·hooks)를 보존하고, 감시가 놓친 외부 변경을 덮지 않기 위해서.
- 읽기에 실패하면 쓰지 않는다. 쓰기 직전 `lstat` 으로 대상이 심링크인지 확인하고 거부한다 (dotfile 관리 도구와의 충돌 방지).
- 직전 내용은 가능한 경우 `settings.json.bak` (권한 0600) 으로 한 부 남긴다.
- `MONGSHELL_CLAUDE_SETTINGS` 로 대상 경로를 바꿀 수 있다 (개발·테스트용).

### 3. openclaw 상태 (선택 경로)

**원격 경로 (서버 에이전트, Decision #25).** openclaw 는 별도 서버 맥에서 돈다. 같은 상태 문서에 서버 맥 자체의 신호(전원·디스크, Decision #31)와 CI 러너 신호(Decision #75)가 `host` 로 함께 실린다.

```
[서버 맥] mongshell-openclaw-agent  ──(LaunchAgent, 기본 60초 주기)
   └─ Probe → posix_spawn: `openclaw channels status --probe`  (새 프로세스 그룹, 25초 초과 시 그룹 SIGTERM → 1초 → SIGKILL, 출력 읽기는 최대 27초)
        └─ 파싱 → ok / degraded / down  (공개 detail 은 허용 문자 필터 통과분만). 시간 초과는 따로 판정해 down + detail `응답 지연 · 25초 초과` 로 싣는다
        └─ 실행 실패·빈 출력 → 관측 실패: 게시·복구 카운트 없이 주기만큼 대기 후 종료(exit 75) → KeepAlive 재기동. 복구 직후 재확인이면 복구 전 판정으로 한 번 쓰고 종료 — 쿨다운 보존
   └─ 자동복구: 2회 연속 실패(시간 초과만 이어졌으면 4회, 복구 직후 재확인의 실패는 시간 초과로 셈) + 쿨다운 600초 → launchctl kickstart -k <게이트웨이 레이블>  (Decision #79)
   └─ HostProbe → IOKit 전원 정보 + 홈 볼륨 여유 공간 + CI 러너 (LaunchDaemon plist 개수, 레이블별 launchctl print)  (읽기만)
        └─ HostRules → 신호별·종합 ok / warning / critical  (읽을 신호가 없으면 host = null)
   └─ status.json 원자적 쓰기 (0644)
        { schema, checkedAt, health, detail, intervalSeconds, autoHeal, lastHeal, host, agentVersion }
        host = { health, power: { health, pluggedIn, charging, batteryPercent } | null,
                 disk: { health, availableBytes } | null,
                 runners: { health, running, total } | null } | null
        └─ tailscale funnel --https=8443 --set-path=/<토큰>
             → https://<서버 DNS 이름>:8443/<토큰>

[맥북] 메뉴바 앱  OpenClawModel ──(주기 폴링, 기본 60초 · 최소 15초)
   └─ OpenClawStatusClient → HTTPS GET (ephemeral 세션, 캐시 무시, 타임아웃 10초, 리다이렉트 거부, 200 응답만 본문을 64KB 까지 읽음)
        └─ 관대한 디코딩 (detail 은 제어문자·줄바꿈 문자→공백, 120자·유니코드 스칼라 480개) → OpenClawReading (마지막 성공 응답 보관)
             └─ OpenClawHealth: 🟢 ok / 🟡 degraded / 🔴 down(서버 보고) / ⚪️ unreachable  (서버 detail 은 ok·degraded·down 모두 팝오버·설정 상태 행에 표시)
             └─ ServerHostHealth: reported(ServerHost) / ⚪️ unreachable(last:)(마지막 값 유지) / absent(그리지 않음)
                  └─ reported 의 점 색은 ServerHostLevel: 🟢 ok / 🟡 warning / 🔴 critical
   └─ lastHeal.at 이 지금까지 본 것보다 늦어짐 → "openclaw 자동 재시작됨 (서버)" / "openclaw 자동 재시작 실패 (서버)" 알림 (첫 응답은 기준점)
   └─ host 의 신호별 레벨이 오름 → ServerHostAlertWatch → 전원·디스크·CI 러너 알림 (첫 응답은 기준점, 쿨다운에 눌린 상승은 쿨다운 뒤로 미룸)
```

- 게이트웨이 레이블은 설치 시 고정한다(`--gateway-label`). 에이전트 자신의 레이블은 탐색·명시 모두에서 제외된다.
- 재시작 후에도 `status.json` 의 `lastHeal` 로 복구 쿨다운을 이어받는다.
- 설치·제거는 `server/install.sh` / `server/uninstall.sh` (사용법: [server/README.md](../server/README.md)). 설치 옵션(주기·자동복구)은 데이터 폴더의 `options` 파일(`key=value`, 실행하지 않고 파싱)에 저장돼, 재실행 때 명시하지 않은 옵션은 지난 값을 이어받는다.

- **연락 두절(회색)** 판정은 마지막 **성공** 응답의 `checkedAt` 이 `max(180초, 3×intervalSeconds)` 를 넘었는가 하나다. 일시적 요청 실패는 마지막 성공이 신선한 동안 상태를 바꾸지 않는다. 빨강은 서버가 게이트웨이 다운을 보고했을 때만이다.
- `checkedAt` 이 없거나 해석 불가한 문서는 실패로 취급한다. 미래 시각(서버 시계가 빠름)은 그 값을 처음 받은 시각으로 고정해 나이를 잰다. 서버 시계가 느리면 그만큼 일찍 두절로 판정된다.
- 마지막 성공보다 `checkedAt` 이 이른 응답(겹친 요청의 늦은 도착)은 무시한다. 단 뒤로 간 폭이 두절 임계를 넘으면 늦은 도착이 아니라 서버 시계가 되돌려진 것이므로 새 기준으로 받아들이고, 복구 알림 판정도 기준점부터 다시 잡는다(그 사이의 복구는 알리지 않는다). 우리가 취소한 요청(URL 재적용 등)은 실패로 기록하지 않는다.
- HTTP 404 는 연락 두절이되 "주소 또는 토큰이 맞지 않습니다" 로 구분한다. 에러 문구에 URL(=토큰)을 넣지 않는다.
- 앱은 읽기 전용이다 — 재시작·자동복구·로그는 서버 몫이다.

**에이전트 버전 (`agentVersion`, Decision #81).** `install.sh` 가 빌드할 소스에서 `git describe --tags --match 'v[0-9]*' --long` 으로 정해 `--build-version` 으로 넘긴다 — 릴리스 tag 위면 `v1.2.0`, 그 뒤로 커밋이 N개면 `v1.2.0+N` (해시 없음). 에이전트는 `[0-9A-Za-z.+-]` 1–32자만 싣고, 정하지 못했거나 형식이 틀리면 `null` 이다. 앱은 문자열을 한 줄로 펴고 32자로 잘라 팝오버 "서버 확인" 시각 아래에 `에이전트 v1.2.0+3` 으로 보이며, 값이 없으면(구버전 에이전트 포함) 그 줄을 그리지 않는다. 버전은 표시 전용 — 어떤 판정에도 쓰지 않는다.

**서버 호스트 신호 (`host`, Decision #31 · CI 러너는 #75).**

| 키 | 값 | 비고 |
|---|---|---|
| `host` | 객체 또는 `null` | 읽을 수 있는 신호가 하나도 없으면 `null`. 구버전 에이전트는 키 자체가 없다 |
| `host.health` | `ok` / `warning` / `critical` | 있는 신호 중 가장 나쁜 것 — 메뉴바 서버 점의 색 |
| `host.power` | 객체 또는 `null` | 내장 배터리가 없거나 전원 공급원을 알 수 없으면 `null`. 시스템이 공급원을 말해 주지 않으면 배터리 자신의 상태가 `AC Power` / `Battery Power` 일 때만 그것을 쓴다 |
| `host.power.health` | `ok` / `warning` / `critical` | 어댑터 연결 → ok, 배터리 구동 → warning, 배터리 구동 + 잔량 20% 이하 → critical. 배터리 구동 + 잔량 불명 → warning |
| `host.power.pluggedIn` | bool | 시스템 전원 공급원이 내장 배터리가 아님 (UPS 전원 포함) |
| `host.power.charging` | bool | 배터리가 충전 중이라고 보고함 |
| `host.power.batteryPercent` | 0–100 정수 또는 `null` | 현재 용량 ÷ 최대 용량 (반올림, 100 상한). 둘 중 하나라도 읽지 못하면 `null` |
| `host.disk` | 객체 또는 `null` | 홈 볼륨이 여유 공간을 알려주지 않으면 `null` |
| `host.disk.health` | `ok` / `warning` / `critical` | 여유 20GB 미만 → warning, 5GB 미만 → critical (GB = 10⁹ 바이트) |
| `host.disk.availableBytes` | 정수 | 홈 디렉토리가 있는 볼륨의 여유. 비울 수 있는 공간을 포함한 값(`volumeAvailableCapacityForImportantUsage`)을 먼저 쓰고, 그 값이 없거나 0 이하면 일반 여유 공간으로 폴백 |
| `host.runners` | 객체 또는 `null` | `/Library/LaunchDaemons/com.github.actions-runner.*.plist` 가 하나도 없으면 `null`. 어느 레이블이든 `launchctl` 을 듣지 못하거나(실행 실패·시간 초과·신호 종료·빈 출력) 러너 전체 마감(10초)을 넘기면 신호 전체가 `null` — 재지 않은 판정을 싣지 않는다 |
| `host.runners.health` | `ok` / `warning` / `critical` | 전부 동작 → ok, 일부만 동작 → warning, 하나도 동작 안 함 → critical |
| `host.runners.running` | 0 이상 정수 | `launchctl print system/<레이블>` 의 최상위(탭 1개) 줄이 `state = running` 인 러너 수. 하위 블록의 `state = …` 는 보지 않는다. 그 밖의 응답(로드되지 않음 포함)은 동작 안 함 |
| `host.runners.total` | 1 이상 정수 | 설치된 러너 plist 개수 — 대수는 하드코딩하지 않는다. 레이블·사용자명·경로는 싣지 않는다 |

- **판정은 에이전트에만 있다** (`HostRules`). 앱은 임계값을 갖지 않고 `health` 문자열을 읽어 표시한다. 히스테리시스는 없다.
- `host` 아래의 문자열 값은 세 레벨 이름뿐이다. 호스트명·경로·OS 버전은 싣지 않는다 (에이전트 자신의 빌드 버전은 최상위 `agentVersion`).
- **앱의 읽기는 관대하다.** `host` 가 없거나 객체가 아니면 서버 점 없이 openclaw 판정만 읽는다. 읽을 수 없는 `health` 값(모르는 문자열, 문자열이 아닌 값)과 `health` 가 빠진 신호는 `warning` 으로 읽는다. `host.health` 가 없거나 `null` 이면 신호 중 가장 나쁜 것이 대신한다. `pluggedIn`·`charging` 은 JSON bool 만, `batteryPercent` 는 0–100 범위의 수만 받고 그 밖의 값은 그 수치만 비운다. `availableBytes` 가 음수이거나 수가 아니면 디스크 신호는 없는 것으로 본다. `host.runners` 는 객체가 아니면 없는 것으로 보고, `running`·`total` 은 0 이상 정수만 받으며, 둘 중 하나라도 쓸 수 없거나 `total` 이 0 이거나 `running > total` 이면 러너 신호는 없는 것으로 본다. `host.health` 가 없을 때의 "가장 나쁜 신호" 에는 러너도 들어간다.
- **신선도는 openclaw 점과 같은 규칙**이다 (위 연락 두절 판정). 문서가 오래되면 서버 점은 회색이 되고 마지막으로 받은 수치를 흐리게 남긴다. 마지막 성공 응답에 `host` 가 없었거나 성공 응답이 아직 없으면 서버 점을 그리지 않는다 (`.absent`). 두 점은 서로의 값에 영향을 주지 않는다.
- **표시 위치.** 메뉴바는 openclaw 표시(발자국 + 점) 아래에 서버 글리프 + 점을 쌓는다. 팝오버는 openclaw 섹션 아래에 서버 섹션(상태 한 마디 + 전원 줄 + 디스크 줄 + CI 러너 줄 `CI 러너 3/4`)을 두고, "서버 확인" 시각과 새로고침은 두 섹션 아래에 한 번만 둔다. 서버가 보내지 않은 신호의 줄은 그리지 않는다. 러너 신호는 메뉴바에 새 줄을 만들지 않는다 — 서버 점의 종합 판정에 합쳐진다.
- **상태 한 마디.** 종합 레벨의 원인이 된 신호를 말한다 (같은 레벨이면 전원 > 디스크 > 러너). 전원의 원인 문구 `어댑터 분리` / `배터리 부족` 은 문서가 `pluggedIn: false` 일 때만 쓰고, `true` 이거나 알 수 없으면 `전원 주의` / `전원 위험` 이다. 디스크는 `디스크 여유 부족` / `디스크 거의 가득`. 러너는 개수가 말하는 대로 `CI 러너 일부 중단`(0 < running < total) / `CI 러너 전부 중단`(running = 0) 이고, 레벨이 나쁜데 running == total 이면 `CI 러너 주의` / `CI 러너 위험` 이다. 아는 신호가 종합 레벨을 설명하지 못하면 `주의` / `위험` 이다.
- **알림** (`ServerHostAlertWatch`). 전원·디스크·CI 러너를 따로 추적한다.
  - 앱 시작 또는 상태 URL 변경 뒤 첫 성공 응답은 기준점이며 알리지 않는다. 기준점에 없던 신호가 나중에 처음 나타나면 ok 와 비교한다.
  - 레벨이 직전보다 오르면 알린다. 같은 레벨 유지·회복·연락 두절·신호가 사라진 것은 알리지 않는다.
  - 이미 알린 레벨 이하로 다시 오르면 마지막 알림 후 3600초(쿨다운)가 지나야 알린다. 그보다 높은 레벨로의 상승은 즉시 알린다.
  - 쿨다운에 눌린 상승은 미뤄 둔다. 쿨다운이 끝난 뒤 첫 관측에서 그 신호가 여전히 ok 보다 나쁘면 그때의 레벨로 한 번 알리고, 그 사이 ok 로 회복했으면 알리지 않는다.
  - 쿨다운은 맥북의 시계로 잰다. 마지막 알림 이후 경과 시간이 음수(시계가 되돌려짐)이면 쿨다운이 끝난 것으로 본다.
  - 통지 게이트(`Preferences.showsOpenClaw` 가 참이고 앱 번들로 실행 중)가 닫힌 상태에서 성공 응답이 도착하면, 감시는 그 응답을 비교에 쓰지 않고 초기화된다 (`observe(_:now:canNotify: false)`) — 기준점·쿨다운·미뤄 둔 알림을 버린다. 그렇게 초기화된 뒤에는 게이트가 열린 상태에서 받은 첫 성공 응답이 기준점이다.
  - 초기화는 게이트가 닫히는 순간이 아니라 닫힌 상태에서 성공 응답이 도착할 때 일어난다. 닫았다가 다음 성공 응답이 오기 전에 다시 열면(폴링 주기 안의 전환, 닫힌 동안 요청이 모두 실패) 기준점·쿨다운·미뤄 둔 알림이 그대로 남는다.
  - 감시 대상은 `OpenClawReading` 이 채택한 마지막 성공의 `host` 이되, **그 문서가 신선할 때만**이다 (`ServerHostHealth.reportedHost` — 두절이면 `nil`, 곧 "신호 없음" 과 같은 취급이라 기준점은 유지되고 알림은 없다). 무시된 늦은 도착 응답은 알림 판정에 들어가지 않고, 에이전트가 멈춘 뒤 funnel 이 계속 서빙하는 낡은 문서(요청은 성공)도 들어가지 않는다. 다시 신선해진 첫 관측에서 그 신호가 여전히 ok 보다 나쁘면 그때 알린다.
  - 알림 식별자는 신호별로 고정(`server-host-power`, `server-host-disk`, `server-host-runners`)이라 새 알림이 같은 신호의 옛 알림을 대체한다.

  | 신호 · 레벨 | 제목 | 본문 |
  |---|---|---|
  | 전원 warning, `pluggedIn: false` | `서버 전원 어댑터 분리됨` | `배터리 82%로 동작 중입니다.` (잔량 불명: `배터리로 동작 중입니다.`) |
  | 전원 critical, `pluggedIn: false` | `서버 배터리 부족` | `배터리 18% — 어댑터를 연결하지 않으면 곧 꺼집니다.` (잔량 불명: 뒤 문장만) |
  | 전원 warning, `pluggedIn` 이 `true` 이거나 불명 | `서버 전원 주의` | 팝오버 전원 줄과 같은 문구 — `배터리 82% · 충전 중` (수치가 하나도 없으면 `서버의 전원 상태를 확인하세요.`) |
  | 전원 critical, `pluggedIn` 이 `true` 이거나 불명 | `서버 전원 위험` | 위와 같음 |
  | 디스크 warning | `서버 디스크 여유 부족` | `여유 18GB` |
  | 디스크 critical | `서버 디스크 거의 가득` | `여유 4.2GB` |
  | 러너, 일부만 동작 | `서버 CI 러너 일부 중단` | `4대 중 3대 동작` |
  | 러너, 하나도 동작 안 함 | `서버 CI 러너 전부 중단` | `4대 중 0대 동작` |
  | 러너 warning / critical 인데 전부 동작 | `서버 CI 러너 주의` / `서버 CI 러너 위험` | 위와 같은 형식 |

상태 URL 이 없거나 사용자가 `Claude만` 을 고르면 메뉴바·팝오버·알림에 아무 흔적도 남지 않는다 (`Preferences.showsOpenClaw`). 서버 호스트 표시와 알림도 같은 조건을 따르며 별도 토글이 없다 — `showsOpenClaw` 가 참이고 서버가 `host` 를 보낼 때만 나타난다. 설정의 URL 입력칸은 PHILOSOPHY 원칙 2 의 설정 진입점 예외로 항상 보인다.

### 4. GitHub PR 폴링 (선택 경로)

설정의 "GitHub 표시" 를 켠 경우에만 돈다 (Decision #45). 같은 status item 의 두 번째 영역이며, 기본값은 꺼짐이다.

```
GitHubModel.pollLoop()  ──(@MainActor, Task — AppDelegate 가 소유·주입, 싱글턴 아님)
   └─ GitHubCredentialStore            ← Keychain (자체 PAT → gh CLI 항목 순)
        ├─ 자체 PAT: service Config.ownKeychainService, account "github-pat"
        └─ gh CLI:  service "gh:github.com" (account = GitHub 사용자명, service 만으로 조회, 읽기 전용)
             └─ go-keyring 접두 디코딩: `go-keyring-base64:`+base64 / `go-keyring-encoded:`+hex / 평문
   └─ GitHubAPIClient.fetch(token:now:)
        └─ POST https://api.github.com/graphql   (BoundedHTTP: 타임아웃 20초, 리다이렉트 거부, 본문 4MB 캡, 2xx 만 본문 읽음)
             Authorization: bearer …
             User-Agent: mongshell-menubar/<CFBundleShortVersionString, 번들 밖에서는 dev>
             본문: search alias 2개 (mine / merged:>=7일 전, 각 first: 20, sort:updated-desc)
                   + PR 당 id · headRefOid · mergeable · mergeStateStatus · reviewDecision
                   + PR 당 마지막 커밋의 statusCheckRollup { state, contexts(first: 30) { totalCount, nodes } }
                   + rateLimit { cost remaining limit resetAt }
        └─ interpret(statusCode:headers:data:)  →  .snapshot / .unauthorized(401) / .rateLimited(403·429 + retry-after, x-ratelimit-remaining: 0, errors[].type == RATE_LIMITED)
             그 밖의 코드(3xx·5xx)·`data` 없는 본문 → throws GitHubAPIError (배너)
        └─ parse() → GitHubSnapshot  (alias 누락은 빈 목록, PullRequest 아닌 노드·rateLimit 누락은 건너뜀, 검사는 (워크플로 id, event)별 가장 최근 실행(runNumber)보다 앞선 실행의 CheckRun 을 버린 뒤 (워크플로 이름 ?? 앱 slug, job 이름)별·StatusContext 는 context 별 최신 실행 하나, x-oauth-scopes 에 repo 없음 → tokenScopesLackRepo)
   └─ @Published snapshot / loadState / glance 갱신
        ├─ GitHubMenuBarView       (헤어라인 · 글리프(머지 가능한 내 PR 있으면 merge 초록) · 점 · 처리할 PR 수 — 0 이면 숫자 없음)
        ├─ GitHubHoverSummaryView  (CI 줄 + 내 PR N · 막힘 N + 머지 가능 N 세 줄)
        ├─ GitHubPopoverView       (배너 + 섹션 2개: 내 PR 8 · 최근 머지 3, 넘치면 "외 N건"; 내 PR 의 머지 가능 행에 squash 머지 버튼)
        └─ GitHubSettingsSection   (토큰 출처 · PAT 입력 · 갱신 주기 · 레포 숨기기)
   └─ GitHubModel.merge(_:expectedHead:) → GitHubAPIClient.merge(…) → interpretMerge   (팝오버의 머지 버튼 클릭에서만)
```

- 주기 (`GitHubPollPolicy.nextAutoWait`): 백그라운드 3분(설정 1~10분, `Config.githubPollRange`) · 팝오버를 열면 즉시 1회 · 내 PR 에 시작한 지 60분 이내인 실행중 검사가 있고 상태가 정상(`loaded`)이면 팝오버 열림과 무관하게 30초(`Config.githubFastPollSeconds`), 그 외 base · 잔량 200 미만, `.rateLimited`, 또는 한도 헤더 없는 403·429(`GitHubPollPolicy.backsOff` — GitHub 보조 한도일 수 있어 같이 물러나되, 상태는 한도로 단정하지 않고 오류 배너 그대로)이면 지수 백오프(`base * 2^n`, 상한 3600초). 30초의 판정(`GitHubSnapshot.hasFreshRunningChecks`)은 `effectiveChecks` 가 진행중인 PR 의 running 칩 중 `startedAt` 이 `Config.githubFastPollMaxRunningAge`(60분) 이내인 것이 있는가이다 (5분까지 미래인 시작은 시계 오차로 보아 세고 — `Config.githubFastPollClockSkew` — 그보다 미래면 세지 않는다) — queued 칩만 있거나, rollup 만 진행중이거나, 시작 시각이 없는 running 은 세지 않는다. 표시(주황 점·hover CI 줄)는 대기·집계 진행중도 진행중으로 보이지만, 빠른 주기는 위 조건에서만이다 (이유는 Decision #45 후속 (#51)). 백오프 중엔 30초 주기를 쓰지 않고, 팝오버를 열어도 즉시 요청을 보내지 않는다. 팝오버 닫힘은 요청·재시작을 일으키지 않는다.
- 401 이나 PAT 저장 실패면 자동 폴링을 멈추고, 팝오버를 열어도 요청하지 않는다. 재개는 수동뿐이다 — 팝오버의 재시도·새로고침, PAT 적용·지우기, gh 토큰 다시 시도, "GitHub 표시" 다시 켜기. 재개한 요청이 다시 401 이면 다시 멈춘다.
- 판정 (`GitHubPullRequest.swift`, 순수 값): 배지 우선순위 충돌 > 검사 실패 > 변경 요청 > Draft > 리뷰 대기 > 승인 > 머지 가능. 머지 가능 = GitHub 의 `mergeStateStatus == CLEAN`(브랜치 보호·필수 검사·필수 리뷰의 종합) + Draft 아님 + 검사 실패·진행중 아님이고, 그 필드가 없거나 모르는 값(unknown)이면 승인 + 검사 통과(또는 검사 없음) + `statusCheckRollup.state` 가 대기(PENDING/EXPECTED) 아님 + `mergeable == MERGEABLE` 이다 — 아직 보고되지 않은 필수 검사는 칩(contexts 노드)으로 오지 않아, 칩이 전부 통과여도 rollup 만이 그것을 안다. 그 밖에는 승인이면 승인, 아니면 리뷰 대기. 검사는 두 단계로 정리한다. 먼저 밀려난 실행을 버린다 — CheckRun 의 `checkSuite.workflowRun` 에서 (워크플로 id `workflow.databaseId`, `event`)별로 가장 큰 `runNumber` 를 찾고, 그보다 작은 `runNumber` 의 CheckRun 은 새 실행에 같은 job 이 아직 없어도 버린다. `event` 가 키에 있어 같은 워크플로의 `push` 실행과 `pull_request` 실행은 서로 가리지 않는다. 워크플로 id·`event`·`runNumber` 중 하나라도 읽지 못한 CheckRun, `workflowRun` 이 없는 다른 앱의 CheckRun, StatusContext 는 이 단계에서 버리지 않는다. 다음으로 남은 것 중 같은 검사의 재실행(같은 실행의 attempt 2 등 — `runNumber` 가 같다)끼리 묶어 가장 최근 실행 하나만 남긴다. 묶는 키는 CheckRun 이면 (워크플로 이름 — 없으면 앱 slug, job 이름)이고 — job 이름은 커밋 안에서 고유하지 않다 — 둘 다 읽지 못한 CheckRun 은 어느 것과도 묶지 않는다. StatusContext 는 `context` 이름이 키다. 가장 최근은 `startedAt`(없으면 `completedAt`)이 늦은 것이고, 시각이 없는 실행은 아직 시작하지 않은 최신 실행으로 보아 시각이 있는 실행보다 늦다고 친다 — 둘 다 없으면 응답에서 뒤에 온 것. 남은 칩은 원래 순서를 지킨다. PR 의 검사 상태(검사 실패·진행중·통과)는 목록을 끝까지 받았으면(`totalCount` == 읽은 검사 수 — 정리로 버린 것도 읽은 수에 든다 — 30개를 넘거나, 모르는 종류의 노드를 건너뛰었거나, `totalCount` 가 없으면 끝까지가 아니다) 정리된 칩에서 — 실패가 하나라도 있으면 실패, 아니면 running/queued 가 있으면 진행중, 그 밖은 통과 — 읽고, 아니면(또는 칩이 비었으면) `statusCheckRollup.state` 를 쓴다 (`effectiveChecks` — 배지·메뉴바 숫자·점 색·hover·"검사 진행중" 배지가 모두 이 하나를 읽는다). 메뉴바 숫자 = 내 PR 중 막힌 것(충돌·검사 실패·변경 요청). 점은 막힘 있으면 빨강, 막힘 없이 내 PR 중 검사 진행중(`effectiveChecks` 가 진행중)이 있으면 주황, 그 밖은 초록, 토큰 없음·거부·401·오류는 회색. 글리프는 지금 머지 가능한 내 PR 이 하나라도 있으면 초록 알약(`Palette.mergePillFill`, 14×13pt) 위의 흰 bold `arrow.triangle.merge`(`colorCoding` 대상 아님), 없으면 `arrow.triangle.pull` 회색이다 (Decision #52 후속 (#56)) — 두 글리프는 알약 폭(14pt)의 고정 칸에 그려, 바뀌어도 status item 폭이 움직이지 않는다. 지금 머지 가능 = 팝오버에 그려지는 내 PR 행(숨긴 레포 제외, 섹션 상한 `Config.githubSectionCaps.mine` 까지 — 넘친 PR 은 "외 N건" 으로 접혀 버튼이 없다) 중 팝오버 머지 버튼과 같은 `GitHubMergePolicy.canOffer(_, section: .mine)` 이 참인 것에서, 그 PR 의 머지 요청이 나가 있거나(`.merging`) 끝난(`.merged` — search 색인이 늦어 목록에 남은 동안) 것을 뺀 수다. 실패(`.failed`)는 버튼이 다시 나오므로 센다. 스냅샷을 읽지 않는 상태(토큰 없음·401 등)에서는 0 이고, 메뉴바 숫자·점에는 더하지 않는다. hover 셋째 줄(CI 줄·내 PR 줄 다음)은 "머지 가능 N · <레포 이름> #<번호> 외 K" 이고, 0 이면 "머지 가능 0" 으로 없음을 말한다. 모르는 값은 통과로 읽지 않는다 — CheckRun 모르는 `status` → queued, `COMPLETED` + 모르는 `conclusion` → failed, rollup 모르는 `state` → pending, `mergeable` 모르는 값 → unknown(충돌 아님), `mergeStateStatus` 모르는 값·누락 → unknown(CLEAN 아님). 검사 칩은 전부 통과·건너뜀이면 "검사 N개 통과 · 소요" 하나로 접는다.
- hover CI 줄 (`GitHubCILine`, 순수 값 — Decision #45 후속 (#51)): 대상은 내 PR 이고, PR 마다 `effectiveChecks` 로 읽는다 — 이미 실패한 PR 은 남은 칩이 돌고 있어도 실패다. 진행중 PR 이 있으면 "CI N · <레포 이름> #<번호> <검사 이름> <경과>…"(N = 진행중 PR 수, 주황) — 고르는 검사는 진행중 PR 전체의 running 칩 중 `startedAt` 이 가장 이른 것(같으면·시각이 없으면 목록 순서)이고, 경과는 팝오버의 running 칩과 같은 `TimeText.duration` 표기로 hover 가 떠 있는 동안 1초마다 오른다. 시각 있는 running 칩이 없으면 경과 대신 "진행중", running 칩이 없고 queued 만 있으면 목록 순서상 첫 PR 의 첫 queued 칩에 "대기", 칩 없이 rollup 만 진행중이면 검사 이름 자리에 "검사". 진행중이 없고 실패 PR 이 있으면 "CI N · #<번호> <첫 실패 검사 이름> 실패"(N = 실패 PR 수, 빨강, 실패 칩이 없으면 "검사"). 둘 다 없고 검사 있는 PR 이 하나라도 있으면 "CI 모두 통과", 없으면 "CI 없음" — 둘 다 숫자 없음. 둘째 줄은 "내 PR N · 막힘 M · <첫 막힘 사유>".
- 머지 (Decision #49): 버튼은 "내 PR" 섹션의 행 중 `mergeStateStatus == CLEAN` · Draft 아님 · `id`·`headRefOid` 를 받았고 PR 링크가 https·github.com 검사를 통과한 것에만 그린다 (`GitHubMergePolicy.canOffer`). 한 번 클릭하면 그 순간 행에 보이는 head SHA 로 `GitHubModel.merge(_:expectedHead:)` 를 부르고, 모델이 스냅샷의 `mine` 에서 같은 id 의 PR 을 다시 꺼내 판정한다 (`GitHubMergePolicy.gate`): `loadState` 가 loaded·loading·rateLimited 가 아니거나, 그 PR 의 요청이 나가 있거나 머지됐거나, 다시 꺼낸 PR 이 `canOffer` 를 통과하지 못하면 보내지 않고, 그 목록이 토큰을 바꾸기(PAT 적용·지우기) 전에 받은 것이면 — 바꾼 뒤에도 새 토큰의 답이 오기까지 목록과 `loadState` 는 그대로 남는다 — 보내지 않고 행에 "토큰이 바뀌어 목록을 다시 받는 중이에요" 를 남기고(목록을 받은 세대와 지금 세대를 비교), 목록을 받은 토큰 출처(PAT · gh 계정)가 지금 풀리는 출처와 다르면 — 앱 밖의 `gh auth switch` 는 세대를 바꾸지 않는다 — 같은 사유를 남기고 목록을 다시 받으며(성공 직후 갱신과 같은 조건), 그 head 가 클릭한 행이 보인 head 와 다르면 보내지 않고 행에 "그 사이 새 커밋이 올라왔어요" 를 남긴다. 통과하면 `fetch` 와 같은 토큰 결정 순서·같은 엔드포인트·같은 `BoundedHTTP` 세션(타임아웃 20초, 리다이렉트 거부, 본문 캡, 2xx 만 본문 읽음)으로 mutation 하나를 보낸다 — `mergePullRequest(input: { pullRequestId, mergeMethod: SQUASH, expectedHeadOid }) { pullRequest { number state mergedAt } }`, 두 id(다시 꺼낸 PR 의 node id, 클릭한 행이 보인 head)는 GraphQL 변수로. 커밋 제목·본문 인자와 브랜치 삭제 인자는 없다. 응답 해석(`interpretMerge`): `pullRequest.state == MERGED` → 성공(즉시 갱신 — `GitHubPollPolicy.refreshesOnOpen` 과 같은 조건. 백오프 중이면 다음 정기 깨어남까지, 요청이 나가 있는 동안 401·PAT 저장 실패로 멈췄으면 수동 재개까지 미룬다 — 멈춘 상태에서는 머지를 보내지 않으므로 멈춤은 이 경우뿐이다) · 401 → `.unauthorized`(§ 401 정지와 같음) · 403/429 + 한도 헤더 또는 `RATE_LIMITED` → 한도 · 그 밖의 403 또는 `errors[].type == FORBIDDEN` → 권한 없음 · `head branch was modified` 문구(대소문자 무시) → head 바뀜 · 그 밖의 `errors[].message`(`expectedHeadOid` 변수 검증 오류 포함) → 머지 불가(GitHub 메시지를 한 줄로 줄이고 토큰 모양 문자열은 가리고 120자로 자름) · errors 없이 MERGED 가 아닌 `state` → 머지 불가(그 서버 값도 같은 정규화) · 깨진 본문·3xx·5xx·전송 실패 → 오류. 실패 사유는 그 행 아래 한 줄로 보이고 다음 성공한 갱신까지 남는다. 성공한 PR 은 목록에서 빠질 때까지(search 색인 지연) 버튼 대신 "머지됨" 이다.
- 링크: 응답의 URL 은 https 만 받는다 (검사 링크 `detailsUrl`·`targetUrl` 은 CI 가 채우는 제3자 값). PR 링크는 그에 더해 `github.com` 호스트일 때만 연다.
- 한도: 토큰당 시간당 5,000 포인트. 요청당 1 포인트 안팎 (노드 수에 비례). 팝오버 바닥에 쓴 비율을 작은 링으로 보이고, 정확한 `remaining / limit` 는 툴팁에만 둔다.
- 숨긴 레포(`Preferences.githubHiddenRepos`, "owner/name" 소문자)는 스냅샷을 읽는 모든 소비자가 `hiding(_:)` 을 거치므로 메뉴바 숫자·hover·팝오버·주기 판정 어디에도 세지 않는다.
- 꺼져 있으면 폴링도 없고 메뉴바·팝오버·hover 어디에도 흔적이 없다. 설정의 "GitHub 표시" 토글은 PHILOSOPHY 원칙 2 의 설정 진입점 예외로 항상 보인다. 켜는 동작이 첫 Keychain 읽기이며, gh 항목 접근 거부는 세션 동안 기억해 설정에서만 재시도한다.

## Auth

**단일 사용자·단일 계정 전제.** 서버 세션이나 멀티유저 개념이 없다.

읽기 우선순위:

1. **자체 OAuth 토큰** — Keychain (`Config.ownKeychainService`)
2. **Claude Code CLI 토큰** — Keychain `Claude Code-credentials`, 없으면 `~/.claude/.credentials.json`

Claude Code 사용자는 로그인 없이 기존 토큰을 재사용한다. 다른 앱의 Keychain 항목을 읽으므로 **첫 실행 시 "키체인 접근 허용" 프롬프트**가 뜬다.

토큰이 없을 때의 로그인 흐름은 **OAuth 2.0 Authorization Code + PKCE** 이며, Claude Code 의 client_id 를 재사용한다 (ToS 회색지대 — Decision 2).

- **1순위: 루프백** (`LoopbackServer`, RFC 8252) — 임의 free 포트를 열고 브라우저가 `/callback?code=…&state=…` 로 돌아오면 자동 완료.
- **폴백: 수동 붙여넣기** — 루프백 리다이렉트가 거부되면 콘솔 콜백 페이지에 표시된 `code#state` 를 앱에 붙여넣는다.

**인증 경계**: 토큰은 Keychain 에만 저장되고 `api.anthropic.com` / `platform.claude.com` 외 어디에도 전송되지 않는다. 텔레메트리·크래시 리포터가 없다. 토큰을 싣는 두 요청 — 사용량 요청(`UsageAPIClient`, Bearer 토큰)과 토큰 엔드포인트 요청(`OAuthTokenClient`, `refresh_token` 또는 인증 코드 + `code_verifier` 가 든 POST 바디) — 은 모두 `BoundedHTTP` 세션으로 보내 리다이렉트를 따르지 않으므로, 3xx 로 토큰·인증 코드가 다른 호스트에 보내지는 경로가 코드에서 막혀 있다.

**openclaw 상태 URL** (서버 에이전트): 경로의 토큰(32자리 hex)이 유일한 접근 통제인 읽기 전용 capability URL 이다. Claude 자격증명과 무관하며, `server/install.sh --rotate-token` 으로 폐기·재발급한다. 앱은 이것을 Keychain 이 아니라 `Preferences`(UserDefaults)에 두고, userinfo 없는 https 주소만 받는다.

**GitHub 토큰** (GitHub PR 영역, Decision #45): Claude 자격증명과 별개의 읽기 우선순위다.

1. **자체 PAT** — Keychain `Config.ownKeychainService`, account `github-pat` (설정에서 붙여넣은 classic PAT, `repo` 권한)
2. **gh CLI 토큰** — Keychain service `gh:github.com` (account 는 GitHub 사용자명이라 service 만으로 조회, 여러 항목이면 임의의 하나). gh 가 go-keyring 으로 감싼 값(`go-keyring-base64:` 접두 등)은 읽을 때 푼다. 다른 앱의 항목이라 **첫 읽기 — 설정 토글을 켜는 동작 — 에 "키체인 접근 허용" 프롬프트**가 뜨고, 거부는 세션 동안 기억한다.

토큰은 Keychain 에만 있고 `api.github.com` 한 호스트에만 전송된다 — 리다이렉트를 따르지 않으므로 3xx 로 다른 호스트에 보내지는 경로가 없다. 폴링은 query 뿐이고, 쓰기는 사용자가 버튼을 눌러 보낸 squash 머지 mutation 하나다 (§ 4, Decision #49).

## Infrastructure

호스팅 인프라가 없다. 배포는 로컬 빌드 산출물이다. openclaw 원격 감시를 쓰면 사용자가 운영하는 서버 맥에 에이전트를 로컬 빌드로 설치한다.

| 경로 | 도구 | 서명 | 용도 |
|---|---|---|---|
| 로컬 사용 | `scripts/make_app.sh` | Apple Development 인증서(무료 Apple ID, 선택)가 있으면 그것, 없으면 팀 ID 없는 서명 — 자기 서명·ad-hoc (Decision #68) | 각자 빌드해서 쓰기 (기본 경로는 Apple 계정 불필요) |
| 지인 공유 | `scripts/release.sh` | Developer ID + 공증 | `.dmg` 배포 (Gatekeeper 통과, 업데이트 후 토큰 유지) |
| 서버 에이전트 | `server/install.sh` | 없음 (서버 맥에서 release 빌드) | openclaw·서버 호스트 감시 에이전트 LaunchAgent 등록 + Tailscale Funnel 공개 (8443) |

- **App Sandbox 미사용** — Keychain 의 타 앱 항목(Claude Code 자격증명, gh CLI 토큰) 접근이 샌드박스와 양립하지 않는다.
- 버전 SSOT 는 git tag (`v1.0.0`, `v1.0.1` …) 이며 GitHub Releases 가 배포 채널이다.
- 외부 SaaS 의존은 Anthropic 호스트다. openclaw 원격 감시를 쓰면 Tailscale(Funnel)이, GitHub PR 영역을 켜면 `api.github.com` 이 추가된다.

## 알려진 제약

- 사용량 엔드포인트는 **비공개**다. 스키마·헤더가 예고 없이 바뀌거나 차단될 수 있다.
- `User-Agent: claude-code/<version>` 이 없으면 공격적인 rate limit 버킷으로 떨어져 지속적인 429 를 받는다.
- `swift run` 으로 맨 바이너리를 실행하면 UserNotifications 가 앱 번들을 요구해 크래시한다.
