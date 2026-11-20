"""Configured limits E2E with local provider mocks. Run after `zig build`."""
import json
from pathlib import Path
import unittest

from test_llm import LlmTests, records
from test_agent import AgentTests, BIN
from mock_llm_tool import content


class LlmLimits(unittest.TestCase):
    provider = "chat_completions"
    setUpClass = classmethod(LlmTests.setUpClass.__func__)
    stop_server = classmethod(LlmTests.stop_server.__func__)
    setUp = LlmTests.setUp
    observed = LlmTests.observed
    starts = LlmTests.starts
    ask = LlmTests.ask
    result = LlmTests.result
    assert_tool_docs = LlmTests.assert_tool_docs

    def test_child_llm_limits_after_config_is_poisoned(self):
        config = Path(self.env["NIB_HOME"]) / "config.toml"
        config.write_text("[limits]\nllm_calls_per_run = 3\nllm_concurrency = 2\nllm_input_kib = 17\n")
        self.addCleanup(config.unlink, missing_ok=True)
        events = self.ask("llm_limits_child")
        child = self.result(events)
        self.assertTrue(child["ok"], child)
        results = json.loads(child["text"].split("result: ", 1)[1])
        self.assertEqual([r["ok"] for r in results], [True, True, True, False], results)
        self.assertIn("3 calls per Run", results[3]["error"])
        self.assertEqual(len(self.starts()), 3, self.observed())
        self.assertEqual(max(e["active"] for e in self.starts()), 2, self.observed())
        root_id = events[0]["start"]["session_id"]
        children = [records(path)[0] for path in (config.parent / "sessions").glob("*.jsonl")
                    if records(path)[0].get("parent_session_id") == root_id]
        self.assertEqual(len(children), 1)
        self.assertIn("2 concurrent/process, 3/Run, 17 KiB", children[0]["messages"][0]["content"])
        self.assertEqual(config.read_text(), "[limits]\nllm_concurrency = 0\n")

    def test_calls_and_concurrency_and_docs(self):
        config = Path(self.env["NIB_HOME"]) / "config.toml"
        config.write_text("[limits]\nllm_calls_per_run = 3\nllm_concurrency = 2\nllm_input_kib = 17\n")
        self.addCleanup(config.unlink, missing_ok=True)
        events = self.ask("llm_limits")
        results = self.result(events)
        self.assertEqual([r["ok"] for r in results], [True, True, True, False], results)
        self.assertIn("3", results[3]["error"])
        starts = self.starts()
        self.assertEqual(len(starts), 3, self.observed())
        run_end = next(event["run_end"] for event in events if "run_end" in event)
        self.assertEqual(run_end["tool_summary"], {"counts": [{"name": "llm", "count": 3}], "omitted": 0, "failures": 0, "files": []})
        self.assertEqual(max(e["active"] for e in starts), 2, self.observed())
        session = events[0]["start"]["session_id"]
        system = records(Path(self.env["NIB_HOME"]) / "sessions" / (session + ".jsonl"))[0]["messages"][0]["content"]
        self.assertIn("2 concurrent/process, 3/Run, 17 KiB", system)
        self.assertNotIn("{{llm_limits}}", system)


