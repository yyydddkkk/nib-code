"""Exercise the release fast path against committed Git trees."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CLASSIFIER = Path(__file__).resolve().parents[1] / 'scripts/ci_release_metadata.py'


class ReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.repo = Path(temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'CI Test')
        self.git('config', 'user.email', 'ci@example.test')
        self.release('1.0.0')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, env=self.env, text=True).strip()

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def release(self, version='1.0.1', *, note_path=None, note=None, dependency='old-hash'):
        (self.repo / 'build.zig.zon').write_text(
            f'.{{\n    .version = "{version}",\n    .dependencies = .{{ .dep = "{dependency}" }},\n}}\n')
        path = self.repo / 'docs/releases' / (note_path or f'{version}.md')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(note if note is not None else
                        f'# nib {version}\n\nNotes.\n\n---\n\n# nib {version}（中文）\n\n发行说明。\n',
                        encoding='utf-8')
        return path

    def classify(self, *refs):
        return subprocess.run([sys.executable, CLASSIFIER, *refs], cwd=self.repo, env=self.env,
                              capture_output=True, text=True, check=False)

    def assert_mode(self, mode, *refs):
        result = self.classify(*refs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), mode)

    def assert_invalid(self, message, *refs):
        result = self.classify(*refs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertNotIn('metadata', result.stdout)

    def test_version_and_matching_bilingual_note(self):
        self.release()
        self.assert_mode('metadata', self.base, self.commit())

    def test_current_version_notes_only_and_empty_diff_use_full(self):
        self.release('1.0.0', note='Reworded notes.')
        self.assert_mode('full', self.base, self.commit())
        self.assert_mode('full', self.base, self.base)

    def test_mixed_change_uses_full_even_with_newline_in_filename(self):
        self.release()
        (self.repo / 'unknown\nchange').touch()
        self.assert_mode('full', self.base, self.commit())

    def test_dependency_change_uses_full_even_with_version_and_notes(self):
        self.release(dependency='new-hash')
        self.assert_mode('full', self.base, self.commit())

    def test_manifest_mode_change_uses_full(self):
        self.release()
        (self.repo / 'build.zig.zon').chmod(0o755)
        self.assert_mode('full', self.base, self.commit())

    def test_unknown_manifest_edit_uses_full(self):
        self.release()
        with (self.repo / 'build.zig.zon').open('a') as manifest:
            manifest.write('// trailing comment\n')
        self.assert_mode('full', self.base, self.commit())

    def test_invalid_version_syntax_blocks_fast_path(self):
        self.release('1.01.1')
        self.assert_invalid('stable X.Y.Z', self.base, self.commit())

    def test_absent_matching_note_blocks_fast_path(self):
        self.release().unlink()
        self.assert_invalid('expected a change to docs/releases/1.0.1.md', self.base, self.commit())

    def test_wrong_note_path_blocks_fast_path(self):
        self.release(note_path='1.0.2.md')
        self.assert_invalid('expected a change to docs/releases/1.0.1.md', self.base, self.commit())

    def test_wrong_heading_blocks_fast_path(self):
        note = self.release()
        note.write_text(note.read_text(encoding='utf-8').replace('1.0.1（中文）', '1.0.2（中文）'),
                        encoding='utf-8')
        self.assert_invalid('heading', self.base, self.commit())

    def test_empty_chinese_body_blocks_fast_path(self):
        self.release(note='# nib 1.0.1\n\nNotes.\n---\n# nib 1.0.1（中文）\n')
        self.assert_invalid('nonempty body', self.base, self.commit())

    def test_symlink_note_blocks_fast_path(self):
        note = self.release()
        note.unlink()
        note.symlink_to('1.0.0.md')
        self.assert_invalid('regular, non-executable', self.base, self.commit())

    def test_missing_history_fails_closed(self):
        self.assert_mode('full', 'missing-base', self.base)
        self.assert_mode('full', self.base, 'missing-head')

    def test_pr_compares_merge_base_and_pinned_merge_snapshot(self):
        self.git('switch', '-qc', 'release')
        self.release()
        head = self.commit()
        self.git('switch', '-q', 'main')
        (self.repo / 'new-on-base').touch()
        advanced_base = self.commit()
        self.git('merge', '--no-ff', '--no-edit', 'release')
        merge = self.git('rev-parse', 'HEAD')
        self.assert_mode('metadata', advanced_base, head, merge)
        self.assert_mode('full', self.base, head, merge)  # Stale base SHA.

        (self.repo / 'unexpected-integration-change').touch()
        self.git('add', '-A')
        self.git('commit', '--amend', '--no-edit')
        self.assert_mode('full', advanced_base, head, 'HEAD')

    def test_pr_with_mixed_authored_diff_uses_full_even_if_base_already_has_app_change(self):
        self.git('switch', '-qc', 'mixed')
        self.release()
        (self.repo / 'app').touch()
        head = self.commit()
        self.git('switch', '-q', 'main')
        (self.repo / 'app').touch()
        advanced_base = self.commit()
        self.git('merge', '--no-ff', '--no-edit', 'mixed')
        self.assert_mode('metadata', advanced_base, 'HEAD')
        self.assert_mode('full', advanced_base, head, 'HEAD')


if __name__ == '__main__':
    unittest.main(verbosity=2)
