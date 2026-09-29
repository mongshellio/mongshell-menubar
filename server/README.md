# 서버 에이전트 (mongshell-openclaw-agent) — 설치·운영 런북

openclaw 게이트웨이가 24시간 도는 **서버 맥**에 설치하는 감시 에이전트의 설치·운영 절차. 새 서버 맥에서 **위에서 아래로 그대로 따라 하면** 설치부터 맥북 연결까지 끝나도록 썼다. 설계 사양(데이터 흐름·판정 규칙·보안 경계)은 [docs/architecture.md § 3. openclaw 상태](../docs/architecture.md#3-openclaw-상태-선택-경로), 결정 배경은 [Decision #25](../docs/architecture-decisions.md) 가 권위다. 이 문서는 절차만 다룬다.

> **실기 검증은 일부만.** 2026-09-29 첫 설치(macOS 27, tailscale 1.102.4)에서 `install.sh` 는 funnel 설정 직전까지 통과했고, funnel 설정은 같은 명령을 sudo 로 손으로 실행해 확인했다. 그 결과로 `install.sh` 가 sudo 를 쓰게 고쳤지만, **고친 스크립트를 처음부터 끝까지 돌린 확인은 아직 없다.** 토큰 교체·제거(`--rotate-token`, `uninstall.sh`)와 데몬 재시작 뒤 동작도 확인하지 못했다. 가정별 확인 여부는 [6. 첫 설치 때 확인할 것](#6-첫-설치-때-확인할-것-실기-미검증-가정) 에 있다. 막히면 그 절의 **보고용 정보 수집** 명령으로 상태를 모은다.

## 목차

0. [전체 그림](#0-전체-그림)
1. [준비물 체크리스트](#1-준비물-체크리스트)
2. [서버 맥 설치](#2-서버-맥-설치) — A. 기본 도구 · B. Tailscale · C. 관리 콘솔 · D. 상시 가동 · E. install.sh · F. 동작 확인
3. [각 맥북 설정](#3-각-맥북-설정)
4. [일상 운영](#4-일상-운영)
5. [문제 해결](#5-문제-해결)
6. [첫 설치 때 확인할 것 (실기 미검증 가정)](#6-첫-설치-때-확인할-것-실기-미검증-가정)
7. [알려진 한계](#7-알려진-한계)

---

## 0. 전체 그림

```
┌──────────────── 서버 맥 (항상 켜 둠) ────────────────┐
│  openclaw 게이트웨이 (launchd)                        │
│        ▲ probe · kickstart                            │
│  mongshell-openclaw-agent (LaunchAgent, 60초 주기)    │
│        │ 쓰기                                         │
│        ▼                                              │
│  status.json ◀── tailscaled (brew 판, root) 가 서빙   │
└────────────────────────┬─────────────────────────────┘
                         │ Tailscale Funnel (공개 HTTPS, 포트 8443)
                         ▼
          https://<서버 DNS 이름>:8443/<토큰>
             ▲            ▲            ▲
          맥북 A        맥북 B        휴대폰(확인용)
       (메뉴바 앱)    (메뉴바 앱)   ── Tailscale 불필요
```

- 에이전트가 게이트웨이를 주기적으로 검사하고 필요하면 재시작(자동복구)한 뒤, 판정 결과를 `status.json` 에 쓴다. 에이전트 자신은 네트워크 리스너가 없다.
- 서버 맥의 tailscaled 가 그 파일을 Funnel 로 **인터넷에 공개**한다. URL 경로의 토큰이 유일한 접근 통제다 — 응답에는 상태 판정만 담기고 PID·원시 출력은 없다.
- 맥북의 메뉴바 앱은 그 URL 을 HTTPS 로 **읽기만** 한다. **Tailscale 은 서버 맥에만 설치한다.** 맥북·휴대폰에는 필요 없다.

공개는 **8443 포트 전용**이다. funnel 은 포트 단위로 공개되므로, 443 에 tailnet 전용으로 둔 다른 `tailscale serve` 핸들러가 함께 노출되지 않게 분리했다. 설치 스크립트는 8443 에 이 설치가 만들지 않은 핸들러가 있으면 중단한다.

## 1. 준비물 체크리스트

- [ ] **Tailscale 계정** — 관리 콘솔(https://login.tailscale.com/admin) 에서 정책 파일을 고칠 수 있는 관리자(Admin/Owner) 권한
- [ ] **서버 맥 관리자 권한** — `sudo` 가 필요한 단계가 있다 (tailscaled 데몬, operator, pmset, `install.sh` 의 funnel 설정)
- [ ] **openclaw 가 서버 맥에서 이미 launchd 로 돌고 있을 것**, 그리고 아래 두 조건을 만족할 것 (에이전트가 이 경로·위치만 본다)
  - 바이너리가 `/opt/homebrew/bin/openclaw` 또는 `/usr/local/bin/openclaw` 에 있다
  - 게이트웨이가 **에이전트를 설치할 같은 사용자**의 `~/Library/LaunchAgents/` 에 plist 로 등록돼 있고, 파일 이름에 `claw` 가 들어 있다 (openclaw 기본 레이블: `ai.openclaw.gateway`)
  - 그 plist 의 **파일 이름(확장자 제외)이 plist 안의 `Label` 과 같을 것** — 에이전트는 파일 이름을 레이블로 보고 `launchctl kickstart` 한다
  - 확인: `ls -l /opt/homebrew/bin/openclaw /usr/local/bin/openclaw; ls ~/Library/LaunchAgents | grep -i claw` — 바이너리는 둘 중 하나만 보이면 정상이다 (다른 쪽의 `No such file or directory` 는 무시). 레이블 일치는 [E](#e-serverinstallsh-실행) 의 게이트웨이 레이블 확인 명령으로 본다
- [ ] **repo 클론 가능** — `https://github.com/mongshellio/mongshell-menubar` 는 공개 repo 라 인증 없이 클론된다
- [ ] **외부망 기기 하나** — 와이파이를 끈 휴대폰 등. 공개 URL 확인용
- [ ] **URL 보관 장소** — 비밀번호 관리자 등 (설치가 출력하는 URL 이 곧 접근권이다)
- 소요 시간: 처음이면 **30~60분** (대부분 Command Line Tools 설치와 관리 콘솔 설정). 이후 맥북 1대당 5~10분.

## 2. 서버 맥 설치

각 단계는 **실행할 명령 → 성공하면 이렇게 보인다 → 안 되면** 순서다. 명령은 모두 서버 맥의 터미널에서, **에이전트를 돌릴 사용자(= openclaw 게이트웨이를 돌리는 사용자)** 로 실행한다.

### A. 기본 도구

- [ ] **Command Line Tools** (Swift 컴파일러 포함 — 설치 스크립트가 에이전트를 소스에서 빌드한다)
  ```bash
  xcode-select --install     # 이미 설치돼 있으면 "already installed" 로 끝난다
  swift --version
  ```
  성공: `Apple Swift version 6.x …` 가 나온다. `Package.swift` 가 `swift-tools-version: 6.0` 이라 **Swift 6 이상**이 필요하다.
  안 되면: Swift 5.x 가 나오면 소프트웨어 업데이트에서 Command Line Tools 를 갱신한다. → [5-1](#5-1-installsh--uninstallsh-메시지별) `swift 가 없습니다`

- [ ] **Homebrew**
  ```bash
  brew --version
  ```
  성공: `Homebrew 4.x …`. 없으면 https://brew.sh 의 설치 명령을 따른다.

- [ ] **repo 클론** — 위치는 자유지만 `~/Documents`·`~/Desktop`·`~/Downloads` 는 피한다 (iCloud 동기화·개인정보 보호 권한 프롬프트 영향권). 권장:
  ```bash
  mkdir -p ~/src && cd ~/src
  git clone https://github.com/mongshellio/mongshell-menubar.git
  cd mongshell-menubar
  ```
  성공: `ls server` 에 `README.md install.sh lib.sh uninstall.sh` 가 보인다. 이후 명령은 모두 이 repo 루트에서 실행한다.

### B. Tailscale (오픈소스판, brew formula)

App Store/Standalone 판 앱이 아니라 **brew formula** 를 쓴다 — `install.sh` 가 `tailscaled` 데몬을 전제로 한다.

- [ ] **App Store/Standalone 판이 있으면 먼저 제거** — 메뉴바의 Tailscale 아이콘에서 종료한 뒤 `/Applications/Tailscale.app` 을 휴지통으로.
  ```bash
  ls -d /Applications/Tailscale.app 2>/dev/null || echo "앱 판 없음"
  ```
  성공: `앱 판 없음`.

- [ ] **설치·데몬 시작·operator·로그인** — operator 를 로그인과 함께 준다. operator 를 주면 `tailscale status`·`tailscale serve status` 를 sudo 없이 쓸 수 있다. 파일을 서빙하는 funnel 설정은 실기에서 operator 로도 거부돼(원인 미확인) `install.sh` 가 그 명령을 sudo 로 실행한다 ([E](#e-serverinstallsh-실행)). 경로 해제가 sudo 없이 되는지는 아직 확인하지 못했다 ([6](#6-첫-설치-때-확인할-것-실기-미검증-가정) 가정 6).
  ```bash
  brew install tailscale
  sudo brew services start tailscale   # tailscaled 를 root 데몬으로 상시 실행
  sudo tailscale up --operator=$USER   # 출력되는 로그인 URL 을 브라우저로 열어 승인
  ```
  성공:
  ```bash
  pgrep -lx tailscaled                                              # → "<PID> tailscaled"
  tailscale status --json | plutil -extract BackendState raw -o - - # → Running
  ```
  안 되면: → [5-1](#5-1-installsh--uninstallsh-메시지별) `tailscaled 데몬이 돌고 있지 않습니다` / `Tailscale 상태가 Running 이 아닙니다`

  이미 로그인한 기기라면 operator 만 따로 준다: `sudo tailscale set --operator=$USER` (성공하면 출력 없음).

### C. Tailscale 관리 콘솔

관리 콘솔: https://login.tailscale.com/admin

- [ ] **DNS** 탭 → **MagicDNS** 켜기
- [ ] **DNS** 탭 → **HTTPS Certificates** 켜기
- [ ] **Access controls** (정책 파일) 에 funnel 권한 추가 — 서버 기기에만 준다. 기존 정책 파일의 최상위 객체 안에 `tagOwners` 와 `nodeAttrs` 를 넣는다 (이미 있는 키면 항목만 추가):
  ```jsonc
  "tagOwners": {
    "tag:openclaw-server": ["autogroup:admin"]
  },
  "nodeAttrs": [
    {
      "target": ["tag:openclaw-server"],
      "attr":   ["funnel"]
    }
    // 대안(범위가 넓음): 태그 없이 모든 멤버 기기에 허용하려면
    // "target": ["autogroup:member"]
  ]
  ```
- [ ] **Machines** 탭 → 서버 맥의 `⋯` → **Edit ACL tags** 에서 `tag:openclaw-server` 를 붙인다.
  태그가 붙은 기기는 사용자 소유가 아니라 태그 소유로 바뀐다(Tailscale 의 태그 기기 규칙). 이 서버 맥에는 영향이 없지만, 기존 ACL 이 사용자 기준으로 이 기기를 허용하고 있었다면 확인한다.

확인 (서버 맥 터미널):
```bash
tailscale status --json | plutil -extract Self.DNSName raw -o - -   # → <이름>.<tailnet>.ts.net.  (끝의 점은 정상)
tailscale status --json | plutil -extract Self.Tags json -o - -     # → ["tag:openclaw-server"]
```
안 되면: DNSName 이 비거나 에러면 MagicDNS 가 꺼져 있다. `Self.Tags` 가 `No value at that key path` 면 태그가 아직 안 붙었다 (콘솔에서 태그 저장 후 수십 초 걸릴 수 있다). HTTPS Certificates·funnel 권한은 여기서 직접 확인할 명령이 없고, E 단계의 funnel 설정·URL 확인에서 드러난다.

### D. 상시 가동

에이전트는 사용자 LaunchAgent 라 **해당 사용자가 로그인해 있어야** 돈다 (화면 잠금은 괜찮다).

- [ ] 시스템 설정 → 잠금 화면/에너지: **잠자기 방지** (디스플레이는 꺼져도 됨)
- [ ] 시스템 설정 → 사용자 및 그룹: 재부팅 후 **자동 로그인** 켜기. FileVault 가 켜져 있으면 macOS 가 자동 로그인을 허용하지 않는다 — 이 경우 정전·재부팅 뒤에는 직접 로그인해야 에이전트가 다시 돈다.
- [ ] 정전 복구 후 자동 시작:
  ```bash
  sudo pmset -a autorestart 1
  pmset -g | grep -E '^ *(sleep|autorestart)'
  ```
  성공: `sleep 0` (또는 잠자기 방지 설정), `autorestart 1`. 모델에 따라 `autorestart` 줄이 안 보일 수 있다 (미지원 기기).

### E. `server/install.sh` 실행

- [ ] **먼저 [6](#6-첫-설치-때-확인할-것-실기-미검증-가정) 가정 1 확인** (첫 설치 때만) — 공개 설정이 비어 있는 지금 한 번 기록해 둔다:
  ```bash
  tailscale serve status --json; echo "exit $?"
  ```
- [ ] repo 루트에서 실행. 첫 설치는 막혔을 때 보고할 수 있게 출력을 저장하며 실행하는 것을 권한다 ([6 보고용 정보 수집](#막혔을-때-보고용-정보-수집)):
  ```bash
  server/install.sh 2>&1 | tee ~/openclaw-install.log   # 또는 그냥 server/install.sh
  ```
  `▶ tailscale funnel 설정` 단계에서 **맥 로그인 비밀번호**를 물을 수 있다 (sudo — 최근에 인증했으면 묻지 않는다). 실기에서 파일을 서빙하는 funnel 설정이 operator 를 준 사용자로도 거부됐기 때문이다. 비밀번호를 입력할 수 있게 터미널에서 직접 실행한다. `| tee` 로 실행해도 입력은 되지만 프롬프트는 로그 파일에 남지 않는다.

| 옵션 | 뜻 |
|---|---|
| (없음) | 첫 설치: 60초 주기, 자동복구 켬. 재실행: 지난번 설치 옵션 그대로 |
| `--interval N` | probe 주기(초). **15~86400**, 6자리 이하 정수 |
| `--auto-heal` | 게이트웨이 자동복구 켜기 (`--no-auto-heal` 로 꺼 둔 것을 되돌릴 때) |
| `--no-auto-heal` | 게이트웨이 자동복구 끄기 (상태 보고만) |
| `--rotate-token` | URL 토큰 재발급 — 옛 URL 은 즉시 무효 ([4. 토큰 교체](#토큰-교체)) |
| `-h`, `--help` | 도움말 |

**성공하면 이렇게 보인다** (각 `▶` 는 스크립트 단계, 값은 예시):
```
▶ 사전조건 확인
  tailscale: /opt/homebrew/bin/tailscale (server-mac.tail1234.ts.net)
  openclaw : /opt/homebrew/bin/openclaw
▶ URL 토큰 준비
  새 토큰 발급                 ← 재실행이면 "기존 토큰 재사용"
▶ 공개 포트 8443 점검
▶ 에이전트 빌드 (release)
  (swift build 출력)
  → ~/Library/Application Support/mongshell-openclaw-agent/mongshell-openclaw-agent
▶ 게이트웨이 launchd 레이블 탐색
  → ai.openclaw.gateway        ← 게이트웨이 레이블이 맞는지 꼭 확인
▶ LaunchAgent 등록
▶ 첫 상태 파일 대기 (최대 40s)
  → ~/Library/Application Support/mongshell-openclaw-agent/status.json
▶ tailscale funnel 설정
  파일을 서빙하는 funnel 설정은 관리자 권한이 필요해 sudo 로 실행합니다 (비밀번호를 물을 수 있습니다).
  Password:                    ← 맥 로그인 비밀번호 (최근에 인증했으면 안 나온다)
  (tailscale 출력)
▶ 공개 URL 확인
  → 응답 확인
  → 루트 404 확인 (토큰 경로만 공개)

설치 완료.
  상태 URL : https://server-mac.tail1234.ts.net:8443/<32자리 토큰>
  로그     : ~/Library/Logs/mongshell-openclaw-agent.log
  옵션     : 주기 60초, 자동복구 켬 (대상 ai.openclaw.gateway)

위 상태 URL 을 메뉴바 앱 설정의 openclaw 섹션에 붙여넣으세요.
```

안 되면: `오류:` 로 시작하는 마지막 메시지를 [5-1](#5-1-installsh--uninstallsh-메시지별) 에서 찾는다. `경고:` 는 설치를 멈추지 않는다.

- [ ] **게이트웨이 레이블 확인** — `▶ 게이트웨이 launchd 레이블 탐색` 아래 `→` 줄이 실제 게이트웨이 레이블인지 본다. 스크립트는 `~/Library/LaunchAgents` 의 plist 를 이름순으로 정렬해 **이름에 `claw` 가 들어간 첫 번째**(에이전트 자신 제외)를 고른다. `claw` 가 들어간 plist 가 여러 개면 엉뚱한 것이 잡힐 수 있다. 게이트웨이를 재설치해 레이블이 바뀌면 `install.sh` 를 다시 돌린다.
  에이전트는 plist **파일 이름**을 레이블로 kickstart 하므로, 파일 이름과 plist 안의 `Label` 이 같고 launchd 에 실제로 로드돼 있어야 자동복구가 된다:
  ```bash
  LABEL=ai.openclaw.gateway     # 위 → 줄에 나온 값
  plutil -extract Label raw -o - ~/Library/LaunchAgents/$LABEL.plist   # → $LABEL 과 같은 문자열
  launchctl print gui/$(id -u)/$LABEL | head -3                        # → 에러 없이 서비스 정보가 나와야 한다
  ```
  다르면 자동복구의 `kickstart` 가 실패한다 (로그에 `복구 시도 — … kickstart 실패`).

- [ ] **상태 URL 보관** — `상태 URL :` 줄을 **비밀번호 관리자**(1Password, macOS 암호 앱 등)에 저장한다. 이 URL 을 아는 사람은 누구나 상태를 읽을 수 있다(토큰 = 접근권). 채팅·이슈·스크린샷에 원문으로 남기지 않는다. 잊어도 [4. URL 다시 보기](#url-다시-보기) 로 다시 만들 수 있다.

**재실행은 안전하다** — 토큰은 재사용되고(URL 불변) LaunchAgent 만 교체된다. 주기·자동복구 옵션은 데이터 폴더의 `options` 파일에 저장돼, 재실행 때 **생략한 옵션은 지난 값을 이어받고** 명시한 옵션만 바뀐다. 적용된 값은 설치 끝의 `옵션 :` 줄에서 확인한다. 저장 파일의 값이 깨져 있으면 `경고: 저장된 … 올바르지 않아 무시합니다` 를 내고 그 항목을 버린 뒤 기본값(60초 / 켬)을 쓰며, 파일을 읽을 수 없으면 `경고: 저장된 설치 옵션을 읽을 수 없어 기본값을 씁니다` 를 내고 두 항목 모두 기본값을 쓴다. 어느 경우든 설치 끝에 실제 적용된 값으로 파일이 다시 쓰인다.

설치되는 것:

| 경로 | 내용 |
|---|---|
| `~/Library/Application Support/mongshell-openclaw-agent/` | 바이너리, `status.json`(0644), `token`(0600), `options`(설치 옵션, `key=value`) |
| `~/Library/LaunchAgents/com.mongshell.openclaw-agent.plist` | LaunchAgent (RunAtLoad·KeepAlive) |
| `~/Library/Logs/mongshell-openclaw-agent.log` | 시작·상태 변화·복구 시도·쓰기 실패·자기 레이블 경고 시에만 한 줄씩 기록 ([5-3](#5-3-서버-맥-진단-명령)) |
| tailscaled 의 serve 설정 | 포트 8443, 경로 `/<토큰>` → `status.json` (funnel, `--bg` 로 저장 — 데몬 재시작 뒤 유지되는지는 [6](#6-첫-설치-때-확인할-것-실기-미검증-가정) 가정 4) |

### F. 동작 확인

- [ ] **외부망**(와이파이 끈 휴대폰 등)에서 상태 URL 을 연다 → JSON 이 보여야 한다. 실제 파일은 키 정렬·들여쓰기된 형태다:
  ```json
  {
    "autoHeal" : true,
    "checkedAt" : "2026-09-29T03:12:45Z",
    "detail" : "Telegram default",
    "health" : "ok",
    "intervalSeconds" : 60,
    "lastHeal" : null,
    "schema" : 1
  }
  ```
  `health` 는 `ok` / `degraded` / `down` 중 하나다. 서버 맥 자신에서 연 결과는 공개 여부의 증거로 보지 않는다 ([6](#6-첫-설치-때-확인할-것-실기-미검증-가정) 가정 8) — 반드시 외부망 기기로 연다.
- [ ] 1분쯤 뒤 새로고침 → `checkedAt` 이 갱신돼야 한다 (UTC 표기).
- [ ] 토큰 없이 `https://<서버 DNS 이름>:8443/` 를 열면 **404** 여야 한다 (토큰 경로만 공개). 설치 스크립트도 끝에 이것을 확인한다 — 404 가 아니라 2xx/3xx 면 포트 8443 의 funnel 을 통째로 내리고 중단, 이 맥에서 닿지 않으면 경고만 한다.

안 되면: → [5-2](#5-2-공개-url--메뉴바-증상별)

## 3. 각 맥북 설정

맥북마다 아래를 반복한다. **맥북에는 Tailscale 이 필요 없다.**

- [ ] **메뉴바 앱 설치** — 이 repo 의 방법 중 하나:
  - 직접 빌드 (Command Line Tools 필요, Apple 계정 불필요): 루트 README [§ 설치 — 각자 빌드해서 쓰기](../README.md#설치--각자-빌드해서-쓰기-apple-계정-불필요)
    ```bash
    git clone https://github.com/mongshellio/mongshell-menubar.git && cd mongshell-menubar
    ./scripts/make_app.sh          # release 빌드 → mongshell-menubar.app
    open mongshell-menubar.app
    ```
  - 서명된 dmg 를 받은 경우: Applications 로 드래그 후 실행 (만드는 법: 루트 README [§ 배포](../README.md#배포-지인에게-서명된-dmg-공유))
- [ ] 메뉴바 아이콘 클릭 → 팝오버의 **설정…** → **openclaw** 섹션
- [ ] **상태 URL** 칸에 서버 설치가 출력한 URL 을 붙여넣고 **적용** (또는 Return)
  - `https:// 주소만 사용할 수 있습니다` / `주소 형식이 올바르지 않습니다` 가 뜨면 URL 을 다시 복사한다 (앞뒤 공백은 자동으로 지워진다).
- [ ] 적용 후 나타나는 **메뉴바 표시** 에서 **`Claude + openclaw`** 선택 (기본값은 `Claude만` — 이대로면 메뉴바에 아무것도 안 붙는다)
- [ ] 같은 섹션의 **상태** 줄에 초록 점과 `정상 — …` 이 뜨는지, **자동 복구** 가 `서버에서 켜짐` 인지 확인. **확인 간격**(30/60/120초)은 맥북마다 고를 수 있다.

메뉴바 신호등 의미:

| 점 | 상태 (설정의 상태 줄) | 뜻 |
|---|---|---|
| 🟢 | 정상 | 게이트웨이와 채널이 정상 |
| 🟡 | 채널 이상 | 게이트웨이는 응답하지만 채널 일부가 멈춤/오류. 서버가 모르는 `health` 값도 여기로 온다 |
| 🔴 | 게이트웨이 다운 | **서버가** 게이트웨이 다운을 보고함 (openclaw 바이너리가 없을 때 포함) |
| ⚪ | 서버 연락 두절 / 확인 중… | 서버 소식이 끊김 — 게이트웨이 고장이 **아니다**. 맥북이 오프라인이거나, Funnel·서버 맥·에이전트 쪽 문제. 마지막 성공 응답이 일정 시간(서버 주기 기준, [4. 자동복구 끄기 / 주기 변경](#자동복구-끄기--주기-변경)) 넘게 오래되면 회색이 된다 |

서버가 자동 재시작하면 맥북에 `openclaw 자동 재시작됨 (서버)` / `openclaw 자동 재시작 실패 (서버)` 알림이 뜬다 (앱 실행 후 첫 응답은 기준점이라 알리지 않는다).

## 4. 일상 운영

명령은 모두 **서버 맥**, repo 루트 기준이다.

### URL 다시 보기

토큰 파일과 MagicDNS 이름으로 URL 을 다시 만든다 (토큰은 바뀌지 않는다):
```bash
DNS="$(tailscale status --json | plutil -extract Self.DNSName raw -o - - | sed 's/\.$//')"
TOKEN="$(tr -d '[:space:]' < ~/Library/Application\ Support/mongshell-openclaw-agent/token)"
echo "https://$DNS:8443/$TOKEN"
```
`server/install.sh` 를 다시 실행해도 마지막에 같은 URL 을 출력한다 (옵션도 지난 값 그대로).

### 코드 업데이트

```bash
git pull && server/install.sh        # 설치 때 쓴 --interval / --no-auto-heal 은 저장값으로 이어진다
```
토큰이 재사용되므로 맥북 설정은 그대로 둔다. 새 에이전트가 이전 `status.json` 의 `lastHeal` 을 읽어 복구 쿨다운(600초)을 이어받는다.

### 토큰 교체

URL 이 새어 나갔거나 주기적으로 바꾸고 싶을 때:
```bash
server/install.sh --rotate-token     # 주기·자동복구는 저장값 그대로
```
옛 funnel 경로를 먼저 내리고, 실제로 사라진 것을 `tailscale serve status` 로 확인한 뒤에만 새 토큰을 발급한다 (확인 못 하면 새 토큰을 만들지 않고 중단). 옛 URL 은 즉시 404 가 된다 → **모든 맥북에서 새 URL 을 다시 붙여넣어야** 한다 (안 하면 ⚪ `주소 또는 토큰이 맞지 않습니다`).

### 자동복구 끄기 / 주기 변경

```bash
server/install.sh --no-auto-heal     # 상태 보고만 (맥북 설정의 "자동 복구" 가 "서버에서 꺼짐" 으로 바뀐다)
server/install.sh --interval 30      # probe 주기 30초 (자동복구는 저장값 그대로)
server/install.sh --interval 60 --auto-heal   # 기본값(60초, 자동복구 켬)으로 되돌리기
```
주기를 늘리면 맥북의 연락 두절 판정도 그만큼 느슨해진다 — 마지막 성공 응답이 `max(180초, 3×주기)` 보다 오래되면 회색 (판정 사양: [architecture.md § 3](../docs/architecture.md#3-openclaw-상태-선택-경로)).

### 제거

```bash
server/uninstall.sh          # 확인 프롬프트
server/uninstall.sh --yes    # 묻지 않음
```
funnel 경로 → LaunchAgent → 데이터 폴더(토큰·설치 옵션 포함) 순으로 지운다. Tailscale 자체(데몬·로그인·다른 serve/funnel 설정)와 로그 파일은 남긴다. 공개 경로가 실제로 내려갔는지 `tailscale serve status` 로 다시 확인하며, 확인하지 못하면(tailscaled 가 꺼져 있을 때 포함 — `--bg` 로 저장된 공개 설정은 데몬 재기동 시 되살아난다) **아무것도 지우지 않고 중단한다** — 토큰 파일이 남아야 재실행으로 같은 경로를 끌 수 있다. 성공하면 `제거 완료. 로그 파일은 남겨 뒀습니다: …` 가 나온다. 맥북 쪽은 설정의 **지우기** 로 URL 을 비우면 openclaw 요소가 사라진다.

## 5. 문제 해결

### 5-1. install.sh / uninstall.sh 메시지별

`오류:` 는 중단, `경고:` 는 계속 진행이다. 공통 원칙: 공개 여부를 **확인할 수 없으면 진행하지 않는다**(fail-closed). 대부분 원인을 고친 뒤 같은 명령을 다시 실행하면 된다. 메시지가 안내하는 `tailscale funnel … off` 명령이 권한 거부로 실패하면 같은 명령 앞에 `sudo` 를 붙인다.

**사전조건 (install.sh)**

| 메시지 | 원인 | 해결 |
|---|---|---|
| `App Store/Standalone 판 Tailscale 앱만 발견됐습니다…` | tailscaled 없이 `/Applications/Tailscale.app` 만 있음 | 앱 종료·제거 후 [B](#b-tailscale-오픈소스판-brew-formula) |
| `tailscaled 데몬이 돌고 있지 않습니다…` | 데몬 미시작 | `sudo brew services start tailscale`, 확인 `pgrep -lx tailscaled` |
| `tailscale CLI 가 PATH 에 없습니다…` | brew 경로가 PATH 에 없음 | `brew install tailscale`, `command -v tailscale` 확인 (Apple Silicon 은 `/opt/homebrew/bin`) |
| `'tailscale status --json' 실패…` | 로그인 전·데몬 통신 실패 | `tailscale up`, `tailscale status` |
| `Tailscale 상태가 Running 이 아닙니다 (현재: …)` | `NeedsLogin`·`Stopped` 등 | `tailscale up` 으로 로그인/연결 |
| `이 기기의 MagicDNS 이름을 얻지 못했습니다…` | MagicDNS 꺼짐 | [C](#c-tailscale-관리-콘솔) MagicDNS 켜기 |
| `openclaw 바이너리가 없습니다 (/opt/homebrew/bin, /usr/local/bin 확인).` | 두 경로 어디에도 실행 파일 없음 (npm 전역 경로 등) | 두 경로 중 하나에 openclaw 가 있어야 한다. 에이전트도 같은 두 경로만 본다 |
| `swift 가 없습니다…` | Command Line Tools 없음 | `xcode-select --install` |
| `openssl 이 없습니다.` | 기본 `/usr/bin/openssl` 이 PATH 에 없음 | `ls -l /usr/bin/openssl`, PATH 확인 |
| `--interval 에는 6자리 이하 정수(초)가 필요합니다` / `--interval 은 15~86400 초여야 합니다: …` / `알 수 없는 인자: …` | 옵션 오류 | `server/install.sh --help` |
| `경고: 저장된 주기가 올바르지 않아 무시합니다 (…): interval=…` / `경고: 저장된 자동복구 값이 올바르지 않아 무시합니다 (…): auto_heal=…` | 데이터 폴더의 `options` 파일 값이 깨짐 | 깨진 항목은 버려지고 기본값(60초 / 켬)으로 설치되며, 설치 끝에 그 적용값으로 파일이 다시 쓰인다. 다른 값을 원하면 `--interval N` / `--no-auto-heal` 로 명시해 재실행한다 |
| `경고: 저장된 설치 옵션을 읽을 수 없어 기본값을 씁니다: …` | `options` 파일 읽기 권한 없음 | 두 항목 모두 기본값으로 설치된다. `ls -l` 로 권한 확인. 다른 값을 원하면 옵션을 명시해 재실행한다 |

**토큰·공개 포트 (install.sh, 공용 lib.sh)**

| 메시지 | 원인 | 해결 |
|---|---|---|
| `경고: 토큰 파일 형식이 올바르지 않아 새로 발급합니다: …` | 토큰 파일이 32자리 hex 가 아님 | 자동으로 새 토큰. 옛 경로가 남아 있으면 다음 단계에서 아래 "다른 핸들러" 로 멈춘다 |
| `'tailscale serve status --json' 출력이 JSON 이 아닙니다: …` (뒤이어 아래 `…읽지 못해…` 오류) | 빈 설정의 출력 형식이 가정과 다름 ([6](#6-첫-설치-때-확인할-것-실기-미검증-가정) 가정 1) | 원문을 보고용 정보와 함께 기록. `tailscale serve status` 확인 |
| `'tailscale serve status --json' 을 읽지 못해 포트 8443 가 비어 있는지 확인할 수 없습니다.` | serve 설정 조회 실패 | `tailscale serve status --json; echo $?` 로 원인 확인 |
| `포트 8443 에 이 설치가 만들지 않은 serve 핸들러가 있습니다…` (목록 뒤따름) | 8443 에 다른 경로·TCP 포워딩이 있음. 토큰 파일을 잃은 옛 설치의 경로도 여기 걸린다 | `tailscale serve status` 로 확인. 8443 을 다른 용도로 쓰지 않는다면 `tailscale funnel --https=8443 off` 로 포트째 내리고 재실행. `tailscale serve reset` 은 443 등 **모든** 포트 설정을 지우므로 피한다 |
| `tailscale serve 설정을 읽지 못해 옛 공개 경로 해제 여부를 확인할 수 없습니다…` | (`--rotate-token`·uninstall) 설정 조회 실패 | 위와 같음 |
| `옛 공개 경로 해제 실패…` | `funnel … --set-path=/<옛토큰> off` 실패 | 메시지의 명령으로 직접 끈 뒤 재실행 |
| `해제 후 tailscale serve 설정을 다시 읽지 못했습니다…` | 해제 후 재조회 실패 | `tailscale funnel status` 로 옛 경로가 사라졌는지 직접 확인 |
| `해제 명령은 성공했지만 옛 공개 경로가 남아 있습니다…` | `off` 가 경로를 안 지움 ([6](#6-첫-설치-때-확인할-것-실기-미검증-가정) 가정 6) | 메시지의 명령으로 끈 뒤 재실행, 반복되면 보고 |

**빌드·등록·공개 (install.sh)**

| 메시지 | 원인 | 해결 |
|---|---|---|
| (swift 컴파일 에러로 종료) | Swift 버전 낮음, 소스 문제 | `swift --version` 이 6 이상인지. repo 루트에서 `swift build -c release --product mongshell-openclaw-agent` 로 재현 |
| `빌드 산출물을 찾지 못했습니다: …` | 빌드 경로 불일치 | 위 명령 재현 후 보고 |
| `경고: 게이트웨이 plist 를 찾지 못해 기본값 ai.openclaw.gateway 을 씁니다.` | `~/Library/LaunchAgents` 에 `claw` plist 없음 | 게이트웨이가 다른 사용자/시스템 도메인에 있으면 자동복구가 실패한다. [1](#1-준비물-체크리스트) 조건 확인 |
| `생성한 plist 가 올바르지 않습니다: …` | plist 생성 오류 | `plutil -lint ~/Library/LaunchAgents/com.mongshell.openclaw-agent.plist` 결과와 함께 보고 |
| `경고: 설치 옵션을 저장하지 못했습니다 — 다음 재실행은 옵션을 다시 줘야 합니다: …` | 데이터 폴더 쓰기 실패 | 에이전트는 이번 옵션으로 돈다. `ls -la ~/Library/Application\ Support/mongshell-openclaw-agent/` 로 권한 확인 |
| `launchctl bootstrap 실패…` | 등록 실패 | 메시지의 `launchctl bootstrap gui/<uid> …` 를 직접 실행해 에러 확인. 해당 사용자가 서버 맥 화면에 로그인해 있지 않으면 `gui/<uid>` 도메인이 없어 실패한다 — 로그인 상태([D](#d-상시-가동))에서 재실행 |
| `상태 파일이 생기지 않았습니다. 로그 확인: …` | 에이전트가 40초 안에 첫 파일을 못 씀 | `tail -n 50 ~/Library/Logs/mongshell-openclaw-agent.log`, `launchctl print gui/$(id -u)/com.mongshell.openclaw-agent` 의 `last exit code` |
| `토큰 형식이 올바르지 않습니다 (32자리 hex 가 아님)…` | 새 토큰 발급(`openssl rand -hex 16`)이 기대한 값을 내지 못함 | 메시지의 토큰 파일을 지우고 재실행. 반복되면 `openssl rand -hex 16` 을 직접 실행해 출력 확인 |
| `sudo 인증 실패…` | sudo 가 비밀번호를 받지 못함 (터미널 없이 실행·비밀번호 오류), 관리자 계정이 아님 | 터미널에서 직접 재실행. 이 시점에 에이전트는 이미 설치돼 돌고 있으므로 재실행은 안전하다 |
| `tailscale funnel 설정 실패…` | HTTPS 인증서·funnel nodeAttr 미설정 등 — 바로 위 tailscale 출력이 원인을 말한다 | [C](#c-tailscale-관리-콘솔) 재확인 후 재실행. 에이전트는 이미 설치돼 돌고 있다 |
| `401 Unauthorized: must be root, or be an operator and able to run 'sudo tailscale' to serve a path or Unix socket` (tailscale 의 출력) | 파일을 서빙하는 serve 설정을 sudo 없이 보냄 — funnel 설정을 sudo 없이 실행하는 옛 `install.sh`, 또는 명령을 손으로 실행 | `install.sh` 가 funnel 설정을 sudo 로 실행하는 판인지 확인하고(`grep -n 'sudo "\$TAILSCALE"' server/install.sh`), 손으로 실행했다면 같은 명령 앞에 `sudo` 를 붙인다 |
| `경고: 이 맥에서 URL 응답을 확인하지 못했습니다 (전파 지연일 수 있음)…` | 인증서 첫 발급 지연·자기 자신 접속 불가 | 몇 분 뒤 외부망 기기로 [F](#f-동작-확인) |
| `토큰 없는 https://…:8443/ 가 NNN 를 돌려줍니다…` | 루트가 404 가 아님 = 토큰 외 무언가 공개됨. 스크립트가 8443 funnel 을 내렸다 | `tailscale funnel status` 로 8443 의 다른 핸들러를 끄고 재설치. "내리는 데도 실패했습니다" 가 함께 나오면 `tailscale funnel --https=8443 off` 를 직접 |
| `경고: …에 닿지 못해 루트 비공개를 확인하지 못했습니다…` / `…예상한 404 가 아닌 NNN…` | 이 맥에서 확인 불가 | 외부망 기기로 루트가 404 인지 확인 |

**uninstall.sh**

| 메시지 | 원인 | 해결 |
|---|---|---|
| `tailscaled 가 돌고 있지 않아 funnel 경로를 해제할 수 없습니다…` | 데몬 꺼짐 (저장된 공개 설정은 데몬 재기동 시 되살아난다) | `sudo brew services start tailscale` 후 재실행 |
| `tailscaled 는 돌고 있는데 tailscale CLI 가 PATH 에 없어…` | PATH | `command -v tailscale` 확인 |
| `이 기기의 MagicDNS 이름을 얻지 못해 공개 경로를 확인할 수 없습니다…` | 로그아웃·MagicDNS 꺼짐 | `tailscale status` |
| `(토큰 파일 없음 — 건너뜀)` | 이미 지워졌거나 설치된 적 없음 | 공개 경로가 남았는지 `tailscale funnel status` 로 확인 |
| 해제 관련 `오류:` | 위 "토큰·공개 포트" 표와 같다 | |

### 5-2. 공개 URL · 메뉴바 증상별

맥북 설정의 **상태** 줄에 `서버 연락 두절 — <detail>` / `게이트웨이 다운 — <detail>` 형태로 이유가 붙는다 (팝오버에도 같은 detail 이 한 줄로 보인다).

| 메뉴바 / detail | 뜻 | 확인 순서 |
|---|---|---|
| ⚪ `주소 또는 토큰이 맞지 않습니다` | HTTP 404 — funnel 은 살아 있는데 그 경로가 없다 | 토큰 교체 후 옛 URL 을 쓰는 중? [URL 다시 보기](#url-다시-보기) 결과와 비교. `tailscale funnel status` 에 `/<토큰>` 경로가 있는지 |
| ⚪ `서버 응답 오류 (HTTP NNN)` | 404 외 응답. 3xx 도 여기 (앱은 리다이렉트를 따르지 않는다) | 외부망에서 URL 을 직접 열어 응답 확인. 5xx 면 tailscaled 가 `status.json` 을 못 읽는지 ([6](#6-첫-설치-때-확인할-것-실기-미검증-가정) 가정 9) |
| ⚪ `응답 시간 초과` | 10초 안에 응답 없음 | 서버 맥이 잠들었거나 네트워크 문제. 서버 맥 상태·`tailscale status` |
| ⚪ `네트워크 연결 없음` | **맥북**이 오프라인 | 맥북 네트워크. 서버 문제 아님 |
| ⚪ `서버에 연결할 수 없습니다` | DNS·TLS·연결 거부 등 | 외부망 휴대폰으로 URL 확인 → 안 열리면 서버 쪽: tailscaled 실행·funnel status·관리 콘솔 funnel 권한 |
| ⚪ `상태 파일을 읽을 수 없습니다` | 응답이 JSON 객체가 아니거나 64KB 초과 | URL 을 직접 열어 내용 확인 |
| ⚪ `상태 파일에 확인 시각이 없습니다` | JSON 에 해석 가능한 `checkedAt` 없음 | `cat ~/Library/Application\ Support/mongshell-openclaw-agent/status.json` |
| ⚪ `서버 에이전트가 갱신을 멈췄습니다` | 응답은 오는데 `checkedAt` 이 오래됨 — 에이전트가 멈춤 | `launchctl print …` 로 실행 여부, 로그의 `상태 파일 쓰기 실패` 여부. 서버 맥 로그아웃·잠자기도 원인 |
| ⚪ `확인 중…` | URL 적용 후 아직 첫 응답 전 | 확인 간격만큼 기다린다 |
| 🔴 `게이트웨이 다운` (detail 없음) | 서버가 down 보고 — probe 시간 초과·연결 거부·출력 해석 불가 | 서버 맥에서 `openclaw channels status --probe` |
| 🔴 `게이트웨이 다운 — openclaw 바이너리 없음` | 에이전트가 `/opt/homebrew/bin`·`/usr/local/bin` 어디에서도 openclaw 를 찾지 못함 | `ls -l /opt/homebrew/bin/openclaw /usr/local/bin/openclaw`. 재설치·경로 이동 후엔 다음 probe 에서 풀린다 |
| 🟡 `채널 이상 — …` | 채널 일부 멈춤/오류 | 자동복구가 켜져 있으면 2회 연속 실패 뒤 재시작을 시도한다 (쿨다운 600초) |
| 메뉴바에 신호등이 없음 | `Claude만` 선택 또는 URL 미적용 | [3](#3-각-맥북-설정) 의 메뉴바 표시 |

### 5-3. 서버 맥 진단 명령

```bash
tailscale funnel status                                             # 현재 공개 중인 경로
tailscale serve status --json                                       # serve 설정 원문
tail -f ~/Library/Logs/mongshell-openclaw-agent.log                 # 에이전트 로그
launchctl print gui/$(id -u)/com.mongshell.openclaw-agent           # 실행 상태 (state, last exit code)
cat ~/Library/Application\ Support/mongshell-openclaw-agent/status.json
```

로그 줄 형식 (에이전트가 쓰는 문구). 각 줄은 UTC ISO 시각으로 시작한다:
```
2026-09-29T03:12:45Z 시작 — status-file=… interval=60s autoHeal=true      ← 에이전트 기동
2026-09-29T03:12:45Z 경고: --gateway-label 이 자기 레이블(…)이라 무시하고 자동 탐색합니다
2026-09-29T03:12:47Z 상태: ok (Telegram default)                          ← 판정이 바뀔 때만
2026-09-29T04:01:10Z 복구 시도 — ai.openclaw.gateway kickstart 성공 (원인: down)   ← 자동복구 (성공|실패)
2026-09-29T04:05:00Z 상태 파일 쓰기 실패 — …                              ← 디스크·권한 문제
```
- 인자 오류는 시각 없이 `오류: …` 와 사용법을 출력하고 즉시 종료한다(exit 64). LaunchAgent 가 KeepAlive 로 계속 재기동한다.

## 6. 첫 설치 때 확인할 것 (실기 미검증 가정)

스크립트가 기대는 가정과, 그와 맞물린 확인 사항이다. **실기** 열은 2026-09-29 첫 설치(macOS 27, tailscale 1.102.4) 때의 결과다 — 상태 URL 은 외부망 기기에서도 열어 확인했고, 그 밖은 서버 맥 자신에서 확인했다. Tailscale 버전이 다르면 다시 확인하고, 틀린 것이 있으면 아래 정보 수집 결과와 함께 보고한다.

| # | 가정 (출처) | 실기 | 확인 방법 | 틀렸을 때 증상 |
|---|---|---|---|---|
| 1 | serve 설정이 비었을 때 `tailscale serve status --json` 은 빈 출력, JSON, 또는 `No serve config` 로 시작하는 문구다 (`lib.sh`) | 확인 — `{}` 가 나왔다 | **설치 전**에 `tailscale serve status --json; echo "exit $?"` | `'tailscale serve status --json' 출력이 JSON 이 아닙니다` 로 설치 중단 |
| 1a | brew 판 tailscaled 에 operator 를 준 일반 사용자가 `tailscale status`·`serve status` 를 sudo 없이 쓸 수 있다 (이 문서 [B](#b-tailscale-오픈소스판-brew-formula) 단계) | 확인. 단 **파일을 서빙하는 funnel 설정은 operator 로도 거부**돼 `install.sh` 가 그 명령을 sudo 로 실행한다 | B 이후 `tailscale status` 와 `tailscale serve status` 가 sudo 없이 되는지 | `access denied`·권한 오류 |
| 2 | serve JSON 구조가 `Web["<DNS 이름>:8443"].Handlers`, `TCP["8443"]`, `Foreground` 다 (`lib.sh` 의 해석) | `Web[…].Handlers` 는 확인 — 아래 명령이 `/<토큰>` 을 출력했다. `TCP[…].TCPForward`·`Foreground` 분기는 그런 설정이 없어 미확인 | **설치 후** repo 루트에서 아래 명령이 `/<토큰>` 한 줄을 출력하는지 | 빈 출력이면 스크립트가 경로를 못 본다 → 포트 점검이 무의미해지고, `--rotate-token`·uninstall 이 옛 경로를 "없음" 으로 보고 **해제 없이** 진행할 수 있다. 가장 중요한 확인 |
| 3 | funnel 대상에 파일 경로를 주면 그 파일 하나를 `--set-path` 경로에 서빙한다 (`install.sh` §8) | 확인 (외부망 기기에서도) | 외부망에서 상태 URL 이 JSON 을 돌려주는지 ([F](#f-동작-확인)) | 404·빈 응답·디렉터리 목록 |
| 4 | `--bg` 는 설정을 tailscaled 에 영구 저장한다 (`install.sh` §8) | 미확인 | `sudo brew services restart tailscale` 후 `tailscale funnel status` 와 외부망 URL 재확인 | 데몬 재시작·재부팅 뒤 ⚪ `주소 또는 토큰이 맞지 않습니다` 또는 연결 불가 |
| 5 | `--yes` 는 버전에 따라 없을 수 있어 help 에 있을 때만 붙인다 (`install.sh` §8) | 미확인 | `tailscale funnel --help 2>&1 \| grep -E -- '--?yes'` | 없으면 `▶ tailscale funnel 설정` 에서 확인 프롬프트·브라우저 안내가 뜨고 멈춘 것처럼 보일 수 있다 — 화면 안내를 따른다 |
| 6 | `funnel --https=8443 --set-path=/<토큰> off` 가 그 경로 하나만 해제하고, operator 를 준 사용자가 sudo 없이 실행할 수 있다 (`install.sh`·`uninstall.sh`) | 미확인 | `--rotate-token` 한 번 실행 → `tailscale funnel status` 에 새 경로만 있고, 외부망에서 옛 URL 이 404 | `옛 공개 경로 해제 실패` (권한 거부면 메시지의 명령 앞에 `sudo` 를 붙여 끈 뒤 재실행), `해제 명령은 성공했지만 옛 공개 경로가 남아 있습니다` (스크립트가 잡음), 또는 다른 경로까지 사라짐 |
| 7 | 토큰 경로만 걸려 있으면 루트 `/` 는 404 다 (`install.sh` §9) | 확인 (서버 맥 자신에서만) | 외부망에서 `https://<DNS 이름>:8443/` | 설치 끝에서 `토큰 없는 … 가 NNN 를 돌려줍니다` 로 중단 |
| 8 | (추정) 설치 스크립트의 URL 자가 확인은 서버 맥 자신에서 하므로 MagicDNS 가 tailnet 주소로 풀려 **Funnel(인터넷 경로)을 거치지 않았을 수 있다** | 자가 확인이 어느 경로를 탔는지는 미확인. 외부망 기기에서는 상태 URL 이 열렸다 | 반드시 외부망 기기로 [F](#f-동작-확인) | `→ 응답 확인` 이 나와도 외부에서는 안 열림 |
| 9 | root 인 tailscaled 가 `~/Library/Application Support` 아래 파일을 권한 프롬프트 없이 읽는다 (`install.sh` DATA_DIR 주석) | 확인 (외부망 기기에서도) | 외부망 URL 이 JSON 을 돌려주는지 | `status.json` 은 갱신되는데 URL 이 오류(5xx·404)를 돌려줌 |

가정 2 확인 명령 (서버 맥, repo 루트):
```bash
bash -c 'source server/lib.sh; DNS="$(tailscale status --json | plutil -extract Self.DNSName raw -o - - | sed "s/\.$//")"; serve_handlers tailscale "$DNS:$FUNNEL_PORT"'
```

### 막혔을 때 보고용 정보 수집

아래를 서버 맥 터미널에 통째로 붙여넣으면 `~/openclaw-diag.txt` 에 모인다. 32자리 hex(토큰)는 `<TOKEN>` 으로 가려진다. 보내기 전에 파일을 한 번 훑어 토큰·개인 정보가 남지 않았는지 확인한다 (tailnet 기기 이름·DNS 이름은 남는다).
```bash
{
  echo "== 환경"; sw_vers; uname -m; swift --version 2>&1 | head -1
  echo "== tailscale"; command -v tailscale; tailscale version
  pgrep -lx tailscaled || echo "tailscaled 없음"
  tailscale status --json | plutil -extract BackendState raw -o - -; echo
  DNS="$(tailscale status --json | plutil -extract Self.DNSName raw -o - - | sed 's/\.$//')"; echo "$DNS"
  echo "== serve/funnel"; tailscale serve status --json; echo "exit $?"; tailscale funnel status
  echo "== openclaw"; ls -l /opt/homebrew/bin/openclaw /usr/local/bin/openclaw
  ls ~/Library/LaunchAgents | grep -i claw
  echo "== 에이전트"; ls -la ~/Library/Application\ Support/mongshell-openclaw-agent
  cat ~/Library/Application\ Support/mongshell-openclaw-agent/status.json
  launchctl print gui/$(id -u)/com.mongshell.openclaw-agent | head -40
  tail -n 50 ~/Library/Logs/mongshell-openclaw-agent.log
  echo "== 이 맥에서 본 응답 코드 (루트 / 토큰 경로)"
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 20 "https://$DNS:8443/"
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 20 "https://$DNS:8443/$(tr -d '[:space:]' < ~/Library/Application\ Support/mongshell-openclaw-agent/token)"
} 2>&1 | sed -E 's/[0-9a-f]{32}/<TOKEN>/g' > ~/openclaw-diag.txt; echo "저장: ~/openclaw-diag.txt"
```

`install.sh` 출력 전문도 함께 남긴다. [E](#e-serverinstallsh-실행) 단계를 처음부터 아래 `tee` 형태로 실행했다면 그 로그를 쓰면 된다 — 로그만 얻으려고 다시 실행하면 LaunchAgent 가 한 번 더 교체된다(안전하지만 부작용이 있다). 마지막 `설치 완료.` 블록에 URL(토큰)이 들어가므로 가린 뒤 원본은 지운다:
```bash
server/install.sh 2>&1 | tee ~/openclaw-install.log      # E 단계에서 이미 했다면 생략
sed -E 's/[0-9a-f]{32}/<TOKEN>/g' ~/openclaw-install.log > ~/openclaw-install.masked.log
rm ~/openclaw-install.log
```
공유는 `*.masked.log` 와 `openclaw-diag.txt` 만 한다.

## 7. 알려진 한계

- **status.json 심링크 바꿔치기.** funnel 은 root 인 tailscaled 가 경로의 파일을 서빙한다. 이 사용자 권한을 이미 가진 공격자가 `status.json`(또는 데이터 폴더)을 다른 파일로 가는 심링크로 바꾸면, 에이전트의 다음 쓰기(원자적 교체라 링크를 덮어쓴다)까지 그 대상 파일이 공개 URL 로 나갈 수 있다. 사용자 권한 탈취가 전제라 별도 방어는 두지 않는다.
- **파일 모드 설정 전 짧은 틈.** 상태 파일은 임시 파일 교체 뒤 0644 로 모드를 고정하는데, 그 사이 잠깐은 umask 를 따른다. umask 가 느슨하면 그 틈에 다른 로컬 사용자가 쓸 수 있다. 서버 맥은 1인 사용을 전제로 한다.
