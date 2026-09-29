# mongshell-menubar — macOS 메뉴바 Claude 사용량 표시 앱

맥 메뉴바에 Claude 사용량을 Claude 마크 + `5h NN% · 7d NN%`로 상시 표시하고, 클릭하면
5시간 한도·7일 한도·요금 상태를 보여주는 팝오버가 열리는 메뉴바 앱입니다. 

<img width="136" height="50" alt="image" src="https://github.com/user-attachments/assets/d01dd02e-0eff-4366-93ae-cb75ac4850f1" />
<img width="626" height="984" alt="image" src="https://github.com/user-attachments/assets/e988ab74-489b-4530-9bf4-4559608c125f" />



## 메뉴바 표시
**Claude 마크(테라코타 스타버스트)** + 5시간·7일 사용률을 **작은 링 게이지**로 컴팩트하게
표시합니다 — 왼쪽이 5h, 오른쪽이 7d. 링은 사용한 만큼 채워지고, 색상 코딩 켜짐 시 사용량
3단계(초록 <50 · 주황 <80 · 빨강 ≥80)로 색칠되며, 둘 중 하나라도 90% 이상이면 마크가
맥동합니다. **5h는 링 옆에 초기화 시각(예: `19:00`)을 함께** 보여주고(5시간 창은 리셋 시각을
놓치기 쉬워서), 7d는 링만 둡니다. 정확한 %와 7d 리셋 시각은 클릭 시 뜨는 팝오버에서 봅니다.

