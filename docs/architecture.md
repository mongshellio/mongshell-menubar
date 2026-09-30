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
| 최소 플랫폼 | macOS 14 |
| UI | SwiftUI 뷰 + AppKit 호스팅 (`NSStatusItem`, `NSPopover`, `NSWindow`) |
| 동시성 | Swift Concurrency (`@MainActor` 격리, `Task`, `async/await`) |
| 네트워크 | `URLSession` (Foundation) |
| 로컬 리스너 | `Network.framework` (`NWListener`) — OAuth 루프백 |
| 자격증명 | Security.framework Keychain (generic password) |
| 설정 영속화 | `UserDefaults` (`@AppStorage`) |
| 알림 | UserNotifications (앱 번들 필수) |
| 로그인 항목 | ServiceManagement (`SMAppService.mainApp`) |
| 외부 프로세스 | Foundation `Process` — `openclaw` CLI, `launchctl` (서버 에이전트 전용 — 메뉴바 앱은 셸아웃하지 않는다) |
| 호스트 신호 읽기 (서버 에이전트) | IOKit (`IOKit.ps` — 전원 공급원·내장 배터리), Foundation `URL` 리소스 값 (홈 볼륨 여유 공간) |
| 상태 공개 (서버 에이전트) | Tailscale Funnel — 오픈소스판 `tailscaled` 가 상태 파일을 정적 서빙 (포트 8443) |
| 외부 패키지 의존성 | **없음** |

DB·백엔드 서비스가 없다. 메뉴바 앱은 단일 프로세스 클라이언트다. 예외는 선택 기능인 openclaw 감시로, 사용자가 운영하는 서버 맥에 헤드리스 에이전트(`mongshell-openclaw-agent`)를 둔다 — openclaw 게이트웨이와 서버 맥 자체의 신호(전원·디스크)를 판정해 네트워크 리스너 없이 상태 파일만 쓰고, 공개는 tailscaled 가 한다.

## Data Flow

### 1. 사용량 폴링 (주 경로)

```
UsageModel.pollLoop()  ──(@MainActor, Task)
   └─ CredentialStore.token()      ← Keychain (자체 토큰 → Claude Code 토큰 순)
   └─ UsageAPIClient.fetch(token:)
        └─ GET https://api.anthropic.com/api/oauth/usage
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
- 토큰이 없으면 네트워크를 타지 않고 `UsageSnapshot.sample` 로 렌더한다.

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

**원격 경로 (서버 에이전트, Decision #25).** openclaw 는 별도 서버 맥에서 돈다. 같은 상태 문서에 서버 맥 자체의 신호(전원·디스크)가 `host` 로 함께 실린다 (Decision #31).

```
[서버 맥] mongshell-openclaw-agent  ──(LaunchAgent, 기본 60초 주기)
   └─ Probe → Process: `openclaw channels status --probe`
        └─ 파싱 → ok / degraded / down  (공개 detail 은 허용 문자 필터 통과분만)
   └─ 자동복구: 2회 연속 실패 + 쿨다운 600초 → launchctl kickstart -k <게이트웨이 레이블>
   └─ HostProbe → IOKit 전원 정보 + 홈 볼륨 여유 공간  (읽기만)
        └─ HostRules → 신호별·종합 ok / warning / critical  (읽을 신호가 없으면 host = null)
   └─ status.json 원자적 쓰기 (0644)
        { schema, checkedAt, health, detail, intervalSeconds, autoHeal, lastHeal, host }
        host = { health, power: { health, pluggedIn, charging, batteryPercent } | null,
                 disk: { health, availableBytes } | null } | null
        └─ tailscale funnel --https=8443 --set-path=/<토큰>
             → https://<서버 DNS 이름>:8443/<토큰>

[맥북] 메뉴바 앱  OpenClawModel ──(주기 폴링, 기본 60초 · 최소 15초)
   └─ OpenClawStatusClient → HTTPS GET (ephemeral 세션, 캐시 무시, 타임아웃 10초, 리다이렉트 거부, 200 응답만 본문을 64KB 까지 읽음)
        └─ 관대한 디코딩 (detail 은 제어문자·줄바꿈 문자→공백, 120자·유니코드 스칼라 480개) → OpenClawReading (마지막 성공 응답 보관)
             └─ OpenClawHealth: 🟢 ok / 🟡 degraded / 🔴 down(서버 보고) / ⚪️ unreachable  (서버 detail 은 ok·degraded·down 모두 팝오버·설정 상태 행에 표시)
             └─ ServerHostHealth: reported(ServerHost) / ⚪️ unreachable(last:)(마지막 값 유지) / absent(그리지 않음)
                  └─ reported 의 점 색은 ServerHostLevel: 🟢 ok / 🟡 warning / 🔴 critical
   └─ lastHeal.at 이 지금까지 본 것보다 늦어짐 → "openclaw 자동 재시작됨 (서버)" / "openclaw 자동 재시작 실패 (서버)" 알림 (첫 응답은 기준점)
   └─ host 의 신호별 레벨이 오름 → ServerHostAlertWatch → 전원·디스크 알림 (첫 응답은 기준점, 쿨다운에 눌린 상승은 쿨다운 뒤로 미룸)
