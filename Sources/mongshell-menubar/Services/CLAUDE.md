---
role: "Sources/mongshell-menubar/Services/ 작성 규약의 단일 권위 — 외부 경계(네트워크·Keychain·파일·프로세스·로그인 항목) 격리 규칙과 실패 처리 원칙. 상태 소유와 그리기는 다루지 않음."
kind: operational
non_goals:
  - "상태 소유·폴링 조율 (Models/CLAUDE.md)"
  - "뷰 작성·디자인 토큰 (Views/CLAUDE.md)"
  - "엔드포인트·인증 사양 (docs/architecture.md)"
---

# Services/ 작성 규약

`Sources/mongshell-menubar/Services/**` 작업 시 자동 로드.

## 역할 경계

**앱과 바깥 세계가 닿는 모든 지점이 여기 있다.** 이 디렉토리 밖에서 `URLSession`·`SecItem*`·`Process`·`FileManager` 쓰기·`NWListener`·`SMAppService` 를 부르지 않는다.

| 경계 | 타입 |
|---|---|
| 상수·엔드포인트·OAuth 파라미터 | `Config` |
| Keychain | `Credentials` |
| 사용량 API | `UsageAPIClient` |
| OAuth 흐름 | `AuthService`, `LoopbackServer` |
| 사용자 설정 파일 | `ClaudeSettingsStore` |
| openclaw 서버 상태 URL (HTTPS 읽기 전용) — openclaw 판정과 서버 호스트 신호(`host`)를 한 문서에서 읽는다 | `OpenClawStatusClient` |
| 로그인 항목 (ServiceManagement) | `LoginItemService` |

`TimeText` 는 외부 경계가 아니라 포맷터다 — 위 타입들과 성격이 다르지만, 표시 문자열의 SSOT 을 한 곳에 두려고 여기 있다. 이 예외를 늘리지 않는다.

서비스는 **상태를 소유하지 않는다.** `@Published` 를 두지 않고, 호출자(`Models/`)에게 값이나 에러를 돌려준다. 예외는 이벤트를 밀어야 하는 파일 감시(`ClaudeSettingsStore`)이며, 이때도 콜백/스트림으로 넘기고 UI 상태를 직접 만들지 않는다.

## 상수는 `Config` 로

엔드포인트 URL·헤더 값·client_id·Keychain 서비스 이름·폴링 하한을 호출부에 인라인하지 않는다. 값과 함께 **왜 그 값인지**를 주석으로 남긴다 — 특히 리버스엔지니어링으로 얻은 값은 근거가 사라지면 아무도 손대지 못한다.

`User-Agent: claude-code/<version>` 은 선택이 아니다. 빼면 지속적인 429 를 받는다 (Decision 2).

## 실패 처리 원칙

**외부에서 들어오는 것은 관대하게, 사용자 것은 보수적으로.**

- **API 응답**: 스키마가 비공개라 바뀔 수 있다. 후보 키 경로를 여러 개 탐색하고 채울 수 있는 것만 채운다. 필드 하나가 비어도 앱은 계속 동작해야 한다.
- **서버 상태 문서의 부분 실패는 그 부분만 잃는다.** `host` 가 깨져 있어도 openclaw 판정은 읽는다. 단 판정을 **관대하게 읽되 초록으로 만들지 않는다** — 읽을 수 없는 판정은 `ok` 로 접지 않는다. 케이스별 읽기 규칙은 [docs/architecture.md § 3. openclaw 상태](../../../docs/architecture.md#3-openclaw-상태-선택-경로) 의 서버 호스트 신호 절, 배경은 Decision #31.
- **사용자 파일**: 읽기에 실패하면 **쓰지 않는다.** 실패를 빈 값으로 강등하면 다음 저장이 파일을 날린다. 타입이 예상과 다른 값은 "비었다" 로 해석하지 않고 보존한다 (Decision #11).
- 에러는 삼키지 말고 타입으로 올린다 (`APIError`, `AuthError`). 호출자가 401(재인증)과 429(백오프)를 구분할 수 있어야 한다.
- 사용자에게 보일 메시지는 `LocalizedError` 로 한국어를 붙인다.

## 파일 쓰기

사용자 파일을 쓸 때 지키는 절차 — 하나라도 빠지면 Decision #11 의 불변식이 깨진다.

1. 쓰기 직전 디스크를 **다시 읽고** 그 값을 베이스로 삼는다.
2. 대상이 심링크인지 `lstat` 으로 확인하고, 남은 홉을 직접 해석한다. `resolvingSymlinksInPath` 는 **대상이 없는 심링크를 풀지 못한다** (dotfile 재stow 중에 링크를 일반 파일로 갈아치우는 사고의 원인이었다).
3. 원자적으로 쓴다. 백업은 권한 0600.
4. 경로는 한 번만 해석하고 재사용한다 — 매 접근마다 심링크를 다시 타지 않는다.
5. 크기 상한을 둔다 (현재 5MB).

## 프로세스 실행

현재 앱에는 외부 프로세스 실행이 없다 (openclaw 셸아웃은 서버 에이전트로 옮겨갔다 — Decision #25). 다시 생기면 아래를 지킨다.

- **타임아웃 없는 `Process` 실행 금지.** 외부 CLI 가 매달리면 폴링 루프 전체가 멈춘다.
- 메인 스레드에서 기다리지 않는다.
- 인자는 배열로 넘긴다 — 셸 문자열을 조립하지 않는다.
- 출력 파싱은 관대하게. CLI 출력 포맷은 우리가 통제하지 않는다.

## 파일 감시

- 재시도는 **성공 여부를 돌려주고, 실제로 감시에 복귀했을 때만 통지**한다. 무조건 통지하면 파일이 없는 동안 주기적 리로드 루프가 돈다 (실제 회귀 사례).
- 이벤트는 디바운스한다 (현재 150ms).
- 중지 이후에 소스가 설치되지 않도록 순서를 지킨다.

## 자격증명

이 절의 규칙은 Claude 자격증명(OAuth 토큰)에 적용한다. openclaw 상태 URL 의 저장 위치는 [docs/architecture.md § Auth](../../../docs/architecture.md#auth) 가 권위이고, 여기서 지킬 운영 규칙은 하나다 — URL 이 곧 토큰이므로 로그·에러 문구에 넣지 않는다.

- 토큰은 Keychain 에만 둔다. `UserDefaults`·파일·로그 어디에도 쓰지 않는다.
- Anthropic 호스트 외 어디에도 전송하지 않는다.
- 디버그 로그에 토큰·인증 코드를 남기지 않는다.
- Claude Code 의 Keychain 항목은 **읽기 전용**으로 취급한다. 우리 것이 아니다.

## 테스트

`Services/` 의 순수 로직(파싱·포맷·설정 병합)은 `Tests/` 에서 검증할 수 있다. 새 대상을 추가하면 **`scripts/test.sh` 의 `swiftc` 인자에 의존 소스를 직접 나열**해야 한다 — 자동 탐색이 없다 (Decision #11-1, [docs/development.md](../../../docs/development.md) § 테스트).
