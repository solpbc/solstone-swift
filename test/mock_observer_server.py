#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import argparse
import json
import os
import re
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STOP = threading.Event()
SERVER = None
EXPECTED_OBSERVER_KEY = "test-observer-key-abc"


class Handler(BaseHTTPRequestHandler):
    lock = threading.Lock()
    count_file = None
    should_fail_create = False
    create_count = 0
    uploads = []

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

    def _require_observer_auth(self):
        if self.headers.get("Authorization") == f"Bearer {EXPECTED_OBSERVER_KEY}":
            return True
        self._send_json(401, {"error": "unauthorized"})
        return False

    def _read_bytes(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _require_ingest_protocol(self):
        if self.headers.get("X-Solstone-Protocol-Version") == "3":
            return True
        self._send_json(426, {"status": "failed", "reason_code": "protocol_version_legacy"})
        return False

    @classmethod
    def _state_payload(cls):
        return {
            "create_count": cls.create_count,
            "upload_count": len(cls.uploads),
            "uploads": cls.uploads,
        }

    @classmethod
    def _write_state_file(cls):
        if cls.count_file is None:
            return
        with open(cls.count_file, "w", encoding="utf-8") as handle:
            json.dump(cls._state_payload(), handle)

    @staticmethod
    def _multipart_parts(body, content_type):
        match = re.search(r'boundary="?([^";]+)"?', content_type)
        if not match:
            return []
        boundary = ("--" + match.group(1)).encode()
        parts = []
        for raw_part in body.split(boundary):
            part = raw_part.strip()
            if not part or part == b"--":
                continue
            if part.endswith(b"--"):
                part = part[:-2]
            part = part.strip(b"\r\n")
            headers, separator, content = part.partition(b"\r\n\r\n")
            if not separator:
                continue
            header_text = headers.decode("utf-8", errors="ignore")
            disposition_match = re.search(r'Content-Disposition:\s*form-data;\s*name="([^"]+)"(?:;\s*filename="([^"]+)")?', header_text)
            if not disposition_match:
                continue
            parts.append(
                {
                    "name": disposition_match.group(1),
                    "filename": disposition_match.group(2),
                    "content": content.rstrip(b"\r\n"),
                }
            )
        return parts

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/observer/status":
            self._send_json(200, Handler._state_payload())
            return
        if path == "/app/devices/ingest/manifest":
            if not self._require_ingest_protocol():
                return
            self._send_json(200, {"days": {}})
            return
        if path.startswith("/app/devices/ingest/manifest/"):
            if not self._require_ingest_protocol():
                return
            day = path.rsplit("/", 1)[-1]
            self._send_json(200, {"version": 1, "day": day, "segments": {}})
            return
        if path.startswith("/app/devices/ingest/segments/"):
            if not self._require_ingest_protocol():
                return
            self._send_json(200, {"protocol_version": 3, "total": 0, "items": []})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/app/devices/register":
            if Handler.should_fail_create:
                self._send_json(500, {"error": "create failed"})
                return
            with Handler.lock:
                Handler.create_count += 1
                Handler._write_state_file()
                count = Handler.create_count
            print(f"OBSERVER_CREATE:{count}", flush=True)
            self._send_json(200, {"name": "solstone-swift", "key": EXPECTED_OBSERVER_KEY, "prefix": "obs_"})
            return

        if self.path == "/app/observer/ingest/event":
            if not self._require_observer_auth():
                return
            self._read_bytes()
            self._send_json(200, {"ok": True})
            return

        if self.path == "/app/devices/health":
            if not self._require_observer_auth():
                return
            self._read_bytes()
            self._send_json(200, {"ok": True})
            return

        if self.path == "/app/devices/ingest":
            if not self._require_ingest_protocol():
                return
            body = self._read_bytes()
            parts = self._multipart_parts(body, self.headers.get("Content-Type", ""))
            envelopes = [part for part in parts if part["name"] == "envelope" and part["filename"] is None]
            files = [part for part in parts if part["name"] == "files" and part["filename"] is not None]
            if len(envelopes) != 1:
                self._send_json(400, {"status": "failed", "reason_code": "field_missing"})
                return
            try:
                envelope = json.loads(envelopes[0]["content"].decode("utf-8"))
                submitted = [entry["submitted"] for entry in envelope["files"]]
            except (KeyError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
                self._send_json(400, {"status": "failed", "reason_code": "envelope_invalid"})
                return
            filenames = [part["filename"] for part in files]
            if len(submitted) != len(files) or sorted(submitted) != sorted(filenames):
                self._send_json(400, {"status": "failed", "reason_code": "file_name_mismatch"})
                return
            if "audio.m4a" not in submitted:
                self._send_json(400, {"status": "failed", "reason_code": "file_name_mismatch"})
                return
            upload = {
                "segment": envelope.get("segment"),
                "day": envelope.get("day"),
                "file_count": len(files),
                "filename": "audio.m4a",
                "protocol_version": self.headers.get("X-Solstone-Protocol-Version"),
                "authorization": self.headers.get("Authorization"),
            }
            with Handler.lock:
                Handler.uploads.append(upload)
                Handler._write_state_file()
                upload_count = len(Handler.uploads)
            print(f"OBSERVER_UPLOAD:{upload_count}:{upload['filename']}", flush=True)
            self._send_json(200, {"status": "ok"})
            return

        self._send_json(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path.startswith("/app/devices/source/"):
            if not self._require_observer_auth():
                return
            source = self.path.removeprefix("/app/devices/source/")
            self._send_json(200, {"ok": True, "source": source})
            return

        self._send_json(404, {"error": "not found"})


def handle_signal(_signum, _frame):
    STOP.set()
    if SERVER is not None:
        threading.Thread(target=SERVER.shutdown, daemon=True).start()


def main():
    global SERVER
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8575)
    parser.add_argument("--count-file")
    args = parser.parse_args()

    Handler.count_file = args.count_file
    Handler.should_fail_create = os.environ.get("MOCK_OBSERVER_SHOULD_FAIL_CREATE") == "1"
    if Handler.count_file is not None:
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