```

- 게이트웨이 레이블은 설치 시 고정한다(`--gateway-label`). 에이전트 자신의 레이블은 탐색·명시 모두에서 제외된다.
- 재시작 후에도 `status.json` 의 `lastHeal` 로 복구 쿨다운을 이어받는다.
- 설치·제거는 `server/install.sh` / `server/uninstall.sh` (사용법: [server/README.md](../server/README.md)). 설치 옵션(주기·자동복구)은 데이터 폴더의 `options` 파일(`key=value`, 실행하지 않고 파싱)에 저장돼, 재실행 때 명시하지 않은 옵션은 지난 값을 이어받는다.

- **연락 두절(회색)** 판정은 마지막 **성공** 응답의 `checkedAt` 이 `max(180초, 3×intervalSeconds)` 를 넘었는가 하나다. 일시적 요청 실패는 마지막 성공이 신선한 동안 상태를 바꾸지 않는다. 빨강은 서버가 게이트웨이 다운을 보고했을 때만이다.
- `checkedAt` 이 없거나 해석 불가한 문서는 실패로 취급한다. 미래 시각(서버 시계가 빠름)은 그 값을 처음 받은 시각으로 고정해 나이를 잰다. 서버 시계가 느리면 그만큼 일찍 두절로 판정된다.
- 마지막 성공보다 `checkedAt` 이 이른 응답(겹친 요청의 늦은 도착)은 무시한다. 단 뒤로 간 폭이 두절 임계를 넘으면 늦은 도착이 아니라 서버 시계가 되돌려진 것이므로 새 기준으로 받아들이고, 복구 알림 판정도 기준점부터 다시 잡는다(그 사이의 복구는 알리지 않는다). 우리가 취소한 요청(URL 재적용 등)은 실패로 기록하지 않는다.
- HTTP 404 는 연락 두절이되 "주소 또는 토큰이 맞지 않습니다" 로 구분한다. 에러 문구에 URL(=토큰)을 넣지 않는다.
- 앱은 읽기 전용이다 — 재시작·자동복구·로그는 서버 몫이다.

**서버 호스트 신호 (`host`, Decision #31).**

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

- **판정은 에이전트에만 있다** (`HostRules`). 앱은 임계값을 갖지 않고 `health` 문자열을 읽어 표시한다. 히스테리시스는 없다.
- `host` 아래의 문자열 값은 세 레벨 이름뿐이다. 호스트명·경로·버전은 싣지 않는다.
- **앱의 읽기는 관대하다.** `host` 가 없거나 객체가 아니면 서버 점 없이 openclaw 판정만 읽는다. 읽을 수 없는 `health` 값(모르는 문자열, 문자열이 아닌 값)과 `health` 가 빠진 신호는 `warning` 으로 읽는다. `host.health` 가 없거나 `null` 이면 신호 중 가장 나쁜 것이 대신한다. `pluggedIn`·`charging` 은 JSON bool 만, `batteryPercent` 는 0–100 범위의 수만 받고 그 밖의 값은 그 수치만 비운다. `availableBytes` 가 음수이거나 수가 아니면 디스크 신호는 없는 것으로 본다.
- **신선도는 openclaw 점과 같은 규칙**이다 (위 연락 두절 판정). 문서가 오래되면 서버 점은 회색이 되고 마지막으로 받은 수치를 흐리게 남긴다. 마지막 성공 응답에 `host` 가 없었거나 성공 응답이 아직 없으면 서버 점을 그리지 않는다 (`.absent`). 두 점은 서로의 값에 영향을 주지 않는다.
- **표시 위치.** 메뉴바는 openclaw 표시(발자국 + 점) 아래에 서버 글리프 + 점을 쌓는다. 팝오버는 openclaw 섹션 아래에 서버 섹션(상태 한 마디 + 전원 줄 + 디스크 줄)을 두고, "서버 확인" 시각과 새로고침은 두 섹션 아래에 한 번만 둔다. 서버가 보내지 않은 신호의 줄은 그리지 않는다.
- **상태 한 마디.** 종합 레벨의 원인이 된 신호를 말한다 (둘이 같은 레벨이면 전원). 전원의 원인 문구 `어댑터 분리` / `배터리 부족` 은 문서가 `pluggedIn: false` 일 때만 쓰고, `true` 이거나 알 수 없으면 `전원 주의` / `전원 위험` 이다. 디스크는 `디스크 여유 부족` / `디스크 거의 가득`. 아는 신호가 종합 레벨을 설명하지 못하면 `주의` / `위험` 이다.
- **알림** (`ServerHostAlertWatch`). 전원과 디스크를 따로 추적한다.
  - 앱 시작 또는 상태 URL 변경 뒤 첫 성공 응답은 기준점이며 알리지 않는다. 기준점에 없던 신호가 나중에 처음 나타나면 ok 와 비교한다.
  - 레벨이 직전보다 오르면 알린다. 같은 레벨 유지·회복·연락 두절·신호가 사라진 것은 알리지 않는다.
  - 이미 알린 레벨 이하로 다시 오르면 마지막 알림 후 3600초(쿨다운)가 지나야 알린다. 그보다 높은 레벨로의 상승은 즉시 알린다.
  - 쿨다운에 눌린 상승은 미뤄 둔다. 쿨다운이 끝난 뒤 첫 관측에서 그 신호가 여전히 ok 보다 나쁘면 그때의 레벨로 한 번 알리고, 그 사이 ok 로 회복했으면 알리지 않는다.
  - 쿨다운은 맥북의 시계로 잰다. 마지막 알림 이후 경과 시간이 음수(시계가 되돌려짐)이면 쿨다운이 끝난 것으로 본다.
  - 통지 게이트(`Preferences.showsOpenClaw` 가 참이고 앱 번들로 실행 중)가 닫힌 상태에서 성공 응답이 도착하면, 감시는 그 응답을 비교에 쓰지 않고 초기화된다 (`observe(_:now:canNotify: false)`) — 기준점·쿨다운·미뤄 둔 알림을 버린다. 그렇게 초기화된 뒤에는 게이트가 열린 상태에서 받은 첫 성공 응답이 기준점이다.
  - 초기화는 게이트가 닫히는 순간이 아니라 닫힌 상태에서 성공 응답이 도착할 때 일어난다. 닫았다가 다음 성공 응답이 오기 전에 다시 열면(폴링 주기 안의 전환, 닫힌 동안 요청이 모두 실패) 기준점·쿨다운·미뤄 둔 알림이 그대로 남는다.
  - 감시 대상은 `OpenClawReading` 이 채택한 마지막 성공의 `host` 이되, **그 문서가 신선할 때만**이다 (`ServerHostHealth.reportedHost` — 두절이면 `nil`, 곧 "신호 없음" 과 같은 취급이라 기준점은 유지되고 알림은 없다). 무시된 늦은 도착 응답은 알림 판정에 들어가지 않고, 에이전트가 멈춘 뒤 funnel 이 계속 서빙하는 낡은 문서(요청은 성공)도 들어가지 않는다 — 쿨다운에 눌려 미뤄 둔 알림이 두절 중에 낡은 값으로 나가지 않도록. 다시 신선해진 첫 관측에서 그 신호가 여전히 ok 보다 나쁘면 그때 알린다.
  - 알림 식별자는 신호별로 고정(`server-host-power`, `server-host-disk`)이라 새 알림이 같은 신호의 옛 알림을 대체한다.

  | 신호 · 레벨 | 제목 | 본문 |
  |---|---|---|
  | 전원 warning, `pluggedIn: false` | `서버 전원 어댑터 분리됨` | `배터리 82%로 동작 중입니다.` (잔량 불명: `배터리로 동작 중입니다.`) |
  | 전원 critical, `pluggedIn: false` | `서버 배터리 부족` | `배터리 18% — 어댑터를 연결하지 않으면 곧 꺼집니다.` (잔량 불명: 뒤 문장만) |
  | 전원 warning, `pluggedIn` 이 `true` 이거나 불명 | `서버 전원 주의` | 팝오버 전원 줄과 같은 문구 — `배터리 82% · 충전 중` (수치가 하나도 없으면 `서버의 전원 상태를 확인하세요.`) |
  | 전원 critical, `pluggedIn` 이 `true` 이거나 불명 | `서버 전원 위험` | 위와 같음 |
  | 디스크 warning | `서버 디스크 여유 부족` | `여유 18GB` |
  | 디스크 critical | `서버 디스크 거의 가득` | `여유 4.2GB` |

상태 URL 이 없거나 사용자가 `Claude만` 을 고르면 메뉴바·팝오버·알림에 아무 흔적도 남지 않는다 (`Preferences.showsOpenClaw`). 서버 호스트 표시와 알림도 같은 조건을 따르며 별도 토글이 없다 — `showsOpenClaw` 가 참이고 서버가 `host` 를 보낼 때만 나타난다. 설정의 URL 입력칸은 PHILOSOPHY 원칙 2 의 설정 진입점 예외로 항상 보인다.

## Auth

**단일 사용자·단일 계정 전제.** 서버 세션이나 멀티유저 개념이 없다.

읽기 우선순위:

1. **자체 OAuth 토큰** — Keychain (`Config.ownKeychainService`)
2. **Claude Code CLI 토큰** — Keychain `Claude Code-credentials`, 없으면 `~/.claude/.credentials.json`

Claude Code 사용자는 로그인 없이 기존 토큰을 재사용한다. 다른 앱의 Keychain 항목을 읽으므로 **첫 실행 시 "키체인 접근 허용" 프롬프트**가 뜬다.

토큰이 없을 때의 로그인 흐름은 **OAuth 2.0 Authorization Code + PKCE** 이며, Claude Code 의 client_id 를 재사용한다 (ToS 회색지대 — Decision 2).

- **1순위: 루프백** (`LoopbackServer`, RFC 8252) — 임의 free 포트를 열고 브라우저가 `/callback?code=…&state=…` 로 돌아오면 자동 완료.
- **폴백: 수동 붙여넣기** — 루프백 리다이렉트가 거부되면 콘솔 콜백 페이지에 표시된 `code#state` 를 앱에 붙여넣는다.

