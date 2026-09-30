---
role: "Sources/mongshell-menubar/Models/ 작성 규약의 단일 권위 — 상태 소유, @MainActor 격리, 설정 영속화, 스냅샷 타입 설계. 그리기와 외부 I/O 구현은 다루지 않음."
kind: operational
non_goals:
  - "뷰 작성·디자인 토큰 (Views/CLAUDE.md)"
  - "외부 I/O 구현 자체 (Services/CLAUDE.md)"
  - "각 상태 설계의 배경 (docs/architecture-decisions.md)"
---

# Models/ 작성 규약

`Sources/mongshell-menubar/Models/**` 작업 시 자동 로드.

## 역할 경계

모델은 **상태를 소유하고, 그 상태를 바꾸는 흐름을 조율한다.** 외부와 직접 말하지 않는다 — 네트워크·Keychain·파일·프로세스 접근은 `Services/` 타입에 위임하고, 모델은 그 결과를 `@Published` 로 반영한다.

| 종류 | 예 | 규칙 |
|---|---|---|
| 상태 소유 객체 | `UsageModel`, `OpenClawModel`, `ClaudeSettingsModel`, `Preferences` | `@MainActor final class … : ObservableObject` |
| 값 타입 | `UsageSnapshot`, `ModelUsage`, `OpenClawHealth`, `ServerHost` / `ServerHostPower` / `ServerHostDisk` / `ServerHostLevel`, `ServerHostHealth` | `struct`/`enum`, `Equatable`, 로직 없음에 가깝게. 단 판정 규칙을 테스트 가능하게 담는 순수 값 타입은 허용 (`OpenClawReading` — 두절 판정, `OpenClawHealWatch` — 복구 알림 판정, `ServerHostAlertWatch` — 서버 호스트 알림 판정) |

## `@MainActor` 격리

상태 소유 객체는 **전부 `@MainActor`** 다. AppKit 상태바 호스트와 SwiftUI 뷰가 같은 인스턴스를 보기 때문에 격리를 깨면 그 자리에서 데이터 레이스다.

- 오래 걸리는 일은 `Task` 안에서 `await` 로 넘기고, 결과를 받아 `@Published` 를 갱신하는 지점만 메인에 남긴다.
- 폴링 루프는 `Task` 하나로 소유하고, 재시작 시 **이전 태스크를 반드시 취소**한다 (`pollTask?.cancel()`). 취소 없이 새로 만들면 루프가 중첩된다.
- `Task.isCancelled` 를 루프 조건에 넣는다.

## 싱글턴

`UsageModel.shared` / `Preferences.shared` / `OpenClawModel.shared` / `ClaudeSettingsModel.shared` 는 의도된 싱글턴이다 — AppKit 호스트와 SwiftUI 뷰가 **같은 인스턴스를 관찰해야** 하기 때문. 새 싱글턴을 늘리지 않는다. 그 이유가 없는 상태는 소유자에게 주입한다.

## 쓰기 가능 상태는 `private(set)`

외부에서 갈아끼울 수 있는 `@Published var` 를 만들지 않는다. 상태 변경은 모델의 메서드를 통해서만 일어난다 (CQS — [docs/code-standards.md](../../../docs/code-standards.md)).

## 설정 영속화

