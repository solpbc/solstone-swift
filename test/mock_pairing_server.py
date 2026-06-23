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
    lock = threading.Lock()
    count_file = None
    confirm_count = 0
    briefing_updates = []
    unpair_count = 0
    push_register_count = 0
    push_deregister_count = 0
    last_push_payload = None

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
    def _write_state_file(cls):
        if cls.count_file is None:
            return
        with open(cls.count_file, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "confirm_count": cls.confirm_count,
                    "briefing_updates": cls.briefing_updates,
                    "unpair_count": cls.unpair_count,
                    "push_register_count": cls.push_register_count,
                    "push_deregister_count": cls.push_deregister_count,
                    "last_push_payload": cls.last_push_payload,
                },
                handle,
            )

    def do_POST(self):
        if self.path == "/api/pairing/confirm":
            body = self._read_json()
            with Handler.lock:
                Handler.confirm_count += 1
                Handler._write_state_file()
                count = Handler.confirm_count
            print(f"PAIR_CONFIRM:{count}", flush=True)
            self._send_json(
                200,
                {
                    "session_key": "pair-session-test",
                    "device_id": "device-123",
                    "journal_root": f"http://127.0.0.1:{self.server.server_address[1]}",
                    "owner_identity": "sol",
                    "server_version": "mock-pairing-server",
                    "echo_token": body.get("token"),
                },
            )
            return

        if self.path == "/api/push/register":
            body = self._read_json()
            with Handler.lock:
                Handler.push_register_count += 1
                Handler.last_push_payload = body
                Handler._write_state_file()
                count = Handler.push_register_count
            print(f"PUSH_REGISTER:{count}", flush=True)
            self._send_json(200, {"ok": True})
            return

        self._send_json(404, {"error": "not found"})

    def do_PUT(self):
        if self.path == "/api/settings/briefing-time":
            body = self._read_json()
            with Handler.lock:
                Handler.briefing_updates.append(body)
                Handler._write_state_file()
            print("BRIEFING_TIME:saved", flush=True)
            self._send_json(200, {"ok": True})
            return

        self._send_json(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/api/pairing/status":
            self._send_json(
                200,
                {
                    "confirm_count": Handler.confirm_count,
                    "briefing_updates": Handler.briefing_updates,
                    "unpair_count": Handler.unpair_count,
                    "push_register_count": Handler.push_register_count,
                    "push_deregister_count": Handler.push_deregister_count,
                    "last_push_payload": Handler.last_push_payload,
                },
            )
            return

        self._send_json(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path == "/api/push/register":
            with Handler.lock:
                Handler.push_deregister_count += 1
                Handler._write_state_file()
            self.send_response(204)
            self.end_headers()
            return

        if self.path.startswith("/api/pairing/devices/"):
            with Handler.lock:
                Handler.unpair_count += 1
                Handler._write_state_file()
                count = Handler.unpair_count
            print(f"UNPAIR:{count}", flush=True)
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
    parser.add_argument("--port", type=int, default=8676)
    parser.add_argument("--count-file")
    args = parser.parse_args()

    Handler.count_file = args.count_file
    Handler._write_state_file()

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
