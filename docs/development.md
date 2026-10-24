---
role: "빌드·테스트·스냅샷·릴리스 등 로컬 개발 명령어의 단일 권위 — 각 명령이 검증하는 대상의 설계 배경은 다루지 않음."
kind: operational
non_goals:
  - "코드 작성 기준 (docs/code-standards.md)"
  - "명령이 검증하는 구조의 설계 배경 (docs/architecture.md, docs/architecture-decisions.md)"
  - "영역별 세부 규약 (영역별 CLAUDE.md — 영역별 명령이 다르면 그쪽이 우선 권위)"
---

# 개발 명령어

macOS 26+ 와 Xcode **또는** Command Line Tools 만 있으면 된다. 외부 패키지 의존성이 없어 `swift build` 가 네트워크를 타지 않는다.

CLT 27.0 이상에서 `plugin for module 'SwiftUIMacros' not found` 가 나면 누군가 `@State` 를 새로 적은 것이다 — 수동 펼침으로 바꾼다 (Decision #11-2, `Views/CLAUDE.md`).

## 명령 요약

| 목적 | 명령 |
|---|---|
| 빌드 / typecheck | `swift build` (앱 + 서버 에이전트 두 타깃 모두) |
| 테스트 | `./scripts/test.sh` |
| lint | 별도 도구 없음 — `swift build` 경고가 대신한다 (경고 0 유지) |
| DB 마이그레이션 | 해당 없음 (DB 없음 — 영속 상태는 UserDefaults + Keychain) |
| 로컬 실행 | `./scripts/make_app.sh debug && open mongshell-menubar.app` |
| 시각 검증 (스냅샷) | `swift build && MONGSHELL_SNAPSHOT=/tmp/mongshell_snaps ./.build/debug/mongshell-menubar` |
| 배포용 dmg | `DEV_ID=… NOTARY_PROFILE=… ./scripts/release.sh` |
| 서버 에이전트만 빌드 | `swift build --product mongshell-openclaw-agent` |
| 서버 스크립트 문법 검사 | `bash -n server/*.sh` |
| 서버 에이전트 설치 (서버 맥) | `server/install.sh` — [server/README.md](../server/README.md) |

## typecheck

Swift 는 컴파일이 곧 타입 검사라 별도 typecheck 명령이 없다. **`swift build` 가 typecheck 명령이다.**

## 테스트

```bash
./scripts/test.sh
```

`swift test` 가 **아니다.** `swift test` 는 XCTest 나 swift-testing 을 요구하는데 둘 다 Command Line Tools 에 들어 있지 않고, "Xcode 없이 빌드 가능" 은 이 프로젝트가 유지하는 전제다 (Decision #11-1). 대신 `scripts/test.sh` 가 `swiftc` 로 **실제 소스 파일과 테스트 파일을 함께 컴파일**해 실행한다 — 사본이 아니라 배포되는 코드를 그대로 검증한다.

그래서 `Package.swift` 에 test 타깃이 없는 것이 정상이다. 없다고 추가하지 말 것 — CLT 환경에서 빌드가 깨진다.

### 테스트 배치 컨벤션

- 테스트는 소스 옆(co-located)이 아니라 **`Tests/<대상>Tests/main.swift`** 에 둔다. `swiftc` 로 직접 컴파일하는 실행 파일이라 `@main` 없는 top-level 코드가 진입점이고, 소스 트리에 섞이면 `swift build` 가 앱 타깃에 함께 넣어버린다.
- 새 테스트 대상을 추가하면 `scripts/test.sh` 의 `swiftc` 인자에 **그 대상이 의존하는 소스 파일을 직접 나열**해야 한다. 자동 탐색이 없다.
- 현재 커버리지는 일곱 묶음이다.
  - `Tests/ClaudeSettingsTests` — `ClaudeSettingsStore` / `ClaudeSettingsModel`. 불변식: **보이지 않는 설정을 앱이 파괴하지 않는다.**
  - `Tests/AuthTests` (실행 파일 `auth-tests`) — OAuth 토큰 경로 (`OAuthTokenClient`·`AuthError`). 불변식: **200 + `access_token` 만 토큰이 되고, 토큰이 되지 못한 2xx 의 실패 상세에는 바디 대신 최상위 키 이름(또는 크기)만 남으며, 죽은 refresh 토큰(`invalid_grant`)만 버리고 일시 오류·거부된 3xx 에는 살아 있는 토큰을 지키며, 본문은 200·400·401 에서만 읽어 `invalid_grant` 판정이 살아 있고 큰 오류 페이지는 상태 코드로 드러나며, 실제 응답 모양은 응답 상한(`Config.oauthTokenMaxResponseBytes`) 아래에 넉넉히 들어가고, `signedInAt` 이전에 저장된 토큰도 읽힌다.**
  - `Tests/OpenClawAgentTests` (실행 파일 `agent-tests`) — 서버 에이전트의 `Probe` / `Heal` / `HostProbe` / `StatusFile` (`main.swift` 는 진입점이라 제외). 불변식: **판정 규칙·복구 시점·자기 레이블 제외·공개 JSON 형식과 detail 필터가 조용히 바뀌지 않는다. 호스트 판정의 임계 경계(20% · 20GB · 5GB · 러너 전부/일부/0)와 전원·디스크·CI 러너 읽기 해석이 바뀌지 않고(극단값에 트랩하지 않고, 알 수 없는 전원 공급원을 ok 로 읽지 않고, `launchctl print` 의 최상위 `state` 만 보며, launchctl 을 듣지 못한 러너를 동작·중단 어느 쪽으로도 세지 않는다), 호스트 로그의 비교 키는 신호별 레벨이며, `host` 아래 문자열 값은 세 레벨 이름뿐이다.**
  - `Tests/OpenClawClientTests` (실행 파일 `client-tests`) — 앱의 `OpenClawStatusClient` / `OpenClawStatus` / `OpenClawHealth` / `ServerHost` / `ServerHostAlertWatch` / `TimeText` (`Palette` 는 점 색 때문에 함께 컴파일). 에이전트의 `Probe.swift`·`HostProbe.swift`·`StatusFile.swift` 를 함께 컴파일해 에이전트 인코더 → 앱 파서 왕복을 검증한다. 불변식: **두 타깃의 JSON 키가 어긋나지 않고, 연락 두절(회색)과 게이트웨이 다운(빨강)이 섞이지 않으며, 서버 복구 알림은 새 복구에만 뜨며, 원격 문자열과 응답 크기는 상한 안에서만 받는다. 깨진 `host` 는 서버 점만 잃고 openclaw 판정은 남으며, 읽을 수 없는 레벨(모르는 문자열·문자열이 아닌 값)은 초록이 되지 않고, 전원의 원인 문구는 `pluggedIn: false` 일 때만 나오고 러너의 중단 문구는 개수가 보여줄 때만 나오며, 있을 수 없는 러너 개수(`running > total`, `total` 0, 정수 아님)는 러너 신호를 버리며, 서버 호스트 알림은 신호별 상승에 뜨고 쿨다운을 지키되 쿨다운에 눌린 상승은 버리지 않고 미루며, 통지 게이트가 닫힌 동안에는 아무것도 알린 것으로 세지 않는다.**
  - **두 타깃의 타입 이름은 겹치면 안 된다.** `client-tests` 는 앱 소스와 에이전트 소스를 한 모듈로 컴파일하므로, 양쪽에 같은 이름의 타입이 있으면 재선언 오류로 테스트가 컴파일되지 않는다 (`swift build` 는 타깃이 달라 통과한다). 그래서 같은 개념이라도 에이전트는 `HostLevel` / `HostStatus`, 앱은 `ServerHostLevel` / `ServerHost` 다.
  - `Tests/GitHubTests` (실행 파일 `github-tests`) — GitHub PR 영역(Decision #45)의 순수 판정(`GitHubPullRequest` / `GitHubState`)과 `GitHubAPIClient` 의 `interpret` / `parse` / 쿼리 문자열, `GitHubCredentials` 의 go-keyring 값 디코딩 (`@MainActor` 모델은 제외). 불변식: **배지 우선순위·메뉴바 숫자·점 색·칩 접기·hover CI 줄(진행중 > 실패 > 통과·없음, 이미 실패한 PR 은 진행중으로 세지 않음)·폴링 주기(백오프 중엔 30초 주기 없음, 빠른 주기는 loaded + 60분 이내 running 일 때만)가 바뀌지 않고, 모르는 검사 값은 통과가 되지 않으며(완료 + 모르는 conclusion 은 failed, 모르는 status 는 queued), 401/403·429/2xx 외의 코드와 `data` 없는 본문은 빈 목록이 아니라 오류이고, gh 의 세 가지 저장 형태가 모두 토큰으로 풀린다. 머지 가능 판정이 팝오버 머지 버튼과 같고 진행·완료된 머지는 세지 않는다.**
  - `Tests/UsageTests` (실행 파일 `usage-tests`) — `UsageAPIClient.parse` 와 그것이 채우는 `UsageSnapshot`, `AuthDebugLog` 의 usage 로그 줄·dedupe 키, 사용량 `Meter`, 클라이언트의 상태 코드 매핑과 본문 읽기 규칙 (`Palette`·`TimeText`·`DisplayText`·`BoundedHTTP`·`Config`·`Credentials` 를 함께 컴파일; `@MainActor` 모델은 제외). 불변식: **실제 응답 모양에서 session / weekly_all / weekly_scoped 가 읽히고, 모르는 `kind` 의 `limits` 항목은 버려지지 않고 `extraLimits` 에 이름·percent·resetAt 으로 실리며(스코프 모델명은 weekly_scoped 행과 같은 표기 뒤에 kind 를 붙인다), `limits` 가 없는 flat 폴백에서는 `extraLimits` 가 비고, `unknownTopLevel` 과 로그 줄은 [docs/architecture.md § 1](architecture.md#1-사용량-폴링-주-경로) 의 필터 규칙 셋을 따르며, dedupe 키는 percent·utilization 이 움직여도 같고 kind·resets_at·버킷 집합이 바뀌면 다르고, 범위 밖·비유한 숫자는 트랩 없이 100/0/nil 로 접히며, 응답 문자열은 한 줄·글자 상한 안에서만 라벨과 로그에 닿고 개수 상한을 넘는 행은 버려지며, `Meter` 의 색은 남은 양 모드에서도 사용량 기준이고 색상 코딩이 꺼지면 위험도 색이 아니라 모노크롬이며, 401/403 은 재인증·429 는 `Retry-After` 백오프·거부된 3xx 는 HTTP 오류로 갈리고, 본문은 200 일 때만 읽어 큰 오류 페이지도 상태 코드로 드러나며, 실제 응답 모양은 응답 상한(`Config.usageMaxResponseBytes`) 아래에 넉넉히 들어간다.**
  - `Tests/ServerOptionsTests` (`main.sh` — Swift 가 아니라 bash 라 컴파일 없이 `bash` 로 실행) — 실제 `server/lib.sh` 를 source 해 `server/install.sh` 의 설치 옵션 규칙(`valid_interval` / `load_saved_options` / `resolve_options`)을 검증한다. 불변식: **우선순위는 명령줄 > 저장값 > 기본값(60초 · 자동복구 켬)이고, 깨진 저장값(숫자가 아님 · 30–86400 범위 밖 · 자릿수 초과 · `auto_heal` 이 0/1 이 아님)과 읽을 수 없는 `options` 파일은 경고 후 기본값으로 가되 설치를 중단시키지 않으며, `options` 파일의 내용은 실행되지 않는다.**
- 서버 스크립트(`server/*.sh`)에서 자동 테스트가 있는 것은 위 설치 옵션 규칙뿐이다. 나머지 — tailscale serve/funnel 설정 조회·경로 해제(`server/lib.sh` 의 `serve_handlers` / `unpublish_path`), `install.sh` / `uninstall.sh` 의 빌드·LaunchAgent 등록·토큰·공개 절차 — 는 tailscale 실기가 필요해 자동 테스트가 없다. `bash -n` 문법 검사와, 서버 맥에서의 설치 후 [server/README.md](../server/README.md) § 동작 확인이 검증 경로다.

## 로컬 실행

```bash
./scripts/make_app.sh debug && open mongshell-menubar.app
```

`swift run` 이나 `.build/debug/mongshell-menubar` 직접 실행은 **크래시한다** — UserNotifications 가 앱 번들을 요구한다. 스냅샷 렌더 모드(아래)만 예외적으로 맨 바이너리로 돈다.

`make_app.sh` 는 인자 없이 부르면 release 빌드다.

## 시각 검증 (스냅샷)

```bash
swift build && MONGSHELL_SNAPSHOT=/tmp/mongshell_snaps ./.build/debug/mongshell-menubar
```

`MONGSHELL_SNAPSHOT` 이 설정되면 앱이 메뉴바에 붙는 대신 오프스크린으로 PNG 를 렌더하고 종료한다 (`App/SnapshotRenderer.swift`). 이 프로젝트는 웹 UI 가 아니라 `.claude/browser-scenarios.md` 대상이 아니며, **UI 변경의 시각 확인은 이 경로가 담당한다.**

`Form` 기반 화면(설정창)은 `ImageRenderer` 로 빈 이미지가 나와 오프스크린 윈도우 캡처 경로를 쓴다 — 새 설정 UI 를 추가하면 그쪽에 등록한다.

산출물 (`<이름>.png`):

| 파일 | 내용 |
|---|---|
| `menubar_strip_dark` / `menubar_strip_light` | 메뉴바 — 사용량 레벨 3쌍 × openclaw 점 (정상 / 두절 / 다운) |
| `menubar_host_strip_dark` / `menubar_host_strip_light` | 메뉴바 두 줄 스택 — 서버 점 없음(단일 표시, 비교 기준) → 서버 점 ok / warning / critical / 두절. 실제 메뉴바 두께(22pt)로 잘라 그리므로 넘치는 스택은 잘려 보인다 |
| `popover` | 팝오버 — openclaw 정상, 서버 섹션 없음 |
| `popover_host_on_battery` | 팝오버 — 서버 섹션, 어댑터가 빠진 서버 (전원 warning) |
| `popover_host_disk_critical` | 팝오버 — 서버 섹션, 배터리 없는 서버의 디스크 critical (전원 줄 없음) |
| `popover_host_unreachable` | 팝오버 — 두절, 서버 섹션에 마지막 값이 흐리게 남음 |
| `popover_openclaw_unreachable` / `popover_openclaw_down` | 팝오버 — openclaw 두절 / 게이트웨이 다운 |
| `popover_extra_limit` | 팝오버 — 로그인된 상태(샘플 배너 없음)에서 7일 한도 아래에 앱이 모르는 `kind` 의 한도(설정 화면의 제한 초기화/보너스) 한 줄이 위험도 색 막대와 초기화 캡션으로 붙은 상태. `popover` 에는 없다 |
| `settings` / `settings_claude` / `settings_openclaw` / `settings_openclaw_down` | 설정창 |
| `github_menubar_strip_dark` / `github_menubar_strip_light` / `github_menubar_strip_zero_dark` / `github_menubar_strip_ci_dark` | 메뉴바 두 영역 — Claude 영역 뒤에 헤어라인 · GitHub 글리프 · 점 · 숫자 (3건·빨강 / 0건·초록 / 0건·주황 = CI 진행중) |
| `github_menubar_strip_merge_dark` / `github_menubar_strip_merge_light` | 메뉴바 두 영역 — 머지 가능한 내 PR 이 있어 글리프가 초록 merge 로 바뀐 상태 (Decision #52). `_zero_dark` 와 글리프 칸 밖은 픽셀 단위로 같아야 한다 (폭 불변) |
| `github_hover` | GitHub 영역 hover 요약 — CI 줄 + 내 PR 줄 + 머지 가능 줄, CI 경과 시간은 `frozenNow` 로 고정 |
| `github_popover` / `github_popover_overflow` / `github_popover_no_token` / `github_popover_unauthorized` | GitHub 팝오버 — gh CLI 로 연결됨 / 섹션 상한 초과("외 N건")와 빈 섹션("없음") / 토큰 없음 배너 / 401 배너. 진행중 칩의 경과 시간은 `frozenNow` 로 고정 |
| `github_popover_merge_failed` | GitHub 팝오버 — 내 PR 의 머지 가능 행에서 GitHub 가 squash 머지를 거절해 행 아래 빨간 사유 한 줄이 붙은 상태 (Decision #49). `github_popover` 에는 같은 행에 평상시 버튼이 보인다 |
| `settings_github` | 설정창 GitHub 섹션 (켜진 상태) |

`popover_openclaw_down` 을 뺀 openclaw 팝오버 스냅샷(`popover`·`popover_host_*`·`popover_openclaw_unreachable`)은 "서버 확인" 아래에 `에이전트 v1.2.0+3` 줄을 그린다 (Decision #81). `popover_openclaw_down` 은 버전을 보내지 않는 에이전트라 그 줄이 없다.

## Claude Code 설정 편집 테스트

앱이 `~/.claude/settings.json` 을 실제로 읽고 쓴다. 개발 중에는 사본을 가리키게 한다.

```bash
MONGSHELL_CLAUDE_SETTINGS=/tmp/settings.json open mongshell-menubar.app
```

`scripts/test.sh` 는 이 변수를 케이스별로 직접 설정하며, 셸에서 상속된 값이 실제 파일을 가리키지 못하도록 실행 직전 `env -u` 로 지운다.

## 배포용 dmg

```bash
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="mongshell-menubar-notary" ./scripts/release.sh
```

앱 번들의 `CFBundleShortVersionString` 은 `make_app.sh` 가 빌드 시 가장 가까운 `vX.Y.Z` 태그에서 찍는다 (Decision #47) — `Resources/Info.plist` 의 `0.0.0` 은 자리표시다. 릴리스 빌드 전에 `git fetch --tags` 로 태그를 받아 둔다 — `release.sh` 는 번들 버전이 `0.0.0` 자리표시로 남으면 서명 전에 멈춘다.

`make_app.sh` 의 서명은 로컬 전용이다 — 남에게 주면 Gatekeeper 가 막는다. 서명 신원은 Apple Development 인증서가 있으면 그것이고, 없으면 팀 ID 가 없는 서명이라 빌드마다 Keychain 재승인이 필요하다 (Decision #68, 고르는 순서와 인증서 발급은 [README § 로컬 코드 서명 인증서](../README.md#키체인-프롬프트가-재빌드마다-다시-뜰-때--로컬-코드-서명-인증서)). 배포 준비물과 절차는 [README](../README.md) § 배포 참조.
