#!/usr/bin/env python3
"""Synthetic native account protocol fixture; binds loopback only and never sends email.

Tests launch their own process/port. State records contract checks and request counts, never
real accounts or user settings. The auth/API stage prefixes intentionally differ.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class AccountFixture(BaseHTTPRequestHandler):
    counts = {}
    checks = []
    mode = "online"
    rotated = False

    def log_message(self, *_):
        pass

    def reply(self, status, value, headers=None):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def record(self):
        state = type(self)
        state.counts[self.path] = state.counts.get(self.path, 0) + 1
        state.checks.append(self.headers.get("Cookie") is None)

    def do_GET(self):
        if self.path == "/fixture/stats":
            return self.reply(200, {"counts": self.counts, "checks": self.checks})
        self.record()
        if self.path != "/api/v1/me":
            return self.reply(404, {"code": "FIXTURE_ROUTE"})
        if self.mode == "offline":
            return self.reply(503, {"code": "SERVICE_UNAVAILABLE", "message": "PRIVATE_BODY_MUST_NOT_APPEAR"})
        if self.mode == "invalid":
            return self.reply(401, {"code": "AUTH_INVALID"})
        if self.mode == "malformed":
            return self.reply(200, {"profile": {"email": "synthetic@example.invalid"}})
        token = self.headers.get("Authorization")
        if token not in ("Bearer synthetic-id", "Bearer synthetic-id-rotated"):
            return self.reply(401, {"code": "AUTH_INVALID"})
        self.reply(200, {"userId": "server-account-surrogate", "canonicalAccountId": "server-account-surrogate",
                         "profile": {"email": "synthetic@example.invalid"}, "selectedWorkspaceId": "ignored-workspace"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path == "/fixture/mode":
            type(self).mode = body["mode"]
            return self.reply(200, {"ok": True})
        self.record()
        type(self).checks.append(self.headers.get("Content-Type") == "application/json")
        if self.path == "/auth/api/send-code":
            if body == {"email": "redirect@example.invalid"}:
                return self.reply(307, {}, {"Location": "/forbidden-redirect"})
            if body == {"email": "oversized@example.invalid"}:
                # No Content-Length: the reader must cap accumulated bytes, not trust headers.
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                try:
                    for _ in range(32):
                        self.wfile.write(b"x" * 65536)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            if body == {"email": "immediate@example.invalid"}:
                return self.reply(200, {"ok": True, "idToken": "synthetic-id", "refreshToken": "synthetic-refresh", "expiresIn": 3600})
            type(self).checks.append(body == {"email": "synthetic@example.invalid"})
            return self.reply(200, {"ok": True, "csrfToken": "synthetic-csrf", "otpSessionToken": "synthetic-otp-session"})
        if self.path == "/auth/api/verify-code":
            type(self).checks.append(body.get("csrfToken") == "synthetic-csrf" and body.get("otpSessionToken") == "synthetic-otp-session")
            codes = {"00000000": "OTP_CODE_INVALID", "99999999": "OTP_SESSION_EXPIRED", "88888888": "OTP_CHALLENGE_CONSUMED"}
            if body.get("code") in codes:
                return self.reply(400, {"code": codes[body["code"]], "message": "PRIVATE_BODY_MUST_NOT_APPEAR"})
            type(self).checks.append(body.get("code") == "12345678")
            return self.reply(200, {"ok": True, "idToken": "synthetic-id", "refreshToken": "synthetic-refresh", "expiresIn": 3600})
        if self.path == "/auth/api/refresh-token":
            if body == {"refreshToken": "synthetic-refresh"} and not self.rotated:
                type(self).rotated = True
                return self.reply(200, {"ok": True, "idToken": "synthetic-id-rotated", "refreshToken": "synthetic-refresh-rotated", "expiresIn": 3600})
            if body == {"refreshToken": "synthetic-refresh-rotated"}:
                return self.reply(200, {"ok": True, "idToken": "synthetic-id-rotated", "expiresIn": 3600})
            return self.reply(401, {"code": "REFRESH_TOKEN_FAILED"})
        self.reply(404, {"code": "FIXTURE_ROUTE"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), AccountFixture)
    print(json.dumps({"port": server.server_port}), flush=True)
    server.serve_forever()
