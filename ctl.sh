#!/usr/bin/env bash
# Control helper for the myradio Omarchy plugin.
#
# Talks to the local myradio studio over its loopback API. The control token is
# read from the studio's data folder and only ever written to a connection whose
# far end is owned by this account: studio_connect opens the connection, checks
# its owner in /proc/net/tcp, and the request goes over that same connection.
# The token is written by a shell builtin, so it never appears in a process list.
#
#   ctl.sh status              one JSON line: reachability, listener state, slim station status
#   ctl.sh action <json>       POST /api/action with {"operation":..., "arguments":{...}}
#   ctl.sh listen <volume>     start the local listener (verified connection into mpv) if it is not running
#   ctl.sh unlisten            stop the local listener
#   ctl.sh volume <0-130>      set the listener volume
#   ctl.sh title <text>        set the listener's media title (shown by MPRIS clients)
#   ctl.sh open                open the studio in the browser and copy its launch code
#   ctl.sh launch              start the studio (`myradio`), which opens the browser itself

set -uo pipefail

PORT="${MYRADIO_PORT:-8765}"
case "$PORT" in ''|*[!0-9]*) PORT=8765 ;; esac
DATA="${MYRADIO_DATA_DIR:-$HOME/.myradio}"
BASE="http://127.0.0.1:$PORT"
RUN="${XDG_RUNTIME_DIR:-/tmp}/omarchy-myradio-$(id -u)"
SOCK="$RUN/mpv.sock"
PIDF="$RUN/listen.pid"
SELF="$(readlink -f "$0")"

token() {
  local tok
  tok="$( { tr -d '[:space:]' < "$DATA/control.token"; } 2>/dev/null)" || return 1
  [ -n "$tok" ] || return 1
  printf '%s' "$tok"
}

# Open a connection to the studio on fd 3 and keep it only when the far end of
# this very connection belongs to this account. /proc/net/tcp lists both ends of
# a loopback connection with the uid that owns each socket (the server side
# shows its owner even before it is accepted). Everything that carries the token
# is written to fd 3 afterwards, so there is no moment between the check and the
# use in which another account could take the port.
#   0 = ours (fd 3 open)   1 = nothing is listening   2 = owned by someone else
studio_connect() {
  { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; } 2>/dev/null || return 1
  local ino mine peer=""
  ino="$(readlink "/proc/$BASHPID/fd/3")"
  ino="${ino//[^0-9]/}"
  mine="$(awk -v i="$ino" '$10 == i { print $2; exit }' /proc/net/tcp)"
  [ -n "$mine" ] && peer="$(awk -v l="$(printf '0100007F:%04X' "$PORT")" -v r="$mine" \
    '$2 == l && $3 == r { print $8; exit }' /proc/net/tcp)"
  [ -n "$peer" ] && [ "$peer" = "$(id -u)" ] && return 0
  exec 3>&-
  return 2
}

# Send the request head (and body) on fd 3, then skip the response head.
# Prints nothing; leaves the response body on fd 3. Exit: 0 when the status is
# below 400, 22 otherwise, 7 when the studio does not answer.
http_request() {
  local method="$1" path="$2" tok="$3" body="${4:-}" line code req
  printf -v req '%s %s HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nX-Myradio-Token: %s\r\n' "$method" "$path" "$PORT" "$tok"
  [ -n "$body" ] && printf -v req '%sContent-Type: application/json\r\nContent-Length: %s\r\n' \
    "$req" "$(printf '%s' "$body" | wc -c)"
  printf '%s\r\n%s' "$req" "$body" >&3 2>/dev/null || return 7   # one write
  IFS= read -r -t 8 line <&3 || return 7
  code="${line#* }"
  code="${code%% *}"
  case "$code" in ''|*[!0-9]*) return 7 ;; esac
  while IFS= read -r -t 8 line <&3; do
    [ -z "${line%$'\r'}" ] && break
  done
  [ "$code" -lt 400 ] || return 22
}

# GET (no body) or POST against the studio. Prints the response body.
# Exit: 0 ok, 22 HTTP error, 7 offline, 93 port owned by another account, 90 no token.
api() {
  local path="$1" body="${2:-}" tok rc
  tok="$(token)" || return 90
  studio_connect
  case $? in 0) ;; 2) return 93 ;; *) return 7 ;; esac
  http_request "$([ -n "$body" ] && echo POST || echo GET)" "$path" "$tok" "$body"
  rc=$?
  [ "$rc" = 7 ] || timeout 8 cat <&3
  exec 3>&-
  [ -n "$body" ] && [ "$rc" = 22 ] && rc=0   # an action's error reply is JSON the panel shows
  return "$rc"
}

