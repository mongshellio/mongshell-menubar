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
| 상태 공개 (서버 에이전트) | Tailscale Funnel — 오픈소스판 `tailscaled` 가 상태 파일을 정적 서빙 (포트 8443) |
| 외부 패키지 의존성 | **없음** |

DB·백엔드 서비스가 없다. 메뉴바 앱은 단일 프로세스 클라이언트다. 예외는 선택 기능인 openclaw 감시로, 사용자가 운영하는 서버 맥에 헤드리스 에이전트(`mongshell-openclaw-agent`)를 둔다 — 네트워크 리스너 없이 상태 파일만 쓰고, 공개는 tailscaled 가 한다.

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

**원격 경로 (서버 에이전트, Decision #25).** openclaw 는 별도 서버 맥에서 돈다.

```
[서버 맥] mongshell-openclaw-agent  ──(LaunchAgent, 기본 60초 주기)
   └─ Probe → Process: `openclaw channels status --probe`
        └─ 파싱 → ok / degraded / down  (공개 detail 은 허용 문자 필터 통과분만)
   └─ 자동복구: 2회 연속 실패 + 쿨다운 600초 → launchctl kickstart -k <게이트웨이 레이블>
   └─ status.json 원자적 쓰기 (0644)
        { schema, checkedAt, health, detail, intervalSeconds, autoHeal, lastHeal }
        └─ tailscale funnel --https=8443 --set-path=/<토큰>
             → https://<서버 DNS 이름>:8443/<토큰>

[맥북] 메뉴바 앱  OpenClawModel ──(주기 폴링, 기본 60초 · 최소 15초)
   └─ OpenClawStatusClient → HTTPS GET (ephemeral 세션, 캐시 무시, 타임아웃 10초)
        └─ 관대한 디코딩 → OpenClawReading (마지막 성공 응답 보관)
             └─ OpenClawHealth: 🟢 ok / 🟡 degraded / 🔴 down(서버 보고) / ⚪️ unreachable
   └─ lastHeal.at 변화 → "openclaw 자동 재시작됨 (서버)" / "openclaw 자동 재시작 실패 (서버)" 알림 (첫 응답은 기준점)
```

- 게이트웨이 레이블은 설치 시 고정한다(`--gateway-label`). 에이전트 자신의 레이블은 탐색·명시 모두에서 제외된다.
- 재시작 후에도 `status.json` 의 `lastHeal` 로 복구 쿨다운을 이어받는다.
- 설치·제거는 `server/install.sh` / `server/uninstall.sh` (사용법: [server/README.md](../server/README.md)).

- **연락 두절(회색)** 판정은 마지막 **성공** 응답의 `checkedAt` 이 `max(180초, 3×intervalSeconds)` 를 넘었는가 하나다. 일시적 요청 실패는 마지막 성공이 신선한 동안 상태를 바꾸지 않는다. 빨강은 서버가 게이트웨이 다운을 보고했을 때만이다.
- `checkedAt` 이 없거나 해석 불가한 문서는 실패로 취급한다. 미래 시각(시계 오차)은 수신 시각으로 잘라 나이 0 으로 본다.
- HTTP 404 는 연락 두절이되 "주소 또는 토큰이 맞지 않습니다" 로 구분한다. 에러 문구에 URL(=토큰)을 넣지 않는다.
- 앱은 읽기 전용이다 — 재시작·자동복구·로그는 서버 몫이다.

상태 URL 이 없거나 사용자가 `Claude만` 을 고르면 메뉴바·팝오버·알림에 아무 흔적도 남지 않는다 (`Preferences.showsOpenClaw`). 설정의 URL 입력칸은 PHILOSOPHY 원칙 2 의 설정 진입점 예외로 항상 보인다.

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

**openclaw 상태 URL** (서버 에이전트): 경로의 토큰(32자리 hex)이 유일한 접근 통제인 읽기 전용 capability URL 이다. Claude 자격증명과 무관하며, `server/install.sh --rotate-token` 으로 폐기·재발급한다. 앱은 이것을 Keychain 이 아니라 `Preferences`(UserDefaults)에 두고, https 만 받는다.

## Infrastructure

호스팅 인프라가 없다. 배포는 로컬 빌드 산출물이다. openclaw 원격 감시를 쓰면 사용자가 운영하는 서버 맥에 에이전트를 로컬 빌드로 설치한다.

| 경로 | 도구 | 서명 | 용도 |
|---|---|---|---|
| 로컬 사용 | `scripts/make_app.sh` | ad-hoc | 각자 빌드해서 쓰기 (Apple 계정 불필요) |
| 지인 공유 | `scripts/release.sh` | Developer ID + 공증 | `.dmg` 배포 (Gatekeeper 통과, 업데이트 후 토큰 유지) |
| 서버 에이전트 | `server/install.sh` | 없음 (서버 맥에서 release 빌드) | openclaw 감시 에이전트 LaunchAgent 등록 + Tailscale Funnel 공개 (8443) |

- **App Sandbox 미사용** — Keychain 의 타 앱 항목(Claude Code 자격증명) 접근이 샌드박스와 양립하지 않는다.
- 버전 SSOT 는 git tag (`v1.0.0`, `v1.0.1` …) 이며 GitHub Releases 가 배포 채널이다.
- 외부 SaaS 의존은 Anthropic 호스트다. openclaw 원격 감시를 쓰면 Tailscale(Funnel)이 추가된다.

## 알려진 제약

- 사용량 엔드포인트는 **비공개**다. 스키마·헤더가 예고 없이 바뀌거나 차단될 수 있다.
- `User-Agent: claude-code/<version>` 이 없으면 공격적인 rate limit 버킷으로 떨어져 지속적인 429 를 받는다.
- `swift run` 으로 맨 바이너리를 실행하면 UserNotifications 가 앱 번들을 요구해 크래시한다.
