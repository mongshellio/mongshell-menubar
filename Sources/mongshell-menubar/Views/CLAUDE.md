---
role: "Sources/mongshell-menubar/Views/ 작성 규약의 단일 권위 — SwiftUI 뷰의 역할 경계, 디자인 토큰 사용, 스냅샷 등록 절차. 상태 소유·폴링은 다루지 않음."
kind: operational
non_goals:
  - "상태 소유·폴링·영속화 (Models/CLAUDE.md)"
  - "외부 경계(네트워크·Keychain·파일·프로세스) 접근 (Services/CLAUDE.md)"
  - "UI 결정의 배경 (docs/PHILOSOPHY.md, docs/architecture-decisions.md)"
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

이렇게 펼친 뷰에는 **`init` 을 직접 적는다.** 초기값이 있는 `private var` 저장 프로퍼티도 멤버와이즈 이니셜라이저에 들어가 그 접근 수준을 private 으로 끌어내리므로, 다른 파일에서 뷰를 만들면 빌드가 깨진다.

`@Binding`·`@ObservedObject`·`@StateObject`·`@Environment`·`@AppStorage` 는 여전히 프로퍼티 래퍼라 그대로 쓴다. `@Entry`·`@Animatable` 도 같은 플러그인을 요구하므로 쓰지 않는다.

`App/AppDelegate.swift` 가 AppKit 호스트(`NSStatusItem`/`NSPopover`/설정 윈도우)를 소유한다. 팝오버의 생명주기·상호배타(hover ↔ 클릭)는 뷰가 아니라 AppDelegate 의 책임이다.

## 표면은 셋뿐이다

| 표면 | 뷰 | 제약 |
|---|---|---|
| 메뉴바 | `MenuBarIconView`, `ClaudeMarkView` | 폭이 유한하다. 상시 표시 항목 추가는 무엇을 뺄지 함께 제시해야 한다. 신호등은 세로로 **두 줄까지** 쌓는다 (Decision #31) |
| hover 요약 | `HoverSummaryView` | 즉시 표시가 존재 이유다 — 지연을 만드는 애니메이션·비동기 로드 금지 |
| 클릭 팝오버 / 설정창 | `PopoverView`, `SettingsView`, `ClaudeSettingsSection`, `OpenClawSettingsSection` | 정확한 숫자와 상세는 여기로 미룬다 |

메뉴바에 무언가를 더하려는 변경은 [docs/PHILOSOPHY.md](../../../docs/PHILOSOPHY.md) § Design Principles 1 을 먼저 통과해야 한다. Claude 사용량 외의 신호라면 같은 문서의 § Admission Criteria 도 통과해야 한다.

### 메뉴바 두 줄 스택

서버가 호스트 신호를 보내면 단일 openclaw 표시(발자국 + 점) 자리에 **두 줄 스택**이 들어간다 — 위는 발자국 + openclaw 점, 아래는 서버 글리프 + 서버 점 (Decision #31).

- **두 줄이 상한이다** (Decision #31). 세 번째 줄을 넣지 않는다.
- 스택은 그것이 대신하는 단일 표시보다 넓으면 안 된다 (PHILOSOPHY § Admission Criteria 4).
- 치수는 `MenuBarIconView.swift` 의 `StackedIndicator` 가 권위다. 글리프 열 폭을 고정해 두 점이 세로로 정렬된다.
- 서버 점은 openclaw 표시 옆에만 그린다 — openclaw 점 없이 서버 점만 그리는 경로는 없다.
- 단일 표시와 스택은 폭이 달라, 서버 점이 생기거나 사라지면 `AppDelegate` 가 status item 크기를 다시 잡는다.

## 디자인 토큰

- **색은 `Design/Palette.swift` 가 단일 권위다.** 뷰에 `Color(hex:)`·`.red`·`.orange` 를 직접 적지 않는다. 새 색이 필요하면 `Palette` 에 이름을 붙여 추가한다.
- 사용량 3단계(초록 <50 · 주황 <80 · 빨강 ≥80) 판정도 `Palette` 의 로직을 쓴다. 뷰마다 임계값을 다시 적으면 색상 코딩이 갈린다.
- 시간 표기는 `Services/TimeText.swift` 가 권위다. 메뉴바용 압축 포맷(`clockShort`, `weekdayClockShort`)과 팝오버용 서술 문구를 섞지 않는다.
- 사용량 게이지·수치처럼 사용량 3단계 색을 쓰는 요소는 색상 코딩이 꺼진 경우(`Preferences.colorCoding == false`)의 모노크롬 폴백을 항상 함께 처리한다.
- **신호등 점(openclaw·서버 호스트)은 `colorCoding` 의 대상이 아니다.** 그 토글은 사용량 3단계 색상의 것이고, 신호등은 색이 곧 정보라 모노크롬 폴백이 없다. 점 색은 `OpenClawHealth.dotColor` / `ServerHostHealth.dotColor` 에서 받는다 — 뷰에서 레벨을 색으로 다시 매핑하지 않는다.

## 표시 모드

`Preferences.showRemaining` 은 **보이는 숫자와 게이지 채움만** 뒤집는다. **색(위험도)은 항상 사용량 기준**이다 — 남은 양 모드에서 90% 남았다고 빨강이 되면 안 된다. 새 게이지를 만들 때 이 규칙을 다시 확인한다.

## 다크/라이트

메뉴바 뷰는 상태바 배경에 따라 자동 적응해야 한다. 팝오버는 라이트 고정(`Palette.popoverBG`)이다. 두 맥락의 색을 공유하지 않는다.

## 스냅샷 등록

UI 를 추가·변경하면 `App/SnapshotRenderer.swift` 의 렌더 목록에 반영한다 — 이 프로젝트의 시각 검증 경로다 ([docs/development.md](../../../docs/development.md) § 시각 검증).

`Form` 기반 화면은 `ImageRenderer` 로 **빈 이미지가 나온다.** 설정창 계열은 오프스크린 윈도우 캡처 경로에 등록해야 한다.

## 선택 기능의 비가시성

openclaw·Claude Code 설정처럼 전제가 없을 수 있는 요소는 **비활성 회색 표시(기능 꺼짐의 의미)가 아니라 아예 렌더하지 않는다** (PHILOSOPHY 원칙 2 / Decision #25). `if` 로 분기하되 자리(spacer·구분선)를 남기지 않는다.

서버 호스트 요소도 같다 (Decision #31). `ServerHostHealth.absent` 면 메뉴바의 서버 줄과 팝오버의 서버 섹션(구분선 포함)을 그리지 않고, 서버가 보내지 않은 신호의 줄(배터리 없는 서버의 전원 줄)은 빈 줄 없이 빠진다. 연락 두절은 "없음" 이 아니다 — 마지막 값을 흐리게 남기고, 어느 줄도 원인으로 강조하지 않는다.

설정 진입점 예외는 PHILOSOPHY 원칙 2 를 따른다 — 현재 해당하는 것은 `OpenClawSettingsSection` 의 상태 URL 입력칸뿐이다.
