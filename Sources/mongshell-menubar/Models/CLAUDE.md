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

`ServerHostHealth` 도 같은 구분을 따른다 (Decision #31).

- `.absent` — 그릴 것이 없다. 상태 URL 이 없거나, 성공 응답이 아직 없거나, 서버가 `host` 를 보내지 않는다. 회색 점으로 대신하지 않는다.
- `.reported(ServerHost)` — 신선한 문서의 판정.
- `.unreachable(last:)` — `host` 를 받은 적이 있지만 문서가 오래됐다. 마지막 값을 들고 있어 뷰가 흐리게 남길 수 있다. 마지막 성공에 `host` 가 없었으면 `.unreachable` 이 아니라 `.absent` 다.

신선도 판정은 `OpenClawReading` 한 곳에 있고 (`health(now:)` 와 `hostHealth(now:)` 가 같은 규칙을 쓴다), 두 상태는 서로의 값에 영향을 주지 않는다.

**앱은 서버 호스트의 임계값을 갖지 않는다.** 레벨은 서버 에이전트가 판정해 보낸 것이고(`HostRules`), 모델 쪽 타입은 그것을 담아 표시 문구로 바꿀 뿐이다. 수치로 레벨을 다시 계산하는 코드를 넣지 않는다.

**전원의 원인 문구는 `pluggedIn == false` 일 때만 쓴다** (`ServerHostPower.isOnBattery`). 전원 레벨은 앱이 판정을 읽지 못해 `warning` 으로 접은 것일 수도 있어, 레벨만 보고 "어댑터 분리"·"배터리 부족" 이라고 하면 같은 화면의 "충전 중" 과 모순된다. 그 밖에는 레벨만 말한다 ("전원 주의"·"전원 위험"). 상태어와 알림 문구 모두 같다.

## 알림·백오프

- 임계 알림은 **레벨이 올라갈 때 한 번만** 보낸다 (`lastNotifiedLevel`). 폴링마다 재발송하지 않는다.
- 서버 호스트 알림(`ServerHostAlertWatch`, Decision #31)은 **신호별**(전원·디스크 따로)로 같은 원칙을 따른다.
  - 첫 관측(앱 시작·상태 URL 변경 뒤)은 기준점이며 알리지 않는다. 기준점에 없던 신호가 나중에 처음 나타나면 ok 와 비교한다.
  - 레벨이 직전보다 오르면 알린다. 유지·회복·두절·신호가 사라진 것은 알리지 않는다.
  - 이미 알린 레벨 이하로 다시 오르는 것은 마지막 알림 후 `repeatCooldown`(3600초) 동안 알리지 않는다 — 에이전트 판정에 히스테리시스가 없어 임계 근처에서 출렁이기 때문. 더 높은 레벨로의 상승은 쿨다운과 무관하게 즉시 알린다.
  - **쿨다운에 눌린 상승은 버리지 않고 미룬다.** 쿨다운이 끝난 뒤 첫 관측에서 신호가 여전히 ok 보다 나쁘면 그때의 레벨로 한 번 알리고, 그 사이 ok 로 회복했으면 알리지 않는다. 쿨다운은 출렁임을 막는 장치이지 상태를 숨기는 장치가 아니다.
  - 쿨다운은 이 맥의 시계로 잰다. 경과 시간이 음수(시계가 되돌려짐)이면 끝난 것으로 본다.
  - 감시에는 방금 받은 응답이 아니라 `reading.lastSuccess?.host` 를 넘긴다 — `OpenClawReading` 이 버린 늦은 도착 응답이 알림 판정에 섞이지 않게.
  - 알림 발송 여부는 복구 알림과 같은 문(`canNotifyAboutServer` — `notificationsAvailable`, `Preferences.showsOpenClaw`)을 지난다. **문이 닫혀 있으면 그 사실을 감시에 넘긴다** (`observe(_:now:canNotify:)`). `canNotify: false` 로 불린 감시는 그 관측을 비교에 쓰지 않고 알던 것(기준점·쿨다운·미뤄 둔 알림)을 버려, 그 뒤 문이 열린 상태의 첫 관측이 기준점이 된다. 보여주지 못한 알림을 "알렸다" 고 기록하게 두면 다음 상승이 쿨다운에 눌린다. 초기화는 `observe` 가 불릴 때, 곧 성공 응답이 도착할 때에만 일어난다 — 문을 닫았다가 다음 성공 응답 전에 다시 열면 기준점·쿨다운이 그대로 남는다.
- 429 백오프는 지수이며 상한이 있다. 백오프 상태를 폴링 주기 설정과 섞지 않는다 — 사용자 설정은 하한(`Config.minPollInterval`)과 함께 base 를 정할 뿐이다.
