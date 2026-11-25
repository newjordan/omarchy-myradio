#!/usr/bin/env bash
# Exercise ctl.sh against a local signed stand-in. No studio and no model weights.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN='plugin-test-token_NOTHEX'
WORKDIR="$(mktemp -d)"
DATA="$WORKDIR/data"
RUNTIME="$WORKDIR/run"
LOG="$WORKDIR/requests.log"
FAKEBIN="$WORKDIR/bin"
MOCK_PID=""
PORT=""

mkdir -p "$DATA" "$RUNTIME" "$FAKEBIN"
printf '%s\n' "$TOKEN" > "$DATA/control.token"
chmod 600 "$DATA/control.token"

cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    MOCK_PID=""
  fi
  local pid args
  while read -r pid args; do
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$WORKDIR"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done < <(ps -eo pid=,args=)
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

die() {
  printf 'ctl test: %s\n' "$1" >&2
  if [ -f "$WORKDIR/server.err" ]; then
    printf 'server stderr:\n' >&2
    cat "$WORKDIR/server.err" >&2 || true
  fi
  exit 1
}

run_ctl() {
  local path="${CTL_PATH:-$PATH}"
  (
    export MYRADIO_DATA_DIR="$DATA"
    export XDG_RUNTIME_DIR="$RUNTIME"
    if [ -n "${MYRADIO_PORT+x}" ]; then export MYRADIO_PORT; fi
    if [ -n "${MYRADIO_START_JSON+x}" ]; then export MYRADIO_START_JSON; fi
    exec env PATH="$path" "$ROOT/ctl.sh" "$@"
  )
}

start_server() {
  python3 "$ROOT/tests/mock_studio.py" --token "$TOKEN" --log "$LOG" "$@" \
    >"$WORKDIR/server.out" 2>"$WORKDIR/server.err" &
  MOCK_PID=$!
  local _
  for _ in $(seq 1 50); do
    if [ -s "$WORKDIR/server.out" ] && grep -q '^PORT ' "$WORKDIR/server.out"; then
      PORT="$(awk '/^PORT / { print $2; exit }' "$WORKDIR/server.out")"
      MYRADIO_PORT="$PORT"
      return 0
    fi
    if ! kill -0 "$MOCK_PID" 2>/dev/null; then
      die "mock studio exited"
    fi
    sleep 0.05
  done
  die "mock studio did not print a port"
}

stop_server() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    MOCK_PID=""
  fi
  : >"$WORKDIR/server.out"
}

assert_json() {
  local label="$1" filter="$2" json="$3"
  if ! printf '%s' "$json" | jq -e "$filter" >/dev/null; then
    printf 'ctl test: %s\n%s\n' "$label" "$json" >&2
    exit 1
  fi
}

no_token() {
  local text="$1"
  case "$text" in
    *"$TOKEN"*) die "control token appeared in output" ;;
  esac
  if [ -f "$LOG" ] && grep -q '"leaked":true\|"token_header":true' "$LOG"; then
    die "control token was sent to the studio"
  fi
}

# --- pure helpers -----------------------------------------------------------

helpers="$(bash -c '
source "$1"
printf "port=%s\n" "$(normalize_port 00008765)"
normalize_port 0 >/dev/null && printf "zero=ok\n" || printf "zero=bad\n"
normalize_port 65536 >/dev/null && printf "big=ok\n" || printf "big=bad\n"
normalize_port 65535 >/dev/null && printf "max=ok\n" || printf "max=bad\n"
normalize_port abc >/dev/null && printf "abc=ok\n" || printf "abc=bad\n"
judge_peer 0 06 1000 >/dev/null
printf "down=%s\n" "$?"
judge_peer 0 01 1000 >/dev/null
printf "foreign=%s\n" "$?"
judge_peer 1000 01 1000 >/dev/null
printf "ours=%s\n" "$?"
judge_peer "" "" 1000 >/dev/null
printf "empty=%s\n" "$?"
' _ "$ROOT/ctl.sh")"
printf '%s\n' "$helpers" | grep -qx 'port=8765' || die "leading zeros were not normalised: $helpers"
printf '%s\n' "$helpers" | grep -qx 'zero=bad' || die "port 0 was accepted"
printf '%s\n' "$helpers" | grep -qx 'big=bad' || die "port 65536 was accepted"
printf '%s\n' "$helpers" | grep -qx 'max=ok' || die "port 65535 was rejected"
printf '%s\n' "$helpers" | grep -qx 'abc=bad' || die "port abc was accepted"
printf '%s\n' "$helpers" | grep -qx 'down=1' || die "a closing root socket was not treated as down"
printf '%s\n' "$helpers" | grep -qx 'foreign=2' || die "an established foreign socket was not rejected"
printf '%s\n' "$helpers" | grep -qx 'ours=0' || die "our own socket was not accepted"
printf '%s\n' "$helpers" | grep -qx 'empty=1' || die "a missing peer was not treated as down"

