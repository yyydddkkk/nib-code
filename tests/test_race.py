"""Race E2E: real TUI authorization, temporary Git repos, loopback mocks only.

    zig build && python3 tests/test_race.py
"""
import contextlib
import json
from pathlib import Path
import shlex
import signal
import sys
import threading
import os
import subprocess
import time
import unittest

from test_agent import alive
from test_agent_fork import ForkTests, Handler, child_step, tool_value
from mock_llm_tool import content
from test_background_agent import BackgroundTests
from test_interjections import Terminal
from test_agent_reuse import settled, system
from test_llm import records, wait_for


def race_code(**options):
    args = {"branches": [{"prompt": "child:one"}, {"prompt": "child:two"}], **options}
    return "await tools.race(" + json.dumps(args) + ")"


class RaceHandler(Handler):
    def respond(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        items = body.get("messages", body.get("input", []))
        users = [content(m) for m in items if m.get("role") == "user"]
        users = [text.split("\n\n", 1)[-1] if text.startswith("[race ") else text for text in users]
        prompt = next(text for text in reversed(users) if text.startswith(("parent:", "child:")))
        with self.server.lock:
            serial = len(self.server.requests)
            self.server.requests.append(dict(prompt=prompt, body=body, messages=items))
        text = "done:" + prompt
        if prompt in self.server.handlers:
            code, text = self.server.handlers[prompt](items)
        else:
            code = next(self.server.plans[prompt], None)
        if text == "HTTP_FAILURE":
            data = b'{"error": {"message": "intentional branch failure"}}'
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.reply(body, serial, code, text, 100)


class RaceTests(unittest.TestCase):
    provider = "chat_completions"

    def mock(self):
        mock = ForkTests.mock(self)
        mock.RequestHandlerClass = RaceHandler
        return mock

    def setUp(self):
        BackgroundTests.setUp(self)
        self.env = {k: v for k, v in self.env.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0", XDG_CONFIG_HOME=str(self.tmp / "config"),
                        XDG_DATA_HOME=str(self.tmp / "data"))
        self.git("init", "-q")
        self.git("config", "core.hooksPath", os.devnull)
        self.git("config", "user.email", "race@example.invalid")
        self.git("config", "user.name", "race test")
        (self.cwd / "result.txt").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.original_head = self.git("rev-parse", "HEAD")
        self.original_worktrees = self.git("worktree", "list", "--porcelain", "-z")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.cwd, env=self.env,
                                       stderr=subprocess.STDOUT, timeout=10)

    def start(self, mock, code, enabled=True, cwd=None, prompt="parent:race"):
        mock.plan(prompt, code, None)
        terminal = Terminal(cwd or self.cwd, self.env)
        terminal.race_prompt = prompt
        self.addCleanup(terminal.close)
        if enabled:
            terminal.send("/race\r")
            terminal.until(b"race enabled")
        terminal.race_offset = len(terminal.read())
        terminal.send(prompt + "\r")
        return terminal

    def finish(self, terminal, mock):
        prompt = terminal.race_prompt

        def finished():
            terminal.read()
            if terminal.child.poll() is not None:
                raise AssertionError("nib exited before finishing the Turn")
            return len(mock.observed(prompt)) == 2 and any(
                m.get("role") == "assistant" and m.get("content") == "done:" + prompt
                and not m.get("tool_calls")
                for r in self.root_records() for m in r.get("messages", []))

        try:
            wait_for(finished, timeout=20)
            wait_for(lambda: b"last turn:" in terminal.read()[terminal.race_offset:], timeout=10)
        except AssertionError as error:
            raise AssertionError((str(error), mock.errors,
                                  [(r["prompt"], child_step(r["messages"])) for r in mock.requests],
                                  terminal.child.poll(), terminal.output[-3000:])) from error
        return tool_value(mock.observed(prompt)[-1])

    def root_records(self):
        return [r for path in (self.home / "sessions").glob("?" * 32 + ".jsonl")
                if records(path) and not records(path)[0].get("parent_session_id") for r in records(path)]

    def test_disabled_is_data_without_starting_children(self):
        mock = self.mock()
        before = self.snapshot()
        terminal = self.start(mock, race_code(), enabled=False)
        result = self.finish(terminal, mock)
        self.assertFalse(result["ok"])
        self.assertIn("/race", result["error"])
        self.assertEqual("parent:race", content(mock.observed("parent:race")[0]["messages"][-1]))
        self.assertEqual(self.snapshot(), before)
        self.assert_cleaned()
        self.assertFalse(mock.observed("child:one"))
        self.assertFalse(mock.observed("child:two"))

    def test_winner_applies_bash_changes_and_joins_loser(self):
        mock = self.mock()
        pidfile = self.tmp / "loser.pid"
        loser = "printf loser > result.txt; echo $$ > " + str(pidfile) + "; sleep 30"
        mock.plan("child:two", "await tools.bash(" + json.dumps({"command": loser}) + ")", None)

        def winner(items):
            if child_step(items) == 0:
                return "await tools.bash({command: \"printf 'winner\\n' > result.txt\"})", "winner working"
            wait_for(pidfile.exists)
            return None, "winner complete"

        mock.handlers["child:one"] = winner
        terminal = self.start(mock, race_code(verify="test $(cat result.txt) = winner"))
        result = self.finish(terminal, mock)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["winner"], "a1")
        self.assertEqual(result["stopped"], ["a2"])
        self.assertEqual((self.cwd / "result.txt").read_text(), "winner\n")
        self.assertFalse(alive(int(pidfile.read_text())))
        root = self.root_records()
        self.assertEqual(result["changes"][0]["path"], str(self.cwd / "result.txt"))
        race = [r["race"] for r in root if r.get("race", {}).get("state") == "finished"][0]
        self.assertTrue(race["applied"], race)
        self.assertEqual([b["state"] for b in race["branches"]], ["won", "stopped"])
        self.assertGreater(race["usage"]["prompt_tokens"], 0)
        self.assertTrue(any(c["name"] == "race" for r in root for c in r.get("calls", [])))
        report = json.loads(subprocess.check_output([
            sys.executable, str(Path(__file__).resolve().parents[1] / "scripts/stats.py"),
            str(self.home / "sessions"), "--json"]))["race"]
        self.assertEqual((report["count"], report["applied"], report["branches"]), (1, 1, 2))
        self.assertEqual(report["winner_ms"]["samples"], 1)
        self.assertEqual(report["usage"]["total_tokens"],
                         result["usage"]["prompt_tokens"] + result["usage"]["completion_tokens"])
        self.assertFalse([r for r in root if r.get("agent_session")])
        self.assertFalse(list((self.home / "races").glob("race-*")))
        self.assertNotEqual(self.git("diff", "--", "result.txt"), b"")

    def test_verify_failure_does_not_apply_any_branch(self):
        mock = self.mock()
        for name in ("one", "two"):
            mock.plan("child:" + name, "await tools.bash({command: \"printf changed > result.txt\"})", None)
        terminal = self.start(mock, race_code(verify="exit 7"))
        result = self.finish(terminal, mock)
        self.assertFalse(result["ok"], result)
        self.assertIsNone(result["winner"])
        self.assertEqual(len(result["failures"]), 2)
        self.assertTrue(all(f["error"] == "VerificationFailed" for f in result["failures"]))
        self.assertEqual((self.cwd / "result.txt").read_text(), "base\n")
        self.assertFalse(list((self.home / "races").glob("race-*")))

    def test_timeout_stops_and_joins_all_branches(self):
        mock = self.mock()
        for name in ("one", "two"):
            mock.plan("child:" + name, "await tools.bash({command: \"printf changed > result.txt; sleep 30\"})", None)
        started = time.monotonic()
        terminal = self.start(mock, race_code(timeout_ms=2500))
        result = self.finish(terminal, mock)
        self.assertFalse(result["ok"], result)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual((self.cwd / "result.txt").read_text(), "base\n")
        self.assertFalse(list((self.home / "races").glob("race-*")))

    def snapshot(self):
        files = {str(p.relative_to(self.cwd)): (p.read_bytes(), p.stat().st_mode & 0o777)
                 for p in self.cwd.rglob("*")
                 if ".git" not in p.relative_to(self.cwd).parts and p.is_file()}
        return files, self.git("ls-files", "--stage", "-z"), self.git("status", "--porcelain=v1", "-z")

    def assert_cleaned(self):
        wait_for(lambda: self.git("worktree", "list", "--porcelain", "-z") == self.original_worktrees)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.original_head)
        self.assertFalse(list((self.home / "races").glob("race-*")))

    def hold(self, mock):
        def handle(_):
            if not mock.release.wait(30):
                raise AssertionError("mock hold was not released")
            return None, "released"
        return handle

    def worker(self, name):
        path = self.tmp / (name + ".pids")
        code = ("import json,os,signal,subprocess,sys,time; from pathlib import Path; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "child=subprocess.Popen([sys.executable,'-c',"
                "'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(120)']); "
                "parent=os.getppid(); "
                "exec(\"while parent > 1 and b'--agent-input' not in Path(f'/proc/{parent}/cmdline').read_bytes().split(bytes([0])):\\n"
                " parent=int(Path(f'/proc/{parent}/status').read_text().split('PPid:')[1].split()[0])\"); "
                "assert parent > 1, 'no child nib ancestor'; "
                "p=Path(sys.argv[1]); temp=p.with_suffix('.tmp'); "
                "temp.write_text(json.dumps(dict(worker=os.getpid(),grandchild=child.pid,nib=parent))); temp.replace(p); "
                "time.sleep(120)")

        def cleanup():
            if path.exists():
                for pid in json.loads(path.read_text()).values():
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGKILL)
        self.addCleanup(cleanup)
        return path, "await tools.bash(" + json.dumps({
            "command": shlex.join([sys.executable, "-c", code, str(path)]),
            "timeout_ms": 120000}) + ")"

    def pids(self, path):
        wait_for(path.exists, timeout=10)
        pids = json.loads(path.read_text())
        self.assertTrue(all(alive(pid) for pid in pids.values()), pids)
        return pids

    def assert_dead(self, pids):
        wait_for(lambda: all(not alive(pid) for pid in pids.values()), timeout=10)

    def test_toggle_facts_and_new_process_defaults_off(self):
        (self.home / "config.toml").write_text("[limits]\nrace_branches = 2\n")
        mock = self.mock()
        mock.plan("child:one")
        mock.plan("child:two")
        terminal = self.start(mock, race_code())
        self.assertTrue(self.finish(terminal, mock)["ok"])
        child_counts = [len(mock.observed("child:" + name)) for name in ("one", "two")]
        self.assertGreater(sum(child_counts), 0)
        self.assertIn("[race enabled: up to 2 branches]",  content(mock.observed("parent:race")[0]["messages"][-1]))
        terminal.send("/race\r")
        terminal.until(b"race disabled (not saved)")
        prompt = "parent:toggled-off"
        mock.plan(prompt, race_code(), None)
        terminal.race_prompt, terminal.race_offset = prompt, len(terminal.read())
        terminal.send(prompt + "\r")
        result = self.finish(terminal, mock)
        self.assertFalse(result["ok"], result)
        self.assertIn("disabled", result["error"].lower())
        self.assertIn("[race disabled]", content(mock.observed(prompt)[0]["messages"][-1]))
        terminal.close()
        terminal = self.start(mock, race_code(), enabled=False, prompt="parent:new-process")
        self.assertFalse(self.finish(terminal, mock)["ok"])
        self.assertEqual([len(mock.observed("child:" + name)) for name in ("one", "two")], child_counts)
        self.assertEqual((self.home / "config.toml").read_text(), "[limits]\nrace_branches = 2\n")
        self.assert_cleaned()

    def test_fast_wins_in_either_position_and_kills_process_group(self):
        for index in (0, 1):
            with self.subTest(fast_index=index):
                (self.cwd / "result.txt").write_text("base\n")
                mock = self.mock()
                names = ("one", "two")
                path, worker = self.worker("slow-" + str(index))
                mock.plan("child:" + names[1 - index], worker)
                ready = threading.Event()

                def fast(items, path=path, ready=ready):
                    if child_step(items) == 0:
                        return "await tools.bash({command: \"printf 'winner\\n' > result.txt\"})", "working"
                    self.pids(path)
                    ready.set()
                    return None, "fast branch complete"

                mock.handlers["child:" + names[index]] = fast
                terminal = self.start(mock, race_code(timeout_ms=15000), prompt="parent:fast-" + str(index))
                result = self.finish(terminal, mock)
                self.assertTrue(ready.is_set())
                self.assertTrue(result["ok"], result)
                self.assertEqual(result["winner"], "a" + str(index + 1))
                self.assert_dead(json.loads(path.read_text()))
                self.assertEqual(result["text"], "fast branch complete")
                self.assertEqual(result["stopped"], ["a" + str(2 - index)])
                self.assertEqual(result["failures"], [])
                self.assertEqual((self.cwd / "result.txt").read_text(), "winner\n")
                self.assertEqual({c["path"] for c in result["changes"]}, {str(self.cwd / "result.txt")})
                self.assert_cleaned()
                terminal.close()

    def test_verify_failure_then_valid_winner(self):
        mock = self.mock()
        rejected = self.tmp / "verify-rejected"
        mock.plan("child:one", "await tools.bash({command: \"printf bad > result.txt\"})")

        def good(items):
            if child_step(items) == 0:
                return "await tools.bash({command: \"printf good > result.txt\"})", "working"
            wait_for(rejected.exists, timeout=10)
            self.assertEqual((self.cwd / "result.txt").read_text(), "base\n")
            return None, "verified winner"

        mock.handlers["child:two"] = good
        verify = ("if [ \"$(cat result.txt)\" = bad ]; then touch " + shlex.quote(str(rejected)) +
                  "; exit 9; fi; test \"$(cat result.txt)\" = good")
        result = self.finish(self.start(mock, race_code(verify=verify)), mock)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["winner"], "a2")
        self.assertEqual(result["text"], "verified winner")
        self.assertEqual(len(result["failures"]), 1)
        self.assertEqual(result["failures"][0]["id"], "a1")
        self.assertIn("verif", result["failures"][0]["error"].lower())
        self.assertEqual((self.cwd / "result.txt").read_text(), "good")
        self.assert_cleaned()

    def test_all_provider_failures_leave_dirty_parent_untouched(self):
        (self.cwd / "result.txt").write_text("staged\n")
        self.git("add", "result.txt")
        (self.cwd / "result.txt").write_text("unstaged\n")
        (self.cwd / "untracked.txt").write_text("untracked\n")
        before = self.snapshot()
        mock = self.mock()
        for name in ("one", "two"):
            mock.handlers["child:" + name] = lambda _: (None, "HTTP_FAILURE")
        result = self.finish(self.start(mock, race_code()), mock)
        self.assertFalse(result["ok"], result)
        self.assertIsNone(result["winner"])
        self.assertEqual(result["changes"], [])
        self.assertEqual({f["id"] for f in result["failures"]}, {"a1", "a2"})
        self.assertEqual(self.snapshot(), before)
        self.assert_cleaned()

    def test_dirty_untracked_snapshot_and_fork_history_are_isolated(self):
        (self.cwd / "result.txt").write_text("staged\n")
        self.git("add", "result.txt")
        (self.cwd / "result.txt").write_text("dirty snapshot\n")
        (self.cwd / "untracked.txt").write_text("untracked snapshot\n")
        before = self.snapshot()
        mock = self.mock()
        both = {name: threading.Event() for name in ("one", "two")}

        def branch(name):
            def handle(items):
                step = child_step(items)
                if step == 0:
                    return '[await tools.read({path: "result.txt"}), await tools.read({path: "untracked.txt"})]', "reading"
                if step == 1:
                    self.assertEqual([r["text"] for r in tool_value({"messages": items})],
                                     ["dirty snapshot\n", "untracked snapshot\n"])
                    both[name].set()
                    for event in both.values():
                        self.assertTrue(event.wait(10))
                    return "await tools.write(" + json.dumps({"path": name + ".txt", "content": name}) + ")", "writing"
                if name == "two":
                    return self.hold(mock)(items)
                wait_for(lambda: len(mock.observed("child:two")) == 3, timeout=10)
                self.assertEqual(self.snapshot(), before)
                return None, "isolated winner"
            return handle

        for name in both:
            mock.handlers["child:" + name] = branch(name)
        result = self.finish(self.start(mock, race_code()), mock)
        self.assertTrue(result["ok"], result)
        self.assertEqual((self.cwd / "result.txt").read_text(), "dirty snapshot\n")
        self.assertEqual((self.cwd / "untracked.txt").read_text(), "untracked snapshot\n")
        self.assertEqual((self.cwd / "one.txt").read_text(), "one")
        self.assertFalse((self.cwd / "two.txt").exists())
        self.assertEqual(self.git("ls-files", "--stage", "-z"), before[1])
        parent = mock.observed("parent:race")[-1]
        for name in both:
            child = mock.observed("child:" + name)[0]
            self.assertEqual(system(child["body"]), system(parent["body"]))
            self.assertEqual(child["body"]["tools"], parent["body"]["tools"])
            self.assertTrue(any("parent:race" in content(m) for m in child["messages"] if m.get("role") == "user"))
        self.assert_cleaned()

    def test_absolute_path_mapping_and_foreground_background_bash_reject(self):
        mock = self.mock()
        path = str(self.cwd / "result.txt")
        marker = self.cwd / "must-not-exist"
        read = "tools.read(" + json.dumps({"path": path}) + ")"
        edit = "tools.edit(" + json.dumps({"path": path, "old_text": "base", "new_text": "branch"}) + ")"
        reject = [settled("tools.bash(" + json.dumps({"command": "touch " + shlex.quote(str(marker)),
                                                    "background": bg}) + ")") for bg in (False, True)]
        glob = "tools.glob(" + json.dumps({"path": str(self.cwd), "pattern": "*.txt"}) + ")"
        search = "tools.grep(" + json.dumps({"path": str(self.cwd), "pattern": "branch"}) + ")"
        code = ("const original = await " + read + "; await " + edit + "; [original, await " + read +
                ", await " + reject[0] + ", await " + reject[1] + ", await " + glob + ", await " + search + "]")
        mock.plan("child:one", code)
        mock.handlers["child:two"] = self.hold(mock)
        result = self.finish(self.start(mock, race_code()), mock)
        self.assertTrue(result["ok"], result)
        original, changed, fg, bg, globbed, searched = tool_value(mock.observed("child:one")[-1])
        self.assertEqual(original["text"], "base\n")
        self.assertEqual(changed["text"], "branch\n")
        for failed in (fg, bg):
            self.assertIs(failed["resolved"], False, failed)
            self.assertIn("parent", failed["error"].lower())
        self.assertTrue(any(p.endswith("result.txt") for p in globbed["paths"]), globbed)
        self.assertTrue(any("branch" in m["text"] for m in searched["matches"]), searched)
        self.assertFalse(marker.exists())
        self.assertEqual((self.cwd / "result.txt").read_text(), "branch\n")
        self.assert_cleaned()

    def test_conflict_saves_patch_without_parent_or_index_changes(self):
        mock = self.mock()
        before_apply = []

        def conflict(items):
            if child_step(items) == 0:
                return 'await tools.bash({command: "printf winner > result.txt; printf isolated > winner-only.txt"})', "working"
            (self.cwd / "result.txt").write_text("parent concurrent edit\n")
            (self.cwd / "parent-only.txt").write_text("concurrent untracked\n")
            before_apply.append(self.snapshot())
            return None, "conflicting winner"

        mock.handlers["child:one"] = conflict
        mock.handlers["child:two"] = self.hold(mock)
        result = self.finish(self.start(mock, race_code()), mock)
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["winner"], "a1")
        self.assertIn("conflict", result["error"].lower())
        self.assertEqual(result["changes"], [])
        self.assertEqual(self.snapshot(), before_apply[0])
        patch = Path(result["patch"])
        self.assertTrue(patch.is_file(), result)
        text = patch.read_text()
        self.assertIn("winner", text)
        self.assertIn("winner-only.txt", text)
        self.assertNotIn("parent concurrent edit", text)
        self.assert_cleaned()
        self.assertTrue(patch.is_file(), "cleanup must retain recovery patch")

    def test_turn_cancel_kills_process_groups_and_cleans_worktrees(self):
        before = self.snapshot()
        mock = self.mock()
        workers = [self.worker("cancel-" + str(i)) for i in range(2)]
        for name, (_, code) in zip(("one", "two"), workers):
            mock.plan("child:" + name, code)
        terminal = self.start(mock, race_code())
        pids = [self.pids(path) for path, _ in workers]
        terminal.send("\x1b")
        terminal.until(b"canceled")
        for group in pids:
            self.assert_dead(group)
        self.assertEqual(len(mock.observed("parent:race")), 1)
        self.assertEqual(self.snapshot(), before)
        self.assert_cleaned()
        mock.plan("parent:after-cancel")
        terminal.send("parent:after-cancel\r")

        def usable():
            terminal.read()
            return any(m.get("content") == "done:parent:after-cancel"
                       for r in self.root_records() for m in r.get("messages", []))
        wait_for(usable, timeout=10)

    def test_non_git_rejects_before_starting_branches(self):
        mock = self.mock()
        directory = self.tmp / "not-git"
        directory.mkdir()
        (directory / "untouched.txt").write_text("untouched\n")
        result = self.finish(self.start(mock, race_code(), cwd=directory), mock)
        self.assertFalse(result["ok"], result)
        self.assertIsNone(result["winner"])
        self.assertTrue(result["error"], result)
        self.assertFalse(mock.observed("child:one"))
        self.assertFalse(mock.observed("child:two"))
        self.assertEqual({p.name: p.read_text() for p in directory.iterdir()}, {"untouched.txt": "untouched\n"})
        self.assert_cleaned()


