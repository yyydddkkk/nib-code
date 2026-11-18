"""Task-ID reuse E2E with gated local mocks and temporary NIB_HOME only.

    zig build && python3 tests/test_agent_reuse.py
"""
import fcntl
from mock_http import ThreadingHTTPServer
import http.server
import json
import shlex
import signal
import subprocess
import sys
import threading
import unittest

from background_assertions import stop_result

from mock_agent import USAGE, reply
from mock_llm_tool import content
from test_agent import alive
from test_background_agent import BIN, ROOT, BackgroundTests
from test_llm import records, wait_for


def agent(prompt, resume=None, background=False, **options):
    args = {"prompt": "child:" + prompt, **options}
    if resume is not None:
        args["resume"] = resume
    if background:
        args["background"] = True
    return "tools.agent(" + json.dumps(args) + ")"


def settled(call):
    return ("(async () => { try { return {resolved: true, value: await " + call +
            "} } catch (error) { return {resolved: false, error: error.message} } })()")


def completions(messages):
    results = []
    for message in messages:
        text = content(message)
        if text.startswith("[background agent "):
            heading, encoded = text.split("\n", 1)
            result = json.loads(encoded)
            if heading != "[background agent " + result["id"] + " finished]":
                raise AssertionError((heading, result))
            results.append(result)
    return results


def system(body):
    if "messages" in body:
        return "\n".join(content(m) for m in body["messages"] if m.get("role") == "system")
    return body["instructions"]