## openclaw 게이트웨이 상태 (선택 기능 — 상태 URL 설정 시에만 활성화)
[openclaw](https://openclaw.ai) 게이트웨이가 도는 **서버 맥**에 감시 에이전트를 설치하면
([server/README.md](server/README.md)), 에이전트가 판정·자동복구를 하고 결과를 공개 HTTPS
주소(`https://<서버>.ts.net:8443/<토큰>`)로 내놓습니다. 설정의 **openclaw** 섹션에 그 주소를
붙여넣고 **`Claude + openclaw`** 를 고르면 게이트웨이·채널 건강 상태가 **같은 메뉴바
아이템에 통합**됩니다 — 사용률 오른쪽에 발자국 + 신호등(🟢 정상 / 🟡 채널 이상 / 🔴
게이트웨이 다운 / ⚪️ 서버 연락 두절)이 붙고, 팝오버 아래에 상태·채널·서버 확인 시각이
표시됩니다. 회색은 서버 소식이 끊겼다는 뜻일 뿐 게이트웨이 고장이 아닙니다(맥북이
오프라인이어도 빨간 점이 뜨지 않게). 앱은 읽기만 하며, 서버가 자동 재시작하면 알림으로
알려줍니다. **URL 이 없거나 `Claude만`을 고르면 이 요소는 메뉴바·팝오버 어디에도 나타나지
않고 기존과 100% 동일하게 동작합니다.**

## Claude Code 설정 (선택 기능 — `~/.claude` 가 있을 때만 활성화)
설정창의 **Claude Code** 섹션에서 `~/.claude/settings.json` 을 직접 편집합니다 — 기본 모델,
추론 강도, 대체 모델, 컨텍스트 자동 압축, 권한 기본 모드. 각 항목에 무엇을 바꾸는 값인지
한글 설명이 붙어 있고, 추론 강도·권한 모드 선택지에는 문서·CLI 와 대조할 수 있게 실제
값(`xhigh`, `auto` …)을 함께 표기합니다.

권한 기본 모드는 `ask`/`auto`/`deny` 만 제공합니다 — `allow`(전부 허용)는 오클릭 위험 때문에
GUI 에서 뺐습니다. 파일에 이미 `allow` 나 앱이 모르는 값(고정 모델 ID 등)이 들어 있으면
"직접 설정한 값"으로 그대로 보여주고 유지하므로, 설정창을 열었다는 이유로 값이 바뀌지는
않습니다.

Claude Code 는 설정 파일을 감시하므로 **대부분 실행 중인 세션에도 즉시 반영**되고, `model`
만 새 세션부터 적용됩니다. 반대로 CLI 쪽 변경(`/effort`, `/fast`)도 파일 감시로 설정창에
바로 반영됩니다.

저장은 **read-modify-write** 입니다 — 저장 직전 파일을 다시 읽어 위 5개 키만 교체하므로
권한 목록·플러그인 설정 등 앱이 모르는 키는 값이 그대로 보존됩니다(다만 파일 전체가 키
정렬된 형태로 다시 쓰이므로 손으로 잡아둔 키 순서·들여쓰기는 유지되지 않습니다). 직전
내용은 가능한 경우 `settings.json.bak` 로 한 부 남습니다. 기본값으로 되돌리면 값을 쓰는
대신 **키를 삭제**합니다. `hooks`·`env`·MCP 같은 자유형 키는 의도적으로 다루지 않습니다.

> 개발 중에는 `MONGSHELL_CLAUDE_SETTINGS=<경로>` 로 실제 설정 파일 대신 사본을 쓰게 할 수
> 있습니다.

## 설치 — 각자 빌드해서 쓰기 (Apple 계정 불필요)
직접 빌드한 앱은 Gatekeeper에 막히지 않습니다. 필요한 건 **macOS 14+ 와 Xcode
(또는 Command Line Tools)** 뿐.
```bash
git clone <이 저장소 URL> && cd mongshell-menubar
./scripts/make_app.sh          # release 빌드 → mongshell-menubar.app 생성(로컬 ad-hoc 서명)
open mongshell-menubar.app                 # 메뉴바에 아이콘 등장
```
처음 실행하면:
- **Claude Code 사용자**: "키체인 접근 허용" 프롬프트 → *항상 허용* → 바로 실제 사용량 표시.
- 그 외: 팝오버의 **로그인** → 브라우저에서 Claude 로그인·승인 → 자동 복귀.

> `swift run`으로 맨 바이너리를 직접 실행하면 UserNotifications가 앱 번들을 요구해
> 크래시합니다. 항상 `.app` 번들(`make_app.sh`)로 실행하세요.

> 재빌드할 때마다 키체인 프롬프트가 다시 뜬다면 ad-hoc 서명 때문입니다 —
> [로컬 코드 서명 인증서](#키체인-프롬프트가-재빌드마다-다시-뜰-때--로컬-코드-서명-인증서) 참고.

### 개발용
```bash
./scripts/make_app.sh debug && open mongshell-menubar.app          # 디버그 빌드
./scripts/test.sh                                                  # settings.json 읽기/쓰기 회귀 테스트
swift build && MONGSHELL_SNAPSHOT=/tmp/mongshell_snaps ./.build/debug/mongshell-menubar   # 아이콘/팝오버·설정창 PNG 렌더
```

#### 키체인 프롬프트가 재빌드마다 다시 뜰 때 — 로컬 코드 서명 인증서
`make_app.sh` 는 서명할 인증서가 없으면 ad-hoc 서명(`--sign -`)으로 떨어집니다. 이때
designated requirement 가 `cdhash H"…"` 로 바이너리 해시에 고정되는데, 키체인의 *항상 허용*
은 이 requirement 를 기준으로 앱을 식별합니다. 재빌드하면 해시가 바뀌어 macOS 가 다른 앱으로
보므로 `Claude Code-credentials` 접근 프롬프트가 매번 다시 뜹니다.

자기 서명 인증서로 서명하면 requirement 가
`identifier "com.mongshell.menubar" and certificate leaf = H"…"` 가 되어 재빌드에도 신원이
유지되고, *항상 허용* 을 한 번만 누르면 됩니다. Apple Developer 계정은 필요 없습니다.

1. **Certificate Assistant** 실행:
   ```bash
   open "/System/Library/CoreServices/Certificate Assistant.app"
   ```
   > macOS 26 에서는 Keychain Access 를 열면 Passwords 앱으로 리다이렉트되고 **인증서 지원
   > 메뉴가 없습니다.** 예전 문서의 `Keychain Access → 인증서 지원 → 인증서 생성…` 경로 대신
   > Certificate Assistant 를 직접 띄우세요.
2. **직접 인증서 생성(Create a Certificate for Yourself)** 선택
3. 이름 `mongshell-menubar Dev` / 신원 유형 **자기 서명 루트** / 인증서 유형 **코드 서명**
   - 유효기간 기본값은 365일 — 늘리려면 "기본값 무효화" 체크 후 `Validity Period` 에 `3650`
   - `Key Usage` 는 `Signature` 만 (`Certificate Signing` 은 켜지 마세요),
     `Extended Key Usage` 는 `Code Signing`, `Subject Alternate Name` 은 체크 해제
   - 저장 위치 Keychain 은 **`login`**
4. 확인 → `./scripts/make_app.sh`
   ```bash
   security find-identity -p codesigning   # -v 없이
   ```

`-v` 를 붙이면 `0 valid identities found` 로 나옵니다. 자기 서명 루트는 신뢰 앵커가 없어
`CSSMERR_TP_NOT_TRUSTED` 로 분류되기 때문인데 **이 상태로도 문제없습니다** — `codesign` 은 신뢰
체인을 요구하지 않고, 키체인 ACL 매칭도 리프 인증서 지문 비교라 신뢰 여부와 무관합니다. 따라서
`security add-trusted-cert` 로 신뢰 설정을 건드릴 필요가 없습니다. `make_app.sh` 도 같은 이유로
`-v` 없이 인증서를 찾습니다.

이름을 다르게 지었으면 `SIGN_ID="<인증서 이름>" ./scripts/make_app.sh` 로 넘기세요. 서명이
제대로 붙었는지는 이렇게 확인합니다 — `cdhash` 가 아니라 `certificate leaf` 가 나와야 합니다.
```bash
codesign -dvvv --requirements - mongshell-menubar.app
```
첫 서명 때 개인 키 접근 프롬프트가 한 번 뜨는데 여기서도 *항상 허용* 을 누르면 됩니다.
배포용 `release.sh` 는 Developer ID 로 다시 서명하므로 영향받지 않습니다.

테스트는 `swift test` 가 아니라 `scripts/test.sh` 입니다 — `swift test` 는 XCTest 나
swift-testing 을 요구하는데 둘 다 Command Line Tools 에 들어 있지 않아서, Xcode 없이 빌드
가능하다는 이 프로젝트의 전제와 맞지 않습니다. 대신 실제 소스 파일을 그대로 컴파일해
검증합니다. 다루는 불변식은 하나입니다 — **보이지 않는 설정을 앱이 파괴하지 않는다.**

## 구조
```
Sources/mongshell-menubar/
  MongshellMenubarApp.swift            @main (Settings 씬은 비어 있음 — UI는 상태바+팝오버)
  App/AppDelegate.swift     NSStatusItem + NSPopover + 설정창 관리
  App/SnapshotRenderer.swift 오프스크린 PNG QA 렌더러(MONGSHELL_SNAPSHOT)
  Views/ClaudeMarkView.swift Claude 스타버스트 마크 Canvas 렌더러
  Views/MenuBarIconView.swift 상태바 마크 + 5h/7d 링 게이지(+5h 초기화 시각),
                            openclaw 신호등, 다크/라이트 적응, ≥90% 맥동
  Views/HoverSummaryView.swift hover 즉시 요약(5h/7d · 초기화 3열 Grid)
  Views/PopoverView.swift   라이트 팝오버 308px(5시간/주간/모델별 + openclaw 섹션)
  Views/SettingsView.swift  일반(자동 실행)·색상·폴링·알림·Claude Code·openclaw·계정
  Views/ClaudeSettingsSection.swift  settings.json 편집 섹션(한글 설명 캡션)
  Views/OpenClawSettingsSection.swift openclaw 상태 URL 입력·상태·확인 간격 섹션
  Design/Palette.swift      색 토큰 SSOT(사용량 3단계·팝오버 표면/텍스트)
  Models/…                  Preferences, UsageState, UsageModel(폴링/알림),
                            OpenClawHealth, OpenClawStatus(두절 판정·복구 알림 판정),
                            OpenClawModel(상태 URL 폴링/복구 알림),
                            ClaudeSettingsModel(settings.json ↔ 구조체),
                            LoginItemModel(로그인 항목 상태 캐시/안내)
  Services/…                Config, Credentials(Keychain), UsageAPIClient, AuthService(PKCE),
                            LoopbackServer(OAuth 루프백 리다이렉트 수신),
                            TimeText, OpenClawStatusClient(상태 URL HTTPS 읽기/관대한 디코딩),
                            ClaudeSettingsStore(settings.json 입출력/파일 감시),
                            LoginItemService(SMAppService 로그인 항목 등록)
```

## 데이터 소스 & 인증
- **인증 우선순위**: 자체 OAuth 로그인 토큰(Keychain) → 없으면 Claude Code CLI 토큰
  (Keychain `Claude Code-credentials` 또는 `~/.claude/.credentials.json`) 자동 감지.
  - Claude Code 사용자는 **로그인 없이** 앱이 기존 토큰을 재사용합니다. 다른 앱이 그 항목을
    읽으므로 **첫 실행 시 "키체인 접근 허용" 프롬프트**가 뜹니다 → "항상 허용".
  - Claude Code가 없으면 **OAuth 로그인**: 브라우저가 열리고 로그인·승인하면 로컬 루프백
    리스너로 **자동 복귀**합니다. 루프백 리다이렉트가 거부되면 콘솔 콜백 페이지에 표시되는
    인증 코드를 앱에 붙여넣는 방식으로 폴백합니다.
- **엔드포인트**: `GET https://api.anthropic.com/api/oauth/usage`.
  - 헤더: `Authorization: Bearer …`, `anthropic-beta: oauth-2025-04-20`,
    **`User-Agent: claude-code/<version>` (필수 — 없으면 429 도배)**.
  - 응답: `five_hour.utilization`, `seven_day.utilization`, `seven_day_<model>.utilization`
    (각각 0–100 %) + `resets_at`(ISO8601).
- **폴링**: 기본 300초, 최소 180초. 429 시 지수 백오프.
- **토큰은 각자 Keychain에만 저장**, 외부 서버로 절대 전송하지 않습니다.

## ⚠️ 배포 전 반드시 알아둘 것 (비공식 도구)
- Claude **구독(Pro/Max) 한도에는 공식 API가 없습니다.** 위 엔드포인트는 **비공개**이며
  예고 없이 변경·차단될 수 있습니다.
- 자체 OAuth는 Claude Code의 client_id/User-Agent를 사용 → **공식 클라이언트 사칭 성격의
  ToS 회색지대**입니다. 공개 배포·사용은 본인 책임입니다.
- 엔드포인트/스키마/헤더와 OAuth 파라미터는 커뮤니티 리버스엔지니어링으로 확인된 실제 값을
  사용합니다. 로그인·토큰이 없으면 UI는 샘플 데이터로 렌더됩니다.

## 배포 (지인에게 서명된 dmg 공유)
`scripts/make_app.sh`는 로컬 개발용 ad-hoc 서명까지만 하므로, 남에게 주면 Gatekeeper가
차단합니다. 서명·공증된 `.dmg`는 `scripts/release.sh`로 만듭니다.

**준비물(1회):** Apple Developer 계정($99/년) + **Developer ID Application** 인증서.
```bash
# 인증서 확인
security find-identity -v -p codesigning
# 공증 자격증명 저장(앱 암호는 appleid.apple.com에서 발급)
xcrun notarytool store-credentials mongshell-menubar-notary \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
```
**릴리스:**
```bash
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="mongshell-menubar-notary" scripts/release.sh
# → mongshell-menubar.dmg 생성. 받는 사람은 Applications로 드래그 후 실행.
```
정식 Developer ID로 서명하면 **로그인 토큰이 업데이트 후에도 유지**됩니다(ad-hoc은 빌드마다
서명이 바뀌어 재로그인 필요). 각 사용자는 자기 Claude 계정으로 로그인하며, 토큰은 각자
Keychain에만 저장됩니다.

> **주의:** 이 앱은 Claude Code의 client_id/User-Agent와 비공개 엔드포인트를 사용하는
> 비공식 도구입니다(ToS 회색지대). 공유·사용은 본인 책임이며, 위 README의 경고를 함께
> 전달하세요.
