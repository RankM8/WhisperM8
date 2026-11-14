#!/usr/bin/env python3
"""Winziger Fake-API-Server: beantwortet jede Anfrage mit dem 429 „Limit erreicht“
von Claudes Abo-API. Für WM8-79: Wie verhält sich ein Empfänger am Nutzungslimit?
Loggt nur Methode und Pfad, nie Header (dort steckt das OAuth-Token).

  python3 scripts/claude-peer-fake-limit-server.py <port> <logdatei>
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]

class H(BaseHTTPRequestHandler):
    def _answer(self):
        n = int(self.headers.get("content-length") or 0)
        if n:
            self.rfile.read(n)
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {self.command} {self.path}\n")
        body = json.dumps({"type": "error", "error": {"type": "rate_limit_error",
                           "message": "This request would exceed your account's rate limit. Please try again later."}}).encode()
        self.send_response(429)
        self.send_header("content-type", "application/json")
        self.send_header("x-should-retry", "false")
        self.send_header("anthropic-ratelimit-unified-status", "rejected")
        self.send_header("anthropic-ratelimit-unified-reset", str(int(time.time()) + 3 * 3600))
        self.send_header("anthropic-ratelimit-unified-representative-claim", "five_hour")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = do_HEAD = _answer
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
