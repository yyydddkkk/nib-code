"""Offline CLI smoke test. Pass --runner /path/to/wine to use a Windows build on Linux."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
from threading import Event, Thread


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = request['messages']
        user = max(i for i, message in enumerate(messages) if message['role'] == 'user')
        prompt = messages[user]['content']
        if prompt == 'hold session':
            self.server.holding.set()
            if not self.server.resume.wait(timeout=20):
                return
        if prompt == 'idle once' and not self.server.stalled.is_set():
            self.server.stalled.set()
            self.server.release.wait(timeout=15)
            return
        if prompt in ('idle once', 'hold session') or any(
                message['role'] == 'tool' for message in messages[user + 1:]):
            delta, reason = {'content': 'done'}, 'stop'
        else:
            delta, reason = {'tool_calls': [{
                'index': 0, 'id': 'smoke_' + str(user), 'type': 'function',
                'function': {'name': 'run', 'arguments': json.dumps({'code': messages[user]['content']})},
            }]}, 'tool_calls'
        body = (''.join('data: ' + json.dumps({'choices': [choice]}) + '\n\n' for choice in (
            {'index': 0, 'delta': delta},
            {'index': 0, 'delta': {}, 'finish_reason': reason},
        )) + 'data: [DONE]\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('exe', type=Path)
    parser.add_argument('--runner')
    parser.add_argument('--basic', action='store_true', help='only check startup and the JS runtime')
    args = parser.parse_args()
    argv = ([args.runner] if args.runner else []) + [str(args.exe.resolve(strict=True))]
    windows = os.name == 'nt' or args.runner is not None
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(
        ('NIB_', 'OPENAI_', 'DEEPSEEK_', 'CODEX_'))}
    env.update(NIB_PROVIDER='chat_completions', NIB_API_KEY='mock',
               NIB_CONTEXT_WINDOW='128000', NIB_HOME='nib home 数据', CODEX_HOME='codex')
    with tempfile.TemporaryDirectory(prefix='nib cli 测试 ') as directory, \
            ThreadingHTTPServer(('127.0.0.1', 0), MockHandler) as server:
        cwd = Path(directory)
        env['NIB_BASE_URL'] = f'http://127.0.0.1:{server.server_port}'
        server.holding = Event()
        server.resume = Event()
        server.stalled = Event()
        server.release = Event()
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def nib(*command, input=None, status=0, **overrides):
            result = subprocess.run([*argv, *command], cwd=cwd, env=env | overrides,
                                    input=input, capture_output=True, text=True,
                                    encoding='utf-8', errors='replace', timeout=45)
            assert result.returncode == status, (command, result)
            return result

        def ask(code, *options):
            result = nib('ask', '--json', *options, '-', input=code)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            runs = [e['run_end'] for e in events if 'run_end' in e]
            assert len(runs) == 1 and runs[0]['ok'], (events, result.stderr)
            assert events[-1]['end']['text'] == 'done', events
            return events[0]['start']['session_id'], runs[0]

        try:
            assert nib('--version').stdout.startswith('nib ')
            assert nib('js', 'console.log(40+2)').stdout.splitlines()[0] == '42'
            if args.basic:
                print('Basic CLI smoke passed')
                return
            if windows:
                failure = nib('ask', '--json', 'blocked', status=1, NIB_SANDBOX='workspace')
                assert 'Workspace isolation is unavailable' in failure.stdout, failure
            path = 'notes 文档.txt'
            js_path = json.dumps(path)
            session, _ = ask(f'await tools.write({{path: {js_path}, content: "first\\n"}})')
            assert (cwd / path).read_bytes() == b'first\n'
            resumed, _ = ask(f'const path = {js_path}; await tools.read({{path}}); '
                             'await tools.edit({path, old_text: "first", new_text: "second"});',
                             '--resume', session)
            assert resumed == session
            assert (cwd / path).read_bytes() == b'second\n'
            assert (cwd / env['NIB_HOME'] / 'sessions' / (session + '.jsonl')).is_file()
            if os.name == 'nt':
                from windows_bash_jobs import check
                def resume_interrupted(session):
                    resumed, _ = ask('console.log("resumed")', '--resume', session)
                    assert resumed == session, resumed

                check(argv, cwd, env, resume_interrupted)
            with subprocess.Popen([*argv, 'ask', '--json', 'hold session'], cwd=cwd, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as held:
                try:
                    assert server.holding.wait(timeout=15), 'mock did not receive the request'
                    held_id = json.loads(held.stdout.readline())['start']['session_id']
                    busy = nib('ask', '--json', '--resume', held_id, 'contended', status=1)
                    assert 'Session is busy in another process' in busy.stdout, busy
                    server.resume.set()
                    out, err = held.communicate(timeout=15)
                    assert held.returncode == 0 and json.loads(out.splitlines()[-1])['end']['text'] == 'done', (out, err)
                finally:
                    server.resume.set()
                    if held.poll() is None:
                        held.kill()
            config = cwd / env['NIB_HOME'] / 'config.toml'
            config.write_text('[limits]\nstream_idle_timeout_s = 1\n', encoding='utf-8')
            stalled = nib('ask', '--json', 'idle once')
            events = [json.loads(line) for line in stalled.stdout.splitlines()]
            retries = [e['retry'] for e in events if 'retry' in e]
            assert server.stalled.is_set() and len(retries) == 1, events
            assert 'Stream idle timeout' in retries[0]['reason'], events
            assert events[-1]['end']['text'] == 'done', events
        finally:
            server.release.set()
            server.shutdown()
            thread.join()
    print('CLI smoke passed')


if __name__ == '__main__':
    main()
