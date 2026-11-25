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
#   ctl.sh listen [volume]     start the local listener (verified connection into mpv) if it is not running
#   ctl.sh unlisten            stop the local listener
#   ctl.sh volume <0-130>      set the listener volume
#   ctl.sh title <text>        set the listener's media title (shown by MPRIS clients)
#   ctl.sh open                open the studio in the browser with a one-time login ticket
#   ctl.sh launch              start the studio (`myradio --no-browser`); the panel then opens it
#   ctl.sh windup              start the studio if it is down, start playing, go live if a broadcast is set up
#   ctl.sh shutdown            go off air, stop playing and shut the studio down
#
# MYRADIO_START_JSON, when set, is a JSON array of words that starts a studio on
# another computer, e.g. ["ssh","mini","launchctl","kickstart","gui/501/com.myradio"].

set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$SELF")"
SLIM="$ROOT/status.jq"

# Echo a canonical port, or return 1 when it is not an integer from 1 to 65535.
normalize_port() {
  local p="${1-}"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "${#p}" -gt 1 ] && [ "${p:0:1}" = 0 ]; do p="${p:1}"; done
  # Reject before arithmetic so a huge digit string cannot abort the shell.
  [ "${#p}" -le 5 ] || return 1
  p=$((10#$p))
  if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then return 1; fi
  printf '%s' "$p"
}

PORT_OK=0
PORT=0
if [ -n "${MYRADIO_PORT+x}" ]; then
  if PORT="$(normalize_port "$MYRADIO_PORT")"; then
    PORT_OK=1
  else
    PORT_OK=0
    PORT=0
  fi
else
  PORT=8765
  PORT_OK=1
fi

require_port() {
  [ "$PORT_OK" = 1 ] && return 0
  echo "myradio: the studio port must be a number from 1 to 65535" >&2
  return 2
}

DATA="${MYRADIO_DATA_DIR:-$HOME/.myradio}"
BASE="http://127.0.0.1:${PORT}"
RUN="${XDG_RUNTIME_DIR:-/tmp}/omarchy-myradio-$(id -u)"
SOCK="$RUN/mpv.sock"
PIDF="$RUN/listen.pid"

usage() {
  cat >&2 <<'EOF'
usage: ctl.sh <command>

  status              one JSON object: reachability and a slim station status
  action <json>       POST /api/action with a JSON object
  listen [volume]     play the station here through mpv (volume 0-130, default 80)
  unlisten            stop playing here; the station keeps going
  volume <0-130>      set the listener volume
  title <text>        set the listener's media title
  open                open the studio in the browser with a one-time login ticket
  launch              start the studio
  windup              start the studio if needed, start playing, and go live
  shutdown            stop the broadcast and playout, then shut the studio down
EOF
}

token() {
  local tok
  tok="$( { tr -d '[:space:]' < "$DATA/control.token"; } 2>/dev/null)" || return 1
  [ -n "$tok" ] || return 1
  printf '%s' "$tok"
}

# 0 ours, 2 another account, 1 nothing established (gone or still closing).
# An SSH tunnel whose studio is down leaves a closing socket owned by uid 0.
# That is "nothing there", not another account, so Wind up can still start it.
judge_peer() {
  local uid="$1" state="$2" mine="$3"
  if [ "$state" = "01" ]; then
    if [ "$uid" = "$mine" ]; then return 0; fi
    return 2
  fi
  return 1
}

# Open a connection to the studio on fd 3 and keep it only when the far end of
# this very connection belongs to this account. /proc/net/tcp lists both ends of
# a loopback connection with the uid that owns each socket; an established far
# end shows its listener's owner even before it is accepted. With a tunnel the
# far end is your own ssh; the signed reply is what proves the studio behind it.
#   0 = ours (fd 3 open)   1 = nothing to talk to   2 = owned by another account
studio_connect() {
  local ino mine peer="" uid="" state="" rc
  { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; } 2>/dev/null || return 1
  ino="$(readlink "/proc/$BASHPID/fd/3" 2>/dev/null || true)"
  ino="${ino//[^0-9]/}"
  if [ -n "$ino" ]; then
    mine="$(awk -v i="$ino" '$10 == i { print $2; exit }' /proc/net/tcp 2>/dev/null || true)"
  fi
  if [ -n "${mine:-}" ]; then
    peer="$(awk -v l="$(printf '0100007F:%04X' "$PORT")" -v r="$mine" \
      '$2 == l && $3 == r { print $8, $4; exit }' /proc/net/tcp 2>/dev/null || true)"
  fi
  if [ -n "$peer" ]; then
    read -r uid state <<<"$peer"
  fi
  judge_peer "$uid" "$state" "$(id -u)"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  exec 3>&-
  return "$rc"
}

# HMAC-SHA256 of $2 keyed with $1, as hex. The key is only handled by shell
# builtins: padded blocks are written by printf into the pipe to sha256sum,
# never passed to another program as an argument. Keys longer than 64 bytes are
# hashed first, which is what HMAC specifies and what the studio does.
hmac_sha256() {
  local key="$1" msg="$2" i c hex="" ipad="" opad="" inner="" bin="" b nbytes
  for ((i = 0; i < ${#key}; i++)); do
    printf -v c '%d' "'${key:i:1}"
    [ "$c" -le 255 ] || return 1
    printf -v hex '%s%02x' "$hex" "$c"
  done
  if [ "${#key}" -gt 64 ]; then
    hex="$(printf '%s' "$key" | sha256sum)" || return 1
    hex="${hex%% *}"
  fi
  nbytes=$(( ${#hex} / 2 ))
  for ((i = 0; i < 64; i++)); do
    if [ "$i" -lt "$nbytes" ]; then
      b=$((16#${hex:i*2:2}))
    else
      b=0
    fi
    printf -v ipad '%s\\x%02x' "$ipad" $((b ^ 0x36))
    printf -v opad '%s\\x%02x' "$opad" $((b ^ 0x5c))
  done
  inner="$( { printf '%b' "$ipad"; printf '%s' "$msg"; } | sha256sum)" || return 1
  inner="${inner%% *}"
  for ((i = 0; i < 64; i += 2)); do bin+="\\x${inner:i:2}"; done
  inner="$( { printf '%b' "$opad"; printf '%b' "$bin"; } | sha256sum)" || return 1
  printf '%s' "${inner%% *}"
}

sha256_of() { local h; h="$(sha256sum)"; printf '%s' "${h%% *}"; }

byte_count() {
  local n
  n="$(printf '%s' "$1" | wc -c)"
  printf '%s' "${n//[[:space:]]/}"
}

# Read a reply head from fd 3. Sets CODE, REPLY_AUTH and LENGTH; the body stays
# on fd 3. Exit: 0 when a reply head arrived, 7 when the studio did not answer.
read_head() {
  local line name value
  CODE="" REPLY_AUTH="" LENGTH=""
  IFS= read -r -t 8 line <&3 2>/dev/null || return 7
  line="${line%$'\r'}"
  CODE="${line#* }"
  CODE="${CODE%% *}"
  CODE="${CODE%$'\r'}"
  case "$CODE" in ''|*[!0-9]*) return 7 ;; esac
  while IFS= read -r -t 8 line <&3 2>/dev/null; do
    line="${line%$'\r'}"
    [ -z "$line" ] && break
    name="${line%%:*}"
    value="${line#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "${name,,}" in
      x-myradio-response-auth) REPLY_AUTH="$value" ;;
      content-length) LENGTH="$value" ;;
    esac
  done
}

# Connect, mapping studio_connect's result to this script's exit codes.
connect_or_code() {
  studio_connect
  case $? in
    0) return 0 ;;
    2) return 93 ;;
    *) return 7 ;;
  esac
}

# Ask the studio for a one-time challenge (no token involved). Sets CHALLENGE.
# Exit: 0, 7 offline, 93 another account's port, 94 no challenge (not the
# studio, or myradio older than 0.5.0).
get_challenge() {
  local body="" rc
  CHALLENGE=""
  connect_or_code || return $?
  printf 'GET /api/challenge HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\n\r\n' "$PORT" >&3 2>/dev/null || { exec 3>&-; return 7; }
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
  printf -v req '%s %s HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\nX-Myradio-Auth: v1 %s %s\r\nX-Myradio-Body-SHA256: %s\r\n' \
    "$method" "$path" "$PORT" "$CHALLENGE" "$sig" "$body_hash"
  if [ -n "$body" ]; then
    printf -v req '%sContent-Type: application/json\r\nContent-Length: %s\r\n' "$req" "$(byte_count "$body")"
  fi
  printf '%s\r\n%s' "$req" "$body" >&3 2>/dev/null || { exec 3>&-; return 7; }
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
  local path="$1" body="${2:-}" tok file rc=0
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

# Text of a signed action reply's error, or empty when the studio accepted it.
action_error() {
  local err
  if ! err="$(jq -r 'if type == "object" then (.error // "") else "Unexpected reply from the studio." end' <<<"$1" 2>/dev/null)"; then
    printf '%s' "Unexpected reply from the studio."
    return 0
  fi
  printf '%s' "$err"
}

fail_json() {
  jq -cn --arg e "$1" '{ok:false, error:$e}'
}

# Start the studio: a configured command for a studio on another computer, or
# the local `myradio` without a browser (the panel opens it with a login ticket).
# Exit: 0 started, 91 nothing to start with.
start_studio() {
  local -a cmd=()
  if [ -n "${MYRADIO_START_JSON:-}" ]; then
    mapfile -t cmd < <(jq -r 'if type == "array" and length > 0 and all(type == "string") then .[] else empty end' \
      <<<"$MYRADIO_START_JSON" 2>/dev/null)
    [ "${#cmd[@]}" -gt 0 ] || return 91
  else
    command -v myradio >/dev/null 2>&1 || return 91
    cmd=(myradio --data-dir "$DATA" --port "$PORT" --no-browser)
  fi
  setsid -f "${cmd[@]}" >/dev/null 2>&1 </dev/null
}

# True when the pid file still belongs to this script's listener, not a recycled pid.
listening() {
  local pid cmd
  [ -f "$PIDF" ] || return 1
  pid="$(cat "$PIDF" 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    *" _stream "*|*" _stream") ;;
    *) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# The listener's pid file and mpv socket live in a private folder that must be ours (never follow a planted one).
private_run_dir() {
  mkdir -p "$RUN" 2>/dev/null || return 1
  if [ ! -d "$RUN" ] || [ -L "$RUN" ] || [ ! -O "$RUN" ]; then
    echo "myradio: $RUN is not a private folder" >&2
    return 1
  fi
  chmod 700 "$RUN"
}

# Echo a volume from 0 to 130. Non-numeric input fails.
clamp_volume() {
  local v="${1-}"
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  v=$((10#$v))
  if [ "$v" -gt 130 ]; then v=130; fi
  printf '%s' "$v"
}

mpv_cmd() {
  [ -S "$SOCK" ] || return 1
  printf '%s\n' "$1" | socat -t 1 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
}

broadcast_is_live() {
  case "$1" in
    streaming|connecting|retrying|encoding) return 0 ;;
    *) return 1 ;;
  esac
}

installed_flag() {
  if command -v myradio >/dev/null 2>&1 || [ -f "$DATA/control.token" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

listening_flag() {
  if listening; then printf 'true'; else printf 'false'; fi
}

# One JSON object. Pretty when a person is looking, one line when a program is.
emit_json() {
  if [ -t 1 ] && command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$1" | jq . 2>/dev/null && return 0
  fi
  printf '%s\n' "$1"
}

emit_reach() {
  local reach="$1" installed listening_now
  installed="$(installed_flag)"
  listening_now="$(listening_flag)"
  emit_json "{\"reach\":\"$reach\",\"installed\":$installed,\"listening\":$listening_now,\"status\":null}"
}

report_action_failure() {
  local rc="$1"
  case "$rc" in
    90) printf '%s\n' '{"error":"Start myradio once to finish setup."}' ;;
    92) printf '%s\n' '{"error":"The listener folder is not private."}' ;;
    93) printf '%s\n' '{"error":"Another account holds the studio port, so nothing was sent."}' ;;
    94) printf '%s\n' '{"error":"Could not verify the studio, so the reply was ignored. Your control code was not sent. The studio needs myradio 0.5.0 or newer."}' ;;
    *) printf '%s\n' '{"error":"myradio is not reachable."}' ;;
  esac
  exit "$rc"
}

# Sourced by the test suite so the helpers can be checked without a command.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

case "${1:-}" in
  status)
    if [ "$PORT_OK" != 1 ]; then
      emit_reach badport
      exit 0
    fi
    if ! token >/dev/null; then
      emit_reach missing
      exit 0
    fi
    body="$(api /api/status 2>/dev/null)"
    rc=$?
    if [ "$rc" = 0 ]; then
      slimmed="$(printf '%s' "$body" | jq -c -f "$SLIM" 2>/dev/null)" || slimmed=null
      installed="$(installed_flag)"
      listening_now="$(listening_flag)"
      emit_json "{\"reach\":\"ok\",\"installed\":$installed,\"listening\":$listening_now,\"status\":${slimmed:-null}}"
    elif [ "$rc" = 93 ]; then
      emit_reach foreign
    elif [ "$rc" = 94 ]; then
      emit_reach unverified
    else
      emit_reach offline
    fi
    ;;
  action)
    require_port || exit $?
    if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
      echo "myradio: action expects a JSON object" >&2
      usage
      exit 2
    fi
    if ! printf '%s' "$2" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "myradio: action expects a JSON object" >&2
      exit 2
    fi
    api /api/action "$2"
    rc=$?
    [ "$rc" -eq 0 ] || report_action_failure "$rc"
    ;;
  listen)
    require_port || exit $?
    vol="$(clamp_volume "${2:-80}")" || vol=80
    token >/dev/null || exit 90
    private_run_dir || exit 92
    if command -v flock >/dev/null 2>&1; then
      exec 9>>"$RUN/listen.lock" || exit 92
      flock -n 9 || exit 0
    elif listening; then
      exit 0
    fi
    if listening; then exit 0; fi
    rm -f "$SOCK"
    # Its own process group (this script + mpv), so unlisten can stop all of it.
    # The lock on fd 9 is inherited, so a second listen while this one is up does nothing.
    # shellcheck disable=SC2016 # $1 and $$ belong to the child shell
    setsid -f bash -c 'echo $$ > "$2"; exec "$1" _stream "$3"' _ "$SELF" "$PIDF" "$vol" >/dev/null 2>&1
    ;;
  _stream)   # the listener process started by `listen`: the studio's signed stream piped into mpv
    vol="$(clamp_volume "${2:-80}")" || vol=80
    trap 'rm -f "$PIDF" "$SOCK"' EXIT
    tok="$(token)" || exit 90
    signed_request GET /stream.wav "$tok" || exit $?
    [ "$CODE" = 200 ] && reply_is_signed "$tok" stream || exit 94
    # volume-max matches the panel, which goes to 130. Older mpv clamps at 100 without it.
    mpv --no-video --no-terminal --cache=no --volume-max=130 --volume="$vol" \
        --force-media-title=myradio --input-ipc-server="$SOCK" - <&3
    ;;
  unlisten)
    if listening; then kill -- "-$(cat "$PIDF")" 2>/dev/null || true; fi
    rm -f "$PIDF" "$SOCK"
    ;;
  volume)
    v="$(clamp_volume "${2-}")" || { echo "myradio: volume must be a number from 0 to 130" >&2; exit 2; }
    if ! mpv_cmd "{\"command\":[\"set_property\",\"volume\",$v]}"; then
      echo "myradio: the listener is not running" >&2
      exit 1
    fi
    ;;
  title)
    if ! mpv_cmd "$(jq -cn --arg t "${2:-myradio}" '{command:["set_property","force-media-title",$t]}')"; then
      echo "myradio: the listener is not running" >&2
      exit 1
    fi
    ;;
  open)
    # The browser makes its own connection, so the control code never goes to
    # it. Ask the studio (signed request, verified reply) for a login ticket that
    # works once within a minute, and open the studio through a page in this
    # account's private run folder, so the ticket is not on any command line.
    require_port || exit $?
    private_run_dir || exit 92
    reply="$(api /api/login-ticket '{}')"
    rc=$?
    [ "$rc" = 0 ] || exit "$rc"
    [[ $reply =~ \"ticket\":\ *\"([A-Za-z0-9_-]{43})\" ]] || exit 22
    page="$(mktemp --suffix=.html "$RUN/open.XXXXXX")" || exit 92
    printf '<!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>myradio</title><script>location.replace("%s/#ticket=%s")</script>\n' \
      "$BASE" "${BASH_REMATCH[1]}" > "$page"
    setsid -f xdg-open "$page" >/dev/null 2>&1
    # shellcheck disable=SC2016 # $1 belongs to the child shell
    setsid -f bash -c 'sleep 30; rm -f "$1"' _ "$page" >/dev/null 2>&1
    ;;
  launch)
    require_port || exit $?
    start_studio
    ;;
  windup)
    # Start the studio if it is down, start playing, and go live when a
    # broadcast destination is saved. Prints one JSON line with the outcome.
    require_port || exit $?
    token >/dev/null || exit 90
    api /api/status >/dev/null
    rc=$?
    case "$rc" in
      0) ;;
      90|92|93|94) exit "$rc" ;;
      *)
        start_studio || exit $?
        for ((i = 0; i < 45; i++)); do
          sleep 2
          api /api/status >/dev/null && break
        done
        ;;
    esac
    status_json="$(api /api/status)" || exit $?
    if [ "$(jq -r '.running' <<<"$status_json")" != true ]; then
      started="$(api /api/action '{"operation":"transport.start","arguments":{}}')" || exit $?
      err="$(action_error "$started")"
      if [ -n "$err" ]; then fail_json "$err"; exit 0; fi
    fi
    live=false
    if [ "$(jq -r '.broadcast.configured' <<<"$status_json")" = true ]; then
      bstate="$(jq -r '.broadcast.state // empty' <<<"$status_json")"
      if broadcast_is_live "$bstate"; then
        live=true
      else
        reply="$(api /api/action '{"operation":"broadcast.start","arguments":{}}')" || exit $?
        err="$(action_error "$reply")"
        if [ -n "$err" ]; then fail_json "$err"; exit 0; fi
        live=true
      fi
    fi
    jq -cn --argjson live "$live" '{ok:true, live:$live}'
    ;;
  shutdown)
    # Off air first (so the studio does not come back playing), then shut it down.
    require_port || exit $?
    if listening; then kill -- "-$(cat "$PIDF")" 2>/dev/null || true; fi
    rm -f "$PIDF" "$SOCK"
    api /api/action '{"operation":"broadcast.stop","arguments":{}}' >/dev/null || exit $?
    api /api/action '{"operation":"transport.stop","arguments":{}}' >/dev/null || exit $?
    reply="$(api /api/shutdown '{}')" || exit $?
    [ "$(jq -r '.ok' <<<"$reply")" = true ] && exit 0
    [ "$(jq -r '.error // empty' <<<"$reply")" = "Not found." ] && exit 95   # myradio older than 0.5.1
    printf '%s\n' "$reply"
    exit 22
    ;;
  help|-h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
