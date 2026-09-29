#!/usr/bin/env bash
# 서버 맥에 mongshell-openclaw-agent 를 설치하고 tailscale funnel 로 상태 파일을
# 공개 HTTPS 주소에 올린다. 재실행해도 안전하다 (토큰 재사용, LaunchAgent 교체).
#
# 사용법: server/install.sh [--interval N] [--no-auto-heal] [--rotate-token]
# 사전 준비(brew 판 Tailscale 설치·로그인·funnel 권한)는 server/README.md 참조.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/server/lib.sh"
PRODUCT="mongshell-openclaw-agent"
SELF_LABEL="com.mongshell.openclaw-agent"
DEFAULT_GATEWAY_LABEL="ai.openclaw.gateway"
# TCC 보호 폴더(Documents·Desktop 등)를 피해 Application Support 에 둔다 —
# launchd 로 뜬 에이전트와 root 인 tailscaled 가 권한 프롬프트 없이 접근할 수 있다.
DATA_DIR="$HOME/Library/Application Support/$PRODUCT"
BIN="$DATA_DIR/$PRODUCT"
STATUS_FILE="$DATA_DIR/status.json"
TOKEN_FILE="$DATA_DIR/token"
PLIST="$HOME/Library/LaunchAgents/$SELF_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/$PRODUCT.log"
DOMAIN="gui/$(id -u)"
# 에이전트 첫 쓰기는 probe(최대 8s) 뒤에 온다. 여유 있게.
STATUS_WAIT_SECONDS=40
CURL_ATTEMPTS=6

INTERVAL=""
# 에이전트(Options.minimumInterval/maximumInterval)와 같은 범위.
MIN_INTERVAL=15
MAX_INTERVAL=86400
AUTO_HEAL=1
ROTATE_TOKEN=0

die()  { printf '\n오류: %s\n' "$*" >&2; exit 1; }
warn() { printf '경고: %s\n' "$*" >&2; }
step() { printf '▶ %s\n' "$*"; }

