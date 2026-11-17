"""tools.search E2E against local provider mocks only. Run after `zig build`."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from mock_providers import Mock

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"

CODE = """const found = await tools.search({query: "zig", count: 2});
const unsearched = await tools.search({query: "nosearch"});
let bad = [];
for (const args of [{query: "x", count: 0}, {query: ""}]) {
  try { await tools.search(args); } catch (e) { bad.push(e.message); }
}
({found, unsearched, bad})"""

PAGE_B = {"title": "B page", "url": "https://b.dev/2"}


class WebSearch(unittest.TestCase):
    def run_session(self, provider, protocol, key_env, code=CODE, **mock_args):
        tmp = tempfile.TemporaryDirectory(prefix="nib-search-")
        self.addCleanup(tmp.cleanup)
        mock = Mock(protocol, code=code, **mock_args)
        self.addCleanup(mock.close)
        home = Path(tmp.name)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_", "XAI_", "CODEX_"))}
        env.update(HOME=tmp.name, NIB_HOME=str(home / "nib"), NIB_PROVIDER=provider, NIB_BASE_URL=mock.url,
                   NIB_RECORD="on", NIB_CODEX_TRANSPORT="sse", NIB_CODEX_RUN_TOOL="function")
        if key_env:
            env[key_env] = mock.key
        else:
            (home / "codex").mkdir()
            (home / "codex/auth.json").write_text(json.dumps({"tokens": {
                "access_token": "fake-search-access", "account_id": "fake-search-account",
                "refresh_token": "fake-search-refresh", "id_token": "fake-search-id"}}))
            env["CODEX_HOME"] = str(home / "codex")
        result = subprocess.run([str(BIN), "ask", "--json", "search"], cwd=tmp.name, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(mock.errors, mock.errors)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        output = next(e["run_end"]["output"] for e in events if "run_end" in e)
        return mock, json.loads(output.removeprefix("result: ")), home

    def first(self, mock):
        path, headers, body = mock.searches[0]
        return path, {k.lower(): v for k, v in headers.items()}, body

    def check_arguments(self, value):
        self.assertEqual(len(value["bad"]), 2, value)

    def check_responses(self, provider, key_env, **mock_args):
        mock, value, _ = self.run_session(provider, "responses", key_env, custom_run=provider == "openai", **mock_args)
        path, headers, body = self.first(mock)
        self.assertEqual(path, "/codex/responses" if provider == "codex" else "/responses")
        self.assertEqual(body["model"], "gpt-6-luna")
        self.assertEqual(body["tools"], [{"type": "web_search", "search_context_size": "high"}])
        self.assertEqual((body["tool_choice"], body["store"], body["stream"]), ("required", False, True))
        self.assertEqual(body["include"], ["web_search_call.action.sources"])
        self.assertEqual(body["input"][0]["content"], [{"type": "input_text", "text": "zig"}])
        if provider == "codex":
            self.assertEqual(headers["chatgpt-account-id"], "fake-search-account")
            self.assertEqual(headers["authorization"], "Bearer fake-search-access")
        else:
            self.assertEqual(headers["authorization"], "Bearer " + mock.key)
        found = value["found"]
        self.assertEqual(found["ok"], True)
        self.assertEqual(found["answer"], "answer for zig")
        self.assertEqual(found["results"], [dict(PAGE_B, summary=""), {"title": "https://a.dev/1", "url": "https://a.dev/1", "summary": ""}])
        self.assertEqual(value["unsearched"], {"ok": False, "error": "model answered without searching"})
        self.check_arguments(value)
        self.assertEqual(len(mock.searches), 2)

    def test_codex(self):
        self.check_responses("codex", None, codex=True)

    def test_openai(self):
        self.check_responses("openai", "OPENAI_API_KEY")

    def test_anthropic(self):
        mock, value, _ = self.run_session("anthropic", "anthropic_messages", "ANTHROPIC_API_KEY")
        path, headers, body = self.first(mock)
        self.assertEqual(path, "/v1/messages")
        self.assertEqual(headers["x-api-key"], mock.key)
        self.assertEqual(body["model"], "claude-haiku-5-5")
        self.assertEqual(body["tools"][0]["type"], "web_search_20250305")
        self.assertEqual(body["messages"], [{"role": "user", "content": "zig"}])
        found = value["found"]
        self.assertEqual(found["answer"], "answer for zig")
        self.assertEqual(found["results"], [dict(PAGE_B, summary="quote"), {"title": "A page", "url": "https://a.dev/1", "date": "May 1, 2026", "summary": ""}])
        self.assertEqual(value["unsearched"], {"ok": False, "error": "model answered without searching"})
        self.check_arguments(value)

    def test_deepseek(self):
        code = CODE.replace("({found", """let long = "";
try { await tools.search({query: "中".repeat(129)}); } catch (e) { long = e.message; }
({long, found""")
        mock, value, home = self.run_session("deepseek", "chat_completions", "DEEPSEEK_API_KEY", code=code)
        path, headers, body = self.first(mock)
        self.assertEqual(path, "/v1/tools/search")
        self.assertEqual(headers["authorization"], "Bearer " + mock.key)
        self.assertEqual(body, {"query": "zig", "count": 2})
        self.assertEqual(value["found"], {"ok": True, "results": [
            {"title": "A page", "url": "https://a.dev/1", "summary": "sum"},
            {"title": "B page", "url": "https://b.dev/2", "date": "2026-01-02", "summary": "only snippet"}]})
        self.assertIn("at most 128", value["long"])
        self.check_arguments(value)
        self.replay_offline(mock, home)

    def replay_offline(self, mock, home):
        sessions = [f for f in (home / "nib/sessions").glob("*.jsonl") if not f.name.endswith(".calls.jsonl")]
        self.assertEqual(len(sessions), 1)
        before = len(mock.searches)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "DEEPSEEK_"))}
        env["NIB_HOME"] = str(home / "nib")
        result = subprocess.run([str(BIN), "replay", sessions[0].stem, "--all", "--json"], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual((report["total"], report["matched"], report["divergences"]), (1, 1, 0), report)
        self.assertEqual(len(mock.searches), before)

    def test_unsupported_provider(self):
        code = 'await tools.search({query: "zig"})'
        mock, value, _ = self.run_session("xai", "responses", "XAI_API_KEY", code=code)
        self.assertEqual(value, {"ok": False, "error": "web search is not available for provider xai"})
        self.assertEqual(mock.searches, [])


if __name__ == "__main__":
    unittest.main()
