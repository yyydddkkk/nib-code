"""Model switching through the TUI, using local providers and fake keys only."""
import json
import os
from pathlib import Path
import tempfile
import subprocess

from mock_providers import Mock
from test_interjections import Terminal, wait_for, screen


def test_model(tmp):
    tmp.mkdir()
    home = tmp / "home"
    home.mkdir()
    first = Mock("responses", custom_run=True)
    second = Mock("anthropic_messages")
    config = home / "config.toml"
    config.write_text(f'# keep\nprovider = "anthropic"\neffort = "high"\n[openai]\nbase_url = "{first.url}"\n[anthropic]\nbase_url = "{second.url}"\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "CODEX_")) and k not in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY")}
    env.update(HOME=str(home), NIB_HOME=str(home), NIB_PROVIDER="anthropic", OPENAI_API_KEY=first.key, ANTHROPIC_API_KEY=second.key, TERM="xterm-256color")
    terminal = None
    def logs():
        return [p for p in (home / "sessions").glob("*.jsonl") if not p.name.endswith(".calls.jsonl")]
    def completed(count):
        return sum('"role":"assistant"' in p.read_text() for p in logs()) >= count
    try:
        terminal = Terminal(tmp, env)
        original = logs()[0].stem
        terminal.send("/model\r")
        terminal.until(b"current")
        terminal.until(b"gpt-6.1-terra")
        terminal.until(b"claude-sonnet-5-5")
        terminal.send("\x15/model gpt-6.1-t")
        wait_for(lambda: "/model gpt-6.1-t" in "\n".join(screen(terminal.read(), 120, 32)), "model filter")
        terminal.send("\t\r")
        terminal.until(b"NIB_PROVIDER overrides at startup")
        wait_for(lambda: 'model = "gpt-6.1-terra"' in config.read_text(), "saved model")
        assert [p.stem for p in logs()] == [original]
        terminal.send("again first\r")
        wait_for(lambda: completed(1), "first committed step")
        terminal.wait_turn("mock answer")
        assert first.requests[-1][2]["model"] == "gpt-6.1-terra"
        terminal.send("/model anthropic/claude-sonnet-5-5\t\r")
        terminal.until(b"new session")
        wait_for(lambda: len(logs()) == 2, "new session")
        terminal.send("again second\r")
        wait_for(lambda: completed(2), "second committed step")
        terminal.wait_turn("mock answer")
        assert second.requests[-1][2]["model"] == "claude-sonnet-5-5"
        assert len(first.requests) == 1
        messages = second.requests[-1][2]["messages"]
        assert "again first" not in json.dumps(messages)
        text = config.read_text()
        assert text.startswith('# keep\nprovider = "anthropic"\neffort = "high"\n')
        assert 'model = "claude-sonnet-5-5"' in text
        old = [json.loads(line) for line in (home / "sessions" / (original + ".jsonl")).read_text().splitlines()]
        assert old[-1].get("model") == "gpt-6.1-terra"
        resumed = subprocess.run([str(Path(__file__).resolve().parents[1] / "zig-out/bin/nib"), "ask", "--resume", original, "again resumed"], cwd=tmp, env={**env, "NIB_PROVIDER": "openai", "NIB_MODEL": "gpt-6.1-terra"}, capture_output=True, text=True, timeout=15)
        assert resumed.returncode == 0, resumed.stderr
        assert "mock answer" in resumed.stdout
        assert not first.errors and not second.errors, (first.errors, second.errors)
    finally:
        if terminal:
            terminal.close()
        first.close()
        second.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-model-") as directory:
        test_model(Path(directory) / "model")
    print("model switch: ok")
