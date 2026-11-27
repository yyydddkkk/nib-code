"""Native Windows process-tree assertions for the CLI smoke test."""

import ctypes as C
from ctypes import wintypes as W
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time


PROBE = '''
import os
from pathlib import Path
import subprocess
import sys
import time

if sys.argv[1] == 'leaf':
    Path('leaf.pid').write_text(str(os.getpid()), encoding='ascii')
else:
    subprocess.Popen([sys.executable, __file__, 'leaf'])
    Path('branch.pid').write_text(str(os.getpid()), encoding='ascii')
time.sleep(30)
'''


def check(argv, cwd, env):
    kernel = C.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
    kernel.WaitForSingleObject.restype = W.DWORD
    kernel.TerminateProcess.argtypes = [W.HANDLE, W.UINT]
    kernel.CloseHandle.argtypes = [W.HANDLE]
    synchronize = 0x00100000
    terminate = 0x0001
    signaled = 0
    waiting = 258
    python = shlex.quote(Path(sys.executable).as_posix())

    def wait_for(path, proc, deadline):
        while True:
            value = path.read_text(encoding='ascii') if path.exists() else ''
            if value:
                return value
            if proc.poll() is not None:
                out, err = proc.communicate(timeout=5)
                raise AssertionError((path, proc.returncode, out, err))
            if time.monotonic() > deadline:
                raise AssertionError((path, 'not ready'))
            time.sleep(0.02)

    for case in ('exit', 'timeout', 'cancel', 'parent killed'):
        work = cwd / ('bash ' + case)
        work.mkdir()
        (work / 'probe.py').write_text(PROBE, encoding='ascii')
        (work / 'bash.exe').touch()
        command = f'{python} probe.py branch &\n'
        if case == 'exit':
            command += 'while [ ! -f release ]; do sleep 0.05; done; printf "stdout\\n"; printf "stderr\\n" >&2; exit 7'
        else:
            command += 'wait'
        options = dict(command=command, cwd=work.name)
        if case == 'timeout':
            options['timeout_ms'] = 7000
        if case == 'cancel':
            options['background'] = True
            code = 'const {id} = await tools.bash(' + json.dumps(options) + '); '
            code += ('for (let i = 0; i < 240; i++) { '
                     'try { await tools.read({path: "bash cancel/release"}); break; } catch {} '
                     'await tools.sleep(50); } '
                     'console.log(JSON.stringify(await tools.stop({id, reason: "Verify process tree cleanup"})));')
        else:
            code = 'console.log(JSON.stringify(await tools.bash(' + json.dumps(options) + ')))'
        if case != 'parent killed':
            returned = json.dumps(work.name + '/returned')
            verified = json.dumps(work.name + '/verified')
            code += (f'; await tools.write({{path: {returned}, content: "ready"}}); '
                     'for (let i = 0; i < 240; i++) { '
                     f'try {{ await tools.read({{path: {verified}}}); break; }} catch {{}} '
                     'await tools.sleep(50); }')
        handles = []
        with subprocess.Popen([*argv, 'ask', '--json', '-'], cwd=cwd, env=env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as nib:
            try:
                nib.stdin.write(code.encode('utf-8'))
                nib.stdin.close()
                nib.stdin = None
                start_deadline = time.monotonic() + 6
                for name in ('branch.pid', 'leaf.pid'):
                    value = wait_for(work / name, nib, start_deadline)
                    handle = kernel.OpenProcess(synchronize | terminate, False, int(value))
                    assert handle, (case, name, C.get_last_error())
                    handles.append(handle)
                    assert kernel.WaitForSingleObject(handle, 0) == waiting, (case, name, 'not live')
                if case in ('exit', 'cancel'):
                    (work / 'release').touch()
                if case == 'parent killed':
                    nib.kill()
                else:
                    wait_for(work / 'returned', nib, time.monotonic() + 12)
                    assert nib.poll() is None, (case, 'nib already exited')
                for handle in handles:
                    assert kernel.WaitForSingleObject(handle, 3000) == signaled, (case, 'descendant survived')
                if case != 'parent killed':
                    (work / 'verified').touch()
                out, err = nib.communicate(timeout=15)
                if case != 'parent killed':
                    assert nib.returncode == 0, (case, out, err)
                    events = [json.loads(line) for line in out.splitlines()]
                    run = next(e['run_end'] for e in events if 'run_end' in e)
                    assert run['ok'], (case, run)
                    result = json.loads(run['output'].splitlines()[0])
                    if case == 'exit':
                        assert result['exit_code'] == 7, result
                        assert result['output'].splitlines() == ['stdout', 'stderr'], result
                    elif case == 'timeout':
                        assert result['timed_out'] and result['exit_code'] is None, result
                    else:
                        assert result['stopped'], result
                print(f'Bash Job Object cleanup: {case} passed', flush=True)
            finally:
                if nib.poll() is None:
                    nib.kill()
                for handle in handles:
                    if kernel.WaitForSingleObject(handle, 0) == waiting:
                        kernel.TerminateProcess(handle, 1)
                    kernel.CloseHandle(handle)
