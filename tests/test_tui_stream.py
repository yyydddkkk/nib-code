"""Incremental TUI output through a PTY, including a paused stream and live input."""
import contextlib
import json
import random
import sys
from pathlib import Path
import tempfile
import threading
import time
from unittest.mock import patch

from test_interjections import Handler, Reply, fixture, finished, history, wait_for

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from screen import screen


# Incrementality is asserted by ordering (text and input appear while the response is still open, gated by the mock).
# Wall-clock bounds only catch stalls: tight ones measure the CI host's CPU contention, not nib.
STALL = 1.0


class StreamReply(Reply):
    def __init__(self):
        self.prefix = "STREAM_BEGIN "
        rng = random.Random(17)
        answer = ("word English 中文 👩‍💻 🙂 **late bold\n- list `inline\n```zig\n" +
                  "const value = 123; // 中文\n" * 150 + "```\nclose` bold**\n") * 12
        answer = answer[:30000]
        self.chunks = []
        while answer:
            n = rng.randint(1, 500)
            self.chunks.append(answer[:n])
            answer = answer[n:]
        self.gaps = [rng.choice([0, .001, .016, .040, .400]) for _ in self.chunks]
        self.tail = " PAUSED_TAIL"
        self.end = " STREAM_END"
        super().__init__(self.prefix + "".join(self.chunks) + self.tail + self.end, gated=True)
        self.reasoning_done = threading.Event()
        self.continue_stream = threading.Event()
        self.paused = threading.Event()
        self.elapsed = 0
        self.sent_chars = 0


class StreamHandler(Handler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        reply = self.server.replies.get(timeout=5)
        reply.messages = body["messages"]
        reply.received.set()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(event):
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()

        def text(value):
            emit({"choices": [{"delta": {"content": value}}]})

        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            emit({"choices": [{"delta": {"reasoning_content": "hidden thinking"}}]})
            if not reply.reasoning_done.wait(10):
                return
            text(reply.prefix)
            if not reply.continue_stream.wait(10):
                return
            start = time.monotonic()
            for chunk, gap in zip(reply.chunks, reply.gaps):
                text(chunk)
                reply.sent_chars += len(chunk)
                time.sleep(gap)
            reply.tail_sent = time.monotonic()
            text(reply.tail)
            reply.elapsed = time.monotonic() - start
            reply.paused.set()
            if not reply.release.wait(10):
                return
            text(reply.end)
            emit({"choices": [{"delta": {}, "finish_reason": "stop"}],
                  "usage": {"prompt_tokens": 100, "completion_tokens": 400}})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()


def test_incremental_stream(tmp):
    reply = StreamReply()
    with patch("test_interjections.Handler", StreamHandler):
        with fixture(tmp, [reply]) as (terminal, home, _):
            terminal.send("stream test\r")
            wait_for(lambda: any("Thinking" in row for row in screen(terminal.read(), 120, 32)), "Thinking during reasoning")
            first_start = time.monotonic()
            reply.reasoning_done.set()
            terminal.until(reply.prefix.strip().encode())
            first_latency = time.monotonic() - first_start
            assert first_latency < STALL, f"first fragment stalled: {first_latency * 1000:.1f}ms"
            wait_for(lambda: any("Generating response" in row for row in screen(terminal.read(), 120, 32)), "Generating response during text")
            assert not reply.paused.is_set(), "first fragment must appear before the rest is sent"
            terminal.send("\x1b[200~live-draft\x1b[201~")
            terminal.until(b"live-draft")
            start = len(terminal.read())
            reply.continue_stream.set()
            terminal.until(b"word")
            assert not reply.release.is_set(), "incremental text must not wait for completion"
            for milestone in (1000, 10000, 30000):
                wait_for(lambda: reply.sent_chars >= milestone, f"{milestone} chars", timeout=30)
                input_start = time.monotonic()
                token = f"input{milestone}"
                terminal.send("\x1b[200~" + token + "\x1b[201~")
                terminal.until(token.encode())
                input_latency = time.monotonic() - input_start
                assert input_latency < STALL, f"input stalled: {input_latency * 1000:.1f}ms"
                assert not reply.paused.is_set() or milestone == 30000, f"input at {milestone} chars was echoed only after the stream ended"
                print(f"PTY chars={milestone} input={input_latency * 1000:.1f}ms")
            wait_for(reply.paused.is_set, "stream pause", timeout=30)
            wait_for(lambda: any("PAUSED_TAIL" in row for row in screen(terminal.read(), 120, 32)), "visible paused tail")
            tail_lag = time.monotonic() - reply.tail_sent
            assert tail_lag < STALL, f"paused tail stalled: {tail_lag * 1000:.1f}ms"
            print(f"PTY first={first_latency * 1000:.1f}ms input={input_latency * 1000:.1f}ms tail={tail_lag * 1000:.1f}ms")
            assert not finished(home, reply.text), "tail must display while the response is still open"
            output = terminal.read()[start:]
            frames = output.count(b"\x1b[?2026h")
            assert 1 < frames, frames
            print(f"stream: {len(reply.chunks)} deltas in {reply.elapsed:.3f}s, {frames} frames, {len(output)} terminal bytes")
            reply.release.set()
            wait_for(lambda: finished(home, reply.text), "complete stream committed")
            wait_for(lambda: any("STREAM_END" in row for row in screen(terminal.read(), 120, 32)), "visible final text")
            assert history(home)[-1]["content"] == reply.text
            assert terminal.child.poll() is None
            terminal.send("\x15")


def test_large_paste_does_not_redraw_per_key(tmp):
    payload = "first line\n" + "/help\n  indented text\twith a tab\n" * 96 + "last line"
    reply = Reply("paste received")
    with fixture(tmp, [reply]) as (terminal, _, _):
        offset = len(terminal.read())
        terminal.send("\x1b[200~" + payload + "\x1b[201~")
        terminal.until(b"[Pasted #1")
        frames = terminal.read()[offset:].count(b"\x1b[?2026h")
        assert 1 <= frames <= 4, f"pasting repainted {frames} frames"
        assert not reply.received.is_set(), "pasted newlines must not submit input"
        terminal.send("\r")
        assert reply.received.wait(5), "pasted draft was not sent"
        assert reply.messages[-1]["content"] == payload
        terminal.wait_turn(reply.text)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-tui-stream-") as directory:
        test_large_paste_does_not_redraw_per_key(Path(directory) / "paste")
        print("test_large_paste_does_not_redraw_per_key: ok")
        test_incremental_stream(Path(directory) / "incremental")
        print("test_incremental_stream: ok")