class Mock(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, parent, cwd):
        self.parent, self.cwd = parent, cwd
        self.requests, self.errors = [], []
        self.on_request = lambda prompt, step: None
        self.lock = threading.Lock()
        self.holding = threading.Event()
        self.release = threading.Event()
        self.parent_holding = threading.Event()
        self.parent_release = threading.Event()
        super().__init__(("127.0.0.1", 0), Handler)

    def observed(self, prompt):
        with self.lock:
            return [r for r in self.requests if r["prompt"] == prompt]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.server.errors.append(repr(error))
            self.send_error(500, str(error))

    def respond(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        provider = "chat_completions" if "messages" in body else "codex"
        messages = body.get("messages", body.get("input", []))
        users = [i for i, m in enumerate(messages) if m.get("role") == "user"]
        first, last = content(messages[users[0]]), users[-1]
        prompt = first if first == "initial" else content(messages[last])
        step = sum(m.get("role") == "tool" or m.get("type") == "function_call_output"
                   for m in messages[last + 1:])
        with self.server.lock:
            self.server.requests.append(dict(prompt=prompt, messages=messages, body=body))
        self.server.on_request(prompt, step)
        code, text = None, "done:" + prompt
        if prompt == "initial":
            code = self.server.parent(messages)
            text = "parent complete"
        elif prompt in ("child:seed", "child:fail", "child:stop-one", "child:stop-two") and step == 0:
            code = ('console.log("child-history-marker"); await tools.write(' +
                    json.dumps({"path": "child-note.txt", "content": "kept\n"}) + ")")
        elif prompt in ("child:stop-one", "child:stop-two"):
            if step != 1:
                raise AssertionError("stopped child tool unexpectedly completed: " + prompt)
            command = shlex.join([sys.executable, str(ROOT / "tests/mock_agent.py"),
                                  "--worker", "cancel", prompt.removeprefix("child:")])
            code = "await tools.bash(" + json.dumps({"command": command}) + ")"
        elif prompt == "child:fail":
            data = json.dumps({"error": {"message": "reusable child mock failure"}}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        elif prompt == "child:hold":
            (self.server.cwd / "held.request").touch()
            self.server.holding.set()
            if not self.server.release.wait(20):
                raise AssertionError("test did not release held child request")
        elif prompt not in ("child:seed", "child:next", "child:last", "child:new"):
            raise AssertionError("forbidden prompt executed: " + prompt)
        reply(self, provider, code, text)


class ReuseTests:
    setUp = BackgroundTests.setUp
    start = BackgroundTests.start
    finish = BackgroundTests.finish

    def mock(self, parent):
        mock = Mock(parent, self.cwd)
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        self.env["NIB_BASE_URL"] = "http://127.0.0.1:" + str(mock.server_port)
        self.env["NIB_CODEX_TRANSPORT"] = "sse"

        def cleanup():
            mock.release.set()
            mock.parent_release.set()
            mock.shutdown()
            mock.server_close()
            thread.join(timeout=3)
        self.addCleanup(cleanup)
        return mock

    def script(self, *codes):
        codes = iter(codes)
        return lambda messages: next(codes, None)

    def outputs(self, events):
        runs = [e["run_end"] for e in events if "run_end" in e]
        for run in runs:
            self.assertTrue(run["ok"], run)
        return [json.loads(r["output"].removeprefix("result: ")) for r in runs]

    def assert_result(self, result, task_id="a1", ok=True):
        self.assertIs(result["ok"], ok, result)
        self.assertEqual(result["id"], task_id, result)
        self.assertNotIn("session", result)
        self.assertIsInstance(result["text"], str)
        self.assertIsInstance(result["changes"], list)
        if not ok:
            self.assertIsInstance(result["error"], str)
            self.assertTrue(result["error"], result)

    def assert_failure(self, result, task_id=None):
        self.assertIs(result["ok"], False, result)
        self.assertIsInstance(result["error"], str)
        self.assertTrue(result["error"], result)
        self.assertNotIn("session", result)
        if task_id is not None:
            self.assertEqual(result["id"], task_id, result)

    def assert_usage(self, result, steps):
        self.assertEqual(result["usage"], {key: steps * value for key, value in USAGE.items()})

    def child_log(self, parent=None):
        paths = [p for p in (self.home / "sessions").glob("?" * 32 + ".jsonl")
                 if (rows := records(p)) and rows[0].get("parent_session_id")
                 and (parent is None or rows[0]["parent_session_id"] == parent)]
        self.assertEqual(len(paths), 1, paths)
        return paths[0]

    def assert_history(self, mock, prompt, previous, interrupted=()):
        requests = mock.observed("child:" + prompt)
        self.assertEqual(len(requests), 1, requests)
        messages = requests[0]["messages"]
        self.assertEqual([content(m) for m in messages if m.get("role") == "user"],
                         ["child:" + p for p in previous + [prompt]])
        self.assertTrue(any("child-history-marker" in m.get("output", content(m)) for m in messages
                            if m.get("role") == "tool" or m.get("type") == "function_call_output"), messages)
        for prior in previous:
            if prior not in interrupted:
                self.assertTrue(any(m.get("role") == "assistant" and content(m) == "done:child:" + prior
                                    for m in messages), messages)

    def assert_single_child_log(self, events, prompts):
        parent = events[0]["start"]["session_id"]
        path = self.child_log(parent)
        logs = list((self.home / "sessions").glob("?" * 32 + ".jsonl"))
        self.assertEqual(set(logs), {path, self.home / "sessions" / (parent + ".jsonl")})
        self.assertEqual([content(m) for row in records(path) for m in row.get("messages", [])
                          if m.get("role") == "user"], ["child:" + p for p in prompts])

    def assert_progress(self, events, prompts, background=False, failed=()):
        progress = [e["progress"] for e in events if "progress" in e]
        self.assertTrue(progress, events)
        self.assertEqual({p["id"] for p in progress}, {"a1"})
        for prompt in prompts:
            samples = [p for p in progress if p["prompt"] == "child:" + prompt]
            self.assertTrue(samples, (prompt, progress))
            self.assertEqual(samples[-1]["state"], "failed" if prompt in failed else "done", samples)
            self.assertTrue(all(p["background"] is background for p in samples), samples)
            self.assertTrue(all("session" not in p and "agent" not in p and "background_id" not in p
                                for p in samples), samples)

    def resume_parent(self, session):
        return self.start("--resume", session, "initial")

    def test_sequential_reuse_keeps_history_system_and_per_call_accounting(self):
        (self.home / "AGENTS.md").write_text("ORIGINAL_GLOBAL_SYSTEM")
        (self.cwd / "AGENTS.md").write_text("ORIGINAL_PROJECT_SYSTEM")
        snapshot = {}

        def parent(messages):
            if not snapshot:
                snapshot["stage"] = 1
                return "await " + agent("seed")
            if snapshot["stage"] == 1:
                snapshot.update(stage=2, log=self.child_log().read_bytes())
                (self.home / "AGENTS.md").write_text("REPLACED_GLOBAL_SYSTEM")
                (self.cwd / "AGENTS.md").write_text("REPLACED_PROJECT_SYSTEM")
                return "await " + agent("next", "a1")
            return None

        mock = self.mock(parent)
        events = self.finish(self.start())
        first, second = self.outputs(events)
        self.assert_result(first)
        self.assert_result(second)
        self.assert_usage(first, 2)
        self.assert_usage(second, 1)
        self.assertEqual(first["changes"], [{"path": "child-note.txt", "added": 1, "removed": 0, "created": True}])
        self.assertEqual(second["changes"], [])
        self.assertEqual(second["text"], "done:child:next")
        original_system = system(mock.observed("child:seed")[0]["body"])
        self.assertIn("ORIGINAL_GLOBAL_SYSTEM", original_system)
        self.assertIn("ORIGINAL_PROJECT_SYSTEM", original_system)
        self.assertNotIn("REPLACED_", original_system)
        self.assertEqual(system(mock.observed("child:next")[0]["body"]), original_system)
        self.assert_history(mock, "next", ["seed"])
        self.assert_single_child_log(events, ["seed", "next"])
        log = self.child_log().read_bytes()
        self.assertTrue(log.startswith(snapshot["log"]))
        self.assertGreater(len(log), len(snapshot["log"]))
        self.assert_progress(events, ["seed", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_foreground_failure_returns_reusable_id(self):
        mock = self.mock(self.script(
            "const failed = await " + agent("fail") +
            "; const resumed = await tools.agent({prompt: 'child:next', resume: failed.id}); [failed, resumed]"))
        events = self.finish(self.start())
        failed, resumed = self.outputs(events)[0]
        self.assert_result(failed, ok=False)
        self.assert_usage(failed, 1)
        self.assertEqual(failed["text"], "done:child:fail")
        self.assertTrue(failed["changes"])
        self.assert_result(resumed)
        self.assert_usage(resumed, 1)
        self.assertEqual(resumed["changes"], [])
        self.assert_history(mock, "next", ["fail"])
        self.assert_single_child_log(events, ["fail", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_non_string_resume_rejects_without_execution(self):
        invalid = [None, 4, False, [], {}]
        args = [{"prompt": "child:forbidden", "resume": value, "background": background}
                for background in (False, True) for value in invalid]
        code = ("await Promise.all(" + json.dumps(args) + ".map(async args => { try { "
                "return {resolved: true, value: await tools.agent(args)} "
                "} catch (error) { return {resolved: false, error: error.message} } }))")
        mock = self.mock(self.script(code, "await " + agent("new")))
        events = self.finish(self.start())
        results, fresh = self.outputs(events)
        self.assertEqual(len(results), len(args))
        for result in results:
            self.assertIs(result["resolved"], False, result)
            self.assertTrue(result["error"], result)
        self.assert_result(fresh)
        self.assert_single_child_log(events, ["new"])
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertFalse(mock.errors, mock.errors)

    def test_invalid_unknown_and_foreign_ids_resolve_failure_in_both_modes(self):
        mock = self.mock(self.script("await " + agent("seed")))
        original = self.finish(self.start())
        self.assert_result(self.outputs(original)[0])
        old_logs = {p: p.read_bytes() for p in (self.home / "sessions").glob("*.jsonl")}
        ids = ["", "a0", "a01", "a-1", "a1x", "A1", "b1", "../a1", "a999",
               "0" * 32, "session:" + self.child_log().stem, "a1"]
        calls = [settled(agent("forbidden", task_id, background))
                 for background in (False, True) for task_id in ids]
        mock.parent = self.script("await Promise.all([" + ",".join(calls) + "])",
                                  "await " + agent("new"))
        events = self.finish(self.start())
        results, fresh = self.outputs(events)
        self.assertEqual(len(results), len(calls))
        for result in results:
            self.assertIs(result["resolved"], True, result)
            self.assert_failure(result["value"])
        self.assert_result(fresh)
        self.assertFalse(completions(mock.observed("initial")[-1]["messages"]))
        self.assertEqual({p: p.read_bytes() for p in old_logs}, old_logs)
        self.assertEqual(len(list((self.home / "sessions").glob("?" * 32 + ".jsonl"))), 4)
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertFalse(mock.errors, mock.errors)

    def check_background_reuse(self, first_prompt):
        state = {"stage": 0}

        def parent(messages):
            done = completions(messages)
            if state["stage"] == 0:
                state["stage"] = 1
                return "await " + agent(first_prompt, background=True)
            if state["stage"] == 1 and done:
                state["stage"] = 2
                return "await " + agent("next", done[0]["id"])
            if state["stage"] == 2:
                state["stage"] = 3
                return "await " + agent("last", "a1", background=True)
            return None

        mock = self.mock(parent)
        events = self.finish(self.start())
        started, resumed, last_started = self.outputs(events)
        self.assertEqual(started, {"id": "a1"})
        self.assertEqual(last_started, {"id": "a1"})
        done = completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(done), 2)
        first, last = done
        self.assert_result(first, ok=first_prompt != "fail")
        self.assertTrue(first["changes"])
        self.assert_result(resumed)
        self.assert_usage(resumed, 1)
        self.assertEqual(resumed["changes"], [])
        self.assert_result(last)
        self.assertEqual(last["changes"], [])
        self.assert_history(mock, "next", [first_prompt])
        self.assert_history(mock, "last", [first_prompt, "next"])
        self.assert_single_child_log(events, [first_prompt, "next", "last"])
        self.assert_progress(events, [first_prompt, "last"], background=True,
                             failed=("fail",) if first_prompt == "fail" else ())
        background = [e["background"] for e in events if "background" in e]
        self.assertEqual([(e["id"], e["state"]) for e in background],
                         [("a1", "started"), ("a1", "finished")] * 2)
        self.assertFalse(mock.errors, mock.errors)

    def test_background_to_foreground_to_background_reuses_same_id(self):
        self.check_background_reuse("seed")

    def test_background_failure_is_reusable(self):
        self.check_background_reuse("fail")

    def test_foreground_to_background_reuses_same_id(self):
        mock = self.mock(self.script("await " + agent("seed"),
                                     "await " + agent("next", "a1", background=True)))
        events = self.finish(self.start())
        seed, started = self.outputs(events)
        self.assert_result(seed)
        self.assertEqual(started, {"id": "a1"})
        done = completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(done), 1)
        self.assert_result(done[0])
        self.assertEqual(done[0]["changes"], [])
        self.assert_history(mock, "next", ["seed"])
        self.assert_single_child_log(events, ["seed", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def check_busy(self, background):
        holder = agent("hold", "a1", background=background)
        code = ("const seed = await " + agent("seed") + "; const holder = " +
                ("await " if background else "") + holder +
                "; const gate = await tools.bash({command: 'while [ ! -f held.request ]; do sleep 0.01; done'}); "
                "if (gate.exit_code !== 0) throw Error('holder gate failed'); "
                "const contenders = await Promise.all([" + agent("forbidden", "a1") + "," +
                agent("forbidden", "a1", background=True) +
                "]); await tools.write({path: 'busy.json', content: JSON.stringify(contenders)}); "
                "({seed, holder: await holder, contenders})")
        stage = {"next": False}

        def parent(messages):
            if not stage.get("started"):
                stage["started"] = True
                return code
            if not stage["next"] and (not background or completions(messages)):
                stage["next"] = True
                return "await " + agent("next", "a1")
            return None

        mock = self.mock(parent)
        process = self.start()
        path = self.cwd / "busy.json"
        wait_for(lambda: path.exists() and path.stat().st_size)
        contenders = json.loads(path.read_text())
        for result in contenders:
            self.assert_failure(result, "a1")
        self.assertIsNone(process.poll(), "busy calls must settle before the holder finishes")
        self.assertFalse(mock.observed("child:forbidden"))
        mock.release.set()
        events = self.finish(process)
        initial, resumed = self.outputs(events)
        self.assert_result(initial["seed"])
        self.assertEqual(initial["contenders"], contenders)
        if background:
            self.assertEqual(initial["holder"], {"id": "a1"})
            done = completions(mock.observed("initial")[-1]["messages"])
            self.assertEqual(len(done), 1)
            self.assert_result(done[0])
        else:
            self.assert_result(initial["holder"])
        self.assert_result(resumed)
        self.assert_history(mock, "next", ["seed", "hold"])
        self.assert_single_child_log(events, ["seed", "hold", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_foreground_busy_rejects_foreground_and_background_contenders(self):
        self.check_busy(False)

    def test_background_busy_rejects_foreground_and_background_contenders(self):
        self.check_busy(True)

    def check_parent_recovery(self, kill):
        state = {"stage": 0}

        def parent(messages):
            if state["stage"] == 0:
                state["stage"] = 1
                return "await " + agent("seed")
            if kill:
                mock.parent_holding.set()
                if not mock.parent_release.wait(20):
                    raise AssertionError("test did not release parent request")
            return None

        (self.home / "AGENTS.md").write_text("ORIGINAL_RECOVERY_SYSTEM")
        mock = self.mock(parent)
        process = self.start()
        if kill:
            self.assertTrue(mock.parent_holding.wait(5))
            process.kill()
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, -signal.SIGKILL)
            self.assertEqual(error, "")
            original = [json.loads(line) for line in output.splitlines()]
            mock.parent_release.set()
        else:
            original = self.finish(process)
        self.assert_result(self.outputs(original)[0])
        parent_id = original[0]["start"]["session_id"]
        before = self.child_log(parent_id).read_bytes()
        (self.home / "AGENTS.md").write_text("REPLACED_RECOVERY_SYSTEM")
        mock.parent = self.script("await " + agent("next", "a1"), "await " + agent("new"))
        events = self.finish(self.resume_parent(parent_id))
        resumed, fresh = self.outputs(events)
        self.assert_result(resumed)
        self.assert_usage(resumed, 1)
        self.assertEqual(resumed["changes"], [])
        self.assert_result(fresh, "a2")
        self.assertEqual(parent_id, events[0]["start"]["session_id"])
        self.assert_history(mock, "next", ["seed"])
        child_paths = [p for p in (self.home / "sessions").glob("*.jsonl")
                       if records(p)[0].get("parent_session_id") == parent_id]
        self.assertEqual(len(child_paths), 2)
        self.assertTrue(any(p.read_bytes().startswith(before) for p in child_paths))
        self.assertEqual(system(mock.observed("child:next")[0]["body"]),
                         system(mock.observed("child:seed")[0]["body"]))
        self.assertFalse(mock.errors, mock.errors)

    def test_resumed_parent_restores_a1_and_next_id(self):
        self.check_parent_recovery(False)

    def test_killed_parent_restores_a1_and_next_id(self):
        self.check_parent_recovery(True)

    def test_pending_reuse_survives_previous_background_completion_and_parent_kill(self):
        state = {"stage": 0}

        def parent(messages):
            if state["stage"] == 0:
                state["stage"] = 1
                return ("await " + agent("seed", background=True) + "; let next; "
                        "for (let i = 0; i < 200; i++) { next = await " +
                        agent("hold", "a1", background=True) +
                        "; if (!(\"ok\" in next)) break; await tools.sleep(10); } next")
            mock.parent_holding.set()
            if not mock.parent_release.wait(20):
                raise AssertionError("test did not release parent request")
            return None

        mock = self.mock(parent)
        process = self.start()
        self.assertTrue(mock.holding.wait(5))
        self.assertTrue(mock.parent_holding.wait(5))
        child = self.child_log()
        parent_id = records(child)[0]["parent_session_id"]
        parent_log = self.home / "sessions" / (parent_id + ".jsonl")
        lifecycle = [event["state"] for row in records(parent_log)
                     for event in ([row["background"]] if "background" in row else
                                   [d["event"] for d in row.get("deliveries", [])])]
        self.assertEqual(lifecycle, ["started", "started", "finished"])
        process.kill()
        process.communicate(timeout=5)
        mock.parent_release.set()
        mock.release.set()

        def child_unlocked():
            with child.open("r+") as stream:
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return False
                fcntl.flock(stream, fcntl.LOCK_UN)
                return True

        wait_for(child_unlocked)
        mock.parent = self.script("await " + agent("next", "a1"))
        events = self.finish(self.resume_parent(parent_id))
        self.assert_result(self.outputs(events)[0])
        lost = [e["background"] for e in events
                if e.get("background", {}).get("state") == "lost"]
        self.assertEqual([(e["id"], e["kind"]) for e in lost], [("a1", "agent")])
        self.assertFalse(mock.errors, mock.errors)

    def check_stop_child_tool_reuse(self, background_resume):
        state = {"stage": 0, "workers": {}, "resumes": []}

        def running_worker(name):
            path = self.cwd / (name + ".started")
            wait_for(lambda: path.exists() and path.stat().st_size)
            pids = json.loads(path.read_text())
            self.assertTrue(all(alive(pid) for pid in pids.values()), pids)
            self.assertFalse((self.cwd / (name + ".done")).exists())
            state["workers"][name] = pids

        def parent(messages):
            if state["stage"] == 0:
                state["stage"] = 1
                return "await " + agent("stop-one", background=True)
            if state["stage"] == 1:
                running_worker("stop-one")
                state.update(stage=2, child=self.child_log(), prefix=self.child_log().read_bytes())
                self.assertFalse(completions(messages), messages)
                resume = agent("stop-two", "a1", background=True) if background_resume else agent("next", "a1")
                return ("const stopped = await tools.stop({id:'a1',reason:'mock requested cancellation'}); "
                        "const resumed = await " + resume + "; [stopped, resumed]")
            if state["stage"] == 2 and background_resume:
                state["stage"] = 3
                done = completions(messages)
                self.assertEqual(len(done), 1, done)
                self.assert_result(done[0], ok=False)
                running_worker("stop-two")
                return ("const busy = await Promise.all([" + agent("forbidden", "a1") + "," +
                        agent("forbidden", "a1", background=True) + "]); "
                        "const stopped = await tools.stop({id:'a1',reason:'mock requested cancellation'}); "
                        "const resumed = await " + agent("next", "a1") +
                        "; [busy, stopped, resumed]")
            return None

        def observe_resume(prompt, step):
            if step == 0 and prompt in ("child:stop-two", "child:next"):
                state["resumes"].append({
                    "prompt": prompt, "child": self.child_log(),
                    "workers": {name: {"alive": [alive(pid) for pid in pids.values()],
                                       "term": (self.cwd / (name + ".term")).exists(),
                                       "done": (self.cwd / (name + ".done")).exists()}
                                for name, pids in state["workers"].items()}})

        mock = self.mock(parent)
        mock.on_request = observe_resume
        events = self.finish(self.start())
        outputs = self.outputs(events)
        self.assertEqual(outputs[0], {"id": "a1"})
        stopped, resumed = outputs[1]
        self.assertEqual(stopped, stop_result("a1", True))
        if background_resume:
            self.assertEqual(len(outputs), 3, outputs)
            self.assertEqual(resumed, {"id": "a1"})
            busy, stopped, resumed = outputs[2]
            for contender in busy:
                self.assert_failure(contender, "a1")
                self.assertIn("busy", contender["error"].lower())
            self.assertEqual(stopped, stop_result("a1", True))
        else:
            self.assertEqual(len(outputs), 2, outputs)
        self.assert_result(resumed)
        self.assertEqual(resumed["text"], "done:child:next")
        self.assert_usage(resumed, 1)
        self.assertEqual(resumed["changes"], [])
        prompts = ["stop-one", "stop-two"] if background_resume else ["stop-one"]
        self.assert_history(mock, "next", prompts, interrupted=prompts)
        self.assert_single_child_log(events, prompts + ["next"])
        self.assertEqual(self.child_log(), state["child"])
        self.assertTrue(state["child"].read_bytes().startswith(state["prefix"]))
        self.assertEqual([r["prompt"] for r in state["resumes"]],
                         (["child:stop-two"] if background_resume else []) + ["child:next"])
        for observation in state["resumes"]:
            self.assertEqual(observation["child"], state["child"], observation)
            self.assertTrue(observation["workers"], observation)
            for worker in observation["workers"].values():
                self.assertFalse(any(worker["alive"]), observation)
                self.assertFalse(worker["done"], observation)
        done = completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(done), len(prompts), done)
        for result in done:
            self.assert_result(result, ok=False)
        lifecycle = [e["background"] for e in events if "background" in e]
        self.assertEqual([(e["id"], e["state"]) for e in lifecycle],
                         [("a1", "started")] * len(prompts) + [("a1", "finished")] * len(prompts))
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertFalse(mock.errors, mock.errors)

    def test_stop_background_child_tool_then_foreground_resume_in_same_run(self):
        self.check_stop_child_tool_reuse(False)

    def test_stopped_completion_keeps_resumed_background_busy_and_stop_targets_latest(self):
        self.check_stop_child_tool_reuse(True)

    def check_canceled_continuation(self, background):
        mock = self.mock(self.script("await " + agent("seed")))
        original = self.finish(self.start())
        self.assert_result(self.outputs(original)[0])
        parent = original[0]["start"]["session_id"]
        mock.parent = self.script("await " + agent("hold", "a1", background=background))
        process = self.resume_parent(parent)
        self.assertTrue(mock.holding.wait(5), "continuation never started")
        process.send_signal(signal.SIGINT)
        self.finish(process, ok=False)
        mock.release.set()
        mock.parent = self.script("await " + agent("next", "a1"))
        events = self.finish(self.resume_parent(parent))
        resumed = self.outputs(events)[0]
        self.assert_result(resumed)
        self.assert_usage(resumed, 1)
        self.assertEqual(resumed["changes"], [])
        self.assert_history(mock, "next", ["seed", "hold"], interrupted=("hold",))
        self.assert_single_child_log(events, ["seed", "hold", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_canceled_foreground_continuation_can_resume(self):
        self.check_canceled_continuation(False)

    def test_canceled_background_continuation_can_resume(self):
        self.check_canceled_continuation(True)

    def check_canceled_new_task(self, background):
        mock = self.mock(self.script("await " + agent("hold", background=background)))
        process = self.start()
        self.assertTrue(mock.holding.wait(5), "new task never started")
        process.send_signal(signal.SIGINT)
        original = self.finish(process, ok=False)
        parent = original[0]["start"]["session_id"]
        mock.release.set()
        mock.parent = self.script("await " + agent("next", "a1"))
        events = self.finish(self.resume_parent(parent))
        resumed = self.outputs(events)[0]
        self.assert_result(resumed)
        self.assert_usage(resumed, 1)
        self.assertEqual(resumed["changes"], [])
        requests = mock.observed("child:next")
        self.assertEqual(len(requests), 1, requests)
        self.assertEqual([content(m) for m in requests[0]["messages"] if m.get("role") == "user"],
                         ["child:hold", "child:next"])
        self.assert_single_child_log(events, ["hold", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_canceled_new_foreground_task_is_reusable_before_first_result(self):
        self.check_canceled_new_task(False)

    def test_canceled_new_background_task_is_reusable_before_first_result(self):
        self.check_canceled_new_task(True)

    def test_timeout_result_keeps_id_and_can_resume(self):
        mock = self.mock(self.script("await " + agent("seed"),
                                     "await " + agent("hold", "a1", timeout_ms=1200),
                                     "await " + agent("next", "a1")))
        events = self.finish(self.start())
        seed, timed_out, resumed = self.outputs(events)
        self.assert_result(seed)
        self.assert_result(timed_out, ok=False)
        self.assertRegex(timed_out["error"].lower(), r"timeout|timed.out")
        self.assert_usage(timed_out, 0)
        self.assertEqual(timed_out["changes"], [])
        self.assert_result(resumed)
        self.assert_usage(resumed, 1)
        self.assertEqual(resumed["changes"], [])
        self.assert_history(mock, "next", ["seed", "hold"], interrupted=("hold",))
        self.assert_single_child_log(events, ["seed", "hold", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_cross_process_child_log_lock_fails_then_releases(self):
        state = {"stage": 0}

        def parent(messages):
            if state["stage"] == 0:
                state["stage"] = 1
                return "await " + agent("seed")
            if state["stage"] == 1:
                path = self.child_log()
                locker = subprocess.Popen([sys.executable, "-c",
                    "import fcntl, sys; f = open(sys.argv[1], 'r+'); "
                    "fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); "
                    "print('locked', flush=True); sys.stdin.readline()", str(path)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

                def cleanup():
                    if locker.poll() is None:
                        locker.kill()
                    locker.communicate()
                self.addCleanup(cleanup)
                self.assertEqual(locker.stdout.readline(), "locked\n")
                state.update(stage=2, path=path, locker=locker, before=path.read_bytes())
                return "await Promise.all([" + agent("forbidden", "a1") + "," + agent(
                    "forbidden", "a1", background=True) + "])"
            if state["stage"] == 2:
                self.assertEqual(state["path"].read_bytes(), state["before"])
                output, error = state["locker"].communicate("release\n", timeout=3)
                self.assertEqual((state["locker"].returncode, output, error), (0, "", ""))
                state["stage"] = 3
                return "await " + agent("next", "a1")
            return None

        mock = self.mock(parent)
        events = self.finish(self.start())
        seed, contenders, resumed = self.outputs(events)
        self.assert_result(seed)
        for result in contenders:
            self.assert_failure(result, "a1")
        self.assert_result(resumed)
        self.assertFalse(completions(mock.observed("initial")[-1]["messages"]))
        self.assert_history(mock, "next", ["seed"])
        self.assert_single_child_log(events, ["seed", "next"])
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertFalse(mock.errors, mock.errors)


class ChatTests(ReuseTests, unittest.TestCase):
    provider = "chat_completions"


class CodexTests(ReuseTests, unittest.TestCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main(verbosity=2)
