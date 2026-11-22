#!/usr/bin/env bash
# Control helper for the myradio Omarchy plugin.
#
# Talks to the myradio studio over its loopback API. The control token never
# leaves this computer: every request is signed with it (HMAC-SHA256 over the
# request and a one-time challenge the studio issued; myradio 0.5.0 or newer),
# and the studio signs its reply. A listener that is not the studio, here or at
# the far end of an SSH tunnel, gets no token, cannot replay what it receives,
# and cannot produce a reply this script accepts. A connection is also dropped
# before anything is sent when its local far end belongs to another account.
#
#   ctl.sh status              one JSON line: reachability, listener state, slim station status
#   ctl.sh action <json>       POST /api/action with {"operation":..., "arguments":{...}}
#   ctl.sh listen <volume>     start the local listener (verified connection into mpv) if it is not running
#   ctl.sh unlisten            stop the local listener
#   ctl.sh volume <0-130>      set the listener volume
#   ctl.sh title <text>        set the listener's media title (shown by MPRIS clients)
#   ctl.sh open                open the studio in the browser with a one-time login ticket
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
# shows its owner even before it is accepted). With an SSH tunnel this is your
# own ssh; the signed reply is what proves the studio behind it.
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

# HMAC-SHA256 of $2 keyed with $1 (ASCII, at most 64 bytes), as hex. The key is
# only handled by shell builtins: the padded key blocks are written by printf
# into the pipe to sha256sum, never passed to another program as an argument.
hmac_sha256() {
  local key="$1" msg="$2" i c ipad="" opad="" inner bin=""
  [ "${#key}" -le 64 ] || return 1
  for ((i = 0; i < 64; i++)); do
    c=0
    [ "$i" -lt "${#key}" ] && printf -v c '%d' "'${key:i:1}"
    printf -v ipad '%s\\x%02x' "$ipad" $(( c ^ 0x36 ))
    printf -v opad '%s\\x%02x' "$opad" $(( c ^ 0x5c ))
  done
  inner="$( { printf "$ipad"; printf '%s' "$msg"; } | sha256sum)"
  for ((i = 0; i < 64; i += 2)); do bin+="\\x${inner:i:2}"; done
  inner="$( { printf "$opad"; printf "$bin"; } | sha256sum)"
  printf '%s' "${inner%% *}"
}

sha256_of() { local h; h="$(sha256sum)"; printf '%s' "${h%% *}"; }

# Read a reply head from fd 3. Sets CODE, REPLY_AUTH and LENGTH; the body stays
# on fd 3. Exit: 0 when a reply head arrived, 7 when the studio did not answer.
read_head() {
  local line name value
  CODE="" REPLY_AUTH="" LENGTH=""
  IFS= read -r -t 8 line <&3 || return 7
  CODE="${line#* }"
  CODE="${CODE%% *}"
  case "$CODE" in ''|*[!0-9]*) return 7 ;; esac
  while IFS= read -r -t 8 line <&3; do
    line="${line%$'\r'}"
    [ -z "$line" ] && break
    name="${line%%:*}"
    value="${line#*:}"
    value="${value# }"
    case "${name,,}" in
      x-myradio-response-auth) REPLY_AUTH="$value" ;;
      content-length) LENGTH="$value" ;;
    esac
  done
}

# Connect, mapping studio_connect's result to this script's exit codes.
connect_or_code() {
  studio_connect
  case $? in 0) return 0 ;; 2) return 93 ;; *) return 7 ;; esac
}