**인증 경계**: 토큰은 Keychain 에만 저장되고 `api.anthropic.com` / `platform.claude.com` 외 어디에도 전송되지 않는다. 텔레메트리·크래시 리포터가 없다.

**openclaw 상태 URL** (서버 에이전트): 경로의 토큰(32자리 hex)이 유일한 접근 통제인 읽기 전용 capability URL 이다. Claude 자격증명과 무관하며, `server/install.sh --rotate-token` 으로 폐기·재발급한다. 앱은 이것을 Keychain 이 아니라 `Preferences`(UserDefaults)에 두고, userinfo 없는 https 주소만 받는다.

## Infrastructure

호스팅 인프라가 없다. 배포는 로컬 빌드 산출물이다. openclaw 원격 감시를 쓰면 사용자가 운영하는 서버 맥에 에이전트를 로컬 빌드로 설치한다.

| 경로 | 도구 | 서명 | 용도 |
|---|---|---|---|
| 로컬 사용 | `scripts/make_app.sh` | ad-hoc | 각자 빌드해서 쓰기 (Apple 계정 불필요) |
| 지인 공유 | `scripts/release.sh` | Developer ID + 공증 | `.dmg` 배포 (Gatekeeper 통과, 업데이트 후 토큰 유지) |
| 서버 에이전트 | `server/install.sh` | 없음 (서버 맥에서 release 빌드) | openclaw·서버 호스트 감시 에이전트 LaunchAgent 등록 + Tailscale Funnel 공개 (8443) |

- **App Sandbox 미사용** — Keychain 의 타 앱 항목(Claude Code 자격증명) 접근이 샌드박스와 양립하지 않는다.
- 버전 SSOT 는 git tag (`v1.0.0`, `v1.0.1` …) 이며 GitHub Releases 가 배포 채널이다.
- 외부 SaaS 의존은 Anthropic 호스트다. openclaw 원격 감시를 쓰면 Tailscale(Funnel)이 추가된다.

## 알려진 제약

- 사용량 엔드포인트는 **비공개**다. 스키마·헤더가 예고 없이 바뀌거나 차단될 수 있다.
- `User-Agent: claude-code/<version>` 이 없으면 공격적인 rate limit 버킷으로 떨어져 지속적인 429 를 받는다.
- `swift run` 으로 맨 바이너리를 실행하면 UserNotifications 가 앱 번들을 요구해 크래시한다.
