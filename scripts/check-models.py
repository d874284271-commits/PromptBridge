#!/usr/bin/env python3
"""Build DraftCoreChecks and exercise ProviderModelsClient against a loopback fixture."""

from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
REQUESTS = Counter()
ERRORS = []
LOCK = threading.Lock()
MARKER = "SECRET_SERVER_BODY fixture-key http://sensitive.invalid/"


def record_error(message):
    with LOCK:
        ERRORS.append(message)


def models(*items):
    return {"data": [{"id": item[0], **({"display_name": item[1]} if len(item) > 1 else {})} for item in items]}


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_bytes(self, body, status=200, *, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "fixture-session=never-resend; Path=/")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        try:
            self.handle_fixture()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # Cancellation can close the socket before the late fixture response.
        except Exception as error:
            record_error("fixture handler: " + repr(error))
            try:
                self.send_bytes(b"{}", 500)
            except OSError:
                pass

    def handle_fixture(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        query = parse_qs(parsed.query, keep_blank_values=True)
        if self.headers.get("Cookie") is not None:
            record_error("a cookie was sent to a fresh or paginated request")
        with LOCK:
            REQUESTS[self.path] += 1

        if path == "/redirect-target":
            record_error("a redirect was followed")
            self.send_bytes(b"{}", 500)
            return
        if path.endswith("/models-redirect"):
            self.send_bytes(b"{}", 307, headers={"Location": f"http://127.0.0.1:{self.server.server_port}/redirect-target"})
            return
        if path.endswith("/models-http401"):
            self.send_bytes(json.dumps({"error": MARKER}).encode(), 401)
            return
        if path.endswith("/models-http404"):
            self.send_bytes(json.dumps({"error": MARKER}).encode(), 404)
            return
        if path.endswith("/models-invalid"):
            self.send_bytes(("{" + MARKER).encode())
            return
        if path.endswith("/models-empty"):
            self.send_bytes(b"")
            return
        if path.endswith("/models-large"):
            self.send_bytes(b" " * 4096)
            return
        if path.endswith("/models-timeout") or path.endswith("/models-cancel"):
            time.sleep(0.8)
            self.send_bytes(json.dumps(models(("late",))).encode())
            return

        if path.endswith("/models-slow-pages"):
            time.sleep(0.08)
            self.send_bytes(json.dumps({"data": [{"id": "first"}], "has_more": True, "last_id": "first"}).encode())
            return

        expected = None
        if path.endswith("/models-auth-chat"):
            expected = ("chat-key", "chat-model", "Bearer")
        elif path.endswith("/models-auth-responses"):
            expected = ("responses-key", "responses-model", "Bearer")
        elif path.endswith("/models-auth-anthropic"):
            expected = ("anthropic-key", "anthropic-model", "Anthropic")
        elif path.endswith("/model"):
            expected = ("models-key", "custom-model", "Bearer")
        elif path.endswith("/models-pages"):
            expected = ("models-key", None, "Bearer")

        if expected is None:
            record_error("unexpected model list path: " + self.path)
            self.send_bytes(b"{}", 404)
            return
        key, model_id, auth_kind = expected
        if auth_kind == "Anthropic":
            if self.headers.get("x-api-key") != key or self.headers.get("Authorization") is not None:
                record_error("wrong Anthropic authentication headers")
            if self.headers.get("anthropic-version") != "2023-06-01":
                record_error("missing Anthropic version header")
        else:
            if self.headers.get("Authorization") != "Bearer " + key or self.headers.get("x-api-key") is not None:
                record_error("wrong Bearer authentication headers")
            if self.headers.get("anthropic-version") is not None:
                record_error("unexpected Anthropic version header")
        if self.headers.get("Accept") != "application/json":
            record_error("wrong Accept header")

        if path.endswith("/models-pages"):
            cursor = query.get("after_id", [None])[0]
            if cursor is None:
                body = models(("first", "First"), ("duplicate",))
                body.update({"has_more": True, "last_id": "cursor-1"})
            elif cursor == "cursor-1":
                body = models(("duplicate", "Duplicate later"), ("second", "Second"))
                body.update({"has_more": False, "last_id": "cursor-1"})
            else:
                record_error("wrong pagination cursor: " + repr(cursor))
                body = {}
            self.send_bytes(json.dumps(body).encode())
            return
        self.send_bytes(json.dumps(models((model_id,))).encode())


def main():
    built = subprocess.run(["swift", "build", "--product", "DraftCoreChecks"], cwd=ROOT, check=False)
    if built.returncode:
        return built.returncode
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    server.daemon_threads = True
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    try:
        checked = subprocess.run(
            [str(ROOT / ".build/debug/DraftCoreChecks"), "--models-base-url", f"http://127.0.0.1:{server.server_port}"],
            cwd=ROOT, check=False, timeout=45,
        )
    finally:
        server.shutdown()
        server.server_close()
        serving.join(timeout=2)

    expected_paths = {
        "/provider/base/models-auth-chat": 1,
        "/provider/base/models-auth-responses": 1,
        "/provider/base/models-auth-anthropic": 1,
        "/provider/base/model": 1,
        "/provider/base/models-pages": 1,
        "/provider/base/models-pages?after_id=cursor-1": 1,
        "/provider/base/models-redirect": 1,
        "/provider/base/models-http401": 1,
        "/provider/base/models-http404": 1,
        "/provider/base/models-invalid": 1,
        "/provider/base/models-empty": 1,
        "/provider/base/models-large": 1,
        "/provider/base/models-timeout": 1,
        "/provider/base/models-slow-pages": 1,
        "/provider/base/models-slow-pages?after_id=first": 1,
        "/provider/base/models-cancel": 1,
    }
    with LOCK:
        observed = dict(REQUESTS)
        errors = list(ERRORS)
    if observed != expected_paths:
        errors.append(f"request coverage mismatch: expected={expected_paths}, observed={observed}")
    for error in errors:
        print("FAIL fixture " + error, file=sys.stderr)
    if not errors:
        print(f"PASS fixture model paths, pagination, auth, cookies, redirects, and request count ({sum(expected_paths.values())} requests)")
    return checked.returncode or bool(errors)


if __name__ == "__main__":
    sys.exit(main())