ROOT="$ROOT" python3 - <<'PY'
import hashlib, hmac, os, subprocess, sys
root = os.environ["ROOT"]
script = 'source "$1"\nhmac_sha256 "$2" "$3"\n'
cases = [
    ("k", "msg"),
    ("a" * 43, "myradio-v1\nGET\n/api/status\n127.0.0.1:8765\n" + "ab" * 16 + "\n" + "cd" * 32),
    ("a" * 80, "longer than the sha256 block"),
    ("k", ""),
    ("Z_token-not-hex", "plain"),
]
for key, msg in cases:
    got = subprocess.check_output(["bash", "-c", script, "bash", root + "/ctl.sh", key, msg], text=True).strip()
    want = hmac.new(key.encode(), msg.encode("latin-1"), hashlib.sha256).hexdigest()
    if got != want:
        sys.exit(f"hmac mismatch for key length {len(key)}")
PY

# --- client behaviour -------------------------------------------------------

unset MYRADIO_PORT MYRADIO_START_JSON || true
rm -f "$DATA/control.token"
out="$(run_ctl status)"
no_token "$out"
if command -v myradio >/dev/null 2>&1; then
  assert_json "missing token with a binary" '.reach == "missing" and .installed == true and .status == null' "$out"
else
  assert_json "missing token without a binary" '.reach == "missing" and .installed == false and .status == null' "$out"
fi
printf '%s\n' "$TOKEN" > "$DATA/control.token"
chmod 600 "$DATA/control.token"

MYRADIO_PORT=70000
out="$(run_ctl status)"
assert_json "huge port" '.reach == "badport" and .status == null' "$out"
case "$out" in *$'\n'*) die "badport status was not a single line" ;; esac
MYRADIO_PORT=0
out="$(run_ctl status)"
assert_json "port zero" '.reach == "badport"' "$out"
unset MYRADIO_PORT

closed="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
MYRADIO_PORT="$closed"
out="$(run_ctl status)"
assert_json "closed port" '.reach == "offline"' "$out"
no_token "$out"

if run_ctl action >/dev/null 2>&1; then die "action without a body succeeded"; else [ "$?" -eq 2 ]; fi
if run_ctl action '["nope"]' >/dev/null 2>&1; then die "action accepted a JSON array"; else [ "$?" -eq 2 ]; fi
if run_ctl nope >/dev/null 2>&1; then die "unknown command succeeded"; else [ "$?" -eq 2 ]; fi
run_ctl help >/dev/null 2>&1

start_server
out="$(run_ctl status)"
case "$out" in *$'\n'*) die "status was not a single line" ;; esac
assert_json "signed status" '
  .reach == "ok" and .listening == false and .installed == true
  and .status.station.name == "Test FM"
  and .status.listeners == 2
  and .status.queue_total == 1
  and .status.library_total == 2
  and .status.generation.warming == ["host_break", "song"]
  and (.status.generation.roles.song == false)
  and .status.director.settings.every_songs == 4
' "$out"
no_token "$out"

out="$(run_ctl action '{"operation":"studio.ping","arguments":{"n":1}}')"
assert_json "action echo" '.echo.operation == "studio.ping" and .echo.arguments.n == 1' "$out"
no_token "$out"

# Playback: a fake mpv stays up, a second listen does not start another one.
cat > "$FAKEBIN/mpv" <<'EOF'
#!/bin/sh
sleep 30
EOF
chmod +x "$FAKEBIN/mpv"
CTL_PATH="$FAKEBIN:$PATH"
run_ctl listen 80
pidf="$RUNTIME/omarchy-myradio-$(id -u)/listen.pid"
pid=""
for _ in $(seq 1 30); do
  if [ -f "$pidf" ]; then
    pid="$(cat "$pidf")"
    kill -0 "$pid" 2>/dev/null && break
  fi
  sleep 0.1
done
[ -n "$pid" ] || die "listener did not stay up"
run_ctl listen 10
pid2="$(cat "$pidf")"
[ "$pid" = "$pid2" ] || die "a second listen replaced the listener"
streams="$(ps -eo args= | awk '/ _stream / && !/awk/ { n++ } END { print n + 0 }')"
[ "$streams" -eq 1 ] || die "expected one listener, saw $streams"
run_ctl unlisten
sleep 0.2
if kill -0 "$pid" 2>/dev/null; then die "unlisten left the listener running"; fi
unset CTL_PATH

