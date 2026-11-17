"""Mouse selection, scrolling and user cards through a PTY. Run after zig build."""
import base64
import contextlib
import fcntl
import signal
import struct
import termios
import os
from pathlib import Path
import re
import tempfile
from unittest.mock import patch

from test_interjections import Terminal, Reply, fixture, finished, history, screen, wait_for


def mouse(button, col, row, release=False):
    return f"\x1b[<{button};{col + 1};{row + 1}{'m' if release else 'M'}"


def clipboard(terminal, start):
    def copied():
        output = terminal.read()[start:]
        matches = re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x1b\\", output)
        return base64.b64decode(matches[-1]).decode() if matches else None
    return wait_for(copied, "OSC 52 clipboard")


@contextlib.contextmanager
def terminal_fixture(tmp, reply):
    env = {key: value for key, value in os.environ.items()
           if key not in ("DISPLAY", "WAYLAND_DISPLAY")}
    with patch.dict(os.environ, env, clear=True):
        with fixture(tmp, [reply]) as (terminal, home, _):
            terminal.send("mouse test\r")
            wait_for(lambda: finished(home, reply.text), "committed reply")
            terminal.until(b"line-079")
            yield terminal


def test_history_ignores_incomplete_record(tmp):
    sessions = tmp / "sessions"
    sessions.mkdir(parents=True)
    path = sessions / ("a" * 32 + ".jsonl")
    complete = b'{"from":0,"messages":[{"content":"done"}]}\n'
    path.write_bytes(complete + b'{"from":1,"messages":[{"content":"partial')
    assert history(tmp) == [{"content": "done"}]
    path.write_bytes(complete + b'{"from":1,"messages":[{"content":"next"}]}\n')
    assert history(tmp) == [{"content": "done"}, {"content": "next"}]


def test_cross_screen_selection(tmp):
    reply = Reply("\n".join(f"- line-{i:03}" for i in range(80)))
    with terminal_fixture(tmp, reply) as terminal:
        for reverse in (True, False):
            if not reverse:
                terminal.send(mouse(64, 1, 1) * 10)
            start = len(terminal.read())
            terminal.send(mouse(0, 1, 20 if reverse else 1)
                          + mouse(64 if reverse else 65, 1, 10) * 8
                          + mouse(32, 8, 1 if reverse else 24)
                          + mouse(0, 8, 1 if reverse else 24, release=True))
            copied = clipboard(terminal, start)
            lines = re.findall(r"line-(\d{3})", copied)
            numbers = list(map(int, lines))
            assert len(numbers) > 32, copied
            assert numbers == list(range(numbers[0], numbers[-1] + 1)), copied
            assert "history" not in copied and "Message nib" not in copied, copied
            assert terminal.child.poll() is None


def test_background_report_and_user_card(tmp):
    reply = Reply("\n".join(f"- line-{i:03}" for i in range(80)))
    with terminal_fixture(tmp, reply) as terminal:
        terminal.send(mouse(64, 1, 1) * 40)
        terminal.until("▎".encode())
        for color in ("0000/0000/0000", "ffff/ffff/ffff"):
            start = len(terminal.read())
            terminal.send(f"\x1b]11;rgb:{color}\x1b\\")
            wait_for(lambda: len(terminal.read()) > start, "theme redraw")
            assert terminal.child.poll() is None
        start = len(terminal.read())
        terminal.send(mouse(0, 3, 0) + mouse(32, 12, 0) + mouse(0, 12, 0, release=True))
        copied = clipboard(terminal, start)
        assert copied == "mouse test", repr(copied)


def test_click_and_ctrl_o_open_single_runs(tmp):
    replies = [Reply("first", code="/* script-one */ await tools.bash({command: 'echo out-one'}); 'ret-one'"), Reply("first-done"),
               Reply("second", code="/* script-two */ await tools.bash({command: 'echo out-two'}); 'ret-two'"), Reply("second-done")]
    with fixture(tmp, replies) as (terminal, home, _):
        for prompt, text in (("one", "first-done"), ("two", "second-done")):
            terminal.send(prompt + "\r")
            terminal.wait_turn(text)

        def view():
            return "\n".join(screen(terminal.read(), 120, 32))

        def title(index):
            rows = [i for i, line in enumerate(view().split("\n")) if "Run" in line and "Script" not in line]
            return rows[index]

        assert "Script" not in view()
        row = title(0)
        terminal.send(mouse(0, 10, row) + mouse(0, 10, row, release=True))
        wait_for(lambda: "Details" in view(), "first Run opened by click")
        assert "Result" not in view() and "Script" not in view(), view()
        row = next(i for i, line in enumerate(view().split("\n")) if "Details" in line)
        terminal.send(mouse(0, 6, row) + mouse(0, 6, row, release=True))
        wait_for(lambda: "Script ·" in view(), "first Details opened by click")
        assert "script-one" not in view() and "script-two" not in view(), view()
        row = next(i for i, line in enumerate(view().split("\n")) if "Script ·" in line)
        terminal.send(mouse(0, 5, row) + mouse(0, 5, row, release=True))
        wait_for(lambda: "script-one" in view(), "first Script opened separately")
        terminal.send("\x0f\x1b[6~")
        wait_for(lambda: view().count("Details") == 2, "latest Run opened by Ctrl+O")
        assert view().count("Script ·") == 1, view()
        row = [i for i, line in enumerate(view().split("\n")) if "Details" in line][-1]
        terminal.send(mouse(0, 6, row) + mouse(0, 6, row, release=True))
        wait_for(lambda: view().count("Script ·") == 2, "latest Details opened")
        assert "script-two" not in view(), view()
        row = [i for i, line in enumerate(view().split("\n")) if "Script ·" in line][-1]
        terminal.send(mouse(0, 5, row) + mouse(0, 5, row, release=True))
        wait_for(lambda: "script-two" in view(), "latest Script opened separately")
        terminal.send("\x0f")
        wait_for(lambda: "script-two" not in view(), "latest Run closed by Ctrl+O")
        assert terminal.child.poll() is None


