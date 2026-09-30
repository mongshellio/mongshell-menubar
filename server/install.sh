#!/usr/bin/env bash
# 서버 맥에 mongshell-openclaw-agent 를 설치하고 tailscale funnel 로 상태 파일을
# 공개 HTTPS 주소에 올린다. 재실행해도 안전하다 (토큰·옵션 재사용, LaunchAgent 교체).
#
# 사용법: server/install.sh [--interval N] [--auto-heal|--no-auto-heal] [--rotate-token]
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
# 설치 옵션(주기·자동복구). 재실행 때 명시하지 않은 옵션은 여기서 이어받는다 —
# README 의 업데이트 절차(git pull && install.sh)가 옵션을 되돌리지 않도록.
OPTIONS_FILE="$DATA_DIR/options"
PLIST="$HOME/Library/LaunchAgents/$SELF_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/$PRODUCT.log"
DOMAIN="gui/$(id -u)"
# 에이전트 첫 쓰기는 probe(최대 8s) 뒤에 온다. 여유 있게.
STATUS_WAIT_SECONDS=40
CURL_ATTEMPTS=6

# 이 스크립트가 발급하는 형식(openssl rand -hex 16).
TOKEN_PATTERN='^[0-9a-f]{32}$'

# 명령줄에서 준 값. 비어 있으면 저장값 → 기본값 순으로 정한다 (resolve_options).
ARG_INTERVAL=""
ARG_AUTO_HEAL=""
ROTATE_TOKEN=0

die()  { printf '\n오류: %s\n' "$*" >&2; exit 1; }
warn() { printf '경고: %s\n' "$*" >&2; }
step() { printf '▶ %s\n' "$*"; }

usage() {
  cat <<EOF
사용법: $0 [옵션]
  --interval N      probe 주기(초, 기본 $DEFAULT_INTERVAL, $MIN_INTERVAL~$MAX_INTERVAL)
  --auto-heal       게이트웨이 자동복구 켜기 (기본)
  --no-auto-heal    게이트웨이 자동복구 끄기
  --rotate-token    공개 URL 토큰을 새로 발급 (옛 URL 은 즉시 무효)
  -h, --help        이 도움말
주기·자동복구는 저장돼, 다음 실행에서 생략하면 지난 값을 그대로 쓴다.
EOF
}

# $1=옵션 파일, $2=주기, $3=자동복구(0/1). 임시 파일에 쓴 뒤 옮겨, 중간에 끊겨도
# 반쯤 쓰인 파일이 남지 않게 한다.
save_options() {
  local tmp="$1.tmp.$$"
  if printf 'interval=%s\nauto_heal=%s\n' "$2" "$3" >"$tmp" && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      [[ $# -ge 2 && "$2" =~ ^[0-9]{1,6}$ ]] || die "--interval 에는 6자리 이하 정수(초)가 필요합니다"
      valid_interval "$2" || die "--interval 은 $MIN_INTERVAL~$MAX_INTERVAL 초여야 합니다: $2"
      ARG_INTERVAL="$((10#$2))"; shift 2 ;;
    --auto-heal) ARG_AUTO_HEAL=1; shift ;;
    --no-auto-heal) ARG_AUTO_HEAL=0; shift ;;
    --rotate-token) ROTATE_TOKEN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

# 명령줄 > 저장값 > 기본값. 여기서는 읽기만 하고, 저장은 새 에이전트가 이 값으로
# 뜬 뒤에 한다 — 도중에 중단되면 돌던 에이전트와 저장값이 어긋나지 않게.
load_saved_options "$OPTIONS_FILE"
resolve_options

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

