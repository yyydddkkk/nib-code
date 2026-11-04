"""TUI interjections through a PTY and a gated local mock. Run after zig build."""
import contextlib
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import queue
import select
import shlex
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def wait_for(check, description, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if value := check():
            return value
        time.sleep(.02)
    raise AssertionError("timed out: " + description)


class Reply:
    def __init__(self, text="finished", code=None, gated=False):
        self.text, self.code = text, code
        self.received = threading.Event()
        self.release = threading.Event()
        self.messages = None
        if not gated:
            self.release.set()


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, replies):
        self.replies = queue.Queue()
        for reply in replies:
            self.replies.put(reply)
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        reply = self.server.replies.get(timeout=5)
        reply.messages = body["messages"]
        reply.received.set()
        if not reply.release.wait(10):
            return
        delta = {"content": reply.text, "reasoning_content": "mock reasoning"}
        if reply.code is not None:
            delta["tool_calls"] = [{"index": 0, "id": "run1", "type": "function",
                                    "function": {"name": "run", "arguments": json.dumps({"code": reply.code})}}]
        events = [
            {"choices": [{"delta": delta}]},
            {"choices": [{"delta": {}, "finish_reason": "tool_calls" if reply.code else "stop"}],
             "usage": {"prompt_tokens": 100, "completion_tokens": 10}},
        ]
        data = ("".join("data: " + json.dumps(event) + "\n\n" for event in events) + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)


class Terminal:
    def __init__(self, cwd, env):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))

        def controlling_tty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.child = subprocess.Popen([str(BIN)], cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave,
                                      preexec_fn=controlling_tty)
        os.close(slave)
        self.output = b""
        self.until(b"Message nib")

    def read(self):
        while select.select([self.master], [], [], 0)[0]:
            try:
                self.output += os.read(self.master, 65536)
            except OSError:
                break
        return self.output

    def until(self, text):
        try:
            wait_for(lambda: text in self.read(), repr(text))
        except AssertionError:
            raise AssertionError((text, self.child.poll(), self.output[-4000:]))

    def send(self, text):
        os.write(self.master, text.encode())

    def close(self):
        if self.child.poll() is not None:
            return
        self.send("\x03")
        try:
            self.child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait()
        self.read()
        os.close(self.master)
        assert self.child.returncode == 0, self.output[-4000:]


def history(home):
    paths = [path for path in (home / "sessions").glob("*.jsonl") if not path.name.endswith(".calls.jsonl")]
    if not paths:
        return []
    messages = []
    for line in paths[0].read_text().splitlines():
        record = json.loads(line)
        if "messages" in record:
            messages[record["from"]:] = record["messages"]
    return messages


def finished(home, text):
    messages = history(home)
    return messages and messages[-1].get("content") == text


@contextlib.contextmanager
def fixture(tmp, replies):
    tmp.mkdir()
    home = tmp / "home"
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
    with Mock(replies) as mock:
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        env.update(NIB_PROVIDER="chat_completions", NIB_API_KEY="mock",
                   NIB_BASE_URL=f"http://127.0.0.1:{mock.server_port}", NIB_HOME=str(home),
                   HOME=str(tmp), TERM="xterm-256color")
        terminal = Terminal(tmp, env)
        try:
            yield terminal, home, env
        finally:
            terminal.close()
            for reply in replies:
                reply.release.set()
            mock.shutdown()
            thread.join()


def run_code(tmp):
    started, release = tmp / "run-started", tmp / "run-release"
    command = f"touch {shlex.quote(str(started))}; while [ ! -f {shlex.quote(str(release))} ]; do sleep 0.02; done; echo run-result"
    return "await tools.bash({command: " + json.dumps(command) + "})", started, release


def users(messages):
    return [m["content"] for m in messages if m["role"] == "user"]


def test_during_run_and_resume(tmp):
    code, started, release = run_code(tmp)
    first, second, resumed = Reply("running", code=code), Reply("run-finished"), Reply("resumed-finished")
    with fixture(tmp, [first, second, resumed]) as (terminal, home, env):
        terminal.send("initial\r")
        wait_for(started.exists, "Run started")
        terminal.send("interjection one\rinterjection two\r")
        terminal.until(b"queued")
        assert not second.received.is_set(), "must not interrupt the Run"
        release.touch()
        assert second.received.wait(5)
        messages = second.messages
        assert [m["role"] for m in messages[-3:]] == ["tool", "user", "user"], messages
        assert users(messages) == ["initial", "interjection one", "interjection two"]
        assert "run-result" in messages[-3]["content"]
        wait_for(lambda: finished(home, "run-finished"), "committed final Step")
        terminal.until(b"run-finished")
        before = history(home)
        assert [m["role"] for m in before] == ["system", "user", "assistant", "tool", "user", "user", "assistant"]
        terminal.close()
        report = json.loads(subprocess.check_output(["python3", str(ROOT / "scripts/stats.py"),
                                                     str(home / "sessions"), "--json"]))
        assert report["overall"]["turns"] == 1, report["overall"]
        assert report["round_trips"]["steps_per_turn"] == dict(samples=1, median=2, p90=2)
        # The same Session log must replay identically through ask --json, without new event types.
        result = subprocess.run([str(BIN), "ask", "--json", "-c", "after resume"], cwd=tmp, env=env,
                                capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        wire = []
        for message in before:
            message = dict(message)
            if "reasoning" in message:
                message["reasoning_content"] = message.pop("reasoning")["data"]
            message.pop("step_effort", None)
            wire.append(message)
        assert resumed.messages == wire + [{"role": "user", "content": "after resume"}]
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert not any("user_inserted" in event for event in events), events
        assert events[-1]["end"]["text"] == "resumed-finished"


def test_after_final_step(tmp):
    first, second = Reply("first-final", gated=True), Reply("next-final")
    with fixture(tmp, [first, second]) as (terminal, home, _):
        terminal.send("initial\r")
        assert first.received.wait(5)
        terminal.send("next one\rnext two\r")
        terminal.until(b"queued")
        assert not second.received.is_set(), "must not interrupt the model request"
        first.release.set()
        assert second.received.wait(5)
        assert users(second.messages) == ["initial", "next one\n\nnext two"]
        assert second.messages[-2]["content"] == "first-final"
        wait_for(lambda: finished(home, "next-final"), "automatic next Turn")
        assert users(history(home)) == ["initial", "next one\n\nnext two"]


def test_escape_restores_draft(tmp):
    code, started, _ = run_code(tmp)
    first, second = Reply("running", code=code), Reply("resent-final")
    with fixture(tmp, [first, second]) as (terminal, home, _):
        terminal.send("initial\r")
        wait_for(started.exists, "Run started")
        terminal.send("queued one\rqueued two\runsubmitted draft")
        terminal.until(b"queued")
        terminal.send("\x1b")
        terminal.until(b"canceled")
        assert not second.received.is_set(), "Esc must not automatically resend"
        assert users(history(home)) == ["initial"], history(home)
        terminal.send("\r")
        assert second.received.wait(5)
        assert users(second.messages) == ["initial", "queued one\n\nqueued two\n\nunsubmitted draft"]
        wait_for(lambda: finished(home, "resent-final"), "resubmitted restored input")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-interjections-") as directory:
        for test in (test_during_run_and_resume, test_after_final_step, test_escape_restores_draft):
            test(Path(directory) / test.__name__)
            print(test.__name__ + ": ok")
