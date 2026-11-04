"""tools.llm E2E against local mocks only. Run after `zig build`.

    python3 tests/test_llm.py
    python3 tests/test_llm.py CodexTests.test_parallel
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

from mock_llm_tool import SCHEMA, SYSTEM, USAGE, content

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"
INPUT = "独立 input 🙂\n第二行"


def records(path):
    if not path.exists():
        return []
    lines = path.read_text().splitlines(keepends=True)
    return [json.loads(line) for line in lines if line.endswith("\n")]


def wait_for(check, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError("timed out waiting for mock observation")


class LlmTests:
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="nib-llm-" + cls.provider + "-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.tmp = Path(cls.temp.name)
        cls.requests = cls.tmp / "requests.jsonl"
        cls.observations = cls.tmp / "llm.jsonl"
        cls.cwd = cls.tmp / "project"
        cls.cwd.mkdir()
        (cls.cwd / ".git").mkdir()
        (cls.cwd / "AGENTS.md").write_text("LLM_PROJECT_INSTRUCTIONS_MUST_NOT_LEAK")
        home = cls.tmp / "nib"
        home.mkdir()
        (home / "AGENTS.md").write_text("LLM_GLOBAL_INSTRUCTIONS_MUST_NOT_LEAK")
        auth = cls.tmp / "codex"
        auth.mkdir()
        (auth / "auth.json").write_text(json.dumps({"tokens": {
            "access_token": "fake-llm-access", "account_id": "fake-llm-account",
            "refresh_token": "fake-llm-refresh", "id_token": "fake-llm-id"}}))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        cls.env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_", "MOCK_"))}
        cls.env.update(NIB_PROVIDER=cls.provider, NIB_API_KEY="fake-llm-key",
                       NIB_BASE_URL=f"http://127.0.0.1:{port}", NIB_MODEL="mock-parent-model",
                       NIB_REASONING_EFFORT="high", NIB_CONTEXT_WINDOW="128000",
                       NIB_HOME=str(home), CODEX_HOME=str(auth), HOME=str(cls.tmp),
                       XDG_CONFIG_HOME=str(cls.tmp / "config"), XDG_DATA_HOME=str(cls.tmp / "data"))
        cls.server_stderr = open(cls.tmp / "server.stderr", "w+")
        cls.addClassCleanup(cls.server_stderr.close)
        script = "mock_codex.py" if cls.provider == "codex" else "mock_llm.py"
        cls.server = subprocess.Popen(["python3", str(ROOT / "tests" / script), str(port), str(cls.requests)],
                                     env=dict(cls.env, MOCK_PROMPT_TOKENS="100",
                                              MOCK_LLM_TOOL_LOG=str(cls.observations)),
                                     stdout=subprocess.DEVNULL, stderr=cls.server_stderr)
        cls.addClassCleanup(cls.stop_server)

        def ready():
            if cls.server.poll() is not None:
                cls.server_stderr.seek(0)
                raise AssertionError(cls.server_stderr.read())
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    return True
            except OSError:
                return False
        wait_for(ready)

    @classmethod
    def stop_server(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait()

    def setUp(self):
        self.offset = len(records(self.observations))

    def observed(self):
        return records(self.observations)[self.offset:]

    def starts(self):
        return [event for event in self.observed() if event["event"] == "start"]

    def ask(self, prompt):
        result = subprocess.run([str(BIN), "ask", "--json", prompt], cwd=self.cwd,
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertIn("start", events[0], events)
        self.assertIn("end", events[-1], events)
        session_id = events[0]["start"]["session_id"]
        self.assert_tool_docs(session_id)
        steps = [record for record in records(Path(self.env["NIB_HOME"]) / "sessions" / (session_id + ".jsonl"))
                 if "model_ms" in record]
        timing = events[-1]["end"]["timing"]
        for name in ("llm", "agent"):
            self.assertEqual(timing[name + "_calls"], sum(
                call["name"] == name for step in steps for call in step.get("calls", [])))
        for key in ("model_ms", "run_ms"):
            self.assertEqual(timing[key], sum(step[key] for step in steps))
        return events

    def assert_tool_docs(self, session_id, child=False):
        log = Path(self.env["NIB_HOME"]) / "sessions" / (session_id + ".jsonl")
        system = records(log)[0]["messages"][0]["content"]
        self.assertNotIn("{{llm_options}}", system)
        self.assertIn("model: [", system)
        self.assertIn("current: \"mock-parent-model\"", system)
        self.assertNotIn("off may map", system)
        self.assertIn("smaller model/lower effort: faster, cheaper", system)
        self.assertNotIn("Read a few files yourself (cheapest)", system)
        self.assertIn("async llm({", system)
        self.assertEqual("async agent({" in system, not child)
        self.assertEqual("gpt-6.1-terra" in system, self.provider == "codex")
        self.assertEqual("deepseek-flash" in system, self.provider == "chat_completions")
        self.assertIn("effort low/medium/high (else inherit)", system)

    def result(self, events):
        runs = [event["run_end"] for event in events if "run_end" in event]
        self.assertEqual(len(runs), 1, events)
        self.assertTrue(runs[0]["ok"], runs[0])
        return json.loads(runs[0]["output"].removeprefix("result: "))

    def assert_usage(self, events, calls):
        outer = {"prompt_tokens": 200, "completion_tokens": 40 if self.provider == "codex" else 30,
                 "prompt_cache_hit_tokens": 128 if self.provider == "codex" else 192}
        expected = {key: value + calls * USAGE[key] for key, value in outer.items()}
        self.assertEqual(events[-1]["end"]["usage"], expected)
        self.assertEqual(events[-1]["end"]["steps"], 2)

    def assert_request(self, start, *, schema=False):
        body = start["body"]
        self.assertFalse(body.get("tools"), body)
        self.assertTrue(body.get("prompt_cache_key", "").endswith(":llm"), body)
        messages = body.get("messages", body.get("input", []))
        systems = [content(m) for m in messages if m.get("role") == "system"]
        if body.get("instructions"):
            systems.append(body["instructions"])
        self.assertEqual(systems, [SYSTEM], body)
        self.assertNotIn("MUST_NOT_LEAK", json.dumps(body))
        prompts = [m for m in messages if content(m).startswith("llm_mock:")]
        self.assertEqual(len(prompts), 1, messages)
        if self.provider == "codex":
            self.assertEqual(prompts[0]["role"], "developer")
        else:
            self.assertIn(prompts[0]["role"], ("developer", "user"))
        if start["mode"] != "no_input":
            users = [m for m in messages if m.get("role") == "user"]
            self.assertEqual(content(users[-1]), start["input"])
            self.assertNotEqual(users[-1], prompts[0])
        if self.provider == "codex":
            fmt = body.get("text", {}).get("format")
            if schema:
                self.assertEqual(fmt["type"], "json_schema", body)
                self.assertIs(fmt["strict"], True, body)
                self.assertEqual(fmt["schema"], SCHEMA)
            else:
                self.assertTrue(fmt is None or fmt.get("type") == "text", body)
        elif schema:
            self.assertEqual(body.get("response_format"), {"type": "json_object"})
        else:
            self.assertFalse(body.get("response_format"), body)

    def assert_result(self, result, text):
        self.assertEqual(result["text"], text)
        self.assertIsNone(result["data"])
        self.assertEqual(result["usage"], USAGE)

    def test_plain_and_isolation(self):
        events = self.ask("llm_plain")
        self.assert_result(self.result(events), "reply:" + INPUT)
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(self.starts()[0]["input"], INPUT)
        self.assert_request(self.starts()[0])
        self.assert_usage(events, 1)

    def test_no_input(self):
        events = self.ask("llm_no_input")
        self.assert_result(self.result(events), "reply:")
        self.assertEqual(len(self.starts()), 1)
        self.assert_request(self.starts()[0])
        self.assert_usage(events, 1)

    def test_parallel(self):
        events = self.ask("llm_parallel")
        results = self.result(events)
        self.assertEqual(len(results), 10)
        for i, result in enumerate(results):
            self.assert_result(result, "reply:" + str(i))
        starts = self.starts()
        self.assertEqual(len(starts), 10)
        self.assertEqual(sorted(int(start["input"]) for start in starts), list(range(10)))
        for start in starts:
            self.assert_request(start)
        wait_for(lambda: len([e for e in self.observed() if e["event"] == "end"]) == 10)
        observed = self.observed()
        active, peak = 0, 0
        for event in observed:
            active += 1 if event["event"] == "start" else -1
            peak = max(peak, active)
            self.assertEqual(event["active"], active, observed)
            self.assertGreaterEqual(active, 0, observed)
        self.assertEqual(peak, 4, observed)
        self.assertEqual(active, 0, observed)
        completed = [e["input"] for e in observed if e["event"] == "end"]
        self.assertNotEqual(completed, [str(i) for i in range(10)], observed)
        self.assertTrue(all(e["outcome"] == "completed" for e in observed if e["event"] == "end"))
        self.assert_usage(events, 10)
        run_end = next(i for i, event in enumerate(events) if "run_end" in event)
        snapshots = [event["usage"] for event in events[:run_end] if "usage" in event]
        self.assertTrue(any(usage["prompt_tokens"] > 100 for usage in snapshots), events)
        session_id = events[0]["start"]["session_id"]
        log = records(Path(self.env["NIB_HOME"]) / "sessions" / (session_id + ".jsonl"))
        calls = [call for step in log for call in step.get("calls", [])]
        self.assertEqual(len(calls), 10)
        self.assertTrue(all(call["name"] == "llm" and call["ok"] for call in calls), calls)

    def check_schema(self, prompt, attempts):
        events = self.ask(prompt)
        result = self.result(events)
        self.assertEqual(result["data"], {"value": "schema input 🙂", "index": 42})
        self.assertEqual(json.loads(result["text"]), result["data"])
        self.assertEqual(result["usage"], {key: attempts * value for key, value in USAGE.items()})
        self.assertEqual(len(self.starts()), attempts, self.observed())
        for start in self.starts():
            self.assert_request(start, schema=True)
        self.assert_usage(events, attempts)

    def test_buffered_transient_retry(self):
        events = self.ask("llm_transient")
        self.assert_result(self.result(events), "reply:transient")
        self.assertEqual(len(self.starts()), 2, self.observed())
        self.assert_usage(events, 1)

    def test_schema_data(self):
        self.check_schema("llm_schema", 1)

    def test_json_retry_once(self):
        self.check_schema("llm_json_once", 2)

    def test_json_retry_exhausted(self):
        events = self.ask("llm_json_twice")
        result = self.result(events)
        self.assertIs(result.get("rejected"), True, result)
        self.assertNotIn("resolved", result)
        self.assertIn("LLM_BAD_JSON_json_twice", result["message"])
        self.assertEqual(len(self.starts()), 2, self.observed())
        for start in self.starts():
            self.assert_request(start, schema=True)
        self.assert_usage(events, 2)

    def test_model_effort_overrides(self):
        events = self.ask("llm_overrides")
        result = self.result(events)
        self.assert_result(result["override"], "reply:override input")
        self.assert_result(result["inherited"], "reply:default input")
        self.assertEqual(len(self.starts()), 2)
        for start, model, effort in zip(self.starts(), ("mock-llm-override", "mock-parent-model"), ("low", "high")):
            self.assert_request(start)
            body = start["body"]
            self.assertEqual(body["model"], model)
            actual = body.get("reasoning", {}).get("effort") if self.provider == "codex" else body.get("reasoning_effort")
            self.assertEqual(actual, effort, body)
        self.assert_usage(events, 2)

    def test_child_can_call_llm(self):
        events = self.ask("llm_child")
        child = self.result(events)
        probe = json.loads(child["text"].split("result: ", 1)[1])
        self.assertEqual(probe["llm"], "function")
        self.assertEqual(probe["agent"], "undefined")
        root_id = events[0]["start"]["session_id"]
        children = [path for path in (Path(self.env["NIB_HOME"]) / "sessions").glob("*.jsonl")
                    if not path.name.endswith(".calls.jsonl") and records(path)[0].get("parent_session_id") == root_id]
        self.assertEqual(len(children), 1)
        self.assert_tool_docs(children[0].stem, child=True)
        self.assert_result(probe["result"], "reply:" + INPUT)
        self.assertEqual(len(self.starts()), 1)
        self.assert_request(self.starts()[0])
        expected = {"prompt_tokens": 400 + 11,
                    "completion_tokens": (80 if self.provider == "codex" else 60) + 7,
                    "prompt_cache_hit_tokens": (256 if self.provider == "codex" else 384) + 3}
        self.assertEqual(events[-1]["end"]["usage"], expected)

    def check_cancel(self, sig):
        process = subprocess.Popen([str(BIN), "ask", "--json", "llm_cancel"], cwd=self.cwd,
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            def started():
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail("ask exited before four in-flight llm requests: " + stdout + stderr)
                return len(self.starts()) >= 4
            wait_for(started)
            self.assertEqual(len(self.starts()), 4, self.observed())
            before = time.monotonic()
            process.send_signal(sig)
            stdout, stderr = process.communicate(timeout=3)
            self.assertLess(time.monotonic() - before, 3)
            self.assertNotEqual(process.returncode, 0, stdout + stderr)
            self.assertEqual(stderr, "")
            events = [json.loads(line) for line in stdout.splitlines()]
            self.assertIn("error", events[-1], events)
            self.assertFalse(any("end" in event for event in events), events)
            wait_for(lambda: len([e for e in self.observed() if e["event"] == "end"]) == 4, timeout=2)
            time.sleep(.25)
            observed = self.observed()
            self.assertEqual(len(self.starts()), 4, observed)
            ends = [e for e in observed if e["event"] == "end"]
            self.assertEqual({e["id"] for e in ends}, {e["id"] for e in self.starts()})
            self.assertTrue(all(e["outcome"] == "disconnected" for e in ends), observed)
            self.assertEqual(ends[-1]["active"], 0, observed)
            self.assertLess(ends[-1]["at"] - before, 3, observed)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_cancel_sigint_inflight_and_queued(self):
        self.check_cancel(signal.SIGINT)

    def test_cancel_sigterm_inflight_and_queued(self):
        self.check_cancel(signal.SIGTERM)


class CodexTests(LlmTests, unittest.TestCase):
    provider = "codex"


class ChatTests(LlmTests, unittest.TestCase):
    provider = "chat_completions"


if __name__ == "__main__":
    unittest.main(verbosity=2)
