"""Discover CI coverage and balance portable tests using recorded duration estimates."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SECONDS = 10
# These tests use Linux process fixtures or Linux-calibrated PTY latency limits.
LINUX_ONLY = frozenset({
    'session', 'agent', 'agent_reuse', 'agent_fork', 'background_agent',
    'background_bash', 'background_run', 'limits', 'tui_stream',
})


def discover_tests(root):
    tests = list(dict.fromkeys(re.findall(r'tests/test_\w+\.py', (root / 'AGENTS.md').read_text())))
    if not tests:
        raise ValueError('No e2e tests found in AGENTS.md')
    for test in tests:
        if not (root / test).is_file():
            raise ValueError(f'Missing e2e test: {test}')
    return tests


def balanced_groups(tests, seconds, count=4):
    if count < 1:
        raise ValueError('Group count must be positive')
    groups = [[] for _ in range(count)]
    totals = [0] * count
    for test in sorted(tests, key=lambda test: (-seconds.get(test, DEFAULT_SECONDS), test)):
        index = min(range(count), key=lambda index: totals[index])
        groups[index].append(test)
        totals[index] += seconds.get(test, DEFAULT_SECONDS)
    return [group for group in groups if group]


def matrices(tests, seconds):
    portable = [test for test in tests if Path(test).stem.removeprefix('test_') not in LINUX_ONLY]
    return {
        'linux': {'include': [{'test': test, 'name': Path(test).stem} for test in tests]},
        'macos': {'include': [
            {'test': ' '.join(group), 'name': f'group-{index}'}
            for index, group in enumerate(balanced_groups(portable, seconds))
        ]},
    }


def main():
    tests = discover_tests(ROOT)
    seconds = json.loads((ROOT / '.github/ci-e2e-seconds.json').read_text())
    for platform, matrix in matrices(tests, seconds).items():
        print(f'{platform}={json.dumps(matrix, separators=(",", ":"))}')


if __name__ == '__main__':
    main()
