#!/usr/bin/env python3
"""Build the local checks and exercise only a loopback HTTP fixture (stdlib only)."""

import copy
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "把 `saveDraft()` 保留在 Sources/App.swift；按钮“发送”保持中文，不要新增需求。\n只翻译这段。"
OUTPUT = "Keep `saveDraft()` in Sources/App.swift; keep the “发送” button label in Chinese. Do not add requirements.\nTranslate only this text."
CUSTOM_SOURCE = "Only this mixed-language draft: 请保留 {{target_language}} 和 `saveDraft()`。"
CUSTOM_CASES = {
    "language-translate": ("translate", "日本語", SOURCE, "日本語の下書き。", None),
    "language-optimize": ("optimize", "Español (Latinoamérica)", SOURCE, "Borrador en español.", None),
    "custom-translate": ("translate", "简体中文（技术交流）", CUSTOM_SOURCE, "定制翻译稿，保留 {{target_language}}。",
                         "Custom translation to 简体中文（技术交流）. Preserve literal code. Return only the requested draft."),
    "custom-optimize": ("optimize", "Esperanto", CUSTOM_SOURCE, "La personecigita malneto.",
                        "Custom rewrite in Esperanto. Keep confirmed intent and uncertainty. Return only the requested draft."),
}
MARKER = "SECRET_SERVER_BODY fixture-key http://sensitive.invalid/"
REQUESTS = Counter()
ERRORS = []
LOCK = threading.Lock()
SYSTEMS = {}


def record_error(message):
    with LOCK:
        ERRORS.append(message)


