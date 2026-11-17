"""Local Codex Responses SSE mock. Usage: mock_codex.py PORT LOGFILE.

Only use fabricated credentials: requests (including headers) are logged verbatim.
"timing" streams UTF-8 Run arguments with delays; "timing final only" puts
the same arguments only in response.output_item.done, without argument deltas.
MOCK_CODEX_AUTH names the temporary auth.json rotated by the 'rotate auth' probe.
"""
from mock_http import ThreadingHTTPServer
import http.server
import json
import os
from pathlib import Path
import sys
import threading
import time

from mock_llm_tool import run_code as llm_run_code, serve as serve_llm, serve_effort, codex_run

LOG = open(sys.argv[2], "a")
LOCK = threading.Lock()
ATTEMPTS = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with LOCK:
            LOG.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
            LOG.flush()
            number = sum(ATTEMPTS.values())
        if serve_effort(self, body, "codex"):
            return
        if serve_llm(self, body, "codex"):
            return
        inputs = body.get("input", [])
        users = [item for item in inputs if item.get("role") == "user"]
        def content(item):
            value = item.get("content", "")
            return value if isinstance(value, str) else "".join(part.get("text", "") for part in value)
        prompt = content(users[-1]) if users else ""
        summary = "Summarize the conversation above" in prompt
        summary_empty = summary and any(content(item) == "summary empty" for item in users)
        summary_truncated = summary and any(content(item) == "summary truncated" for item in users)
        with LOCK:
            attempt = ATTEMPTS.get(prompt, 0)
            ATTEMPTS[prompt] = attempt + 1
        if prompt == "reject auth" or (prompt == "rotate auth" and attempt == 0):
            if prompt == "rotate auth":
                Path(os.environ["MOCK_CODEX_AUTH"]).write_text(json.dumps({"tokens": {
                    "access_token": "fake-access-rotated", "account_id": "fake-account-rotated",
                    "refresh_token": "fake-refresh-rotated", "id_token": "fake-id-rotated"}}))
            self.send_response(401)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"unauthorized"}}')
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        sequence = 0
        def event(kind, **fields):
            nonlocal sequence
            data = ("event: " + kind + "\ndata: " + json.dumps({"type": kind, "sequence_number": sequence, **fields}) + "\n\n").encode()
            sequence += 1
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
            self.wfile.flush()
        output = []
        if prompt in ("timing", "timing final only"):
            heartbeat = b": ping\n\n"
            self.wfile.write(b"%x\r\n" % len(heartbeat) + heartbeat + b"\r\n")
            self.wfile.flush()
            time.sleep(.1)
        event("response.created", response={"id": f"resp_{number}", "status": "in_progress", "output": []})
        failure = None
        if prompt == "stream retry server" and attempt == 0:
            failure = ("error", "server_error", "mock transient after deltas")
        elif prompt == "stream context fatal":
            failure = ("response.failed", "context_length_exceeded", "mock context budget exceeded")
        elif prompt == "stream rate exhausted":
            failure = ("response.failed", "rate_limit_exceeded", "mock limit; try again in 20ms")
        elif prompt == "stream rate retry" and attempt == 0:
            failure = ("error", "rate_limit_exceeded", "mock limit; try again in 0.03s")
        elif prompt == "stream retry cancel":
            failure = ("error", "rate_limit_exceeded", "mock limit; try again in 10s")
        if failure or (prompt == "stream retry disconnect" and attempt == 0):
            for text in ("failed attempt prefix", " must not be committed"):
                event("response.output_text.delta", delta=text)
            if failure:
                kind, code, message = failure
                if kind == "error":
                    event(kind, code=code, message=message)
                else:
                    event(kind, response={"status": "failed", "error": {"code": code, "message": message}})
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        if prompt == "interrupt stalled":
            event("response.output_text.delta", item_id=f"msg_{number}", output_index=0, content_index=0, delta="partial answer")
            time.sleep(30)
            return
        if not summary and body.get("reasoning", {}).get("effort") != "none":
            for part in range(2):
                summary_text = "Mock reasoning." if body.get("reasoning", {}).get("summary") == "auto" else ""
                item = {"id": f"rs_{number}_{part}", "type": "reasoning",
                        "summary": [{"type": "summary_text", "text": summary_text}] if summary_text else [],
                        "encrypted_content": f"fake-encrypted-{number}-{part}" + ("x" * 100000 if prompt == "large reasoning" else "")}
                index = len(output)
                event("response.output_item.added", output_index=index, item={"id": item["id"], "type": "reasoning", "summary": []})
                for offset in range(0, len(summary_text), 5):
                    event("response.reasoning_summary_text.delta", item_id=item["id"], output_index=index,
                          summary_index=0, delta=summary_text[offset:offset + 5])
                event("response.output_item.done", output_index=index, item=item)
                output.append(item)
        last = inputs[-1] if inputs else {}
        if summary:
            text = "" if summary_empty else "Earlier work: completed mock tools. Continue the current user request."
        elif (last.get("type") in ("function_call_output", "custom_tool_call_output")
              and not (prompt in ("syntax recovery", "runtime recovery") and "Run script failed" in last["output"])):
            text = "Tool returned: " + last["output"]
        elif prompt.startswith("stream ") or prompt in ("plain text", "large reasoning", "child probe", "rotate auth", "reject auth", "stream incomplete", "stream failed", "stream truncated"):
            text = "Mock text complete."
        else:
            code = 'await tools.bash({command: "echo hello from codex mock"})'
            if prompt == "delegate":
                code = 'await tools.agent({prompt: "child probe"})'
            elif prompt == "bash env":
                code = 'await tools.bash({command: "env | cut -d= -f1 | sort"})'
            elif prompt.startswith("read auth "):
                code = 'try { await tools.read({path: ' + json.dumps(prompt[len("read auth "):]) + '}) } catch (e) { e.message }'
            if prompt in ("timing", "timing final only"):
                code = ('await tools.bash({command: "sleep 0.08; printf 计时🙂"}); '
                        'await tools.write({path: "timing.txt", content: "计时🙂"}); '
                        'await tools.read({path: "timing.txt"})')
            code = llm_run_code(prompt) or code
            if prompt in ("syntax recovery", "runtime recovery"):
                if last.get("type") in ("function_call_output", "custom_tool_call_output"):
                    code = 'await tools.write({path: "recovered.txt", content: "fixed"}); "recovered"'
                else:
                    code = 'const broken = "oops\n";' if prompt == "syntax recovery" else 'throw new Error("runtime probe")'
            index = len(output)
            item = dict(codex_run(body, {"code": code}, f"call_{number}"), id=f"fc_{number}", status="completed")
            if prompt in ("syntax recovery", "runtime recovery") and last.get("type") in ("function_call_output", "custom_tool_call_output"):
                old = 'const broken = "oops\n";' if prompt == "syntax recovery" else 'throw new Error("runtime probe")'
                item = {"type": "function_call", "name": "rerun", "call_id": f"call_{number}",
                        "id": f"fc_{number}", "status": "completed", "arguments": json.dumps({
                            "base": "1:0", "edits": [{"old_text": old, "new_text": code}]})}
            key = "input" if item["type"] == "custom_tool_call" else "arguments"
            kind = "custom_tool_call_input" if key == "input" else "function_call_arguments"
            arguments = item[key]
            if prompt != "timing final only":
                event("response.output_item.added", output_index=index, item={**item, key: "", "status": "in_progress"})
                for offset in range(0, len(arguments), 7):
                    event(f"response.{kind}.delta", item_id=item["id"], output_index=index, delta=arguments[offset:offset + 7])
                    if prompt == "timing":
                        time.sleep(.01)
                event(f"response.{kind}.done", item_id=item["id"], output_index=index, **{key: arguments})
            event("response.output_item.done", output_index=index, item=item)
            output.append(item)
            text = None
        if text is not None:
            index = len(output)
            item = {"id": f"msg_{number}", "type": "message", "role": "assistant", "status": "completed",
                    "phase": "final_answer", "content": [{"type": "output_text", "text": text, "annotations": []}]}
            event("response.output_item.added", output_index=index, item={**item, "content": [], "status": "in_progress"})
            event("response.content_part.added", item_id=item["id"], output_index=index, content_index=0,
                  part={"type": "output_text", "text": "", "annotations": []})
            for offset in range(0, len(text), 9):
                event("response.output_text.delta", item_id=item["id"], output_index=index, content_index=0, delta=text[offset:offset + 9])
            event("response.output_text.done", item_id=item["id"], output_index=index, content_index=0, text=text)
            event("response.output_item.done", output_index=index, item=item)
            output.append(item)
        compacted = any(content(item).startswith("Earlier session summary:") for item in users)
        tokens = 100 if summary or compacted else int(os.environ.get("MOCK_PROMPT_TOKENS", "3300"))
        if prompt == "stream truncated":
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        status = "incomplete" if prompt == "stream incomplete" or summary_truncated else "failed" if prompt == "stream failed" else "completed"
        response = {"id": f"resp_{number}", "status": status, "output": output,
                    "usage": {"input_tokens": tokens, "output_tokens": 20, "input_tokens_details": {"cached_tokens": 64}}}
        if status == "failed":
            response["error"] = {"code": "invalid_prompt", "message": "mock rejected prompt"}
        elif status == "incomplete":
            response["incomplete_details"] = {"reason": "max_output_tokens" if summary_truncated else "usage_not_included"}
        event("response." + status, response=response)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
