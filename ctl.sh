#!/usr/bin/env bash
# Control helper for the myradio Omarchy plugin.
#
# Talks to the local myradio studio over its loopback API. The control token is
# read from the studio's data folder and handed to curl through a file
# descriptor, so it never appears in a process list.
#
#   ctl.sh status              one JSON line: reachability, listener state, slim station status
#   ctl.sh action <json>       POST /api/action with {"operation":..., "arguments":{...}}
#   ctl.sh listen <volume>     start the local listener (curl | mpv) if it is not running
#   ctl.sh unlisten            stop the local listener
#   ctl.sh volume <0-130>      set the listener volume
#   ctl.sh title <text>        set the listener's media title (shown by MPRIS clients)
#   ctl.sh open                open the studio in the browser
#   ctl.sh launch              start the studio (`myradio`), which opens the browser itself

set -uo pipefail

PORT="${MYRADIO_PORT:-8765}"
case "$PORT" in ''|*[!0-9]*) PORT=8765 ;; esac
DATA="${MYRADIO_DATA_DIR:-$HOME/.myradio}"
BASE="http://127.0.0.1:$PORT"
RUN="${XDG_RUNTIME_DIR:-/tmp}/omarchy-myradio-$(id -u)"
SOCK="$RUN/mpv.sock"
PIDF="$RUN/listen.pid"

token() {
  local tok
  tok="$( { tr -d '[:space:]' < "$DATA/control.token"; } 2>/dev/null)" || return 1
  [ -n "$tok" ] || return 1
  printf '%s' "$tok"
}

# GET or POST against the studio. Prints the body; exit status is curl's.
api() {
  local path="$1" body="${2:-}" tok
  tok="$(token)" || return 90
  if [ -n "$body" ]; then
    curl -sS --max-time 8 --noproxy '*' \
      -H @<(printf 'X-Myradio-Token: %s\n' "$tok") \
      -H 'Content-Type: application/json' \
      --data-binary "$body" "$BASE$path"
  else
    curl -fsS --max-time 4 --noproxy '*' \
      -H @<(printf 'X-Myradio-Token: %s\n' "$tok") "$BASE$path"
  fi
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
    if body="$(api /api/status 2>/dev/null)"; then
      slimmed="$(printf '%s' "$body" | jq -c "$slim" 2>/dev/null)" || slimmed=null
      printf '{"reach":"ok","installed":%s,"listening":%s,"status":%s}\n' "$installed" "$l" "${slimmed:-null}"
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
    # One process group (bash + curl + mpv) so unlisten can stop all of it.
    setsid -f bash -c '
      echo $$ > "$4"
      tok="$(tr -d "[:space:]" < "$1/control.token")"
      curl -sN --noproxy "*" -H @<(printf "X-Myradio-Token: %s\n" "$tok") "$2/stream.wav" \
        | mpv --no-video --no-terminal --cache=no --volume="$3" \
              --force-media-title=myradio --input-ipc-server="$5" -
      rm -f "$4" "$5"
    ' _ "$DATA" "$BASE" "$vol" "$PIDF" "$SOCK" >/dev/null 2>&1
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
    tok="$(token)" || exit 90
    setsid -f xdg-open "$BASE/#token=$tok" >/dev/null 2>&1
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
