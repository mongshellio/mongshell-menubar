# shellcheck shell=bash
# install.sh / uninstall.sh 공용: 공개 포트와 tailscale serve 설정 조회·경로 해제.
# 그리고 install.sh 의 설치 옵션 결정 규칙 — scripts/test.sh 가 source 해 시험할 수
# 있도록 여기 둔다. source 해서 쓴다. 호출 스크립트가 die() / warn() 을 정의해 둬야 한다.

# 공개 전용 포트. funnel 은 포트 단위로 인터넷에 여므로, 443 에 tailnet 전용으로 둔
# 다른 serve 핸들러(대시보드 등)가 있으면 우리 경로와 함께 노출된다. 그래서 우리
# 경로만 이 포트에 따로 둔다 (funnel 허용 포트: 443·8443·10000).
FUNNEL_PORT=8443

# 설정이 비었을 때 'serve status --json' 이 JSON 대신 내놓을 수 있는 문구.
# 실기 미확인 가정: 빈 설정에서 빈 출력이나 "No serve config" 류 텍스트가 나올 수
# 있다고 보고 대비한다. 여기 없는 비-JSON 은 설정 존재를 숨길 수 있으니 실패로 둔다.
SERVE_EMPTY_PATTERN='^no serve config'
# 해석 실패 시 에러에 보여줄 원문 길이(바이트).
SERVE_EXCERPT_BYTES=200

# $1=tailscale CLI, $2="<DNS 이름>:<포트>"
# 그 포트에 걸린 serve/funnel 핸들러를 한 줄에 하나씩 출력한다 — 웹 경로는 "/…",
# TCP 포워딩은 "tcp:…". 설정을 읽거나 해석하지 못하면 비0 으로 끝난다
# (호출자는 fail-closed 로 다룬다).
serve_handlers() {
  local json trimmed
  json="$("$1" serve status --json 2>/dev/null)" || return 1
  trimmed="$(tr -d '[:space:]' <<<"$json")"
  [[ -n "$trimmed" ]] || return 0
  if [[ "${trimmed:0:1}" != "{" ]]; then
    if grep -qiE -- "$SERVE_EMPTY_PATTERN" <<<"$json"; then return 0; fi
    printf "'tailscale serve status --json' 출력이 JSON 이 아닙니다: %s\n" \
      "$(head -c "$SERVE_EXCERPT_BYTES" <<<"$json")" >&2
    return 1
  fi
  /usr/bin/osascript -l JavaScript - "$json" "$2" <<'JS'
function run(argv) {
  var cfg = argv[0] ? JSON.parse(argv[0]) : {};
  var hostPort = argv[1];
  var port = hostPort.slice(hostPort.lastIndexOf(":") + 1);
  var out = [];
  function scan(c) {
    if (!c) return;
    var tcp = (c.TCP || {})[port];
    if (tcp && tcp.TCPForward) out.push("tcp:" + tcp.TCPForward);
    var web = (c.Web || {})[hostPort];
    if (web && web.Handlers) Object.keys(web.Handlers).forEach(function (k) { out.push(k); });
  }
  scan(cfg);
  // --bg 없이 띄운 포그라운드 세션도 같은 포트를 점유한다.
  var fg = cfg.Foreground || {};
  Object.keys(fg).forEach(function (id) { scan(fg[id]); });
  return out.join("\n");
}
JS
}

# $1=tailscale CLI, $2="<DNS 이름>:<포트>", $3=경로("/<토큰>")
# 경로가 걸려 있으면 funnel 에서 내리고, 설정을 다시 읽어 실제로 사라졌는지 확인한다.
# 어느 단계든 실패하면 옛 URL 이 계속 공개돼 있을 수 있으므로 die 한다.
# 원래 없던 경로면 할 일이 없다.
unpublish_path() {
  local cli="$1" host_port="$2" path="$3" handlers
  local manual="tailscale funnel --https=${host_port##*:} --set-path=<경로> off"
  handlers="$(serve_handlers "$cli" "$host_port")" \
    || die "tailscale serve 설정을 읽지 못해 옛 공개 경로 해제 여부를 확인할 수 없습니다. 'tailscale serve status' 를 확인하세요."
  grep -qxF -- "$path" <<<"$handlers" || return 0
  "$cli" funnel --https="${host_port##*:}" --set-path="$path" off \
    || die "옛 공개 경로 해제 실패. 'tailscale funnel status' 로 확인하고 '$manual' 로 끈 뒤 다시 실행하세요."
  handlers="$(serve_handlers "$cli" "$host_port")" \
    || die "해제 후 tailscale serve 설정을 다시 읽지 못했습니다. 'tailscale funnel status' 로 옛 경로가 꺼졌는지 확인하세요."
  if grep -qxF -- "$path" <<<"$handlers"; then
    die "해제 명령은 성공했지만 옛 공개 경로가 남아 있습니다. '$manual' 로 끈 뒤 다시 실행하세요."
  fi
}

# ── 설치 옵션 (install.sh) ─────────────────────────────────────────────────
# 에이전트(Options.defaultInterval/minimumInterval/maximumInterval)와 같은 값.
DEFAULT_INTERVAL=60
MIN_INTERVAL=15
MAX_INTERVAL=86400
DEFAULT_AUTO_HEAL=1

# 명령줄과 저장 파일에 같은 규칙을 쓴다. 자릿수 상한을 먼저 걸어 산술 비교에서
# 오버플로가 나지 않게 하고, 10# 으로 앞자리 0 을 8진수로 읽지 않게 한다.
valid_interval() {
  [[ "$1" =~ ^[0-9]{1,6}$ ]] && (( 10#$1 >= MIN_INTERVAL && 10#$1 <= MAX_INTERVAL ))
}

# $1=옵션 파일. 저장값을 SAVED_INTERVAL / SAVED_AUTO_HEAL 에 담는다 (없으면 빈 값).
# key=value 줄을 파싱만 한다 — 파일 내용을 source 로 실행하지 않는다. 모르는 키는
# 무시하고, 형식이 깨진 값은 경고 후 버려 기본값이 쓰이게 한다.
load_saved_options() {
  SAVED_INTERVAL=""
  SAVED_AUTO_HEAL=""
  [[ -f "$1" ]] || return 0
  if [[ ! -r "$1" ]]; then
    warn "저장된 설치 옵션을 읽을 수 없어 기본값을 씁니다: $1"
    return 0
  fi
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      interval)
        if valid_interval "$value"; then SAVED_INTERVAL="$((10#$value))"
        else warn "저장된 주기가 올바르지 않아 무시합니다 ($1): interval=$value"; fi ;;
      auto_heal)
        if [[ "$value" == 0 || "$value" == 1 ]]; then SAVED_AUTO_HEAL="$value"
        else warn "저장된 자동복구 값이 올바르지 않아 무시합니다 ($1): auto_heal=$value"; fi ;;
    esac
  done <"$1"
}

# 명령줄(ARG_*) > 저장값(SAVED_*) > 기본값 으로 INTERVAL / AUTO_HEAL 을 정한다.
resolve_options() {
  INTERVAL="${ARG_INTERVAL:-${SAVED_INTERVAL:-$DEFAULT_INTERVAL}}"
  AUTO_HEAL="${ARG_AUTO_HEAL:-${SAVED_AUTO_HEAL:-$DEFAULT_AUTO_HEAL}}"
}
