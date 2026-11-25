#!/usr/bin/env python3
"""A loopback stand-in for the myradio studio's signed HTTP API.

It checks the same signature the studio checks and signs replies the same way.
It never reads model weights. The control token is a test fixture passed on the
command line, not a real station secret.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

SIGNED_AUTH = re.compile(r"v1 ([0-9a-f]{32}) ([0-9a-f]{64})")
SHA256_HEX = re.compile(r"[0-9a-f]{64}")


def sign(token: str, *parts: str) -> str:
    return hmac.new(token.encode(), "\n".join(parts).encode("latin-1"), hashlib.sha256).hexdigest()


class Studio(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, token: str, status: dict, log_path: Path, shutdown_mode: str, fail_broadcast: bool, bad_signature: bool):
        super().__init__(("127.0.0.1", 0), Handler)
        self.token = token
        self.status = status
        self.log_path = log_path
        self.shutdown_mode = shutdown_mode
        self.fail_broadcast = fail_broadcast
        self.bad_signature = bad_signature
        self.lock = threading.Lock()
        self.challenges: dict[str, float] = {}

    def issue_challenge(self) -> str:
        challenge = secrets.token_hex(16)
        with self.lock:
            self.challenges[challenge] = time.monotonic() + 30
        return challenge

    def redeem(self, challenge: str) -> bool:
        with self.lock:
            until = self.challenges.pop(challenge, None)
        return until is not None and until > time.monotonic()

    def record(self, entry: dict) -> None:
        line = json.dumps(entry, separators=(",", ":")) + "\n"
        with self.lock:
            with self.log_path.open("a", encoding="utf-8") as handle:
                handle.write(line)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "myradio-test"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:
        return

    @property
    def studio(self) -> Studio:
        server = self.server
        assert isinstance(server, Studio)
        return server

    def respond(self, status: int, value, body_hash: str | None = None) -> None:
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        digest = body_hash if body_hash is not None else hashlib.sha256(data).hexdigest()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        signed = getattr(self, "signed", None)
        if signed:
            token = self.studio.token + "x" if self.studio.bad_signature else self.studio.token
            self.send_header(
                "X-Myradio-Response-Auth",
                "v1 " + sign(token, "myradio-v1-response", signed[0], str(status), digest),
            )
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def leaked(self, body: bytes = b"") -> bool:
        token = self.studio.token
        if any(token in key or token in value for key, value in self.headers.items()):
            return True
        return token.encode() in body

    def note(self, body: bytes = b"", operation: str = "") -> None:
        self.studio.record({
            "method": self.command,
            "path": urlsplit(self.path).path,
            "token_header": self.headers.get("X-Myradio-Token") is not None,
            "leaked": self.leaked(body),
            "operation": operation,
        })

    def authorize(self, body: bytes) -> bool:
        match = SIGNED_AUTH.fullmatch(self.headers.get("X-Myradio-Auth", ""))
        body_hash = self.headers.get("X-Myradio-Body-SHA256", "")
        if not match or not SHA256_HEX.fullmatch(body_hash):
            return False
        challenge, signature = match.groups()
        expected = sign(
            self.studio.token,
            "myradio-v1",
            self.command,
            self.path,
            self.headers.get("Host", ""),
            challenge,
            body_hash,
        )
        if not hmac.compare_digest(expected, signature) or not self.studio.redeem(challenge):
            return False
        if not hmac.compare_digest(hashlib.sha256(body).hexdigest(), body_hash):
            return False
        self.signed = (challenge, body_hash)
        return True

    def read_body(self) -> bytes:
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            size = -1
        if size < 0 or size > 32768:
            return b""
        return self.rfile.read(size)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/api/challenge":
            self.note()
            self.respond(200, {"challenge": self.studio.issue_challenge(), "expires_in": 30})
            return
        if not self.authorize(b""):
            self.note()
            self.respond(401, {"error": "Unlock with the launch code from your launcher."})
            return
        self.note()
        if path == "/api/status":
            self.respond(200, self.studio.status)
            return
        if path == "/stream.wav":
            self.stream()
            return
        self.respond(404, {"error": "Not found."})

    def do_POST(self) -> None:
        body = self.read_body()
        if not self.authorize(body):
            self.note(body)
            self.respond(401, {"error": "Unlock with the launch code from your launcher."})
            return
        try:
            payload = json.loads(body.decode() or "{}")
        except (UnicodeError, ValueError):
            payload = {}
        operation = payload.get("operation", "") if isinstance(payload, dict) else ""
        path = urlsplit(self.path).path
        self.note(body, operation if path == "/api/action" else path)
        if path == "/api/login-ticket":
            self.respond(200, {"ticket": secrets.token_urlsafe(32), "expires_in": 60})
            return
        if path == "/api/shutdown":
            if self.studio.shutdown_mode == "missing":
                self.respond(404, {"error": "Not found."})
            else:
                self.respond(200, {"ok": True, "message": "The studio is shutting down."})
            return
        if path != "/api/action":
            self.respond(404, {"error": "Not found."})
            return
        if operation == "transport.start":
            self.studio.status["running"] = True
            self.respond(200, {"ok": True})
            return
        if operation == "transport.stop":
            self.studio.status["running"] = False
            self.respond(200, {"ok": True})
            return
        if operation == "broadcast.stop":
            self.studio.status.setdefault("broadcast", {})["state"] = "disconnected"
            self.respond(200, {"ok": True})
            return
        if operation == "broadcast.start":
            if self.studio.fail_broadcast:
                self.respond(400, {"error": "FFmpeg is not installed. Install an FFmpeg build with libmp3lame, then restart myradio."})
                return
            self.studio.status.setdefault("broadcast", {})["state"] = "streaming"
            self.respond(200, {"ok": True})
            return
        self.respond(200, {"ok": True, "echo": payload})

    def stream(self) -> None:
        header = b"RIFF\xff\xff\xff\xffWAVEfmt "
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Connection", "close")
        signed = getattr(self, "signed", None)
        if signed:
            token = self.studio.token + "x" if self.studio.bad_signature else self.studio.token
            self.send_header(
                "X-Myradio-Response-Auth",
                "v1 " + sign(token, "myradio-v1-response", signed[0], "200", "stream"),
            )
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(header)
            self.wfile.flush()
            while True:
                time.sleep(0.2)
                self.wfile.write(b"\x00" * 32)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            return


def default_status() -> dict:
    return {
        "station": {"name": "Test FM", "tagline": "A test", "auto_fill": True},
        "running": False,
        "elapsed": 3,
        "fading": False,
        "error": None,
        "current": None,
        "queue": [{"id": "q1", "track_id": "t1", "title": "Rain", "artist": "Dial", "duration": 12, "kind": "music"}],
        "library": [{}, {}],
        "history": [],
        "health": {"state": "stopped"},
        "stats": {"on_air_seconds": 90},
        "stream": {"listeners": 2},
        "broadcast": {"configured": False, "state": "disconnected"},
        "extensions": {
            "generation": {
                "state": "running",
                "status": {
                    "configured": True,
                    "paused": False,
                    "headline": "The makers are warming up.",
                    "next_step": "",
                    "capabilities": {"roles": {"song": False, "update": False, "host_break": False, "id": False}},
                    "fixture_roles": [],
                    "jobs": {"queued": 1, "running": 0},
                    "recent": [],
                    "workers": [
                        {"id": "music", "ready": False, "state": "warming", "roles": ["song"]},
                        {"id": "voice", "ready": False, "state": "failed", "roles": ["update"]},
                        {"id": "check", "ready": False, "state": "checking", "roles": ["host_break"]},
                    ],
                },
            },
            "director": {
                "state": "running",
                "status": {
                    "enabled": False,
                    "waiting": 0,
                    "placed": 0,
                    "dropped": 0,
                    "settings": {"every_songs": 4, "station_id_minutes": 30, "news_minutes": 0, "hosts": ["marlowe"]},
                    "requests": [],
                },
            },
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", required=True)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--status", type=Path)
    parser.add_argument("--shutdown-mode", choices=("ok", "missing"), default="ok")
    parser.add_argument("--fail-broadcast", action="store_true")
    parser.add_argument("--bad-signature", action="store_true")
    args = parser.parse_args()
    status = json.loads(args.status.read_text(encoding="utf-8")) if args.status else default_status()
    args.log.write_text("", encoding="utf-8")
    server = Studio(args.token, status, args.log, args.shutdown_mode, args.fail_broadcast, args.bad_signature)
    print(f"PORT {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
