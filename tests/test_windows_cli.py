"""Offline CLI smoke test. Pass --runner /path/to/wine to use a Windows build on Linux."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
from threading import Thread


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = request['messages']
        user = max(i for i, message in enumerate(messages) if message['role'] == 'user')
        if any(message['role'] == 'tool' for message in messages[user + 1:]):
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
            if windows:
                _, run = ask('try { await tools.bash({command: "echo should not run"}); } '
                             'catch (err) { console.log(String(err)); }')
                assert 'tools.bash is unavailable' in json.dumps(run), run
        finally:
            server.shutdown()
            thread.join()
    print('CLI smoke passed')


if __name__ == '__main__':
    main()
