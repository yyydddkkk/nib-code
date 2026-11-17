"""SQLite metrics import without models, nib binaries, or tool recordings."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('stats_db', ROOT / 'scripts/stats_db.py')
stats_db = importlib.util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(stats_db)


class StatsDatabaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.path = self.root / 'session.jsonl'
        self.database = self.root / 'stats.sqlite3'
        self.db = stats_db.open_database(self.database)
        self.addCleanup(self.db.close)

    def records(self):
        return [
            dict({'from': 0}, messages=[dict(role='system', content='SECRET_SYSTEM')], at=1000,
                 cwd=str(self.root), nib_version='0.14.0+test', provider='codex', model='model',
                 system_sha='abc', profile='profile', tuning=dict(delivery='user'), patches_off=[]),
            dict({'from': 1}, messages=[dict(role='user', content='SECRET_PROMPT')], at=2000),
            dict({'from': 2}, messages=[
                dict(role='assistant', tool_calls=[dict(id='call1', function=dict(
                    name='run', arguments='SECRET_JS'))]),
                dict(role='tool', tool_call_id='call1', content='SECRET_OUTPUT')],
                at=3000, ms=100, model_ms=60, run_ms=30, tool_bytes=99, output_bytes=10,
                usage=dict(prompt_tokens=20, completion_tokens=5, prompt_cache_hit_tokens=10),
                turn_step=1, effort='high', transport='websocket', incremental=True,
                run_results=[dict(tool_call_id='call1', ok=True, run_ms=30, tool_bytes=99,
                                  output_bytes=10, calls_omitted=2)],
                calls=[dict(name='read', start_ms=1, end_ms=4, ok=True, run_index=0,
                            result_bytes=99, dispatched=True, path='SECRET_FILE')]),
            dict({'from': 4}, messages=[dict(role='assistant', content='SECRET_ANSWER')],
                 at=4000, ms=20, model_ms=20),
        ]

    def write(self, records, path=None):
        (path or self.path).write_text(''.join(json.dumps(record) + '\n' for record in records))

    def rows(self, table):
        return self.db.execute(f'SELECT * FROM {table}').fetchall()

    def test_normalized_metrics_privacy_and_permissions(self):
        self.write(self.records())
        self.assertEqual(stats_db.import_session(self.db, self.path), 'imported')
        self.assertEqual(len(self.rows('sessions')), 1)
        self.assertEqual(self.db.execute('SELECT step, status, at_ms, time_source, ms, model_ms, '
                                        'prompt_tokens, incremental FROM steps ORDER BY step').fetchall(),
                         [(1, 'complete', 3000, 'record', 100, 60, 20, 1),
                          (2, 'complete', 4000, 'record', 20, 20, None, None)])
        self.assertEqual(self.db.execute('SELECT phase, ok, run_ms, calls_omitted FROM runs').fetchall(),
                         [('foreground', 1, 30, 2)])
        self.assertEqual(self.db.execute('SELECT name, duration_ms, ok, result_bytes FROM tool_calls').fetchall(),
                         [('read', 3, 1, 99)])
        dump = '\n'.join(self.db.iterdump())
        self.assertNotIn('SECRET_', dump)
        self.assertNotIn(b'SECRET_', self.database.read_bytes())
        self.assertEqual(self.database.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.db.execute('PRAGMA user_version').fetchone()[0], stats_db.SCHEMA_VERSION)

    def test_unchanged_append_rebuild_and_truncation(self):
        records = self.records()
        self.write(records)
        stats_db.import_session(self.db, self.path)
        with mock.patch.object(Path, 'open', side_effect=AssertionError('unchanged source reopened')):
            self.assertEqual(stats_db.import_session(self.db, self.path), 'unchanged')
        with self.path.open('a') as stream:
            stream.write(json.dumps(dict({'from': 5}, messages=[dict(role='assistant', content='extra')])) + '\n')
        self.assertEqual(stats_db.import_session(self.db, self.path), 'imported')
        self.assertEqual(len(self.rows('steps')), 3)
        self.assertEqual(stats_db.import_session(self.db, self.path, rebuild=True), 'imported')
        self.assertEqual(len(self.rows('steps')), 3)
        self.write(records[:1])
        stats_db.import_session(self.db, self.path)
        self.assertEqual(self.rows('steps'), [])
        self.assertEqual(self.rows('runs'), [])
        self.assertEqual(self.rows('tool_calls'), [])

    def test_failed_import_rolls_back_previous_session(self):
        self.write(self.records())
        stats_db.import_session(self.db, self.path)
        before = list(self.db.iterdump())
        self.write([dict(messages=[], diagnostic=dict(error_name='Error'))])
        with self.assertRaisesRegex(ValueError, 'header'):
            stats_db.import_session(self.db, self.path)
        self.assertEqual(list(self.db.iterdump()), before)
        self.write(self.records())
        original = stats_db.fingerprint
        calls = 0

        def changed(stat):
            nonlocal calls
            calls += 1
            result = original(stat)
            return (result[0], result[1] + 1, *result[2:]) if calls == 3 else result

        with mock.patch.object(stats_db, 'fingerprint', side_effect=changed):
            with self.assertRaisesRegex(ValueError, 'changed'):
                stats_db.import_session(self.db, self.path, rebuild=True)
        self.assertEqual(list(self.db.iterdump()), before)

    def test_corrupt_lines_and_incomplete_tail(self):
        self.write(self.records()[:3])
        with self.path.open('ab') as stream:
            stream.write(b'bad json\n[]\n\xff\n{"from":4,"messages":[')
        stats_db.import_session(self.db, self.path)
        self.assertEqual(self.db.execute('SELECT invalid_lines, pending_bytes FROM sessions').fetchone(),
                         (3, len(b'{"from":4,"messages":[')))
        self.assertEqual(len(self.rows('steps')), 1)
        with self.path.open('ab') as stream:
            stream.write(b'{"role":"assistant","content":"done"}]}\n')
        stats_db.import_session(self.db, self.path)
        self.assertEqual(len(self.rows('steps')), 2)
        self.assertEqual(self.db.execute('SELECT pending_bytes FROM sessions').fetchone(), (0,))

    def test_compaction_repair_diagnostic_and_interruption(self):
        records = self.records()
        records.extend([
            dict({'from': 0}, messages=[dict(role='system', content='summary'),
                                       dict(role='assistant', content='retained')]),
            dict(repair=True),
            dict(diagnostic=dict(error_name='ProviderFailure', message='SECRET_ERROR', step=3, attempts=2), at=5000),
            dict({'from': 2}, messages=[dict(role='assistant', content='[interrupted by user]')], at=6000),
            dict({'from': 3}, messages=[dict(role='assistant', content='resumed')], at=7000),
        ])
        self.write(records)
        stats_db.import_session(self.db, self.path)
        self.assertEqual(self.db.execute('SELECT step, status FROM steps').fetchall(),
                         [(1, 'complete'), (2, 'complete'), (3, 'interrupted'), (4, 'complete')])
        self.assertEqual(self.db.execute('SELECT error_name, attempts, step FROM diagnostics').fetchone(),
                         ('ProviderFailure', 2, 3))
        self.assertNotIn('SECRET_ERROR', '\n'.join(self.db.iterdump()))

    def test_background_completion_once_and_child_separation(self):
        records = self.records()[:3]
        records[2]['run_results'][0].update(background_id='r1', ok=True)
        records[2]['calls'] = []
        result = dict(step=1, run_index=0, ok=False, run_ms=200, tool_bytes=80, calls_omitted=1,
                      calls=[dict(name='bash', start_ms=2, end_ms=190, ok=True, run_index=0)])
        records.extend([
            dict(background=dict(id='r1', kind='run', state='finished', completion=result)),
            dict({'from': 4}, messages=[dict(role='user', source='background', background_id='r1',
                                            content='SECRET_BACKGROUND', background_run=result)], at=5000),
        ])
        self.write(records)
        child = self.root / 'child.jsonl'
        child_records = self.records()
        child_records[0]['parent_session_id'] = 'session'
        self.write(child_records, child)
        stats_db.import_session(self.db, self.path)
        stats_db.import_session(self.db, child)
        self.assertEqual(self.db.execute('SELECT phase, ok, run_ms FROM runs WHERE session_path = ? ORDER BY id',
                                        (str(self.path),)).fetchall(),
                         [('background_start', None, 30), ('background', 0, 200)])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM steps JOIN sessions '
                                        'ON sessions.path = steps.session_path '
                                        'WHERE sessions.parent_session_id IS NULL').fetchone(), (1,))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM tool_calls').fetchone(), (2,))

    def test_background_lifecycle_completions_with_tool_delivery(self):
        for delivery in ('wait', 'fold', 'user_first'):
            with self.subTest(delivery=delivery):
                records = self.records()[:3]
                records[2]['run_results'][0]['background_id'] = 'r1'
                records[2]['calls'] = []
                result = dict(step=1, run_index=0, ok=False, run_ms=200, tool_bytes=80,
                              calls_omitted=1, calls=[dict(name='bash', start_ms=2, end_ms=190,
                                                          ok=True, run_index=0, result_bytes=80)])
                lifecycle = dict(background=dict(id='r1', kind='run', state='finished',
                                                 completion=result), at=5000)
                if delivery == 'user_first':
                    records.append(dict({'from': 4}, messages=[dict(
                        role='user', background_id='r1', background_run=result)], at=5000))
                elif delivery == 'fold':
                    records[2]['messages'][1]['content'] += '\n[background result]'
                records.extend([lifecycle, lifecycle])
                self.write(records)
                stats_db.import_session(self.db, self.path, rebuild=True)
                self.assertEqual(self.db.execute(
                    'SELECT step, run_index, phase, ok, run_ms, tool_bytes, background_id '
                    'FROM runs ORDER BY id').fetchall(),
                    [(1, 0, 'background_start', None, 30, 99, 'r1'),
                     (1, 0, 'background', 0, 200, 80, 'r1')])
                self.assertEqual(self.db.execute(
                    'SELECT name, duration_ms, result_bytes FROM tool_calls').fetchall(),
                    [('bash', 188, 80)])

    def test_model_switch_before_first_step_replaces_session_metadata(self):
        records = self.records()
        replacement = dict(records[0], model='switched', provider='anthropic', profile='other',
                           system_sha='new-sha', tuning=dict(delivery='tool'),
                           patches_off=['patch'], at=2500)
        records.insert(2, replacement)
        records[3]['from'] = 1
        records[4]['from'] = 3
        compacted = dict(replacement, model='not-a-model-switch')
        records.append(compacted)
        self.write(records)
        for rebuild in (False, True):
            stats_db.import_session(self.db, self.path, rebuild=rebuild)
            self.assertEqual(self.db.execute(
                'SELECT model, provider, profile, system_sha, tuning, patches_off, at_ms '
                'FROM sessions').fetchone(),
                ('switched', 'anthropic', 'other', 'new-sha', '{"delivery": "tool"}',
                 '["patch"]', 2500))
            self.assertEqual(len(self.rows('steps')), 2)

    def test_unknown_is_null_not_success_or_zero(self):
        records = self.records()[:3]
        record = records[2]
        record.pop('at')
        record['ms'] = True
        record['model_ms'] = -1
        record['usage']['prompt_tokens'] = 2 ** 100
        record['incremental'] = 1
        record['run_results'] = []
        record['calls'][0].update(start_ms=10, end_ms=1, ok='true', dispatched=None)
        self.write(records)
        stats_db.import_session(self.db, self.path)
        self.assertEqual(self.db.execute('SELECT ms, model_ms, prompt_tokens, incremental, time_source FROM steps').fetchone(),
                         (None, None, None, None, 'mtime'))
        self.assertEqual(self.db.execute('SELECT ok, run_ms FROM runs').fetchone(), (None, None))
        self.assertEqual(self.db.execute('SELECT duration_ms, ok, dispatched FROM tool_calls').fetchone(),
                         (None, None, None))

    def test_foreign_and_future_database_rejected_without_changes(self):
        foreign = self.root / 'foreign.sqlite3'
        with sqlite3.connect(foreign) as db:
            db.execute('CREATE TABLE important (value TEXT)')
            db.execute("INSERT INTO important VALUES ('keep')")
        before = foreign.read_bytes()
        with self.assertRaisesRegex(ValueError, 'supported'):
            stats_db.open_database(foreign)
        self.assertEqual(foreign.read_bytes(), before)
        with self.db:
            self.db.execute('PRAGMA user_version = 99')
        with self.assertRaisesRegex(ValueError, 'supported'):
            stats_db.open_database(self.database)
        self.assertEqual(self.db.execute('PRAGMA user_version').fetchone(), (99,))

    def test_cli_default_home_dedup_sidecars_and_errors(self):
        sessions = self.root / 'sessions'
        sessions.mkdir()
        self.path = sessions / 'session.jsonl'
        self.write(self.records())
        sidecar = sessions / 'session.calls.jsonl'
        sidecar.write_text('SECRET_SIDECAR')
        (sessions / 'alias.jsonl').symlink_to(sidecar)
        command = [sys.executable, str(ROOT / 'scripts/stats_db.py')]
        env = dict(os.environ, NIB_HOME=str(self.root))
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'imported=1 unchanged=0 failed=0')
        result = subprocess.run(command + [str(sessions), str(self.path), str(sidecar)], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'imported=0 unchanged=1 failed=0')
        self.assertNotIn('SECRET_SIDECAR', '\n'.join(self.db.iterdump()))
        broken = sessions / 'broken.jsonl'
        broken.write_text('broken\n')
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('failed=1', result.stdout)
        self.assertIn('no complete Session header', result.stderr)
        self.assertEqual(len(self.rows('sessions')), 1)
        result = subprocess.run(command + [str(self.root / 'missing')], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('not a Session file or directory', result.stderr)


if __name__ == '__main__':
    unittest.main()
