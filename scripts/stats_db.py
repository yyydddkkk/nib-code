#!/usr/bin/env python3
"""Build a local, rebuildable SQLite metrics index from nib Session logs."""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import sys


APPLICATION_ID = 0x4E494253
SCHEMA_VERSION = 1
SCHEMA = (
    """CREATE TABLE sessions (
        path TEXT PRIMARY KEY, session_id TEXT NOT NULL, parent_session_id TEXT,
        cwd TEXT, nib_version TEXT, provider TEXT, model TEXT, profile TEXT,
        system_sha TEXT, tuning TEXT, patches_off TEXT, at_ms INTEGER,
        source_identity TEXT NOT NULL, source_size INTEGER NOT NULL,
        source_mtime_ns INTEGER NOT NULL, source_ctime_ns INTEGER NOT NULL,
        source_lines INTEGER NOT NULL DEFAULT 0, invalid_lines INTEGER NOT NULL DEFAULT 0,
        pending_bytes INTEGER NOT NULL DEFAULT 0
    )""",
    """CREATE TABLE steps (
        session_path TEXT NOT NULL REFERENCES sessions(path) ON DELETE CASCADE,
        step INTEGER NOT NULL, source_line INTEGER NOT NULL, at_ms INTEGER,
        time_source TEXT NOT NULL, status TEXT NOT NULL, turn_step INTEGER, effort TEXT,
        ms INTEGER, model_ms INTEGER, run_ms INTEGER, tool_bytes INTEGER, output_bytes INTEGER,
        prompt_tokens INTEGER, completion_tokens INTEGER, prompt_cache_hit_tokens INTEGER,
        prompt_cache_write_tokens INTEGER, transport TEXT, incremental INTEGER,
        input_items INTEGER, input_bytes INTEGER, full_reason TEXT, calls_omitted INTEGER,
        PRIMARY KEY (session_path, step)
    )""",
    """CREATE TABLE runs (
        id INTEGER PRIMARY KEY,
        session_path TEXT NOT NULL REFERENCES sessions(path) ON DELETE CASCADE,
        source_line INTEGER NOT NULL, step INTEGER NOT NULL, run_index INTEGER NOT NULL,
        phase TEXT NOT NULL, at_ms INTEGER, time_source TEXT NOT NULL,
        tool_call_id TEXT, background_id TEXT, ok INTEGER, run_ms INTEGER,
        tool_bytes INTEGER, output_bytes INTEGER, calls_omitted INTEGER
    )""",
    """CREATE TABLE tool_calls (
        run_id INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        call_index INTEGER NOT NULL, name TEXT NOT NULL, start_ms INTEGER, end_ms INTEGER,
        duration_ms INTEGER, ok INTEGER, result_bytes INTEGER, dispatched INTEGER,
        background INTEGER, task_id TEXT, PRIMARY KEY (run_id, call_index)
    )""",
    """CREATE TABLE diagnostics (
        session_path TEXT NOT NULL REFERENCES sessions(path) ON DELETE CASCADE,
        source_line INTEGER NOT NULL, at_ms INTEGER, time_source TEXT NOT NULL,
        error_name TEXT, attempts INTEGER, step INTEGER,
        PRIMARY KEY (session_path, source_line)
    )""",
    'CREATE INDEX sessions_version ON sessions(nib_version)',
    'CREATE INDEX sessions_parent ON sessions(parent_session_id)',
    'CREATE INDEX steps_time ON steps(at_ms)',
    'CREATE INDEX runs_session_step ON runs(session_path, step, run_index)',
    'CREATE INDEX tool_calls_name ON tool_calls(name)',
)


def integer(value):
    return value if type(value) is int and 0 <= value <= 0x7FFFFFFFFFFFFFFF else None


def text(value):
    return value if isinstance(value, str) else None


def boolean(value):
    return int(value) if type(value) is bool else None


def objects(value):
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


def insert(db, table, values):
    columns = ', '.join(values)
    placeholders = ', '.join('?' for _ in values)
    return db.execute(f'INSERT INTO {table} ({columns}) VALUES ({placeholders})', tuple(values.values())).lastrowid


def open_database(path):
    path = Path(path).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        pass
    else:
        os.close(fd)
    db = sqlite3.connect(path, timeout=1)
    try:
        app_id = db.execute('PRAGMA application_id').fetchone()[0]
        version = db.execute('PRAGMA user_version').fetchone()[0]
        tables = db.execute("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").fetchall()
        if app_id == 0 and version == 0 and not tables:
            with db:
                db.execute('BEGIN IMMEDIATE')
                for statement in SCHEMA:
                    db.execute(statement)
                db.execute(f'PRAGMA application_id = {APPLICATION_ID}')
                db.execute(f'PRAGMA user_version = {SCHEMA_VERSION}')
        elif app_id != APPLICATION_ID or version != SCHEMA_VERSION:
            raise ValueError('not a supported nib metrics database; use a new database path')
        db.execute('PRAGMA foreign_keys = ON')
        return db
    except Exception:
        db.close()
        raise


def fingerprint(stat):
    return (f'{stat.st_dev}:{stat.st_ino}', stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)


