"""Drive nib through Windows ConPTY; no real provider or credentials are used."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from queue import Empty, Queue
import select
import signal
import sys
import tempfile
from threading import Thread
import time

import pyte
from winpty import Backend, PtyProcess


class Model(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        prompt = next(m['content'] for m in reversed(request['messages']) if m['role'] == 'user')
        self.server.prompts.put(prompt)
        self.server.turns += 1
        choice = {'index': 0, 'delta': {'content': f'mock-answer-{self.server.turns}'}, 'finish_reason': 'stop'}
        body = ('data: ' + json.dumps({'choices': [choice]}) + '\n\ndata: [DONE]\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Terminal:
    def __init__(self, exe, cwd, env):
        self.process = PtyProcess.spawn([str(exe)], cwd=str(cwd), env=env, dimensions=(30, 96),
                                        backend=Backend.ConPTY)
        self.screen = pyte.Screen(96, 30)
        self.stream = pyte.Stream(self.screen)
        self.output = ''

    def pump(self):
        if select.select([self.process.fileobj], [], [], 0.1)[0]:
            try:
                text = self.process.read(16384)
            except EOFError:
                return
            self.output += text
            self.stream.feed(text)

    def wait(self, condition, label):
        end = time.monotonic() + 15
        while time.monotonic() < end:
            self.pump()
            if condition():
                return
            if not self.process.isalive():
                break
        self.fail(label)

    def fail(self, label):
        raise AssertionError((label, '\n'.join(self.screen.display), self.output[-6000:]))

    def shown(self, text):
        self.wait(lambda: any(text in row for row in self.screen.display), text)

    def send(self, text):
        self.process.write(text)

    def resize(self, rows, cols):
        self.screen.resize(rows, cols)
        self.process.setwinsize(rows, cols)

    def stop(self):
        if self.process.isalive():
            self.process.kill(signal.SIGTERM)
        self.process.close(force=True)


def exercise(t, prompts):
    def submitted(expected):
        assert prompts.get(timeout=10) == expected, expected

    t.shown('mock-windows-model')
    t.send('typing-xyz\x7f\x1b[DQ')
    t.shown('typing-xQy')
    t.send('\r')
    submitted('typing-xQy')
    t.shown('mock-answer-1')
    print('Windows TUI: typing, Backspace, Left and Enter passed', flush=True)

    t.send('\x1b[200~paste-first 中文\r\npaste-second\x1b[201~')
    t.shown('paste-first 中文')
    t.shown('paste-second')
    try:
        raise AssertionError(('paste submitted before Enter', prompts.get(timeout=0.5)))
    except Empty:
        pass
    t.send('\r')
    submitted('paste-first 中文\npaste-second')
    t.shown('mock-answer-2')
    print('Windows TUI: Unicode multiline paste stayed in the editor until Enter', flush=True)

    draft = 'resize-start-' + 'a' * 43 + '-resize-end'
    t.send(draft)
    t.shown(draft)
    t.resize(18, 44)
    t.wait(lambda: any('resize-start' in row for row in t.screen.display) and
           any('resize-end' in row and 'resize-start' not in row for row in t.screen.display),
           'draft reflow after shrink')
    t.send('X')
    t.shown('resize-endX')
    t.resize(30, 96)
    t.shown(draft + 'X')
    t.send('\r')
    submitted(draft + 'X')
    t.shown('mock-answer-3')
    print('Windows TUI: shrink, edit, grow and submit passed', flush=True)

    t.send('\x03')
    t.shown('press ctrl+c again to quit')
    t.send('\x03')
    t.wait(lambda: not t.process.isalive(), 'clean exit')
    assert t.process.exitstatus == 0, t.process.exitstatus
    assert '\x1b[?1049l' in t.output, repr(t.output[-300:])
    print('Windows TUI: exited and left the alternate screen', flush=True)


def main(exe):
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(
        ('NIB_', 'OPENAI_', 'DEEPSEEK_', 'CODEX_'))}
    with tempfile.TemporaryDirectory(prefix='nib tui 测试 ') as directory, \
            ThreadingHTTPServer(('127.0.0.1', 0), Model) as server:
        cwd = Path(directory)
        env.update(NIB_PROVIDER='chat_completions', NIB_API_KEY='mock', NIB_MODEL='mock-windows-model',
                   NIB_CONTEXT_WINDOW='128000', NIB_HOME=str(cwd / 'home'), CODEX_HOME=str(cwd / 'codex'),
                   NIB_BASE_URL=f'http://127.0.0.1:{server.server_port}', TERM='xterm-256color')
        server.prompts = Queue()
        server.turns = 0
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            terminal = Terminal(exe, cwd, env)
            try:
                exercise(terminal, server.prompts)
            finally:
                terminal.stop()
        finally:
            server.shutdown()
            thread.join()


if __name__ == '__main__':
    main(Path(sys.argv[1]).resolve(strict=True))
