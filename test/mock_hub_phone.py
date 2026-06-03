#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
import argparse
import json
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTML = """<!doctype html>
<html><body>
<nav>
  <a href="#today">Today</a>
  <a href="#ask">Ask</a>
</nav>
<script>
const postRoute = () => {
  const bridge = window.webkit?.messageHandlers?.solstone;
  if (!bridge) return;
  const route = window.location.hash.replace(/^#/, '') || 'today';
  bridge.postMessage({ type: 'route', data: { route } });
};

window.addEventListener('load', () => {
  const bridge = window.webkit?.messageHandlers?.solstone;
  if (!bridge) return;
  bridge.postMessage({ type: 'ready' });
  postRoute();
  const stream = new EventSource('/api/stream');
  window.__solstoneStream = stream;
});

window.addEventListener('hashchange', postRoute);
</script>
</body></html>
"""
JSON_ROUTES = {
    "/api/today": {"title": "Today", "items": []},
    "/api/ask": {"questions": []},
}
STOP = threading.Event()
SERVER = None


class Handler(BaseHTTPRequestHandler):
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
        if self.path == "/" or self.path == "/dev/mock-portal":
            self._send_bytes(200, HTML.encode(), "text/html; charset=utf-8")
            return
        if self.path in JSON_ROUTES:
            self._send_json(200, JSON_ROUTES[self.path])
            return
        if self.path == "/api/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                self.wfile.write(b'data: {"type":"status","state":"idle"}\n\n')
                self.wfile.flush()
                while not STOP.wait(5):
                    self.wfile.write(b":keep-alive\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            return
        self._send_json(404, {"error": "not found"})


def handle_signal(_signum, _frame):
    STOP.set()
    if SERVER is not None:
        threading.Thread(target=SERVER.shutdown, daemon=True).start()


def main():
    global SERVER
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7071)
    args = parser.parse_args()
    SERVER = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    print(f"READY:{args.port}", flush=True)
    try:
        SERVER.serve_forever()
    finally:
        STOP.set()
        SERVER.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