def timestamp(record, mtime_ns):
    at = integer(record.get('at'))
    return (at, 'record') if at is not None else (mtime_ns // 1_000_000, 'mtime')


def add_calls(db, run_id, calls):
    for index, call in enumerate(calls):
        name = text(call.get('name'))
        if name is None:
            continue
        start, end = integer(call.get('start_ms')), integer(call.get('end_ms'))
        duration = end - start if start is not None and end is not None and end >= start else None
        insert(db, 'tool_calls', dict(
            run_id=run_id, call_index=index, name=name, start_ms=start, end_ms=end,
            duration_ms=duration, ok=boolean(call.get('ok')),
            result_bytes=integer(call.get('result_bytes')), dispatched=boolean(call.get('dispatched')),
            background=boolean(call.get('background')), task_id=text(call.get('id'))))


def add_run(db, path, line, step, index, phase, at, time_source, result, calls, call_id=None, background_id=None):
    run_id = insert(db, 'runs', dict(
        session_path=path, source_line=line, step=step, run_index=index, phase=phase,
        at_ms=at, time_source=time_source, tool_call_id=call_id, background_id=background_id,
        ok=None if phase == 'background_start' else boolean(result.get('ok')),
        **{key: integer(result.get(key)) for key in ('run_ms', 'tool_bytes', 'output_bytes', 'calls_omitted')}))
    add_calls(db, run_id, calls)


def add_foreground_runs(db, path, line, step, record, messages, at, time_source):
    calls = [call for message in messages if message.get('role') == 'assistant'
             for call in objects(message.get('tool_calls'))]
    results = {item['tool_call_id']: item for item in objects(record.get('run_results'))
               if isinstance(item.get('tool_call_id'), str)}
    details = objects(record.get('calls'))
    for index, call in enumerate(calls):
        call_id = text(call.get('id'))
        result = dict(results.get(call_id, {}))
        if len(calls) == 1 and 'calls_omitted' not in result:
            result['calls_omitted'] = record.get('calls_omitted')
        background_id = text(result.get('background_id'))
        phase = 'background_start' if background_id else 'foreground'
        add_run(db, path, line, step, index, phase, at, time_source, result,
                [item for item in details if integer(item.get('run_index')) == index], call_id, background_id)


def add_background_run(db, path, line, result, background_id, at, time_source):
    if not isinstance(result, dict):
        return
    step, index = integer(result.get('step')), integer(result.get('run_index'))
    if step is None or step == 0 or index is None:
        return
    if db.execute("SELECT 1 FROM runs WHERE session_path = ? AND phase = 'background' "
                  'AND step = ? AND run_index = ?', (path, step, index)).fetchone():
        return
    add_run(db, path, line, step, index, 'background', at, time_source, result,
            objects(result.get('calls')), background_id=text(background_id))


def add_background_runs(db, path, line, messages, at, time_source):
    for message in messages:
        add_background_run(db, path, line, message.get('background_run'),
                           message.get('background_id'), at, time_source)


def session_metadata(record):
    tuning = record.get('tuning')
    patches = record.get('patches_off')
    return dict(
        at_ms=integer(record.get('at')),
        **{field: text(record.get(field)) for field in (
            'parent_session_id', 'cwd', 'nib_version', 'provider', 'model', 'profile', 'system_sha')},
        tuning=json.dumps(tuning, sort_keys=True) if isinstance(tuning, dict) and all(
            isinstance(k, str) and isinstance(v, str) for k, v in tuning.items()) else None,
        patches_off=json.dumps(patches) if isinstance(patches, list) and all(
            isinstance(item, str) for item in patches) else None)


def add_step(db, path, line, step, record, messages, at, time_source):
    interrupted = any(message.get('role') == 'assistant' and re.search(
        r'\[interrupted(?: by user|: process terminated)\]\s*$', message.get('content') or '')
        for message in messages)
    usage = record.get('usage') if isinstance(record.get('usage'), dict) else {}
    insert(db, 'steps', dict(
        session_path=path, step=step, source_line=line, at_ms=at, time_source=time_source,
        status='interrupted' if interrupted else 'complete', effort=text(record.get('effort')),
        transport=text(record.get('transport')), incremental=boolean(record.get('incremental')),
        full_reason=text(record.get('full_reason')),
        **{key: integer(record.get(key)) for key in (
            'turn_step', 'ms', 'model_ms', 'run_ms', 'tool_bytes', 'output_bytes',
            'input_items', 'input_bytes', 'calls_omitted')},
        **{key: integer(usage.get(key)) for key in (
            'prompt_tokens', 'completion_tokens', 'prompt_cache_hit_tokens', 'prompt_cache_write_tokens')}))
    if not interrupted:
        add_foreground_runs(db, path, line, step, record, messages, at, time_source)


def valid_messages(record):
    messages = record.get('messages')
    if integer(record.get('from')) is None or not isinstance(messages, list) or not messages:
        return None
    if not all(isinstance(message, dict) and message.get('role') in ('system', 'user', 'assistant', 'tool')
               and (message.get('content') is None or isinstance(message['content'], str))
               and (message.get('tool_calls') is None or isinstance(message['tool_calls'], list))
               for message in messages):
        return None
    return messages


def import_session(db, path, rebuild=False):
    path = Path(path).expanduser().resolve()
    if path.name.endswith('.calls.jsonl'):
        return 'ignored'
    key = str(path)
    before = fingerprint(path.stat())
    previous = db.execute('SELECT source_identity, source_size, source_mtime_ns, source_ctime_ns '
                          'FROM sessions WHERE path = ?', (key,)).fetchone()
    if not rebuild and previous == before:
        return 'unchanged'
    with db:
        db.execute('DELETE FROM sessions WHERE path = ?', (key,))
        header = None
        length = step = consumed = line = invalid = pending = 0
        with path.open('rb') as stream:
            if fingerprint(os.fstat(stream.fileno())) != before:
                raise ValueError('source changed before import; retry')
            while consumed < before[1]:
                data = stream.readline(before[1] - consumed)
                consumed += len(data)
                if not data.endswith(b'\n'):
                    pending = len(data)
                    break
                line += 1
                try:
                    record = json.loads(data)
                except (ValueError, RecursionError):
                    invalid += 1
                    continue
                if not isinstance(record, dict):
                    invalid += 1
                    continue
                if record.get('repair'):
                    continue
                messages = valid_messages(record)
                if header is None:
                    if messages is None or record['from'] != 0 or messages[0]['role'] != 'system':
                        invalid += 1
                        continue
                    header = record
                    insert(db, 'sessions', dict(
                        path=key, session_id=path.stem, **session_metadata(record),
                        source_identity=before[0], source_size=before[1], source_mtime_ns=before[2],
                        source_ctime_ns=before[3]))
                    length = len(messages)
                    continue
                at, time_source = timestamp(record, before[2])
                background = record.get('background')
                if isinstance(background, dict) and background.get('kind') == 'run':
                    add_background_run(db, key, line, background.get('completion'),
                                       background.get('id'), at, time_source)
                diagnostic = record.get('diagnostic')
                if isinstance(diagnostic, dict):
                    insert(db, 'diagnostics', dict(
                        session_path=key, source_line=line, at_ms=at, time_source=time_source,
                        error_name=text(diagnostic.get('error_name')),
                        attempts=integer(diagnostic.get('attempts')), step=integer(diagnostic.get('step'))))
                    continue
                if messages is None:
                    continue
                replacement = record['from'] < length
                length = record['from'] + len(messages)
                if replacement:
                    if step == 0 and record['from'] == 0 and messages[0]['role'] == 'system' and 'model' in record:
                        metadata = session_metadata(record)
                        assignments = ', '.join(f'{column} = ?' for column in metadata)
                        db.execute(f'UPDATE sessions SET {assignments} WHERE path = ?',
                                   (*metadata.values(), key))
                    continue
                add_background_runs(db, key, line, messages, at, time_source)
                assistants = sum(message['role'] == 'assistant' for message in messages)
                if assistants:
                    add_step(db, key, line, step + 1, record, messages, at, time_source)
                    step += assistants
            if (fingerprint(os.fstat(stream.fileno())) != before or fingerprint(path.stat()) != before):
                raise ValueError('source changed during import; retry')
        if header is None:
            raise ValueError('no complete Session header')
        db.execute('UPDATE sessions SET source_lines = ?, invalid_lines = ?, pending_bytes = ? WHERE path = ?',
                   (line, invalid, pending, key))
    return 'imported'


def session_paths(inputs):
    paths = set()
    for item in inputs:
        path = Path(item).expanduser()
        if path.is_dir():
            paths.update(p.resolve() for p in path.glob('*.jsonl') if p.is_file() and not p.name.endswith('.calls.jsonl'))
        elif path.is_file():
            if not path.name.endswith('.calls.jsonl'):
                paths.add(path.resolve())
        else:
            raise ValueError(f'not a Session file or directory: {path}')
    return sorted(path for path in paths if not path.name.endswith('.calls.jsonl'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path, help='Session JSONL files or directories; excludes tool recordings')
    parser.add_argument('--db', type=Path, help='database path; default: $NIB_HOME/stats.sqlite3')
    parser.add_argument('--rebuild', action='store_true', help='reimport selected files even if unchanged')
    args = parser.parse_args()
    home = Path(os.environ.get('NIB_HOME', '~/.nib')).expanduser()
    database = args.db or home / 'stats.sqlite3'
    try:
        paths = session_paths(args.paths or [home / 'sessions'])
        with_database = open_database(database)
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f'Error: {error}\n')
    counts = dict(imported=0, unchanged=0, failed=0)
    try:
        for path in paths:
            try:
                counts[import_session(with_database, path, args.rebuild)] += 1
            except (OSError, ValueError, sqlite3.Error) as error:
                counts['failed'] += 1
                print(f'{path}: {error}', file=sys.stderr)
    finally:
        with_database.close()
    print(' '.join(f'{key}={value}' for key, value in counts.items()))
    return int(counts['failed'] != 0)


if __name__ == '__main__':
    sys.exit(main())