def test_edit_run_shows_only_diff(tmp):
    code = ('/* edit-script-marker */ console.log(await tools.edit('
            '{path: "sample.txt", old_text: "before-edit", new_text: "after-edit"}));')
    replies = [Reply("editing", code=code), Reply("edit-done")]
    with fixture(tmp, replies) as (terminal, _, __):
        (tmp / "sample.txt").write_text("before-edit\n")
        terminal.send("edit the file\r")
        terminal.wait_turn("edit-done")

        def view():
            return "\n".join(screen(terminal.read(), 120, 32))

        row = next(i for i, line in enumerate(view().split("\n")) if "Run · edit" in line)
        terminal.send(mouse(0, 10, row) + mouse(0, 10, row, release=True))
        wait_for(lambda: "Changes" in view() and "after-edit" in view(), "edit diff opened")
        for simple in (False, True):
            if simple:
                terminal.send("\x13")
                wait_for(lambda: "context " not in view(), "simple mode")
            shown = view()
            assert "before-edit" in shown and "after-edit" in shown, shown
            assert "Result" not in shown and "Script" not in shown, shown
            assert "replaced" not in shown and "edit-script-marker" not in shown, shown
        assert (tmp / "sample.txt").read_text() == "after-edit\n"


def test_caught_edit_failure_keeps_result_and_script(tmp):
    code = ('await tools.edit({path:"sample.txt",old_text:"before",new_text:"after"});'
            'try { await tools.edit({path:"sample.txt",old_text:"missing",new_text:"unused"}); }'
            'catch (e) { console.log("caught-edit-error", e.message); }')
    with fixture(tmp, [Reply("editing", code=code), Reply("caught-edit-done")]) as (terminal, _, __):
        (tmp / "sample.txt").write_text("before\n")
        terminal.send("edit the file\r")
        terminal.wait_turn("caught-edit-done")
        def view():
            return "\n".join(screen(terminal.read(), 120, 32))
        row = next(i for i, line in enumerate(view().split("\n")) if "Run · edit" in line)
        terminal.send(mouse(0, 10, row) + mouse(0, 10, row, release=True))
        wait_for(lambda: "Changes" in view(), "caught edit opened")
        shown = view()
        assert "Result" in shown and "Script" in shown and "caught-edit-error" in shown, shown


def test_simple_mode(tmp):
    replies = [Reply("working", code="/* simple-script */ await tools.bash({command: 'echo done'}); 'done'"), Reply("simple-done"), Reply("second-done")]
    with fixture(tmp, replies) as (terminal, home, env):
        terminal.send("check\r")
        terminal.wait_turn("simple-done")

        terminal.send("again\r")
        terminal.wait_turn("second-done")
        fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
        os.kill(terminal.child.pid, signal.SIGWINCH)

        def view():
            return "\n".join(screen(terminal.read(), 160, 40))

        wait_for(lambda: "╭" + "─" * 158 + "╮" in view(), "resized normal frame")
        wait_for(lambda: "context " in view(), "normal input metadata")
        terminal.send("\x13")
        wait_for(lambda: (home / "config.toml").exists() and 'ui = "simple"' in (home / "config.toml").read_text(), "Ctrl+S persistence")
        wait_for(lambda: "Ask about" not in view() and "tokens" not in view(), "Simple framed input")
        lines = view().split("\n")
        assert lines[37] == "╭" + "─" * 158 + "╮", view()
        assert lines[38] == "│" + " " * 158 + "│", view()
        assert lines[39] == "╰" + "─" * 158 + "╯", view()
        assert lines[0] == " ▎ check", view()
        assert "tokens" not in view() and "mock" not in view(), view()
        row = next(i for i, line in enumerate(view().split("\n")) if "Run" in line)
        terminal.send(mouse(0, 15, row) + mouse(0, 15, row, release=True))
        wait_for(lambda: "Details" in view(), "Run opens by click")
        assert "Result" not in view() and "Script" not in view(), view()
        row = next(i for i, line in enumerate(view().split("\n")) if "Details" in line)
        terminal.send(mouse(0, 6, row) + mouse(0, 6, row, release=True))
        wait_for(lambda: "Script ·" in view(), "Details opens by click")
        assert "simple-script" not in view(), view()
        row = next(i for i, line in enumerate(view().split("\n")) if "Script ·" in line)
        terminal.send(mouse(0, 5, row) + mouse(0, 5, row, release=True))
        wait_for(lambda: "simple-script" in view(), "Script opens by click")
        terminal.send("/simple\r")
        wait_for(lambda: "Ask about" in view(), "command returns to normal")
        assert "simple-script" in view(), view()
        terminal.send("\x13")
        wait_for(lambda: "Ask about" not in view(), "key returns to Simple")
        assert "simple-script" in view(), view()
        terminal.close()
        with patch.object(Terminal, "until", lambda *args, **kwargs: None):
            restarted = Terminal(tmp, env)
        try:
            restarted.until("╭".encode())
            restored = "\n".join(screen(restarted.read(), 120, 32))
            assert "╭" in restored and "Ask about" not in restored, restored
        finally:
            restarted.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-tui-mouse-") as directory:
        for test in (test_history_ignores_incomplete_record, test_cross_screen_selection, test_background_report_and_user_card, test_click_and_ctrl_o_open_single_runs, test_edit_run_shows_only_diff, test_caught_edit_failure_keeps_result_and_script, test_simple_mode):
            test(Path(directory) / test.__name__)
            print(test.__name__ + ": ok")
