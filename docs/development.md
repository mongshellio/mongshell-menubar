---
role: "빌드·테스트·스냅샷·릴리스 등 로컬 개발 명령어의 단일 권위 — 각 명령이 검증하는 대상의 설계 배경은 다루지 않음."
kind: operational
non_goals:
  - "코드 작성 기준 (docs/code-standards.md)"
  - "명령이 검증하는 구조의 설계 배경 (docs/architecture.md, docs/architecture-decisions.md)"
  - "영역별 세부 규약 (영역별 CLAUDE.md — 영역별 명령이 다르면 그쪽이 우선 권위)"
---

# 개발 명령어

macOS 14+ 와 Xcode **또는** Command Line Tools 만 있으면 된다. 외부 패키지 의존성이 없어 `swift build` 가 네트워크를 타지 않는다.

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
- 현재 커버리지는 두 묶음이다.
  - `Tests/ClaudeSettingsTests` — `ClaudeSettingsStore` / `ClaudeSettingsModel`. 불변식: **보이지 않는 설정을 앱이 파괴하지 않는다.**
  - `Tests/OpenClawAgentTests` — 서버 에이전트의 `Probe` / `Heal` / `StatusFile` (`main.swift` 는 진입점이라 제외). 불변식: **판정 규칙·복구 시점·자기 레이블 제외·공개 JSON 형식과 detail 필터가 조용히 바뀌지 않는다.**
- 서버 스크립트(`server/*.sh`)는 tailscale 실기가 필요해 자동 테스트가 없다. `bash -n` 문법 검사와, 서버 맥에서의 설치 후 [server/README.md](../server/README.md) § 동작 확인이 검증 경로다.

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

`make_app.sh` 의 ad-hoc 서명은 로컬 전용이다 — 남에게 주면 Gatekeeper 가 막고, 빌드마다 서명이 바뀌어 Keychain 토큰이 무효화된다. 준비물과 절차는 [README](../README.md) § 배포 참조.
