"""Input prediction ghost text through a PTY and a local mock. Run after zig build."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mock_http import ThreadingHTTPServer
from screen import screen
from test_interjections import Terminal, wait_for

MARK = "Predict the user's next message"


class Gate:
    def __init__(self, text, gated=False):
        self.text = text
        self.received = threading.Event()
        self.release = threading.Event()
        self.answered = threading.Event()
        self.body = None
        if not gated:
            self.release.set()


class Mock(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, predictions, turn_gates=None):
        self.predictions = list(predictions)
        self.turn_gates = turn_gates or {}
        self.turns = 0
        self.lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        first = body["messages"][0].get("content", "")
        with self.server.lock:
            if MARK in first:
                gate = self.server.predictions.pop(0)
                text = gate.text
            else:
                self.server.turns += 1
                gate = self.server.turn_gates.get(self.server.turns)
                text = gate.text if gate else f"answer {self.server.turns}"
        if gate:
            gate.body = body
            gate.received.set()
            if not gate.release.wait(10):
                return
        events = [
            {"choices": [{"delta": {"content": text}}]},
            {"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 100, "completion_tokens": 10}},
        ]
        data = ("".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)
        if gate:
            gate.answered.set()


@contextlib.contextmanager
def fixture(tmp, predictions, turn_gates=None):
    tmp.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
    with Mock(predictions, turn_gates) as mock:
        threading.Thread(target=mock.serve_forever, daemon=True).start()
        env.update(NIB_PROVIDER="chat_completions", NIB_API_KEY="mock",
                   NIB_BASE_URL=f"http://127.0.0.1:{mock.server_port}", NIB_HOME=str(tmp / "home"),
                   HOME=str(tmp), TERM="xterm-256color")
        terminal = Terminal(tmp, env)
        try:
            yield terminal, mock
        finally:
            terminal.close()
            for gate in [*predictions, *(turn_gates or {}).values()]:
                gate.release.set()
            mock.shutdown()


def rows(terminal):
    return screen(terminal.read(), 120, 32)


def shown(terminal, text):
    return any(text in row for row in rows(terminal))


def settle(gate):
    assert gate.answered.wait(5)
    time.sleep(.4)


def test_prediction(tmp):
    first, late, over, after = Gate("run the tests"), Gate("late guess", True), Gate("late third", True), Gate("after four")
    user = "Let me know when the fix is ready for tests"
    reply = "The fix is ready. Should I start the test suite?"
    gate4 = Gate("answer 4", True)
    with fixture(tmp, [first, late, over, after], {1: Gate(reply), 4: gate4}) as (terminal, mock):
        terminal.send(user + "\r")
        terminal.wait_turn(reply)
        wait_for(lambda: shown(terminal, "run the tests"), "ghost text")
        assert not shown(terminal, "Ask about this project")
        request = first.body["messages"]
        assert [m["role"] for m in request] == ["system", "user"], request
        instruction = request[0]["content"]
        assert "You are an input predictor, not the agent" in instruction
        assert "'I' refers to the user" in instruction and "'you' refers to the agent" in instruction
        assert "Use the assistant's last reply only as context" in instruction
        assert user in request[1]["content"] and reply in request[1]["content"]
        assert not request[1]["content"].startswith("Predict") and not first.body.get("tools")

        terminal.send("x")
        wait_for(lambda: not shown(terminal, "run the tests"), "typing hides ghost")
        terminal.send("\x7f")
        wait_for(lambda: shown(terminal, "run the tests"), "cleared input shows ghost")
        terminal.send("\t")
        wait_for(lambda: shown(terminal, "run the tests"), "tab keeps text")
        assert mock.turns == 1, "Tab must not send"
        terminal.send("\x7f" * len("run the tests"))
        wait_for(lambda: shown(terminal, "Ask about this project"), "consumed prediction stays gone")
        assert not shown(terminal, "run the tests")

        # A prediction arriving while the user types waits for an empty input.
        terminal.send("second\r")
        terminal.wait_turn("answer 2")
        assert late.received.wait(5)
        terminal.send("abc")
        late.release.set()
        settle(late)
        assert not shown(terminal, "late guess") and shown(terminal, "abc")
        terminal.send("\x7f" * 3)
        wait_for(lambda: shown(terminal, "late guess"), "late prediction appears once empty")
        terminal.send("\t")
        terminal.send("\x7f" * len("late guess"))
        wait_for(lambda: shown(terminal, "Ask about this project"), "cleared again")

        # Sending immediately does not wait for a pending prediction, and its late result is dropped.
        terminal.send("third\r")
        terminal.wait_turn("answer 3")
        assert over.received.wait(5)
        terminal.send("fourth\r")
        assert gate4.received.wait(5), "new Turn must start while the prediction is pending"
        over.release.set()
        settle(over)
        assert not shown(terminal, "late third")
        gate4.release.set()
        terminal.wait_turn("answer 4")
        wait_for(lambda: shown(terminal, "after four"), "prediction after the new Turn")
        assert not shown(terminal, "late third")


def test_greeting_prediction(tmp):
    reply = "你好！有什么我可以帮你的吗？"
    prediction = Gate("NONE")
    with fixture(tmp, [prediction], {1: Gate(reply)}) as (terminal, _):
        terminal.send("你好\r")
        terminal.wait_turn(reply)
        assert prediction.received.wait(5)
        instruction, context = (m["content"] for m in prediction.body["messages"])
        assert "Do not answer the user, echo the assistant's reply, or continue it" in instruction
        assert "A greeting followed by a generic offer to help is not enough" in instruction
        assert "output exactly NONE" in instruction
        assert "User's last message:\n你好\n\nAssistant's last reply:\n" + reply in context
        settle(prediction)
        assert shown(terminal, "Ask about this project") and not shown(terminal, "NONE")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-prediction-") as directory:
        test_prediction(Path(directory) / "prediction")
        test_greeting_prediction(Path(directory) / "greeting")
        print("test_prediction: ok")
