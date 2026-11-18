"""Local tools.agent provider mock and observable child-process fault worker."""
from mock_http import ThreadingHTTPServer
import http.server
import json
import os
from pathlib import Path
import shlex
import signal
import sys
import threading
import time

from mock_llm_tool import content

USAGE = {"prompt_tokens": 100, "completion_tokens": 20, "prompt_cache_hit_tokens": 8}


def worker(mode, name):
    parent = os.getppid()
    while parent > 1:
        args = Path(f"/proc/{parent}/cmdline").read_bytes().split(b"\0")
        if b"--agent-input" in args:
            break
        parent = int(Path(f"/proc/{parent}/status").read_text().split("PPid:")[1].split()[0])
    if parent <= 1:
        raise RuntimeError("could not find child nib")

    def terminated(signum, frame):
        Path(name + ".term").write_text(str(signum))
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminated)
    Path(name + ".started").write_text(json.dumps({"worker": os.getpid(), "child": parent}))
    if mode in ("crash", "nonzero"):
        deadline = time.monotonic() + 5
        while not all(Path(peer + ".started").exists() for peer in ("peer-a", "peer-b")):
            if time.monotonic() > deadline:
                raise RuntimeError("peers did not start")
            time.sleep(.01)
        os.kill(parent, signal.SIGKILL if mode == "crash" else signal.SIGTERM)
        return
    if mode == "gate":
        deadline = time.monotonic() + 30
        while not Path(name + ".release").exists():
            if time.monotonic() > deadline:
                raise RuntimeError("worker was not released")
            time.sleep(.01)
    else:
        time.sleep(3 if mode == "peer" else 30)
    Path(name + ".done").write_text("completed")


def parent_code(case):
    if case == "limits-queue":
        return ('await Promise.all(Array.from({length: 5}, (_, i) => '
                'tools.agent({prompt: "agent-child:limits-wait-" + i})))')
    if case == "limits-child":
        return 'await tools.agent({prompt: "agent-child:limits-loop"})'
    if case in ("limits-loop", "limits-default"):
        return "42"
    if case == "limits-budget":
        return ('const text = (await tools.read({path: "budget.txt"})).text; '
                'if (text.length !== 50000) throw new Error("tool data was truncated"); text')
    if case == "changes":
        return 'await tools.agent({prompt: "agent-child:changes"})'
    if case.startswith("parallel:"):
        fault = case.split(":", 1)[1]
        calls = [{"prompt": "agent-child:" + fault, "timeout_ms": 2200 if fault == "timeout" else 10000},
                 {"prompt": "agent-child:peer-a"}, {"prompt": "agent-child:peer-b"}]
        return "await Promise.all(" + json.dumps(calls) + ".map(args => tools.agent(args)))"
    if case == "error":
        return 'await tools.agent({prompt: "agent-child:error"})'
    if case == "empty":
        return 'await tools.agent({prompt: "agent-child:empty"})'
    if case.startswith("options:"):
        options = json.loads(case.split(":", 1)[1])
        return "await tools.agent(" + json.dumps({"prompt": "agent-child:empty", **options}) + ")"
    if case == "invalid":
        invalid = [None, [], {}, {"prompt": 4}, {"prompt": "agent-child:empty", "timeout_ms": 0},
                   {"prompt": "agent-child:empty", "timeout_ms": -1},
                   {"prompt": "agent-child:empty", "timeout_ms": "slow"},
                   {"prompt": "agent-child:empty", "model": 42},
                   {"prompt": "agent-child:empty", "effort": "turbo"},
                   {"prompt": "agent-child:empty", "effort": 42}]
        return ("await Promise.all(" + json.dumps(invalid) +
                '.map(args => tools.agent(args).then(value => ({resolved: true, value}), '
                'error => ({resolved: false, error: error.message}))))')
    if case == "cancel":
        return ('await Promise.all(["cancel-a", "cancel-b", "cancel-c"].map(name => '
                'tools.agent({prompt: "agent-child:" + name}))).then(value => '
                '{console.log("UNEXPECTED_AGENT_RESOLVE"); return value})')
    raise ValueError(case)


def child_code(case, step):
    if case.startswith("limits-wait-"):
        return 'await tools.bash({command: "sleep 0.15"})' if step == 0 else None
    if case == "limits-loop":
        return "42"
    if case == "empty":
        return None
    if case == "changes":
        return [
            'await tools.write(' + json.dumps({"path": "new.txt", "content": "a\nb\n"}) + '); '
            'await tools.edit({path: "existing.txt", old_text: "old", new_text: "new"})',
            'await tools.edit({path: "new.txt", old_text: "b", new_text: "c"}); '
            'await tools.write(' + json.dumps({"path": "existing.txt", "content": "final\n"}) + ')',
            'await tools.read({path: "read-only.txt"}); '
            'await tools.bash({command: "printf bash-only > bash-only.txt"}); '
            'await tools.write(' + json.dumps({"path": "failed-run.txt", "content": "kept\n"}) + '); '
            'throw new Error("expected fixture failure")',
        ][step] if step < 3 else None
    if step == 0:
        return "await tools.write(" + json.dumps({"path": case + ".txt", "content": "partial\n"}) + ")"
    if step == 1 and case != "error":
        mode = "peer" if case.startswith("peer-") else "cancel" if case.startswith("cancel-") else case
        command = shlex.join([sys.executable, str(Path(__file__).resolve()), "--worker", mode, case])
        return "await tools.bash(" + json.dumps({"command": command}) + ")"
    return None