# Volume is clamped and refused when nothing is listening.
sockdir="$RUNTIME/omarchy-myradio-$(id -u)"
mkdir -p "$sockdir"
python3 -c 'import os, socket, sys
path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)
sock = socket.socket(socket.AF_UNIX)
sock.bind(path)
' "$sockdir/mpv.sock"
cat > "$FAKEBIN/socat" <<EOF
#!/bin/sh
cat > "$WORKDIR/socat.in"
exit 0
EOF
chmod +x "$FAKEBIN/socat"
CTL_PATH="$FAKEBIN:$PATH"
run_ctl volume 140
unset CTL_PATH
assert_json "clamped volume" '.command == ["set_property", "volume", 130]' "$(cat "$WORKDIR/socat.in")"
rm -f "$sockdir/mpv.sock"
if run_ctl volume 40 >/dev/null 2>&1; then die "volume succeeded without a listener"; else [ "$?" -eq 1 ]; fi

# Opening the studio hands the browser a ticket, not the control token.
cat > "$FAKEBIN/xdg-open" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > "$WORKDIR/opened"
EOF
chmod +x "$FAKEBIN/xdg-open"
CTL_PATH="$FAKEBIN:$PATH"
run_ctl open
unset CTL_PATH
for _ in $(seq 1 20); do
  [ -s "$WORKDIR/opened" ] && break
  sleep 0.05
done
[ -s "$WORKDIR/opened" ] || die "browser was not opened"
page="$(cat "$WORKDIR/opened")"
[ -f "$page" ] || die "login page was not written"
page_text="$(cat "$page")"
case "$page_text" in
  *"$TOKEN"*) die "login page contains the control token" ;;
  *'#ticket='*) ;;
  *) die "login page has no ticket" ;;
esac
case "$page" in
  *"$TOKEN"*) die "login page path contains the control token" ;;
esac
no_token "$page_text"

# Wind up while the encoder is already running must not start the broadcast again.
stop_server
cat > "$WORKDIR/encoding.json" <<'EOF'
{
  "running": true,
  "broadcast": {"configured": true, "state": "encoding"},
  "station": {"name": "Test"},
  "queue": [],
  "library": [],
  "history": [],
  "stream": {"listeners": 0}
}
EOF
start_server --status "$WORKDIR/encoding.json"
out="$(run_ctl windup)"
assert_json "encoding is already live" '.ok == true and .live == true' "$out"
if grep -q '"operation":"broadcast.start"' "$LOG"; then
  die "wind up started a broadcast that was already encoding"
fi
no_token "$out"

stop_server
cat > "$WORKDIR/golive.json" <<'EOF'
{
  "running": true,
  "broadcast": {"configured": true, "state": "disconnected"},
  "station": {"name": "Test"},
  "queue": [],
  "library": [],
  "history": [],
  "stream": {"listeners": 0}
}
EOF
start_server --status "$WORKDIR/golive.json" --fail-broadcast
out="$(run_ctl windup)"
assert_json "broadcast failure is visible" '.ok == false and (.error | contains("FFmpeg"))' "$out"
no_token "$out"

stop_server
start_server --status "$WORKDIR/golive.json"
out="$(run_ctl windup)"
assert_json "go live" '.ok == true and .live == true' "$out"
grep -q '"operation":"broadcast.start"' "$LOG" || die "wind up did not start the broadcast"

stop_server
start_server --shutdown-mode missing
if run_ctl shutdown >/dev/null 2>&1; then die "old studio shutdown succeeded"; else [ "$?" -eq 95 ]; fi

stop_server
start_server
run_ctl shutdown
ops="$(jq -r 'select(.operation != "") | .operation' "$LOG" | paste -sd' ' -)"
[ "$ops" = "broadcast.stop transport.stop /api/shutdown" ] || die "shutdown order was: $ops"
no_token ""

stop_server
start_server --bad-signature
out="$(run_ctl status)"
assert_json "bad signature" '.reach == "unverified"' "$out"
case "$out" in
  *"Test FM"*) die "an unverified body was kept" ;;
esac
no_token "$out"
stop_server

# A remote start command is a list of words, not a shell line.
marker="$WORKDIR/started"
cat > "$FAKEBIN/remote-start" <<EOF
#!/bin/sh
printf '%s\n' "\$#" "\$1" > "$marker"
EOF
chmod +x "$FAKEBIN/remote-start"
MYRADIO_PORT=9
MYRADIO_START_JSON="$(jq -n --arg bin "$FAKEBIN/remote-start" --arg arg 'hello; rm -rf /' '[$bin, $arg]')"
run_ctl launch
for _ in $(seq 1 20); do
  [ -f "$marker" ] && break
  sleep 0.05
done
[ -f "$marker" ] || die "start command did not run"
[ "$(sed -n '1p' "$marker")" = "1" ] || die "start command was split by a shell"
[ "$(sed -n '2p' "$marker")" = 'hello; rm -rf /' ] || die "start command argument was rewritten"
unset MYRADIO_START_JSON
MYRADIO_START_JSON='{"not":"a list"}'
if run_ctl launch >/dev/null 2>&1; then die "a JSON object was accepted as a start command"; else [ "$?" -eq 91 ]; fi
unset MYRADIO_START_JSON MYRADIO_PORT

printf 'ctl tests passed\n'