class CodexRaceTests(RaceTests):
    provider = "codex"

    def test_second_branch_wins_only_after_verification_passes(self):
        mock = self.mock()
        mock.plan("child:one", "await tools.bash({command: \"printf bad > result.txt\"})", None)
        mock.plan("child:two", "await tools.bash({command: \"sleep 0.2; printf good > result.txt\"})", None)
        terminal = self.start(mock, race_code(verify="test $(cat result.txt) = good"))
        result = self.finish(terminal, mock)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["winner"], "a2")
        self.assertEqual(result["failures"][0]["id"], "a1")
        self.assertEqual((self.cwd / "result.txt").read_text(), "good")

    def test_cancel_during_verify_joins_processes_before_cleanup(self):
        mock = self.mock()
        for name in ("one", "two"):
            mock.plan("child:" + name, None)
        pidfile = self.tmp / "verify.pids"
        verify = "echo $$ >> " + str(pidfile) + "; sleep 30"
        terminal = self.start(mock, race_code(verify=verify))

        def verifying():
            terminal.read()
            return pidfile.exists() and len(pidfile.read_text().splitlines()) == 2
        wait_for(verifying)
        terminal.send("\x1b")
        terminal.until(b"canceled")
        self.assertTrue(all(not alive(int(pid)) for pid in pidfile.read_text().splitlines()))
        self.assertEqual((self.cwd / "result.txt").read_text(), "base\n")
        self.assertFalse(list((self.home / "races").glob("race-*")))
        event = [r["race"] for r in self.root_records() if r.get("race", {}).get("state") == "finished"][0]
        self.assertEqual(event["error"], "Canceled")
        self.assertTrue(all(branch["state"] == "stopped" for branch in event["branches"]))


if __name__ == "__main__":
    unittest.main()