def reply(handler, provider, code, text):
    run_name = "rerun" if isinstance(code, dict) else "run"
    run_args = code if isinstance(code, dict) else {"code": code}
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Transfer-Encoding", "chunked")
    handler.end_headers()
    sequence = 0

    def event(kind=None, **fields):
        nonlocal sequence
        if kind:
            fields = {"type": kind, "sequence_number": sequence, **fields}
        data = (("event: " + kind + "\n" if kind else "") + "data: " + json.dumps(fields) + "\n\n").encode()
        handler.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        sequence += 1

    if provider == "codex":
        event("response.created", response={"id": "agent_response", "status": "in_progress", "output": []})
        message = {"id": "agent_message", "type": "message", "role": "assistant", "status": "completed",
                   "content": [{"type": "output_text", "text": text, "annotations": []}]}
        event("response.output_item.added", output_index=0, item={**message, "content": [], "status": "in_progress"})
        event("response.content_part.added", output_index=0, item_id=message["id"], content_index=0,
              part={"type": "output_text", "text": "", "annotations": []})
        event("response.output_text.delta", output_index=0, item_id=message["id"], content_index=0, delta=text)
        event("response.output_text.done", output_index=0, item_id=message["id"], content_index=0, text=text)
        event("response.output_item.done", output_index=0, item=message)
        output = [message]
        if code is not None:
            item = {"id": "agent_fc", "type": "function_call", "call_id": "agent_call", "name": run_name,
                    "arguments": json.dumps(run_args), "status": "completed"}
            event("response.output_item.added", output_index=1, item={**item, "arguments": "", "status": "in_progress"})
            event("response.function_call_arguments.delta", output_index=1, item_id=item["id"], delta=item["arguments"])
            event("response.function_call_arguments.done", output_index=1, item_id=item["id"], arguments=item["arguments"])
            event("response.output_item.done", output_index=1, item=item)
            output.append(item)
        event("response.completed", response={"id": "agent_response", "status": "completed", "output": output,
              "usage": {"input_tokens": 100, "output_tokens": 20, "input_tokens_details": {"cached_tokens": 8}}})
    else:
        event(choices=[{"delta": {"reasoning_content": "Mock agent step."}}])
        event(choices=[{"delta": {"content": text}}])
        if code is not None:
            event(choices=[{"delta": {"tool_calls": [{"index": 0, "id": "agent_call", "type": "function",
                  "function": {"name": run_name, "arguments": json.dumps(run_args)}}]}}])
        event(choices=[{"delta": {}, "finish_reason": "tool_calls" if code is not None else "stop"}], usage=USAGE)
        handler.wfile.write(b"e\r\ndata: [DONE]\n\n\r\n")
    handler.wfile.write(b"0\r\n\r\n")
    handler.wfile.flush()


def serve(port, logfile):
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            provider = "chat_completions" if "messages" in body else "codex"
            messages = body.get("messages", body.get("input", []))
            prompt = next(content(m) for m in reversed(messages) if m.get("role") == "user")
            step = sum(m.get("role") == "tool" or m.get("type") == "function_call_output" for m in messages)
            with lock, open(logfile, "a") as log:
                log.write(json.dumps({"prompt": prompt, "step": step, "body": body, "at": time.monotonic()}) + "\n")
            if prompt == "agent-child:error" and step == 1:
                error = json.dumps({"error": {"message": "agent mock failure"}}).encode()
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(error)))
                self.end_headers()
                self.wfile.write(error)
                return
            if prompt == "agent-parent:limits-child" and step == 0:
                Path(os.environ["NIB_HOME"], "config.toml").write_text("[limits]\nmax_steps = 0\n")
            if prompt.startswith("agent-parent:"):
                case = prompt.split(":", 1)[1]
                continuing = case in ("limits-loop", "limits-budget") or (case == "limits-default" and step < 59)
                code = parent_code(case) if step == 0 or continuing else None
                text = "parent complete"
            else:
                case = prompt.split(":", 1)[1]
                code = child_code(case, step)
                text = ("prelude:" if code is not None else "done:") + case
            try:
                reply(self, provider, code, text)
            except (BrokenPipeError, ConnectionResetError):
                pass

    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    if sys.argv[1] == "--worker":
        worker(*sys.argv[2:])
    else:
        serve(int(sys.argv[1]), sys.argv[2])
