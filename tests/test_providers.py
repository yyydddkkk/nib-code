"""Provider selection, wire round trips, resume and inheritance; local mocks only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from mock_providers import Mock

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class Providers(unittest.TestCase):
    def exercise(self, name, protocol, key_env, custom=False):
        with tempfile.TemporaryDirectory(prefix="nib-provider-") as tmp:
            home = Path(tmp)
            mock = Mock(protocol, custom_run=name == "openai")
            self.addCleanup(mock.close)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_", "XAI_", "CODEX_"))}
            env.update(NIB_API_KEY=mock.key, DEEPSEEK_API_KEY=mock.key, HOME=tmp, NIB_HOME=str(home / "nib"), NIB_PROVIDER=name, NIB_BASE_URL=mock.url)
            env[key_env] = mock.key
            if custom:
                (home / "nib").mkdir()
                (home / "nib/config.toml").write_text(f'[providers.{name}]\nprotocol = "{protocol}"\nbase_url = "{mock.url}"\nmodel = "custom-model"\ncontext_window = 128000\napi_key_env = "{key_env}"\n')
            def ask(prompt, *args, ok=True, provider=None):
                result = subprocess.run([str(BIN), "ask", "--json", prompt, *args], cwd=tmp, env=dict(env, NIB_PROVIDER=provider or name), capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
                return [json.loads(line) for line in result.stdout.splitlines()]
            events = ask("round trip", "--effort", "high")
            if name == "openai":
                self.assertTrue(all(body["model"] == "gpt-6.2-sol" for _, _, body in mock.requests))
            self.assertFalse(mock.errors, mock.errors)
            end = events[-1]["end"]
            self.assertEqual(end["steps"], 2)
            self.assertEqual(end["usage"]["prompt_tokens"], 200)
            self.assertEqual(end["usage"]["prompt_cache_hit_tokens"], 16)
            if protocol in ("anthropic_messages", "responses"):
                self.assertEqual(end["usage"]["prompt_cache_write_tokens"], 8)
            session = events[0]["start"]["session_id"]
            before = len(mock.requests)
            ask("again", "--resume", session)
            self.assertEqual(len(mock.requests), before + 1)
            other = "deepseek" if name != "deepseek" else "chat_completions"
            mismatch = ask("again", "--resume", session, provider=other, ok=False)
            self.assertIn("different provider", mismatch[-1]["error"]["message"])
            failed = ask("unauthorized", ok=False)
            message = failed[-1]["error"]["message"]
            self.assertIn("401", message)
            self.assertIn(key_env, message)
            self.assertNotIn("fake-key-must-not-be-echoed", message)
            delegated = ask("delegate")
            self.assertEqual(delegated[-1]["end"]["usage"]["prompt_tokens"], 400)
            self.assertFalse(mock.errors, mock.errors)
            rows = [json.loads(line) for file in (home / "nib/sessions").glob("*.jsonl") if not file.name.endswith(".calls.jsonl") for line in file.read_text().splitlines()]
            self.assertTrue(any(row.get("parent_session_id") for row in rows))
            self.assertNotIn(mock.key, json.dumps(rows))
            help_result = subprocess.run([str(BIN), "--help"], cwd=tmp, env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(help_result.returncode, 0)
            self.assertIn("Active provider: " + name, help_result.stdout)
            if protocol == "anthropic_messages":
                report = subprocess.run(["python3", str(ROOT / "scripts/stats.py"), str(home / "nib/sessions"), "--json"], capture_output=True, text=True, timeout=5)
                self.assertEqual(report.returncode, 0, report.stderr)
                self.assertGreater(json.loads(report.stdout)["usage"]["prompt_cache_write_tokens"], 0)

    def test_chat_completion_consistency(self):
        example = 'Quoted example: <｜DSML｜tool_calls><｜DSML｜invoke name="run">console.log("example")</｜DSML｜invoke></｜DSML｜tool_calls>'
        for structured, reason in ((False, "tool_calls"), (False, "stop"), (False, None), (True, "tool_calls"), (True, None)):
            with self.subTest(structured=structured, reason=reason), tempfile.TemporaryDirectory(prefix="nib-chat-finish-") as tmp:
                mock = Mock("chat_completions")
                self.addCleanup(mock.close)

                def serve(h, body):
                    h.send_response(200)
                    h.send_header("Content-Type", "text/event-stream")
                    h.end_headers()

                    def event(delta, **extra):
                        h.wfile.write(("data: " + json.dumps({"choices": [{"delta": delta, **extra}]}) + "\n\n").encode())

                    has_result = any(m.get("role") == "tool" for m in body["messages"])
                    event({"content": example}, finish_reason=None)
                    if structured and not has_result:
                        args = json.dumps({"code": 'console.log("fragmented");'})
                        event({"tool_calls": [{"index": 0, "id": "call_1", "function": {"name": "run", "arguments": args[:9]}}]})
                        event({"tool_calls": [{"index": 0, "function": {"arguments": args[9:]}}]})
                    terminal = "stop" if has_result else reason
                    event({}, **({"finish_reason": terminal} if terminal else {}))
                    h.wfile.write(b'data: {"choices":[],"usage":{"prompt_tokens":10}}\n\ndata: [DONE]\n\n')

                mock.serve = serve
                env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "DEEPSEEK_"))}
                env.update(HOME=tmp, NIB_HOME=str(Path(tmp) / "nib"), NIB_PROVIDER="deepseek", NIB_API_KEY=mock.key, DEEPSEEK_API_KEY=mock.key, NIB_BASE_URL=mock.url)
                result = subprocess.run([str(BIN), "ask", "--json", "check completion"], cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
                events = [json.loads(line) for line in result.stdout.splitlines()]
                inconsistent = not structured and reason == "tool_calls"
                self.assertEqual(result.returncode == 0, not inconsistent, result.stdout + result.stderr)
                if inconsistent:
                    self.assertIn("InvalidResponse", events[-1]["error"]["message"])
                    self.assertFalse(any("end" in e for e in events))
                else:
                    self.assertIn("end", events[-1])
                    self.assertEqual(events[-1]["end"]["steps"], 2 if structured else 1)
                    self.assertEqual(events[-1]["end"]["text"], example)
                runs = [e["run_start"] for e in events if "run_start" in e]
                self.assertEqual(runs, ['console.log("fragmented");'] if structured else [])
                self.assertEqual(len(mock.requests), 2 if structured else 1)
                self.assertFalse(mock.errors, mock.errors)

    def test_builtins(self):
        for name, protocol, key in [("openai", "responses", "OPENAI_API_KEY"), ("xai", "responses", "XAI_API_KEY"), ("anthropic", "anthropic_messages", "ANTHROPIC_API_KEY"), ("deepseek", "chat_completions", "DEEPSEEK_API_KEY")]:
            with self.subTest(provider=name):
                self.exercise(name, protocol, key)

    def test_gpt_62_minimum_reasoning(self):
        with tempfile.TemporaryDirectory(prefix="nib-gpt-62-") as tmp:
            mock = Mock("responses", custom_run=True)
            self.addCleanup(mock.close)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "OPENAI_", "CODEX_"))}
            env.update(HOME=tmp, NIB_HOME=str(Path(tmp) / "nib"), NIB_PROVIDER="openai", NIB_BASE_URL=mock.url, OPENAI_API_KEY=mock.key)
            for model in ("gpt-6.2-sol", "gpt-6.2-astra"):
                with self.subTest(model=model):
                    result = subprocess.run([str(BIN), "ask", "--json", "again", "--effort", "off"], cwd=tmp, env=dict(env, NIB_MODEL=model), capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    body = mock.requests[-1][2]
                    self.assertEqual(body["model"], model)
                    self.assertEqual(body["reasoning"], {"effort": "low"})
            self.assertFalse(mock.errors, mock.errors)

    def test_custom_identity_and_no_auth(self):
        with tempfile.TemporaryDirectory(prefix="nib-provider-noauth-") as tmp:
            mock = Mock("responses", key="")
            self.addCleanup(mock.close)
            home = Path(tmp) / "nib"
            home.mkdir()
            sections = "".join(f'[providers.{name}]\nprotocol = "responses"\nbase_url = "{mock.url}"\nmodel = "local-model"\ncontext_window = 128000\n' for name in ("one", "two"))
            (home / "config.toml").write_text('provider = "one"\n' + sections)
            env = {k: v for k, v in os.environ.items() if not k.startswith("NIB_")}
            env.update(HOME=tmp, NIB_HOME=str(home))
            def run(*args):
                return subprocess.run([str(BIN), "ask", "--json", *args], cwd=tmp, env=env, capture_output=True, text=True, timeout=10)
            first = run("round trip")
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            session = json.loads(first.stdout.splitlines()[0])["start"]["session_id"]
            header = json.loads((home / "sessions" / (session + ".jsonl")).read_text().splitlines()[0])
            self.assertEqual(header["custom_provider"], "one")
            env["NIB_PROVIDER"] = "two"
            other = run("again", "--resume", session)
            self.assertNotEqual(other.returncode, 0)
            self.assertIn("different provider", other.stdout)
            self.assertFalse(mock.errors, mock.errors)

    def test_custom(self):
        for protocol in ("responses", "chat_completions", "anthropic_messages"):
            with self.subTest(protocol=protocol):
                self.exercise("mysite", protocol, "SITE_KEY", custom=True)

    def test_custom_max_output(self):
        for protocol, field in (("responses", "max_output_tokens"), ("chat_completions", "max_tokens"), ("anthropic_messages", "max_tokens")):
            for limit in (None, 4096):
                with self.subTest(protocol=protocol, limit=limit), tempfile.TemporaryDirectory(prefix="nib-provider-limit-") as tmp:
                    mock = Mock(protocol, key="")
                    self.addCleanup(mock.close)
                    home = Path(tmp) / "nib"
                    home.mkdir()
                    extra = f"max_output = {limit}\n" if limit else ""
                    (home / "config.toml").write_text(f'provider = "site"\n[providers.site]\nprotocol = "{protocol}"\nbase_url = "{mock.url}"\nmodel = "m"\ncontext_window = 128000\n{extra}')
                    env = {k: v for k, v in os.environ.items() if not k.startswith("NIB_")}
                    env.update(HOME=tmp, NIB_HOME=str(home))
                    result = subprocess.run([str(BIN), "ask", "--json", "round trip"], cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    bodies = [json.loads(body) if isinstance(body, (str, bytes)) else body for _, _, body in mock.requests]
                    self.assertTrue(bodies)
                    for body in bodies:
                        if protocol == "anthropic_messages" and limit is None:
                            self.assertEqual(body["max_tokens"], 128000)
                        elif limit is None or protocol == "responses":
                            self.assertNotIn(field, body)
                        else:
                            self.assertEqual(body[field], limit)


if __name__ == "__main__":
    unittest.main()
