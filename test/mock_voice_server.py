#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import argparse
import json
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STOP = threading.Event()
SERVER = None


class Handler(BaseHTTPRequestHandler):
    nav_hint_calls = 0
    simulate_503 = False

    def log_message(self, format, *args):
        print(format % args, flush=True)

    def _send_bytes(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, status, payload):
        self._send_bytes(status, json.dumps(payload).encode(), "application/json")

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/voice/nav-hints":
            call_id = parse_qs(parsed.query).get("call_id", [""])[0]
            if not call_id:
                self._send_json(400, {"error": "missing call_id"})
                return
            if Handler.nav_hint_calls == 0:
                Handler.nav_hint_calls += 1
                self._send_json(200, {"hints": ["today"], "consumed": True})
            else:
                self._send_json(200, {"hints": [], "consumed": True})
            return
        if parsed.path == "/api/voice/status":
            self._send_json(200, {"brain_ready": True, "brain_age_seconds": 3600})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/voice/session":
            if Handler.simulate_503:
                self._send_json(503, {"error": "voice unavailable — brain not ready"})
            else:
                self._send_json(200, {"ephemeral_key": "ek_test_abc123"})
            return
        if parsed.path == "/api/voice/connect":
            self._send_json(200, {"status": "connected"})
            return
        if parsed.path == "/api/voice/refresh-brain":
            self._send_json(200, {"status": "ok"})
            return
        self._send_json(404, {"error": "not found"})


def handle_signal(_signum, _frame):
    STOP.set()
    if SERVER is not None:
        threading.Thread(target=SERVER.shutdown, daemon=True).start()


def main():
    global SERVER
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7072)
    parser.add_argument("--simulate-503", action="store_true")
    args = parser.parse_args()

    Handler.simulate_503 = args.simulate_503
    SERVER = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    actual_port = SERVER.server_address[1]
    print(f"READY:{actual_port}", flush=True)
    try:
        SERVER.serve_forever()
    finally:
        STOP.set()
        SERVER.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
