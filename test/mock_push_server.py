#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import argparse
import json
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STOP = threading.Event()
SERVER = None


class Handler(BaseHTTPRequestHandler):
    requests = []
    lock = threading.Lock()
    count_file = None

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

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw.decode() or "{}")

    @classmethod
    def _write_registration_count(cls):
        if cls.count_file is None:
            return
        with cls.lock:
            count = sum(1 for method, path, _ in cls.requests if method == "POST" and path == "/api/push/register")
        with open(cls.count_file, "w", encoding="utf-8") as handle:
            handle.write(f"{count}\n")

    def do_GET(self):
        if self.path == "/api/push/status":
            with Handler.lock:
                registration_count = sum(
                    1 for method, path, _ in Handler.requests if method == "POST" and path == "/api/push/register"
                )
            self._send_json(200, {"registered": registration_count > 0, "registration_count": registration_count})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/push/register":
            body = self._read_json()
            with Handler.lock:
                Handler.requests.append(("POST", self.path, body))
                count = sum(1 for method, path, _ in Handler.requests if method == "POST" and path == "/api/push/register")
            Handler._write_registration_count()
            print(f"REGISTERED:{count}", flush=True)
            self._send_json(
                200,
                {
                    "status": "registered",
                    "bundle_id": body.get("bundle_id"),
                    "token_prefix": str(body.get("device_token", ""))[:8],
                }
            )
            return

        if self.path == "/api/push/test":
            with Handler.lock:
                Handler.requests.append(("POST", self.path, {}))
            print("TEST_PUSH:queued", flush=True)
            self._send_json(200, {"queued": True})
            return

        self._send_json(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path == "/api/push/register":
            with Handler.lock:
                Handler.requests.append(("DELETE", self.path, {}))
            self.send_response(204)
            self.end_headers()
            return
        self._send_json(404, {"error": "not found"})


def handle_signal(_signum, _frame):
    STOP.set()
    if SERVER is not None:
        threading.Thread(target=SERVER.shutdown, daemon=True).start()


def main():
    global SERVER
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8474)
    parser.add_argument("--count-file")
    args = parser.parse_args()

    Handler.count_file = args.count_file
    if Handler.count_file is not None:
        with open(Handler.count_file, "w", encoding="utf-8") as handle:
            handle.write("0\n")

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
