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
from unittest.mock import patch

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


class StatsTest(unittest.TestCase):
    def test_calls_sidecar_is_never_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ('a' * 32 + '.jsonl')
            calls = path.with_suffix('.calls.jsonl')
            synthetic_log(path, [[None]])
            synthetic_log(calls, [[None]], private_marker='PRIVATE_CALLS_CONTENT')
            original_open = Path.open

            def open_main_only(file, *args, **kwargs):
                self.assertNotEqual(file, calls, 'stats must not open the private sidecar')
                return original_open(file, *args, **kwargs)

            with patch.object(Path, 'open', open_main_only):
                self.assertEqual(list(stats.records(calls)), [])
                report = stats.summarize([path, calls])
            self.assertEqual(report['overall']['sessions'], 1)
            self.assertNotIn('PRIVATE_CALLS_CONTENT', json.dumps(report))
            for inputs in ([directory], [str(path), str(calls)]):
                output = subprocess.check_output([sys.executable, str(ROOT / 'scripts/stats.py'), *inputs, '--json'])
                self.assertEqual(json.loads(output)['overall']['sessions'], 1)
                self.assertNotIn(b'PRIVATE_CALLS_CONTENT', output)

    def assertRoundTrips(self, actual, expected):
        self.assertEqual(len(actual["notes"]), 2)
        self.assertEqual({key: value for key, value in actual.items() if key != "notes"}, expected)

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
                            disjoint_write_files=dict(count=2, pairs=5, ratio=.4))
            self.assertRoundTrips(report['round_trips'], expected)
            self.assertEqual(report['overall']['steps'], 19)
            cli = ['python3', str(ROOT / 'scripts/stats.py'), str(path)]
            result = json.loads(subprocess.check_output(cli + ['--json']))
            self.assertRoundTrips(result['round_trips'], expected)
            text = subprocess.check_output(cli).decode()
            self.assertIn('往返结构：', text)
            self.assertIn('每 Turn Step: samples=3 median=7.00 p90=7.00', text)
            self.assertIn('写→仅验证: 2/16 = 12.50%', text)
            self.assertIn('连续写不同文件（不相交）: 2/5 = 40.00%', text)
            self.assertEqual(path.read_bytes(), before)

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
                          'cargo test --all', 'git diff --stat', 'pytest -q', 'diff a b',
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
                         'tools.bash({command: "git status"})',
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
        self.assertIn('写→仅验证: 0/0 = n/a', stats.text_report(empty))

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
                    self.assertIn('分组 group_by=' + group_by, text)
                    for key in members:
                        self.assertIn(f'=== {group_by}={key} ===', text)
                    self.assertEqual(text.count('每 Turn Step:'), len(members) + 1)
                    self.assertEqual(text.count('写→仅验证:'), len(members) + 1)
            version = stats.summarize(paths.values(), group_by='version')['groups']['1.0']
            self.assertRoundTrips(version['round_trips'], dict(
                steps_per_turn=dict(samples=2, median=3, p90=4),
                write_to_validation=dict(count=2, pairs=4, ratio=.5),
                disjoint_write_files=dict(count=1, pairs=1, ratio=1)))
            patches = stats.summarize(paths.values(), group_by='patches')['groups']
            self.assertEqual(patches['none']['overall']['steps'], 8)
            self.assertEqual(patches['none']['round_trips']['steps_per_turn'], dict(samples=4, median=1.5, p90=4))
            self.assertEqual(patches['unknown']['overall']['steps'], 5)
            for path in paths.values():
                os.utime(path, (0, 0))
            empty = stats.summarize(paths.values(), since=date(2099, 1, 1), group_by='patches')
            self.assertEqual(empty['groups'], {})
            self.assertIn('无入选分组', stats.text_report(empty))
            self.assertEqual(stats.summarize(paths.values(), cwd=ROOT, group_by='version')['groups'], {})
        for metadata, expected in [({}, 'unknown'), ({'nib_version': ''}, 'unknown'),
                                   ({'system_sha': 's'}, 'none'), ({'nib_version': 'v'}, 'none'),
                                   ({'patches_off': ''}, 'none'), ({'patches_off': [3]}, 'unknown'),
                                   ({'patches_off': {}}, 'unknown'), ({'patches_off': 'one'}, 'one')]:
            self.assertEqual(stats.header_group(metadata, 'patches'), expected)
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
                            disjoint_write_files=dict(count=0, pairs=0, ratio=None))
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
                    self.assertIn('1 条回退文件时间', stats.text_report(report))
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
            self.assertIsNone(timing['effort']['downgraded']['run_failure_rate'])
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
            self.assertEqual(timing['bash'], dict(heuristic=True, matched_calls=1, unmatched_calls=1,
                             top10=[dict(command='git status', count=1, total_ms=60, median_ms=60)]))
            cli = ['python3', str(ROOT / 'scripts/stats.py'), str(path)]
            json_report = json.loads(subprocess.check_output(cli + ['--json']))
            self.assertEqual(json_report['timing'], timing)
            text = subprocess.check_output(cli).decode()
            self.assertLessEqual(len(text.split('口径：\n', 1)[1].splitlines()) + 1, 5)
            self.assertLessEqual(len(json_report['notes']), 4)
            for snippet in ('计时 Timing', '无 effort 记录', 'step_ms: samples=3 median=100.00 p90=300.00',
                            'model_ms: samples=2', 'run_result_ms: samples=2',
                            'code_first_ms: samples=2', 'code_span_ms: samples=2',
                            'code streaming (last-first > 50 ms): 1/2 = 50.00%',
                            'bash: count=2 total=70 ms median=35.00 ms', 'omitted=3',
                            'heuristic', 'unmatched=1', 'git status: count=1 total=60 ms'):
                self.assertIn(snippet, text)

    def test_effort_groups_downgraded_same_step_run_failures_json_and_text(self):
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
            self.assertEqual(low['downgraded'], dict(steps=3, steps_with_runs=2, steps_with_failed_run=1,
                steps_with_unknown_run_status=0, run_failure_rate=.5))
            self.assertEqual(groups['medium']['downgraded'], dict(steps=2, steps_with_runs=1,
                steps_with_failed_run=0, steps_with_unknown_run_status=1, run_failure_rate=0))
            self.assertEqual(effort['downgraded'], dict(steps=5, steps_with_runs=3, steps_with_failed_run=1,
                steps_with_unknown_run_status=1, run_failure_rate=1 / 3))
            self.assertEqual(groups['high']['model_ms']['samples'], 0)
            self.assertIsNone(groups['high']['model_ms']['median'])
            self.assertIsNone(groups['high']['cache_hit_rate'])
            self.assertIsNone(groups['high']['downgraded']['run_failure_rate'])
            cli = ['python3', str(ROOT / 'scripts/stats.py'), str(path)]
            self.assertEqual(json.loads(subprocess.check_output(cli + ['--json']))['timing']['effort'], effort)
            text = subprocess.check_output(cli).decode()
            for snippet in ('Step effort', 'low: steps=7 model_ms median=20.00 samples=2',
                            'cache_hit_rate=12.50%（50/400）', '本 Step Run 失败 1/2 = 50.00%',
                            '降档 Step 合计 5；本 Step Run 失败 1/3 = 33.33%',
                            'high: steps=1 model_ms median=n/a samples=0 cache_hit_rate=n/a',
                            'timing.effort.by_effort', 'steps_with_failed_run/steps_with_runs',
                            'effort_downgraded', '未知状态仍入分母'):
                self.assertIn(snippet, text)

    def test_effort_empty_invalid_fields_and_zero_samples(self):
        effort = stats.EffortStats()
        self.assertEqual(effort.report()['by_effort'], {})
        self.assertIsNone(effort.report()['downgraded']['run_failure_rate'])
        for value in (None, '', '  ', 5, False, [], {}):
            effort.add(dict(effort=value, effort_source='model'), [False])
        self.assertEqual(effort.report()['by_effort'], {})
        for usage in (None, {}, dict(prompt_tokens=10), dict(prompt_cache_hit_tokens=5),
                      dict(prompt_tokens=True, prompt_cache_hit_tokens=5),
                      dict(prompt_tokens=10, prompt_cache_hit_tokens=-1)):
            effort.add(dict(effort='low', effort_source='model', effort_downgraded=False,
                            model_ms=False, usage=usage), [False])
        effort.add(dict(effort='low', model_ms=0,
                        usage=dict(prompt_tokens=0, prompt_cache_hit_tokens=0)), [])
        low = effort.report()['by_effort']['low']
        self.assertEqual(low['steps'], 7)
        self.assertEqual(low['model_ms'], dict(samples=1, median=0, p90=0))
        self.assertEqual(low['steps_with_cache_usage'], 1)
        self.assertEqual(low['prompt_cache_hit_tokens'], 0)
        self.assertIsNone(low['cache_hit_rate'])
        self.assertEqual(low['downgraded']['steps'], 0)

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
                    self.assertEqual(effort['downgraded'], dict(steps=count, steps_with_runs=count,
                        steps_with_failed_run=0, steps_with_unknown_run_status=0, run_failure_rate=0))
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
                    self.assertEqual(timing['bash'], dict(heuristic=True, matched_calls=count,
                        unmatched_calls=0, top10=[dict(command='git status', **tool)]))
                    cli = [sys.executable, str(ROOT / 'scripts/stats.py'), str(path),
                           '--since', '2025-01-02']
                    self.assertEqual(json.loads(subprocess.check_output(cli + ['--json'])), report)
                    text = subprocess.check_output(cli).decode()
                    self.assertEqual(text, stats.text_report(report) + '\n')
                    for snippet in (f'Step {steps}；Run {count}', '计时 Timing',
                                    f'model_ms: samples={count}', f'median={expected["median"]:.2f}',
                                    'first_data_ms 是首次收到任何流数据',
                                    '--since 按记录 at', '缺失或无效 at 回退到文件修改时间'):
                        self.assertIn(snippet, text)
            excluded = stats.summarize([path], date(2025, 1, 2), cwd=ROOT)
            self.assertEqual(excluded['overall']['steps'], 0)
            self.assertEqual(excluded['timing'], stats.Timing().report())

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

    def test_bash_timing_literal_heuristic_and_unmatched(self):
        cases = [('tools.bash({command: "git status --short; zig build"})', 'git status'),
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


if __name__ == '__main__':
    unittest.main()
