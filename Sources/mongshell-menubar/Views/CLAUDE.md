---
role: "Sources/mongshell-menubar/Views/ 작성 규약의 단일 권위 — SwiftUI 뷰의 역할 경계, 디자인 토큰 사용, 스냅샷 등록 절차. 상태 소유·폴링은 다루지 않음."
kind: operational
non_goals:
  - "상태 소유·폴링·영속화 (Models/CLAUDE.md)"
  - "외부 경계(네트워크·Keychain·파일·프로세스) 접근 (Services/CLAUDE.md)"
  - "UI 결정의 배경 (docs/PHILOSOPHY.md, docs/architecture-decisions.md #3/#5/#8)"
---

# Views/ 작성 규약

`Sources/mongshell-menubar/Views/**` 작업 시 자동 로드.

## 역할 경계

뷰는 **그리기만 한다.** 데이터를 가져오거나 저장하지 않는다.

- 상태는 `Models/` 의 `@MainActor ObservableObject` (`UsageModel.shared`, `Preferences.shared`, `OpenClawModel`) 를 `@ObservedObject`/`@EnvironmentObject` 로 관찰한다.
- 뷰 안에서 `URLSession`·`Process`·`FileManager`·Keychain 을 직접 부르지 않는다. 필요하면 모델에 메서드를 만들고 그것을 호출한다.
- 사용자 액션은 모델 메서드 호출로 끝난다 (`refreshNow()`, `applyStatusURL(_:)` 등).

## 뷰 로컬 상태는 `@State` 대신 수동 펼침

`@State` 를 적지 않는다. macOS 27 SDK 부터 `@State` 는 SwiftUIMacros 플러그인이 전개하는 매크로이고, 그 플러그인은 Xcode 에만 들어 있어 Command Line Tools 빌드가 깨진다 (Decision #11-2). `State<Value>` 프로퍼티 래퍼 자체는 남아 있으므로 매크로가 만들었을 것을 직접 적는다 — `MenuBarIconView.pulsing` 이 본보기다:

```swift
private var _pulsing = State(initialValue: false)
private var pulsing: Bool {
    get { _pulsing.wrappedValue }
    nonmutating set { _pulsing.wrappedValue = newValue }
}
```

`@Binding`·`@ObservedObject`·`@StateObject`·`@Environment`·`@AppStorage` 는 여전히 프로퍼티 래퍼라 그대로 쓴다. `@Entry`·`@Animatable` 도 같은 플러그인을 요구하므로 쓰지 않는다.

`App/AppDelegate.swift` 가 AppKit 호스트(`NSStatusItem`/`NSPopover`/설정 윈도우)를 소유한다. 팝오버의 생명주기·상호배타(hover ↔ 클릭)는 뷰가 아니라 AppDelegate 의 책임이다.

## 표면은 셋뿐이다

| 표면 | 뷰 | 제약 |
|---|---|---|
| 메뉴바 | `MenuBarIconView`, `ClaudeMarkView` | 폭이 유한하다. 상시 표시 항목 추가는 무엇을 뺄지 함께 제시해야 한다 |
| hover 요약 | `HoverSummaryView` | 즉시 표시가 존재 이유다 — 지연을 만드는 애니메이션·비동기 로드 금지 |
| 클릭 팝오버 / 설정창 | `PopoverView`, `SettingsView`, `ClaudeSettingsSection`, `OpenClawSettingsSection` | 정확한 숫자와 상세는 여기로 미룬다 |

메뉴바에 무언가를 더하려는 변경은 [docs/PHILOSOPHY.md](../../../docs/PHILOSOPHY.md) § Design Principles 1 을 먼저 통과해야 한다.

## 디자인 토큰

- **색은 `Design/Palette.swift` 가 단일 권위다.** 뷰에 `Color(hex:)`·`.red`·`.orange` 를 직접 적지 않는다. 새 색이 필요하면 `Palette` 에 이름을 붙여 추가한다.
- 사용량 3단계(초록 <50 · 주황 <80 · 빨강 ≥80) 판정도 `Palette` 의 로직을 쓴다. 뷰마다 임계값을 다시 적으면 색상 코딩이 갈린다.
- 시간 표기는 `Services/TimeText.swift` 가 권위다. 메뉴바용 압축 포맷(`clockShort`, `weekdayClockShort`)과 팝오버용 서술 문구를 섞지 않는다.
- 색상 코딩이 꺼진 경우(`Preferences.colorCoding == false`)의 모노크롬 폴백을 항상 함께 처리한다.

## 표시 모드

`Preferences.showRemaining` 은 **보이는 숫자와 게이지 채움만** 뒤집는다. **색(위험도)은 항상 사용량 기준**이다 — 남은 양 모드에서 90% 남았다고 빨강이 되면 안 된다. 새 게이지를 만들 때 이 규칙을 다시 확인한다.

## 다크/라이트

메뉴바 뷰는 상태바 배경에 따라 자동 적응해야 한다. 팝오버는 라이트 고정(`Palette.popoverBG`)이다. 두 맥락의 색을 공유하지 않는다.

## 스냅샷 등록

UI 를 추가·변경하면 `App/SnapshotRenderer.swift` 의 렌더 목록에 반영한다 — 이 프로젝트의 시각 검증 경로다 ([docs/development.md](../../../docs/development.md) § 시각 검증).

`Form` 기반 화면은 `ImageRenderer` 로 **빈 이미지가 나온다.** 설정창 계열은 오프스크린 윈도우 캡처 경로에 등록해야 한다.

## 선택 기능의 비가시성

openclaw·Claude Code 설정처럼 전제가 없을 수 있는 요소는 **비활성 회색 표시가 아니라 아예 렌더하지 않는다** (PHILOSOPHY 원칙 2 / Decision #25). `if` 로 분기하되 자리(spacer·구분선)를 남기지 않는다. 예외는 전제를 만드는 입력 자체 — openclaw 상태 URL 입력칸은 원격 서버를 감지할 수 없어 항상 보인다.
