"""CI matrix discovery, coverage, and duration-based sharding; Python stdlib only."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('ci_matrix', ROOT / 'scripts/ci_matrix.py')
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


def flatten(matrix):
    return [test for entry in matrix['include'] for test in entry['test'].split()]


class CiMatrixTest(unittest.TestCase):
    def test_discovery_preserves_order_and_deduplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'tests').mkdir()
            for name in ('test_b.py', 'test_a.py'):
                (root / 'tests' / name).touch()
            (root / 'AGENTS.md').write_text('tests/test_b.py tests/test_a.py tests/test_b.py')
            self.assertEqual(ci.discover_tests(root), ['tests/test_b.py', 'tests/test_a.py'])

    def test_empty_discovery_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'AGENTS.md').write_text('No tests listed')
            with self.assertRaisesRegex(ValueError, 'No e2e tests'):
                ci.discover_tests(root)

    def test_missing_test_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'AGENTS.md').write_text('tests/test_missing.py')
            with self.assertRaisesRegex(ValueError, 'Missing e2e test: tests/test_missing.py'):
                ci.discover_tests(root)

    def test_longest_first_balances_groups(self):
        seconds = {'a': 8, 'b': 7, 'c': 6, 'd': 5}
        self.assertEqual(ci.balanced_groups(list(seconds), seconds, 2), [['a', 'd'], ['b', 'c']])

    def test_unknown_duration_keeps_new_test(self):
        seconds = {'slow': 20, 'fast': 1}
        self.assertEqual(ci.balanced_groups(['fast', 'new', 'slow'], seconds, 2),
                         [['slow'], ['new', 'fast']])
        self.assertEqual(ci.DEFAULT_SECONDS, 10)

    def test_ties_are_deterministic(self):
        seconds = {'a': 10, 'b': 10, 'c': 10}
        self.assertEqual(ci.balanced_groups(['a', 'b', 'c'], seconds, 2),
                         ci.balanced_groups(['c', 'b', 'a'], seconds, 2))

    def test_small_suites_have_no_empty_groups(self):
        self.assertEqual(ci.balanced_groups(['a'], {}), [['a']])
        self.assertEqual(ci.balanced_groups([], {}), [])
        with self.assertRaisesRegex(ValueError, 'positive'):
            ci.balanced_groups(['a'], {}, 0)

    def test_platform_coverage_and_new_tests(self):
        linux_only = {'session', 'agent', 'agent_reuse', 'agent_fork', 'background_agent',
                      'background_bash', 'background_run', 'limits', 'tui_stream'}
        tests = [f'tests/test_{name}.py' for name in sorted(linux_only)]
        portable = ['tests/test_skills.py', 'tests/test_new.py']
        tests += portable
        matrices = ci.matrices(tests, {})
        self.assertEqual(flatten(matrices['linux']), tests)
        self.assertCountEqual(flatten(matrices['macos']), portable)

    def test_repository_coverage_is_exactly_once(self):
        tests = ci.discover_tests(ROOT)
        seconds = json.loads((ROOT / '.github/ci-e2e-seconds.json').read_text())
        self.assertTrue(all(value > 0 for value in seconds.values()))
        matrices = ci.matrices(tests, seconds)
        self.assertEqual(flatten(matrices['linux']), tests)
        portable = [test for test in tests if Path(test).stem.removeprefix('test_') not in ci.LINUX_ONLY]
        self.assertCountEqual(flatten(matrices['macos']), portable)
        self.assertEqual(len(matrices['macos']['include']), 4)
        for matrix in matrices.values():
            names = [entry['name'] for entry in matrix['include']]
            self.assertEqual(len(names), len(set(names)))
            self.assertTrue(all(entry['test'] for entry in matrix['include']))

    def test_recorded_estimates_improve_over_round_robin(self):
        tests = ci.discover_tests(ROOT)
        seconds = json.loads((ROOT / '.github/ci-e2e-seconds.json').read_text())
        portable = [test for test in tests if Path(test).stem.removeprefix('test_') not in ci.LINUX_ONLY]
        def longest(groups):
            return max(sum(seconds.get(test, ci.DEFAULT_SECONDS) for test in group) for group in groups)
        self.assertLess(longest(ci.balanced_groups(portable, seconds)),
                        longest([portable[index::4] for index in range(4)]))

    def test_cli_outputs_both_matrices_outside_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/ci_matrix.py')],
                                    cwd=directory, check=True, capture_output=True, text=True)
        outputs = {key: json.loads(value) for key, value in
                   (line.split('=', 1) for line in result.stdout.splitlines())}
        seconds = json.loads((ROOT / '.github/ci-e2e-seconds.json').read_text())
        self.assertEqual(outputs, ci.matrices(ci.discover_tests(ROOT), seconds))


if __name__ == '__main__':
    unittest.main(verbosity=2)
