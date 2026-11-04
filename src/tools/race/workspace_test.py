import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import fcntl

if len(sys.argv) > 1:
    import types
    ws = types.ModuleType('workspace')
    exec(sys.argv.pop(1), ws.__dict__)
else:
    spec = importlib.util.spec_from_file_location('workspace', Path(__file__).with_name('workspace.py'))
    ws = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ws)


class WorkspaceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@localhost')
        (self.root / 'file').write_text('one\ntwo\nthree\nfour\nfive\n')
        (self.root / '.gitignore').write_text('ignored\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.home = Path(self.tmp.name) / 'nib' / 'races' / 'race-test'
        self.home.mkdir(parents=True)
        self.lock = open(self.home / 'owner.lock', 'w+b')
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.lock.write(b'nib-race-1\n')
        self.lock.flush()
        self.addCleanup(self.lock.close)

    def git(self, *args):
        return ws.git(self.root, *args)

    def create(self):
        return ws.create(self.home, self.root)

    def branch(self, index=0):
        return Path(ws.branch(self.home, index)['path'])

    def test_dirty_snapshot_and_index_preserved(self):
        (self.root / 'file').write_text('staged\n')
        self.git('add', 'file')
        (self.root / 'file').write_text('unstaged\n')
        (self.root / 'new').write_bytes(b'\0raw\xff')
        (self.root / 'ignored').write_text('ignored')
        self.git('add', '-f', 'ignored')
        (self.root / 'ignored').write_text('dirty ignored tracked')
        (self.root / 'folder').mkdir()
        (self.root / 'folder' / 'file').write_text('untracked')
        refs = self.git('show-ref')
        index = (self.root / '.git' / 'index').read_bytes()
        self.create()
        branch = self.branch()
        self.assertEqual((branch / 'file').read_text(), 'unstaged\n')
        self.assertEqual((branch / 'new').read_bytes(), b'\0raw\xff')
        self.assertEqual((branch / 'ignored').read_text(), 'dirty ignored tracked')
        self.assertEqual((branch / 'folder' / 'file').read_text(), 'untracked')
        self.assertEqual((self.root / '.git' / 'index').read_bytes(), index)
        self.assertEqual(self.git('show-ref'), refs)
        self.assertEqual(self.git('status', '--porcelain'), b'MM file\nAM ignored\n?? folder/\n?? new\n')

    def test_binary_deletion_executable_and_parent_index(self):
        old = (self.root / '.git' / 'index').read_bytes()
        self.create()
        branch = self.branch()
        (branch / 'file').unlink()
        (branch / 'binary').write_bytes(bytes(range(256)))
        (branch / 'nested').mkdir()
        (branch / 'nested' / 'script').write_text('#!/bin/sh\n')
        (branch / 'nested' / 'script').chmod(0o755)
        result = ws.apply(self.home, branch)
        self.assertTrue(result['ok'], result)
        self.assertFalse((self.root / 'file').exists())
        self.assertEqual((self.root / 'binary').read_bytes(), bytes(range(256)))
        self.assertEqual((self.root / 'nested' / 'script').stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.root / '.git' / 'index').read_bytes(), old)
        self.assertEqual(len(result['edits']), 3)
        ws.clean(self.home)
        self.assertFalse(self.home.exists())
        self.assertEqual(len(self.git('worktree', 'list', '--porcelain').split(b'worktree ')), 2)

    def test_three_way_preserves_nonoverlapping_parent_changes(self):
        self.create()
        branch = self.branch()
        (branch / 'file').write_text('winner\ntwo\nthree\nfour\nfive\n')
        (self.root / 'file').write_text('one\ntwo\nthree\nfour\nparent\n')
        (self.root / 'unrelated').write_text('keep')
        result = ws.apply(self.home, branch)
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / 'file').read_text(), 'winner\ntwo\nthree\nfour\nparent\n')
        self.assertEqual((self.root / 'unrelated').read_text(), 'keep')

    def test_conflict_keeps_parent_and_saves_binary_patch_outside_workspace(self):
        self.create()
        branch = self.branch()
        (branch / 'file').write_text('winner\n')
        (branch / 'binary').write_bytes(b'\0winner')
        (self.root / 'file').write_text('parent\n')
        before = (self.root / '.git' / 'index').read_bytes()
        result = ws.apply(self.home, branch)
        self.assertFalse(result['ok'])
        patch = Path(result['patch'])
        self.assertIn(b'GIT binary patch', patch.read_bytes())
        self.assertEqual((self.root / 'file').read_text(), 'parent\n')
        self.assertFalse((self.root / 'binary').exists())
        self.assertEqual((self.root / '.git' / 'index').read_bytes(), before)
        ws.clean(self.home)
        self.assertTrue(patch.exists())

    def test_private_commits_do_not_use_user_signing_configuration(self):
        self.git('config', 'commit.gpgsign', 'true')
        self.git('config', 'gpg.program', '/nonexistent-nib-test-signer')
        self.create()
        branch = self.branch()
        (branch / 'file').write_text('winner\n')
        result = ws.apply(self.home, branch)
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / 'file').read_text(), 'winner\n')

    def test_external_merge_driver_never_runs_in_parent(self):
        marker = Path(self.tmp.name) / 'merge-driver-ran'
        (self.root / '.gitattributes').write_text('file merge=external\n')
        self.git('add', '.gitattributes')
        self.git('commit', '-qm', 'attributes')
        self.git('config', 'merge.external.driver', 'touch ' + str(marker) + '; exit 0')
        self.create()
        branch = self.branch()
        (branch / 'file').write_text('winner\n')
        (self.root / 'file').write_text('parent\n')
        result = ws.apply(self.home, branch)
        self.assertFalse(result['ok'], result)
        self.assertFalse(marker.exists())
        self.assertEqual((self.root / 'file').read_text(), 'parent\n')
        self.assertTrue(Path(result['patch']).exists())

    def test_ignored_collision_not_overwritten(self):
        self.create()
        branch = self.branch()
        (branch / '.gitignore').write_text('')
        (branch / 'ignored').write_text('winner')
        (self.root / 'ignored').write_text('parent ignored')
        result = ws.apply(self.home, branch)
        self.assertFalse(result['ok'])
        self.assertEqual((self.root / 'ignored').read_text(), 'parent ignored')
        self.assertEqual((self.root / '.gitignore').read_text(), 'ignored\n')

    def test_transaction_rolls_back_all_files_and_new_directories(self):
        self.create()
        branch = self.branch()
        (branch / 'aaa').mkdir()
        (branch / 'aaa' / 'new').write_text('new')
        (branch / 'file').write_text('winner')
        write = ws.atomic_write
        calls = []
        def fail_second(path, data, mode):
            calls.append(path)
            if len(calls) >= 2:
                raise OSError('injected write failure')
            return write(path, data, mode)
        with mock.patch.object(ws, 'atomic_write', fail_second):
            result = ws.apply(self.home, branch)
        self.assertFalse(result['ok'])
        self.assertFalse((self.root / 'aaa').exists())
        self.assertEqual((self.root / 'file').read_text(), 'one\ntwo\nthree\nfour\nfive\n')

    def test_concurrent_parent_change_rejected_before_any_write(self):
        self.create()
        branch = self.branch()
        (branch / 'file').write_text('winner')
        fingerprint = ws.fingerprint
        def concurrent(root):
            (self.root / 'concurrent').write_text('new')
            return fingerprint(root)
        with mock.patch.object(ws, 'fingerprint', concurrent):
            result = ws.apply(self.home, branch)
        self.assertFalse(result['ok'])
        self.assertEqual((self.root / 'file').read_text(), 'one\ntwo\nthree\nfour\nfive\n')

    def test_live_lock_and_dead_residual_cleanup(self):
        self.create()
        branch = self.branch()
        ws.reap(self.home.parent)
        self.assertTrue(branch.exists())
        self.lock.close()
        ws.reap(self.home.parent)
        self.assertFalse(self.home.exists())
        self.assertNotIn(str(branch).encode(), self.git('worktree', 'list', '--porcelain'))

    def test_filters_and_autocrlf_do_not_transform_snapshot(self):
        (self.root / '.gitattributes').write_text('* text eol=crlf\n')
        self.git('config', 'core.autocrlf', 'true')
        (self.root / 'file').write_bytes(b'raw\r\nbytes\n')
        self.create()
        branch = self.branch()
        self.assertEqual((branch / 'file').read_bytes(), b'raw\r\nbytes\n')
        (branch / 'file').write_bytes(b'changed\r\nraw\n')
        result = ws.apply(self.home, branch)
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / 'file').read_bytes(), b'changed\r\nraw\n')

    def test_reject_symlinks_nested_repositories_and_sparse_checkout(self):
        (self.root / 'link').symlink_to('file')
        with self.assertRaises(ws.Refused):
            self.create()
        (self.root / 'link').unlink()
        nested = self.root / 'nested'
        nested.mkdir()
        ws.git(nested, 'init', '-q')
        with self.assertRaises(ws.Refused):
            self.create()
        import shutil
        shutil.rmtree(nested)
        self.git('config', 'core.sparseCheckout', 'true')
        with self.assertRaisesRegex(ws.Refused, 'sparse'):
            self.create()

    def test_stale_cleanup_through_symlink_home_and_unowned_directories(self):
        self.create()
        branch = self.branch()
        alias = Path(self.tmp.name) / 'alias'
        alias.symlink_to(self.home.parent, target_is_directory=True)
        unowned = self.home.parent / 'race-unowned'
        unowned.mkdir()
        (unowned / 'owner.lock').write_text('not nib')
        self.lock.close()
        ws.reap(alias)
        self.assertFalse(self.home.exists())
        self.assertTrue(unowned.exists())
        self.assertNotIn(str(branch).encode(), self.git('worktree', 'list', '--porcelain'))

    def test_deleted_parent_repository_does_not_leak_residuals(self):
        self.create()
        self.branch()
        import shutil
        shutil.rmtree(self.root)
        self.lock.close()
        ws.reap(self.home.parent)
        self.assertFalse(self.home.exists())

    def test_missing_owner_metadata_cleanup_requires_marker(self):
        self.lock.close()
        ws.reap(self.home.parent)
        self.assertFalse(self.home.exists())

    def test_raw_path_names_deleted_dirty_file_and_ignored_untracked(self):
        (self.root / 'file').unlink()
        (self.root / 'ignored').write_bytes(b'not captured')
        odd = 'unicodé space\ttab\nnewline'
        (self.root / odd).write_bytes(b'raw')
        self.create()
        branch = self.branch()
        self.assertFalse((branch / 'file').exists())
        self.assertFalse((branch / 'ignored').exists())
        self.assertEqual((branch / odd).read_bytes(), b'raw')
        (branch / odd).write_bytes(b'changed')
        result = ws.apply(self.home, branch)
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / odd).read_bytes(), b'changed')
        self.assertFalse((self.root / 'file').exists())
        self.assertEqual((self.root / 'ignored').read_bytes(), b'not captured')

    def test_deletion_restored_when_later_write_fails(self):
        self.create()
        branch = self.branch()
        (branch / 'file').unlink()
        (branch / 'zzz').write_text('new')
        with mock.patch.object(ws, 'atomic_write', side_effect=OSError('persistent write failure')):
            result = ws.apply(self.home, branch)
        self.assertFalse(result['ok'])
        self.assertEqual((self.root / 'file').read_text(), 'one\ntwo\nthree\nfour\nfive\n')
        self.assertFalse((self.root / 'zzz').exists())
        self.assertFalse(list(self.root.glob('.nib-race-*')))

    def test_reject_nonrepo_unborn_submodule_and_unmerged_index(self):
        empty = Path(self.tmp.name) / 'empty'
        empty.mkdir()
        with self.assertRaises(ws.Refused):
            ws.create(self.home, empty)
        ws.git(empty, 'init', '-q')
        with self.assertRaises(ws.Refused):
            ws.create(self.home, empty)
        oid = self.git('rev-parse', 'HEAD').strip().decode()
        self.git('update-index', '--add', '--cacheinfo', '160000,' + oid + ',submodule')
        with self.assertRaisesRegex(ws.Refused, 'submodule'):
            self.create()
        self.git('update-index', '--force-remove', 'submodule')
        blob = self.git('rev-parse', 'HEAD:file').strip()
        ws.git(self.root, 'update-index', '--index-info', data=b'100644 ' + blob + b' 1\tconflict\n')
        with self.assertRaisesRegex(ws.Refused, 'unmerged'):
            self.create()

    def test_repository_root_with_trailing_whitespace(self):
        renamed = self.root.with_name('repo \n')
        self.root.rename(renamed)
        self.root = renamed
        info = self.create()
        self.assertEqual(info['root'], str(renamed))
        branch = self.branch()
        (branch / 'file').write_text('changed')
        result = ws.apply(self.home, branch)
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / 'file').read_text(), 'changed')

    def test_empty_parent_subdirectory_is_preserved(self):
        sub = self.root / 'empty' / 'sub'
        sub.mkdir(parents=True)
        ws.create(self.home, sub)
        self.assertTrue((self.branch() / 'empty' / 'sub').is_dir())

    def test_parent_subdirectory_and_linked_worktree(self):
        linked = Path(self.tmp.name) / 'linked'
        self.git('worktree', 'add', '--detach', str(linked), 'HEAD')
        (linked / 'sub').mkdir()
        (linked / 'sub' / 'untracked').write_text('dirty')
        info = ws.create(self.home, linked / 'sub')
        self.assertEqual(info['root'], str(linked))
        self.assertEqual(info['cwd'], str(linked / 'sub'))
        branch = self.branch()
        self.assertEqual((branch / 'sub' / 'untracked').read_text(), 'dirty')


if __name__ == '__main__':
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout))
