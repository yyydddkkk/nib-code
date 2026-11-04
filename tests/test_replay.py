"""Run recording and offline replay E2E with a local provider. Run after zig build."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class ReplayTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nib-replay-")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        (self.cwd / ".git").mkdir()
        (self.cwd / "input.txt").write_text("replay needle\n")
        self.home = self.tmp / "nib"
        self.codes = {}
        self.requests = []
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fixture.requests.append(body)
                messages = body["messages"]
                prompt = next(message["content"] for message in reversed(messages)
                              if message["role"] == "user")
                latest_user = max(index for index, message in enumerate(messages) if message["role"] == "user")
                code = None if any(message["role"] == "tool" for message in messages[latest_user:]) else fixture.codes[prompt]
                delta = {"content": "done"}
                if code is not None:
                    delta["tool_calls"] = [{"index": 0, "id": "replay-call", "type": "function",
                                            "function": {"name": "run", "arguments": json.dumps({"code": code})}}]
                events = [{"choices": [{"delta": delta}]},
                          {"choices": [{"delta": {}, "finish_reason": "tool_calls" if code else "stop"}],
                           "usage": {"prompt_tokens": 10, "completion_tokens": 5}}]
                data = ("".join("data: " + json.dumps(event) + "\n\n" for event in events)
                        + "data: [DONE]\n\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(data)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()

        def stop_server():
            self.server.shutdown()
            self.server.server_close()
            thread.join()
        self.addCleanup(stop_server)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("NIB_", "OPENAI_", "DEEPSEEK_", "CODEX_"))}
        self.env.update(NIB_PROVIDER="chat_completions", NIB_API_KEY="fake-replay-key",
                        NIB_BASE_URL=f"http://127.0.0.1:{self.server.server_port}", NIB_MODEL="mock-replay",
                        NIB_HOME=str(self.home), HOME=str(self.tmp))

    def nib(self, *arguments, env=None):
        return subprocess.run([str(BIN), *arguments], cwd=self.cwd, env=env or self.env,
                              capture_output=True, text=True, timeout=20)

    def record(self, code, env=None):
        prompt = "record-" + str(len(self.codes))
        self.codes[prompt] = code
        result = self.nib("ask", "--json", prompt, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        runs = [event["run_end"] for event in events if "run_end" in event]
        self.assertEqual(len(runs), 1, events)
        self.assertTrue(runs[0]["ok"], runs)
        self.session = events[0]["start"]["session_id"]
        self.calls = self.home / "sessions" / (self.session + ".calls.jsonl")
        return runs[0]

    def replay(self, *arguments, match=None):
        before = len(self.requests)
        offline = dict(self.env, NIB_BASE_URL="http://127.0.0.1:1", NIB_API_KEY="", NIB_PROVIDER="invalid")
        result = self.nib("replay", self.session, *arguments, "--json", env=offline)
        try:
            report = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(result.stdout + result.stderr)
        self.assertEqual(len(self.requests), before, "replay called the provider")
        if match is not None:
            self.assertIs(report["match"], match, report)
            if match:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return report

    def call_records(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_read_grep_bash_and_all_are_offline(self):
        self.record('const read = await tools.read({path: "input.txt"}); '
                    'const grep = await tools.grep({pattern: /needle/, path: "."}); '
                    'const bash = await tools.bash({command: "printf once >> side-effect.txt; printf shell-result"}); '
                    'console.log({read, grep, bash})')
        records = self.call_records()
        calls = [record for record in records if "name" in record]
        self.assertEqual([record["name"] for record in calls], ["read", "grep", "bash"])
        self.assertEqual([record["index"] for record in calls], [0, 1, 2])
        self.assertEqual(sorted(record["seq"] for record in calls), [0, 1, 2])
        for record in calls:
            self.assertEqual((record["step"], record["run"]), (1, 0))
            self.assertTrue(record["ok"], record)
            self.assertIn("args", record)
            self.assertIn("result", record)
        self.assertEqual(stat.S_IMODE(self.calls.stat().st_mode), 0o600)
        metadata = [record["meta"] for record in records if "meta" in record]
        self.assertTrue(any("start_ms_epoch" in meta for meta in metadata), metadata)
        self.assertTrue(any(meta.get("end") for meta in metadata), metadata)
        (self.cwd / "input.txt").unlink()
        before = self.calls.read_bytes()
        report = self.replay("--run", "1:0", match=True)
        self.assertFalse(report["incomplete"], report)
        self.assertFalse(report["uses_time"], report)
        self.assertFalse(report["uses_random"], report)
        self.assertIn("shell-result", report["output"])
        summary = self.replay("--all")
        self.assertEqual({key: summary[key] for key in ("total", "matched", "divergences", "indeterminate")},
                         dict(total=1, matched=1, divergences=[], indeterminate=0))
        self.assertEqual((self.cwd / "side-effect.txt").read_text(), "once")
        self.assertEqual(self.calls.read_bytes(), before, "replay changed the recording")

    def test_script_override_and_unrecorded_call(self):
        self.record('await tools.read({path: "input.txt"})')
        script = self.tmp / "override.js"
        script.write_text('const path = "input.txt"; await tools.read({path})')
        report = self.replay("--run", "1:0", "--script", str(script))
        self.assertIsNone(report["match"], report)
        self.assertIn("replay needle", report["output"])
        self.assertNotIn("not recorded", json.dumps(report).lower())
        script.write_text('await tools.read({path: "input.txt"}); '
                          'await tools.write({path: "must-not-exist.txt", content: "unsafe"})')
        report = self.replay("--run", "1:0", "--script", str(script))
        self.assertIsNone(report["match"], report)
        self.assertIn("not recorded", json.dumps(report).lower())
        self.assertFalse((self.cwd / "must-not-exist.txt").exists())

    def test_changed_recorded_arguments_diverge(self):
        self.record('await tools.read({path: "input.txt"})')
        records = self.call_records()
        next(record for record in records if record.get("name") == "read")["args"] = {"path": "other.txt"}
        self.calls.write_text("".join(json.dumps(record) + "\n" for record in records))
        report = self.replay("--run", "1:0", match=False)
        self.assertTrue(report.get("divergence"), report)

    def test_date_now_is_stable(self):
        self.record('console.log(Date.now()); await tools.read({path: "input.txt"}); console.log(Date.now())')
        first = self.replay("--run", "1:0")
        second = self.replay("--run", "1:0")
        self.assertTrue(first["uses_time"], first)
        self.assertFalse(first["uses_random"], first)
        self.assertEqual(first["output"], second["output"])
        self.assertFalse(first["incomplete"], first)

    def test_resume_deduplicates_without_reusing_step_numbers(self):
        self.record('await tools.read({path: "input.txt"})')
        self.codes["resumed"] = 'await tools.read({path: "input.txt"})'
        resumed = self.nib("ask", "--resume", self.session, "--json", "resumed")
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        calls = [entry for entry in self.call_records() if "name" in entry]
        self.assertEqual([entry["step"] for entry in calls], [1, 3])
        self.assertIn("same_as", calls[1]["result"])
        self.assertEqual(self.replay("--all"), dict(total=2, matched=2, divergences=[], indeterminate=0))

    def test_recording_off(self):
        self.record('await tools.read({path: "input.txt"})', env=dict(self.env, NIB_RECORD="off"))
        self.assertFalse(self.calls.exists())

    def test_child_has_its_own_recording(self):
        self.codes["child"] = 'console.log(typeof tools.agent); await tools.write({path: "child.txt", content: "child wrote"})'
        self.record('await tools.agent({prompt: "child"})')
        calls = [record for record in self.call_records() if "name" in record]
        self.assertEqual([record["name"] for record in calls], ["agent"])
        self.assertTrue(json.loads(calls[0]["result"])["ok"], calls)
        children = [path for path in (self.home / "sessions").glob("*.jsonl")
                    if not path.name.endswith(".calls.jsonl")
                    and json.loads(path.read_text().splitlines()[0]).get("parent_session_id") == self.session]
        self.assertEqual(len(children), 1, children)
        child_calls = children[0].with_name(children[0].stem + ".calls.jsonl")
        child_records = [json.loads(line) for line in child_calls.read_text().splitlines()]
        self.assertEqual([record["name"] for record in child_records if "name" in record], ["write"])
        (self.cwd / "child.txt").unlink()
        self.replay("--run", "1:0", match=True)
        self.assertFalse((self.cwd / "child.txt").exists())
        self.session = children[0].stem
        self.replay("--run", "1:0", match=True)
        self.assertFalse((self.cwd / "child.txt").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
