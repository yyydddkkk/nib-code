"""Automatic whole-Run yielding, against local mocks without real credentials."""
import contextlib
from mock_http import ThreadingHTTPServer
import http.server
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from mock_agent import reply
from test_agent import alive
from test_agent_reuse import system
from test_interjections import Terminal
from test_llm import wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class Mock(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, cwd):
        self.cwd = cwd
        self.requests = []
        self.case = "overlap"
        self.provider = "chat_completions"
        self.release = threading.Event()
        self.followup = threading.Event()
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.release.wait(10)
        body = b"wait-result"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        index = len(self.server.requests)
        self.server.requests.append(request)
        case = self.server.case
        if case == "request-failure":
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"mock refused request"}}')
            return
        code = None
        if case.startswith("replace-"):
            mode = case.removeprefix("replace-")
            delay = "30" if mode in ("run", "bash", "detached") else ".4"
            command = "echo $$ >> workers.pid; if [ ! -e started ]; then touch started; sleep " + delay + "; fi; printf checked"
            if mode == "cancel":
                command = "echo $$ >> workers.pid; sleep 30"
            if index == 0:
                options = dict(command=command)
                if mode in ("bash", "detached"):
                    options["background"] = True
                if mode == "detached":
                    options["detached"] = True
                code = ("await tools.write({path:'source.txt',content:'before'}); "
                        "const r=await tools.bash(" + json.dumps(options) + "); "
                        "console.log('await-resolved',r); r")
            elif index == 1:
                wait_for(lambda: (self.server.cwd / ("workers.pid" if mode == "cancel" else "started")).exists())
                change = ""
                if mode != "unchanged":
                    change = "await tools.write({path:'source.txt',content:" + json.dumps("before" if mode == "noop" else "after") + "}); "
                if mode == "different":
                    command += " "
                code = change + "await tools.bash(" + json.dumps(dict(command=command)) + ")"
            elif mode == "cancel":
                self.server.followup.set()
                self.server.release.wait(10)
        elif case == "repair":
            if index == 0:
                code = {"base": "1:0", "edits": [
                    {"old_text": "await tools.sleep(200); throw new Error('late-failure🙂')", "new_text": "'repaired'"}]}
        elif case in ("fold-failure", "wait-failure"):
            if index == 0:
                code = "await tools.sleep(200); throw new Error('late-failure🙂')"
            elif index == 1:
                if case == "fold-failure":
                    time.sleep(.5)
                    code = "'independent-result'"
                else:
                    code = "await tools.wait(['r1'])"
        elif case == "done":
            pass
        elif case == "wait-unavailable":
            if index == 0:
                code = "({exposed: 'wait' in tools, type: typeof tools.wait})"
        elif case == "resume":
            code = "await tools.sleep(150); 'resumed-result'" if index == 0 else None
        elif index == 0:
            if case in ("wait", "empty-wait", "stop-reason"):
                script = ("import sys, urllib.request; print('stdout-before', flush=True); "
                          "print(urllib.request.urlopen(" + repr(f"http://127.0.0.1:{self.server.server_port}/work") + ").read().decode(), flush=True); "
                          "print('stderr-after', file=sys.stderr)")
                code = "await tools.bash(" + json.dumps({"command": shlex.join([sys.executable, "-c", script])}) + ")"
            elif case == "timeout":
                code = "await tools.bash(" + json.dumps({"command": "echo $$ > worker.pid; sleep 30", "timeout_ms": 500}) + ")"
            elif case == "recovery":
                code = "await tools.write({path:'changed.txt',content:'partial work'}); await tools.bash({command:'echo $$ > worker.pid; sleep 30'})"
            elif case in ("cancel", "crash", "stop", "wait-cancel"):
                command = "echo $$ > worker.pid; sleep 30; echo should-not-finish"
                code = "const r=await tools.bash(" + json.dumps({"command": command}) + "); if(r.exit_code!==null) throw new Error('stop did not kill command'); r"
            elif case == "limit":
                code = "await tools.sleep(220); console.log('limit-result')"
            elif case == "reject":
                code = "await tools.sleep(200); throw new Error('late failure')"
            elif case == "budget":
                code = "console.log('prefix-before-yield'); await tools.sleep(200); console.log('x'.repeat(40000)); 'tail-result'"
            elif case == "multiple":
                code = "await tools.sleep(400); await tools.write({path:'first.txt',content:'first'}); 'first-result'"
            elif case == "slots":
                code = "await tools.sleep(2000); 'slot-result'"
            elif case in ("fold", "wait-tool", "wait-ids"):
                code = "await tools.bash(" + json.dumps({"command": "sleep .2; printf bash-result"}) + ")"
            else:
                command = "sleep .45; printf bash-result"
                code = ("console.log('before-yield'); const r=await tools.bash(" + json.dumps({"command": command}) + "); "
                        "if(r.exit_code!==0) throw new Error('await result changed'); "
                        "await tools.write({path:'late.txt',content:r.output}); console.log('after-yield'); r")
        elif case in ("cancel", "crash"):
            self.server.followup.set()
            self.server.release.wait(10)
        elif case == "empty-wait" and index == 1:
            code = "console.log('')"
        elif case == "stop-reason" and index == 1:
            code = "for(const reason of [undefined,'  ']) {try {await tools.stop({id:'r1',reason}); throw new Error('accepted missing reason')} catch(e) {if(!String(e).includes('nonempty reason')) throw e}}"
        elif case == "stop" and index == 1:
            code = "await tools.stop({id:'r1',reason:'mock requested cancellation'})"
        elif case == "multiple" and index == 1:
            code = "await tools.sleep(180); await tools.write({path:'second.txt',content:'second'}); 'second-result'"
        elif case == "slots" and index < 9:
            code = "await tools.sleep(2000); 'slot-result'"
        elif case == "fold" and index == 1:
            time.sleep(.6)
            code = "await tools.write({path:'independent.txt',content:'done while waiting'}); 'independent-result'"
        elif case == "wait-cancel" and index == 1:
            code = "await tools.wait()"
        elif case == "wait-tool" and index == 1:
            code = "await tools.wait()"
        elif case == "wait-ids" and index == 1:
            code = "const none = await tools.wait(['r9']); const r = await tools.wait(['r1']); console.log(JSON.stringify({none, ids: r.results.map(x => x.id)}))"
        elif case == "overlap" and index == 1:
            code = "await tools.write({path:'independent.txt',content:'done while waiting'}); 'independent-result'"
        if index > 0 and case not in ("cancel", "crash", "resume"):
            self.server.followup.set()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            reply(self, self.server.provider, code, "Waiting." if case == "wait" and index == 1 else "done" if code is None else "working")


class BackgroundRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = Path(self.tmp.name)
        self.home = self.cwd / "home"
        self.home.mkdir()
        self.config()
        self.server = Mock(self.cwd)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.env = dict(os.environ, NIB_HOME=str(self.home), NIB_PROVIDER="chat_completions",
                        NIB_API_KEY="mock", NIB_RECORD="on", NIB_MODEL="mock",
                        NIB_BASE_URL=f"http://127.0.0.1:{self.server.server_port}")

    def tearDown(self):
        self.server.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def config(self, extra=""):
        (self.home / "config.toml").write_text("[limits]\nrun_background_after_ms = 50\n" + extra)

    def launch(self, *args):
        return subprocess.Popen([str(BIN), "ask", "--json", "initial", *args], cwd=self.cwd,
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def finish(self, process, ok=True, torn=False):
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode == 0, ok, stdout + stderr)
        self.assertEqual(stderr, "")
        events = [json.loads(line) for line in stdout.splitlines()]
        session = events[0]["start"]["session_id"]
        rows = []
        for line in (self.home / "sessions" / (session + ".jsonl")).read_text().splitlines():
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                if not torn:
                    raise
        if torn:
            self.assertTrue(any(r.get("repair") for r in rows))
        return events, rows, session

    def results(self, rows):
        return [m for r in rows for m in r.get("messages", []) if m.get("background_kind") == "run"]

    def test_changed_command_supersedes_explicit_bash_and_automatic_run(self):
        for mode in ("run", "bash"):
            with self.subTest(mode=mode):
                self.server.case = "replace-" + mode
                self.server.requests.clear()
                for name in ("started", "workers.pid"):
                    (self.cwd / name).unlink(missing_ok=True)
                _, rows, session = self.finish(self.launch())
                lifecycle = [r["bash"] for r in rows if "bash" in r]
                replaced = [r for r in lifecycle if r["state"] == "superseded"]
                self.assertEqual(len(replaced), 1)
                self.assertEqual((replaced[0]["id"], replaced[0]["superseded_by"]), ("b1", "b2"))
                self.assertLess(replaced[0]["elapsed_ms"], 3000)
                messages = [m for r in rows for m in r.get("messages", []) if m.get("source") == "background"]
                old = next(m for m in messages if m.get("background_kind") == ("run" if mode == "run" else "bash"))
                self.assertTrue(old["background_ok"])
                self.assertIn('"superseded_by":"b2"', old["content"])
                self.assertNotIn('"error"', old["content"])
                if mode == "run":
                    self.assertIn("await-resolved", old["content"])
                    self.assertTrue(old["background_run"]["calls"][1]["ok"])
                for pid in (self.cwd / "workers.pid").read_text().splitlines():
                    wait_for(lambda: not alive(int(pid)))
                stats = json.loads(subprocess.check_output([sys.executable, str(ROOT / "scripts/stats.py"), str(self.home / "sessions" / (session + ".jsonl")), "--json"]))
                self.assertEqual(stats["bash_superseded"], 1)
                self.assertEqual(stats["overall"]["runs_failed"], 0)

    def test_cancel_after_supersession_cleans_both_process_groups(self):
        self.server.case = "replace-cancel"
        process = self.launch()
        self.addCleanup(process.wait, timeout=5)
        self.addCleanup(process.kill)
        self.assertTrue(self.server.followup.wait(5))
        wait_for(lambda: (self.cwd / "workers.pid").exists() and len((self.cwd / "workers.pid").read_text().splitlines()) == 2)
        pids = [int(pid) for pid in (self.cwd / "workers.pid").read_text().splitlines()]
        wait_for(lambda: not alive(pids[0]))
        process.send_signal(signal.SIGINT)
        stdout, _ = process.communicate(timeout=5)
        self.server.release.set()
        for pid in pids:
            wait_for(lambda: not alive(pid))
        session = json.loads(stdout.splitlines()[0])["start"]["session_id"]
        rows = [json.loads(line) for line in (self.home / "sessions" / (session + ".jsonl")).read_text().splitlines()]
        self.assertEqual(sum(r.get("bash", {}).get("state") == "superseded" for r in rows), 1)
        self.assertEqual(sum(r.get("bash", {}).get("state") == "finished" for r in rows), 2)

    def test_unchanged_noop_different_and_detached_are_not_superseded(self):
        for mode in ("unchanged", "noop", "different", "detached"):
            with self.subTest(mode=mode):
                self.server.case = "replace-" + mode
                self.server.requests.clear()
                for name in ("started", "workers.pid"):
                    (self.cwd / name).unlink(missing_ok=True)
                _, rows, _ = self.finish(self.launch())
                self.assertFalse(any(r.get("bash", {}).get("state") == "superseded" for r in rows))
                if mode != "detached":
                    old = self.results(rows)[0]
                    self.assertTrue(old["background_ok"])
                    self.assertIn('"exit_code":0', old["content"])
                for pid in (self.cwd / "workers.pid").read_text().splitlines():
                    wait_for(lambda: not alive(int(pid)))

    def test_empty_runs_wait_and_missing_stop_reason_keeps_work(self):
        for case in ("empty-wait", "stop-reason"):
            with self.subTest(case=case):
                self.server.case = case
                self.server.requests.clear()
                self.server.release.clear()
                self.server.followup.clear()
                previous = set((self.home / "sessions").glob("*.jsonl"))
                process = self.launch()
                wait_for(self.server.followup.is_set)
                log = lambda: [json.loads(line) for f in (self.home / "sessions").glob("*.jsonl")
                               if ".calls." not in f.name and f not in previous for line in f.read_text().splitlines()]
                wait_for(lambda: any(m.get("waiting") for r in log() for m in r.get("messages", [])))
                self.assertEqual(len(self.server.requests), 3 if case == "stop-reason" else 2)
                self.assertIsNone(process.poll())
                self.server.release.set()
                _, rows, _ = self.finish(process)
                self.assertTrue(self.results(rows)[0]["background_ok"])
                self.assertIn("wait-result", self.results(rows)[0]["content"])
                self.assertEqual(len(self.server.requests), 4 if case == "stop-reason" else 3)

    def assert_overlap(self):
        self.env["NIB_RECORD"] = "on"
        events, rows, session = self.finish(self.launch())
        results = self.results(rows)
        self.assertEqual(len(results), 1)
        result = results[0]
        self.assertTrue(result["background_ok"])
        self.assertIn("before-yield\nafter-yield", result["content"])
        self.assertIn('"exit_code":0', result["content"])
        self.assertIn("bash-result", result["content"])
        completion = result["background_run"]
        execution = completion["execution"]
        self.assertGreater(execution["start_ms_epoch"], 0)
        self.assertGreaterEqual(execution["end_ms_epoch"], execution["start_ms_epoch"])
        self.assertAlmostEqual(execution["end_ms_epoch"] - execution["start_ms_epoch"], completion["run_ms"], delta=100)
        self.assertEqual((completion["step"], completion["run_index"]), (1, 0))
        self.assertEqual([c["path"] for c in completion["changes"]], ["late.txt"])
        self.assertEqual([c["name"] for c in completion["calls"]], ["bash", "write"])
        self.assertEqual(completion["tool_bytes"], sum(c["result_bytes"] for c in completion["calls"]))
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertIn("continuing in background as r1", runs[0]["output"])
        self.assertIn("Captured output is preserved", runs[0]["output"])
        self.assertIn("Results arrive automatically as messages", runs[0]["output"])
        self.assertIn("reply briefly without tools", runs[0]["output"])
        self.assertNotIn("tools.wait()", runs[0]["output"])
        self.assertNotIn("before-yield", runs[0]["output"])
        self.assertEqual(runs[0]["changes"], [])
        self.assertEqual([c["path"] for c in runs[1]["changes"]], ["independent.txt"])
        self.assertEqual((self.cwd / "late.txt").read_text(), "bash-result")
        self.assertLess((self.cwd / "independent.txt").stat().st_mtime_ns, (self.cwd / "late.txt").stat().st_mtime_ns)
        lifecycle = [e["background"] for e in events if "background" in e and e["background"]["kind"] == "run"]
        self.assertEqual([e["state"] for e in lifecycle], ["started", "finished"])
        self.assertEqual(events[-1]["end"]["text"], "done")
        replayed = subprocess.run([str(BIN), "replay", session, "--all", "--json"], cwd=self.cwd,
                                  env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(replayed.returncode, 0, replayed.stdout + replayed.stderr)
        replay_report = json.loads(replayed.stdout)
        self.assertEqual(replay_report["divergences"], 0, replay_report)
        self.assertEqual(replay_report["undetermined"], 0, replay_report)
        self.assertEqual(replay_report["matched"], 2, replay_report)
        report = json.loads(subprocess.check_output(["python3", str(ROOT / "scripts/stats.py"), str(self.home / "sessions"), "--json"]))
        self.assertEqual(report["background_runs"]["background_calls"], 1)
        self.assertGreaterEqual(report["background_runs"]["background_steps"]["median"], 1)

    def test_overlap_keeps_await_console_changes_and_replay(self):
        self.assert_overlap()

    def test_codex_overlap_keeps_await_console_changes_and_replay(self):
        self.server.provider = "codex"
        auth = self.cwd / "auth"
        auth.mkdir()
        (auth / "auth.json").write_text(json.dumps({"tokens": {
            "access_token": "fake", "account_id": "fake", "refresh_token": "fake", "id_token": "fake"}}))
        self.env.update(NIB_PROVIDER="codex", NIB_MODEL="gpt-6.1-sol", CODEX_HOME=str(auth))
        self.assert_overlap()

    def test_no_independent_work_waits_without_model_requests_or_final_text(self):
        self.server.case = "wait"
        process = self.launch()
        try:
            self.assertTrue(self.server.followup.wait(5))
            def waiting_step():
                for path in (self.home / "sessions").glob("*.jsonl"):
                    if path.name.endswith(".calls.jsonl"):
                        continue
                    rows = [json.loads(line) for line in path.read_text().splitlines()]
                    if any(m.get("waiting") for r in rows for m in r.get("messages", [])):
                        return rows
            wait_for(waiting_step)
            self.assertIsNone(process.poll())
            self.assertEqual(len(self.server.requests), 2)
        finally:
            self.server.release.set()
        events, rows, _ = self.finish(process)
        self.assertEqual(len(self.server.requests), 3)
        self.assertEqual([e["notice"] for e in events if "notice" in e], ["Waiting."])
        self.assertFalse(any(e.get("delta", {}).get("text") == "Waiting." for e in events))
        self.assertEqual(events[-1]["end"]["text"], "done")
        messages = self.server.requests[-1]["messages"]
        self.assertEqual(messages[-2]["content"], "Waiting.")
        completion = json.loads(messages[-1]["content"].split("\n", 1)[1].removeprefix("result: "))
        self.assertEqual(completion, {"exit_code": 0, "output": "stdout-before\nwait-result\nstderr-after\n"})
        self.assertFalse([c for r in rows for c in r.get("calls", [])])
        self.assertEqual([c["name"] for c in self.results(rows)[0]["background_run"]["calls"]], ["bash"])
        self.assertNotIn("stdout-before", next(e["run_end"]["output"] for e in events if "run_end" in e))
        self.assertNotIn("waiting", messages[-2])

    def finished_records(self, rows):
        return [d["event"] for r in rows for d in r.get("deliveries", [])
                if d["event"]["state"] == "finished"]

    def test_user_delivery_inserts_a_user_message(self):
        self.server.case = "fold"
        self.env["NIB_TUNE"] = "delivery=user"
        _, rows, _ = self.finish(self.launch())
        final = self.server.requests[-1]["messages"]
        self.assertEqual(len([m for m in final if m["role"] == "user"]), 2)
        self.assertNotIn("bash-result", final[-2]["content"])
        self.assertIn("bash-result", final[-1]["content"])
        self.assertEqual(len(self.results(rows)), 1)

    def test_tool_delivery_folds_results_into_the_next_tool_message(self):
        self.server.case = "fold"
        self.env["NIB_TUNE"] = "delivery=tool"
        events, rows, _ = self.finish(self.launch())
        for request in self.server.requests:
            self.assertEqual(len([m for m in request["messages"] if m["role"] == "user"]), 1)
        content = self.server.requests[-1]["messages"][-1]["content"]
        self.assertEqual(self.server.requests[-1]["messages"][-1]["role"], "tool")
        self.assertLess(content.index("independent-result"), content.index("[background run r1 finished]"))
        self.assertIn("bash-result", content)
        self.assertEqual(self.results(rows), [])
        self.assertEqual([r["id"] for r in self.finished_records(rows)], ["r1"])
        finished = [e["background"] for e in events if e.get("background", {}).get("state") == "finished"]
        self.assertEqual([e["id"] for e in finished], ["r1"])
        registration = next(e["run_end"]["output"] for e in events if "run_end" in e)
        self.assertIn("appended to a later Run's output", registration)
        self.assertIn("await tools.wait()", registration)
        self.assertNotIn("reply briefly without tools", registration)
        self.assertEqual(events[-1]["end"]["text"], "done")

    def test_tool_delivery_wait_returns_results_once_and_is_not_backgrounded(self):
        self.server.case = "wait-tool"
        self.env["NIB_TUNE"] = "delivery=tool"
        events, rows, _ = self.finish(self.launch())
        prompt = system(self.server.requests[0])
        self.assertIn("async wait(", prompt)
        self.assertIn("call `await tools.wait()`", prompt)
        final = self.server.requests[-1]["messages"]
        self.assertEqual([m["content"] for m in final if m["role"] == "user"][1:], [])
        self.assertEqual(final[-1]["role"], "tool")
        self.assertIn('"results":[{"id":"r1","kind":"run"', final[-1]["content"])
        self.assertEqual("".join(m["content"] for m in final[1:] if m["role"] != "assistant").count("bash-result"), 1)
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), 2)
        self.assertNotIn("continuing in background", runs[1]["output"])
        self.assertIsNone(runs[1].get("background_id"))
        self.assertEqual([e["background"]["state"] for e in events if e.get("background", {}).get("kind") == "run"], ["started", "finished"])
        self.assertEqual([r["id"] for r in self.finished_records(rows)], ["r1"])
        self.assertEqual(self.results(rows), [])
        waited = next(r for r in rows if r.get("deliveries"))
        self.assertEqual(waited["deliveries"][0]["via"], "wait")
        self.assertEqual(waited["output_bytes"], len(final[-1]["content"].encode()))
        self.assertEqual(rows[-1]["output_bytes"], 0)

    def failing_tool_delivery(self, case):
        self.server.case = case
        self.server.requests.clear()
        self.env["NIB_TUNE"] = "delivery=tool"
        _, rows, session = self.finish(self.launch())
        received = self.server.requests[-1]["messages"][-1]
        self.assertEqual(received["role"], "tool")
        self.assertIn("Source: 1:0", received["content"])
        path = self.home / "sessions" / f"{session}.jsonl"
        return rows, session, path

    def test_failed_tool_delivery_can_rerun(self):
        for case in ("fold-failure", "wait-failure"):
            with self.subTest(case=case):
                rows, session, path = self.failing_tool_delivery(case)
                delivery_step = next(i for i, r in enumerate(rows) if any(
                    m["role"] == "tool" and "Source: 1:0" in m["content"] for m in r["messages"]))
                path.write_bytes(b"".join(path.read_bytes().splitlines(keepends=True)[:delivery_step + 1]))
                self.server.case = "repair"
                self.server.requests.clear()
                self.finish(self.launch("--resume", session))
                output = self.server.requests[-1]["messages"][-1]["content"]
                self.assertIn("repaired", output)

    def test_folded_runs_replay_their_own_output(self):
        _, session, _ = self.failing_tool_delivery("fold-failure")
        result = subprocess.run([str(BIN), "replay", session, "--all", "--json"], cwd=self.cwd,
                                env=self.env, capture_output=True, text=True, timeout=5)
        report = json.loads(result.stdout)
        self.assertEqual((report["matched"], report["divergences"], report["undetermined"]),
                         (2, 0, 0), report)

    def test_legacy_folded_run_completion_is_readable(self):
        rows, session, path = self.failing_tool_delivery("fold-failure")
        legacy = []
        for row in rows:
            deliveries = row.pop("deliveries", [])
            for result in row.get("run_results", []):
                result.pop("output", None)
            for delivery in deliveries:
                completion = delivery["event"]["completion"]
                completion.pop("source_reference")
                launch = next(r["source"] for r in legacy if r.get("source", {}).get("step") == 1)
                legacy.append({"source": dict(launch, failed=True), "messages": [], "from": 0})
            legacy.append(row)
            legacy += [{"background": d["event"], "messages": [], "from": 0} for d in deliveries]
        path.write_text("".join(json.dumps(row) + "\n" for row in legacy))
        result = subprocess.run([str(BIN), "replay", session, "--all", "--json"], cwd=self.cwd,
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["matched"], 2)
        self.server.case = "repair"
        self.server.requests.clear()
        self.finish(self.launch("--resume", session))
        self.assertIn("repaired", self.server.requests[-1]["messages"][-1]["content"])

    def test_resume_after_fold_commit(self):
        rows, session, path = self.failing_tool_delivery("fold-failure")
        lines = path.read_bytes().splitlines(keepends=True)
        folded_index, folded = next((i, r) for i, r in enumerate(rows)
                                    if any(m["role"] == "tool" and "[background run r1 finished]" in m["content"]
                                           for m in r["messages"]))
        tool = next(m for m in folded["messages"] if m["role"] == "tool")
        delivered_bytes = len(tool["content"].split("\n\n[background", 1)[1].encode()) + len("[background")
        end = folded_index + 1
        for tail in (b"", lines[end][:32], lines[end].rstrip(b"\n")):
            with self.subTest(torn_bytes=len(tail)):
                path.write_bytes(b"".join(lines[:end]) + tail)
                self.server.case = "done"
                self.server.requests.clear()
                events, resumed, _ = self.finish(self.launch("--resume", session), torn=bool(tail))
                content = "\n".join(m.get("content") or "" for m in self.server.requests[0]["messages"][1:])
                self.assertEqual(content.count("Source: 1:0"), 1)
                self.assertNotIn("lost: process ended", content)
                self.assertFalse([e["background"] for e in events if e.get("background", {}).get("id") == "r1"])
                self.assertEqual([r["output_bytes"] for r in resumed[end:] if "model_ms" in r], [delivered_bytes])
                self.assertEqual([d["event"]["id"] for r in resumed for d in r.get("deliveries", [])], ["r1"])
                self.server.requests.clear()
                _, again, _ = self.finish(self.launch("--resume", session), torn=bool(tail))
                self.assertEqual(again[-1]["output_bytes"], 0)

    def test_tool_delivery_wait_by_id_reports_tasks_that_are_not_pending(self):
        self.server.case = "wait-ids"
        self.env["NIB_TUNE"] = "delivery=tool"
        events, rows, _ = self.finish(self.launch())
        output = [e["run_end"]["output"] for e in events if "run_end" in e][1]
        self.assertIn('"none":{"ok":true,"results":[],"not_pending":["r9"]}', output)
        self.assertIn('"ids":["r1"]', output)

    def test_tool_delivery_wait_is_canceled_with_the_turn(self):
        self.server.case = "wait-cancel"
        self.env["NIB_TUNE"] = "delivery=tool"
        process = self.launch()
        self.addCleanup(process.wait, timeout=5)
        self.addCleanup(process.kill)
        wait_for(lambda: len(self.server.requests) == 2 and (self.cwd / "worker.pid").exists())
        time.sleep(.5)
        self.assertIsNone(process.poll())
        pid = int((self.cwd / "worker.pid").read_text())
        process.send_signal(signal.SIGINT)
        process.communicate(timeout=10)
        wait_for(lambda: not alive(pid))

    def test_user_delivery_has_no_wait_tool(self):
        self.server.case = "wait-unavailable"
        self.env["NIB_TUNE"] = "delivery=user"
        events, _, _ = self.finish(self.launch())
        prompt = system(self.server.requests[0])
        self.assertNotIn("async wait(", prompt)
        self.assertNotIn("tools.wait(", prompt)
        self.assertIn("reply briefly without tools", prompt)
        run, = [e["run_end"] for e in events if "run_end" in e]
        self.assertTrue(run["ok"], run)
        self.assertEqual(json.loads(run["output"].removeprefix("result: ")),
                         {"exposed": False, "type": "undefined"})

    def test_tool_delivery_falls_back_to_a_user_message_when_the_model_waits_by_replying(self):
        self.server.case = "wait"
        self.env["NIB_TUNE"] = "delivery=tool"
        process = self.launch()
        try:
            self.assertTrue(self.server.followup.wait(5))
            wait_for(lambda: len(self.server.requests) == 2)
            time.sleep(.2)
            self.assertEqual(len(self.server.requests), 2)
        finally:
            self.server.release.set()
        events, rows, _ = self.finish(process)
        messages = self.server.requests[-1]["messages"]
        self.assertEqual((messages[-2]["role"], messages[-2]["content"]), ("assistant", "Waiting."))
        self.assertEqual(messages[-1]["role"], "user")
        self.assertIn("wait-result", messages[-1]["content"])
        self.assertEqual(len(self.results(rows)), 1)

    def test_completed_resume_does_not_redeliver_results(self):
        _, _, session = self.finish(self.launch())
        self.server.case = "resume"
        self.server.requests.clear()
        _, rows, _ = self.finish(self.launch("--resume", session))
        results = self.results(rows)
        self.assertEqual([r["background_id"] for r in results], ["r1", "r2"])
        self.assertFalse(any("lost: process ended" in r["content"] for r in results))

    def test_step_limit_waits_for_delivery_without_extra_request(self):
        self.server.case = "limit"
        self.config("max_steps = 1\n")
        events, rows, _ = self.finish(self.launch(), ok=False)
        self.assertEqual(len(self.server.requests), 1)
        self.assertIn("limit-result", self.results(rows)[0]["content"])
        self.assertIn("waited for background tasks: run r1", events[-1]["error"]["message"])

    def test_late_failure_and_console_budget(self):
        for case in ("reject", "budget"):
            with self.subTest(case=case):
                self.server.case = case
                self.server.requests.clear()
                events, rows, _ = self.finish(self.launch())
                result = self.results(rows)[0]
                self.assertEqual(result["background_ok"], case == "budget")
                output = result["background_run"]["output"]
                self.assertLessEqual(len(output.encode()), 16 * 1024)
                if case == "reject":
                    self.assertIn("late failure", output)
                else:
                    self.assertIn("prefix-before-yield", output)
                    self.assertIn("tail-result", output)
                    self.assertIn("omitted", output)

    def test_multiple_runs_keep_changes_separate(self):
        self.server.case = "multiple"
        _, rows, _ = self.finish(self.launch())
        results = self.results(rows)
        self.assertEqual({r["background_id"] for r in results}, {"r1", "r2"})
        for result in results:
            expected = "first.txt" if result["background_id"] == "r1" else "second.txt"
            self.assertEqual([c["path"] for c in result["background_run"]["changes"]], [expected])

    def test_background_run_limit_keeps_ninth_run_foreground(self):
        self.server.case = "slots"
        events, rows, _ = self.finish(self.launch())
        starts = [e["background"] for e in events if e.get("background", {}).get("kind") == "run" and e["background"]["state"] == "started"]
        self.assertEqual(len(starts), 8)
        self.assertEqual(len(self.results(rows)), 8)
        runs = [e["run_end"]["output"] for e in events if "run_end" in e]
        self.assertIn("slot-result", runs[8])
        self.assertNotIn("continuing in background", runs[8])

    def test_stop_by_id_delivers_canceled_result(self):
        self.server.case = "stop"
        _, rows, _ = self.finish(self.launch())
        result = self.results(rows)[0]
        self.assertFalse(result["background_ok"])
        self.assertIn("run canceled", result["content"])
        self.assertFalse(alive(int((self.cwd / "worker.pid").read_text())))

    def test_explicit_bash_timeout_still_applies_after_run_yields(self):
        self.server.case = "timeout"
        events, rows, _ = self.finish(self.launch())
        self.assertIn("continuing in background as r1", next(e["run_end"]["output"] for e in events if "run_end" in e))
        result = self.results(rows)[0]
        self.assertFalse(result["background_ok"])
        self.assertIn("timed out after 500 ms", result["content"])
        self.assertFalse(alive(int((self.cwd / "worker.pid").read_text())))

    def test_cancel_cleans_process_and_resume_marks_lost(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
            with self.subTest(sig=sig):
                self.server.case = "crash" if sig == signal.SIGKILL else "cancel"
                self.server.requests.clear()
                self.server.followup.clear()
                self.server.release.clear()
                process = self.launch()
                self.assertTrue(self.server.followup.wait(5))
                pid = int((self.cwd / "worker.pid").read_text())
                process.send_signal(sig)
                stdout, _ = process.communicate(timeout=5)
                self.server.release.set()
                session = json.loads(stdout.splitlines()[0])["start"]["session_id"]
                if sig == signal.SIGKILL:
                    # SIGKILL cannot run Session cleanup; remove the orphan fixture ourselves.
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(pid, signal.SIGKILL)
                else:
                    self.assertFalse(alive(pid))
                self.server.case = "resume"
                self.server.requests.clear()
                _, rows, _ = self.finish(self.launch("--resume", session))
                results = self.results(rows)
                self.assertEqual(results[0]["background_id"], "r1")
                self.assertIn("lost: process ended", results[0]["content"])
                self.assertEqual(results[-1]["background_id"], "r2")
                self.assertIn("resumed-result", results[-1]["content"])

    def test_tui_cancellation_reports_files_even_without_run_result(self):
        self.server.case = "recovery"
        (self.home / "config.toml").write_text("[limits]\nrun_background_after_ms = 100000\n")
        terminal = Terminal(self.cwd, self.env)
        try:
            terminal.send("initial\r")
            wait_for(lambda: (self.cwd / "worker.pid").exists())
            terminal.send("\x1b")
            terminal.until(b"type continue to resume")
            self.assertIn(b"edited: changed.txt", terminal.output)
            self.assertIn(b"bash changes untracked", terminal.output)
            self.assertEqual((self.cwd / "changed.txt").read_text(), "partial work")
            wait_for(lambda: not alive(int((self.cwd / "worker.pid").read_text())))
        finally:
            terminal.close()

    def test_tui_request_failure_does_not_claim_file_changes(self):
        self.server.case = "request-failure"
        terminal = Terminal(self.cwd, self.env)
        try:
            terminal.send("initial\r")
            terminal.until(b"model connection/request failed")
            terminal.until(b"type continue to resume")
            self.assertIn(b"no recorded edit/write changes", terminal.output)
            self.assertNotIn(b"edited:", terminal.output)
        finally:
            terminal.close()

    def test_tui_tasks_and_stop_during_model_request(self):
        self.server.case = "cancel"
        terminal = Terminal(self.cwd, self.env)
        try:
            terminal.send("initial\r")
            self.assertTrue(self.server.followup.wait(5))
            pid = int((self.cwd / "worker.pid").read_text())
            terminal.send("/tasks\r")
            terminal.until(b"per-tool deadlines")
            terminal.send("/stop r1\r")
            terminal.until(b"stopped by user")
            wait_for(lambda: not alive(pid))
            paths = [p for p in (self.home / "sessions").glob("*.jsonl") if not p.name.endswith(".calls.jsonl")]
            rows = [json.loads(line) for line in paths[0].read_text().splitlines()]
            self.assertIn({"id": "r1", "reason": "user requested stop", "stopped": True},
                          [r["task_stop"] for r in rows if "task_stop" in r])
            self.assertTrue(alive(terminal.child.pid))
        finally:
            self.server.release.set()
            terminal.close()

    def test_escape_cancels_background_run_in_tui(self):
        self.server.case = "cancel"
        terminal = Terminal(self.cwd, self.env)
        try:
            terminal.send("initial\r")
            self.assertTrue(self.server.followup.wait(5))
            terminal.send("/tasks\r")
            terminal.until(b"r1 Run")
            pid = int((self.cwd / "worker.pid").read_text())
            terminal.send("\x1b")
            wait_for(lambda: not alive(pid))
            terminal.until(b"Canceled")
        finally:
            self.server.release.set()
            terminal.close()

    def test_small_run_stays_foreground(self):
        (self.home / "config.toml").write_text("[limits]\nrun_background_after_ms = 1000\n")
        _, rows, _ = self.finish(self.launch())
        self.assertEqual(self.results(rows), [])


if __name__ == "__main__":
    unittest.main()
