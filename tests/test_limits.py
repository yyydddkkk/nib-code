"""Configured limits E2E with local provider mocks. Run after `zig build`."""
import json
from pathlib import Path
import unittest

from test_llm import LlmTests, records
from test_agent import AgentTests


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
                    if not path.name.endswith(".calls.jsonl") and records(path)[0].get("parent_session_id") == root_id]
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
        result, events = self.ask("limits-child")
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
