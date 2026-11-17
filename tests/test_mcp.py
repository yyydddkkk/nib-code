"""MCP tools, protocol fallback, isolation and context; local mocks only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from mock_mcp import HTTP
from mock_providers import Mock

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class MCP(unittest.TestCase):
    def setup_case(self, config, code, protocol="chat_completions", mock_class=Mock):
        temp = tempfile.TemporaryDirectory(prefix="nib-mcp-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        home, data, project = [root / n for n in ("home", "data", "project")]
        for path in (home, data, project):
            path.mkdir()
        (project / ".git").mkdir()
        mock = mock_class(protocol, code=code)
        self.addCleanup(mock.close)
        (data / "config.toml").write_text(config)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_", "XAI_", "CODEX_"))}
        env.update(NIB_RECORD="on", HOME=str(home), NIB_HOME=str(data), NIB_PROVIDER="anthropic" if protocol == "anthropic_messages" else "chat_completions", NIB_API_KEY=mock.key, NIB_BASE_URL=mock.url, ANTHROPIC_API_KEY=mock.key, GITHUB_TOKEN="fake-github-token", MCP_TEST_TOKEN="fake-mcp-token", MCP_UNLISTED="do-not-pass")
        def ask(prompt="probe", *args):
            result = subprocess.run([str(BIN), "ask", "--json", prompt, *args], cwd=project, env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(mock.errors, mock.errors)
            return [json.loads(line) for line in result.stdout.splitlines()]
        return root, data, mock, ask

    def stdio_config(self, legacy=False, enabled=True, record=None):
        args = [str(ROOT / "tests/mock_mcp.py")]
        if legacy:
            args.append("--legacy")
        if record:
            args += ["--record", str(record)]
        return f'[mcp]\nlocal = {str(enabled).lower()}\n[mcp.local]\ncommand = {json.dumps(sys.executable)}\nargs = {json.dumps(args)}\nenv = ["MCP_TEST_TOKEN", "GITHUB_TOKEN"]\n'

    def results(self, mock):
        return [m["content"] for _, _, req in mock.requests for m in req.get("messages", []) if m.get("role") == "tool"]

    def test_disabled_context_is_identical(self):
        root, data, mock, ask = self.setup_case(self.stdio_config(enabled=False), 'throw Error("must not run")')
        ask("child probe")
        baseline = mock.requests[-1][2]["messages"][0]["content"]
        self.assertNotIn("<mcp_tools>", baseline)
        self.assertFalse((data / "mcp").exists())
        (data / "config.toml").write_text("")
        ask("child probe")
        self.assertEqual(baseline, mock.requests[-1][2]["messages"][0]["content"])

    def test_stdio_modern_and_legacy(self):
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                code = '''console.log(await tools.mcp_schema("local.echo"));
console.log(await tools.mcp("local.echo", {text:"hello"}));
console.log(await tools.mcp("local.fail", {text:"bad"}));
console.log(await tools.mcp("local.rpc_error", {text:"rpc"}));
console.log(await tools.mcp("local.change", {text:"change"}));
console.log(await tools.mcp_schema("local.added"));
console.log((await tools.mcp("local.large", {text:"large"})).content.length);
console.log(await tools.mcp("local.env", {}));'''
                records = tempfile.TemporaryDirectory(prefix="nib-mcp-record-")
                self.addCleanup(records.cleanup)
                record = Path(records.name) / "requests.jsonl"
                root, data, mock, ask = self.setup_case(self.stdio_config(legacy, record=record), code)
                ask()
                requests = [json.loads(line) for line in record.read_text().splitlines()]
                run_pid = next(r["pid"] for r in requests if r["request"].get("method") == "tools/call")
                methods = [(r["request"].get("method"), (r["request"].get("params") or {}).get("name")) for r in requests if r["pid"] == run_pid]
                before_change = methods[:methods.index(("tools/call", "change"))]
                self.assertNotIn(("tools/list", None), before_change, "calls reuse the discovered catalog")
                self.assertIn(("tools/list", None), methods, "list_changed refreshes the catalog")
                system = mock.requests[0][2]["messages"][0]["content"]
                self.assertIn("local.echo(text: string) — Echo the input.", system)
                self.assertIn("local.second()", system)
                self.assertNotIn("Unneeded detail", system)
                result = self.results(mock)[0]
                self.assertIn('"ok":true,"content":"hello"', result)
                self.assertIn('"ok":false,"content":"bad"', result)
                self.assertIn('mock RPC failure', result)
                self.assertIn('25000', result)
                self.assertIn('fake-mcp-token', result)
                self.assertIn('\\"key\\": null', result)
                calls = next((data / "sessions").glob("*.calls.jsonl")).read_text()
                self.assertIn('"name":"mcp"', calls)
                self.assertIn('"name":"mcp_schema"', calls)
                session = next(p for p in (data / "sessions").glob("*.jsonl") if not p.name.endswith(".calls.jsonl"))
                (data / "config.toml").write_text(self.stdio_config(legacy, enabled=False))
                ask("again", "--resume", session.stem)
                self.assertEqual(system, mock.requests[-1][2]["messages"][0]["content"])

    def test_http_json_sse_and_legacy(self):
        for legacy in (False, True):
            for sse in (False, True):
                with self.subTest(legacy=legacy, sse=sse):
                    server = HTTP(legacy, sse)
                    self.addCleanup(server.close)
                    config = f'[mcp]\ndocs = true\n[mcp.docs]\nurl = "{server.url}"\nheader_env = "MCP_TEST_TOKEN"\n'
                    _, _, mock, ask = self.setup_case(config, 'console.log(await tools.mcp("docs.echo", {text:"from HTTP"}));')
                    ask()
                    self.assertIn('"content":"from HTTP"', self.results(mock)[0])
                    self.assertFalse(server.errors, server.errors)
                    self.assertTrue(all({k.lower():v for k,v in headers.items()}["authorization"] == "Bearer fake-mcp-token" for _, headers in server.requests))

    def test_images(self):
        _, _, mock, ask = self.setup_case(self.stdio_config(), 'console.log(await tools.mcp("local.image", {text:"picture"}));', "anthropic_messages")
        ask()
        message = mock.requests[1][2]["messages"][-1]["content"][0]
        self.assertEqual(message["content"][1]["type"], "image")

    def test_subagent(self):
        class AgentProvider(Mock):
            def serve(self, h, body):
                subtask = any(m.get("content") == "mcp subtask" for m in body.get("messages", []))
                self.code = 'console.log(await tools.mcp("local.echo", {text:"subagent MCP"})); console.log(await tools.mcp("local.env", {}));' if subtask else 'console.log(await tools.agent({prompt:"mcp subtask"}));'
                return super().serve(h, body)
        _, data, mock, ask = self.setup_case(self.stdio_config(), "", mock_class=AgentProvider)
        ask()
        logs = [p for p in (data / "sessions").glob("*.calls.jsonl")]
        self.assertEqual(len(logs), 2)
        self.assertTrue(any("fake-github-token" in p.read_text() for p in logs))
        self.assertTrue(any('subagent MCP' in p.read_text() and '\"name\":\"mcp\"' in p.read_text() for p in logs))

    def test_stdio_sandbox(self):
        outside = tempfile.TemporaryDirectory(prefix="nib-mcp-outside-", dir=Path.home())
        self.addCleanup(outside.cleanup)
        target = Path(outside.name) / "blocked"
        code = 'console.log(await tools.mcp("local.sandbox", {text:"test", path:' + json.dumps(str(target)) + '}));'
        _, _, mock, ask = self.setup_case(self.stdio_config() + '\n[sandbox]\nmode = "workspace"\n', code)
        ask()
        self.assertIn('"content":"denied"', self.results(mock)[0])
        self.assertFalse(target.exists())


def tui_toggle():
    from test_interjections import Reply, fixture, wait_for
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp) / "tui"
        reply = Reply("mcp-tui-done")
        with fixture(directory, [reply], config=MCP().stdio_config(enabled=False)) as (terminal, home, _):
            config = home / "config.toml"
            terminal.send("/mcp\r")
            terminal.until(b"Applies to new sessions.")
            terminal.send("/mcp on local\r")
            wait_for(lambda: "local = true" in config.read_text(), "MCP enabled")
            terminal.until(b"Applies to new sessions.")
            terminal.send("/new\r/mcp\r")
            terminal.until(b"tools")
            terminal.send("/mcp off local\r")
            wait_for(lambda: "local = false" in config.read_text(), "MCP disabled")
            terminal.send("check context\r")
            terminal.until(reply.text.encode())
            assert "<mcp_tools>" in reply.messages[0]["content"]


if __name__ == "__main__":
    result = unittest.main(exit=False).result
    if not result.wasSuccessful():
        sys.exit(1)
    tui_toggle()