usage() {
  cat <<EOF
사용법: $0 [옵션]
  --interval N      probe 주기(초, 기본 60, $MIN_INTERVAL~$MAX_INTERVAL)
  --no-auto-heal    게이트웨이 자동복구 끄기 (기본: 켬)
  --rotate-token    공개 URL 토큰을 새로 발급 (옛 URL 은 즉시 무효)
  -h, --help        이 도움말
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      # 자릿수 상한을 먼저 걸어 산술 비교에서 오버플로가 나지 않게 한다.
      [[ $# -ge 2 && "$2" =~ ^[0-9]{1,6}$ ]] || die "--interval 에는 6자리 이하 정수(초)가 필요합니다"
      # 10# — 앞자리 0 을 8진수로 읽지 않도록.
      (( 10#$2 >= MIN_INTERVAL && 10#$2 <= MAX_INTERVAL )) \
        || die "--interval 은 $MIN_INTERVAL~$MAX_INTERVAL 초여야 합니다: $2"
      INTERVAL="$((10#$2))"; shift 2 ;;
    --no-auto-heal) AUTO_HEAL=0; shift ;;
    --rotate-token) ROTATE_TOKEN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

# ── 1. 사전조건 ────────────────────────────────────────────────────────────
step "사전조건 확인"

if ! pgrep -x tailscaled >/dev/null; then
  if [[ -d /Applications/Tailscale.app ]]; then
    die "App Store/Standalone 판 Tailscale 앱만 발견됐습니다. 이 설치는 오픈소스판(brew)
데몬 tailscaled 를 전제로 합니다. 앱을 종료·제거한 뒤 README 대로
  brew install tailscale && sudo brew services start tailscale
을 실행하세요."
  fi
  die "tailscaled 데몬이 돌고 있지 않습니다. 'sudo brew services start tailscale' 로 시작하세요."
fi

TAILSCALE="$(command -v tailscale || true)"
[[ -n "$TAILSCALE" ]] || die "tailscale CLI 가 PATH 에 없습니다. 'brew install tailscale' 을 확인하세요."

TS_JSON="$("$TAILSCALE" status --json 2>/dev/null)" \
  || die "'tailscale status --json' 실패. 'tailscale up' 으로 로그인했는지 확인하세요."
BACKEND_STATE="$(plutil -extract BackendState raw -o - - <<<"$TS_JSON" 2>/dev/null || true)"
[[ "$BACKEND_STATE" == "Running" ]] \
  || die "Tailscale 상태가 Running 이 아닙니다 (현재: ${BACKEND_STATE:-알 수 없음}). 'tailscale up' 으로 로그인하세요."
DNS_NAME="$(plutil -extract Self.DNSName raw -o - - <<<"$TS_JSON" 2>/dev/null || true)"
DNS_NAME="${DNS_NAME%.}"
[[ -n "$DNS_NAME" ]] || die "이 기기의 MagicDNS 이름을 얻지 못했습니다. 관리 콘솔에서 MagicDNS 를 켜세요."
HOST_PORT="$DNS_NAME:$FUNNEL_PORT"

OPENCLAW=""
for c in /opt/homebrew/bin/openclaw /usr/local/bin/openclaw; do
  if [[ -x "$c" ]]; then OPENCLAW="$c"; break; fi
done
[[ -n "$OPENCLAW" ]] || die "openclaw 바이너리가 없습니다 (/opt/homebrew/bin, /usr/local/bin 확인)."

command -v swift >/dev/null || die "swift 가 없습니다. 'xcode-select --install' 로 Command Line Tools 를 설치하세요."
command -v openssl >/dev/null || die "openssl 이 없습니다."

echo "  tailscale: $TAILSCALE ($DNS_NAME)"
echo "  openclaw : $OPENCLAW"

# ── 2. 빌드·배치 ───────────────────────────────────────────────────────────
step "에이전트 빌드 (release)"
swift build -c release --product "$PRODUCT" --package-path "$ROOT"
BUILT="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$PRODUCT"
[[ -x "$BUILT" ]] || die "빌드 산출물을 찾지 못했습니다: $BUILT"

mkdir -p "$DATA_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
# 실행 중인 바이너리를 덮어쓰지 않도록 먼저 에이전트를 내린다.
launchctl bootout "$DOMAIN/$SELF_LABEL" 2>/dev/null || true
install -m 0755 "$BUILT" "$BIN"
echo "  → $BIN"

# ── 3. 게이트웨이 레이블 ────────────────────────────────────────────────────
# 에이전트의 폴백 탐색과 같은 규칙(정렬 후 이름에 claw 포함, 자기 레이블 제외)을
# 설치 시점에 한 번 돌려 --gateway-label 로 고정한다.
step "게이트웨이 launchd 레이블 탐색"
GATEWAY_LABEL=""
shopt -s nocasematch
while IFS= read -r f; do
  label="$(basename "$f" .plist)"
  if [[ "$label" != "$SELF_LABEL" && "$label" == *claw* ]]; then
    GATEWAY_LABEL="$label"
    break
  fi
done < <(find "$HOME/Library/LaunchAgents" -maxdepth 1 -name '*.plist' 2>/dev/null | LC_ALL=C sort)
shopt -u nocasematch
if [[ -z "$GATEWAY_LABEL" ]]; then
  warn "게이트웨이 plist 를 찾지 못해 기본값 $DEFAULT_GATEWAY_LABEL 을 씁니다."
  GATEWAY_LABEL="$DEFAULT_GATEWAY_LABEL"
fi
echo "  → $GATEWAY_LABEL"

# ── 4. 토큰 ────────────────────────────────────────────────────────────────
step "URL 토큰 준비"
OLD_TOKEN=""
if [[ -s "$TOKEN_FILE" ]]; then OLD_TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"; fi
if [[ -n "$OLD_TOKEN" && $ROTATE_TOKEN -eq 0 ]]; then
  TOKEN="$OLD_TOKEN"
  echo "  기존 토큰 재사용"
else
  if [[ -n "$OLD_TOKEN" ]]; then
    # 옛 경로를 먼저 내려야 옛 URL 이 계속 살아 있지 않다.
    # 가정: '<같은 --https/--set-path> off' 가 그 경로 하나만 해제한다 (실기 미확인).
    "$TAILSCALE" funnel --https="$FUNNEL_PORT" --set-path="/$OLD_TOKEN" off 2>/dev/null \
      || warn "옛 funnel 경로 해제 실패 — 'tailscale funnel status' 로 확인 후 수동으로 끄세요."
  fi
  TOKEN="$(openssl rand -hex 16)"
  (umask 077 && printf '%s\n' "$TOKEN" > "$TOKEN_FILE")
  chmod 0600 "$TOKEN_FILE"
  echo "  새 토큰 발급"
fi

# ── 4b. 공개 포트 점검 ─────────────────────────────────────────────────────
# funnel 은 포트 전체를 공개하므로, 이 포트에 우리 토큰 경로 말고 다른 핸들러가
# 있으면 그것까지 인터넷에 열린다. 확인할 수 없으면(설정 조회 실패) 진행하지 않는다.
step "공개 포트 $FUNNEL_PORT 점검"
HANDLERS="$(serve_handlers "$TAILSCALE" "$HOST_PORT")" \
  || die "'tailscale serve status --json' 을 읽지 못해 포트 $FUNNEL_PORT 가 비어 있는지 확인할 수 없습니다."
FOREIGN="$(grep -vxF -e '' -e "/$TOKEN" <<<"$HANDLERS" || true)"
if [[ -n "$FOREIGN" ]]; then
  die "포트 $FUNNEL_PORT 에 이 설치가 만들지 않은 serve 핸들러가 있습니다. funnel 을 켜면 함께 공개되므로 중단합니다:
$(sed 's/^/  /' <<<"$FOREIGN")
'tailscale serve status' 로 확인하고 정리한 뒤 다시 실행하세요."
fi

# ── 5. LaunchAgent ─────────────────────────────────────────────────────────
step "LaunchAgent 등록"
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

EXTRA_ARGS=""
if [[ -n "$INTERVAL" ]]; then
  EXTRA_ARGS+="    <string>--interval</string>
    <string>$INTERVAL</string>
"
fi
if [[ $AUTO_HEAL -eq 0 ]]; then
  EXTRA_ARGS+="    <string>--no-auto-heal</string>
"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SELF_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$BIN")</string>
    <string>--status-file</string>
    <string>$(xml_escape "$STATUS_FILE")</string>
    <string>--gateway-label</string>
    <string>$(xml_escape "$GATEWAY_LABEL")</string>
    <string>--self-label</string>
    <string>$SELF_LABEL</string>
$EXTRA_ARGS  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$LOG_FILE")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$LOG_FILE")</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null || die "생성한 plist 가 올바르지 않습니다: $PLIST"

# 이전 실행이 남긴 파일로 "대기 성공" 을 착각하지 않도록 지운다.
rm -f "$STATUS_FILE"
# bootout 직후 bootstrap 은 서비스가 완전히 내려가기 전이면 실패(EIO)하므로 재시도.
bootstrapped=0
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then bootstrapped=1; break; fi
  sleep 1
done
[[ $bootstrapped -eq 1 ]] || die "launchctl bootstrap 실패. 'launchctl bootstrap $DOMAIN \"$PLIST\"' 를 직접 실행해 원인을 확인하세요."

# ── 6. 첫 상태 파일 대기 ───────────────────────────────────────────────────
step "첫 상태 파일 대기 (최대 ${STATUS_WAIT_SECONDS}s)"
waited=0
until [[ -s "$STATUS_FILE" ]]; do
  if (( waited >= STATUS_WAIT_SECONDS )); then
    die "상태 파일이 생기지 않았습니다. 로그 확인: $LOG_FILE"
  fi
  sleep 1; waited=$((waited + 1))
done
echo "  → $STATUS_FILE"

# ── 7. funnel ──────────────────────────────────────────────────────────────
# 가정(개발 맥에 tailscale 이 없어 실기 확인 못 함): 파일 경로를 대상으로 주면
# funnel 이 그 파일 하나를 --set-path 경로에 서빙하고, --bg 는 설정을 tailscaled
# 에 영구 저장한다. --yes(확인 프롬프트 생략)는 버전에 따라 없을 수 있어 help 로
# 지원 여부를 보고 붙인다.
step "tailscale funnel 설정"
FUNNEL_ARGS=(funnel --bg --https="$FUNNEL_PORT" --set-path="/$TOKEN")
if "$TAILSCALE" funnel --help 2>&1 | grep -q -- '-yes'; then
  FUNNEL_ARGS+=(--yes)
fi
FUNNEL_ARGS+=("$STATUS_FILE")
if ! "$TAILSCALE" "${FUNNEL_ARGS[@]}"; then
  die "tailscale funnel 설정 실패. brew 판 tailscaled 는 root 로 돌아 일반 사용자 CLI 권한이 부족할 수 있습니다.
  sudo tailscale set --operator=\$USER
를 한 번 실행한 뒤 다시 설치하세요. 관리 콘솔의 HTTPS 인증서·funnel nodeAttr 도 확인하세요 (README)."
fi

# ── 8. 확인 ────────────────────────────────────────────────────────────────
URL="https://$HOST_PORT/$TOKEN"
step "공개 URL 확인"
ok=0
for _ in $(seq 1 "$CURL_ATTEMPTS"); do
  # 첫 요청은 인증서 발급으로 수 초 걸릴 수 있다.
  if curl -fsS --max-time 20 "$URL" >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [[ $ok -eq 1 ]]; then
  echo "  → 응답 확인"
else
  warn "이 맥에서 URL 응답을 확인하지 못했습니다 (전파 지연일 수 있음). 외부망 기기로 열어보세요."
fi

# 토큰 없는 루트는 404 여야 한다 — 그렇지 않으면 토큰 말고 다른 것이 공개된 것.
ROOT_URL="https://$HOST_PORT/"
ROOT_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$ROOT_URL" 2>/dev/null || true)"
case "$ROOT_CODE" in
  404) echo "  → 루트 404 확인 (토큰 경로만 공개)" ;;
  2*|3*)
    die "토큰 없는 $ROOT_URL 가 $ROOT_CODE 를 돌려줍니다 — 토큰 경로 말고 다른 것이 공개돼 있습니다.
'tailscale funnel status' 로 확인하고 포트 $FUNNEL_PORT 의 다른 핸들러를 끄세요." ;;
  ""|000)
    warn "이 맥에서 $ROOT_URL 에 닿지 못해 루트 비공개를 확인하지 못했습니다. 외부망 기기로 열어 404 인지 확인하세요." ;;
  *)
    warn "$ROOT_URL 가 예상한 404 가 아닌 $ROOT_CODE 를 돌려줍니다. 외부망 기기로 열어 확인하세요." ;;
esac

cat <<EOF

설치 완료.
  상태 URL : $URL
  로그     : $LOG_FILE
  자동복구 : $([[ $AUTO_HEAL -eq 1 ]] && echo 켬 || echo 끔) (대상 $GATEWAY_LABEL)

위 상태 URL 을 메뉴바 앱 설정에 붙여넣으세요.
EOF
