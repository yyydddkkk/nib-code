"""Plugin installation, opt-in context and Session snapshots; local fixtures only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from mock_providers import Mock

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class Plugins(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nib-plugins-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home, self.data, self.project = [self.root / n for n in ("home", "data", "project")]
        for p in (self.home, self.data, self.project):
            p.mkdir()
        (self.project / ".git").mkdir()
        self.mock = Mock("chat_completions", code="console.log('plugin probe')")
        self.addCleanup(self.mock.close)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_", "CODEX_"))}
        self.env.update(HOME=str(self.home), NIB_HOME=str(self.data), NIB_PROVIDER="chat_completions", NIB_MODEL="mock", NIB_API_KEY=self.mock.key, NIB_BASE_URL=self.mock.url, PLUGIN_TEST_TOKEN="not-for-session-log")
        self.source = self.package("example")

    def package(self, name):
        source = self.root / (name + " source")
        (source / ".claude-plugin").mkdir(parents=True)
        (source / ".claude-plugin/plugin.json").write_text(json.dumps({"name": name, "version": "1.0.0"}))
        (source / "skills/review").mkdir(parents=True)
        (source / "skills/review/SKILL.md").write_text("---\nname: review\ndescription: Plugin review workflow\n---\nReview fixture body.\n")
        (source / "commands").mkdir()
        (source / "commands/check.md").write_text("Check $ARGUMENTS with ${CLAUDE_PLUGIN_ROOT}/scripts/check.sh")
        return source

    def run_nib(self, *args, ok=True):
        result = subprocess.run([str(BIN), *map(str, args)], env=self.env, cwd=self.project, text=True, capture_output=True, timeout=40)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def install(self, source=None):
        return self.run_nib("plugin", "install", source or self.source)

    def ask(self, prompt="child probe", *args):
        before = len(self.mock.requests)
        self.run_nib("ask", prompt, *args)
        self.assertFalse(self.mock.errors, self.mock.errors)
        return self.mock.requests[before][2]["messages"]

    def log(self):
        files = list((self.data / "sessions").glob("*.jsonl"))
        files = [f for f in files if not f.name.endswith(".calls.jsonl")]
        return max(files, key=lambda f: f.stat().st_mtime_ns)

    def test_default_off_and_package_gate(self):
        bare = self.ask()[0]["content"]
        self.assertIn("installed · disabled", self.install())
        self.assertEqual(bare, self.ask()[0]["content"])
        messages = self.ask("$example:review /example:check")
        self.assertNotIn("Review fixture body", messages[1]["content"])
        self.assertIn("example · off", self.run_nib("plugin", "list"))
        self.run_nib("plugin", "on", "example")
        system = self.ask()[0]["content"]
        self.assertIn("example:review", system)
        self.assertNotIn("example:check", system)
        messages = self.ask("$example:review")
        self.assertIn("Review fixture body", messages[1]["content"])
        self.run_nib("plugin", "off", "example")
        self.assertEqual(bare, self.ask()[0]["content"])

    def test_commands_arguments_and_no_shell_execution(self):
        marker = self.root / "must-not-exist"
        (self.source / "commands/check.md").write_text(f"---\ndescription: Check files\n---\nCheck $ARGUMENTS in ${{CLAUDE_PLUGIN_ROOT}}. !`touch {marker}`")
        self.assertIn("Unsupported", self.install())
        self.run_nib("plugin", "on", "example")
        messages = self.ask("/example:check one two")
        self.assertIn("Check one two in ", messages[1]["content"])
        self.assertNotIn("${CLAUDE_PLUGIN_ROOT}", messages[1]["content"])
        self.assertNotIn("$ARGUMENTS", messages[1]["content"])
        self.assertFalse(marker.exists())
        messages = self.ask("$example:check")
        self.assertIn("Check $ARGUMENTS", messages[1]["content"])

    def test_snapshots_resume_uninstall_and_reinstall(self):
        self.install()
        self.run_nib("plugin", "on", "example")
        original = self.ask("$example:review")[0]["content"]
        session = self.log().stem
        header = json.loads(self.log().read_text().splitlines()[0])
        self.assertEqual(len(header["plugin_skills"]), 2)
        old_root = header["plugin_skills"][0]["plugin_root"]
        self.run_nib("plugin", "uninstall", "example")
        self.assertTrue(Path(old_root).exists())
        self.assertNotIn("example:review", self.ask()[0]["content"])
        (self.source / "skills/review/SKILL.md").write_text("---\ndescription: Changed workflow\n---\nNEW BODY")
        self.install()
        self.assertIn("example · off", self.run_nib("plugin", "list"))
        messages = self.ask("$example:review", "--resume", session)
        self.assertEqual(original, messages[0]["content"])
        self.assertIn("Review fixture body", messages[-1]["content"])
        self.assertNotIn("NEW BODY", messages[-1]["content"])

    def test_unsupported_components_are_reported_and_not_executed(self):
        (self.source / "hooks").mkdir()
        marker = self.root / "hook-ran"
        (self.source / "hooks/hooks.json").write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": f"touch {marker}"}]}]}}))
        (self.source / "agents").mkdir()
        (self.source / ".lsp.json").write_text("{}")
        text = self.install()
        for name in ("hooks", "agents", ".lsp.json"):
            self.assertIn("Unsupported: " + name, text)
        self.run_nib("plugin", "on", "example")
        self.ask()
        self.assertFalse(marker.exists())
        self.assertIn("Unsupported: hooks", self.run_nib("plugin", "list"))

    def test_mcp_namespacing_templates_and_disabled_no_discovery(self):
        (self.source / "server.py").write_text((ROOT / "tests/mock_mcp.py").read_text())
        # The mock imports its sibling wire helpers.
        for helper in ("mock_http.py",):
            (self.source / helper).write_text((ROOT / "tests" / helper).read_text())
        (self.source / ".mcp.json").write_text(json.dumps({"mcpServers": {"local": {"command": sys.executable, "args": ["${CLAUDE_PLUGIN_ROOT}/server.py"], "env": {"MCP_TEST_TOKEN": "${PLUGIN_TEST_TOKEN}"}}}}))
        self.install()
        self.assertNotIn("<mcp_tools>", self.ask()[0]["content"])
        self.assertFalse((self.data / "mcp").exists())
        self.run_nib("plugin", "on", "example")
        self.mock.code = 'console.log(await tools.mcp("example__local.env", {}));'
        self.assertIn("example__local.echo", self.ask("probe")[0]["content"])
        log = self.log().read_text()
        header = json.loads(log.splitlines()[0])
        self.assertNotIn("not-for-session-log", json.dumps(header))
        self.assertIn("${PLUGIN_TEST_TOKEN}", json.dumps(header))
        self.assertIn("not-for-session-log", log)

    def test_default_mcp_file_can_be_referenced_once_by_multiple_paths(self):
        (self.source / ".mcp.json").write_text(json.dumps({"mcpServers": {"local": {"command": sys.executable}}}))
        (self.source / ".claude-plugin/plugin.json").write_text(json.dumps({"name": "example", "mcpServers": ["./.mcp.json", "././.mcp.json"]}))
        self.assertIn("1 MCP server", self.install())
        (self.source / ".claude-plugin/plugin.json").write_text(json.dumps({"name": "example", "mcpServers": {"local": {"command": "different"}}}))
        self.assertIn("PluginMcpNameConflict", self.run_nib("plugin", "install", self.source, ok=False))

    def test_child_inherits_only_names_referenced_by_enabled_plugin_templates(self):
        (self.source / "server.py").write_text((ROOT / "tests/mock_mcp.py").read_text())
        (self.source / "mock_http.py").write_text((ROOT / "tests/mock_http.py").read_text())
        (self.source / ".mcp.json").write_text(json.dumps({"mcpServers": {"local": {"command": sys.executable, "args": ["${CLAUDE_PLUGIN_ROOT}/server.py"], "env": {"MCP_TEST_TOKEN": "${GITHUB_TOKEN}"}}}}))
        self.env["GITHUB_TOKEN"] = "fake-child-plugin-token"
        self.install()
        self.run_nib("plugin", "on", "example")
        original = self.mock.serve
        parent_code = ('console.log(await tools.agent({prompt:"mcp-token-probe"}));'
                       'console.log(await tools.agent({prompt:"mcp-token-probe",fork:true}));')
        def serve(handler, body):
            prompt = next((m.get("content", "") for m in reversed(body["messages"]) if m.get("role") == "user"), "")
            self.mock.code = 'console.log(await tools.mcp("example__local.env", {}));' if prompt == "mcp-token-probe" else parent_code
            if prompt == "mcp-token-probe":
                body = dict(body, messages=[m for m in body["messages"]
                            if not (m.get("role") == "tool" and m.get("content", "").startswith("[forked as child"))])
            return original(handler, body)
        self.mock.serve = serve
        self.ask("parent plugin probe")
        child_logs = []
        for path in (self.data / "sessions").glob("*.jsonl"):
            if path.name.endswith(".calls.jsonl"):
                continue
            records = [json.loads(line) for line in path.read_text().splitlines()]
            if records and records[0].get("parent_session_id"):
                child_logs.append(path.read_text())
                self.assertNotIn("fake-child-plugin-token", json.dumps(records[0]))
        self.assertEqual(len(child_logs), 2)
        for log in child_logs:
            self.assertIn("fake-child-plugin-token", log)

    def test_child_and_fork_keep_parent_package_snapshot(self):
        import shlex
        self.install()
        self.run_nib("plugin", "on", "example")
        command = shlex.join([str(BIN), "plugin", "off", "example"])
        self.mock.code = ('await tools.bash({command:' + json.dumps(command) + '});'
                          'console.log(await tools.agent({prompt:"child $example:review"}));'
                          'console.log(await tools.agent({prompt:"child $example:review",fork:true}));')
        self.ask("probe")
        children = [req[2]["messages"] for req in self.mock.requests
                    if req[2]["messages"][-1].get("role") == "user"
                    and req[2]["messages"][-1].get("content", "").startswith("child $example:review")]
        self.assertEqual(len(children), 2)
        for messages in children:
            self.assertIn("example:review", messages[0]["content"])
            self.assertIn("Review fixture body", messages[-1]["content"])
        self.assertIn("example · off", self.run_nib("plugin", "list"))

    def test_mcp_recursive_paths_fail_without_publication(self):
        (self.source / ".mcp.json").write_text(json.dumps("./.mcp.json"))
        self.run_nib("plugin", "install", self.source, ok=False)
        self.assertIn("No plugins installed", self.run_nib("plugin", "list"))

    def test_unsupported_mcp_is_not_run(self):
        (self.source / ".mcp.json").write_text(json.dumps({"mcpServers": {"bad": {"command": "must-not-run", "headers": {"X": "Y"}}}}))
        self.assertIn("Unsupported: MCP bad", self.install())
        self.run_nib("plugin", "on", "example")
        self.assertNotIn("<mcp_tools>", self.ask()[0]["content"])

    def test_custom_paths_and_subdirectory(self):
        (self.source / "extra").mkdir()
        (self.source / "extra/test.md").write_text("Custom command")
        (self.source / ".claude-plugin/plugin.json").write_text(json.dumps({"name": "example", "commands": ["./extra/test.md"]}))
        self.run_nib("plugin", "install", self.root, "--path", self.source.name)
        self.run_nib("plugin", "on", "example")
        self.assertIn("Custom command", self.ask("/example:test")[1]["content"])

    def test_git_install_from_local_repository(self):
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"], check=True)
        self.assertIn("installed · disabled", self.install(self.source.as_uri()))

    def test_duplicate_install_preserves_enabled_setting(self):
        self.install()
        self.run_nib("plugin", "on", "example")
        self.run_nib("plugin", "install", self.source, ok=False)
        self.assertIn("example · on", self.run_nib("plugin", "list"))
        self.assertEqual(len(list((self.data / "plugins/store").iterdir())), 1)

    def test_rejects_escaping_paths_and_special_files(self):
        for path in ("../outside", str(self.root)):
            with self.subTest(path=path):
                (self.source / ".claude-plugin/plugin.json").write_text(json.dumps({"name": "example", "skills": [path]}))
                self.run_nib("plugin", "install", self.source, ok=False)
        (self.source / ".claude-plugin/plugin.json").write_text('{"name":"example"}')
        (self.source / "link").symlink_to(self.home, target_is_directory=True)
        self.run_nib("plugin", "install", self.source, ok=False)
        self.assertIn("No plugins installed", self.run_nib("plugin", "list"))
        self.assertEqual(list((self.data / "plugins/store").iterdir()), [])

    def test_invalid_manifest_and_namespace_collision(self):
        for manifest in ('{"name":"../bad"}', '{"name":42}', '{bad json'):
            (self.source / ".claude-plugin/plugin.json").write_text(manifest)
            self.run_nib("plugin", "install", self.source, ok=False)
        (self.source / ".claude-plugin/plugin.json").write_text('{"name":"example"}')
        (self.source / "commands/review.md").write_text("collision")
        self.run_nib("plugin", "install", self.source, ok=False)

    def test_can_disable_unavailable_package(self):
        self.install()
        self.run_nib("plugin", "on", "example")
        record = self.data / "plugins/installed/example"
        root = Path(record.read_text().strip())
        (root / ".claude-plugin/plugin.json").write_text("invalid")
        self.assertIn("unavailable", self.run_nib("plugin", "list"))
        self.run_nib("plugin", "off", "example")
        self.ask()


def tui_plugins():
    from test_interjections import Reply, fixture, wait_for, screen
    with tempfile.TemporaryDirectory(prefix="nib-plugins-tui-") as temp:
        for width in (60, 120, 160):
            import fcntl
            import struct
            import termios
            directory = Path(temp) / str(width)
            reply = Reply("plugin-tui-done")
            frozen = Reply("plugin-frozen-done")
            disabled = Reply("plugin-disabled-done")
            with fixture(directory, [reply, frozen, disabled]) as (terminal, home, _):
                fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, width, 0, 0))
                source = directory / "package"
                (source / ".claude-plugin").mkdir(parents=True)
                (source / ".claude-plugin/plugin.json").write_text('{"name":"example"}')
                (source / "commands").mkdir()
                (source / "commands/check.md").write_text("Check $ARGUMENTS")
                env = dict(os.environ, NIB_HOME=str(home))
                result = subprocess.run([str(BIN), "plugin", "install", str(source)], env=env, capture_output=True, timeout=15)
                assert result.returncode == 0, result.stderr
                terminal.send("/plugins\r")
                wait_for(lambda: "example · off" in "\n".join(screen(terminal.output, width, 32)), "installed plugin listing")
                terminal.send("/plugins on example\r")
                wait_for(lambda: "example = true" in (home / "config.toml").read_text(), "plugin enabled")
                terminal.send("/new\r/example:check files\r")
                terminal.wait_turn(reply.text)
                assert "Check files" in reply.messages[1]["content"], reply.messages
                terminal.send("/plugins off example\r")
                wait_for(lambda: "example = false" in (home / "config.toml").read_text(), "plugin disabled")
                terminal.send("/example:check still-here\r")
                terminal.wait_turn(frozen.text)
                assert "Check still-here" in frozen.messages[-1]["content"], frozen.messages
                terminal.send("/new\r$example:check\r")
                terminal.wait_turn(disabled.text)
                assert disabled.messages[1]["content"] == "$example:check", disabled.messages
            print(f"plugins TUI {width} columns: passed")


if __name__ == "__main__":
    result = unittest.main(exit=False).result
    if not result.wasSuccessful():
        sys.exit(1)
    tui_plugins()
