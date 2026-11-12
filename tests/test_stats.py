"""Synthetic/corrupt/legacy log coverage; mock sessions live in test_session.py."""
from datetime import date, datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('stats', ROOT / 'scripts/stats.py')
stats = importlib.util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(stats)


def synthetic_log(path, turns, **metadata):
    records = [dict({'from': 0}, cwd=str(path.parent), messages=[dict(role='system', content='base')], **metadata)]
    length = 1
    for steps in turns:
        if not steps:
            records.append(dict({'from': length}, messages=[dict(role='user', content='empty')]))
            length += 1
        for index, codes in enumerate(steps):
            messages = [dict(role='user', content='request')] if index == 0 else []
            if codes is None:
                messages.append(dict(role='assistant', content='done'))
                calls = []
            else:
                codes = codes if isinstance(codes, list) else [codes]
                calls = [dict(id=f'r{length}_{i}', function=dict(name='run', arguments=json.dumps(dict(code=code))))
                         for i, code in enumerate(codes)]
                messages.append(dict(role='assistant', tool_calls=calls))
                messages.extend(dict(role='tool', tool_call_id=call['id'], content='ok') for call in calls)
            records.append(dict({'from': length}, messages=messages, ms=10, model_ms=6,
                                usage=dict(prompt_tokens=10, completion_tokens=2, prompt_cache_hit_tokens=4),
                                run_results=[dict(tool_call_id=call['id'], ok=True) for call in calls]))
            length += len(messages)
    path.write_text('\n'.join(map(json.dumps, records)) + '\n')
    return records


def mechanical_metric(count, samples, *, ms=None, sample_ms=None, timed_count=None,
                      timed_samples=None, sources=None, hit_sources=None):
    ms = count * 10 if ms is None else ms
    sample_ms = samples * 10 if sample_ms is None else sample_ms
    return dict(count=count, samples=samples, ratio=count / samples if samples else None,
                ms=ms, sample_ms=sample_ms, time_ratio=ms / sample_ms if sample_ms else None,
                timed_count=count if timed_count is None else timed_count,
                timed_samples=samples if timed_samples is None else timed_samples,
                sources=sources if sources is not None else dict(recorded=0, static=samples, mixed=0),
                hit_sources=hit_sources if hit_sources is not None else dict(recorded=0, static=count, mixed=0))