- 사용자 설정은 `Preferences` 의 `@AppStorage` (UserDefaults) 가 유일한 경로다. `UserDefaults.standard` 를 다른 곳에서 직접 읽지 않는다.
- enum 설정은 `…Raw: String` 을 `@AppStorage` 로 두고 계산 프로퍼티로 감싼다 (`menuBarTarget` 패턴). 파일에 알 수 없는 값이 있으면 **기본값으로 폴백하되 저장된 raw 값을 덮지 않는다.**
- **`~/.claude/settings.json` 값을 `Preferences` 에 복제하지 않는다.** 그 파일이 SSOT 이고 `ClaudeSettingsModel` 은 그것을 구조체로 매핑만 한다 (Decision #11). 두 벌을 두면 어느 쪽이 진짜인지 알 수 없게 된다.

## 스냅샷 타입 설계

- **없는 데이터를 지어내지 않는다.** 엔드포인트가 주지 않는 정보는 필드를 만들지 않는다 (`UsageSnapshot` 이 peak/off-peak 를 의도적으로 생략하는 이유).
- 원본(`Date?`)과 표시용 문자열(`"3시간 8분 후 초기화"`)을 **둘 다** 들고 있어도 된다 — 표시 맥락마다 포맷이 다르기 때문. 단, 포맷 로직은 `Services/TimeText.swift` 에 두고 모델은 저장만 한다.
- 로그아웃·미인증 상태는 에러가 아니라 `.sample` 스냅샷으로 렌더한다. 빈 화면을 만들지 않는다.

## 상태 열거형

"전제가 없음" 을 별도 케이스로 둔다 — `OpenClawHealth.notConfigured` 처럼. `nil` 이나 `down` 으로 뭉뚱그리면 "완전히 감춘다" 와 "빨간 점을 띄운다" 를 구분할 수 없다 (PHILOSOPHY 원칙 2 / Decision #25). 같은 이유로 "상대에게 닿지 않음"(`.unreachable`, 회색)과 "상대가 고장을 보고함"(`.down`, 빨강)도 한 케이스로 합치지 않는다.

`ServerHostHealth` 도 같은 구분을 따른다 (Decision #31) — 전제 없음은 `.absent` 별도 케이스다 (회색 점으로 대신하지 않는다), 두절은 `.unreachable(last:)` 로 마지막 값을 들고 간다, 신선도 판정은 `OpenClawReading` 한 곳에만 둔다 (`health(now:)` 와 `hostHealth(now:)` 가 같은 규칙을 쓴다). 각 케이스의 조건은 [docs/architecture.md § 3. openclaw 상태](../../../docs/architecture.md#3-openclaw-상태-선택-경로) 의 서버 호스트 신호 절이 권위다.

**앱은 서버 호스트의 임계값을 갖지 않는다.** 레벨은 서버 에이전트가 판정해 보낸 것이고(`HostRules`), 모델 쪽 타입은 그것을 담아 표시 문구로 바꿀 뿐이다. 수치로 레벨을 다시 계산하는 코드를 넣지 않는다.

**전원의 원인 문구는 `ServerHostPower.isOnBattery` 로만 분기한다** — 상태어와 알림 문구 모두 (사양: [docs/architecture.md § 3. openclaw 상태](../../../docs/architecture.md#3-openclaw-상태-선택-경로), 배경: Decision #31).

## 알림·백오프

- 임계 알림은 **레벨이 올라갈 때 한 번만** 보낸다 (`lastNotifiedLevel`). 폴링마다 재발송하지 않는다.
- 서버 호스트 알림(Decision #31)은 **신호별**(전원·디스크 따로)로 같은 원칙을 따른다. 규칙(기준점·상승 시 알림·쿨다운·미뤄 둔 알림·게이트)은 [docs/architecture.md § 3. openclaw 상태](../../../docs/architecture.md#3-openclaw-상태-선택-경로) 의 서버 호스트 신호 절이 권위이고, 여기서 지킬 규약은 넷이다.
  - 판정은 순수 값 타입 `ServerHostAlertWatch` 에 둔다. 모델은 결과를 받아 보내기만 한다.
  - 감시에는 **신선한 문서의 `host` 만** 넘긴다 — `hostHealth.reportedHost` (두절·부재는 `nil`; 배경: Decision #31).
  - 알림 발송 여부는 복구 알림과 같은 문(`canNotifyAboutServer`)을 지나고, **문이 닫혀 있으면 그 사실을 감시에 넘긴다** (`observe(_:now:canNotify: false)`) — 감시가 그 관측으로 초기화된다.
  - `observe` 는 성공 응답이 도착할 때만 부른다. 실패 응답에서 부르면 게이트 초기화 시점이 사양과 달라진다.
- 429 백오프는 지수이며 상한이 있다. 백오프 상태를 폴링 주기 설정과 섞지 않는다 — 사용자 설정은 하한(`Config.minPollInterval`)과 함께 base 를 정할 뿐이다.