# Ask the studio for a one-time challenge (no token involved). Sets CHALLENGE.
# Exit: 0, 7 offline, 93 another account's port, 94 no challenge (not the
# studio, or myradio older than 0.5.0).
get_challenge() {
  local body="" rc
  CHALLENGE=""
  connect_or_code || return $?
  printf 'GET /api/challenge HTTP/1.0\r\nHost: 127.0.0.1:%s\r\n\r\n' "$PORT" >&3 2>/dev/null || { exec 3>&-; return 7; }
  read_head
  rc=$?
  [ "$rc" = 0 ] && body="$(timeout 4 head -c 512 <&3)"
  exec 3>&-
  [ "$rc" = 0 ] || return 7
  [ "$CODE" = 200 ] && [[ $body =~ \"challenge\":\ *\"([0-9a-f]{32})\" ]] || return 94
  CHALLENGE="${BASH_REMATCH[1]}"
}

# Send one request signed over a fresh challenge and read the reply head; the
# body stays on fd 3. Exit codes as get_challenge.
signed_request() {
  local method="$1" path="$2" tok="$3" body="${4:-}" sig body_hash req
  get_challenge || return $?
  connect_or_code || return $?
  body_hash="$(printf '%s' "$body" | sha256_of)"
  sig="$(hmac_sha256 "$tok" "myradio-v1"$'\n'"$method"$'\n'"$path"$'\n'"127.0.0.1:$PORT"$'\n'"$CHALLENGE"$'\n'"$body_hash")" \
    || { exec 3>&-; return 7; }
  printf -v req '%s %s HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nX-Myradio-Auth: v1 %s %s\r\nX-Myradio-Body-SHA256: %s\r\n' \
    "$method" "$path" "$PORT" "$CHALLENGE" "$sig" "$body_hash"
  [ -n "$body" ] && printf -v req '%sContent-Type: application/json\r\nContent-Length: %s\r\n' \
    "$req" "$(printf '%s' "$body" | wc -c)"
  printf '%s\r\n%s' "$req" "$body" >&3 2>/dev/null || { exec 3>&-; return 7; }   # one write
  read_head || { exec 3>&-; return 7; }
}

# True when the reply to the request just sent was signed by the studio.
reply_is_signed() {   # $1 token, $2 body hash ("stream" for the live stream)
  local want
  want="$(hmac_sha256 "$1" "myradio-v1-response"$'\n'"$CHALLENGE"$'\n'"$CODE"$'\n'"$2")" || return 1
  [ -n "$REPLY_AUTH" ] && [ "$REPLY_AUTH" = "v1 $want" ]
}

# GET (no body) or POST against the studio. Prints the reply body only when the
# studio signed it. Exit: 0 ok, 22 HTTP error, 7 offline, 90 no token,
# 92 no private folder, 93 port owned by another account, 94 not verified as the
# studio (something else answered, or myradio older than 0.5.0).
api() {
  local path="$1" body="${2:-}" tok rc=0 file
  tok="$(token)" || return 90
  private_run_dir || return 92
  signed_request "$([ -n "$body" ] && echo POST || echo GET)" "$path" "$tok" "$body" || return $?
  file="$(mktemp "$RUN/reply.XXXXXX")" || { exec 3>&-; return 92; }
  case "$LENGTH" in
    ''|*[!0-9]*) timeout 8 cat <&3 > "$file" ;;
    *) timeout 8 head -c "$LENGTH" <&3 > "$file" ;;
  esac
  exec 3>&-
  if ! reply_is_signed "$tok" "$(sha256_of < "$file")"; then
    rm -f "$file"
    return 94
  fi
  cat "$file"
  rm -f "$file"
  [ "$CODE" -lt 400 ] || rc=22
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
    elif [ "$rc" = 94 ]; then
      printf '{"reach":"unverified","installed":%s,"listening":%s,"status":null}\n' "$installed" "$l"
    else
      printf '{"reach":"offline","installed":%s,"listening":%s,"status":null}\n' "$installed" "$l"
    fi
    ;;
  action)
    api /api/action "${2:-}"
    case $? in
      0) ;;
      93) printf '{"error":"Another account holds the studio port, so nothing was sent."}\n' ;;
      94) printf '{"error":"Could not verify the studio, so the reply was ignored. Your control code was not sent. The studio needs myradio 0.5.0 or newer."}\n' ;;
      *) printf '{"error":"myradio is not reachable."}\n' ;;
    esac
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
  _stream)   # the listener process started by `listen`: the studio's signed stream piped into mpv
    vol="${2:-80}"
    case "$vol" in ''|*[!0-9]*) vol=80 ;; esac
    trap 'rm -f "$PIDF" "$SOCK"' EXIT
    tok="$(token)" || exit 90
    signed_request GET /stream.wav "$tok" || exit $?
    [ "$CODE" = 200 ] && reply_is_signed "$tok" stream || exit 94
    mpv --no-video --no-terminal --cache=no --volume="$vol" \
        --force-media-title=myradio --input-ipc-server="$SOCK" - <&3
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
    # The browser makes its own connection, so the control code never goes to
    # it. Ask the studio (signed request, verified reply) for a login ticket that
    # works once within a minute, and open the studio through a page in this
    # account's private run folder, so the ticket is not on any command line.
    private_run_dir || exit 92
    reply="$(api /api/login-ticket '{}')"
    rc=$?
    [ "$rc" = 0 ] || exit "$rc"
    [[ $reply =~ \"ticket\":\ *\"([A-Za-z0-9_-]{43})\" ]] || exit 22
    page="$(mktemp --suffix=.html "$RUN/open.XXXXXX")" || exit 92
    printf '<!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>myradio</title><script>location.replace("%s/#ticket=%s")</script>\n' \
      "$BASE" "${BASH_REMATCH[1]}" > "$page"
    setsid -f xdg-open "$page" >/dev/null 2>&1
    setsid -f bash -c 'sleep 30; rm -f "$1"' _ "$page" >/dev/null 2>&1
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