# ── 2. 토큰 ────────────────────────────────────────────────────────────────
# 토큰·공개 포트 점검은 에이전트를 내리기 전에 한다 — 여기서 중단돼도 돌던
# 에이전트는 그대로 감시를 계속한다.
step "URL 토큰 준비"
mkdir -p "$DATA_DIR"
OLD_TOKEN=""
if [[ -s "$TOKEN_FILE" ]]; then OLD_TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"; fi
if [[ -n "$OLD_TOKEN" && ! "$OLD_TOKEN" =~ $TOKEN_PATTERN ]]; then
  # 깨진 값으로는 내릴 경로를 믿고 만들 수 없으니 해제는 시도하지 않는다. 그 값으로
  # 걸린 옛 경로가 남아 있다면 다음 단계(공개 포트 점검)가 남의 핸들러로 보고 중단한다.
  warn "토큰 파일 형식이 올바르지 않아 새로 발급합니다: $TOKEN_FILE"
  OLD_TOKEN=""
fi
if [[ -n "$OLD_TOKEN" && $ROTATE_TOKEN -eq 0 ]]; then
  TOKEN="$OLD_TOKEN"
  echo "  기존 토큰 재사용"
else
  if [[ -n "$OLD_TOKEN" ]]; then
    # 옛 경로를 먼저 내려야 옛 URL 이 계속 살아 있지 않다. 내리지 못했거나 내린 뒤에도
    # 남아 있으면 새 토큰을 만들지 않고 중단한다 (unpublish_path, fail-closed).
    # 가정: '<같은 --https/--set-path> off' 가 그 경로 하나만 해제한다 (실기 미확인).
    unpublish_path "$TAILSCALE" "$HOST_PORT" "/$OLD_TOKEN"
    echo "  옛 공개 경로 해제 확인"
  fi
  TOKEN="$(openssl rand -hex 16)"
  (umask 077 && printf '%s\n' "$TOKEN" > "$TOKEN_FILE")
  chmod 0600 "$TOKEN_FILE"
  echo "  새 토큰 발급"
fi

# ── 3. 공개 포트 점검 ──────────────────────────────────────────────────────
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

# ── 4. 빌드·배치 ───────────────────────────────────────────────────────────
step "에이전트 빌드 (release)"
swift build -c release --product "$PRODUCT" --package-path "$ROOT"
BUILT="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$PRODUCT"
[[ -x "$BUILT" ]] || die "빌드 산출물을 찾지 못했습니다: $BUILT"

mkdir -p "$DATA_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
# 실행 중인 바이너리를 덮어쓰지 않도록 먼저 에이전트를 내린다.
launchctl bootout "$DOMAIN/$SELF_LABEL" 2>/dev/null || true
# 옛 에이전트의 마지막 쓰기와 같은 초에 걸리지 않도록 1초 넘긴 뒤 기준 시각을 잡는다
# (mtime 은 초 단위). 이후의 status.json 쓰기는 새 에이전트의 것이다.
sleep 1
INSTALL_STARTED="$(date +%s)"
install -m 0755 "$BUILT" "$BIN"
echo "  → $BIN"

# ── 5. 게이트웨이 레이블 ────────────────────────────────────────────────────
# 에이전트의 폴백 탐색과 같은 규칙(정렬 후 이름에 claw 포함, 자기 레이블 제외)을
# 설치 시점에 한 번 돌려 --gateway-label 로 고정한다.
step "게이트웨이 launchd 레이블 탐색"
GATEWAY_LABEL=""
while IFS= read -r f; do
  label="$(basename "$f" .plist)"
  # claw 포함 여부만 대소문자 무시, 자기 레이블 제외는 정확히 일치 — 에이전트의
  # lowercased().contains("claw") / != selfLabel 과 같다. (bash 3.2 라 ${,,} 없음)
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$label")"
  if [[ "$label" != "$SELF_LABEL" && "$lower" == *claw* ]]; then
    GATEWAY_LABEL="$label"
    break
  fi
