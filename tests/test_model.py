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
        terminal.send("/model openai/gpt-6.1-sol\r")
        terminal.until("openai · gpt-6.1-sol · new session".encode())
        terminal.send("/resume " + original + "\r")
        terminal.until(("resumed session " + original[:8]).encode())
        terminal.send("again switched\r")
        wait_for(lambda: len(first.requests) == 3, "cross-model resume request")
        terminal.wait_turn("mock answer")
        switched = first.requests[-1][2]
        assert switched["model"] == "gpt-6.1-sol"
        assert "again first" in json.dumps(switched["input"])
        assert "again switched" in json.dumps(switched["input"])
        assert not any(item.get("type") == "reasoning" for item in switched["input"])
        assert not first.errors and not second.errors, (first.errors, second.errors)
    finally:
        if terminal:
            terminal.close()
        first.close()
        second.close()


def test_resume_profile_status(tmp):
    tmp.mkdir()
    home = tmp / "home"
    home.mkdir()
    mock = Mock("responses", custom_run=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "CODEX_"))}
    env.update(HOME=str(home), NIB_HOME=str(home), NIB_PROVIDER="openai",
               OPENAI_API_KEY=mock.key, TERM="xterm-256color")
    (home / "config.toml").write_text(f'[openai]\nbase_url = "{mock.url}"\ncontext_window = 128000\n')
    sessions = home / "sessions"
    bin_path = Path(__file__).resolve().parents[1] / "zig-out/bin/nib"

    def start(model):
        previous = set(sessions.glob("*.jsonl"))
        result = subprocess.run([str(bin_path), "ask", "again original"], cwd=tmp,
                                env={**env, "NIB_MODEL": model}, capture_output=True,
                                text=True, timeout=15)
        assert result.returncode == 0, result.stderr
        log, = set(sessions.glob("*.jsonl")) - previous
        return log

    def check_status(log, model, profile, send_turn=False):
        terminal = Terminal(tmp, {**env, "NIB_MODEL": model,
                                  "NIB_TUNE": "delivery=user,validation=single"})
        try:
            terminal.send(f"/resume {log.stem}\r")
            terminal.until(f"resumed session {log.stem[:8]}".encode())
            terminal.send("/status\r")
            terminal.until(b"No completed turn yet.")
            visible = "\n".join(screen(terminal.read(), 120, 32))
            lines = [line.strip() for line in visible.splitlines() if "retained session Profile:" in line]
            assert lines == ([] if profile is None else [f"{model} · retained session Profile: {profile}"]), visible
            if send_turn:
                before = len(log.read_bytes().splitlines())
                terminal.send("again resumed\r")
                wait_for(lambda: log.read_bytes().count(b"\n") > before, "resumed Step")
                terminal.wait_turn("mock answer")
                return mock.requests[-1][2]
        finally:
            terminal.close()

    try:
        original = start("deepseek-flash")
        header_bytes = original.read_bytes().splitlines()[0]
        header = json.loads(header_bytes)
        system = mock.requests[-1][2]["instructions"].encode()
        assert system == header["messages"][0]["content"].encode()
        assert (header["family"], header["profile"]) == ("deepseek", "deepseek")
        assert header["tuning"] == {"delivery": "tool", "validation": "none"}
        check_status(original, "deepseek-pro", None)

        target = "gpt-6.1-sol"
        resumed = check_status(original, target, "deepseek", send_turn=True)
        assert resumed["model"] == target
        assert resumed["instructions"].encode() == system
        records = original.read_bytes().splitlines()
        assert records[0] == header_bytes
        assert json.loads(records[-1])["model"] == target
        # The latest Step now matches the request, but the header still wins.
        check_status(original, target, "deepseek")

        legacy = sessions / ("1" * 32 + ".jsonl")
        del header["profile"]
        del header["family"]
        legacy.write_bytes(b"\n".join([json.dumps(header).encode(), *records[1:]]) + b"\n")
        check_status(legacy, target, "unknown")
        check_status(legacy, "deepseek-flash", None)
        del header["model"]
        legacy.write_bytes(b"\n".join([json.dumps(header).encode(), *records[1:]]) + b"\n")
        check_status(legacy, "deepseek-flash", None)

        fallback = start("gemini-flash")
        assert json.loads(fallback.read_bytes().splitlines()[0])["profile"] == "default"
        check_status(fallback, "gemini-pro", None)
        check_status(fallback, "other-model", "default")  # different family, same Profile
        assert not mock.errors, mock.errors
    finally:
        mock.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-model-") as directory:
        test_model(Path(directory) / "model")
        test_resume_profile_status(Path(directory) / "resume-profile")
    print("model switch: ok")