class AgentLimits(unittest.TestCase):
    provider = "chat_completions"
    setUp = AgentTests.setUp
    stop_server = AgentTests.stop_server
    start = AgentTests.start
    ask = AgentTests.ask

    def configure(self):
        (Path(self.env["NIB_HOME"]) / "config.toml").write_text("[limits]\nmax_steps = 2\n")

    def test_agent_concurrency_queues_and_completes(self):
        (Path(self.env["NIB_HOME"]) / "config.toml").write_text("[limits]\nagent_concurrency = 2\n")
        results, _ = self.ask("limits-queue")
        self.assertEqual(len(results), 5)
        self.assertTrue(all(r["ok"] for r in results), results)
        active = set()
        peak = 0
        completed = 0
        for request in records(self.requests):
            if not request["prompt"].startswith("agent-child:limits-wait-"):
                continue
            if request["step"] == 0:
                active.add(request["prompt"])
                peak = max(peak, len(active))
            else:
                self.assertEqual(request["step"], 1)
                active.remove(request["prompt"])
                completed += 1
        self.assertEqual(peak, 2)
        self.assertEqual(completed, 5)
        self.assertEqual(active, set())

    def session_log(self, events):
        session = events[0]["start"]["session_id"]
        return records(Path(self.env["NIB_HOME"]) / "sessions" / (session + ".jsonl"))

    def limited_turn(self, case, steps):
        (Path(self.env["NIB_HOME"]) / "config.toml").write_text(f"[limits]\nmax_steps = {steps}\n")
        process = self.start(case)
        output, error = process.communicate(timeout=20)
        self.assertEqual(error, "")
        self.assertNotEqual(process.returncode, 0, output)
        events = [json.loads(line) for line in output.splitlines()]
        self.assertIn("error", events[-1], events)
        self.assertIn(f"stopped after {steps} step" + ("s" if steps != 1 else ""), json.dumps(events[-1]))
        self.assertEqual(events[-1]["error"]["steps"], steps)
        self.assertFalse(any("end" in e for e in events), events)
        self.assertEqual([r["step"] for r in records(self.requests)], list(range(steps)))
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), steps)
        self.assertTrue(all(r["ok"] for r in runs), runs)
        return events, [r["output"] for r in runs]

    def test_default_max_steps_is_unlimited(self):
        process = self.start("limits-default")
        output, error = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, output + error)
        self.assertEqual(error, "")
        events = [json.loads(line) for line in output.splitlines()]
        self.assertEqual(events[-1]["end"]["steps"], 60)
        self.assertEqual([r["step"] for r in records(self.requests)], list(range(60)))
        system = self.session_log(events)[0]["messages"][0]["content"]
        self.assertNotIn("This Turn may use at most", system)
        for request in records(self.requests):
            body = request["body"]
            if self.provider == "codex":
                items = body.get("input", [])
                sent_system = items[0]["content"] if items and items[0].get("role") == "developer" else body["instructions"]
            else:
                sent_system = body["messages"][0]["content"]
            self.assertNotIn("This Turn may use at most", sent_system)
        runs = [e["run_end"]["output"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), 59)
        self.assertTrue(all("Steps left in this Turn]" not in r for r in runs))

    def assert_five_step_countdown(self, events, outputs):
        system = self.session_log(events)[0]["messages"][0]["content"]
        instruction = "This Turn may use at most 5 Steps; when they run out, the Turn stops without another model request."
        self.assertIn(instruction, system)
        for request in records(self.requests):
            body = request["body"]
            if self.provider == "codex":
                items = body.get("input", [])
                sent_system = items[0]["content"] if items and items[0].get("role") == "developer" else body["instructions"]
            else:
                sent_system = body["messages"][0]["content"]
            self.assertIn(instruction, sent_system)
        self.assertNotIn("Steps left in this Turn]", outputs[0])
        self.assertTrue(outputs[1].endswith("[3 Steps left in this Turn]"))
        for output, left in zip(outputs[2:], (2, 1, 0)):
            marker = f"[{left} Steps left in this Turn]"
            self.assertTrue(output.endswith(marker), output[-200:])
            self.assertEqual(output.count(marker), 1)
        stored = [m["content"] for r in self.session_log(events) for m in r.get("messages", [])
                  if m.get("role") == "tool"]
        self.assertEqual(stored, outputs)
        for request, previous in zip(records(self.requests)[1:], outputs):
            messages = request["body"].get("messages", request["body"].get("input", []))
            results = [m.get("output", content(m)) for m in messages
                       if m.get("role") == "tool" or m.get("type") == "function_call_output"]
            self.assertEqual(results[-1], previous)

    def test_five_steps_system_countdown_and_no_sixth_request(self):
        events, outputs = self.limited_turn("limits-loop", 5)
        self.assert_five_step_countdown(events, outputs)

    def test_configured_run_output_budget(self):
        self.env["NIB_RECORD"] = "on"
        (self.cwd / "budget.txt").write_text("x" * 50000)
        self.env["NIB_RUN_OUTPUT_BYTES"] = "32768"
        events, outputs = self.limited_turn("limits-budget", 1)
        payload = outputs[0].removesuffix("\n[0 Steps left in this Turn]")
        self.assertGreater(len(payload.encode()), 16 * 1024)
        self.assertLessEqual(len(payload.encode()), 32 * 1024)
        self.assertIn("omitted", payload)
        system = self.session_log(events)[0]["messages"][0]["content"]
        self.assertIn("share 32 KiB per Run", system)
        session = events[0]["start"]["session_id"]
        import subprocess
        replay = subprocess.run([str(BIN), "replay", session, "--all", "--json"],
                                env=self.env, cwd=self.cwd, capture_output=True, text=True, timeout=20)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        self.assertEqual(json.loads(replay.stdout)["matched"], 1)

    def test_countdown_is_outside_run_output_budget(self):
        (self.cwd / "budget.txt").write_text("x" * 50000)
        events, outputs = self.limited_turn("limits-budget", 5)
        self.assert_five_step_countdown(events, outputs)
        payload = outputs[0]
        self.assertIn("bytes omitted", payload)
        self.assertLessEqual(len(payload.encode()), 16 * 1024)
        self.assertEqual(outputs[1].removesuffix("\n[3 Steps left in this Turn]"), payload)
        for output, left in zip(outputs[2:], (2, 1, 0)):
            self.assertEqual(output[:len(payload)], payload)
            self.assertEqual(output[len(payload):].strip("\n"), f"[{left} Steps left in this Turn]")
            self.assertGreater(len(output.encode()), 16 * 1024)

    def test_turn_stops_before_third_step(self):
        self.configure()
        process = self.start("limits-loop")
        output, error = process.communicate(timeout=20)
        self.assertNotEqual(process.returncode, 0, output + error)
        events = [json.loads(line) for line in output.splitlines()]
        self.assertIn("error", events[-1], events)
        self.assertIn("stopped after 2 steps", json.dumps(events[-1]))
        self.assertEqual(events[-1]["error"]["steps"], 2)
        requests = records(self.requests)
        self.assertEqual([r["step"] for r in requests], [0, 1])

    def test_child_inherits_limits_without_reading_poisoned_config(self):
        self.configure()
        process = self.start("limits-child")
        output, error = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, output + error)
        self.assertEqual(error, "")
        events = [json.loads(line) for line in output.splitlines()]
        self.assertIn("end", events[-1], events)
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), 1)
        self.assertTrue(runs[0]["ok"], runs[0])
        result, _ = json.JSONDecoder().raw_decode(runs[0]["output"].removeprefix("result: "))
        self.assertFalse(result["ok"], result)
        self.assertIn("stopped after 2 steps", result["error"])
        requests = records(self.requests)
        child = [r for r in requests if r["prompt"] == "agent-child:limits-loop"]
        self.assertEqual([r["step"] for r in child], [0, 1], requests)
        self.assertEqual((Path(self.env["NIB_HOME"]) / "config.toml").read_text(),
                         "[limits]\nmax_steps = 0\n")


class CodexLlmLimits(LlmLimits):
    provider = "codex"


class CodexAgentLimits(AgentLimits):
    provider = "codex"


if __name__ == "__main__":
    unittest.main(verbosity=2)
