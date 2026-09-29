# shellcheck shell=bash
# install.sh / uninstall.sh 공용: 공개 포트와 tailscale serve 설정 조회.
# source 해서 쓴다. 호출 스크립트가 die() 를 정의해 둬야 한다.

# 공개 전용 포트. funnel 은 포트 단위로 인터넷에 여므로, 443 에 tailnet 전용으로 둔
# 다른 serve 핸들러(대시보드 등)가 있으면 우리 경로와 함께 노출된다. 그래서 우리
# 경로만 이 포트에 따로 둔다 (funnel 허용 포트: 443·8443·10000).
FUNNEL_PORT=8443

# $1=tailscale CLI, $2="<DNS 이름>:<포트>"
# 그 포트에 걸린 serve/funnel 핸들러를 한 줄에 하나씩 출력한다 — 웹 경로는 "/…",
# TCP 포워딩은 "tcp:…". 설정을 읽거나 해석하지 못하면 비0 으로 끝난다
# (호출자는 fail-closed 로 다룬다).
serve_handlers() {
  local json
  json="$("$1" serve status --json 2>/dev/null)" || return 1
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