class StatsTest(unittest.TestCase):
    def test_bash_lifecycle_does_not_replace_history_and_counts_supersession(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'root.jsonl'
            rows = synthetic_log(path, [[None]])
            expected = stats.summarize([path])
            rows[1:1] = [dict(at=100 + i, bash=dict(id='b1', run=1, state=state, **extra))
                         for i, (state, extra) in enumerate([
                             ('started', dict(command='anything', cwd='/a')),
                             ('superseded', dict(superseded_by='b2', elapsed_ms=12)),
                             ('finished', dict(elapsed_ms=15))])]
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            actual = stats.summarize([path])
            self.assertEqual(actual['bash_superseded'], 1)
            self.assertEqual(actual['overall'], expected['overall'])
            self.assertIn('Bash supersessions: 1', stats.text_report(actual))


    def test_child_costs_parent_system_groups_and_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            paths = []
            for name, sha, steps in [('before', 'old', 2), ('after', 'new', 3)]:
                parent = directory / (name + '.jsonl')
                synthetic_log(parent, [[None]], system_sha=sha)
                child = directory / (name + '-child.jsonl')
                synthetic_log(child, [['tools.read({path: \"a\"})'] * (steps - 1) + [None]],
                              parent_session_id=name, system_sha='same-child-system')
                paths.extend([parent, child])
            report = stats.summarize(sorted(paths), group_by='system')
            costs = report['child_costs']
            self.assertEqual(costs['sessions'], 2)
            self.assertEqual(costs['full_range_sessions'], 2)
            self.assertEqual(costs['steps'], dict(samples=2, median=2.5, p90=3))
            self.assertEqual(costs['model_ms'], dict(samples=2, median=15, p90=18))
            self.assertEqual(costs['prompt_tokens'], dict(samples=2, median=25, p90=30))
            self.assertEqual(costs['uncached_prompt_tokens'], dict(samples=2, median=15, p90=18))
            self.assertEqual(set(costs['by_parent_system']), {'old', 'new'})
            self.assertEqual(costs['by_parent_system']['old']['prompt_tokens']['median'], 20)
            self.assertEqual(costs['by_parent_system']['new']['prompt_tokens']['median'], 30)
            self.assertEqual(costs['by_parent_system']['old']['uncached_prompt_tokens']['median'], 12)
            self.assertEqual(costs['by_parent_system']['new']['uncached_prompt_tokens']['median'], 18)
            self.assertEqual(report['groups']['same-child-system']['child_costs'], costs)
            orphan = stats.summarize([paths[1]])['child_costs']
            self.assertEqual(set(orphan['by_parent_system']), {'unknown'})
            cli = [sys.executable, str(ROOT / 'scripts/stats.py'), str(directory), '--group-by', 'system']
            self.assertEqual(json.loads(subprocess.check_output(cli + ['--json'])), report)
            text = subprocess.check_output(cli).decode()
            self.assertIn('Recorded child-session costs', text)
            self.assertIn('parent_system=old', text)
            self.assertIn('parent_system=new', text)
            self.assertIn('uncached_prompt_tokens: samples=2 median=15.00 p90=18.00', text)

    def test_child_costs_missing_invalid_zero_and_interrupted(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            paths = []
            for name, steps in [('missing', 2), ('invalid', 1), ('zero', 1), ('interrupted', 1), ('empty', 0)]:
                path = directory / (name + '.jsonl')
                rows = synthetic_log(path, [[None] * steps], parent_session_id='missing-parent')
                if name == 'missing':
                    rows[1].pop('model_ms')
                    rows[2]['usage'].pop('prompt_tokens')
                elif name == 'invalid':
                    rows[1]['model_ms'] = True
                    rows[1]['usage']['prompt_tokens'] = -1
                elif name == 'zero':
                    rows[1]['model_ms'] = 0
                    rows[1]['usage'] = dict(prompt_tokens=0)
                elif name == 'interrupted':
                    rows[1]['calls'] = [dict(name='llm', usage=dict(prompt_tokens=999999))]
                    rows.append(dict({'from': rows[1]['from'] + 2}, messages=[
                        dict(role='user', content='request'),
                        dict(role='assistant', content='[interrupted by user]')],
                        model_ms=999999, usage=dict(prompt_tokens=999999)))
                path.write_text('\n'.join(map(json.dumps, rows)) + '\n{broken json\n')
                paths.append(path)
            sidecar = directory / 'zero.calls.jsonl'
            synthetic_log(sidecar, [[None]], parent_session_id='parent')
            costs = stats.summarize(paths + [sidecar])['child_costs']
            self.assertEqual(costs['sessions'], 5)
            self.assertEqual(costs['full_range_sessions'], 4)
            self.assertEqual(costs['no_step_sessions'], 1)
            self.assertEqual(costs['partial_range_sessions'], 0)
            self.assertEqual(costs['steps'], dict(samples=4, median=1, p90=2))
            self.assertEqual(costs['model_ms'], dict(samples=2, median=3, p90=6))
            self.assertEqual(costs['prompt_tokens'], dict(samples=2, median=5, p90=10))
            self.assertEqual(costs['uncached_prompt_tokens'], dict(samples=1, median=6, p90=6))
            self.assertEqual(set(costs['by_parent_system']), {'unknown'})

    def test_child_costs_uncached_requires_valid_pair_on_every_step(self):
        cases = [
            ({}, None),
            (dict(prompt_tokens=10), None),
            (dict(prompt_cache_hit_tokens=4), None),
            (dict(prompt_tokens=True, prompt_cache_hit_tokens=0), None),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens=True), None),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens=-1), None),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens=1.5), None),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens='4'), None),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens=None), None),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens=11), None),
            (dict(prompt_tokens=0, prompt_cache_hit_tokens=0), 0),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens=10), 0),
            (dict(prompt_tokens=10, prompt_cache_hit_tokens=0), 10),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'child.jsonl'
            for usage, expected in cases:
                with self.subTest(usage=usage):
                    rows = synthetic_log(path, [[None, None]], parent_session_id='parent')
                    rows[-1]['usage'] = usage
                    path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
                    costs = stats.summarize([path])['child_costs']
                    value = None if expected is None else 6 + expected
                    self.assertEqual(costs['uncached_prompt_tokens'],
                                     dict(samples=int(expected is not None), median=value, p90=value))
                    self.assertEqual(costs['model_ms']['samples'], 1)
                    self.assertEqual(costs['prompt_tokens']['samples'],
                                     int(stats.number(usage.get('prompt_tokens'))))

    def test_child_costs_uncached_distributes_session_sums_not_step_values(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index in range(1, 11):
                path = Path(directory) / f'{index}.jsonl'
                rows = synthetic_log(path, [[None] * index], parent_session_id='parent')
                for row in rows[1:]:
                    row['usage'] = dict(prompt_tokens=100 * index, prompt_cache_hit_tokens=100 * index - 1)
                path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
                paths.append(path)
            costs = stats.summarize(paths)['child_costs']
            self.assertEqual(costs['uncached_prompt_tokens'], dict(samples=10, median=5.5, p90=9))

    def test_child_costs_since_partial_range_and_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            parent = directory / 'parent.jsonl'
            parent_rows = synthetic_log(parent, [[None]], system_sha='original')
            child = directory / 'child.jsonl'
            rows = synthetic_log(child, [['tools.read({path: \"a\"})', None]], parent_session_id='parent')
            cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
            for row in parent_rows + rows:
                row['at'] = cutoff - 1
            parent_rows[0]['cwd'] = '/different-parent-cwd'
            rows[-1]['at'] = cutoff
            parent.write_text('\n'.join(map(json.dumps, parent_rows)) + '\n')
            child.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            costs = stats.summarize([parent, child], since=date(2025, 1, 2), cwd=directory)['child_costs']
            self.assertEqual(costs['sessions'], 1)
            self.assertEqual(costs['partial_range_sessions'], 1)
            self.assertEqual(costs['full_range_sessions'], 0)
            for field in ('steps', 'model_ms', 'prompt_tokens', 'uncached_prompt_tokens'):
                self.assertEqual(costs[field], dict(samples=0, median=None, p90=None))
            self.assertEqual(set(costs['by_parent_system']), {'original'})
            self.assertEqual(stats.summarize([child], cwd=ROOT)['child_costs']['sessions'], 0)

    def test_child_costs_fork_new_groups_first_request_and_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            paths = []
            for name, sha in [('parent-a', 'old'), ('parent-b', 'new')]:
                path = directory / (name + '.jsonl')
                synthetic_log(path, [[None]], system_sha=sha,
                              forked_from=dict(session='root-source', message_count=2))
                paths.append(path)
            for name, parent, usages, fork in [
                ('fork-a', 'parent-a', [(100, 80), (1000, 0)], True),
                ('fork-b', 'parent-b', [(10, 2), (10, 10), (10, 10)], True),
                ('fresh', 'parent-a', [(20, 0)], False),
            ]:
                path = directory / (name + '.jsonl')
                rows = synthetic_log(path, [[None] * len(usages)],
                                     parent_session_id=parent, system_sha='child')
                if fork:
                    rows[0]['forked_from'] = dict(session=parent, message_count=3)
                    rows[0]['messages'].extend([dict(role='user', content='inherited'),
                                                dict(role='assistant', content='inherited')])
                    rows[0]['usage'] = dict(prompt_tokens=999999, prompt_cache_hit_tokens=999999)
                    rows[0]['model_ms'] = 999999
                    for row in rows[1:]:
                        row['from'] += 2
                for row, (prompt, cache) in zip(rows[1:], usages):
                    row['usage'] = dict(prompt_tokens=prompt, prompt_cache_hit_tokens=cache)
                path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
                paths.append(path)
            report = stats.summarize(sorted(paths), group_by='system')
            costs = report['child_costs']
            self.assertEqual(costs['sessions'], 3)
            self.assertEqual(set(costs['by_creation']), {'fork', 'new'})
            fork = costs['by_creation']['fork']
            self.assertEqual(fork['sessions'], 2)
            self.assertEqual(fork['steps'], dict(samples=2, median=2.5, p90=3))
            self.assertEqual(fork['model_ms'], dict(samples=2, median=15, p90=18))
            self.assertEqual(fork['prompt_tokens'], dict(samples=2, median=565, p90=1100))
            self.assertEqual(fork['uncached_prompt_tokens'], dict(samples=2, median=514, p90=1020))
            self.assertEqual(fork['first_request_cache_hit_rate'], dict(samples=2, median=0.5, p90=0.8))
            fresh = costs['by_creation']['new']
            for field, value in [('steps', 1), ('model_ms', 6), ('prompt_tokens', 20),
                                 ('uncached_prompt_tokens', 20), ('first_request_cache_hit_rate', 0)]:
                self.assertEqual(fresh[field], dict(samples=1, median=value, p90=value))
            self.assertEqual(costs['first_request_cache_hit_rate'], dict(samples=3, median=0.2, p90=0.8))
            old = costs['by_parent_system']['old']['by_creation']
            self.assertEqual(set(old), {'fork', 'new'})
            self.assertEqual(old['fork']['first_request_cache_hit_rate']['median'], 0.8)
            self.assertEqual(costs['by_parent_system']['new']['by_creation']['fork']['steps']['median'], 3)
            self.assertEqual(report['groups']['child']['child_costs'], costs)
            orphan = stats.summarize(paths[2:])['child_costs']
            self.assertEqual(orphan['by_creation'], costs['by_creation'])
            self.assertEqual(set(orphan['by_parent_system']), {'unknown'})
            cli = [sys.executable, str(ROOT / 'scripts/stats.py'), str(directory), '--group-by', 'system']
            self.assertEqual(json.loads(subprocess.check_output(cli + ['--json'])), report)
            text = subprocess.check_output(cli, text=True)
            self.assertIn('parent_system=all creation=fork: sessions=2', text)
            self.assertIn('parent_system=old creation=new: sessions=1', text)
            self.assertIn('first_request_cache_hit_rate: samples=2 median=50.00% p90=80.00%', text)

    def test_child_costs_first_request_requires_valid_nonzero_pair(self):
        cases = [(None, None), ({}, None), ([], None)]
        for prompt, cache, expected in [(100, 20, 0.2), (100, 0, 0), (100, 100, 1),
                                        (0, 0, None), (10, 11, None)]:
            cases.append((dict(prompt_tokens=prompt, prompt_cache_hit_tokens=cache), expected))
        for invalid in (None, True, -1, 1.5, '10', [], {}):
            cases.append((dict(prompt_tokens=invalid, prompt_cache_hit_tokens=0), None))
            cases.append((dict(prompt_tokens=10, prompt_cache_hit_tokens=invalid), None))
        cases.extend([(dict(prompt_tokens=10), None), (dict(prompt_cache_hit_tokens=5), None)])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'child.jsonl'
            for usage, expected in cases:
                with self.subTest(usage=usage):
                    rows = synthetic_log(path, [[None, None]], parent_session_id='parent',
                                         forked_from=dict(session='parent', message_count=0))
                    rows[1]['usage'] = usage
                    rows[1].pop('model_ms')
                    path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
                    costs = stats.summarize([path])['child_costs']
                    value = dict(samples=0, median=None, p90=None) if expected is None else dict(
                        samples=1, median=expected, p90=expected)
                    self.assertEqual(costs['first_request_cache_hit_rate'], value)
                    self.assertEqual(costs['by_creation']['fork']['first_request_cache_hit_rate'], value)
                    self.assertEqual(costs['by_creation']['fork']['model_ms']['samples'], 0)
            rows = synthetic_log(path, [[None, None]], parent_session_id='parent')
            rows[2].pop('usage')
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            costs = stats.summarize([path])['child_costs']
            self.assertEqual(costs['first_request_cache_hit_rate'], dict(samples=1, median=0.4, p90=0.4))
            self.assertEqual(costs['uncached_prompt_tokens']['samples'], 0)

    def test_child_costs_fork_metadata_invalid_and_empty(self):
        self.assertEqual(stats.summarize([])['child_costs']['by_creation'], {})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'child.jsonl'
            for fork in (None, False, '', [], {}, dict(session='source'),
                         dict(session='', message_count=1), dict(session=' ', message_count=1),
                         dict(session=1, message_count=1), dict(session='source', message_count=True),
                         dict(session='source', message_count=-1), dict(session='source', message_count=1.5)):
                with self.subTest(fork=fork):
                    synthetic_log(path, [[]], parent_session_id='parent', forked_from=fork)
                    costs = stats.summarize([path])['child_costs']
                    self.assertEqual(set(costs['by_creation']), {'unknown'})
                    self.assertEqual(costs['by_creation']['unknown']['no_step_sessions'], 1)
                    self.assertEqual(costs['first_request_cache_hit_rate']['samples'], 0)

    def test_child_costs_fork_since_and_interrupted(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
            paths = []
            for name, times in [('first-excluded', [cutoff - 1, cutoff]),
                                ('last-excluded', [cutoff, cutoff - 1]),
                                ('empty', []), ('interrupted', [cutoff])]:
                path = directory / (name + '.jsonl')
                rows = synthetic_log(path, [[None] * len(times)], parent_session_id='parent',
                                     forked_from=dict(session='parent', message_count=5))
                rows[0]['at'] = cutoff
                for row, at in zip(rows[1:], times):
                    row['at'] = at
                if name == 'interrupted':
                    rows[1]['messages'][-1]['content'] = '[interrupted by user]'
                path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
                paths.append(path)
            report = stats.summarize(paths, since=date(2025, 1, 2), cwd=directory)
            fork = report['child_costs']['by_creation']['fork']
            self.assertEqual(fork['sessions'], 4)
            self.assertEqual(fork['partial_range_sessions'], 2)
            self.assertEqual(fork['no_step_sessions'], 2)
            for field in ('steps', 'model_ms', 'prompt_tokens', 'uncached_prompt_tokens',
                          'first_request_cache_hit_rate'):
                self.assertEqual(fork[field], dict(samples=0, median=None, p90=None))
            self.assertEqual(stats.summarize(paths, cwd=ROOT)['child_costs']['by_creation'], {})
            cli = [sys.executable, str(ROOT / 'scripts/stats.py'), str(directory),
                   '--since', '2025-01-02', '--cwd', str(directory)]
            self.assertEqual(json.loads(subprocess.check_output(cli + ['--json'])), report)

    def test_tool_data_mixed_logs_and_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bytes.jsonl'
            records = synthetic_log(path, [['tools.read({path: \"a\"})', None]], nib_version='bytes')
            records[1].update(tool_bytes=1000, output_bytes=250,
                run_results=[dict(tool_bytes=100, output_bytes=value) for value in range(10, 111, 10)]
                            + [dict(tool_bytes=0, output_bytes=99), dict(tool_bytes=1), {}],
                calls=[dict(name='read', result_bytes=300), dict(name='read', result_bytes=100),
                       dict(name='bash', result_bytes=600), dict(name='write', result_bytes=0),
                       dict(name='legacy'), dict(name='bad', result_bytes=True)])
            records[2].update(output_bytes=0)
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path], group_by='version')
            data = report['tool_data']
            self.assertEqual(data['step_bytes'], dict(
                tool_bytes=dict(samples=1, total_bytes=1000),
                output_bytes=dict(samples=2, total_bytes=250)))
            self.assertEqual(data['output_tool_ratio'], dict(samples=11, median=0.6, p90=1.0))
            self.assertEqual(data['result_bytes'], 1000)
            self.assertEqual(data['tools'], {
                'bash': dict(count=1, result_bytes=600, ratio=0.6),
                'read': dict(count=2, result_bytes=400, ratio=0.4),
                'write': dict(count=1, result_bytes=0, ratio=0.0)})
            self.assertEqual(report['groups']['bytes']['tool_data'], data)
            cli = subprocess.check_output([sys.executable, str(ROOT / 'scripts/stats.py'),
                                           str(path), '--json'], text=True)
            self.assertEqual(json.loads(cli)['tool_data'], data)
            text = subprocess.check_output([sys.executable, str(ROOT / 'scripts/stats.py'),
                                            str(path)], text=True)
            self.assertIn('Tool data metrics', text)
            self.assertIn('output_bytes/tool_bytes: samples=11 median=0.6 p90=1', text)
            self.assertIn('read: count=2 result_bytes=400 ratio=40.00%', text)
            report['tool_data']['output_tool_ratio'] = dict(samples=1, median=12/96060, p90=12/96060)
            self.assertIn('median=0.000124922 p90=0.000124922', stats.text_report(report))

    def test_tool_data_legacy_invalid_and_zero(self):
        empty = stats.ToolData().report()
        self.assertEqual(stats.summarize([])['tool_data'], empty)
        data = stats.ToolData()
        for value in (None, True, -1, 1.5, '10', [], {}):
            data.add(dict(tool_bytes=value, output_bytes=value, run_results=value, calls=value))
            data.add(dict(run_results=[None, value, dict(tool_bytes=value, output_bytes=10),
                                      dict(tool_bytes=10, output_bytes=value)],
                          calls=[None, value, dict(name='read', result_bytes=value),
                                 dict(name=value if not isinstance(value, str) else '', result_bytes=10)]))
        self.assertEqual(data.report(), empty)
        data.add(dict(run_results=[dict(tool_bytes=0, output_bytes=10),
                                   dict(tool_bytes=10, output_bytes=0),
                                   dict(tool_bytes=10, output_bytes=20)],
                      calls=[dict(name='read', result_bytes=0)]))
        self.assertEqual(data.report()['output_tool_ratio'], dict(samples=2, median=1.0, p90=2.0))
        self.assertIsNone(data.report()['tools']['read']['ratio'])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'legacy.jsonl'
            synthetic_log(path, [[None]])
            report = stats.summarize([path])
            self.assertEqual(report['tool_data'], empty)
            self.assertIn('output_bytes/tool_bytes: samples=0 median=n/a p90=n/a', stats.text_report(report))

    def test_tool_data_selected_steps_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'filter.jsonl'
            records = synthetic_log(path, [[None], [None]])
            for record, day, size in zip(records, (1, 1, 3), (999, 100, 20)):
                record.update(at=int(datetime(2025, 1, day).timestamp() * 1000),
                              tool_bytes=size, output_bytes=size,
                              run_results=[dict(tool_bytes=size, output_bytes=size)],
                              calls=[dict(name='read', result_bytes=size)])
            records.append(dict(records[2], **{'from': 0, 'tool_bytes': 9999}))
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            data = stats.summarize([path], since=date(2025, 1, 2))['tool_data']
            self.assertEqual(data['step_bytes']['tool_bytes'], dict(samples=1, total_bytes=20))
            self.assertEqual(data['output_tool_ratio'], dict(samples=1, median=1.0, p90=1.0))
            self.assertEqual(data['tools']['read'], dict(count=1, result_bytes=20, ratio=1.0))
            self.assertEqual(stats.summarize([path], cwd=Path(directory) / 'other')['tool_data'],
                             stats.ToolData().report())

    def test_calls_sidecars_are_never_read(self):
        with tempfile.TemporaryDirectory() as directory:
            sidecar = Path(directory) / ('a' * 32 + '.calls.jsonl')
            sidecar.write_text('PRIVATE_CALLS_SENTINEL')
            with mock.patch.object(Path, 'stat', side_effect=AssertionError('sidecar accessed')), \
                    mock.patch.object(Path, 'read_text', side_effect=AssertionError('sidecar read')):
                report = stats.summarize([sidecar])
            self.assertEqual(report['overall']['sessions'], 0)
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/stats.py'),
                                     directory, '--json'], capture_output=True, text=True, check=True)
            self.assertNotIn('PRIVATE_CALLS_SENTINEL', result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)['overall']['sessions'], 0)

    def test_mixed_background_agent_and_bash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.jsonl'
            rows = synthetic_log(path, [['tools.agent({prompt: "check", background: true})',
                                         'tools.read({path: "a"})', None]])
            rows[1]['calls'] = [dict(name='agent', background=True, id='a1'),
                                  dict(name='bash'), dict(name='bash', background=True, id='b2')]
            result_from = rows[3]['from']
            rows[3]['from'] += 2
            result = lambda offset, kind, task_id: dict({'from': result_from + offset}, messages=[
                dict(role='user', source='background', background_kind=kind, background_id=task_id,
                     content=f'[background {kind} {task_id} finished]')])
            event = lambda kind, task_id, state, step: dict(background=dict(id=task_id, kind=kind, state=state),
                                                            messages=[], turn_step=step)
            ordered = [rows[0], event('agent', 'a1', 'started', 1), event('bash', 'b2', 'started', 1),
                       rows[1], rows[2], result(0, 'agent', 'a1'), event('agent', 'a1', 'finished', 3),
                       result(1, 'bash', 'b2'), event('bash', 'b2', 'finished', 3), rows[3]]
            path.write_text('\n'.join(map(json.dumps, ordered)) + '\n')
            report = stats.summarize([path])
            self.assertEqual(report['agents']['foreground_calls'], 0)
            self.assertEqual(report['agents']['background_calls'], 1)
            self.assertEqual(report['bash_calls']['foreground_calls'], 1)
            self.assertEqual(report['bash_calls']['background_calls'], 1)
            self.assertEqual(report['bash_calls']['background_steps'], dict(samples=1, median=1, p90=1))
            self.assertEqual(report['overall']['turns'], 1)
            rows[0]['parent_session_id'] = 'parent'
            path.write_text('\n'.join(map(json.dumps, ordered)) + '\n')
            child = stats.summarize([path])
            self.assertEqual(child['agents']['background_calls'], 0)
            self.assertEqual(child['bash_calls']['background_calls'], 1)

    def test_background_agent_standalone_result_needs_terminal_record(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'background.jsonl'
            rows = synthetic_log(path, [['tools.agent({prompt: "one", background: true})',
                                         'tools.read({path: "a"})', None]])
            rows[1]['calls'] = [dict(name='agent', background=True, id='a1')]
            result = dict({'from': rows[3]['from']}, messages=[dict(role='user',
                source='background_agent', background_agent_id='a1', content='[background agent a1 finished]\n{}')])
            rows[3]['from'] += 1
            started = dict(background_agent=dict(id='a1', state='started'), messages=[], turn_step=1)
            finished = dict(background_agent=dict(id='a1', state='finished', ok=True), messages=[], turn_step=3)
            ordered = [rows[0], started, rows[1], rows[2], result, finished, rows[3]]

            def measure(records):
                path.write_text('\n'.join(map(json.dumps, records)) + '\n')
                return stats.summarize([path])['agents']

            self.assertEqual(measure(ordered)['background_steps'], dict(samples=1, median=1, p90=1))
            self.assertEqual(measure(ordered[:-2] + ordered[-1:])['background_steps']['samples'], 0)
            self.assertEqual(measure(ordered[:4] + ordered[5:])['background_steps']['samples'], 0)
            self.assertEqual(measure([rows[0], rows[1], rows[2], result, rows[3]])['background_steps']['samples'], 1)

    def test_background_agent_overlap_and_turn_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'background.jsonl'
            records = synthetic_log(path, [['tools.agent({prompt: "one", background: true})',
                                            'tools.read({path: "a"})',
                                            'tools.agent({prompt: "three", background: true})', None]], nib_version='background')
            records[1]['calls'] = [dict(name='agent', background=True, id='a1'),
                                   dict(name='agent'), dict(name='agent', dispatched=False)]
            records[2]['calls'] = []  # lifecycle remains available when calls are omitted
            records[3]['messages'].insert(0, dict(role='user', source='background_agent',
                background_agent_id='a1', content='[background agent a1 finished]\n{}'))
            records[3]['calls'] = [dict(name='agent', background=True, id='a3')]
            records[4]['from'] += 1
            records[4]['messages'][0:0] = [
                dict(role='user', source='background_agent', background_agent_id=agent_id, content='result')
                for agent_id in ('a2', 'a3', 'unknown')]
            lifecycle = lambda agent_id, state, step: dict(background_agent=dict(id=agent_id, state=state),
                                                          messages=[], turn_step=step)
            records = [records[0], lifecycle('a1', 'started', 1), records[1],
                       lifecycle('a2', 'started', 2), records[2],
                       lifecycle('a1', 'finished', 3), lifecycle('a3', 'started', 3), records[3],
                       lifecycle('a2', 'finished', 4), lifecycle('a3', 'lost', 4), records[4]]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path], group_by='version')
            agents = report['agents']
            self.assertEqual(agents['foreground_calls'], 1)
            self.assertEqual(agents['background_calls'], 3)
            self.assertEqual(agents['background_steps'], dict(samples=3, median=1, p90=1))
            self.assertEqual(report['overall']['turns'], 1)
            self.assertEqual(report['overall']['steps'], 4)
            self.assertEqual(report['groups']['background']['agents'], agents)
            self.assertIn('Agent calls: foreground 1 / background 3', stats.text_report(report))
            self.assertIn('Main-model Steps during background work: samples=3 median=1.00 p90=1.00', stats.text_report(report))
            records[0]['parent_session_id'] = 'parent'
            path.write_text('\n'.join(map(json.dumps, records)))
            self.assertEqual(stats.summarize([path])['agents'], stats.AgentStats().report())

    def test_background_agent_overlap_skips_filtered_and_interrupted_pairs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'background.jsonl'
            records = synthetic_log(path, [['tools.agent({prompt: "one", background: true})',
                                            'tools.read({path: "a"})', None]])
            for record in records:
                record['at'] = int(datetime(2026, 2, 2).timestamp() * 1000)
            records[1]['calls'] = [dict(name='agent', background=True, id='a1')]
            records[3]['messages'].insert(0, dict(role='user', source='background_agent',
                background_agent_id='a1', content='result'))
            records[2]['at'] = int(datetime(2026, 1, 1).timestamp() * 1000)
            path.write_text('\n'.join(map(json.dumps, records)))
            self.assertEqual(stats.summarize([path], since=date(2026, 2, 1))['agents']['background_steps']['samples'], 0)
            records[2]['messages'] = [dict(role='assistant', content='[interrupted by user]')]
            records[3]['from'] = records[2]['from'] + 1
            path.write_text('\n'.join(map(json.dumps, records)))
            self.assertEqual(stats.summarize([path])['agents']['background_steps']['samples'], 0)

    def assertRoundTrips(self, actual, expected):
        self.assertEqual(len(actual["notes"]), 3)
        self.assertEqual({key: value for key, value in actual.items() if key != "notes"}, expected)

    def test_exploration_metrics(self):
        def read(path):
            return 'tools.read({path: ' + json.dumps(path) + '})'

        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        marker = '[entry 1 of 1 (console)]\nabc\n[19000 of 20000 bytes omitted \u00b7 lines 3\u201390]\nxyz\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'explore.jsonl'
            records = synthetic_log(path, [
                [read('a'), [read('b'), read('a')], read('b'), edit, read('a'), None],
                [read('c'), None],
                [edit, None]])
            for record in records[1:]:
                for message in record['messages']:
                    if message['role'] == 'assistant' and any(
                            read('c') in call['function']['arguments'].replace('\\"', '"')
                            for call in message.get('tool_calls', [])):
                        marked = [m for m in record['messages'] if m['role'] == 'tool']
                        marked[0]['content'] = marker
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path])['exploration']
            self.assertEqual(report['steps_before_first_edit'], dict(samples=2, median=2.5, p90=4))
            self.assertEqual(report['turns_without_edit'], dict(count=1, turns=3, ratio=1 / 3))
            reread = report['reread_before_first_edit']
            self.assertEqual((reread['rereads'], reread['reads']), (2, 4))
            self.assertEqual(report['truncated_runs'], dict(count=1, runs=8, ratio=1 / 8))
            self.assertEqual(report['truncated_explore_runs'], dict(count=1, runs=6, ratio=1 / 6))
            text = subprocess.check_output(['python3', str(ROOT / 'scripts/stats.py'), str(path)]).decode()
            self.assertIn('Re-read before first edit: 2/4 reads', text)

    def test_round_trips_exact_counts_and_cli(self):
        def write(path):
            return 'tools.write({path: ' + json.dumps(path) + ', content: "x"})'

        def bash(command):
            return 'tools.bash({command: ' + json.dumps(command) + '})'

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'pairs.jsonl'
            synthetic_log(path, [
                [write('a'), [write('b'), write('c')], [write('b'), write('d')],
                 'tools.edit({path: dynamic, old_text: "x", new_text: "y"})',
                 write('e'), [bash('zig build'), bash('git diff --stat')], None],
                [write('z'), [write('z'), bash('cargo test')], 'tools.bash({command: dynamic})',
                 bash('zig build && rm -rf out'), [bash('zig test x.zig'), 'tools.read({path: "x"})'],
                 write('q'), [bash('zig fmt --check x.zig'), bash('cargo check')]],
                [bash('git diff'), write('b'), write('./b'), [write('c'), write('a')], None]])
            before = path.read_bytes()
            report = stats.summarize([path])
            expected = dict(steps_per_turn=dict(samples=3, median=7, p90=7),
                            write_to_validation=dict(count=2, pairs=16, ratio=.125),
                            disjoint_write_files=dict(count=2, pairs=5, ratio=.4),
                            mechanical_followups=mechanical_metric(3, 16))
            self.assertRoundTrips(report['round_trips'], expected)
            self.assertEqual(report['overall']['steps'], 19)
            cli = ['python3', str(ROOT / 'scripts/stats.py'), str(path)]
            result = json.loads(subprocess.check_output(cli + ['--json']))
            self.assertRoundTrips(result['round_trips'], expected)
            text = subprocess.check_output(cli).decode()
            self.assertIn('Round-trip structure:', text)
            self.assertIn('Steps per Turn: samples=3 median=7.00 p90=7.00', text)
            self.assertIn('write→validation only: 2/16 = 12.50%', text)
            self.assertIn('consecutive writes to different files (disjoint): 2/5 = 40.00%', text)
            self.assertEqual(path.read_bytes(), before)

    def test_mechanical_followups_static_hits_misses_and_timing(self):
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        read = 'tools.read({path: "a"})'
        status = 'tools.bash({command: "git status --short"})'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "static.jsonl"
            rows = synthetic_log(path, [[edit, status, read, edit,
                                        'tools.bash({command: "git diff && pwd"})',
                                        'tools.bash({command: dynamic})',
                                        ['tools.bash({command: "tail -n 5 a"})', read], None]])
            for row, ms in zip(rows[1:], [9999, 20, None, 30, -1, True, 0, 50]):
                if ms is None:
                    row.pop("ms")
                else:
                    row["ms"] = ms
            path.write_text("\n".join(map(json.dumps, rows)) + "\n")
            report = stats.summarize([path])["round_trips"]
            self.assertEqual(report["mechanical_followups"], mechanical_metric(
                3, 7, ms=20, sample_ms=100, timed_count=2, timed_samples=4))
            self.assertEqual(report["write_to_validation"], dict(count=1, pairs=7, ratio=1/7))
            self.assertEqual(stats.summarize([])["round_trips"]["mechanical_followups"],
                             mechanical_metric(0, 0))

    def test_mechanical_followups_require_explicit_successful_previous_runs(self):
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        read = 'tools.read({path: "a"})'
        cases = [("success", [edit], [True], True),
                 ("all-success", [edit, edit], [True, True], True),
                 ("failed", [edit], [False], False),
                 ("unknown", [edit], [None], False),
                 ("null", [edit], [None], False),
                 ("truthy-int", [edit], [1], False),
                 ("truthy-string", [edit], ["true"], False),
                 ("one-failed", [edit, edit], [True, False], False),
                 ("one-unknown", [edit, edit], [True, None], False),
                 ("zero-runs", None, [], False)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "previous.jsonl"
            for name, codes, statuses, eligible in cases:
                with self.subTest(name=name):
                    rows = synthetic_log(path, [[codes, read]])
                    for result, ok in zip(rows[1]["run_results"], statuses):
                        if ok is None and name != "null":
                            result.pop("ok")
                        else:
                            result["ok"] = ok
                    if name == "unknown":
                        rows[1].pop("run_results")
                    path.write_text("\n".join(map(json.dumps, rows)) + "\n")
                    self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                     mechanical_metric(int(eligible), int(eligible)))
            rows = synthetic_log(path, [[edit, read]])
            rows[2]["run_results"][0]["ok"] = False
            path.write_text("\n".join(map(json.dumps, rows)) + "\n")
            report = stats.summarize([path])["round_trips"]
            self.assertEqual(report["mechanical_followups"], mechanical_metric(1, 1))
            self.assertEqual(report["write_to_validation"], dict(count=0, pairs=1, ratio=0))

    def test_mechanical_followups_turn_boundaries_and_explicit_interjections(self):
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        read = 'tools.read({path: "a"})'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "turns.jsonl"
            synthetic_log(path, [[edit], [read]])
            self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                             mechanical_metric(0, 0))
            for explicit in (False, True):
                for source in (None, "background", "background_agent"):
                    with self.subTest(explicit=explicit, source=source):
                        rows = synthetic_log(path, [[edit, read]])
                        user = dict(role="user", content="interjection")
                        if source is not None:
                            user["source"] = source
                        rows[2]["messages"].insert(0, user)
                        if explicit:
                            rows[1]["turn_step"], rows[2]["turn_step"] = 1, 2
                        path.write_text("\n".join(map(json.dumps, rows)) + "\n")
                        eligible = explicit or source is not None
                        self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                         mechanical_metric(int(eligible), int(eligible)))
            for position in (1, 3):
                with self.subTest(position=position):
                    rows = synthetic_log(path, [[edit, read]])
                    rows[1]["turn_step"], rows[2]["turn_step"] = 1, position
                    path.write_text("\n".join(map(json.dumps, rows)) + "\n")
                    self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                     mechanical_metric(0, 0))

    def test_mechanical_followups_filter_cancel_and_replacement_break_adjacency(self):
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        read = 'tools.read({path: "a"})'
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gaps.jsonl"
            rows = synthetic_log(path, [[edit, read, read]])
            for row, at in zip(rows, [cutoff, cutoff, cutoff - 1, cutoff]):
                row["at"] = at
            path.write_text("\n".join(map(json.dumps, rows)) + "\n")
            self.assertEqual(stats.summarize([path], since=date(2025, 1, 2))["round_trips"]["mechanical_followups"],
                             mechanical_metric(0, 0))
            for boundary in ("[interrupted by user]", "[interrupted: process terminated]", "replacement"):
                with self.subTest(boundary=boundary):
                    rows = synthetic_log(path, [[edit, read]])
                    if boundary == "replacement":
                        middle = dict({"from": rows[1]["from"]},
                                      messages=[dict(role="user", content="compacted context")])
                    else:
                        middle = dict({"from": rows[2]["from"]},
                                      messages=[dict(role="assistant", content=boundary)])
                        rows[2]["from"] += 1
                    rows.insert(2, middle)
                    path.write_text("\n".join(map(json.dumps, rows)) + "\n")
                    self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                     mechanical_metric(0, 0))

    def test_mechanical_followups_static_token_extraction_is_conservative(self):
        read = 'tools.read({path: "a"})'
        cases = [(read, True),
                 ('await Promise.all([tools.read({path: "a"}), tools.bash({command: "git diff"})])', True),
                 ('// tools.write({path: "a"})\n' + read, True),
                 ('const text = "tools.edit({})"; ' + read, True),
                 ('const text = "tools.read({})"; /* tools.bash({command: "pwd"}) */', False),
                 ('tools.bash({command: "pwd"}); helper()', False),
                 ('tools.bash({command: "git " + subcommand})', False),
                 ('tools.bash({command: `git ${subcommand}`})', False),
                 ('tools[method]({path: "a"})', False),
                 ('tools.write({path: "a", content: "x"})', False),
                 ('tools.edit({path: "a", old_text: "x", new_text: "y"})', False),
                 (['console.log("status")', read], True),
                 (['console.log("status")', 'const x = 1'], False),
                 ('false && ' + read, False),
                 ('true || ' + read, False),
                 ('true ? 0 : ' + read, False),
                 ('const check = () => ' + read + '; console.log("done")', False),
                 ('if (false) { ' + read + ' }', False)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tokens.jsonl"
            for code, hit in cases:
                with self.subTest(code=code):
                    synthetic_log(path, [[read, code]])
                    self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                     mechanical_metric(int(hit), 1))
            for command in ("git status; pwd", "git status && pwd", "git status || pwd",
                            "cat a | head", "pwd > output", "cat < input", "pwd 2>&1",
                            "git show $REF", "cat $(pwd)", "cat `pwd`", "pwd\nls",
                            "git push", "gh pr merge 42", "rm a"):
                with self.subTest(command=command):
                    self.assertFalse(stats.validation_command(command))
                    synthetic_log(path, [[read, 'tools.bash({command: ' + json.dumps(command) + '})']])
                    self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                     mechanical_metric(0, 1))

    def test_mechanical_followups_complete_recordings_override_static_calls(self):
        read = 'tools.read({path: "a"})'
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        status = 'tools.bash({command: "git status"})'
        cases = [('tools.bash({command: dynamic})', [("bash", dict(command="git status --short"))], True),
                 (status, [("bash", dict(command="rm a"))], False),
                 (read, [("write", dict(path="a", content="x"))], False),
                 (edit, [("read", dict(path="a"))], True),
                 (status, [("bash", dict(command="pwd")), ("edit", dict(path="a"))], False),
                 ('await helper()', [("read", dict(path="a")),
                                       ("bash", dict(command="gh pr checks 42"))], True),
                 (status, [], False),
                 (status, [("agent", dict(prompt="check"))], False),
                 (status, [("llm", dict(prompt="check"))], False),
                 (status, [("bash", None)], False)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "recorded.jsonl"
            synthetic_log(path, [[edit, code] for code, _, _ in cases])
            recording = []
            for number, (_, calls, _) in enumerate(cases, 1):
                for index, (name, args) in enumerate(calls):
                    recording.append(dict(step=number * 2, run=0, index=index, name=name, args=args))
                meta = dict(end="ok")
                if number % 2 == 0:
                    meta["incomplete"] = None
                recording.append(dict(step=number * 2, run=0, meta=meta))
            recording.append(dict(step=999, run=0, index=0, name="bash", args=dict(command="pwd")))
            calls_path = path.with_suffix(".calls.jsonl")
            calls_path.write_text("garbage\n[]\n" + "\n".join(map(json.dumps, reversed(recording))) + "\n{")
            before = path.read_bytes(), calls_path.read_bytes()
            report = stats.summarize([path])["round_trips"]["mechanical_followups"]
            self.assertEqual(report, mechanical_metric(
                3, 10, sources=dict(recorded=10, static=0, mixed=0),
                hit_sources=dict(recorded=3, static=0, mixed=0)))
            self.assertEqual((path.read_bytes(), calls_path.read_bytes()), before)

    def test_mechanical_followups_complete_failed_current_run_uses_recording(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "current-failure.jsonl"
            rows = synthetic_log(path, [['tools.read({path: "a"})',
                                         'tools.bash({command: dynamic}); throw new Error("unexpected")']])
            rows[2]["run_results"][0]["ok"] = False
            path.write_text("\n".join(map(json.dumps, rows)) + "\n")
            path.with_suffix(".calls.jsonl").write_text("\n".join(map(json.dumps, [
                dict(step=2, run=0, index=0, name="bash", args=dict(command="git status")),
                dict(step=2, run=0, meta=dict(end="error", incomplete=None))])) + "\n")
            self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                             mechanical_metric(1, 1, sources=dict(recorded=1, static=0, mixed=0),
                                               hit_sources=dict(recorded=1, static=0, mixed=0)))

    def test_mechanical_followups_incomplete_recordings_fall_back_per_run(self):
        read = 'tools.read({path: "a"})'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "incomplete.jsonl"
            synthetic_log(path, [[read, read]])
            call = dict(step=2, run=0, index=0, name="write", args=dict(path="a", content="x"))
            end = dict(step=2, run=0, meta=dict(end="ok"))
            cases = {
                "no-sidecar": None,
                "no-end": [call],
                "null-meta": [call, dict(step=2, run=0, meta=None)],
                "incomplete": [call, dict(step=2, run=0, meta=dict(end="ok", incomplete=True))],
                "cancelled": [call, dict(step=2, run=0, meta=dict(end="cancel"))],
                "duplicate-index": [call, call, end],
                "missing-index-zero": [dict(call, index=1), end],
                "index-gap": [call, dict(call, index=2), end],
                "duplicate-end": [call, end, end],
            }
            calls_path = path.with_suffix(".calls.jsonl")
            for name, recording in cases.items():
                with self.subTest(name=name):
                    if recording is None:
                        calls_path.unlink(missing_ok=True)
                    else:
                        calls_path.write_text("\n".join(map(json.dumps, recording)) + "\n")
                    self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                     mechanical_metric(1, 1))
            synthetic_log(path, [[read, 'tools.bash({command: dynamic})']])
            calls_path.write_text(json.dumps(dict(call, name="read", args=dict(path="a"))) + "\n")
            self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                             mechanical_metric(0, 1))

    def test_mechanical_followups_recorded_static_and_mixed_sources(self):
        read = 'tools.read({path: "a"})'
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        dynamic = 'tools.bash({command: command})'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mixed.jsonl"
            synthetic_log(path, [[read, codes] for codes in
                                 ([dynamic, read], [dynamic, edit], [dynamic, dynamic], [read, read])])
            recording = []
            for step, run in [(2, 0), (4, 0), (6, 0), (6, 1)]:
                recording.extend([dict(step=step, run=run, index=0, name="bash", args=dict(command="pwd")),
                                  dict(step=step, run=run, meta=dict(end="ok", incomplete=False))])
            recording.append(dict(step=2, run=1, index=0, name="write", args=dict(path="a")))
            path.with_suffix(".calls.jsonl").write_text("\n".join(map(json.dumps, recording)) + "\n")
            self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"], mechanical_metric(
                3, 4, sources=dict(recorded=1, static=1, mixed=2),
                hit_sources=dict(recorded=1, static=1, mixed=1)))

    def test_mechanical_followups_recording_numbers_include_filtered_interrupted_assistants(self):
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "numbering.jsonl"
            rows = synthetic_log(path, [[edit, edit, edit, 'tools.bash({command: dynamic})']])
            rows[2]["messages"][-1] = dict(role="assistant", content="[interrupted by user]")
            for index, row in enumerate(rows):
                row["at"] = cutoff - 1 if index < 3 else cutoff
            path.write_text("\n".join(map(json.dumps, rows)) + "\n")
            path.with_suffix(".calls.jsonl").write_text("\n".join(map(json.dumps, [
                dict(step=4, run=0, index=0, name="write", args=dict(path="a")),
                dict(step=4, run=0, meta=dict(end="ok")),
                dict(step=5, run=0, index=0, name="bash", args=dict(command="git show HEAD")),
                dict(step=5, run=0, meta=dict(end="ok"))])) + "\n")
            self.assertEqual(stats.summarize([path], since=date(2025, 1, 2))["round_trips"]["mechanical_followups"],
                             mechanical_metric(1, 1, sources=dict(recorded=1, static=0, mixed=0),
                                               hit_sources=dict(recorded=1, static=0, mixed=0)))

    def test_mechanical_followups_zero_and_missing_timing(self):
        read = 'tools.read({path: "a"})'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "untimed.jsonl"
            for ms in (None, True, -1, "10", 1.5, 0):
                with self.subTest(ms=ms):
                    rows = synthetic_log(path, [[read, read]])
                    if ms is None:
                        rows[2].pop("ms")
                    else:
                        rows[2]["ms"] = ms
                    path.write_text("\n".join(map(json.dumps, rows)) + "\n")
                    self.assertEqual(stats.summarize([path])["round_trips"]["mechanical_followups"],
                                     mechanical_metric(1, 1, ms=0, sample_ms=0,
                                                       timed_count=int(ms == 0), timed_samples=int(ms == 0)))

    def test_mechanical_followups_patches_groups_json_and_text(self):
        edit = 'tools.edit({path: "a", old_text: "x", new_text: "y"})'
        read = 'tools.read({path: "a"})'
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            plain, patched = directory / "plain.jsonl", directory / "patched.jsonl"
            synthetic_log(plain, [[edit, read]], nib_version="test")
            synthetic_log(patched, [[edit, edit, 'tools.bash({command: dynamic})']], patches_off=["b", "a"])
            calls_path = patched.with_suffix(".calls.jsonl")
            calls_path.write_text("\n".join(map(json.dumps, [
                dict(step=3, run=0, index=0, name="bash", args=dict(command="pwd")),
                dict(step=3, run=0, meta=dict(end="ok"))])) + "\n")
            before = {path: path.read_bytes() for path in (plain, patched, calls_path)}
            report = stats.summarize([patched, plain], group_by="patches")
            self.assertEqual(report["round_trips"]["mechanical_followups"], mechanical_metric(
                2, 3, sources=dict(recorded=1, static=2, mixed=0),
                hit_sources=dict(recorded=1, static=1, mixed=0)))
            self.assertEqual(report["groups"]["none"]["round_trips"]["mechanical_followups"],
                             mechanical_metric(1, 1))
            self.assertEqual(report["groups"]['["a", "b"]']["round_trips"]["mechanical_followups"], mechanical_metric(
                1, 2, sources=dict(recorded=1, static=1, mixed=0),
                hit_sources=dict(recorded=1, static=0, mixed=0)))
            cli = [sys.executable, str(ROOT / "scripts/stats.py"), str(directory), "--group-by", "patches"]
            self.assertEqual(json.loads(subprocess.check_output(cli + ["--json"])), report)
            text = subprocess.check_output(cli).decode()
            self.assertEqual(text.count("Mechanical follow-up Steps after success (mechanical follow-ups):"), 3)
            self.assertIn("2/3 = 66.67%; Step time 20/30 ms = 66.67% (timed 2/3)", text)
            self.assertIn("1/1 = 100.00%; Step time 10/10 ms = 100.00% (timed 1/1)", text)
            self.assertIn("1/2 = 50.00%; Step time 10/20 ms = 50.00% (timed 1/2)", text)
            self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_turn_step_keeps_interjections_in_the_same_turn(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "interjections.jsonl"
            write_a = 'tools.write({path: "a", content: "x"})'
            write_b = 'tools.write({path: "b", content: "x"})'
            verify = 'tools.bash({command: "zig build"})'
            records = synthetic_log(path, [[write_a, verify, write_b, write_a, None], [None]])
            for record, ordinal in zip(records[1:], [1, 2, 3, 4, 5, 1]):
                record["turn_step"] = ordinal
                if ordinal in (2, 4):
                    record["messages"].insert(0, dict(role="user", content="interjection"))
            offset = 1
            for record in records[1:]:
                record["from"] = offset
                offset += len(record["messages"])
            path.write_text("\n".join(map(json.dumps, records)) + "\n")
            report = stats.summarize([path])
            self.assertEqual(report["overall"]["turns"], 2)
            self.assertEqual(report["round_trips"]["steps_per_turn"], dict(samples=2, median=3, p90=5))
            self.assertEqual(report["round_trips"]["write_to_validation"], dict(count=1, pairs=4, ratio=.25))
            self.assertEqual(report["round_trips"]["disjoint_write_files"], dict(count=1, pairs=1, ratio=1))

    def test_structure_literal_paths_and_conservative_validation(self):
        valid_commands = ['zig build', 'zig test x.zig', 'zig fmt x.zig', 'cargo check',
                          'cargo test --all', 'git diff --stat', 'git status --short',
                          'git log -1', 'git fetch origin', 'git show HEAD',
                          'gh pr view 42', 'gh pr checks 42', 'tail -n 20 output.log',
                          'cat a', 'ls -la', 'head -n 5 a', 'pwd', 'pytest -q', 'diff a b',
                          'python3 tests/test_stats.py', 'python3 -m unittest',
                          'go test ./...', 'make check', 'A=1 /usr/bin/git diff']
        for command in valid_commands:
            with self.subTest(command=command):
                code = 'tools.bash({command: ' + json.dumps(command) + '})'
                self.assertTrue(stats.step_structure([code])['validation'])
        invalid_codes = ['tools.bash({command: command})',
                         'tools.bash({command: "zig build" + args})',
                         'tools.bash({command: `zig ${action}`})',
                         'tools.bash({command: "zig build $ARGS"})',
                         'tools.bash({command: "zig build; rm x"})',
                         'tools.bash({command: "zig build && zig test x"})',
                         'tools.bash({command: "zig build > result"})',
                         'tools.bash({command: "echo test"})',
                         'tools.bash({command: "python3 arbitrary.py"})',
                         'tools.bash({command: "zig build"}); tools.read({path: "a"})',
                         'tools.bash({command: "zig build"}); tools.write({path: "a", content: "x"})',
                         'tools.bash({command: "zig build"}); tools.bash({command: cmd})',
                         'tools.bash({command: "zig build", ...opts})',
                         'tools.bash({command: "zig build", command: cmd})',
                         'tools[method]({command: "zig build"})',
                         'tools.bash({command: "zig build"}); runners[mode]()',
                         'tools.bash({command: "zig build"}); helper()',
                         'tools.bash({command: "zig build"}); const x = `${helper()}`',
                         'const text = "tools.bash({command: zig})"; // tools.bash({})',
                         '', None]
        for code in invalid_codes:
            with self.subTest(code=code):
                self.assertFalse(stats.step_structure([code])['validation'])
        self.assertFalse(stats.step_structure(['tools.bash({command: "zig build"})', None])['validation'])
        complete = stats.step_structure([
            '// tools.write({path: "ignored"})\n'
            'tools.edit({new_text: {a: [1, 2]}, path: "./x/../a", old_text: "x"});'
            "tools.write({'path': 'b', content: `plain`})"], '/project')
        self.assertEqual(complete, dict(writes=True, paths={'/project/a', '/project/b'}, validation=False))
        mixed = stats.step_structure(['tools.write({path: "a"}); tools.bash({command: "git diff"})'])
        self.assertEqual(mixed, dict(writes=True, paths={'a'}, validation=False))
        incomplete = ['tools.write({path: p, content: "x"})',
                      'tools.edit({old_text: "a", new_text: "b"})',
                      'tools.write({path: "a" + suffix, content: "x"})',
                      'tools.write({path: `a${suffix}`, content: "x"})',
                      'tools.write({path: "a", ...options})',
                      'tools.write({path: "a", path: "b"})',
                      'tools.write({[key]: "b", path: "a"})',
                      'tools.write(options)',
                      'tools.write({path: "a"}); runners[mode]()']
        for code in incomplete:
            with self.subTest(code=code):
                item = stats.step_structure([code])
                self.assertTrue(item['writes'])
                self.assertIsNone(item['paths'])
                self.assertFalse(item['validation'])
        item = stats.step_structure(['const text = "tools.write({path: a})"; /* tools.edit({}) */'])
        self.assertEqual(item, dict(writes=False, paths=None, validation=False))

    def test_javascript_literal_path_escapes_and_safe_wrappers(self):
        for literal, expected in [(r"'src\/a.js'", 'src/a.js'), (r"'a\"b'", 'a"b'),
                                  (r"'a\'b'", "a'b"), (r"'\u4e2d\u6587'", '中文'),
                                  (r"'\ud83d\ude00'", '😀'), (r"'a\\b'", 'a\\b'),
                                  (r"'a\x62'", None), (r"'a\q'", None)]:
            with self.subTest(literal=literal):
                self.assertEqual(stats.literal_string(literal), expected)
        code = 'console.log(await Promise.all([tools.bash({command: "zig build"}), tools.bash({command: "git diff"})]))'
        self.assertTrue(stats.step_structure([code])['validation'])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'escapes.jsonl'
            synthetic_log(path, [[r"tools.write({path: 'src\/a.js', content: 'x'})",
                                  "tools.write({path: 'src/a.js', content: 'x'})"]])
            self.assertEqual(stats.summarize([path])['round_trips']['disjoint_write_files'],
                             dict(count=0, pairs=1, ratio=0))

    def test_turn_distribution_empty_and_session_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'turns.jsonl'
            synthetic_log(path, [[None] * n for n in range(1, 11)] + [[]])
            report = stats.summarize([path])['round_trips']
            self.assertEqual(report['steps_per_turn'], dict(samples=11, median=5, p90=9))
            self.assertEqual(report['write_to_validation'], dict(count=0, pairs=45, ratio=0))
            self.assertEqual(report['disjoint_write_files'], dict(count=0, pairs=0, ratio=None))
            a, b = Path(directory) / 'a.jsonl', Path(directory) / 'b.jsonl'
            synthetic_log(a, [['tools.write({path: "a", content: "x"})']])
            synthetic_log(b, [['tools.bash({command: "zig build"})']])
            self.assertEqual(stats.summarize([a, b])['round_trips']['write_to_validation'],
                             dict(count=0, pairs=0, ratio=None))
        empty = stats.summarize([])
        self.assertEqual(empty['round_trips']['steps_per_turn'], dict(samples=0, median=None, p90=None))
        self.assertIn('write→validation only: 0/0 = n/a', stats.text_report(empty))

    def test_undo_notifications_do_not_start_turns(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'undo.jsonl'
            records = synthetic_log(path, [[None]])
            before = stats.summarize([path])['round_trips']['steps_per_turn']
            records.append(dict({'from': 3}, messages=[dict(role='user', source='undo', content='[undo requested]')]))
            records.append(dict({'from': 4}, messages=[dict(role='user', source='undo', content='restored: a')]))
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            self.assertEqual(stats.summarize([path])['round_trips']['steps_per_turn'], before)

    def test_group_by_profile_header(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = {}
            for name, metadata in (('old', {}), ('deepseek', dict(profile='deepseek')),
                                   ('codex', dict(profile='codex')), ('codex2', dict(profile='codex')),
                                   ('invalid', dict(profile=3))):
                paths[name] = Path(directory) / (name + '.jsonl')
                synthetic_log(paths[name], [[None]], **metadata)
            report = stats.summarize(sorted(paths.values()), group_by='profile')
            self.assertEqual({key: group['overall']['sessions'] for key, group in report['groups'].items()},
                             {'codex': 2, 'deepseek': 1, 'unknown': 2})
            cli = ['python3', str(ROOT / 'scripts/stats.py'), directory, '--group-by', 'profile']
            self.assertIn('=== profile=codex ===', subprocess.check_output(cli).decode())

    def test_group_by_header_mixed_versions_systems_patches_and_cli(self):
        write_a = 'tools.write({path: "a", content: "x"})'
        write_b = 'tools.edit({path: "b", old_text: "x", new_text: "y"})'
        verify = 'tools.bash({command: "zig build"})'
        fixtures = [
            ('legacy', {}, [write_a, verify, None]),
            ('modern', dict(nib_version='1.0', system_sha='shaA'), [write_a, write_b, verify, None]),
            ('patched', dict(nib_version='1.0', system_sha='shaB', patches_off=['b', 'a']), [write_a, verify]),
            ('reordered', dict(nib_version='2.0', system_sha='shaA', patches_off=['a', 'b', 'a']), [None]),
            ('system_only', dict(system_sha='shaB'), [write_a, verify]),
            ('version_only', dict(nib_version='2.0'), [None]),
            ('empty', dict(patches_off=[]), [None]),
            ('invalid', dict(nib_version=False, system_sha=7, patches_off=None), [None]),
            ('old_second', {}, [None])]
        expected_members = dict(
            version={'1.0': ['modern', 'patched'], '2.0': ['reordered', 'version_only'],
                     'unknown': ['legacy', 'system_only', 'empty', 'invalid', 'old_second']},
            system={'shaA': ['modern', 'reordered'], 'shaB': ['patched', 'system_only'],
                    'unknown': ['legacy', 'version_only', 'empty', 'invalid', 'old_second']},
            patches={'none': ['modern', 'system_only', 'version_only', 'empty'],
                     '["a", "b"]': ['patched', 'reordered'], 'unknown': ['legacy', 'invalid', 'old_second']})
        with tempfile.TemporaryDirectory() as directory:
            paths = {}
            for name, metadata, steps in fixtures:
                paths[name] = Path(directory) / (name + '.jsonl')
                synthetic_log(paths[name], [steps], **metadata)
            for group_by, members in expected_members.items():
                with self.subTest(group_by=group_by):
                    report = stats.summarize(sorted(paths.values()), group_by=group_by)
                    self.assertEqual(report['group_by'], group_by)
                    self.assertEqual(set(report['groups']), set(members))
                    self.assertEqual(report['overall']['sessions'], 9)
                    self.assertEqual(report['overall']['steps'], 16)
                    self.assertEqual(report['usage']['total_tokens'], 192)
                    self.assertEqual(report['round_trips']['write_to_validation'], dict(count=4, pairs=7, ratio=4/7))
                    self.assertEqual(report['round_trips']['disjoint_write_files'], dict(count=1, pairs=1, ratio=1))
                    for key, names in members.items():
                        group = report['groups'][key]
                        self.assertEqual(group, stats.summarize(sorted(paths[name] for name in names)))
                        self.assertEqual(group['overall']['sessions'], len(names))
                        self.assertEqual(group['usage']['cache_hit_rate'], .4)
                        self.assertEqual(group['timing']['step_ms']['median'], 10)
                    cli = ['python3', str(ROOT / 'scripts/stats.py'), directory, '--group-by', group_by]
                    self.assertEqual(json.loads(subprocess.check_output(cli + ['--json'])), report)
                    text = subprocess.check_output(cli).decode()
                    self.assertIn('Groups group_by=' + group_by, text)
                    for key in members:
                        self.assertIn(f'=== {group_by}={key} ===', text)
                    self.assertEqual(text.count('Steps per Turn:'), len(members) + 1)
                    self.assertEqual(text.count('write→validation only:'), len(members) + 1)
            version = stats.summarize(paths.values(), group_by='version')['groups']['1.0']
            self.assertRoundTrips(version['round_trips'], dict(
                steps_per_turn=dict(samples=2, median=3, p90=4),
                write_to_validation=dict(count=2, pairs=4, ratio=.5),
                disjoint_write_files=dict(count=1, pairs=1, ratio=1),
                mechanical_followups=mechanical_metric(2, 4)))
            patches = stats.summarize(paths.values(), group_by='patches')['groups']
            self.assertEqual(patches['none']['overall']['steps'], 8)
            self.assertEqual(patches['none']['round_trips']['steps_per_turn'], dict(samples=4, median=1.5, p90=4))
            self.assertEqual(patches['unknown']['overall']['steps'], 5)
            for path in paths.values():
                os.utime(path, (0, 0))
            empty = stats.summarize(paths.values(), since=date(2099, 1, 1), group_by='patches')
            self.assertEqual(empty['groups'], {})
            self.assertIn('No selected groups', stats.text_report(empty))
            self.assertEqual(stats.summarize(paths.values(), cwd=ROOT, group_by='version')['groups'], {})
        for metadata, expected in [({}, 'unknown'), ({'nib_version': ''}, 'unknown'),
                                   ({'system_sha': 's'}, 'none'), ({'nib_version': 'v'}, 'none'),
                                   ({'patches_off': ''}, 'none'), ({'patches_off': [3]}, 'unknown'),
                                   ({'patches_off': {}}, 'unknown'), ({'patches_off': 'one'}, 'one')]:
            self.assertEqual(stats.header_group(metadata, 'patches'), expected)
        self.assertEqual(stats.header_group({'system_sha': 's', 'patches_on': ['x']}, 'patches'), 'none on=["x"]')
        self.assertEqual(stats.header_group({'patches_off': ['b', 'a'], 'patches_on': ['y', 'x']}, 'patches'),
                         '["a", "b"] on=["x", "y"]')
        self.assertEqual(stats.header_group({'patches_on': ['x']}, 'patches'), 'unknown')
        with self.assertRaises(ValueError):
            stats.summarize([], group_by='invalid')
        cli = ['python3', str(ROOT / 'scripts/stats.py'), '--group-by', 'invalid']
        self.assertEqual(subprocess.run(cli, capture_output=True).returncode, 2)

    def test_adjacency_since_gaps_compaction_interruption_and_unknown_runs(self):
        write = 'tools.write({path: "a", content: "x"})'
        verify = 'tools.bash({command: "zig build"})'
        old = int(datetime(2025, 1, 1, 12).timestamp() * 1000)
        new = int(datetime(2025, 1, 2, 12).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'gaps.jsonl'
            records = synthetic_log(path, [[write, verify, write, verify]], nib_version='new')
            for record, at in zip(records, [old, new, old, new, new]):
                record['at'] = at
            path.write_text('\n'.join(map(json.dumps, records)))
            report = stats.summarize([path], since=date(2025, 1, 2), group_by='patches')
            self.assertEqual(set(report['groups']), {'none'})
            expected = dict(steps_per_turn=dict(samples=1, median=3, p90=3),
                            write_to_validation=dict(count=1, pairs=1, ratio=1),
                            disjoint_write_files=dict(count=0, pairs=0, ratio=None),
                            mechanical_followups=mechanical_metric(1, 1))
            self.assertRoundTrips(report['round_trips'], expected)
            self.assertRoundTrips(report['groups']['none']['round_trips'], expected)
            records = synthetic_log(path, [[write, verify, None]])
            records.insert(2, dict(records[1]))
            records[2]['messages'] = [dict(role='user', content='summary')] + records[1]['messages'][1:]
            path.write_text('\n'.join(map(json.dumps, records)))
            result = stats.summarize([path])
            self.assertEqual(result['overall']['steps'], 3)
            self.assertEqual(result['round_trips']['write_to_validation'], dict(count=1, pairs=2, ratio=.5))
            records = synthetic_log(path, [[write, verify]])
            interrupted = dict({'from': records[2]['from']},
                               messages=[dict(role='assistant', content='[interrupted by user]')])
            records[2]['from'] += 1
            records.insert(2, interrupted)
            path.write_text('\n'.join(map(json.dumps, records)))
            result = stats.summarize([path])
            self.assertEqual(result['overall']['steps'], 2)
            self.assertEqual(result['round_trips']['write_to_validation'], dict(count=0, pairs=0, ratio=None))
            records = synthetic_log(path, [[write, verify]])
            records[-1]['messages'][0]['tool_calls'].append(dict(id='other', function=dict(name='other', arguments='{}')))
            path.write_text('\n'.join(map(json.dumps, records)))
            self.assertEqual(stats.summarize([path])['round_trips']['write_to_validation'],
                             dict(count=0, pairs=1, ratio=0))
            records = synthetic_log(path, [[write, [verify, None]]])
            path.write_text('\n'.join(map(json.dumps, records)))
            self.assertEqual(stats.summarize([path])['round_trips']['write_to_validation'],
                             dict(count=0, pairs=1, ratio=0))

    def test_legacy_corrupt_compaction_and_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ('a' * 32 + '.jsonl')
            header = dict(cwd=directory, **{'from': 0}, messages=[dict(role='system', content='base')])
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(dict(
                code='await tools.bash({command: "git status; zig build"})'))))
            def step(start, output, **extra):
                return dict({'from': start, 'messages': [dict(role='user', content='hi'),
                    dict(role='assistant', tool_calls=[run]),
                    dict(role='tool', tool_call_id='r', content=output)]}, **extra)
            records = [header,
                       step(1, 'SyntaxError: unexpected token'),
                       dict({'from': 4, 'messages': [dict(role='assistant', content='done')]},
                            usage=dict(prompt_tokens=10, completion_tokens=2, prompt_cache_hit_tokens=4), ms=50),
                       {'from': 1, 'messages': [dict(role='user', content='summary')]},
                       step(2, 'Error: expected { code: string }', run_results=[dict(tool_call_id='r', ok=False)]),
                       {'from': 5, 'messages': [dict(role='assistant', content='[interrupted by user]')]}]
            path.write_text('garbage\n[]\n{"messages":null}\n' + '\n'.join(map(json.dumps, records)) +
                            '\n{"from":5,"messages":[17]}\n{"from":')
            report = stats.summarize([path])
            t = report['overall']
            self.assertEqual((t['sessions'], t['turns'], t['steps'], t['runs']), (1, 2, 3, 2))
            self.assertEqual((t['runs_failed'], t['runs_unknown'], t['run_failure_rate']), (1, 1, 1))
            self.assertEqual(report['usage']['total_tokens'], 12)
            self.assertEqual(report['usage']['cache_hit_rate'], .4)
            self.assertIsNone(t['avg_turn_ms'])
            self.assertEqual(report['tools'], {'bash': 2})
            self.assertEqual(report['errors']['interrupted']['count'], 1)
            self.assertEqual(report['errors']['js_syntax']['count'], 1)
            self.assertEqual(report['errors']['tool_arguments']['count'], 1)
            self.assertEqual(stats.summarize([path], cwd=Path(directory).resolve())['overall']['sessions'], 1)
            self.assertEqual(stats.summarize([path], cwd=ROOT)['overall']['sessions'], 0)
            os.utime(path, (0, 0))
            self.assertEqual(stats.summarize([path], since=date(2000, 1, 1))['overall']['sessions'], 0)
            cli = json.loads(subprocess.check_output(['python3', str(ROOT / 'scripts/stats.py'), '--json',
                                                     directory, str(path)]))
            self.assertEqual(cli['overall']['sessions'], 1)

    def test_since_filters_resumed_steps_not_file_mtime(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'resumed.jsonl'
            header = dict(at=cutoff - 1000, cwd=directory, **{'from': 0},
                          messages=[dict(role='system', content='base')])
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(
                dict(code='tools.bash({command: "missing_command"})'))))
            old = dict(at=cutoff - 1, **{'from': 1}, ms=100,
                       usage=dict(prompt_tokens=100, completion_tokens=20, prompt_cache_hit_tokens=50),
                       messages=[dict(role='user', content='old'),
                                 dict(role='assistant', tool_calls=[run]),
                                 dict(role='tool', tool_call_id='r', content='SyntaxError: old')],
                       run_results=[dict(tool_call_id='r', ok=False)])
            new = dict(at=cutoff, **{'from': 4}, ms=20,
                       usage=dict(prompt_tokens=10, completion_tokens=2, prompt_cache_hit_tokens=4),
                       messages=[dict(role='assistant', content='done')])
            path.write_text('\n'.join(map(json.dumps, [header, old])) + '\n')
            os.utime(path, (cutoff / 1000 + 3600,) * 2)
            self.assertEqual(stats.summarize([path], date(2025, 1, 2))['overall']['steps'], 0)
            with path.open('a') as stream:
                stream.write(json.dumps(new) + '\n')
            for mtime in (0, cutoff / 1000 + 3600):
                with self.subTest(mtime=mtime):
                    os.utime(path, (mtime,) * 2)
                    report = stats.summarize([path], date(2025, 1, 2))
                    t = report['overall']
                    self.assertEqual((t['sessions'], t['turns'], t['steps'], t['runs']), (1, 1, 1, 0))
                    self.assertEqual((t['avg_steps_per_turn'], t['timed_turns']), (1, 0))
                    self.assertIsNone(t['avg_turn_ms'])
                    self.assertEqual(report['usage']['total_tokens'], 12)
                    self.assertEqual(report['tools'], {})
                    self.assertEqual(report['errors']['js_syntax']['count'], 0)
                    self.assertEqual(report['slowest_steps'][0]['step'], 2)
                    self.assertEqual(report['time_filter'], dict(selected_records_with_at=1,
                        selected_records_using_mtime=0, selected_steps_using_mtime=0))
            unfiltered = stats.summarize([path])
            self.assertEqual(unfiltered['overall']['avg_turn_ms'], 120)

    def test_since_legacy_and_invalid_timestamps_report_fallback(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'legacy.jsonl'
            header = {'from': 0, 'messages': [dict(role='system', content='base')]}
            for at in ('missing', None, True, '1735776000000', -1, 1.5):
                with self.subTest(at=at):
                    record = dict({'from': 1}, ms=30, messages=[
                        dict(role='user', content='hi'), dict(role='assistant', content='done')])
                    if at != 'missing':
                        record['at'] = at
                    path.write_text('\n'.join(map(json.dumps, [header, record])) + '\n')
                    os.utime(path, (cutoff / 1000,) * 2)
                    report = stats.summarize([path], date(2025, 1, 2))
                    self.assertEqual(report['overall']['steps'], 1)
                    self.assertEqual(report['overall']['avg_turn_ms'], 30)
                    self.assertEqual(report['time_filter'], dict(selected_records_with_at=0,
                        selected_records_using_mtime=1, selected_steps_using_mtime=1))
                    self.assertIn('1 records using file time', stats.text_report(report))
                    os.utime(path, (cutoff / 1000 - 1,) * 2)
                    self.assertEqual(stats.summarize([path], date(2025, 1, 2))['overall']['steps'], 0)

    def test_since_mixed_records_diagnostics_interruptions_and_compaction(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.jsonl'
            records = [dict(at=cutoff - 1000, **{'from': 0},
                            messages=[dict(role='system', content='base')]),
                       dict(at=cutoff - 1, **{'from': 1}, messages=[
                           dict(role='user', content='old'), dict(role='assistant', content='old')]),
                       dict(at=cutoff, **{'from': 1}, messages=[dict(role='user', content='summary')]),
                       dict(at=cutoff, diagnostic=dict(message='new failure')),
                       dict(at=cutoff - 1, diagnostic=dict(message='old failure')),
                       dict(diagnostic=dict(message='legacy failure')),
                       dict(at=cutoff - 1, **{'from': 2}, messages=[dict(role='user', content='old'),
                           dict(role='assistant', content='[interrupted by user]')]),
                       dict(at=cutoff, **{'from': 4}, messages=[dict(role='user', content='new'),
                           dict(role='assistant', content='[interrupted by user]')]),
                       dict({'from': 6}, ms=40, messages=[
                           dict(role='user', content='legacy'), dict(role='assistant', content='ok')])]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            os.utime(path, (cutoff / 1000,) * 2)
            report = stats.summarize([path], date(2025, 1, 2))
            self.assertEqual(report['errors']['provider_failure']['count'], 2)
            self.assertEqual(report['errors']['interrupted']['count'], 1)
            t = report['overall']
            self.assertEqual((t['sessions'], t['turns'], t['steps'], t['timed_turns']), (1, 2, 1, 1))
            self.assertEqual(t['avg_turn_ms'], 40)
            self.assertEqual(report['time_filter'], dict(selected_records_with_at=2,
                selected_records_using_mtime=2, selected_steps_using_mtime=1))

    def test_since_compaction_preserves_turn_without_recounting_retained_history(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'compact.jsonl'
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(
                dict(code='tools.read({path: "missing"})'))))
            retained = [dict(role='assistant', tool_calls=[run]),
                        dict(role='tool', tool_call_id='r', content='Error: missing file')]
            for first_at, expected_steps, expected_ms in ((cutoff, 2, 120), (cutoff - 1, 1, None)):
                with self.subTest(first_at=first_at):
                    records = [dict(at=cutoff - 100, **{'from': 0},
                                    messages=[dict(role='system', content='base')]),
                               dict(at=first_at, **{'from': 1}, ms=100, messages=[
                                   dict(role='user', content='hi')] + retained,
                                   usage=dict(prompt_tokens=100, completion_tokens=20, prompt_cache_hit_tokens=0)),
                               dict(at=cutoff, **{'from': 1}, messages=[
                                   dict(role='user', content='summary')] + retained),
                               dict(at=cutoff, **{'from': 4}, ms=20,
                                    messages=[dict(role='assistant', content='done')])]
                    path.write_text('\n'.join(map(json.dumps, records)) + '\n')
                    report = stats.summarize([path], date(2025, 1, 2))
                    t = report['overall']
                    self.assertEqual((t['turns'], t['steps'], t['avg_turn_ms']),
                                     (1, expected_steps, expected_ms))
                    self.assertEqual(t['runs'], expected_steps - 1)
                    self.assertEqual(report['errors']['other_failure']['count'], expected_steps - 1)
                    self.assertEqual(report['usage']['total_tokens'], 120 if expected_steps == 2 else 0)
                    self.assertEqual(report['time_filter']['selected_records_with_at'], expected_steps)

    def test_since_interruption_selects_an_existing_turn_without_its_old_step(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'interrupted.jsonl'
            run = dict(id='r', function=dict(name='run', arguments='{}'))
            records = [dict(at=cutoff - 100, **{'from': 0},
                            messages=[dict(role='system', content='base')]),
                       dict(at=cutoff - 1, **{'from': 1}, ms=100,
                            usage=dict(prompt_tokens=100, completion_tokens=20, prompt_cache_hit_tokens=0),
                            messages=[dict(role='user', content='hi'),
                                      dict(role='assistant', tool_calls=[run]),
                                      dict(role='tool', tool_call_id='r', content='SyntaxError: old')]),
                       dict(at=cutoff, **{'from': 4},
                            messages=[dict(role='assistant', content='[interrupted by user]')])]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path], date(2025, 1, 2))
            t = report['overall']
            self.assertEqual((t['turns'], t['steps'], t['timed_turns'], t['runs']), (1, 0, 0, 0))
            self.assertEqual(report['usage']['total_tokens'], 0)
            self.assertEqual(report['errors']['interrupted']['count'], 1)
            self.assertEqual(report['errors']['js_syntax']['count'], 0)
            self.assertEqual(report['time_filter']['selected_records_with_at'], 1)

    def test_since_session_selection_for_header_diagnostic_and_replacement(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.jsonl'
            header = dict(at=cutoff - 1, **{'from': 0}, messages=[dict(role='system', content='base')])
            old = dict(at=cutoff - 1, **{'from': 1}, messages=[
                dict(role='user', content='old'), dict(role='assistant', content='done')])
            replacement = dict(at=cutoff, **{'from': 1}, messages=[dict(role='user', content='summary')])
            diagnostic = dict(at=cutoff, diagnostic=dict(message='new failure'))
            cases = [([header, old, replacement], 0, 0, 0),
                     ([header, diagnostic], 1, 1, 1),
                     ([dict(header, at=cutoff)], 1, 0, 0)]
            for records, sessions, errors, timed_records in cases:
                with self.subTest(records=records):
                    path.write_text('\n'.join(map(json.dumps, records)) + '\n')
                    report = stats.summarize([path], date(2025, 1, 2))
                    t = report['overall']
                    self.assertEqual((t['sessions'], t['turns'], t['steps']), (sessions, 0, 0))
                    self.assertEqual(report['errors']['provider_failure']['count'], errors)
                    self.assertEqual(report['time_filter']['selected_records_with_at'], timed_records)

    def test_diagnostics_do_not_match_read_source_or_successful_test_output(self):
        source = 'SyntaxError: test\nError: run timed out\nError: expected { x }\nCredentialAccessDenied'
        self.assertEqual(list(stats.diagnostics(json.dumps(dict(text=source, next_offset=None)))), [])
        self.assertEqual(list(stats.diagnostics(json.dumps(dict(exit_code=0, output='test \"Error: run timed out\" passed')))), [])
        cases = {'js_syntax': 'SyntaxError: x', 'run_timeout': 'Error: run timed out',
                 'subagent': 'Error: agent: subagent stopped due to timeout after 5 ms',
                 'tool_arguments': 'Error: read: expected { path: string }',
                 'denied': 'Error: CredentialAccessDenied', 'interrupted': 'Error: run canceled'}
        for name, text in cases.items():
            candidates = list(stats.diagnostics(text))
            self.assertTrue(any(stats.re.search(stats.ERRORS[name], s, stats.re.I) for s in candidates), name)
        self.assertIn('exit_code: 127', next(stats.diagnostics('{"exit_code":127,"output":"no command"}')))
        self.assertEqual(list(stats.diagnostics('result: "subagent: HTTP 400"')), ['subagent: HTTP 400'])

    def test_provider_diagnostic_is_not_a_step_or_context_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'diagnostic.jsonl'
            records = [dict(cwd=directory, **{'from': 0}, messages=[dict(role='system', content='base')]),
                       dict(diagnostic=dict(error_name='ProviderFailed',
                            message='Codex stream failed: invalid_prompt: bad request; the Step was not committed.',
                            attempts=1, step=1), **{'from': 0}, messages=[]),
                       dict({'from': 1}, messages=[dict(role='user', content='next'), dict(role='assistant', content='ok')],
                            usage=dict(prompt_tokens=10, completion_tokens=2, prompt_cache_hit_tokens=0))]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path])
            self.assertEqual(report['errors']['provider_failure']['count'], 1)
            self.assertIn('invalid_prompt', report['errors']['provider_failure']['examples'][0]['text'])
            self.assertEqual(report['overall']['steps'], 1)
            self.assertEqual(report['overall']['turns'], 1)
            self.assertEqual(report['usage']['total_tokens'], 12)

    def test_timing_mixed_logs_and_json_text_sections(self):
        def run(call_id, code):
            return dict(id=call_id, function=dict(name='run', arguments=json.dumps(dict(code=code))))

        old = run('old', 'await tools.bash({command: "zig build"})')
        literal = run('literal', 'await tools.bash({command: "git status --short"}); await tools.read({path: "x"})')
        dynamic = run('dynamic', 'await tools.bash({command: cmd})')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.jsonl'
            records = [dict(cwd=directory, **{'from': 0}, messages=[dict(role='system', content='base')]),
                       dict({'from': 1}, messages=[dict(role='user', content='old'),
                            dict(role='assistant', tool_calls=[old]), dict(role='tool', tool_call_id='old', content='ok')], ms=100),
                       dict({'from': 4}, messages=[dict(role='user', content='new'),
                            dict(role='assistant', tool_calls=[literal, dynamic]),
                            dict(role='tool', tool_call_id='literal', content='ok'),
                            dict(role='tool', tool_call_id='dynamic', content='ok')],
                            ms=300, model_ms=150, run_ms=100, first_data_ms=10, attempts=2,
                            code=[dict(tool_call_id='literal', first_ms=40, last_ms=90, progress=[[40, 1], [90, 100]]),
                                  dict(tool_call_id='dynamic', first_ms=60, last_ms=111)],
                            run_results=[dict(tool_call_id='dynamic', ok=False, run_ms=20),
                                         dict(tool_call_id='literal', ok=True, run_ms=80)],
                            calls=[dict(name='read', start_ms=10, end_ms=30, ok=True, run_index=1),
                                   dict(name='bash', start_ms=5, end_ms=65, ok=True, run_index=1),
                                   dict(name='bash', start_ms=0, end_ms=10, ok=False, run_index=0)], calls_omitted=3),
                       dict({'from': 8}, messages=[dict(role='assistant', content='done')], ms=0, model_ms=0,
                            run_ms=0, first_data_ms=0, attempts=1, code=[], calls=[], calls_omitted=0),
                       dict({'from': 9}, messages=[dict(role='user', content='no timing'), dict(role='assistant', content='ok')]) ]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path])
            timing = report['timing']
            self.assertEqual(report['overall']['steps'], 4)
            self.assertEqual(timing['effort']['by_effort'], {})
            self.assertEqual(timing['step_ms'], dict(samples=3, median=100, p90=300))
            self.assertEqual(timing['model_ms'], dict(samples=2, median=75, p90=150))
            self.assertEqual(timing['run_ms'], dict(samples=2, median=50, p90=100))
            self.assertEqual(timing['run_result_ms'], dict(samples=2, median=50, p90=80))
            self.assertEqual(timing['first_data_ms']['median'], 5)
            self.assertEqual(timing['code_first_ms'], dict(samples=2, median=50, p90=60))
            self.assertEqual(timing['code_span_ms'], dict(samples=2, median=50.5, p90=51))
            self.assertEqual(timing['attempts'], dict(samples=2, median=1.5, p90=2))
            self.assertEqual(timing['streaming'], dict(samples=2, over_50_ms=1, ratio=.5))
            self.assertEqual((timing['calls_steps'], timing['calls_omitted']), (2, 3))
            self.assertEqual(timing['tools'], {'bash': dict(count=2, total_ms=70, median_ms=35),
                                              'read': dict(count=1, total_ms=20, median_ms=20)})
            self.assertEqual(timing['bash'], dict(heuristic=True, sources=dict(recorded=0, static=1), matched_calls=1, unmatched_calls=1,
                             top10=[dict(command='git status', count=1, total_ms=60, median_ms=60)]))
            cli = ['python3', str(ROOT / 'scripts/stats.py'), str(path)]
            json_report = json.loads(subprocess.check_output(cli + ['--json']))
            self.assertEqual(json_report['timing'], timing)
            text = subprocess.check_output(cli).decode()
            self.assertLessEqual(len(text.split('Methodology:\n', 1)[1].splitlines()) + 1, 5)
            self.assertLessEqual(len(json_report['notes']), 4)
            for snippet in ('Timing', 'No effort records', 'step_ms: samples=3 median=100.00 p90=300.00',
                            'model_ms: samples=2', 'run_result_ms: samples=2',
                            'code_first_ms: samples=2', 'code_span_ms: samples=2',
                            'code streaming (last-first > 50 ms): 1/2 = 50.00%',
                            'bash: count=2 total=70 ms median=35.00 ms', 'omitted=3',
                            'heuristic', 'unmatched=1', 'git status: count=1 total=60 ms'):
                self.assertIn(snippet, text)

    def test_effort_groups_ignore_legacy_scheduling_fields_json_and_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'effort.jsonl'
            records = [dict(cwd=directory, **{'from': 0},
                            messages=[dict(role='system', content='base')])]
            offset = 1

            def step(effort=None, source=None, runs=(), **extra):
                nonlocal offset
                calls = [dict(id=f'r{i}', function=dict(name='run', arguments='{}'))
                         for i in range(len(runs))]
                messages = [dict(role='assistant', content='response', tool_calls=calls)]
                messages.extend(dict(role='tool', tool_call_id=f'r{i}', content='result')
                                for i in range(len(runs)))
                record = dict({'from': offset}, effort=effort, effort_source=source, messages=messages,
                              run_results=[dict(tool_call_id=f'r{i}', ok=ok) for i, ok in enumerate(runs)],
                              **extra)
                records.append(record)
                offset += len(messages)
                return record

            step('low', 'model', (True,), effort_downgraded=True, model_ms=10,
                 usage=dict(prompt_tokens=100, prompt_cache_hit_tokens=50))
            step('low', 'model', (False, False, True), effort_downgraded=None, model_ms=30,
                 usage=dict(prompt_tokens=300, completion_tokens=2, prompt_cache_hit_tokens=0))
            step('low', 'model')
            step('low', 'model', (False,), effort_downgraded=False)
            step('low', 'default', (False,), effort_downgraded=True)
            step('low', 'guard', (False,), effort_downgraded=True)
            step('low', None, (False,))
            step('medium', 'model', (None,))
            orphan = step('medium', 'model')
            orphan['run_results'] = [dict(tool_call_id='not-produced-here', ok=False)]
            step('high', 'default', (False,))
            for level in ('xhigh', 'max', 'off', 'none', 'minimal', 'default'):
                step(level, 'default')
            legacy = step()
            legacy['messages'][0]['step_effort'] = dict(effort='low', source='model')
            step('', 'model', (False,))
            step(42, 'model', (False,))
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')

            report = stats.summarize([path])
            effort = report['timing']['effort']
            groups = effort['by_effort']
            self.assertEqual(set(groups), {'low', 'medium', 'high', 'xhigh', 'max',
                                           'off', 'none', 'minimal', 'default'})
            self.assertEqual(sum(g['steps'] for g in groups.values()), 16)
            low = groups['low']
            self.assertEqual(low['steps'], 7)
            self.assertEqual(low['model_ms'], dict(samples=2, median=20, p90=30))
            self.assertEqual(low['steps_with_cache_usage'], 2)
            self.assertEqual((low['prompt_tokens'], low['prompt_cache_hit_tokens'], low['cache_hit_rate']),
                             (400, 50, .125))
            self.assertNotIn('downgraded', effort)
            self.assertTrue(all('downgraded' not in group for group in groups.values()))
            self.assertEqual(groups['high']['model_ms']['samples'], 0)
            self.assertIsNone(groups['high']['model_ms']['median'])
            self.assertIsNone(groups['high']['cache_hit_rate'])
            cli = ['python3', str(ROOT / 'scripts/stats.py'), str(path)]
            self.assertEqual(json.loads(subprocess.check_output(cli + ['--json']))['timing']['effort'], effort)
            text = subprocess.check_output(cli).decode()
            for snippet in ('Step effort', 'low: steps=7 model_ms median=20.00 samples=2',
                            'cache_hit_rate=12.50% (50/400)',
                            'high: steps=1 model_ms median=n/a samples=0 cache_hit_rate=n/a',
                            'timing.effort.by_effort'):
                self.assertIn(snippet, text)
            for snippet in ('downgraded', 'effort_downgraded'):
                self.assertNotIn(snippet, text)

    def test_effort_cache_transitions_rates_median_mean_and_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'transitions.jsonl'
            records = synthetic_log(path, [[None] * 6], provider='provider-a', model='model-a')
            levels = ['low', 'low', 'high', 'high', 'high', 'low']
            for record, level, prompt, cache in zip(records[1:], levels,
                                                    [100, 10, 20, 1000, 10, 10],
                                                    [99, 0, 5, 200, 10, 0]):
                record.update(effort=level, provider='not-the-header', model='not-the-header',
                              usage=dict(prompt_tokens=prompt, prompt_cache_hit_tokens=cache))
            path.write_text('\n'.join(map(json.dumps, records)))
            report = stats.summarize([path])
            transitions = report['timing']['effort']['cache_transitions']
            self.assertEqual(len(transitions), 1)
            group = transitions[0]
            self.assertEqual((group['provider'], group['model']), ('provider-a', 'model-a'))
            self.assertEqual(group['same_effort']['samples'], 3)
            self.assertEqual(group['same_effort']['median'], .2)
            self.assertAlmostEqual(group['same_effort']['mean'], .4)
            self.assertEqual(group['different_effort'], dict(samples=2, median=.125, mean=.125))
            self.assertEqual(report['overall']['steps_with_usage'], 0)
            self.assertEqual(report['timing']['effort']['by_effort']['high']['steps'], 3)
            text = stats.text_report(report)
            self.assertIn('provider=provider-a model=model-a', text)
            self.assertIn('same_effort: samples=3 median=20.00% mean=40.00%', text)
            self.assertIn('different_effort: samples=2 median=12.50% mean=12.50%', text)
            cli = subprocess.run(['python3', str(ROOT / 'scripts/stats.py'), str(path), '--json'],
                                 check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(cli.stdout)['timing']['effort']['cache_transitions'], transitions)
            self.assertLessEqual(len(report['notes']), 4)

    def test_effort_cache_transitions_header_groups_turn_and_session_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            cases = [({'provider': 'p', 'model': 'm'}, [[None, None], [None]], .1, False),
                     ({'provider': 'p', 'model': 'm'}, [[None, None]], .9, True),
                     ({'provider': 'p', 'model': 'n'}, [[None, None]], .3, False),
                     ({'provider': 'q', 'model': 'm'}, [[None, None]], .4, False),
                     ({}, [[None, None]], .5, False),
                     ({'provider': '  ', 'model': 7}, [[None, None]], .7, False)]
            for index, (header, turns, rate, different) in enumerate(cases):
                path = Path(directory) / f'{index}.jsonl'
                records = synthetic_log(path, turns, **header)
                for ordinal, record in enumerate(records[1:]):
                    record.update(effort='high' if different and ordinal else 'low',
                                  usage=dict(prompt_tokens=100, prompt_cache_hit_tokens=round(100 * rate)))
                path.write_text('\n'.join(map(json.dumps, records)))
                paths.append(path)
            groups = stats.summarize(paths)['timing']['effort']['cache_transitions']
            self.assertEqual([(g['provider'], g['model']) for g in groups],
                             [('p', 'm'), ('p', 'n'), ('q', 'm'), ('unknown', 'unknown')])
            self.assertEqual(groups[0]['same_effort'], dict(samples=1, median=.1, mean=.1))
            self.assertEqual(groups[0]['different_effort'], dict(samples=1, median=.9, mean=.9))
            for group, expected in zip(groups[1:], [.3, .4, .6]):
                same = group['same_effort']
                self.assertEqual(same['samples'], 2 if group['provider'] == 'unknown' else 1)
                self.assertAlmostEqual(same['median'], expected)
                self.assertAlmostEqual(same['mean'], expected)
                self.assertEqual(group['different_effort'], dict(samples=0, median=None, mean=None))

    def test_effort_cache_transitions_invalid_steps_break_adjacency(self):
        invalid = [dict(effort=value) for value in (None, '', '  ', 5, False, [], {})]
        invalid += [dict(usage=value) for value in (None, [], {},
            dict(prompt_tokens=10), dict(prompt_cache_hit_tokens=5),
            dict(prompt_tokens=True, prompt_cache_hit_tokens=5),
            dict(prompt_tokens=-1, prompt_cache_hit_tokens=5),
            dict(prompt_tokens=1.5, prompt_cache_hit_tokens=0),
            dict(prompt_tokens='10', prompt_cache_hit_tokens=5),
            dict(prompt_tokens=10, prompt_cache_hit_tokens=False),
            dict(prompt_tokens=10, prompt_cache_hit_tokens=-1),
            dict(prompt_tokens=10, prompt_cache_hit_tokens=1.5))]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'invalid.jsonl'
            for fields in invalid:
                with self.subTest(fields=fields):
                    records = synthetic_log(path, [[None] * 3])
                    for record in records[1:]:
                        record['effort'] = 'low'
                    records[2].update(fields)
                    path.write_text('\n'.join(map(json.dumps, records)))
                    self.assertEqual(stats.summarize([path])['timing']['effort']['cache_transitions'], [])
                    last = dict(records[-1], **{'from': records[-1]['from'] + len(records[-1]['messages'])})
                    records.append(last)
                    path.write_text('\n'.join(map(json.dumps, records)))
                    group, = stats.summarize([path])['timing']['effort']['cache_transitions']
                    self.assertEqual(group['same_effort'], dict(samples=1, median=.4, mean=.4))

    def test_effort_cache_transitions_zero_later_prompt_is_not_a_sample(self):
        self.assertEqual(stats.EffortStats().report()['cache_transitions'], [])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'zero.jsonl'
            records = synthetic_log(path, [[None] * 3])
            for record in records[1:]:
                record['effort'] = 'low'
            records[2]['usage'] = dict(prompt_tokens=0, prompt_cache_hit_tokens=0)
            path.write_text('\n'.join(map(json.dumps, records[:3])))
            self.assertEqual(stats.summarize([path])['timing']['effort']['cache_transitions'], [])
            path.write_text('\n'.join(map(json.dumps, records)))
            group, = stats.summarize([path])['timing']['effort']['cache_transitions']
            self.assertEqual(group['same_effort'], dict(samples=1, median=.4, mean=.4))

    def test_effort_cache_transitions_filter_interruption_and_interjections(self):
        old = int(datetime(2025, 1, 1, 12).timestamp() * 1000)
        new = int(datetime(2025, 1, 2, 12).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'selected.jsonl'
            for interrupted_at in (old, new):
                with self.subTest(interrupted_at=interrupted_at):
                    records = synthetic_log(path, [[None] * 8])
                    for ordinal, record in enumerate(records[1:], 1):
                        record.update(turn_step=ordinal, at=old if ordinal == 2 else new,
                                      effort='high' if ordinal >= 7 else 'low',
                                      usage=dict(prompt_tokens=10, prompt_cache_hit_tokens=ordinal))
                        if ordinal in (4, 7):
                            record['messages'].insert(0, dict(role='user', content='interjection'))
                    records[5]['messages'] = [dict(role='assistant', content='[interrupted by user]')]
                    records[5]['at'] = interrupted_at
                    offset = 1
                    for record in records[1:]:
                        record['from'] = offset
                        offset += len(record['messages'])
                    path.write_text('\n'.join(map(json.dumps, records)))
                    report = stats.summarize([path], since=date(2025, 1, 2))
                    self.assertEqual(report['overall']['turns'], 1)
                    group, = report['timing']['effort']['cache_transitions']
                    self.assertEqual(group['same_effort']['samples'], 2)
                    self.assertAlmostEqual(group['same_effort']['median'], .6)
                    self.assertAlmostEqual(group['same_effort']['mean'], .6)
                    self.assertEqual(group['different_effort'], dict(samples=1, median=.7, mean=.7))

    def test_effort_empty_invalid_fields_and_zero_samples(self):
        effort = stats.EffortStats()
        self.assertEqual(effort.report()['by_effort'], {})
        for value in (None, '', '  ', 5, False, [], {}):
            effort.add(dict(effort=value, effort_source='model'))
        self.assertEqual(effort.report()['by_effort'], {})
        for usage in (None, {}, dict(prompt_tokens=10), dict(prompt_cache_hit_tokens=5),
                      dict(prompt_tokens=True, prompt_cache_hit_tokens=5),
                      dict(prompt_tokens=10, prompt_cache_hit_tokens=-1)):
            effort.add(dict(effort='low', effort_source='model', effort_downgraded=False,
                            model_ms=False, usage=usage))
        effort.add(dict(effort='low', model_ms=0,
                        usage=dict(prompt_tokens=0, prompt_cache_hit_tokens=0)))
        low = effort.report()['by_effort']['low']
        self.assertEqual(low['steps'], 7)
        self.assertEqual(low['model_ms'], dict(samples=1, median=0, p90=0))
        self.assertEqual(low['steps_with_cache_usage'], 1)
        self.assertEqual(low['prompt_cache_hit_tokens'], 0)
        self.assertIsNone(low['cache_hit_rate'])

    def test_since_timing_uses_only_selected_complete_steps_text_and_json(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed-timing.jsonl'
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(
                dict(code='tools.bash({command: "git status"})'))))

            def step(start, duration, span, **extra):
                return dict({'from': start}, effort='low', effort_source='model',
                            ms=duration, model_ms=duration, run_ms=duration,
                            first_data_ms=duration, attempts=1, calls_omitted=1,
                            usage=dict(prompt_tokens=duration, completion_tokens=1, prompt_cache_hit_tokens=0),
                            code=[dict(tool_call_id='r', first_ms=duration, last_ms=duration + span)],
                            run_results=[dict(tool_call_id='r', ok=True, run_ms=duration)],
                            calls=[dict(name='bash', start_ms=0, end_ms=duration, ok=True, run_index=0)],
                            messages=[dict(role='user', content='hi'),
                                      dict(role='assistant', tool_calls=[run]),
                                      dict(role='tool', tool_call_id='r', content='ok'),
                                      dict(role='assistant', content='done')], **extra)

            poison = {key: value for key, value in step(1, 9000, 9000).items()
                      if key not in ('from', 'messages')}
            records = [dict(poison, at=cutoff, cwd=directory, **{'from': 0},
                            messages=[dict(role='system', content='base')]),
                       step(1, 1000, 1000, at=cutoff - 1),
                       step(5, 20, 50, at=cutoff),
                       step(9, 30, 51, at=cutoff + 1),
                       step(13, 40, 90, at=None),
                       dict({'from': 17}, messages=[dict(role='user', content='legacy no timing'),
                                                   dict(role='assistant', content='done')]),
                       dict(poison, at=cutoff, diagnostic=dict(message='provider failed')),
                       dict(poison, at=cutoff, **{'from': 19}, messages=[
                           dict(role='user', content='cancel'),
                           dict(role='assistant', content='[interrupted by user]')]),
                       dict(step(21, 9000, 9000, at=cutoff), repair=True),
                       dict(poison, at=cutoff, **{'from': 1},
                            messages=[dict(role='user', content='compacted'),
                                      dict(role='assistant', content='retained')])]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            for mtime, legacy_selected in ((0, False), (cutoff / 1000, True)):
                with self.subTest(mtime=mtime):
                    os.utime(path, (mtime,) * 2)
                    report = stats.summarize([path], date(2025, 1, 2))
                    timing = report['timing']
                    durations = [20, 30, 40] if legacy_selected else [20, 30]
                    count, total = len(durations), sum(durations)
                    steps = count + int(legacy_selected)
                    effort = timing['effort']
                    self.assertEqual(set(effort['by_effort']), {'low'})
                    self.assertEqual(effort['by_effort']['low']['steps'], count)
                    self.assertEqual(effort['by_effort']['low']['prompt_tokens'], total)
                    t = report['overall']
                    self.assertEqual((t['steps'], t['runs'], t['steps_with_ms'], t['steps_with_usage']),
                                     (steps, count, count, count))
                    self.assertEqual(report['usage']['total_tokens'], total + count)
                    self.assertEqual(report['tools'], {'bash': count})
                    self.assertEqual(report['errors']['provider_failure']['count'], 1)
                    self.assertEqual(report['errors']['interrupted']['count'], 1)
                    self.assertEqual(report['time_filter'], dict(selected_records_with_at=4,
                        selected_records_using_mtime=2 if legacy_selected else 0,
                        selected_steps_using_mtime=2 if legacy_selected else 0))
                    expected = dict(samples=count, median=30 if legacy_selected else 25,
                                    p90=40 if legacy_selected else 30)
                    for key in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms',
                                'first_data_ms', 'code_first_ms'):
                        self.assertEqual(timing[key], expected, key)
                    self.assertEqual(timing['attempts'], dict(samples=count, median=1, p90=1))
                    self.assertEqual(timing['code_span_ms'], dict(samples=count,
                        median=51 if legacy_selected else 50.5, p90=90 if legacy_selected else 51))
                    self.assertEqual(timing['streaming'], dict(samples=count, over_50_ms=count - 1,
                                                              ratio=(count - 1) / count))
                    self.assertEqual((timing['calls_steps'], timing['calls_omitted']), (count, count))
                    tool = dict(count=count, total_ms=total, median_ms=expected['median'])
                    self.assertEqual(timing['tools'], {'bash': tool})
                    self.assertEqual(timing['bash'], dict(heuristic=True, sources=dict(recorded=0, static=count), matched_calls=count,
                        unmatched_calls=0, top10=[dict(command='git status', **tool)]))
                    cli = [sys.executable, str(ROOT / 'scripts/stats.py'), str(path),
                           '--since', '2025-01-02']
                    self.assertEqual(json.loads(subprocess.check_output(cli + ['--json'])), report)
                    text = subprocess.check_output(cli).decode()
                    self.assertEqual(text, stats.text_report(report) + '\n')
                    for snippet in (f'Step {steps}; Run {count}', 'Timing',
                                    f'model_ms: samples={count}', f'median={expected["median"]:.2f}',
                                    'first_data_ms is the first receipt of any stream data',
                                    '--since uses record at', 'missing or invalid at falling back to file modification time'):
                        self.assertIn(snippet, text)
            excluded = stats.summarize([path], date(2025, 1, 2), cwd=ROOT)
            self.assertEqual(excluded['overall']['steps'], 0)
            self.assertEqual(excluded['timing'], stats.Timing().report())

    def test_max_gap_distribution_skips_legacy_and_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'gaps.jsonl'
            rows = synthetic_log(path, [[None] for _ in range(15)])
            for row, gap in zip(rows[1:], list(range(1, 11)) + [None, -1, True, '5']):
                row['max_gap_ms'] = gap
            rows.append(dict(diagnostic=dict(error_name='StreamIdleTimeout', message='idle timeout after 1s',
                                             attempts=5, step=16), max_gap_ms=9999))
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            report = stats.summarize([path])
            self.assertEqual(report['timing']['max_gap_ms'], dict(samples=10, median=5.5, p90=9, max=10))
            self.assertIn('max_gap_ms: samples=10 median=5.50 p90=9.00 max=10.00', stats.text_report(report))
        self.assertEqual(stats.summarize([])['timing']['max_gap_ms'],
                         dict(samples=0, median=None, p90=None, max=None))

    def test_timing_legacy_empty_and_invalid_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'legacy.jsonl'
            records = [dict({'from': 0}, messages=[dict(role='system', content='base')]),
                       dict({'from': 1}, messages=[dict(role='user', content='old'), dict(role='assistant', content='ok')], ms=42)]
            path.write_text('\n'.join(map(json.dumps, records)))
            report = stats.summarize([path])
            timing = report['timing']
            self.assertEqual(timing['step_ms'], dict(samples=1, median=42, p90=42))
            for key in ('model_ms', 'run_ms', 'run_result_ms', 'first_data_ms', 'code_first_ms', 'code_span_ms', 'attempts'):
                self.assertEqual(timing[key], dict(samples=0, median=None, p90=None))
            self.assertEqual(timing['tools'], {})
            self.assertEqual(timing['streaming'], dict(samples=0, over_50_ms=0, ratio=None))
            self.assertIn('model_ms: samples=0 median=n/a p90=n/a', stats.text_report(report))
            self.assertEqual(stats.summarize([])['timing']['step_ms']['samples'], 0)
        timing = stats.Timing()
        timing.add(dict(ms=True, model_ms=-1, run_ms='5', first_data_ms=1.2, attempts=None,
                        code=[None, {}, dict(first_ms=-1, last_ms=3), dict(first_ms=10, last_ms=9)],
                        run_results=[None, dict(run_ms=False)], calls_omitted=-1,
                        calls=[None, {}, dict(name='bash', start_ms=True, end_ms=10),
                               dict(name='read', start_ms=20, end_ms=10)]), {})
        report = timing.report()
        self.assertEqual(report['model_ms']['samples'], 0)
        self.assertEqual(report['code_first_ms']['samples'], 1)
        self.assertEqual(report['code_span_ms']['samples'], 0)
        self.assertEqual(report['tools'], {})
        self.assertEqual(report['calls_omitted'], 0)
        self.assertEqual(stats.distribution(list(range(1, 11))), dict(samples=10, median=5.5, p90=9))

    def test_bash_command_chain_groups_and_quoted_separators(self):
        cases = [
            ('zig fmt x && zig build test', 'zig fmt → zig build'),
            ('zig fmt x || zig build test; git diff | head -n 2\npwd',
             'zig fmt → zig build → git diff → head -n → pwd'),
            ('A=1 /usr/bin/zig fmt x && env zig build test', 'zig fmt → zig build'),
            ('git status --short', 'git status'),
            ('pwd > /tmp/out && git status', 'pwd → git status'),
            ('pwd 2>/tmp/err && git status', 'pwd → git status'),
            ('pwd >| /tmp/out && git status', 'pwd → git status'),
            ('> /tmp/out pwd && git status', 'pwd → git status'),
            ('echo 2 > /tmp/out && git status', 'echo 2 → git status'),
            ('echo "&&" && pwd', 'echo && → pwd'),
            ('echo ";"; echo "|"', 'echo ; → echo |'),
            ('printf x |& head -n 1', 'printf x → head -n'),
            ("cat <<EOF\nbody && fake | command\nEOF\ngit status", 'cat → git status'),
            ('echo "a && b; c | d" && git status', 'echo a && b; c | d → git status'),
            ("echo 'one\ntwo' && pwd", 'echo one\ntwo → pwd'),
            ('zig fmt x \\\n && zig build test # ignored ; rm x\ngit diff',
             'zig fmt → zig build → git diff'),
            ("python3 - <<'PY'\nprint('a; b && c | d')\nnot_a_command\nPY\nzig build test",
             'python3 - → zig build'),
            ("python3 - <<-'PY'\n\tprint('a; b')\n\tPY\ngit status", 'python3 - → git status'),
            ("python3 - <<'EOF-SCRIPT'\nprint('a && b')\nEOF-SCRIPT\nzig build", 'python3 - → zig build'),
            ("python3 - <<'123'\nprint('a; b')\n123\ngit diff", 'python3 - → git diff'),
            ("echo ok 'not a <<HEREDOC'\nzig build", 'echo ok → zig build'),
            ("python3 - <<EOF\nprint(1)\n EOF\nzig build", None),
            ('git status && echo "broken', None),
            ('git status && zig $ACTION', None),
        ]
        for command, expected in cases:
            with self.subTest(command=command):
                self.assertEqual(stats.bash_command_group(command), expected)
                code = 'tools.bash({command: ' + json.dumps(command) + '})'
                self.assertEqual(stats.bash_timing_group(code), expected)

    def test_bash_recording_priority_dynamic_calls_and_legacy_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'recorded.jsonl'
            codes = ['tools.bash({command: "git status"})',
                     'tools.bash({command: dynamic})',
                     'for (const cmd of commands) await tools.bash({command: cmd})',
                     'tools.bash({command: "cargo test"})']
            rows = synthetic_log(path, [codes])
            for row, durations in zip(rows[1:], [[180], [40], [10, 20], [30]]):
                row['calls'] = [dict(name='bash', start_ms=0, end_ms=duration, run_index=0)
                                for duration in durations]
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            recording = [dict(step=1, run=0, index=0, name='bash',
                              args=dict(command='zig fmt x && zig build test')),
                         dict(step=2, run=0, index=0, name='bash', args=dict(command='python3 tests/a.py')),
                         dict(step=3, run=0, index=1, seq=0, name='bash', args=dict(command='git diff')),
                         dict(step=3, run=0, index=0, seq=1, name='bash', args=dict(command='git status')),
                         dict(step=3, run=0, meta=dict(end='ok')),
                         dict(step=99, run=0, index=0, name='bash', args=dict(command='orphan call'))]
            calls_path = path.with_suffix('.calls.jsonl')
            calls_path.write_text('garbage\n[]\n' + '\n'.join(map(json.dumps, recording)) + '\n{')
            before = path.read_bytes(), calls_path.read_bytes()
            report = stats.summarize([path])
            bash = report['timing']['bash']
            self.assertEqual(bash['sources'], dict(recorded=4, static=1))
            self.assertEqual((bash['matched_calls'], bash['unmatched_calls']), (5, 0))
            self.assertEqual(bash['top10'], [
                dict(command='zig fmt → zig build', count=1, total_ms=180, median_ms=180),
                dict(command='python3 tests/a.py', count=1, total_ms=40, median_ms=40),
                dict(command='cargo test', count=1, total_ms=30, median_ms=30),
                dict(command='git diff', count=1, total_ms=20, median_ms=20),
                dict(command='git status', count=1, total_ms=10, median_ms=10)])
            self.assertEqual(report['tools']['bash'], 4)
            self.assertEqual(report['bash_top10'], [dict(command='cargo', count=1), dict(command='git', count=1)])
            cli = ['python3', str(ROOT / 'scripts/stats.py'), directory]
            self.assertEqual(json.loads(subprocess.check_output(cli + ['--json']))['timing']['bash'], bash)
            text = subprocess.check_output(cli).decode()
            self.assertIn('recorded=4, static=1', text)
            self.assertIn('zig fmt → zig build: count=1 total=180 ms', text)
            self.assertEqual((path.read_bytes(), calls_path.read_bytes()), before)
            calls_path.unlink()
            fallback = stats.summarize([path])['timing']['bash']
            self.assertEqual(fallback['sources'], dict(recorded=0, static=2))
            self.assertEqual((fallback['matched_calls'], fallback['unmatched_calls']), (2, 3))

    def test_bash_recording_step_numbers_survive_interruption_and_filtering(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'numbering.jsonl'
            code = 'tools.bash({command: "git status"})'
            rows = synthetic_log(path, [[code], [code], [code]])
            rows[1]['messages'][-1] = dict(role='assistant', content='[interrupted by user]')
            for index, row in enumerate(rows[1:], 1):
                row['at'] = cutoff - 1 if index < 3 else cutoff
                row['calls'] = [dict(name='bash', start_ms=0, end_ms=10, run_index=0)]
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            path.with_suffix('.calls.jsonl').write_text(json.dumps(dict(
                step=4, run=0, index=0, name='bash', args=dict(command='zig build test'))) + '\n')
            bash = stats.summarize([path], since=date(2025, 1, 2))['timing']['bash']
            self.assertEqual(bash['sources'], dict(recorded=1, static=0))
            self.assertEqual(bash['top10'][0]['command'], 'zig build')

    def test_bash_timing_literal_heuristic_and_unmatched(self):
        cases = [('tools.bash({command: "git status --short; zig build"})', 'git status → zig build'),
                 ("tools.bash({command: 'echo 你好'})", 'echo 你好'),
                 ('tools.bash({command: `zig build`})', 'zig build'),
                 ('tools.bash({command: "A=1 /usr/bin/git diff --stat"})', 'git diff'),
                 ('tools.bash({command: "pwd"})', 'pwd'),
                 ('tools.bash({command: cmd})', None),
                 ('tools.bash({command: "git " + subcommand})', None),
                 ('tools.bash({command: `git ${subcommand}`})', None),
                 ('tools.bash({command: "git $SUBCOMMAND"})', None),
                 ('tools.bash({command: "git status"}); tools.bash({command: dynamic})', None),
                 ('tools.bash({command: "echo \"broken"})', None)]
        for code, expected in cases:
            with self.subTest(code=code):
                self.assertEqual(stats.bash_timing_group(code), expected)
        timing = stats.Timing()
        result = dict(tool_call_id='r', run_ms=30)
        source = {'r': 'tools.bash({command: "git status"})'}
        timing.add(dict(run_results=[result], calls=[
            dict(name='bash', start_ms=0, end_ms=10, run_index=0),
            dict(name='bash', start_ms=10, end_ms=30, run_index=0),
            dict(name='bash', start_ms=0, end_ms=1, run_index=99),
            dict(name='bash', start_ms=0, end_ms=2, run_index=None)]), source)
        report = timing.report()
        self.assertEqual(report['bash']['matched_calls'], 0)
        self.assertEqual(report['bash']['unmatched_calls'], 4)
        self.assertEqual(report['tools']['bash']['count'], 4)

    def test_bash_timing_top10_by_total_duration(self):
        timing = stats.Timing()
        for i in range(12):
            timing.add(dict(run_results=[dict(tool_call_id='r')], calls=[
                dict(name='bash', start_ms=0, end_ms=i, run_index=0)]),
                {'r': 'tools.bash({command: ' + json.dumps('git cmd' + str(i)) + '})'})
        report = timing.report()['bash']
        self.assertEqual(report['matched_calls'], 12)
        self.assertEqual(len(report['top10']), 10)
        self.assertEqual(report['top10'][0]['command'], 'git cmd11')
        self.assertEqual(report['top10'][-1]['command'], 'git cmd2')
        timing.add(dict(run_results=[dict(tool_call_id='r')], calls=[
            dict(name='bash', start_ms=10, end_ms=30, run_index=0)]),
            {'r': 'tools.bash({command: "git cmd11 --extra"})'})
        self.assertEqual(timing.report()['bash']['top10'][0],
                         dict(command='git cmd11', count=2, total_ms=31, median_ms=15.5))

    def test_static_commands_skip_heredoc_and_redirects(self):
        command = "python3 - <<'PY'\nprint(1); not_a_command()\nPY\ngit status 2>&1; zig build"
        code = 'await tools.bash({timeout_ms: 100, command: ' + json.dumps(command) + '})'
        self.assertEqual(list(stats.commands(code)), ['python3', 'git', 'zig'])
        self.assertEqual(list(stats.commands("tools.bash({command: 'echo 你好'})")), ['echo'])


class TransportTests(unittest.TestCase):
    def test_mixed_transport_groups_steps_and_latency_without_filling_legacy_gaps(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.jsonl'
            rows = synthetic_log(path, [["1", "2", None]])
            for row, transport, model_ms, first_ms, code_ms in zip(
                    rows[1:], ('websocket', 'sse', None), (20, 80, 30), (2, 8, None), (5, 15, None)):
                row['model_ms'] = model_ms
                if transport:
                    row.update(transport=transport, first_data_ms=first_ms,
                               code=[dict(first_ms=code_ms, last_ms=code_ms + 1)])
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            report = stats.summarize([path], group_by='transport')
            self.assertEqual(report['overall']['steps'], 3)
            self.assertEqual(set(report['groups']), {'websocket', 'sse', 'unknown'})
            for name, expected in [('websocket', (20, 2, 5)), ('sse', (80, 8, 15))]:
                group = report['groups'][name]
                self.assertEqual(group['overall']['steps'], 1)
                for field, value in zip(('model_ms', 'first_data_ms', 'code_first_ms'), expected):
                    self.assertEqual(group['timing'][field]['median'], value)
                    self.assertEqual(group['timing'][field]['samples'], 1)
            legacy = report['groups']['unknown']['timing']
            self.assertEqual(legacy['first_data_ms']['samples'], 0)
            self.assertEqual(legacy['code_first_ms']['samples'], 0)
            self.assertIn('transport=websocket', stats.text_report(report))
            output = subprocess.check_output([sys.executable, str(ROOT / 'scripts/stats.py'), str(path),
                                              '--group-by', 'transport', '--json'])
            self.assertEqual(json.loads(output)['groups']['sse']['overall']['steps'], 1)

    def test_full_reason_groups(self):
        for value in (None, '', [], 12):
            self.assertEqual(stats.step_group({'full_reason': value}, 'full_reason'), 'unknown')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'reasons.jsonl'
            rows = synthetic_log(path, [["1", "2", "3", None]])
            for row, reason in zip(rows[1:], ('first_request', None, 'effort_changed', None)):
                row['full_reason'] = reason
            rows[2]['incremental'] = True
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            report = stats.summarize([path], group_by='full_reason')
            self.assertEqual({key: value['overall']['steps'] for key, value in report['groups'].items()},
                             {'first_request': 1, 'incremental': 1, 'effort_changed': 1, 'unknown': 1})
            self.assertEqual(report['groups']['incremental']['round_trips']['write_to_validation']['pairs'], 0)
            output = subprocess.check_output([sys.executable, str(ROOT / 'scripts/stats.py'), str(path),
                                              '--group-by', 'full_reason', '--json'])
            self.assertEqual(json.loads(output)['groups']['effort_changed']['overall']['steps'], 1)

    def test_incremental_groups_preserve_unknown_and_filter_step_adjacency(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.jsonl'
            rows = synthetic_log(path, [["1", "2", "3", "4", None]])
            for row, value in zip(rows[1:], (False, True, None, True, "true")):
                row['incremental'] = value
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            report = stats.summarize([path], group_by='incremental')
            self.assertEqual({key: value['overall']['steps'] for key, value in report['groups'].items()},
                             {'false': 1, 'true': 2, 'unknown': 2})
            self.assertEqual(report['groups']['true']['round_trips']['write_to_validation']['pairs'], 0)
            output = subprocess.check_output([sys.executable, str(ROOT / 'scripts/stats.py'), str(path),
                                              '--group-by', 'incremental', '--json'])
            self.assertEqual(json.loads(output)['groups']['true']['overall']['steps'], 2)


    def cache_log(self, path, *, child=False):
        rows = [dict({'from': 0}, cwd=str(path.parent), messages=[dict(role='system', content='base')])]
        if child:
            rows[0]['parent_session_id'] = 'p'
        state = dict(length=1)

        def add(messages, **fields):
            rows.append(dict({'from': state['length']}, messages=messages, **fields))
            state['length'] += len(messages)

        def step(turn_step, prompt, hit, effort='low', user=False, completion=7):
            messages = ([dict(role='user', content='go')] if user else []) + [dict(role='assistant', content='x')]
            add(messages, turn_step=turn_step, effort=effort, usage=dict(
                prompt_tokens=prompt, completion_tokens=completion, prompt_cache_hit_tokens=hit))

        step(1, 1000, 0, user=True)
        step(2, 1200, 1000)
        step(3, 1400, 1000)
        step(4, 1600, 1350)
        step(5, 1800, 1000, effort='high')
        add([dict(role='user', content='also')])
        step(6, 2000, 1000, effort='high')
        add([dict(role='user', content='result', source='background')])
        step(7, 2100, 1500, effort='high')
        rows.append(dict({'from': 1}, messages=[dict(role='user', content='summary')]))
        state['length'] = 2
        step(8, 500, 0, effort='high')
        step(1, 600, 100, effort='high', user=True)
        path.write_text('\n'.join(map(json.dumps, rows)) + '\n')

    def test_cache_breakdown_attributes_each_cause_and_tolerates_block_rounding(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cache.jsonl'
            self.cache_log(path)
            cache = stats.summarize([path])['cache']
            self.assertEqual((cache['steps'], cache['skipped_steps']), (9, 0))
            self.assertEqual(cache['prompt_tokens'], 12200)
            self.assertEqual(cache['uncached_input_tokens'], 12200 - 6950)
            self.assertEqual(cache['cached_input_tokens'], 6950)
            self.assertEqual(cache['output_tokens'], 63)
            causes = {name: item['tokens'] for name, item in cache['mid_turn_causes'].items()}
            self.assertEqual(causes, dict(effort_change=536, compaction=436, background=436,
                                          user_message=736, unknown=136))
            tokens = cache['tokens']
            self.assertEqual((tokens['session_first'], tokens['turn_start'], tokens['mid_turn']), (1000, 336, 2280))
            self.assertEqual(tokens['inherent'], 200 + 200 + 200 + 200 + 200 + 100 + 100)
            self.assertEqual(sum(tokens.values()), cache['uncached_input_tokens'])
            self.assertAlmostEqual(sum(cache['shares'].values()), 1)
            self.assertEqual([e['lost'] for e in cache['largest_losses']], [736, 536, 436, 436, 336])
            self.assertEqual(cache['largest_losses'][0], dict(
                session_id='cache', turn_step=6, previous_prompt=1800, prompt_tokens=2000,
                prompt_cache_hit_tokens=1000, lost=736, cause='user_message'))
            self.assertEqual(cache['uncached_per_turn']['samples'], 2)
            self.assertEqual((cache['uncached_per_turn']['samples'], cache['uncached_per_turn']['p90']), (2, 4750))
            text = stats.text_report(stats.summarize([path]))
            self.assertIn('Mid-turn loss by cause: effort_change 536', text)
            self.assertIn('5 largest losses', text)

    def test_cache_skips_children_missing_usage_and_filter_gaps(self):
        with tempfile.TemporaryDirectory() as directory:
            child = Path(directory) / 'child.jsonl'
            self.cache_log(child, child=True)
            self.assertEqual(stats.summarize([child])['cache']['steps'], 0)
            path = Path(directory) / 'old.jsonl'
            rows = synthetic_log(path, [["1", "2", "3", "4"]])
            for number, row in enumerate(rows[1:], 1):
                row['turn_step'] = number
            rows[2].pop('usage')
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            cache = stats.summarize([path])['cache']
            self.assertEqual((cache['steps'], cache['skipped_steps']), (2, 1))
            self.assertIsNone(stats.summarize([child])['cache']['hit_rate'])

    def test_cache_section_follows_group_by_and_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cache.jsonl'
            self.cache_log(path)
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            rows[0]['nib_version'] = '1.0.0'
            path.write_text('\n'.join(map(json.dumps, rows)) + '\n')
            output = subprocess.check_output([sys.executable, str(ROOT / 'scripts/stats.py'), str(path),
                                              '--group-by', 'version', '--json'])
            report = json.loads(output)
            self.assertEqual(report['cache']['steps'], 9)
            self.assertEqual(report['groups']['1.0.0']['cache']['tokens']['mid_turn'], 2280)


if __name__ == '__main__':
    unittest.main()
