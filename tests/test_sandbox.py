"""OS write sandbox E2E via local HTTP mock; no API key. Run after `zig build`.

The isolated HOME sits under the real home directory, not /tmp, so the sandbox
(which always allows temp dirs) is what denies writes beside the project.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
import uuid

from http.server import BaseHTTPRequestHandler
from mock_http import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"
DENIED = "ermission denied|not permitted"


class MockHandler(BaseHTTPRequestHandler):
    """Run JavaScript once, or a supplied list of Run argument objects."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        prompt = next(m["content"] for m in reversed(messages) if m["role"] == "user")
        prefix = "mock Run args: "
        runs = json.loads(prompt[len(prefix):]) if prompt.startswith(prefix) else [{"code": prompt}]
        index = sum(m["role"] == "tool" for m in messages)
        if index >= len(runs):
            delta, reason = {"content": "done"}, "stop"
        else:
            delta = {"tool_calls": [{"index": 0, "id": f"sandbox_run_{index}", "type": "function",
                                     "function": {"name": "run", "arguments": json.dumps(runs[index])}}]}
            reason = "tool_calls"
        events = [
            {"choices": [{"index": 0, "delta": delta}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": reason}],
             "usage": {"prompt_tokens": 100, "completion_tokens": 20}},
        ]
        body = ("".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def bash(command, **options):
    return "tools.bash(" + json.dumps({"command": command, **options}) + ")"


class SandboxTests(unittest.TestCase):
    def setUp(self):
        try:
            base = tempfile.mkdtemp(prefix="nib-sandbox-", dir=Path.home())
        except OSError as error:
            self.skipTest("home directory is not writable: " + str(error))
        self.addCleanup(shutil.rmtree, base, True)
        self.base = Path(base).resolve()
        self.project = self.base / "project"
        self.project.mkdir()
        self.home = self.base / "nib"
        self.home.mkdir()
        self.outside = self.base / "outside-file"
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop_server():
            server.shutdown()
            server.server_close()
            thread.join()
        self.addCleanup(stop_server)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("NIB_", "OPENAI_", "DEEPSEEK_", "CODEX_"))}
        self.env.update(
            NIB_SANDBOX="workspace", NIB_PROVIDER="chat_completions", NIB_API_KEY="mock",
            NIB_BASE_URL=f"http://127.0.0.1:{server.server_port}",
            NIB_CONTEXT_WINDOW="128000", NIB_HOME=str(self.home), HOME=str(self.base),
            XDG_DATA_HOME=str(self.base / "data"), XDG_CONFIG_HOME=str(self.base / "config"),
            CODEX_HOME=str(self.base / "codex"), LC_ALL="C")
        for name in ("TMPDIR", "XDG_CACHE_HOME", "CARGO_HOME", "GOPATH"):
            self.env.pop(name, None)

    def run_js(self, code, **env):
        if not isinstance(code, str):
            code = "mock Run args: " + json.dumps(code)
        merged = {**self.env, **env}
        result = subprocess.run([str(BIN), "ask", "--json", code], cwd=self.project, env=merged,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"end"', result.stdout)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def recorded(self, command, **env):
        """Runs a bash command through nib and returns its {exit_code, output}."""
        code = ("const r = await " + bash(command) + ";\n"
                "await tools.write({path: 'result.json', content: JSON.stringify(r)});")
        self.run_js(code, **env)
        return json.loads((self.project / "result.json").read_text())

    def test_project_writes_work_and_outside_writes_are_denied(self):
        result = self.recorded("echo hi > inside.txt && mkdir -p a b && mv inside.txt a/x && mv a/x b/x && cat b/x")
        self.assertEqual(result, {"exit_code": 0, "output": "hi\n"})
        result = self.recorded(f"touch {self.outside}")
        self.assertNotEqual(result["exit_code"], 0, result)
        self.assertRegex(result["output"], DENIED)
        self.assertFalse(self.outside.exists())

    def test_bash_cwd_is_per_call_and_does_not_add_a_writable_root(self):
        sibling = self.base / "sibling with spaces"
        sibling.mkdir()
        (self.project / "link").symlink_to(sibling, target_is_directory=True)
        (self.project / "nested").mkdir()
        calls = [bash("pwd; touch marker", cwd=str(sibling)), bash("pwd; touch marker", cwd="nested"),
                 bash("pwd", cwd="link"), bash("pwd")]
        self.run_js("const r = await Promise.all([" + ",".join(calls) + "]); "
                    "await tools.write({path:'result.json', content:JSON.stringify(r)});")
        outside, inside, link, default = json.loads((self.project / "result.json").read_text())
        self.assertNotEqual(outside["exit_code"], 0)
        self.assertTrue(outside["output"].startswith(str(sibling) + "\n"), outside)
        self.assertRegex(outside["output"], DENIED)
        self.assertFalse((sibling / "marker").exists())
        self.assertEqual(inside, {"exit_code": 0, "output": str(self.project / "nested") + "\n"})
        self.assertTrue((self.project / "nested" / "marker").exists())
        self.assertEqual(link, {"exit_code": 0, "output": str(sibling) + "\n"})
        self.assertEqual(default, {"exit_code": 0, "output": str(self.project) + "\n"})

    def test_run_cwd_aligns_file_search_and_bash_in_a_sibling_worktree(self):
        sibling = self.base / "feature with spaces"
        for args in (("init",), ("-c", "user.name=Test", "-c", "user.email=test@example.com",
                                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "init"),
                     ("worktree", "add", "--detach", str(sibling))):
            subprocess.run(["git", *args], cwd=self.project, check=True, capture_output=True)
        (self.project / "AGENTS.md").write_text("original-instructions-only\n")
        (sibling / "AGENTS.md").write_text("sibling-instructions-differs\n")
        for tree, text in ((self.project, "original"), (sibling, "feature")):
            (tree / "same.txt").write_text(text + "\n")
        (sibling / "nested").mkdir()
        (self.home / "config.toml").write_text(f'[sandbox]\nwritable = ["{sibling}"]\n')
        scoped = """
const [glob, grep] = await Promise.all([
  tools.glob({pattern:'same.txt'}), tools.grep({pattern:'feature',glob:'same.txt'})
]);
if (glob.paths.join() !== 'same.txt' || grep.matches[0]?.path !== glob.paths[0]) throw Error('search');
const path = grep.matches[0].path;
if ((await tools.read({path})).text.trim() !== 'feature') throw Error('read');
await tools.edit({path,old_text:'feature',new_text:'edited'});
await tools.write({path:'added.txt',content:'added'});
const result = await tools.bash({command:'cat same.txt added.txt'});
if (result.exit_code || result.output !== 'edited\\nadded') throw Error(JSON.stringify(result));
const override = await tools.bash({command:'pwd',cwd:'nested'});
if (override.exit_code || !override.output.trim().endsWith('/nested')) throw Error(JSON.stringify(override));
const absolute = await tools.bash({command:'cat same.txt',cwd:override.output.trim() + '/../../project'});
if (absolute.exit_code || absolute.output !== 'original\\n') throw Error(JSON.stringify(absolute));
"""
        normal = """
if ((await tools.read({path:'same.txt'})).text.trim() !== 'original') throw Error('read leaked cwd');
if ((await tools.bash({command:'cat same.txt'})).output.trim() !== 'original') throw Error('bash leaked cwd');
"""
        events = self.run_js([{"code": scoped, "cwd": "../feature with spaces"}, {"code": normal}])
        ends = [event["run_end"] for event in events if "run_end" in event]
        self.assertEqual(len(ends), 2, events)
        self.assertTrue(all(end["ok"] for end in ends), ends)
        self.assertEqual(ends[0]["cwd"], str(sibling))
        self.assertNotIn("cwd", ends[1])
        self.assertEqual((self.project / "same.txt").read_text(), "original\n")
        self.assertFalse((self.project / "added.txt").exists())
        self.assertEqual((sibling / "same.txt").read_text(), "edited\n")
        session = next(e["start"]["session_id"] for e in events if "start" in e)
        log = (self.home / "sessions" / f"{session}.jsonl").read_text()
        self.assertIn("original-instructions-only", log)
        self.assertNotIn("sibling-instructions-differs", log)

    def test_run_cwd_never_adds_writable_roots(self):
        sibling = self.base / "outside"
        sibling.mkdir()
        (sibling / "existing.txt").write_text("unchanged")
        (self.project / "alias").symlink_to(sibling, target_is_directory=True)
        code = """
if ((await tools.read({path:'existing.txt'})).text !== 'unchanged') throw Error('unexpected base');
for (const attempt of [() => tools.write({path:'created.txt',content:'no'}),
                       () => tools.edit({path:'existing.txt',old_text:'unchanged',new_text:'changed'})]) {
  try { await attempt(); throw Error('accepted unauthorized write'); }
  catch (e) { if (!String(e).includes('writable roots')) throw e; }
}
if ((await tools.bash({command:'touch denied.txt'})).exit_code === 0) throw Error('accepted shell write');
"""
        events = self.run_js([{"code": code, "cwd": "alias"}])
        end = next(e["run_end"] for e in events if "run_end" in e)
        self.assertTrue(end["ok"], end)
        self.assertEqual(end["cwd"], str(sibling))
        self.assertEqual(sorted(p.name for p in sibling.iterdir()), ["existing.txt"])
        self.assertEqual((sibling / "existing.txt").read_text(), "unchanged")

    def test_invalid_run_cwd_does_not_execute_javascript(self):
        (self.project / "not-directory").touch()
        code = "await tools.write({path:'unexpected',content:'ran'})"
        events = self.run_js([{"code": code, "cwd": cwd} for cwd in ("", "missing", "not-directory", "nul\0byte")])
        self.assertFalse(any("run_start" in event for event in events), events)
        self.assertFalse((self.project / "unexpected").exists())
        log = next((self.home / "sessions").glob("*.jsonl")).read_text()
        self.assertEqual(log.count("cannot use Run cwd"), 4, log)

    def test_temp_dirs_and_devices_stay_writable(self):
        marker = Path("/tmp") / ("nib-sandbox-" + uuid.uuid4().hex)
        self.addCleanup(lambda: marker.unlink(missing_ok=True))
        result = self.recorded(f"echo ok > {marker} && echo gone > /dev/null && cat {marker}")
        self.assertEqual(result, {"exit_code": 0, "output": "ok\n"})

    def test_default_allows_external_writes_without_notice(self):
        self.env.pop("NIB_SANDBOX")
        self.assertEqual(self.recorded(f"touch {self.outside}")["exit_code"], 0)
        self.run_js("await tools.write({path: '../file-tool', content: 'old'}); await tools.edit({path: '../file-tool', old_text: 'old', new_text: 'new'});")
        self.assertEqual((self.base / "file-tool").read_text(), "new")
        for log in (self.home / "sessions").glob("*.jsonl"):
            self.assertNotIn("sandbox_unavailable", log.read_text())

    def test_executable_directories_are_not_caches(self):
        for rel in (".cargo/bin", ".cargo/registry", ".cargo/git", ".bun/bin", ".bun/install/cache", "go/bin", ".local/bin"):
            (self.base / rel).mkdir(parents=True, exist_ok=True)
        for env in ({}, {"CARGO_HOME": str(self.base / ".cargo")}):
            for rel in (".cargo/bin", ".bun/bin", "go/bin", ".local/bin"):
                self.assertNotEqual(self.recorded(f"touch {self.base}/{rel}/x", **env)["exit_code"], 0)
            for rel in (".cargo/registry", ".cargo/git", ".bun/install/cache"):
                self.assertEqual(self.recorded(f"touch {self.base}/{rel}/x", **env)["exit_code"], 0)

    def test_caches_stay_writable(self):
        (self.base / ".cache").mkdir()
        result = self.recorded(f"mkdir -p {self.base}/.cache/tool && touch {self.base}/.cache/tool/x && echo ok")
        self.assertEqual(result["output"], "ok\n")

    def test_symlink_out_of_project_is_denied_for_bash_and_file_tools(self):
        elsewhere = self.base / "elsewhere"
        elsewhere.mkdir()
        (self.project / "link").symlink_to(elsewhere, target_is_directory=True)
        result = self.recorded("touch link/x")
        self.assertNotEqual(result["exit_code"], 0, result)
        code = ("const message = await tools.write({path: 'link/y', content: 'x'}).then(() => 'wrote', e => String(e.message || e));\n"
                "await tools.write({path: 'result.txt', content: message});")
        self.run_js(code)
        self.assertIn("sandbox", (self.project / "result.txt").read_text())
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_edit_and_write_outside_project_return_errors(self):
        self.outside.write_text("old")
        code = ("const out = {};\n"
                "out.write = await tools.write({path: " + json.dumps(str(self.base / "new-file")) + ", content: 'x'}).then(() => 'wrote', e => String(e.message || e));\n"
                "out.edit = await tools.edit({path: " + json.dumps(str(self.outside)) + ", old_text: 'old', new_text: 'new'}).then(() => 'edited', e => String(e.message || e));\n"
                "out.dotdot = await tools.write({path: '../dotdot', content: 'x'}).then(() => 'wrote', e => String(e.message || e));\n"
                "await tools.write({path: 'result.json', content: JSON.stringify(out)});")
        self.run_js(code)
        out = json.loads((self.project / "result.json").read_text())
        for key in ("write", "edit", "dotdot"):
            self.assertIn("sandbox only allows writes inside the project", out[key], out)
        self.assertEqual(self.outside.read_text(), "old")
        self.assertFalse((self.base / "new-file").exists())
        self.assertFalse((self.base / "dotdot").exists())

    def test_off_by_environment_and_config(self):
        result = self.recorded(f"touch {self.outside}", NIB_SANDBOX="off")
        self.assertEqual(result["exit_code"], 0, result)
        self.assertTrue(self.outside.exists())
        self.outside.unlink()
        self.env.pop("NIB_SANDBOX")
        (self.home / "config.toml").write_text('[sandbox]\nmode = "off"\n')
        self.assertEqual(self.recorded(f"touch {self.outside}")["exit_code"], 0)
        self.outside.unlink()
        self.assertNotEqual(self.recorded(f"touch {self.outside}", NIB_SANDBOX="workspace")["exit_code"], 0)

    def test_configured_writable_roots(self):
        extra = self.base / "extra"
        extra.mkdir()
        (self.home / "config.toml").write_text(f'[sandbox]\nwritable = ["{extra}"]\n')
        self.assertEqual(self.recorded(f"touch {extra}/ok")["exit_code"], 0)
        self.assertTrue((extra / "ok").exists())
        self.assertNotEqual(self.recorded(f"touch {self.outside}")["exit_code"], 0)

    def test_background_bash_is_sandboxed(self):
        command = f"touch {self.outside} 2> err.txt; echo $? > rc.txt"
        self.run_js("await " + bash(command, background=True))
        self.assertTrue((self.project / "rc.txt").exists())
        self.assertNotEqual((self.project / "rc.txt").read_text().strip(), "0")
        self.assertRegex((self.project / "err.txt").read_text(), DENIED)
        self.assertFalse(self.outside.exists())

    def test_subagent_inherits_the_sandbox(self):
        child = "await " + bash(f"touch {self.outside}; echo $? > child-rc.txt")
        self.run_js("await tools.agent(" + json.dumps({"prompt": child}) + ")")
        self.assertNotEqual((self.project / "child-rc.txt").read_text().strip(), "0")
        self.assertFalse(self.outside.exists())


if __name__ == "__main__":
    unittest.main()