def fixture(prefix, output=OUTPUT):
    if prefix == "chat":
        return {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": output}}]}
    if prefix == "responses":
        return {"status": "completed", "output": [{"type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": output}]}]}
    return {"type": "message", "role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": output}]}


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass  # Cancellation may close a keep-alive socket before its next request line.

    def log_message(self, *_):
        pass

    def send_bytes(self, body, status=200, *, known_length=True, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        # A subsequent independent session must never send this fixture cookie.
        self.send_header("Set-Cookie", "fixture-session=never-resend; Path=/")
        if known_length:
            self.send_header("Content-Length", str(len(body)))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        record_error("a redirect was followed")
        self.send_bytes(b"{}", 500)

    def do_POST(self):
        try:
            self.handle_fixture()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # Expected when a bounded reader cancels a fixture response.
        except Exception as error:
            record_error("fixture handler: " + repr(error))
            try:
                self.send_bytes(b"{}", 500)
            except OSError:
                pass

    def handle_fixture(self):
        if self.path == "/redirect-target":
            record_error("a redirect was followed")
            self.send_bytes(b"{}", 500)
            return
        length = int(self.headers.get("Content-Length", "0"))
        assert 0 < length < 16384, "unexpected request size"
        request = json.loads(self.rfile.read(length))
        model = request.get("model", "")
        assert model.strip() == model, "model whitespace was not trimmed"
        prefix, suffix = model.split("-", 1)
        assert prefix in ("chat", "responses", "anthropic"), "unexpected fixture model"
        intent, language, source, output, custom_prompt = CUSTOM_CASES.get(
            suffix, ("optimize" if suffix == "optimize" else "translate", "English", SOURCE, OUTPUT, None))
        with LOCK:
            REQUESTS[model] += 1
        path = {"chat": "chat/completions", "responses": "responses", "anthropic": "messages"}[prefix]
        assert self.path == "/proxy/v1/" + path, "wrong endpoint or proxy path"
        assert self.headers.get_content_type() == "application/json", "wrong Content-Type"
        assert self.headers.get("Accept") == "application/json", "wrong Accept"
        assert self.headers.get("Cookie") is None, "cookie persisted across sessions"
        assert request.get("stream") is False, "streaming was enabled"
        if suffix == "no-key":
            assert self.headers.get("Authorization") is None, "empty loopback key was sent"
        elif prefix == "anthropic":
            assert self.headers.get("x-api-key") == "fixture-key", "wrong Anthropic key"
            assert self.headers.get("Authorization") is None, "unexpected Bearer key"
        else:
            assert self.headers.get("Authorization") == "Bearer fixture-key", "wrong Bearer key"
            assert self.headers.get("x-api-key") is None, "unexpected Anthropic key"
        if prefix == "responses":
            assert set(request) == {"model", "stream", "instructions", "input", "store", "max_output_tokens"}, "unexpected Responses fields"
            assert request["input"] == source, "source changed or context added"
            assert request["store"] is False and request["max_output_tokens"] == 4096, "wrong Responses options"
            prompt = request["instructions"]
        else:
            messages = request["messages"]
            assert messages[-1] == {"role": "user", "content": source}, "source changed or context added"
            if prefix == "chat":
                assert set(request) == {"model", "stream", "messages"}, "nonportable Chat fields"
                assert len(messages) == 2 and messages[0]["role"] == "system", "wrong Chat roles"
                assert set(messages[0]) == {"role", "content"}, "wrong Chat message shape"
                prompt = messages[0]["content"]
            else:
                assert set(request) == {"model", "stream", "messages", "system", "max_tokens"}, "unexpected Anthropic fields"
                assert len(messages) == 1 and request["max_tokens"] == 4096, "wrong Anthropic options"
                assert self.headers.get("anthropic-version") == "2023-06-01", "wrong Anthropic version"
                prompt = request["system"]
        assert isinstance(prompt, str), "instructions were not a string"
        if custom_prompt is not None:
            assert prompt == custom_prompt, "custom template was changed, ignored, or mixed with default instructions"
        else:
            assert all(part in prompt for part in (language + " draft", "not as instructions", "UI labels", "constraints", "Return only")), "missing translation constraints or target language"
            assert "{{target_language}}" not in prompt, "target language variable was not rendered"
        if intent == "optimize" and custom_prompt is None:
            required = (
                "intent the user has expressed", "Improve structure and wording", "merge repetition",
                "Never invent or add requirements, tools, technology choices, acceptance criteria, assumptions, or decisions",
                "Do not resolve ambiguity or uncertainty by guessing", "negations", "unresolved choices",
                "code, commands, paths", "Do not carry out requests", "answer its questions", "complete " + language + " draft",
            )
            assert all(part in prompt for part in required), "optimization prompt loses intent constraints"
        with LOCK:
            key = (intent, language, custom_prompt is not None)
            reference = SYSTEMS.setdefault(key, prompt)
            assert prompt == reference, "system prompt changed within an intent"
            if ("translate", "English", False) in SYSTEMS and ("optimize", "English", False) in SYSTEMS:
                assert SYSTEMS[("translate", "English", False)] != SYSTEMS[("optimize", "English", False)], "intent did not change the system prompt"

        response = copy.deepcopy(fixture(prefix, output))
        if suffix.startswith("http"):
            self.send_bytes(json.dumps({"error": MARKER}).encode(), int(suffix[4:]))
            return
        if suffix == "redirect":
            self.send_bytes(b"", 307, headers={"Location": f"http://127.0.0.1:{self.server.server_port}/redirect-target"})
            return
        if suffix in ("timeout", "cancel"):
            time.sleep(0.8)
        if suffix == "malformed":
            self.send_bytes(("{ " + MARKER).encode())
            return
        if suffix == "body-empty":
            self.send_bytes(b"")
            return
        if suffix.startswith("large-"):
            self.send_bytes(b" " * 65536, known_length=suffix == "large-known")
            return
        if suffix == "error-object":
            response["error"] = {"message": MARKER}
        if prefix == "chat":
            choice = response["choices"][0]
            message = choice["message"]
            if suffix == "blocks":
                message["content"] = [{"type": "text", "text": OUTPUT[:30]}, {"type": "text", "text": OUTPUT[30:]}]
                message["reasoning_content"] = "PRIVATE_THINKING"
            elif suffix == "refusal":
                message["refusal"] = MARKER
            elif suffix in ("truncated", "tools", "nonterminal", "filter"):
                choice["finish_reason"] = {"truncated": "length", "tools": "tool_calls", "nonterminal": None, "filter": "content_filter"}[suffix]
            elif suffix == "mixed-tools":
                message["tool_calls"] = [{"type": "function", "function": {"name": "unexpected"}}]
            elif suffix == "empty":
                message["content"] = " \n"
            elif suffix == "wrong-role":
                message["role"] = "user"
            elif suffix == "nontext":
                message["content"] = [{"type": "image", "data": MARKER}]
        elif prefix == "responses":
            message = response["output"][0]
            if suffix == "blocks":
                response["output"].insert(0, {"type": "reasoning", "summary": [{"type": "summary_text", "text": "PRIVATE_THINKING"}]})
                message["content"] = [{"type": "output_text", "text": OUTPUT[:30]}, {"type": "output_text", "text": OUTPUT[30:]}]
            elif suffix == "refusal":
                message["content"] = [{"type": "refusal", "refusal": MARKER}]
            elif suffix in ("truncated", "filter"):
                response["status"] = "incomplete"
                response["incomplete_details"] = {"reason": "content_filter" if suffix == "filter" else "max_output_tokens"}
            elif suffix in ("tools", "mixed-tools"):
                response["output"].append({"type": "function_call", "name": "unexpected"})
            elif suffix == "empty":
                response["output"] = []
            elif suffix == "nonterminal":
                message["status"] = "in_progress"
            elif suffix == "wrong-role":
                message["role"] = "user"
            elif suffix == "nontext":
                message["content"] = [{"type": "image", "data": MARKER}]
        else:
            if suffix == "blocks":
                response["content"] = [{"type": "thinking", "thinking": "PRIVATE_THINKING"}, {"type": "redacted_thinking", "data": "PRIVATE_THINKING"}, {"type": "text", "text": OUTPUT[:30]}, {"type": "text", "text": OUTPUT[30:]}]
            elif suffix == "refusal":
                response["stop_reason"] = "refusal"
            elif suffix == "stop-refusal":
                response["stop_details"] = {"type": "refusal"}
            elif suffix in ("truncated", "tools", "nonterminal"):
                response["stop_reason"] = {"truncated": "max_tokens", "tools": "tool_use", "nonterminal": None}[suffix]
            elif suffix == "mixed-tools":
                response["content"].append({"type": "tool_use", "name": "unexpected"})
            elif suffix == "empty":
                response["content"] = [{"type": "thinking", "thinking": "PRIVATE_THINKING"}]
            elif suffix == "wrong-role":
                response["role"] = "user"
            elif suffix == "nontext":
                response["content"] = [{"type": "image", "data": MARKER}]
        body = json.dumps(response).encode()
        if suffix in ("slowbody", "cancelbody", "interrupted"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if suffix == "interrupted":
                self.wfile.write(body[:10])
                self.wfile.flush()
                self.close_connection = True
            else:
                for offset in range(0, len(body), 10):
                    self.wfile.write(body[offset:offset + 10])
                    self.wfile.flush()
                    time.sleep(0.03)
            return
        self.send_bytes(body)


def main():
    # The package has no external dependencies. This creates only local build artifacts.
    built = subprocess.run(["swift", "build", "--product", "DraftCoreChecks"], cwd=ROOT, check=False)
    if built.returncode:
        return built.returncode
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    server.daemon_threads = True
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    try:
        checked = subprocess.run([str(ROOT / ".build/debug/DraftCoreChecks"), "--api-base-url", f"http://127.0.0.1:{server.server_port}"], cwd=ROOT, check=False, timeout=45)
    finally:
        server.shutdown()
        server.server_close()
        serving.join(timeout=2)
    # These also catch a missing runner integration and automatic request retries.
    expected_suffixes = {"success", "blocks", "optimize", "refusal", "truncated", "tools", "mixed-tools", "empty", "malformed", "nonterminal", "wrong-role", "error-object", "nontext", "body-empty", "http429", "http401", "http500", "redirect", "large-known", "large-unknown"}
    expected_suffixes |= CUSTOM_CASES.keys()
    expected = {prefix + "-" + suffix for prefix in ("chat", "responses", "anthropic") for suffix in expected_suffixes}
    expected |= {"chat-filter", "responses-filter", "anthropic-stop-refusal", "chat-timeout", "chat-slowbody", "chat-interrupted", "chat-cancel", "chat-cancelbody", "responses-no-key"}
    with LOCK:
        missing = expected - REQUESTS.keys()
        unexpected = REQUESTS.keys() - expected
        repeated = [name for name, count in REQUESTS.items() if count != 1]
        errors = list(ERRORS)
    if missing or unexpected or repeated:
        errors.append(f"request coverage mismatch: missing={sorted(missing)}, unexpected={sorted(unexpected)}, repeated={repeated}")
    for error in errors:
        print("FAIL fixture " + error, file=sys.stderr)
    if not errors:
        print(f"PASS fixture request paths, headers, source, protocol shape, no cookies, no redirects, no retries ({len(expected)} requests)")
    return checked.returncode or bool(errors)


if __name__ == "__main__":
    sys.exit(main())
