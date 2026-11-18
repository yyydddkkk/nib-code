"""Verify source selection and atomic publication without compiling nib."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'scripts/dev-install.sh'
BUILDER = '''#!/usr/bin/env bash
set -euo pipefail
[[ $1 == build && $3 == --cache-dir && $5 == --prefix ]]
[[ ! -e untracked ]]   # Must not copy any real checkout.
[[ -z $(git status --porcelain) ]]
if [[ -n ${MOVE_DEV_TO:-} ]]; then
    git -C "$SOURCE_REPO" update-ref refs/heads/dev "$MOVE_DEV_TO"
fi
if [[ ${MOCK_FAIL:-} == build ]]; then exit 21; fi
mkdir -p "$6/bin"
if [[ ${MOCK_FAIL:-} == validate ]]; then
    printf '#!/bin/sh\\nexit 22\\n' > "$6/bin/nib"
else
    printf '#!/bin/sh\\nprintf "nib %%s\\\\n" "%s:%s:%s"\\n' "$(cat identity)" \
        "$(git rev-parse HEAD)" "${2#-Doptimize=}" > "$6/bin/nib"
fi
'''


class DevInstallTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='dev install test ')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.main = self.root / 'repo'
        self.dev = self.root / 'integration'
        self.feature = self.root / 'feature'
        self.home = self.root / 'home'
        self.bin = self.home / '.local/bin'
        self.tmp = self.root / 'tmp'
        self.mocks = self.root / 'mocks'
        for directory in (self.main, self.bin, self.tmp, self.mocks):
            directory.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.tmp),
                        PATH=f'{self.mocks}{os.pathsep}{os.environ["PATH"]}',
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        self.mock('zig', BUILDER)
        self.git(self.main, 'init', '-q', '-b', 'main')
        self.git(self.main, 'config', 'user.name', 'Installer Test')
        self.git(self.main, 'config', 'user.email', 'installer@example.test')
        (self.main / 'scripts').mkdir()
        shutil.copy2(INSTALLER, self.main / 'scripts')
        (self.main / 'identity').write_text('committed main')
        self.main_commit = self.record(self.main)
        self.git(self.main, 'worktree', 'add', '-qb', 'dev', str(self.dev))
        (self.dev / 'identity').write_text('committed dev')
        self.dev_commit = self.record(self.dev)
        self.git(self.main, 'worktree', 'add', '-qb', 'feature', str(self.feature))
        (self.feature / 'identity').write_text('committed feature')
        self.feature_commit = self.record(self.feature)
        self.git(self.feature, 'update-ref', 'refs/remotes/origin/dev', self.feature_commit)
        (self.bin / 'nib').write_bytes(b'stable binary')
        # A temp-looking directory owned by another session must survive.
        self.other_temp = self.tmp / 'nib-dev.other-session'
        self.other_temp.mkdir()

    def mock(self, name, content):
        path = self.mocks / name
        path.write_text(content)
        path.chmod(0o755)

    def git(self, cwd, *args):
        return subprocess.check_output(['git', *args], cwd=cwd, env=self.env, text=True).strip()

    def record(self, cwd):
        self.git(cwd, 'add', '-A')
        self.git(cwd, 'commit', '-qm', 'fixture')
        return self.git(cwd, 'rev-parse', 'HEAD')

    def install(self, *args, env=None, cwd=None):
        return subprocess.run([self.feature / 'scripts/dev-install.sh', *args], cwd=cwd or self.root,
                              env=env or self.env, capture_output=True, text=True, timeout=15)

    def assert_clean(self, bin_dir=None):
        self.assertEqual(list(self.tmp.iterdir()), [self.other_temp])
        self.assertEqual(list((bin_dir or self.bin).glob('.nib-dev.*')), [])
        self.assertEqual((self.bin / 'nib').read_bytes(), b'stable binary')

    def assert_installed(self, directory, mode):
        actual = subprocess.check_output([directory / 'nib-dev', '--version'], text=True).strip()
        self.assertEqual(actual, f'nib committed dev:{self.dev_commit}:{mode}')

    def test_feature_invocation_uses_local_dev_not_main_dirty_checkouts_or_origin(self):
        checkouts = (self.main, self.dev, self.feature)
        for checkout in checkouts:
            (checkout / 'identity').write_text('uncommitted ' + checkout.name)
            (checkout / 'untracked').touch()
        before = [self.git(p, 'status', '--porcelain=v1') for p in checkouts]
        worktrees = self.git(self.feature, 'worktree', 'list', '--porcelain')
        # The working directory and inherited Git environment do not select the source.
        result = self.install(cwd=self.feature, env=dict(self.env, GIT_DIR=str(self.root / 'wrong')))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'Source: local dev ({self.dev_commit})', result.stdout)
        self.assertIn('Build:  Debug', result.stdout)
        self.assertIn(f'Target: {self.bin}/nib-dev', result.stdout)
        self.assert_installed(self.bin, 'Debug')
        self.assertEqual(self.git(self.feature, 'worktree', 'list', '--porcelain'), worktrees)
        self.assertEqual(self.git(self.feature, 'rev-parse', 'refs/heads/dev'), self.dev_commit)
        self.assertEqual(self.git(self.feature, 'rev-parse', 'refs/heads/main'), self.main_commit)
        self.assertEqual(self.git(self.feature, 'rev-parse', 'refs/remotes/origin/dev'), self.feature_commit)
        for checkout, status in zip(checkouts, before):
            self.assertEqual(self.git(checkout, 'status', '--porcelain=v1'), status)
            self.assertEqual((checkout / 'identity').read_text(), 'uncommitted ' + checkout.name)
        self.assert_clean()

    def test_dev_not_checked_out_and_moves_during_release_fast_build(self):
        self.git(self.dev, 'switch', '-q', '--detach')
        other_bin = self.root / 'other bin'
        env = dict(self.env, SOURCE_REPO=str(self.main), MOVE_DEV_TO=self.feature_commit)
        result = self.install('--release-fast', '--bin-dir', 'other bin', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.main, 'rev-parse', 'dev'), self.feature_commit)
        self.assert_installed(other_bin, 'ReleaseFast')
        self.assertFalse((self.bin / 'nib-dev').exists())
        self.assert_clean(other_bin)

    def test_missing_local_dev_does_not_fall_back_to_main_or_origin(self):
        self.git(self.dev, 'switch', '-q', '--detach')
        self.git(self.main, 'branch', '-D', 'dev')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cannot resolve local refs/heads/dev', result.stderr)
        self.assertFalse((self.bin / 'nib-dev').exists())
        self.assert_clean()

    def test_failed_build_or_validation_preserves_previous_file(self):
        previous = self.bin / 'nib-dev'
        previous.write_bytes(b'previous binary')
        previous.chmod(0o755)
        worktrees = self.git(self.feature, 'worktree', 'list', '--porcelain')
        for failure in ('build', 'validate'):
            with self.subTest(failure=failure):
                result = self.install(env=dict(self.env, MOCK_FAIL=failure))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(previous.read_bytes(), b'previous binary')
                self.assertTrue(os.access(previous, os.X_OK))
                self.assertEqual(self.git(self.feature, 'worktree', 'list', '--porcelain'), worktrees)
                self.assert_clean()

    def test_copy_failure_and_interruption_preserve_previous_file(self):
        previous = self.bin / 'nib-dev'
        previous.write_bytes(b'previous binary')
        for interrupt in ('no', 'yes'):
            with self.subTest(interrupt=interrupt):
                self.mock('cp', '#!/bin/sh\nprintf partial > "$3"\n'
                                'if [ "$INTERRUPT" = yes ]; then kill -TERM "$PPID"; exit 0; fi\nexit 23\n')
                result = self.install(env=dict(self.env, INTERRUPT=interrupt))
                self.assertEqual(result.returncode, 143 if interrupt == 'yes' else 23, result.stderr)
                self.assertEqual(previous.read_bytes(), b'previous binary')
                self.assert_clean()

    def test_rename_failure_preserves_destination_directory(self):
        occupied = self.bin / 'nib-dev'
        occupied.mkdir()
        (occupied / 'keep').touch()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(occupied.iterdir()), [occupied / 'keep'])
        self.assert_clean()

    def test_concurrent_installs_replace_link_and_leave_stable_file_alone(self):
        (self.bin / 'nib-dev').symlink_to('nib')
        script = self.feature / 'scripts/dev-install.sh'
        with subprocess.Popen([script], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as first:
            second = self.install('--release-fast')
            _, error = first.communicate(timeout=15)
        self.assertEqual(first.returncode, 0, error)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertFalse((self.bin / 'nib-dev').is_symlink())
        actual = subprocess.check_output([self.bin / 'nib-dev', '--version'], text=True).strip()
        self.assertIn(actual, {f'nib committed dev:{self.dev_commit}:{mode}' for mode in ('Debug', 'ReleaseFast')})
        self.assert_clean()


if __name__ == '__main__':
    unittest.main(verbosity=2)