done < <(find "$HOME/Library/LaunchAgents" -maxdepth 1 -name '*.plist' 2>/dev/null | LC_ALL=C sort)
if [[ -z "$GATEWAY_LABEL" ]]; then
  warn "게이트웨이 plist 를 찾지 못해 기본값 $DEFAULT_GATEWAY_LABEL 을 씁니다."
  GATEWAY_LABEL="$DEFAULT_GATEWAY_LABEL"
fi
echo "  → $GATEWAY_LABEL"

# ── 6. LaunchAgent ─────────────────────────────────────────────────────────
step "LaunchAgent 등록"
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

EXTRA_ARGS="    <string>--interval</string>
    <string>$INTERVAL</string>
"
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

# bootout 직후 bootstrap 은 서비스가 완전히 내려가기 전이면 실패(EIO)하므로 재시도.
bootstrapped=0
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then bootstrapped=1; break; fi
  sleep 1
done
[[ $bootstrapped -eq 1 ]] || die "launchctl bootstrap 실패. 'launchctl bootstrap $DOMAIN \"$PLIST\"' 를 직접 실행해 원인을 확인하세요."
save_options "$OPTIONS_FILE" "$INTERVAL" "$AUTO_HEAL" \
  || warn "설치 옵션을 저장하지 못했습니다 — 다음 재실행은 옵션을 다시 줘야 합니다: $OPTIONS_FILE"

# ── 7. 첫 상태 파일 대기 ───────────────────────────────────────────────────
step "첫 상태 파일 대기 (최대 ${STATUS_WAIT_SECONDS}s)"
waited=0
# 재설치면 이전 실행의 status.json 이 남아 있다. 지우면 그 안의 lastHeal(복구
# 쿨다운)까지 사라져 재설치 직후 곧바로 재시작이 다시 걸릴 수 있으므로 두고,
# 설치 시작 이후에 다시 쓰였는지를 mtime 으로 본다.
status_written_since_install() {
  [[ -s "$STATUS_FILE" ]] && (( $(stat -f %m "$STATUS_FILE") >= INSTALL_STARTED ))
}
until status_written_since_install; do
  if (( waited >= STATUS_WAIT_SECONDS )); then
    die "상태 파일이 생기지 않았습니다. 로그 확인: $LOG_FILE"
  fi
  sleep 1; waited=$((waited + 1))
done
echo "  → $STATUS_FILE"

# ── 8. funnel ──────────────────────────────────────────────────────────────
# 파일 경로를 대상으로 주면 funnel 이 그 파일 하나를 --set-path 경로에 서빙한다
# (실기 확인, tailscale 1.102.4). 가정(실기 미확인): --bg 는 설정을 tailscaled 에
# 영구 저장한다. --yes(확인 프롬프트 생략)는 버전에 따라 없을 수 있어 help 로
# 지원 여부를 보고 붙인다.
step "tailscale funnel 설정"
# 새로 발급한 토큰은 여기까지 형식 검사를 거치지 않았다. 비어 있으면 --set-path=/ 가
# 되어 상태 파일이 루트에 걸리므로, root 로 넘기기 전에 확인한다.
[[ "$TOKEN" =~ $TOKEN_PATTERN ]] || die "토큰 형식이 올바르지 않습니다 (32자리 hex 가 아님). '$TOKEN_FILE' 을 지우고 다시 실행하세요."
FUNNEL_ARGS=(funnel --bg --https="$FUNNEL_PORT" --set-path="/$TOKEN")
# help 를 먼저 변수로 받는다. 'cmd | grep -q' 는 grep 이 일치 즉시 끝나 cmd 가
# SIGPIPE 로 죽을 수 있고, pipefail 아래에선 그게 "없음" 으로 읽힌다. help 가
# 비0 으로 끝나는 버전도 있어 종료 코드는 보지 않는다.
FUNNEL_HELP="$("$TAILSCALE" funnel --help 2>&1 || true)"
if grep -qE -- '(^|[[:space:],])--?yes([[:space:],=]|$)' <<<"$FUNNEL_HELP"; then
  FUNNEL_ARGS+=(--yes)
