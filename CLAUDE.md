---
role: "mongshell-menubar 프로젝트 진입점 — 정체성·작업 규약 코어(하네스 상시 규칙·정책 노브)·sub-document 인덱스의 단일 권위 (코드 작성 기준은 docs/code-standards.md import, 하네스 본체는 mongshell-dev 플러그인). 기능/아키텍처 의사결정 배경은 다루지 않음."
kind: operational
non_goals:
  - "프로덕트 철학·범위 (docs/PHILOSOPHY.md)"
  - "아키텍처 의사결정 배경 (docs/architecture-decisions.md)"
  - "빌드/테스트/스냅샷 명령어 (docs/development.md)"
  - "영역별 세부 운영 규약 (영역별 CLAUDE.md)"
  - "릴리스 절차 (`/release` 스킬 + scripts/release.sh)"
---

# mongshell-menubar

macOS 메뉴바에 Claude 구독 사용량을 상시 표시하는 1인용 네이티브 앱. SwiftPM executable 타깃 2개(메뉴바 앱 + 서버 맥용 openclaw 감시 에이전트 — `server/README.md`), 외부 의존성 없음. 개발 하네스 = **mongshell-dev 플러그인** (스킬 `/mongshell-dev:qa` 등 네임스페이스 호출 — 흐름도·라우팅은 플러그인 동봉 README 가 권위).

## 작업 규약 코어 (하네스 상시 규칙)
<!-- harness-core: 2026-07 -->

- **오케스트레이터**: 메인 세션은 탐색·계획·서브에이전트 관리·사용자 소통이 주 역할,
  실질 구현은 developer, 검토는 reviewer 에이전트에 위임. 위임이 병렬성·컨텍스트 격리·
  독립 리뷰 중 뭔가를 사면 위임, 자명한 변경(한 줄·오타·기계적 교정)은 직접 편집.
- **1인 운영 전제**: 단순성 우선, 팀 협업 본질 패턴 디스카운트, 운영 부담 최소화.
- **스크립트 우선**: 결정적 판정(개수 비교·존재 확인·형식 검사)은 모델 추론이 아니라
  스크립트/bash 로 처리한다.
- **디버깅 원칙**: 증상 패치 전에 근본원인 — 데이터 흐름 추적 없는 fix 제안, 검증 없는
  원인 단정, 동시 다발 변경은 red flag. 같은 증상에 fix 3회 실패 시 아키텍처를 의심한다.
- **UI 목업 게이트**: UI 변경 인입 시 developer 위임 직전 목업 우선 여부를 판정한다 —
  트리거는 새 화면·큰 레이아웃 재구성만, 기본값 skip, 게이트락 아님. 사용자 "목업 먼저"
  pull 로 양방향 오버라이드 가능. 목업 합의 후 (필요 시) architect → developer 로 이어지며,
  상수·절차 권위는 컴포넌트 영역 CLAUDE.md.
- **머지 규약** (worktree 워크플로우 전제): PR 머지는 `gh pr merge <N> --squash` 만 —
  `--delete-branch` 금지 (worktree 의 `main` 점유와 충돌; remote 브랜치는 repo 설정
  `delete_branch_on_merge` 가 자동 삭제).
- **정책 노브**: 커밋/PR trailer — `Co-Authored-By` **포함**, `🤖 Generated with Claude Code`
  **미포함**. 응답 톤 — 항상 존댓말. 커밋 메시지 — 한국어 conventional commits.

프로덕트 철학·범위는 [docs/PHILOSOPHY.md](docs/PHILOSOPHY.md), 아키텍처 의사결정 기록은 [docs/architecture-decisions.md](docs/architecture-decisions.md). 새 결정 전 가장 먼저 참조.

@docs/code-standards.md

## 스택 메모 (false-positive 방지)

- **SwiftPM 테스트 타깃이 없는 것이 정상.** `swift test` 는 XCTest 나 swift-testing 을 요구하는데 둘 다 Command Line Tools 에 없다. 테스트는 [scripts/test.sh](scripts/test.sh) 가 실제 소스 파일을 직접 컴파일해 돌린다 (Decision #11-1).
- **`swift run` 으로 바이너리를 직접 실행하면 크래시한다** — UserNotifications 가 앱 번들을 요구한다. 항상 `./scripts/make_app.sh` 로 `.app` 을 만들어 실행.
- **뷰에서 `@State` 를 쓰지 않는다.** macOS 27 SDK 부터 `@State` 는 SwiftUIMacros 플러그인이 전개하는 매크로인데, 그 플러그인은 Xcode 에만 있고 Command Line Tools 에는 없다. 로컬 뷰 상태는 `State<Value>` 저장 프로퍼티를 손으로 펼쳐 쓴다 ([MenuBarIconView.swift](Sources/mongshell-menubar/Views/MenuBarIconView.swift) 참조, Decision #11-2).
- **별도 lint 도구가 없다.** `swift build` 의 경고가 그 역할이며, 경고 0 을 유지한다.
- **App Sandbox 미사용.** Keychain 의 Claude Code 자격증명 항목과 `openclaw` 셸아웃이 샌드박스와 양립하지 않는다.
- **비공식 엔드포인트에 의존한다** — 스키마·헤더가 예고 없이 바뀔 수 있다는 전제로 디코딩이 의도적으로 관대하다 (Decision 2).

## Sub-Documents

### 영역별 운영 규약 (해당 디렉토리 파일 작업 시 자동 로드)
- 🤖 [Sources/mongshell-menubar/Views/CLAUDE.md](Sources/mongshell-menubar/Views/CLAUDE.md) — SwiftUI 뷰 작성 규약, 색·치수 토큰, 스냅샷 갱신
- 🤖 [Sources/mongshell-menubar/Models/CLAUDE.md](Sources/mongshell-menubar/Models/CLAUDE.md) — `@MainActor` ObservableObject 경계, 설정 영속화
- 🤖 [Sources/mongshell-menubar/Services/CLAUDE.md](Sources/mongshell-menubar/Services/CLAUDE.md) — 외부 경계(네트워크·Keychain·파일·프로세스) 격리 규약

### 권위 문서
- [docs/PHILOSOPHY.md](docs/PHILOSOPHY.md) — 프로덕트 가치·범위·설계 원칙
- [docs/architecture.md](docs/architecture.md) — Tech Stack·데이터 흐름·인증·배포 사양
- [docs/architecture-decisions.md](docs/architecture-decisions.md) — 아키텍처 결정 기록
- [docs/harness-decisions.md](docs/harness-decisions.md) — 하네스 운영 결정 기록
- [docs/development.md](docs/development.md) — 빌드·테스트·스냅샷·릴리스 명령
- [docs/code-standards.md](docs/code-standards.md) — 코드 작성/리팩토링 기준 (위 `@` 로 자동 로드)
