# 서버 에이전트 (mongshell-openclaw-agent)

openclaw 게이트웨이가 24시간 도는 **서버 맥**에 설치하는 감시 에이전트. 주기적으로 게이트웨이를 probe 하고, 필요하면 launchd 로 재시작(자동복구)한 뒤, 판정 결과를 JSON 파일로 남긴다. 그 파일은 `tailscale funnel` 이 공개 HTTPS 주소 `https://<서버 DNS 이름>/<토큰>` 으로 서빙하고, 다른 네트워크에 있는 맥북들의 메뉴바 앱이 그 주소를 읽는다.

- 에이전트는 네트워크 리스너를 갖지 않는다 — 서빙은 tailscaled 가 한다.
- Tailscale 은 **서버 맥에만** 설치한다. 메뉴바 앱 쪽 맥북에는 필요 없다.
- URL 의 토큰이 유일한 접근 통제다. 응답에는 상태 판정만 담기고 PID·원시 출력은 없다.

## 1회 수동 설정

### 1. 오픈소스판 Tailscale 설치

App Store/Standalone 판 앱이 아니라 **brew formula** 를 쓴다 (`install.sh` 가 `tailscaled` 데몬을 전제로 한다).

```bash
brew install tailscale
sudo brew services start tailscale   # tailscaled 를 root 데몬으로 상시 실행
tailscale up                          # 브라우저로 로그인
```

App Store 판 Tailscale 앱이 설치돼 있다면 먼저 종료·제거한다.

일반 사용자로 `tailscale funnel` 을 쓰려면 한 번 operator 권한을 준다.

```bash
sudo tailscale set --operator=$USER
```

### 2. 관리 콘솔 설정 (https://login.tailscale.com/admin)

1. **DNS** 탭 → MagicDNS 켜기
2. **DNS** 탭 → HTTPS Certificates 켜기
3. **Access controls** (정책 파일) 에 funnel 권한 추가:

```jsonc
"nodeAttrs": [
  {
    "target": ["autogroup:member"],   // 또는 서버 기기만 지정
    "attr":   ["funnel"]
  }
]
```

### 3. 서버 맥 상시 가동

에이전트는 사용자 LaunchAgent 라 **해당 사용자가 로그인해 있어야** 돈다.

- 시스템 설정 → 잠금 화면/에너지: 잠자기 방지 (디스플레이는 꺼져도 됨)
- 시스템 설정 → 사용자 및 그룹: 재부팅 후 **자동 로그인** 켜기
- 정전 복구 후 자동 시작: `sudo pmset -a autorestart 1`

## 설치

repo 를 서버 맥에 클론한 뒤:

```bash
server/install.sh                     # 기본: 60초 주기, 자동복구 켬
server/install.sh --interval 30       # 주기 변경 (최소 15초)
server/install.sh --no-auto-heal      # 자동복구 끄기 (상태 보고만)
server/install.sh --rotate-token      # URL 토큰 재발급 — 옛 URL 은 즉시 무효
```

마지막에 출력되는 `https://…/<토큰>` URL 을 메뉴바 앱 설정에 붙여넣는다. 재실행은 안전하다 — 토큰은 재사용되고 LaunchAgent 만 교체된다 (코드 업데이트 후 `git pull && server/install.sh`).

설치되는 것:

| 경로 | 내용 |
|---|---|
| `~/Library/Application Support/mongshell-openclaw-agent/` | 바이너리, `status.json`, `token`(0600) |
| `~/Library/LaunchAgents/com.mongshell.openclaw-agent.plist` | LaunchAgent (RunAtLoad·KeepAlive) |
| `~/Library/Logs/mongshell-openclaw-agent.log` | 상태 변화·복구 시에만 한 줄씩 기록 |

게이트웨이 launchd 레이블은 설치 시점에 `~/Library/LaunchAgents` 에서 이름에 `claw` 가 들어간 plist 를 찾아 고정한다 (에이전트 자신은 제외). 게이트웨이를 재설치해 레이블이 바뀌면 `install.sh` 를 다시 돌린다.

## 제거

```bash
server/uninstall.sh          # 확인 프롬프트
server/uninstall.sh --yes    # 묻지 않음
```

LaunchAgent·funnel 경로·데이터 폴더를 지운다. Tailscale 자체와 로그 파일은 남긴다.

## 동작 확인

1. **외부망**(와이파이 끈 휴대폰 등)에서 URL 을 연다 → JSON 이 보여야 한다.
   ```json
   { "schema": 1, "checkedAt": "2026-09-29T03:12:45Z", "health": "ok",
     "detail": "Telegram default", "intervalSeconds": 60, "autoHeal": true,
     "lastHeal": null }
   ```
2. 1분쯤 뒤 새로고침 → `checkedAt` 이 갱신돼야 한다.
3. 토큰 없이 `https://<서버 DNS 이름>/` 를 열면 **404** 여야 한다 (토큰 경로만 공개).

## 문제 해결

- `tailscale funnel status` — 현재 공개 중인 경로 확인
- `tail -f ~/Library/Logs/mongshell-openclaw-agent.log` — 에이전트 로그
- `launchctl print gui/$(id -u)/com.mongshell.openclaw-agent` — 에이전트 실행 상태
- funnel 설정이 권한 오류로 실패하면 위 `sudo tailscale set --operator=$USER` 를 확인한다.