listening() {
  [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
}

# The listener's pid file and mpv socket live in a private folder that must be ours (never follow a planted one).
private_run_dir() {
  mkdir -p -m 700 "$RUN" 2>/dev/null || return 1
  [ -d "$RUN" ] && [ ! -L "$RUN" ] && [ -O "$RUN" ] || { echo "myradio: $RUN is not a private folder" >&2; return 1; }
  chmod 700 "$RUN"
}

mpv_cmd() {
  [ -S "$SOCK" ] || return 1
  printf '%s\n' "$1" | socat -t 1 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
}

slim='{
  station: (.station // {}),
  running, elapsed, fading, error,
  current: (.current | if . then {id, title, artist, duration, kind} else null end),
  queue: [(.queue // [])[:12][] | {id, track_id, title, artist, duration, kind}],
  queue_total: ((.queue // []) | length),
  library_total: ((.library // []) | length),
  history: [(.history // [])[:8][] | {title, at, event}],
  health: (.health // {}),
  stats: (.stats // {}),
  listeners: (.stream.listeners // 0),
  broadcast: (.broadcast.state // null),
  director: (.extensions.director.status // null | if . then {
    enabled, waiting, placed, dropped,
    settings: ((.settings // {}) | {every_songs, station_id_minutes, news_minutes, hosts}),
    requests: [(.requests // [])[] | {key, topic, state, message, track_id, headlines}]
  } else null end),
  generation: (.extensions.generation.status // null | if . then {
    configured, paused, headline, next_step,
    roles: (.capabilities.roles // {}),
    fixture_roles: (.fixture_roles // []),
    jobs: (.jobs // {}),
    recent: [(.recent // [])[:6][] | {id, role, state, title, error}]
  } else null end)
}'

case "${1:-}" in
  status)
    l=false; listening && l=true
    installed=false
    { command -v myradio >/dev/null 2>&1 || [ -f "$DATA/control.token" ]; } && installed=true
    if ! token >/dev/null; then
      printf '{"reach":"missing","installed":%s,"listening":%s,"status":null}\n' "$installed" "$l"
      exit 0
    fi
    body="$(api /api/status 2>/dev/null)"
    rc=$?
    if [ "$rc" = 0 ]; then
      slimmed="$(printf '%s' "$body" | jq -c "$slim" 2>/dev/null)" || slimmed=null
      printf '{"reach":"ok","installed":%s,"listening":%s,"status":%s}\n' "$installed" "$l" "${slimmed:-null}"
    elif [ "$rc" = 93 ]; then
      printf '{"reach":"foreign","installed":%s,"listening":%s,"status":null}\n' "$installed" "$l"
    else
      printf '{"reach":"offline","installed":%s,"listening":%s,"status":null}\n' "$installed" "$l"
    fi
    ;;
  action)
    api /api/action "${2:-}" || printf '{"error":"myradio is not reachable."}\n'
    ;;
  listen)
    listening && exit 0
    vol="${2:-80}"
    case "$vol" in ''|*[!0-9]*) vol=80 ;; esac
    token >/dev/null || exit 90
    private_run_dir || exit 92
    rm -f "$SOCK"
    # Its own process group (this script + mpv), so unlisten can stop all of it.
    setsid -f bash -c 'echo $$ > "$2"; exec "$1" _stream "$3"' _ "$SELF" "$PIDF" "$vol" >/dev/null 2>&1
    ;;
  _stream)   # the listener process started by `listen`: a verified connection piped into mpv
    vol="${2:-80}"
    case "$vol" in ''|*[!0-9]*) vol=80 ;; esac
    tok="$(token)" || exit 90
    studio_connect || exit 93
    http_request GET /stream.wav "$tok" || exit 7
    mpv --no-video --no-terminal --cache=no --volume="$vol" \
        --force-media-title=myradio --input-ipc-server="$SOCK" - <&3
    rm -f "$PIDF" "$SOCK"
    ;;
  unlisten)
    if listening; then kill -- "-$(cat "$PIDF")" 2>/dev/null; fi
    rm -f "$PIDF" "$SOCK"
    ;;
  volume)
    v="${2:-80}"
    case "$v" in ''|*[!0-9]*) exit 2 ;; esac
    mpv_cmd "{\"command\":[\"set_property\",\"volume\",$v]}"
    ;;
  title)
    mpv_cmd "$(jq -cn --arg t "${2:-myradio}" '{command:["set_property","force-media-title",$t]}')"
    ;;
  open)
    # The browser makes its own connection, so the code is never put in the
    # address. Look at the studio first (nothing is sent), then open it and put
    # the launch code on the clipboard for the studio's unlock screen; it is
    # cleared after a minute unless something else was copied since.
    tok="$(token)" || exit 90
    studio_connect
    case $? in 0) exec 3>&- ;; 2) exit 93 ;; *) exit 7 ;; esac
    printf '%s' "$tok" | wl-copy 2>/dev/null &&
      notify-send -a myradio "myradio" "Launch code copied. Paste it into the studio to unlock it." 2>/dev/null
    setsid -f bash -c 'sleep 60; [ "$(wl-paste -n 2>/dev/null)" = "$(tr -d "[:space:]" < "$1/control.token")" ] && wl-copy --clear' \
      _ "$DATA" >/dev/null 2>&1
    setsid -f xdg-open "$BASE/" >/dev/null 2>&1
    ;;
  launch)
    command -v myradio >/dev/null 2>&1 || exit 91
    setsid -f myradio >/dev/null 2>&1
    ;;
  *)
    echo "usage: ctl.sh status|action <json>|listen [volume]|unlisten|volume <n>|title <text>|open|launch" >&2
    exit 2
    ;;
esac
