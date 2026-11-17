"""Replay and /reflect privacy E2E, temporary NIB_HOME and local mock only.

Run after zig build: python3 tests/test_replay.py
"""
import contextlib
import hashlib
from mock_http import ThreadingHTTPServer, is_prediction
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import stat
import subprocess
import tempfile
import threading
import unittest

from background_assertions import stop_result

from test_interjections import Terminal, wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


class Mock(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        self.replies = queue.Queue()
        self.requests = []
        super().__init__(("127.0.0.1", 0), Handler)

    def reply(self, *, codes=(), text="mock finished"):
        self.replies.put((codes, text))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if is_prediction(body):
            return self.send_error(400)
        self.server.requests.append(body)
        codes, text = self.server.replies.get(timeout=5)
        delta = {"content": text, "reasoning_content": "mock reasoning"}
        if codes:
            delta["tool_calls"] = [
                {"index": n, "id": f"run-{len(self.server.requests)}-{n}", "type": "function",
                 "function": {"name": "rerun" if isinstance(code, dict) else "run", "arguments": json.dumps(code if isinstance(code, dict) else {"code": code})}}
                for n, code in enumerate(codes)]
        events = [{"choices": [{"delta": delta}]},
                  {"choices": [{"delta": {}, "finish_reason": "tool_calls" if codes else "stop"}],
                   "usage": {"prompt_tokens": 100, "completion_tokens": 10}}]
        data = ("".join("data: " + json.dumps(event) + "\n\n" for event in events)
                + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)


class ReplayTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="nib-replay-")
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        (self.cwd / ".git").mkdir()
        self.home = self.tmp / "nib"
        self.home.mkdir()
        self.mock = Mock()
        thread = threading.Thread(target=self.mock.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.mock.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.mock.shutdown)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
        self.env.update(NIB_HOME=str(self.home), HOME=str(self.tmp), TERM="xterm-256color",
                        NIB_PROVIDER="chat_completions", NIB_API_KEY="local-mock-only",
                        NIB_RECORD="on", NIB_MODEL="mock-replay", NIB_BASE_URL=f"http://127.0.0.1:{self.mock.server_port}")

    def command(self, *args, env=None, check=True):
        result = subprocess.run([str(BIN), *args], cwd=self.cwd, env=env or self.env,
                                text=True, capture_output=True, timeout=20)
        if check:
            self.assertEqual(result.returncode, 0, (args, result.stdout, result.stderr))
        return result

    def ask(self, codes, *, resume=None):
        self.mock.reply(codes=codes)
        self.mock.reply()
        args = ["ask", "--json", "record this mock session"]
        if resume:
            args += ["--resume", resume]
        events = [json.loads(line) for line in self.command(*args).stdout.splitlines()]
        return events[0]["start"]["session_id"]

    def calls_path(self, session):
        return self.home / "sessions" / f"{session}.calls.jsonl"

    def replay(self, session, *args, check=True):
        result = self.command("replay", session, "--json", *args, check=check)
        return json.loads(result.stdout)

    def record_files(self):
        (self.cwd / "sample.txt").write_text("alpha\nbeta\nalpha\n")
        return self.ask([
            'console.log(await tools.read({path: "sample.txt"})); '
            'console.log(await tools.grep({path: "sample.txt", pattern: "alpha"})); '
            'console.log(await tools.read({path: "sample.txt"}));',
            'console.log(await tools.bash({command: "printf side > side-effect; printf bash-output"}));',
        ])

    def test_patch_rerun_resume_validation_and_replay(self):
        code = 'console.log(await tools.bash({command: "echo effect >> effects"})); throw new Error("bad");'
        session = self.ask([code])
        def repair(base, old, new):
            return {"base": base, "edits": [{"old_text": old, "new_text": new}]}
        self.ask([repair("1:0", '"bad"', '"again"')], resume=session)
        self.ask([repair("3:0", 'throw new Error("again")', 'console.log("fixed")')], resume=session)
        self.assertEqual((self.cwd / "effects").read_text().splitlines(), ["effect"] * 3)
        report = self.replay(session, "--all")
        self.assertEqual(report["divergences"], 0, report)
        self.assertEqual(report["matched"], 3, report)
        for args in [repair("5:0", "fixed", "wrong"), repair("99:0", "x", "y"),
                     repair("1:0", "", "x"), repair("1:0", "missing", "x"),
                     repair("1:0", ";", "x"), {"base": "1:0", "edits": []},
                     {"base": "1:0", "edits": [{"old_text": '"bad"', "new_text": '"changed"'},
                                                   {"old_text": "absent", "new_text": "x"}]}]:
            self.ask([args], resume=session)
        self.assertEqual((self.cwd / "effects").read_text().splitlines(), ["effect"] * 3)
        records = jsonl(self.home / "sessions" / f"{session}.jsonl")
        sources = [r["source"] for r in records if "source" in r]
        self.assertEqual(sources[0]["code"], code)
        calls = [c for r in records for m in r["messages"] for c in m.get("tool_calls", [])]
        reruns = [c for c in calls if c["function"]["name"] == "rerun"]
        self.assertEqual(json.loads(reruns[0]["function"]["arguments"]), repair("1:0", '"bad"', '"again"'))
        self.assertTrue(all("executed_source" not in m for request in self.mock.requests for m in request["messages"]))
        foreign = self.ask([repair("1:0", '"bad"', '"foreign"')])
        foreign_records = jsonl(self.home / "sessions" / f"{foreign}.jsonl")
        self.assertFalse(any("source" in r for r in foreign_records))
        self.assertTrue(any(s.get("base") == "3:0" and 'console.log("fixed")' in s["code"] for s in sources))

    def test_patch_rerun_with_hook_records(self):
        (self.home / "config.toml").write_text('[hooks]\nafter_edit = ["true"]\nturn_end = ["true"]\n')
        code = 'await tools.write({path: "edited", content: "before"}); throw new Error("hook repair")'
        session = self.ask([code])
        self.ask([{"base": "1:0", "edits": [{"old_text": 'throw new Error("hook repair")',
                                              "new_text": 'await tools.write({path: "edited", content: "after"})'}]}],
                 resume=session)
        self.assertEqual((self.cwd / "edited").read_text(), "after")
        report = self.replay(session, "--all")
        self.assertEqual(report["matched"], 2, report)
        self.assertEqual(report["divergences"], 0, report)

    def test_pending_source_rejected_then_background_failure_repaired(self):
        (self.home / "config.toml").write_text("[limits]\nrun_background_after_ms = 50\n")
        code = 'await tools.sleep(300); throw new Error("background failure")'
        repair = {"base": "1:0", "edits": [{"old_text": 'throw new Error("background failure")',
                                             "new_text": 'console.log("repaired")'}]}
        self.mock.reply(codes=[code, repair])
        self.mock.reply()
        self.mock.reply()
        result = self.command("ask", "--json", "background repair")
        events = [json.loads(line) for line in result.stdout.splitlines()]
        session = events[0]["start"]["session_id"]
        records = jsonl(self.home / "sessions" / f"{session}.jsonl")
        outputs = [m.get("content", "") for r in records for m in r["messages"] if m["role"] == "tool"]
        self.assertTrue(any("base" in output and "error:" in output for output in outputs), outputs)
        repair["edits"].append({"old_text": "await tools.sleep(300); ", "new_text": ""})
        self.ask([repair], resume=session)
        report = self.replay(session, "--all")
        self.assertEqual(report["matched"], 2, report)
        self.assertEqual(report["divergences"], 0, report)

    def test_all_and_session_global_step_indices_without_side_effects(self):
        session = self.record_files()
        self.ask(['console.log(await tools.read({path: "sample.txt"}));'], resume=session)
        path = self.calls_path(session)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        rows = jsonl(path)
        self.assertEqual([(r["step"], r["run"]) for r in rows if "meta" in r],
                         [(1, 0), (1, 1), (3, 0)])
        calls = [r for r in rows if "index" in r]
        self.assertEqual({r["name"] for r in calls}, {"read", "grep", "bash"})
        for row in calls:
            if isinstance(row.get("result"), dict):
                self.assertEqual(row["result"], {"same_as": row["sha256"]})
                self.assertNotIn("error", row)
            else:
                raw = row["result"] if row["ok"] else row["error"]
                self.assertEqual(hashlib.sha256(raw.encode()).hexdigest(), row["sha256"])
        self.assertTrue(any(isinstance(r.get("result"), dict) for r in calls), calls)
        for row in rows:
            self.assertNotIn("type", row)
            self.assertNotIn("same_as", row)
        for key in {(r["step"], r["run"]) for r in rows}:
            run_rows = [r for r in rows if (r["step"], r["run"]) == key]
            self.assertEqual(sum("meta" in r for r in run_rows), 1)
            self.assertEqual(set(run_rows[-1]), {"step", "run", "meta"})
            self.assertEqual(set(run_rows[-1]["meta"]), {"start_ms_epoch", "run_output_bytes", "end"})
            self.assertEqual(run_rows[-1]["meta"]["run_output_bytes"], 16384)
        (self.cwd / "sample.txt").unlink()
        (self.cwd / "side-effect").unlink()
        before = len(self.mock.requests)
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 3, report)
        self.assertEqual(report["matched"], 3, report)
        self.assertEqual(report["divergences"], 0, report)
        self.assertEqual(report["differences"], [], report)
        self.assertEqual(report["undetermined"], 0, report)
        single = self.replay(session, "--run", "1:1")
        self.assertTrue(single["match"], single)
        self.assertIn("bash-output", single["output"])
        self.assertFalse(single["incomplete"], single)
        self.assertEqual(len(self.mock.requests), before)
        self.assertFalse((self.cwd / "sample.txt").exists())
        self.assertFalse((self.cwd / "side-effect").exists())

    def test_detached_start_and_stop_are_recorded_and_replay_without_processes(self):
        session = self.ask([
            'const job = await tools.bash({command: "printf started > detached-side-effect; sleep 60", '
            'background: true, detached: true}); await tools.sleep(100); '
            'console.log(job, await tools.stop({id: job.id,reason:"mock requested cancellation"}));'
        ])
        calls = [r for r in jsonl(self.calls_path(session)) if "index" in r]
        self.assertEqual([r["name"] for r in calls], ["bash", "sleep", "stop"])
        self.assertEqual(json.loads(calls[0]["result"]), {"id": "b1"})
        self.assertEqual(json.loads(calls[-1]["result"]), stop_result("b1", True))
        log = jsonl(self.home / "sessions" / f"{session}.jsonl")
        timed = [c for row in log for c in row.get("calls", [])]
        self.assertEqual([c["name"] for c in timed], ["bash", "sleep", "stop"])
        self.assertTrue(all(c["ok"] and c["result_bytes"] > 0 for c in timed))
        marker = self.cwd / "detached-side-effect"
        marker.unlink(missing_ok=True)
        before = len(self.mock.requests)
        report = self.replay(session, "--all")
        self.assertEqual(report["matched"], 1, report)
        self.assertEqual(report["divergences"], 0, report)
        self.assertFalse(marker.exists())
        self.assertEqual(len(self.mock.requests), before)

    def test_explicit_step_limits_replay_from_run_metadata(self):
        config = self.home / "config.toml"
        for limit in (1, 2):
            with self.subTest(max_steps=limit):
                config.write_text(f"[limits]\nmax_steps = {limit}\n")
                for step in range(1, limit + 1):
                    self.mock.reply(codes=[f'console.log("step-{step}");',
                                           '"x".repeat(20000)'])
                before = len(self.mock.requests)
                result = self.command("ask", "--json", "limited replay probe", check=False)
                self.assertEqual(result.returncode, 1, result.stderr)
                events = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(events[-1]["error"]["steps"], limit)
                session = events[0]["start"]["session_id"]
                self.assertEqual(len(self.mock.requests) - before, limit)
                records = jsonl(self.home / "sessions" / f"{session}.jsonl")
                runs = [run for record in records for run in record.get("run_results", [])]
                self.assertEqual([run["remaining_steps"] for run in runs],
                                 [limit - step for step in range(1, limit + 1) for _ in range(2)])
                # Replay must use recorded metadata, not the current limit.
                config.unlink()
                before = len(self.mock.requests)
                for step in range(1, limit + 1):
                    for run in range(2):
                        report = self.replay(session, "--run", f"{step}:{run}")
                        self.assertIs(report["match"], True, report)
                        self.assertTrue(report["output"].endswith(
                            f"\n[{limit - step} Steps left in this Turn]"), report)
                report = self.replay(session, "--all")
                self.assertEqual(report["matched"], limit * 2, report)
                self.assertEqual(report["divergences"], 0, report)
                self.assertEqual(len(self.mock.requests), before)

    def test_unlimited_and_legacy_logs_replay_without_step_suffix(self):
        session = self.ask(['console.log("legacy output");'])
        main = self.home / "sessions" / f"{session}.jsonl"
        records = jsonl(main)
        runs = [run for record in records for run in record.get("run_results", [])]
        self.assertTrue(runs)
        self.assertTrue(all("remaining_steps" not in run for run in runs))
        (self.home / "config.toml").write_text("[limits]\nmax_steps = 1\n")
        before = len(self.mock.requests)
        current = self.replay(session, "--run", "1:0")
        self.assertIs(current["match"], True, current)
        self.assertEqual(current["output"], "legacy output")
        for record in records:
            record.pop("run_results", None)
        main.write_text("".join(json.dumps(row) + "\n" for row in records))
        legacy = self.replay(session, "--run", "1:0")
        self.assertEqual(legacy, current)
        self.assertEqual(len(self.mock.requests), before)

    def test_resume_exposes_changed_turn_budget_without_rewriting_system(self):
        self.mock.reply(text="initial complete")
        result = self.command("ask", "--json", "initial prompt")
        events = [json.loads(line) for line in result.stdout.splitlines()]
        session = events[0]["start"]["session_id"]
        main = self.home / "sessions" / f"{session}.jsonl"
        original_header = jsonl(main)[0]
        config = self.home / "config.toml"
        for limit in (1, 3):
            config.write_text(f"[limits]\nmax_steps = {limit}\n")
            self.mock.reply(text="resumed complete")
            self.command("ask", "--json", "resumed prompt", "--resume", session)
            user = [m["content"] for m in self.mock.requests[-1]["messages"] if m["role"] == "user"][-1]
            self.assertIn(f"This Turn may use at most {limit} Steps", user)
            self.assertTrue(user.endswith("\n\nresumed prompt"))
            self.assertEqual(jsonl(main)[0], original_header)

        config.unlink()
        self.mock.reply(text="unlimited again")
        self.command("ask", "--json", "unlimited prompt", "--resume", session)
        user = [m["content"] for m in self.mock.requests[-1]["messages"] if m["role"] == "user"][-1]
        self.assertEqual(user, "unlimited prompt")
        self.assertEqual(jsonl(main)[0], original_header)

    def test_sleep_records_and_replays_without_real_wait(self):
        session = self.ask([
            'const pending = tools.sleep(80); '
            'console.log(await tools.sleep(5)); await pending; console.log("awake");'
        ])
        path = self.calls_path(session)
        rows = jsonl(path)
        calls = [r for r in rows if "index" in r]
        self.assertEqual([(r["index"], r["seq"], r["name"], r["args"]) for r in calls],
                         [(1, 0, "sleep", 5), (0, 1, "sleep", 80)])
        self.assertTrue(all(r["ok"] for r in calls))
        self.assertEqual(calls[0]["result"], "null")
        self.assertEqual(calls[1]["result"], {"same_as": calls[0]["sha256"]})
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["match"], report)
        self.assertIn("awake", report["output"])
        # Matching long recorded waits must not turn into real replay timers.
        for row in rows:
            if "index" in row:
                row["args"] = 2147483647
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        script = self.cwd / "sleep.js"
        script.write_text('console.log(await tools.sleep(2147483647)); '
                          'await tools.sleep(2147483647); console.log("awake");')
        report = self.replay(session, "--run", "1:0", "--script", str(script))
        self.assertIn("awake", report["output"])
        self.assertFalse(report["incomplete"], report)

    def test_worker_and_expired_sleep_replay_preserve_microtask_checkpoints(self):
        session = self.ask([
            'const p = tools.bash({command: "printf ready"}); await tools.sleep(0); '
            'let n = 0; for (let i = 0; i < 20000000; i++) n += i; '
            'const q = tools.sleep(0); console.log(await Promise.race(['
            'p.then(() => "worker").then(x => x).then(x => x), q.then(() => "timer")]));'
        ])
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["match"], report)
        self.assertFalse(report["incomplete"], report)

    def test_rejected_run_discards_sleep_without_fabricating_a_settlement(self):
        session = self.ask(['tools.sleep(2147483647); throw new Error("stop");'])
        rows = jsonl(self.calls_path(session))
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(rows[0]["meta"]["end"], "error")
        self.assertTrue(rows[0]["meta"]["incomplete"])
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["incomplete"], report)
        self.assertIsNone(report["match"])

    def set_recording(self, value):
        if value is None:
            self.env.pop("NIB_RECORD", None)
        else:
            self.env["NIB_RECORD"] = value

    def test_recording_environment_and_main_log_metrics(self):
        (self.cwd / "sample.txt").write_text("recording probe")
        baseline = None
        for value in (None, "on", "off", "", "1", "0", "false", "OFF"):
            with self.subTest(value=value):
                self.set_recording(value)
                session = self.ask(['console.log(await tools.read({path: "sample.txt"}));'])
                enabled = value is not None and value != "off"
                self.assertEqual(self.calls_path(session).exists(), enabled)
                rows = jsonl(self.home / "sessions" / f"{session}.jsonl")
                steps = [r for r in rows if "model_ms" in r]
                self.assertEqual(len(steps), 2)
                step = steps[0]
                self.assertGreater(step["tool_bytes"], 0)
                self.assertGreaterEqual(step["run_ms"], 0)
                self.assertEqual(step["tool_bytes"], sum(c["result_bytes"] for c in step["calls"]))
                self.assertEqual(step["output_bytes"], sum(r["output_bytes"] for r in step["run_results"]))
                metrics = (step["tool_bytes"], step["output_bytes"],
                           [m["content"] for m in step["messages"] if m["role"] == "tool"])
                if baseline is None:
                    baseline = metrics
                self.assertEqual(metrics, baseline)
                if enabled:
                    self.assertTrue(self.replay(session, "--run", "1:0")["match"])
                else:
                    self.assertIn("No replay recording",
                                  self.command("replay", session, "--all", check=False).stderr)

    def test_resume_uses_current_environment_and_preserves_existing_sidecar(self):
        code = 'console.log(await tools.read({path: "sample.txt"}));'
        (self.cwd / "sample.txt").write_text("resume probe")
        session = self.ask([code])
        path = self.calls_path(session)
        recorded = path.read_bytes()
        # A partial, uncommitted tail would be repaired if restore were entered.
        path.write_bytes(recorded + b'{"step":999,"partial":')
        path.chmod(0o640)
        before = path.stat()
        for value in (None, "off"):
            with self.subTest(value=value):
                self.set_recording(value)
                if value is None:
                    self.mock.reply(codes=[code])
                    self.mock.reply()
                    events = [json.loads(line) for line in self.command(
                        "ask", "--json", "--continue", "continue probe").stdout.splitlines()]
                    self.assertEqual(events[0]["start"]["session_id"], session)
                else:
                    self.assertEqual(self.ask([code], resume=session), session)
                self.assertEqual(path.read_bytes(), recorded + b'{"step":999,"partial":')
                after = path.stat()
                self.assertEqual((after.st_mtime_ns, after.st_size, stat.S_IMODE(after.st_mode)),
                                 (before.st_mtime_ns, before.st_size, stat.S_IMODE(before.st_mode)))
                rows = jsonl(self.home / "sessions" / f"{session}.jsonl")
                self.assertEqual(sum("model_ms" in r for r in rows), 4 if value is None else 6)

    def test_enable_on_resume_records_only_new_runs_and_replay_ignores_switch(self):
        self.set_recording(None)
        session = self.ask(['console.log("unrecorded");'])
        self.assertFalse(self.calls_path(session).exists())
        self.set_recording("on")
        self.ask(['console.log("recorded");'], resume=session)
        for value in (None, "off"):
            self.set_recording(value)
            self.assertTrue(self.replay(session, "--run", "3:0")["match"])
            self.assertIn("No replay recording", self.command(
                "replay", session, "--run", "1:0", check=False).stderr)
            self.assertEqual(self.replay(session, "--all")["total"], 1)

    def test_disabled_recording_inherits_into_new_and_resumed_children(self):
        for value in (None, "off"):
            with self.subTest(value=value):
                self.set_recording(value)
                args = json.dumps({"prompt": "child probe", "fork": value is None})
                self.mock.reply(codes=[f"console.log(await tools.agent({args}));"])
                self.mock.reply(codes=['console.log("child first");'])
                self.mock.reply(text="child finished")
                self.mock.reply(text="parent finished")
                events = [json.loads(line) for line in self.command("ask", "--json", "parent").stdout.splitlines()]
                parent = events[0]["start"]["session_id"]
                self.mock.reply(codes=['console.log(await tools.agent({prompt: "child again", resume: "a1"}));'])
                self.mock.reply(codes=['console.log("child resumed");'])
                self.mock.reply(text="child finished")
                self.mock.reply(text="parent finished")
                self.command("ask", "--json", "--resume", parent, "resume parent")
                main = jsonl(self.home / "sessions" / f"{parent}.jsonl")
                agent = next(c for r in main for c in r.get("calls", []) if c["name"] == "agent")
                self.assertTrue(agent["ok"], agent)
                children = [p for p in (self.home / "sessions").glob("*.jsonl")
                            if not p.name.endswith(".calls.jsonl")
                            and jsonl(p)[0].get("parent_session_id") == parent]
                self.assertEqual(len(children), 1)
                child = jsonl(children[0])
                self.assertEqual(sum("model_ms" in r for r in child), 4)
                self.assertIn("child resumed", children[0].read_text())
                self.assertFalse(list((self.home / "sessions").glob("*.calls.jsonl")))

    def test_child_resume_recording_follows_current_environment(self):
        self.mock.reply(codes=['console.log(await tools.agent({prompt: "child probe"}));'])
        self.mock.reply(codes=['console.log("child recorded");'])
        self.mock.reply(text="child finished")
        self.mock.reply(text="parent finished")
        events = [json.loads(line) for line in self.command("ask", "--json", "parent").stdout.splitlines()]
        parent = events[0]["start"]["session_id"]
        saved = {p: (p.read_bytes(), p.stat().st_mtime_ns)
                 for p in (self.home / "sessions").glob("*.calls.jsonl")}
        self.assertEqual(len(saved), 2)
        child_path = next(p for p in saved if p != self.calls_path(parent))
        child = child_path.name.removesuffix(".calls.jsonl")
        for value in (None, "off", "on"):
            with self.subTest(value=value):
                self.set_recording(value)
                self.mock.reply(codes=['console.log(await tools.agent({prompt: "resume child", resume: "a1"}));'])
                self.mock.reply(codes=['console.log("child resumed");'])
                self.mock.reply(text="child finished")
                self.mock.reply(text="parent finished")
                self.command("ask", "--json", "--resume", parent, "resume parent")
                self.assertEqual(set((self.home / "sessions").glob("*.calls.jsonl")), set(saved))
                for path, (data, mtime) in saved.items():
                    if value == "on":
                        self.assertNotEqual(path.read_bytes(), data)
                    else:
                        self.assertEqual(path.read_bytes(), data)
                        self.assertEqual(path.stat().st_mtime_ns, mtime)
        rows = jsonl(self.home / "sessions" / f"{child}.jsonl")
        self.assertEqual(sum("model_ms" in r for r in rows), 8)
        self.assertEqual([(r["step"], r["run"]) for r in jsonl(child_path) if "meta" in r],
                         [(1, 0), (7, 0)])
        self.assertEqual(self.replay(child, "--all")["matched"], 2)

    def test_parent_and_child_have_separate_recordings(self):
        (self.cwd / "child.txt").write_text("child local result")
        self.mock.reply(codes=['console.log(await tools.agent({prompt: "child probe"}));'])
        self.mock.reply(codes=['console.log(typeof tools.agent, await tools.read({path: "child.txt"}));'])
        self.mock.reply(text="child finished")
        self.mock.reply(text="parent finished")
        events = [json.loads(line) for line in self.command("ask", "--json", "parent probe").stdout.splitlines()]
        session = events[0]["start"]["session_id"]
        parent = jsonl(self.calls_path(session))
        agent = next(row for row in parent if row.get("name") == "agent")
        result = json.loads(agent["result"])
        self.assertTrue(result["ok"], result)
        children = [path for path in (self.home / "sessions").glob("*.calls.jsonl")
                    if path != self.calls_path(session)]
        self.assertEqual(len(children), 1)
        child = children[0].name.removesuffix(".calls.jsonl")
        self.assertEqual({row["name"] for row in jsonl(children[0]) if "name" in row}, {"read"})
        (self.cwd / "child.txt").unlink()
        before = len(self.mock.requests)
        self.assertEqual(self.replay(session, "--all")["matched"], 1)
        self.assertEqual(self.replay(child, "--all")["matched"], 1)
        self.assertEqual(len(self.mock.requests), before)

    def test_fork_replays_only_child_runs_across_compaction_and_resume(self):
        parent_code = 'console.log("parent-only", await tools.read({path: "parent.txt"}));'
        child_code = 'console.log("child-only", await tools.read({path: "child.txt"}));'
        (self.cwd / "parent.txt").write_text("parent file result")
        (self.cwd / "child.txt").write_text("child file result")
        self.mock.reply(codes=[parent_code])
        self.mock.reply(codes=['console.log(await tools.agent({prompt: "fork probe", fork: true}));'])
        self.mock.reply(codes=[child_code])
        self.mock.reply(text="child finished")
        self.mock.reply(text="parent finished")
        events = [json.loads(line) for line in self.command(
            "ask", "--json", "parent fork probe").stdout.splitlines()]
        parent = events[0]["start"]["session_id"]
        agent = next(row for row in jsonl(self.calls_path(parent)) if row.get("name") == "agent")
        result = json.loads(agent["result"])
        self.assertTrue(result["ok"], result)
        children = [path for path in (self.home / "sessions").glob("*.jsonl")
                    if not path.name.endswith(".calls.jsonl") and path.stem != parent]
        self.assertEqual(len(children), 1, children)
        main = children[0]
        child = main.stem
        records = jsonl(main)
        header = records[0]
        self.assertEqual(header["forked_from"]["session"], parent)
        inherited = [m for m in header["messages"] if m["role"] == "assistant"]
        self.assertEqual(len(inherited), 2)
        inherited_codes = [json.loads(call["function"]["arguments"])["code"]
                           for m in inherited for call in m.get("tool_calls", [])]
        self.assertIn(parent_code, inherited_codes)
        self.assertEqual([(r["step"], r["run"]) for r in jsonl(self.calls_path(child))
                          if "meta" in r], [(1, 0)])
        (self.cwd / "parent.txt").unlink()
        (self.cwd / "child.txt").unlink()

        def check_replay(expected):
            before = len(self.mock.requests)
            report = self.replay(child, "--all")
            self.assertEqual(report["total"], len(expected), report)
            self.assertEqual(report["matched"], len(expected), report)
            self.assertEqual(report["divergences"], 0, report)
            self.assertEqual(report["undetermined"], 0, report)
            self.assertEqual([r["run"] for r in report["reports"]], list(expected))
            for entry in report["reports"]:
                self.assertIn(expected[entry["run"]], entry["output"])
                self.assertNotIn("parent-only", entry["output"])
                single = self.replay(child, "--run", entry["run"])
                self.assertTrue(single["match"], single)
                self.assertFalse(single["incomplete"], single)
                self.assertEqual(single["output"], entry["output"])
            self.assertEqual(len(self.mock.requests), before)
            self.assertFalse((self.cwd / "parent.txt").exists())
            self.assertFalse((self.cwd / "child.txt").exists())

        check_replay({"1:0": "child-only"})
        before = len(self.mock.requests)
        self.assertEqual(self.replay(parent, "--all")["matched"], 2)
        self.assertEqual(len(self.mock.requests), before)
        replacement = {"from": 1, "messages": [
            {"role": "user", "content": "compacted child summary"},
            {"role": "assistant", "content": "child finished"}], "context_tokens": 50}
        with main.open("a") as stream:
            stream.write(json.dumps(replacement) + "\n")
        check_replay({"1:0": "child-only"})

        self.mock.reply(codes=['console.log(await tools.agent({prompt: "resume fork", resume: "a1"}));'])
        self.mock.reply(codes=['console.log("resumed-child-only");'])
        self.mock.reply(text="child resumed finished")
        self.mock.reply(text="parent resumed finished")
        self.command("ask", "--json", "resume parent", "--resume", parent)
        agents = [r for r in jsonl(self.calls_path(parent)) if r.get("name") == "agent"]
        self.assertEqual(len(agents), 2)
        self.assertTrue(json.loads(agents[-1]["result"])["ok"], agents[-1])
        self.assertEqual([(r["step"], r["run"]) for r in jsonl(self.calls_path(child))
                          if "meta" in r], [(1, 0), (3, 0)])
        check_replay({"1:0": "child-only", "3:0": "resumed-child-only"})

    def test_script_lookup_and_unrecorded_rejection(self):
        session = self.record_files()
        script = self.tmp / "lookup.js"
        script.write_text(
            'console.log((await tools.read({path: "sample.txt"})).text);\n'
            'console.log((await tools.read({path: "sample.txt"})).text);\n'
            'try { await tools.read({path: "never-recorded.txt"}); } '
            'catch (e) { console.log("MISS:" + e.message); }\n')
        (self.cwd / "sample.txt").unlink()
        report = self.replay(session, "--run", "1:0", "--script", str(script))
        self.assertGreaterEqual(report["output"].count("alpha"), 4, report)
        self.assertIn("not recorded", report["output"].lower(), report)
        self.assertFalse((self.cwd / "never-recorded.txt").exists())

    def test_first_argument_divergence(self):
        session = self.record_files()
        path = self.calls_path(session)
        rows = jsonl(path)
        first = next(r for r in rows if "index" in r)
        first["args"]["path"] = "tampered.txt"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        report = self.replay(session, "--run", "1:0", check=False)
        self.assertFalse(report["match"], report)
        self.assertTrue(report["divergence"], report)
        self.assertFalse(report["incomplete"], report)
        difference = report["divergence"]
        for detail in ("index 0", "expected name=read", 'args={"path":"tampered.txt"}',
                       "actual name=read", 'args={"path":"sample.txt"}'):
            self.assertIn(detail, difference)
        all_report = self.replay(session, "--all")
        self.assertEqual(all_report["divergences"], 1, all_report)
        self.assertEqual(all_report["differences"], [{"run": "1:0", "divergence": difference}])
        plain = self.command("replay", session, "--all")
        self.assertIn("replay 1:0: diff:", plain.stdout)
        self.assertIn(difference, plain.stdout)
        plain = self.command("replay", session, "--run", "1:0")
        self.assertIn("replay 1:0: diff", plain.stderr)

    def test_date_now_is_fixed_and_flagged(self):
        session = self.ask(['console.log("CLOCK", Date.now(), Date.now());'])
        first = self.replay(session, "--run", "1:0", check=False)
        second = self.replay(session, "--run", "1:0", check=False)
        self.assertTrue(first["uses_time"], first)
        self.assertFalse(first["uses_random"], first)
        self.assertEqual(first["output"], second["output"])
        clock = first["output"].split("CLOCK ", 1)[1].splitlines()[0].split()
        self.assertEqual(len(clock), 2, first)
        self.assertEqual(clock[0], clock[1], first)
        start = next(r for r in jsonl(self.calls_path(session)) if "meta" in r)
        self.assertEqual(int(clock[0]), start["meta"]["start_ms_epoch"])

    def test_zero_call_runs_and_output_differences(self):
        session = self.ask(['42', 'console.log("zero tools");'])
        rows = jsonl(self.calls_path(session))
        self.assertEqual(len(rows), 2, rows)
        self.assertTrue(all("meta" in row for row in rows))
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 2, report)
        self.assertEqual(report["matched"], 2, report)
        plain = self.command("replay", session, "--run", "1:0")
        self.assertIn("replay 1:0: match", plain.stderr)
        main = self.home / "sessions" / f"{session}.jsonl"
        records = jsonl(main)
        for record in records:
            for message in record.get("messages", []):
                if message.get("role") == "tool":
                    message["content"] = "changed output"
        main.write_text("".join(json.dumps(row) + "\n" for row in records))
        report = self.replay(session, "--all")
        self.assertEqual(report["divergences"], 2, report)
        self.assertEqual({d["run"] for d in report["differences"]}, {"1:0", "1:1"})
        self.assertTrue(all("differs" in d["divergence"] for d in report["differences"]))
        plain = self.command("replay", session, "--all")
        self.assertIn("replay 1:0: diff:", plain.stdout)
        self.assertIn("replay 1:1: diff:", plain.stdout)

    def test_missing_meta_and_explicit_termination(self):
        session = self.record_files()
        path = self.calls_path(session)
        rows = jsonl(path)
        unfinished = [r for r in rows if not ("meta" in r and r["run"] == 0)]
        path.write_text("".join(json.dumps(row) + "\n" for row in unfinished))
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["incomplete"], report)
        self.assertIsNone(report["match"])
        self.assertIsNone(report["end"])
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 2, report)
        self.assertEqual(report["undetermined"], 1, report)
        for end in ("timeout", "cancelled"):
            for row in rows:
                if "meta" in row and row["run"] == 0:
                    row["meta"]["end"] = end
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            report = self.replay(session, "--run", "1:0")
            self.assertEqual(report["end"], end)
            self.assertTrue(report["incomplete"], report)
            self.assertIsNone(report["match"])
            plain = self.command("replay", session, "--run", "1:0")
            self.assertIn(f"end={end}", plain.stderr)
            plain = self.command("replay", session, "--all")
            self.assertIn(f"end={end}", plain.stdout)

    def test_reject_text_is_not_deduplicated(self):
        session = self.ask([
            'for(let i=0;i<2;i++){try{await tools.read({path:"missing"});}'
            'catch(e){console.log(e.message);}}'
        ])
        calls = [r for r in jsonl(self.calls_path(session)) if "index" in r]
        self.assertEqual(len(calls), 2, calls)
        for row in calls:
            self.assertFalse(row["ok"])
            self.assertIsInstance(row["error"], str)
            self.assertNotIn("result", row)
            self.assertNotIn("same_as", row)
        self.assertEqual(calls[0]["error"], calls[1]["error"])
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["match"], report)

    def test_kill_second_run_then_resume_discards_uncommitted_step(self):
        (self.cwd / "kept.txt").write_text("committed result")
        (self.cwd / "orphan.txt").write_text("orphan-only result")
        session = self.ask(['console.log(await tools.read({path: "kept.txt"}));'])
        path = self.calls_path(session)
        retained = path.read_bytes()
        main = self.home / "sessions" / f"{session}.jsonl"
        committed = main.read_bytes()
        self.mock.reply(codes=[
            'console.log(await tools.read({path: "orphan.txt"}));',
            'await tools.bash({command: "printf started > second-started; sleep 30"});',
        ])
        proc = subprocess.Popen([str(BIN), "ask", "--json", "crash this turn",
                                 "--resume", session], cwd=self.cwd, env=self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        try:
            wait_for(lambda: (self.cwd / "second-started").exists(), "second Run dispatched")
            rows = jsonl(path)
            self.assertEqual([(r["step"], r["run"]) for r in rows if "meta" in r],
                             [(1, 0), (3, 0)])
            self.assertTrue(path.read_bytes().startswith(retained))
            current = main.read_bytes()
            self.assertTrue(current.startswith(committed))
            additions = [json.loads(line) for line in current[len(committed):].splitlines()]
            self.assertTrue(additions)
            self.assertTrue(all((r.get("bash") or r.get("source")) and not r["messages"] for r in additions))
        finally:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate(timeout=10)
        self.ask([
            'console.log(await tools.read({path: "orphan.txt"}));',
            'console.log(await tools.read({path: "kept.txt"}));',
        ], resume=session)
        rows = jsonl(path)
        self.assertTrue(path.read_bytes().startswith(retained))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual([(r["step"], r["run"]) for r in rows if "meta" in r],
                         [(1, 0), (3, 0), (3, 1)])
        resumed = [r for r in rows if r["step"] == 3 and "index" in r]
        self.assertIsInstance(resumed[0]["result"], str)
        self.assertIsInstance(resumed[1]["result"], dict)
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 3, report)
        self.assertEqual(report["matched"], 3, report)
        self.assertEqual(report["undetermined"], 0, report)
        self.assertEqual(report["divergences"], 0, report)
        self.assertEqual([r["run"] for r in report["reports"]], ["1:0", "3:0", "3:1"])

    def test_ordinary_errors_drain_pending_calls_and_replay_completely(self):
        (self.cwd / "sample.txt").write_text("settled")
        session = self.ask([
            'await Promise.all([tools.bash({command: "sleep 2"}), tools.read({path: "missing"})])',
            'await tools.read({path: "sample.txt"}); tools.bash({command: "sleep 2"}); '
            'throw new Error("missing highest index")',
            'tools.read({path: "missing"}); throw new Error("before dispatch")',
            'await tools.read({path: "missing"})',
            'throw new Error("no calls")',
            'await tools.read({path: "sample.txt"}); throw new Error("all settled")',
        ])
        rows = jsonl(self.calls_path(session))
        metas = [r["meta"] for r in rows if "meta" in r]
        self.assertEqual(len(metas), 6, rows)
        for meta in metas:
            self.assertEqual(meta["end"], "error")
            self.assertNotIn("incomplete", meta)
        self.assertEqual([r["index"] for r in rows if r["run"] == 0 and "index" in r], [1, 0])
        self.assertEqual([r["index"] for r in rows if r["run"] == 1 and "index" in r], [0, 1])
        self.assertEqual([r["index"] for r in rows if r["run"] == 2 and "index" in r], [0])
        for index in range(6):
            report = self.replay(session, "--run", f"1:{index}")
            self.assertEqual(report["end"], "error", report)
            self.assertFalse(report["incomplete"], report)
            self.assertIs(report["match"], True, report)
            self.assertIsNone(report["divergence"], report)
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 6, report)
        self.assertEqual(report["matched"], 6, report)
        self.assertEqual(report["undetermined"], 0, report)
        self.assertEqual(report["divergences"], 0, report)
        self.assertEqual(report["differences"], [], report)

    def test_reflect_does_not_read_or_publish_calls(self):
        marker = "PRIVATE_CALLS_ONLY_7e4eb7d95c6b"
        fakebin = self.tmp / "bin"
        fakebin.mkdir()
        body_path = self.tmp / "published-body"
        args_path = self.tmp / "published-args"
        gh = fakebin / "gh"
        gh.write_text("""#!/bin/sh
if [ "$2" = list ]; then echo '[]'; exit 0; fi
printf '%s\\n' "$@" > "$FAKE_GH_ARGS"
cat > "$FAKE_GH_BODY"
echo https://example.invalid/issues/1
""")
        gh.chmod(0o700)
        env = dict(self.env, PATH=str(fakebin) + os.pathsep + self.env.get("PATH", ""),
                   NIB_ISSUE_REPO="test/replay-privacy", FAKE_GH_BODY=str(body_path),
                   FAKE_GH_ARGS=str(args_path))
        self.mock.reply(text="baseline complete")
        terminal = Terminal(self.cwd, env)
        try:
            terminal.send("privacy baseline\r")
            def main_log():
                paths = list((self.home / "sessions").glob("*.jsonl"))
                return next((p for p in paths if not p.name.endswith(".calls.jsonl")
                             and "baseline complete" in p.read_text()), None)
            log = wait_for(main_log, "baseline committed")
            terminal.wait_turn("baseline complete")
            secret_result = json.dumps({"text": marker, "next_offset": None})
            secret_rows = [
                {"step": 1, "run": 0, "index": 0, "seq": 0, "name": "read",
                 "args": {"path": "private-only.txt"}, "ok": True, "result": secret_result,
                 "sha256": hashlib.sha256(secret_result.encode()).hexdigest(), "truncated": False},
                {"step": 1, "run": 0, "meta": {"start_ms_epoch": 1234, "end": "ok"}},
            ]
            calls = self.calls_path(log.stem)
            calls.write_text("".join(json.dumps(row) + "\n" for row in secret_rows))
            calls.chmod(0o600)
            self.mock.reply(codes=["console.log(await tools.read({path: " + json.dumps(str(log)) + "}));"])
            self.mock.reply(text="### Issue drafts\n```json\n" + json.dumps([
                {"title": "Replay privacy regression probe", "body": "Synthetic harness-only evidence."}]) + "\n```")
            before = len(self.mock.requests)
            terminal.send("/reflect\r")
            wait_for(body_path.exists, "fake gh publication")
            terminal.until(b"filed")
            reflection_requests = self.mock.requests[before:]
            self.assertGreaterEqual(len(reflection_requests), 2)
            self.assertNotIn(marker, json.dumps(reflection_requests, ensure_ascii=False))
            prompt = next(m["content"] for m in reflection_requests[0]["messages"]
                          if m["role"] == "user" and "This is a reflection" in m.get("content", ""))
            self.assertIn(str(log), prompt)
            self.assertIn("Read only the explicitly specified main log path for this session", prompt)
            self.assertIn("Do not enumerate, glob, or search the sessions directory", prompt)
            self.assertIn("`.calls.jsonl`", prompt)
            self.assertNotIn("parent_session_id is", prompt)
            self.assertNotIn(marker, body_path.read_text())
            self.assertNotIn(marker, args_path.read_text())
            self.assertIn("Synthetic harness-only evidence.", body_path.read_text())
            self.assertNotIn(marker, (self.home / "reflections.md").read_text())
        finally:
            terminal.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
