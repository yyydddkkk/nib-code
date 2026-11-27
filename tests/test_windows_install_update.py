"""Test the native Windows installer and self-updater against local release assets."""

import argparse
from contextlib import contextmanager
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import subprocess
import tempfile
from threading import Thread
from zipfile import ZIP_DEFLATED, ZipFile

ASSET = 'nib-x86_64-windows-preview.zip'
SCRIPT = Path(__file__).resolve().parents[1] / 'install.ps1'


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


@contextmanager
def serve(root):
    with ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=root)) as server:
        loop = Thread(target=server.serve_forever, daemon=True)
        loop.start()
        try:
            yield f'http://127.0.0.1:{server.server_port}'
        finally:
            server.shutdown()
            loop.join()


def check(exe):
    def run(command, *, error=None, **overrides):
        result = subprocess.run(command, env=env | overrides, cwd=root, capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=60)
        if error is not None:
            assert result.returncode != 0 and error.lower() in result.stderr.lower(), result
        else:
            assert result.returncode == 0, result
        return result.stdout.strip()

    old = exe.read_bytes()
    env = {key: val for key, val in os.environ.items() if not key.upper().startswith('NIB_')}
    env.update(HTTP_PROXY='', HTTPS_PROXY='', ALL_PROXY='', NO_PROXY='127.0.0.1')
    with tempfile.TemporaryDirectory(prefix='nib update 测试 ') as temp:
        root = Path(temp)
        installed = root / 'install here'
        target = installed / 'nib.exe'
        previous = installed / 'nib.exe.previous'
        assets = root / 'release assets'
        assets.mkdir()
        ver = run([exe, '--version']).removeprefix('nib ')
        assert re.fullmatch(r'\d+\.\d+\.\d+', ver), ver
        env.update(NIB_INSTALL_DIR=str(installed), NIB_VERSION='v' + ver, NIB_DOWNLOAD_BASE=assets.as_uri())
        install = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT]
        update = [target, 'update', 'v' + ver]

        def zip_binary(binary, name='nib.exe', extra=False):
            with ZipFile(assets / ASSET, 'w', ZIP_DEFLATED) as zip:
                zip.writestr(name, binary)
                if extra:
                    zip.writestr('extra.txt', 'not a release asset')
            checksum(hashlib.sha256((assets / ASSET).read_bytes()).hexdigest())

        def checksum(hash):
            (assets / 'SHA256SUMS').write_text(f'{hash}  {ASSET}\n', encoding='ascii')

        zip_binary(old)
        assert run(install).startswith(f'nib {ver} installed at ')
        assert target.read_bytes() == old
        assert run([target, '--version']) == f'nib {ver}'

        first = old + b'test update one'
        zip_binary(first)
        checksum('0' * 64)
        run(install, error='Checksum mismatch')
        run(update, error='ChecksumMismatch')
        assert target.read_bytes() == old and not previous.exists()
        assert list(installed.iterdir()) == [target]

        zip_binary(first, name='../nib.exe')
        run(install, error='Invalid archive')
        run(update, error='InvalidArchive')
        zip_binary(first, extra=True)
        run(install, error='Invalid archive')
        run(update, error='InvalidArchive')
        assert target.read_bytes() == old and not previous.exists()
        assert list(installed.iterdir()) == [target]

        zip_binary(first)
        assert run(update) == f'nib {ver} is installed'
        assert target.read_bytes() == first and previous.read_bytes() == old
        assert run([target, '--version']) == f'nib {ver}'
        assert not list(installed.glob('.nib-update-*'))

        second = old + b'test update two'
        zip_binary(second)
        with serve(assets) as base:
            assert run(update, NIB_DOWNLOAD_BASE=base) == f'nib {ver} is installed'
            assert target.read_bytes() == second and previous.read_bytes() == first
            zip_binary(old)
            assert run(['pwsh.exe', *install[1:]], NIB_DOWNLOAD_BASE=base).startswith(f'nib {ver} installed at ')
        assert target.read_bytes() == old
        assert run([target, '--version']) == f'nib {ver}'
        assert set(installed.iterdir()) == {target, previous}
    print('Windows install/update: both PowerShell editions, checksums, malformed ZIPs, repeat update and HTTP passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('exe', type=Path)
    check(parser.parse_args().exe.resolve(strict=True))