fi
FUNNEL_ARGS+=("$STATUS_FILE")
# 실기(brew 판 tailscale 1.102.4)에서 operator 를 준 사용자의 파일 서빙 설정이
# 거부됐다: "must be root, or be an operator and able to run 'sudo tailscale' to
# serve a path or Unix socket". 문구상 sudo 가능한 operator 는 허용이지만 그
# 환경에서는 통하지 않았다 (원인 미확인). 그래서 이 명령은 root 로 실행한다.
echo "  파일을 서빙하는 funnel 설정은 관리자 권한이 필요해 sudo 로 실행합니다 (비밀번호를 물을 수 있습니다)."
# 인증 실패와 tailscale 실패를 다른 메시지로 알리려고 인증을 먼저 따로 받는다.
# sudo 는 절대 경로로 부른다 — PATH 앞쪽(/opt/homebrew/bin 등)은 사용자 쓰기 가능이다.
/usr/bin/sudo -v || die "sudo 인증 실패. 비밀번호를 입력할 수 있는 터미널에서 직접 실행했는지, 이 계정이 관리자인지 확인하세요.
에이전트는 이미 설치돼 돌고 있으니 다시 실행하면 됩니다."
if ! /usr/bin/sudo "$TAILSCALE" "${FUNNEL_ARGS[@]}"; then
  die "tailscale funnel 설정 실패 (위 tailscale 출력 참조). 관리 콘솔의 HTTPS 인증서·funnel nodeAttr 를 확인하세요 (README).
에이전트는 이미 설치돼 돌고 있으니 고친 뒤 다시 실행하면 됩니다."
fi

# ── 9. 확인 ────────────────────────────────────────────────────────────────
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
    # 무엇이 새는지 모르니 우리 경로까지 포함해 이 포트의 인터넷 공개를 통째로 내린다.
    # 공개는 root 로 열었는데 off 가 sudo 없이 되는지는 실기 미확인이라, 실패하면
    # root 로 한 번 더 시도한다 — 여는 쪽만 되고 닫는 쪽이 막히는 일이 없게.
    if "$TAILSCALE" funnel --https="$FUNNEL_PORT" off \
      || /usr/bin/sudo "$TAILSCALE" funnel --https="$FUNNEL_PORT" off; then
      PORT_OFF="포트 $FUNNEL_PORT 의 funnel 공개는 내렸습니다 (우리 경로 포함)."
    else
      PORT_OFF="포트 $FUNNEL_PORT 의 funnel 공개를 내리는 데도 실패했습니다 — 지금도 공개돼 있을 수 있으니 'tailscale funnel --https=$FUNNEL_PORT off' 로 직접 끄세요 (권한 거부면 앞에 sudo)."
    fi
    die "토큰 없는 $ROOT_URL 가 $ROOT_CODE 를 돌려줍니다 — 토큰 경로 말고 다른 것이 공개돼 있습니다.
$PORT_OFF
'tailscale funnel status' 로 확인하고 포트 $FUNNEL_PORT 의 다른 핸들러를 끈 뒤 다시 설치하세요." ;;
  ""|000)
    warn "이 맥에서 $ROOT_URL 에 닿지 못해 루트 비공개를 확인하지 못했습니다. 외부망 기기로 열어 404 인지 확인하세요." ;;
  *)
    warn "$ROOT_URL 가 예상한 404 가 아닌 $ROOT_CODE 를 돌려줍니다. 외부망 기기로 열어 확인하세요." ;;
esac

cat <<EOF

설치 완료.
  상태 URL : $URL
  로그     : $LOG_FILE
  옵션     : 주기 ${INTERVAL}초, 자동복구 $([[ $AUTO_HEAL -eq 1 ]] && echo 켬 || echo 끔) (대상 $GATEWAY_LABEL)

위 상태 URL 을 메뉴바 앱 설정의 서버 섹션에 붙여넣으세요.
EOF
