"""`$skill` mentions: expansion in `nib ask`, resume, and the `$` completion menu. Run after zig build."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from test_interjections import Reply, fixture, finished, wait_for, users
from screen import screen

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def ask_expansion():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        home, data, project = [root / name for name in ("home", "data", "project")]
        for path in (home, data, project):
            path.mkdir()
        (project / ".git").mkdir()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        requests = root / "requests.jsonl"
        server = subprocess.Popen(["python3", str(ROOT / "tests/mock_llm.py"), str(port), str(requests)])
        try:
            for _ in range(100):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.05)
            env = dict(os.environ, HOME=str(home), NIB_HOME=str(data), NIB_PROVIDER="chat_completions", NIB_MODEL="mock", NIB_API_KEY="mock", NIB_BASE_URL=f"http://127.0.0.1:{port}/v1")
            skill = project / ".nib/skills/release/SKILL.md"
            skill.parent.mkdir(parents=True)
            skill.write_text("---\nname: release\ndescription: Ship it\ndisable-model-invocation: true\n---\nRELEASE-BODY-MARKER")

            def ask(prompt, *args):
                result = subprocess.run([str(BIN), "ask", prompt, *args], cwd=project, env=env, capture_output=True, timeout=20)
                assert result.returncode == 0, result.stderr
                return [m for m in json.loads(requests.read_text().splitlines()[-1])["messages"] if m["role"] == "user"][-1]["content"]

            plain = ask("prepare $FOO and $HOME")
            assert plain == "prepare $FOO and $HOME", plain
            content = ask("prepare 0.11.0 with $release, $release")
            assert content.startswith("prepare 0.11.0 with $release, $release\n\n")
            assert content.count("<skill name=\"release\"") == 1, content
            assert f'location="{skill.resolve()}"' in content and "RELEASE-BODY-MARKER" in content
            assert "description: Ship it" not in content
            assert not (data / "config.toml").exists()
            session = max((p for p in (data / "sessions").glob("*.jsonl") if not p.name.endswith(".calls.jsonl")), key=lambda p: p.stat().st_mtime)
            assert "RELEASE-BODY-MARKER" in session.read_text()
            skill.unlink()
            resumed = ask("again", "--resume", session.stem)
            assert resumed == "again"
            history = json.loads(requests.read_text().splitlines()[-1])["messages"]
            assert any("RELEASE-BODY-MARKER" in (m.get("content") or "") for m in history), "resume must keep the expanded message"
        finally:
            server.terminate()
            server.wait()


def tui_menu(tmp):
    reply = Reply("done")
    with fixture(tmp, [reply]) as (terminal, home, _):
        skill = tmp / ".nib/skills/review/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("---\ndescription: Review a change\n---\nREVIEW-BODY")
        terminal.send("check this $re")
        wait_for(lambda: "Review a change" in "\n".join(screen(terminal.read(), 120, 32)), "skill candidate")
        terminal.send("\r")
        wait_for(lambda: "check this $review " in "\n".join(screen(terminal.read(), 120, 32)), "accepted skill")
        assert not reply.received.is_set(), "Enter accepted the completion and must not send"
        terminal.send("now\r")
        wait_for(lambda: finished(home, "done"), "committed reply")
        reply.received.wait(5)
        assert "REVIEW-BODY" in users(reply.messages)[-1], reply.messages
        assert users(reply.messages)[-1].startswith("check this $review now"), reply.messages


def tui_scroll_skills(tmp):
    with fixture(tmp, []) as (terminal, _, _):
        for i in range(14):
            skill = tmp / f".nib/skills/task-{i:02}/SKILL.md"
            skill.parent.mkdir(parents=True)
            skill.write_text(f"---\ndescription: Task number {i:02}\n---\n")

        def visible():
            return "\n".join(screen(terminal.read(), 120, 32))

        terminal.send("$")
        wait_for(lambda: "Task number 00" in visible(), "first skill candidate")
        assert "Task number 13" not in visible(), "the list should scroll, not resize the menu"
        terminal.send("\x1b[B" * 13)
        wait_for(lambda: "Task number 13" in visible(), "last skill after scrolling")
        terminal.send("\t")
        wait_for(lambda: "$task-13 " in visible(), "accepted last skill")


if __name__ == "__main__":
    ask_expansion()
    with tempfile.TemporaryDirectory(prefix="nib-skill-mentions-") as directory:
        tui_menu(Path(directory) / "menu")
        tui_scroll_skills(Path(directory) / "scroll")
    print("skill mentions: ok")
