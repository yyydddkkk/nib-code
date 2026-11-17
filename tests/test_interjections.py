"""TUI interjections through a PTY and a gated local mock. Run after zig build."""
import contextlib
import fcntl
from mock_http import ThreadingHTTPServer, is_prediction
import http.server
import json
import os
from pathlib import Path
import pty
import queue
import re
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"
sys.path.insert(0, str(ROOT / "scripts"))
from screen import screen


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


class Mock(ThreadingHTTPServer):
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
        if is_prediction(body):
            return self.send_error(400)
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

        # Acquire the controlling TTY after exec; preexec_fn can deadlock after threads start.
        bootstrap = "import fcntl, os, sys, termios; fcntl.ioctl(0, termios.TIOCSCTTY, 0); os.execv(sys.argv[1], sys.argv[1:])"
        self.child = subprocess.Popen([sys.executable, "-c", bootstrap, str(BIN)], cwd=cwd, env=env,
                                      stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        self.output = b""
        self.output_changed = threading.Condition()
        self.reader_stop = threading.Event()
        self.reader = threading.Thread(target=self.drain, daemon=True)
        self.reader.start()
        self.until(b"Ask about this project")

    def drain(self):
        while not self.reader_stop.is_set():
            if not select.select([self.master], [], [], .05)[0]:
                continue
            try:
                chunk = os.read(self.master, 65536)
                if not chunk:
                    break
                with self.output_changed:
                    self.output += chunk
                    self.output_changed.notify_all()
            except OSError:
                break

    def read(self):
        return self.output

    def until(self, text):
        with self.output_changed:
            if not self.output_changed.wait_for(lambda: text in self.output, timeout=10):
                raise AssertionError((text, self.child.poll(), self.output[-4000:]))

    def wait_turn(self, text):
        # The bill is appended only after the TUI consumes Turn completion.
        with self.output_changed:
            def rendered():
                visible = "\n".join(screen(self.output, 120, 32))
                start = visible.rfind(text)
                return (start >= 0 and
                        re.search(r"\d+ steps?.*?tokens", visible[start + len(text):], re.S))
            if not self.output_changed.wait_for(rendered, timeout=10):
                raise AssertionError((text, self.child.poll(), screen(self.output, 120, 32)))

    def send(self, text):
        os.write(self.master, text.encode())

    def close(self):
        if self.master is None:
            return
        if self.child.poll() is None:
            self.send("\x03")
            self.send("\x03")
            deadline = time.monotonic() + 5
            while self.child.poll() is None and time.monotonic() < deadline:
                time.sleep(.02)
            if self.child.poll() is None:
                self.child.kill()
        self.reader_stop.set()
        self.reader.join()
        os.close(self.master)
        self.master = None
        self.child.wait(timeout=5)
        assert self.child.returncode == 0, self.output[-4000:]


def history(home):
    paths = list((home / "sessions").glob("[0-9a-f]" * 32 + ".jsonl"))
    if not paths:
        return []
    messages = []
    for line in paths[0].read_bytes().split(b"\n")[:-1]:
        record = json.loads(line)
        if record.get("messages"):
            messages[record["from"]:] = record["messages"]
    return messages


def finished(home, text):
    messages = history(home)
    return messages and messages[-1].get("content") == text


@contextlib.contextmanager
def fixture(tmp, replies, config=None, provider="chat_completions", environment=None):
    tmp.mkdir()
    home = tmp / "home"
    if config:
        home.mkdir()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
    with Mock(replies) as mock:
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{mock.server_port}"
        if config:
            (home / "config.toml").write_text(config.replace("{url}", url))
        env.update(NIB_PROVIDER=provider, NIB_API_KEY="mock",
                   NIB_BASE_URL=url, NIB_HOME=str(home),
                   HOME=str(tmp), TERM="xterm-256color", NIB_TUNE="delivery=user")
        env.update(environment or {})
        terminal = Terminal(tmp, env)
        try:
            yield terminal, home, env
        finally:
            terminal.close()
            for reply in replies:
                reply.release.set()
            mock.shutdown()
            thread.join()


def wait_queued(terminal, *texts):
    # Interjections typed in one write reach the TUI one Enter at a time; release only after all are queued.
    def all_queued():
        lines = screen(terminal.read(), 120, 32)
        return all(any(line.rstrip().endswith(f"{text} · queued") for line in lines) for text in texts)
    wait_for(all_queued, "queued: " + ", ".join(texts))


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
        wait_queued(terminal, "interjection one", "interjection two")
        assert not second.received.is_set(), "must not interrupt the Run"
        release.touch()
        assert second.received.wait(5)
        messages = second.messages
        assert [m["role"] for m in messages[-3:]] == ["tool", "user", "user"], messages
        assert users(messages) == ["initial", "interjection one", "interjection two"]
        assert "run-result" in messages[-3]["content"]
        wait_for(lambda: finished(home, "run-finished"), "committed final Step")
        terminal.wait_turn("run-finished")
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
            message.pop("tool_summary", None)
            message.pop("step_calls_omitted", None)
            message.pop("run_ok", None)
            message.pop("bash_replacements", None)
            if message["role"] == "tool":
                message.pop("background_id", None)
            wire.append(message)
        expected = wire + [{"role": "user", "content": "after resume"}]
        assert resumed.messages == expected, (resumed.messages, expected)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert not any("user_inserted" in event for event in events), events
        assert events[-1]["end"]["text"] == "resumed-finished"


def test_during_run_tool_delivery(tmp):
    code, started, release = run_code(tmp)
    first, second = Reply("running", code=code), Reply("run-finished")
    with fixture(tmp, [first, second], environment={"NIB_TUNE": "delivery=tool"}) as (terminal, home, _):
        terminal.send("initial\r")
        wait_for(started.exists, "Run started")
        terminal.send("interjection one\rinterjection two\r")
        wait_queued(terminal, "interjection one", "interjection two")
        release.touch()
        assert second.received.wait(5)
        messages = second.messages
        assert messages[-1]["role"] == "tool", messages
        assert users(messages) == ["initial"], messages
        content = messages[-1]["content"]
        assert content.index("run-result") < content.index("[user message]\ninterjection one") < content.index("[user message]\ninterjection two"), content
        wait_for(lambda: finished(home, "run-finished"), "committed final Step")
        terminal.wait_turn("run-finished")
        assert users(history(home)) == ["initial"]


def test_after_final_step_tool_delivery(tmp):
    first, second = Reply("first-final", gated=True), Reply("next-final")
    with fixture(tmp, [first, second], environment={"NIB_TUNE": "delivery=tool"}) as (terminal, home, _):
        terminal.send("initial\r")
        assert first.received.wait(5)
        terminal.send("next one\r")
        wait_queued(terminal, "next one")
        first.release.set()
        assert second.received.wait(5)
        assert users(second.messages) == ["initial", "next one"]
        wait_for(lambda: finished(home, "next-final"), "automatic next Turn")


def test_after_final_step(tmp):
    first, second = Reply("first-final", gated=True), Reply("next-final")
    with fixture(tmp, [first, second]) as (terminal, home, _):
        terminal.send("initial\r")
        assert first.received.wait(5)
        terminal.send("next one\rnext two\r")
        wait_queued(terminal, "next one", "next two")
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
        wait_queued(terminal, "queued one", "queued two")
        terminal.send("\x1b")
        terminal.until(b"Canceled")
        assert not second.received.is_set(), "Esc must not automatically resend"
        assert users(history(home)) == ["initial"], history(home)
        terminal.send("\r")
        assert second.received.wait(5)
        assert users(second.messages) == ["initial", "queued one\n\nqueued two\n\nunsubmitted draft"]
        wait_for(lambda: finished(home, "resent-final"), "resubmitted restored input")


def test_busy_slash_notice(tmp):
    tmp.mkdir()
    for name, command in (("model", "/model openai/gpt-6.1-terra"),
                          ("compact", "/compact")):
        gated = Reply("busy-finished", gated=True)
        with fixture(tmp / name, [gated]) as (terminal, home, _):
            terminal.send("initial\r")
            assert gated.received.wait(5)
            terminal.send(command)
            terminal.send("\r")
            terminal.until("Turn running · retry command when it ends".encode())
            assert command in "\n".join(screen(terminal.read(), 120, 32))
            assert not gated.release.is_set()
            gated.release.set()
            terminal.wait_turn("busy-finished")
            terminal.send("\x15/help\r")
            terminal.until(b"/help")


def test_reflect_disabled(tmp):
    tmp.mkdir()
    for name, environment in (("unset", {}), ("off", {"NIB_ISSUE_REPO": "off"})):
        with fixture(tmp / name, [], environment=environment) as (terminal, _, _):
            terminal.send("/reflect\r")
            terminal.until(b"unknown command /reflect")


def test_tool_bytes_bill(tmp):
    code = "await Promise.all([tools.read({path:'a.txt'}), tools.read({path:'b.txt'})]); 'ok'"
    with fixture(tmp, [Reply("reading", code=code), Reply("bytes-final")]) as (terminal, home, _):
        (tmp / "a.txt").write_text("你" * 16000)
        (tmp / "b.txt").write_text("x" * 48000)
        terminal.send("measure tool bytes\r")
        wait_for(lambda: finished(home, "bytes-final"), "byte measurement final Step")
        terminal.until("tool data 96kB → 12B".encode())
        assert terminal.child.poll() is None
        records = [json.loads(line) for path in (home / "sessions").glob("*.jsonl")
                   for line in path.read_text().splitlines()]
        assert sum(record.get("tool_bytes", 0) for record in records) == 96060
        assert sum(record.get("output_bytes", 0) for record in records) == 12


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-interjections-") as directory:
        for test in (test_reflect_disabled, test_busy_slash_notice, test_during_run_and_resume, test_during_run_tool_delivery, test_after_final_step, test_after_final_step_tool_delivery, test_escape_restores_draft, test_tool_bytes_bill):
            test(Path(directory) / test.__name__)
            print(test.__name__ + ": ok")
