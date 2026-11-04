#!/usr/bin/env python3
"""Read-only statistics for nib's append-only session logs (standard library only)."""
import argparse
import ast
from collections import Counter
from datetime import date, datetime
import json
import os
from pathlib import Path
import re
import shlex
from statistics import median
import warnings


TOKEN_KEYS = ('prompt_tokens', 'completion_tokens', 'prompt_cache_hit_tokens')
CACHE_TOKEN_KEYS = ('prompt_tokens', 'prompt_cache_hit_tokens')
ERRORS = {
    'js_syntax': r'SyntaxError',
    'command_not_found': r'''["']?exit_code["']?\s*:\s*127\b''',
    'run_timeout': r'run (?:timed out|timeout)',
    'subagent': r'subagent(?::| stopped| failed|.*timeout)|AgentFailed|InvalidAgentOutput|MissingAgentResult',
    'tool_arguments': r'expected \{|arguments must be a JSON object',
    'denied': r'refused by nib|CredentialAccessDenied',
    'interrupted': r'\[interrupted(?: by user|: process terminated)\]|Error: run canceled',
    'provider_failure': None,
    'other_failure': None,
}
TOOL_CALL = re.compile(r'\btools\.([A-Za-z_$][\w$]*)\s*\(')
BASH_COMMAND = re.compile(r'''\btools\.bash\s*\(\s*\{[^{}]*?(?:["']?command["']?)\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`[^`]*`)''', re.S)


def number(value):
    return type(value) is int and value >= 0


def without_heredocs(command):
    lines = []
    delimiters = []
    for line in command.splitlines():
        if delimiters:
            if line.strip() == delimiters[0]:
                delimiters.pop(0)
            continue
        lines.append(line)
        delimiters.extend(m[1] for m in re.finditer(r'''<<-?\s*['"]?([A-Za-z_][\w]*)['"]?''', line))
    return '\n'.join(lines)


def diagnostics(text):
    for line in text.splitlines():
        line = line.removeprefix('result: ').strip()
        try:
            value = json.loads(line)
        except (ValueError, RecursionError):
            value = line
        if isinstance(value, dict):
            if 'exit_code' in value:
                if type(value['exit_code']) is int and value['exit_code'] != 0:
                    yield 'exit_code: ' + str(value['exit_code']) + ' ' + str(value.get('output', ''))[-160:]
                # A shell may return 0 after an earlier Python failure.
                for output_line in str(value.get('output', '')).splitlines():
                    if re.match(r'^\s*SyntaxError:', output_line):
                        yield output_line.strip()
            continue
        if not isinstance(value, str):
            continue
        if re.match(r'^(?:(?:\w*Error|error):|subagent(?::| stopped)|expected \{|CredentialAccessDenied|refused by nib|arguments must be)', value):
            yield value


def commands(code):
    for match in BASH_COMMAND.finditer(code):
        literal = match[1]
        try:
            if literal.startswith('`'):
                if '${' in literal:
                    continue
                command = literal[1:-1]
            else:
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', (SyntaxWarning, DeprecationWarning))
                    command = json.loads(literal) if literal.startswith('"') else ast.literal_eval(literal)
            lexer = shlex.shlex(without_heredocs(command).replace('\n', ';'), posix=True, punctuation_chars=';&|()')
            lexer.whitespace_split = True
            tokens = list(lexer)
        except (ValueError, SyntaxError):
            continue
        start = True
        for token in tokens:
            if token and all(c in ';&|()' for c in token):
                start = True
            elif start:
                if re.match(r'^[A-Za-z_][\w]*=', token) or token in ('env', 'sudo', 'command', 'exec', '!'):
                    continue
                if not token.isdecimal() and not re.match(r'^\d*[<>]', token):
                    yield Path(token).name
                start = False


def distribution(values):
    values = sorted(values)
    return dict(samples=len(values), median=median(values) if values else None,
                p90=values[(9 * len(values) + 9) // 10 - 1] if values else None)


def bash_timing_group(code):
    if TOOL_CALL.findall(code).count('bash') != 1:
        return None
    matches = list(BASH_COMMAND.finditer(code))
    if len(matches) != 1:
        return None
    match = matches[0]
    if not re.match(r'\s*[,}]', code[match.end():]):
        return None
    literal = match[1]
    try:
        if literal.startswith('`'):
            if '${' in literal or '\\' in literal:
                return None
            command = literal[1:-1]
        else:
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', (SyntaxWarning, DeprecationWarning))
                command = json.loads(literal) if literal.startswith('"') else ast.literal_eval(literal)
        lexer = shlex.shlex(without_heredocs(command).replace('\n', ';'), posix=True, punctuation_chars=';&|()')
        lexer.whitespace_split = True
        words = []
        for token in lexer:
            if token and all(c in ';&|()' for c in token):
                break
            if not words and (re.match(r'^[A-Za-z_][\w]*=', token) or token in ('env', 'sudo', 'command', 'exec', '!')):
                continue
            if re.search(r'[$`<>]', token):
                return None
            words.append(Path(token).name if not words else token)
            if len(words) == 2:
                break
        return ' '.join(words) or None
    except (ValueError, SyntaxError):
        return None


JS_TOKEN = re.compile(r'''\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[A-Za-z_$][\w$]*|[^\s]''', re.S)


def literal_string(token):
    if len(token) < 2 or token[0] not in ("'", '"', '`') or token[-1] != token[0]:
        return None
    try:
        if token.startswith('`'):
            return token[1:-1] if '${' not in token and '\\' not in token else None
        if token.startswith("'"):
            encoded, index = ['"'], 1
            while index < len(token) - 1:
                char = token[index]
                if char == '\\':
                    index += 1
                    escape = token[index]
                    if escape == "'":
                        encoded.append("'")
                    elif escape in '"/\\bfnrtu':
                        encoded.extend(('\\', escape))
                    else:
                        return None
                elif char == '"':
                    encoded.append('\\"')
                else:
                    encoded.append(char)
                index += 1
            token = ''.join(encoded) + '"'
        return json.loads(token)
    except (ValueError, IndexError):
        return None


def literal_properties(tokens, start):
    if tokens[start:start + 1] != ['{']:
        return None
    stack, parts, part = ['}'], [], []
    closing = {'{': '}', '[': ']', '(': ')'}
    for index in range(start + 1, len(tokens)):
        token = tokens[index]
        if token in closing:
            stack.append(closing[token])
        elif token in ('}', ']', ')'):
            if not stack or stack.pop() != token:
                return None
            if not stack:
                if tokens[index + 1:index + 2] != [')']:
                    return None
                if part:
                    parts.append(part)
                break
        if token == ',' and len(stack) == 1:
            parts.append(part)
            part = []
        else:
            part.append(token)
    else:
        return None
    properties = {}
    for part in parts:
        if len(part) < 3 or part[1] != ':':
            return None
        key = literal_string(part[0]) if part[0].startswith(('"', "'", '`')) else part[0]
        if key is None or key in properties or not re.fullmatch(r'[A-Za-z_$][\w$]*', key):
            return None
        properties[key] = literal_string(part[2]) if len(part) == 3 else None
    return properties


def validation_command(command):
    if not command or re.search(r'[$`<>\\\n]', command):
        return False
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()')
        lexer.whitespace_split = True
        if any(token and all(c in ';&|()' for c in token) for token in lexer):
            return False
    except ValueError:
        return False
    group = bash_timing_group('tools.bash({command: ' + json.dumps(command) + '})')
    if not group:
        return False
    words = group.split()
    executable = words[0]
    subcommand = words[1] if len(words) > 1 else ''
    families = {'zig': {'build', 'test', 'fmt', 'ast-check'},
                'cargo': {'build', 'test', 'fmt', 'check', 'clippy'},
                'git': {'diff'}, 'go': {'build', 'test', 'fmt', 'vet'},
                'npm': {'test'}, 'npx': {'tsc'},
                'make': {'test', 'check', 'build', 'lint', 'fmt'}}
    if executable in {'diff', 'pytest', 'py.test', 'mypy', 'tsc', 'check', 'fmt'}:
        return True
    if executable == 'ruff':
        return subcommand in {'check', 'format'}
    if executable in {'python', 'python3'}:
        return bool(re.match(r'^\s*(?:python3?|/[^ ]*/python3?)\s+(?:-m\s+(?:unittest|pytest)\b|tests/test_[\w.-]+\.py(?:\s|$))', command))
    return subcommand in families.get(executable, set())


def step_structure(codes, cwd=None):
    writes, complete, validation, calls = False, True, True, 0
    paths = set()
    for code in codes:
        if not isinstance(code, str):
            complete = validation = False
            continue
        tokens = [m[0] for m in JS_TOKEN.finditer(code)
                  if not m[0].isspace() and not m[0].startswith(('//', '/*'))]
        safe_calls = {('console', '.', 'log'), ('JSON', '.', 'stringify'), ('JSON', '.', 'parse'),
                      ('Promise', '.', 'all'), ('Promise', '.', 'allSettled')}
        for index, token in enumerate(tokens):
            if token.startswith('`') and '${' in token:
                complete = validation = False
            if token == '(' and index:
                direct_tool = index >= 3 and tokens[index - 3:index - 1] == ['tools', '.']
                safe_call = tuple(tokens[max(0, index - 3):index]) in safe_calls
                grouping = tokens[index - 1] in ('=', '(', '[', ',', ':', '!', '&&', '||', 'await', 'return')
                if not direct_tool and not safe_call and not grouping:
                    complete = validation = False
            if token == '/' or (token == 'tools' and tokens[index + 1:index + 2] != ['.']):
                complete = validation = False
            if token != 'tools' or tokens[index + 1:index + 2] != ['.']:
                continue
            name = tokens[index + 2] if index + 2 < len(tokens) else ''
            if tokens[index + 3:index + 4] != ['(']:
                complete = validation = False
                continue
            calls += 1
            properties = literal_properties(tokens, index + 4)
            if name in ('edit', 'write'):
                writes = True
                path = properties.get('path') if properties is not None else None
                if not path:
                    complete = False
                else:
                    paths.add(os.path.normpath(os.path.join(cwd or '', path)))
            elif name not in ('read', 'grep', 'glob', 'bash', 'fetch'):
                complete = False
            if name != 'bash' or properties is None or not validation_command(properties.get('command')):
                validation = False
    return dict(writes=writes, paths=paths if writes and complete else None,
                validation=bool(calls) and validation)


def header_group(header, group_by):
    field = {'version': 'nib_version', 'system': 'system_sha', 'patches': 'patches_off'}[group_by]
    value = header.get(field)
    if group_by != 'patches':
        return value if isinstance(value, str) and value.strip() else 'unknown'
    if field not in header:
        return 'none' if any(isinstance(header.get(k), str) and header[k].strip()
                             for k in ('nib_version', 'system_sha')) else 'unknown'
    if value == [] or value == '':
        return 'none'
    if isinstance(value, list) and all(isinstance(v, str) and v for v in value):
        return json.dumps(sorted(set(value)), ensure_ascii=False)
    return value if isinstance(value, str) and value.strip() else 'unknown'


class EffortStats:
    def __init__(self):
        self.groups = {}

    def add(self, record, run_statuses):
        effort = record.get('effort')
        if not isinstance(effort, str) or not effort.strip():
            return
        group = self.groups.setdefault(effort, dict(steps=0, model_ms=[], steps_with_cache_usage=0,
            prompt_tokens=0, prompt_cache_hit_tokens=0, downgraded=Counter()))
        group['steps'] += 1
        if number(record.get('model_ms')):
            group['model_ms'].append(record['model_ms'])
        usage = record.get('usage')
        if isinstance(usage, dict) and all(number(usage.get(k)) for k in CACHE_TOKEN_KEYS):
            group['steps_with_cache_usage'] += 1
            for key in CACHE_TOKEN_KEYS:
                group[key] += usage[key]
        downgraded = record.get('effort_downgraded')
        if record.get('effort_source') == 'model' and (downgraded is None or downgraded is True):
            counts = group['downgraded']
            counts['steps'] += 1
            counts['steps_with_runs'] += bool(run_statuses)
            counts['steps_with_failed_run'] += any(ok is False for ok in run_statuses)
            counts['steps_with_unknown_run_status'] += any(ok is None for ok in run_statuses)

    def report(self):
        def downgrade_summary(counts):
            result = {key: counts[key] for key in ('steps', 'steps_with_runs', 'steps_with_failed_run',
                                                  'steps_with_unknown_run_status')}
            result['run_failure_rate'] = (counts['steps_with_failed_run'] / counts['steps_with_runs']
                                          if counts['steps_with_runs'] else None)
            return result

        groups, total = {}, Counter()
        for effort, group in sorted(self.groups.items()):
            total.update(group['downgraded'])
            groups[effort] = dict(group, model_ms=distribution(group['model_ms']),
                cache_hit_rate=group['prompt_cache_hit_tokens'] / group['prompt_tokens']
                               if group['prompt_tokens'] else None,
                downgraded=downgrade_summary(group['downgraded']))
        return dict(by_effort=groups, downgraded=downgrade_summary(total))


class Timing:
    def __init__(self):
        self.values = {key: [] for key in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms',
                                         'first_data_ms', 'code_first_ms', 'code_span_ms', 'attempts')}
        self.effort = EffortStats()
        self.tools = {}
        self.bash = {}
        self.calls_steps = self.calls_omitted = self.bash_unmatched = 0

    def add(self, record, sources, run_statuses=()):
        self.effort.add(record, run_statuses)
        for key in ('model_ms', 'run_ms', 'first_data_ms', 'attempts'):
            if number(record.get(key)):
                self.values[key].append(record[key])
        if number(record.get('ms')):
            self.values['step_ms'].append(record['ms'])
        code = record.get('code')
        for item in code if isinstance(code, list) else []:
            if not isinstance(item, dict):
                continue
            first, last = item.get('first_ms'), item.get('last_ms')
            if number(first):
                self.values['code_first_ms'].append(first)
                if number(last) and last >= first:
                    self.values['code_span_ms'].append(last - first)
        results = record.get('run_results')
        results = results if isinstance(results, list) else []
        for result in results:
            if isinstance(result, dict) and number(result.get('run_ms')):
                self.values['run_result_ms'].append(result['run_ms'])
        if number(record.get('calls_omitted')):
            self.calls_omitted += record['calls_omitted']
        calls = record.get('calls')
        if not isinstance(calls, list):
            return
        self.calls_steps += 1
        bash_per_run = Counter(c.get('run_index') for c in calls
                               if isinstance(c, dict) and c.get('name') == 'bash' and number(c.get('run_index')))
        for call in calls:
            if not isinstance(call, dict):
                continue
            name, start, end = call.get('name'), call.get('start_ms'), call.get('end_ms')
            if not isinstance(name, str) or not name or not number(start) or not number(end) or end < start:
                continue
            duration = end - start
            self.tools.setdefault(name, []).append(duration)
            if name != 'bash':
                continue
            index = call.get('run_index')
            group = None
            if number(index) and index < len(results) and bash_per_run[index] == 1:
                result = results[index]
                call_id = result.get('tool_call_id') if isinstance(result, dict) else None
                source = sources.get(call_id) if isinstance(call_id, str) else None
                if source is not None:
                    group = bash_timing_group(source)
            if group is None:
                self.bash_unmatched += 1
            else:
                self.bash.setdefault(group, []).append(duration)

    def report(self):
        def tool_summary(values):
            return dict(count=len(values), total_ms=sum(values), median_ms=median(values))
        spans = self.values['code_span_ms']
        streamed = sum(span > 50 for span in spans)
        return dict({key: distribution(values) for key, values in self.values.items()},
                    effort=self.effort.report(),
                    calls_steps=self.calls_steps, calls_omitted=self.calls_omitted,
                    tools={name: tool_summary(values) for name, values in sorted(self.tools.items())},
                    streaming=dict(samples=len(spans), over_50_ms=streamed,
                                   ratio=streamed / len(spans) if spans else None),
                    bash=dict(heuristic=True, matched_calls=sum(map(len, self.bash.values())),
                              unmatched_calls=self.bash_unmatched,
                              top10=[dict(command=name, **tool_summary(values)) for name, values in
                                     sorted(self.bash.items(), key=lambda p: (-sum(p[1]), p[0]))[:10]]))


def records(path):
    if path.name.endswith('.calls.jsonl'):
        return
    try:
        with path.open(encoding='utf-8', errors='replace') as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if not isinstance(record, dict) or record.get('repair'):
                    continue
                diagnostic = record.get('diagnostic')
                if isinstance(diagnostic, dict) and isinstance(diagnostic.get('message'), str):
                    yield record
                    continue
                messages = record.get('messages')
                if not number(record.get('from')) or not isinstance(messages, list) or not messages:
                    continue
                if not all(isinstance(m, dict) and m.get('role') in ('system', 'user', 'assistant', 'tool')
                           and (m.get('content') is None or isinstance(m['content'], str))
                           and (m.get('tool_calls') is None or isinstance(m['tool_calls'], list)) for m in messages):
                    continue
                yield record
    except OSError:
        return


def summarize(paths, since=None, cwd=None, group_by=None):
    if group_by not in (None, 'version', 'system', 'patches'):
        raise ValueError('invalid group_by')
    group_paths = {}
    adjacent_pairs = write_validation_pairs = file_pairs = disjoint_pairs = 0
    totals = dict(sessions=0, root_sessions=0, child_sessions=0, turns=0, steps=0, runs=0,
                  runs_failed=0, runs_with_status=0, runs_unknown=0, steps_with_usage=0,
                  steps_with_ms=0, timed_turns=0)
    cutoff_ms = int(datetime.combine(since, datetime.min.time()).timestamp() * 1000) if since else None
    time_filter = dict(selected_records_with_at=0, selected_records_using_mtime=0,
                       selected_steps_using_mtime=0)
    usage = dict.fromkeys(TOKEN_KEYS, 0)
    tool_counts, bash_counts = Counter(), Counter()
    timing = Timing()
    errors = {name: {'count': 0, 'examples': []} for name in ERRORS}
    slowest, turn_steps, turn_times = [], [], []

    def error(name, text, session):
        item = errors[name]
        item['count'] += 1
        example = {'session_id': session[:8], 'text': ' '.join(text.split())[:180]}
        if len(item['examples']) < 2 and example not in item['examples']:
            item['examples'].append(example)

    for path in paths:
        try:
            mtime_ms = path.stat().st_mtime * 1000
        except OSError:
            continue
        log = iter(records(path))
        header = next(log, None)
        if header is None or not header.get('messages') or header['messages'][0]['role'] != 'system':
            continue
        if cwd is not None and (not isinstance(header.get('cwd'), str) or
                                Path(header['cwd']).expanduser().resolve() != cwd):
            continue
        if group_by is not None:
            group_paths.setdefault(header_group(header, group_by), []).append(path)

        def selected(record):
            at = record.get('at')
            return cutoff_ms is None or (at if number(at) else mtime_ms) >= cutoff_ms

        session_selected = selected(header)
        length = header['from'] + len(header['messages'])
        current = None
        session_step = 0

        def finish_turn():
            if current is not None and current['selected']:
                totals['turns'] += 1
                turn_steps.append(current['steps'])
                if (current['complete'] and current['steps'] and
                        current['steps'] == current['full_steps'] == current['timed']):
                    turn_times.append(current['ms'])

        for record in log:
            include = selected(record)
            has_at = number(record.get('at'))
            diagnostic = isinstance(record.get('diagnostic'), dict)
            if not diagnostic:
                messages = record['messages']
                replacement = record['from'] < length
                length = record['from'] + len(messages)
                if replacement:
                    continue
            if include:
                session_selected = True
                time_filter['selected_records_with_at' if has_at else 'selected_records_using_mtime'] += 1
            if diagnostic:
                if include:
                    error('provider_failure', record['diagnostic']['message'], path.stem)
                continue
            turn_step = record.get('turn_step')
            explicit_turn = number(turn_step) and turn_step > 0
            new_turn = (turn_step == 1 if explicit_turn else any(m['role'] == 'user' for m in messages))
            if new_turn or (explicit_turn and current is None):
                finish_turn()
                current = dict(steps=0, full_steps=0, timed=0, ms=0, complete=False, selected=False, previous=None)
            if current is not None and include:
                current['selected'] = True
            interrupted = False
            for m in messages:
                if m['role'] == 'assistant' and re.search(r'\[interrupted(?: by user|: process terminated)\]\s*$', m.get('content') or ''):
                    if include:
                        error('interrupted', m['content'], path.stem)
                    interrupted = True
                    if current is not None:
                        current['previous'] = None
            if not any(m['role'] == 'assistant' for m in messages) or interrupted:
                continue
            session_step += 1
            if current is not None:
                current['full_steps'] += 1
                current['complete'] = any(m['role'] == 'assistant' and not m.get('tool_calls') for m in messages)
            if not include:
                if current is not None:
                    current['previous'] = None
                continue
            totals['steps'] += 1
            if not has_at:
                time_filter['selected_steps_using_mtime'] += 1
            if current is not None:
                current['steps'] += 1
            u = record.get('usage')
            if isinstance(u, dict) and all(number(u.get(k)) for k in TOKEN_KEYS):
                totals['steps_with_usage'] += 1
                for key in TOKEN_KEYS:
                    usage[key] += u[key]
            ms = record.get('ms')
            if number(ms):
                totals['steps_with_ms'] += 1
                if current is not None:
                    current['timed'] += 1
                    current['ms'] += ms
                slowest.append({'session_id': path.stem[:8], 'step': session_step, 'ms': ms})
                slowest.sort(key=lambda s: s['ms'], reverse=True)
                del slowest[5:]
            statuses = record.get('run_results')
            statuses = {r['tool_call_id']: r['ok'] for r in statuses
                        if isinstance(r, dict) and isinstance(r.get('tool_call_id'), str)
                        and type(r.get('ok')) is bool} if isinstance(statuses, list) else {}
            outputs = {m['tool_call_id']: m.get('content') or '' for m in messages
                       if m['role'] == 'tool' and isinstance(m.get('tool_call_id'), str)}
            sources, run_statuses, step_codes = {}, [], []
            for m in messages:
                for call in m.get('tool_calls') or []:
                    if not isinstance(call, dict) or not isinstance(call.get('function'), dict):
                        step_codes.append(None)
                        continue
                    function = call['function']
                    if function.get('name') != 'run':
                        step_codes.append(None)
                        continue
                    totals['runs'] += 1
                    call_id = call.get('id')
                    ok = statuses.get(call_id) if isinstance(call_id, str) else None
                    run_statuses.append(ok)
                    if ok is not None:
                        totals['runs_with_status'] += 1
                        totals['runs_failed'] += not ok
                    try:
                        args = json.loads(function.get('arguments', ''))
                    except (ValueError, TypeError, RecursionError):
                        args = None
                    code = args.get('code') if isinstance(args, dict) else None
                    step_codes.append(code)
                    if isinstance(code, str):
                        if isinstance(call_id, str):
                            sources[call_id] = code
                        tool_counts.update(TOOL_CALL.findall(code))
                        bash_counts.update(commands(code))
                    text = outputs.get(call_id, '') if isinstance(call_id, str) else ''
                    candidates = list(diagnostics(text))
                    matched = False
                    for name, pattern in ERRORS.items():
                        example = next((s for s in candidates if pattern and re.search(pattern, s, re.I)), None)
                        if example is not None:
                            error(name, example, path.stem)
                            matched = True
                    if not matched and (ok is False or candidates):
                        error('other_failure', candidates[0] if candidates else text, path.stem)
            timing.add(record, sources, run_statuses)
            if current is not None:
                structure = step_structure(step_codes, header.get('cwd') if isinstance(header.get('cwd'), str) else None)
                previous = current['previous']
                if previous is not None:
                    adjacent_pairs += 1
                    write_validation_pairs += previous['writes'] and structure['validation']
                    if previous['paths'] is not None and structure['paths'] is not None:
                        file_pairs += 1
                        disjoint_pairs += previous['paths'].isdisjoint(structure['paths'])
                current['previous'] = structure
        finish_turn()
        if session_selected:
            totals['sessions'] += 1
            totals['child_sessions' if header.get('parent_session_id') else 'root_sessions'] += 1
    totals['runs_unknown'] = totals['runs'] - totals['runs_with_status']
    totals['run_failure_rate'] = totals['runs_failed'] / totals['runs_with_status'] if totals['runs_with_status'] else None
    totals['avg_steps_per_turn'] = sum(turn_steps) / len(turn_steps) if turn_steps else None
    totals['timed_turns'] = len(turn_times)
    totals['avg_turn_ms'] = sum(turn_times) / len(turn_times) if turn_times else None
    usage['total_tokens'] = usage['prompt_tokens'] + usage['completion_tokens']
    usage['cache_hit_rate'] = usage['prompt_cache_hit_tokens'] / usage['prompt_tokens'] if usage['prompt_tokens'] else None
    def pair_summary(count, pairs):
        return dict(count=count, pairs=pairs, ratio=count / pairs if pairs else None)

    report = {'overall': totals, 'usage': usage, 'time_filter': time_filter, 'tools': dict(sorted(tool_counts.items())),
            'bash_top10': [{'command': k, 'count': v} for k, v in sorted(bash_counts.items(), key=lambda p: (-p[1], p[0]))[:10]],
            'errors': errors, 'slowest_steps': slowest, 'timing': timing.report(),
            'round_trips': dict(steps_per_turn=distribution(turn_steps),
                               write_to_validation=pair_summary(write_validation_pairs, adjacent_pairs),
                               disjoint_write_files=pair_summary(disjoint_pairs, file_pairs),
                               notes=["Step 分布按入选 Turn（含零步；旧日志按 user 估算边界）；相邻对限同 Turn、不跨过滤/取消断点。写→验证分母为全部相邻对，后步仅含静态验证 bash，沿用首两词启发式。",
                                      "连续写以双方直接 edit/write 的完整字面量路径为样本（按 cwd 规范化）；文件集合不相交才计不同文件。动态/未知调用跳过；不推断 bash 副作用，fmt 也归验证。"]),
            'notes': ["仅统计入选记录；失败率只用显式 run_results；token=prompt+completion（不重复加缓存），缓存率以 prompt 为分母；错误可重叠，工具/命令数为静态估计。",
                      "Turn 平均耗时只含已结束、全部 Step 入选且有 ms 的 Turn；--since 按记录 at（本地日期），缺失或无效 at 回退到文件修改时间。",
                      f"时间来源：{time_filter['selected_records_with_at']} 条按 at，{time_filter['selected_records_using_mtime']} 条回退文件时间（其中 {time_filter['selected_steps_using_mtime']} 个完整 Step）；计时仅有效字段、缺失不补零；p90=nearest-rank；first_data_ms 是首次收到任何流数据，非内容 token；model_ms 含重试/退避。",
                      "run_ms 为 Step 内 Run 总耗时，run_result_ms 为单 Run；code_first_ms 为首段代码等待，code_span_ms=last-first，streaming 为 >50 ms 比例；calls 含失败、并行耗时可重叠；bash 计时按字面量首两词启发式分组，无法关联列 unmatched，非 shell 子命令耗时。timing.effort.by_effort 按完整 Step 顶层 effort 分组，缺 effort 跳过、缺计时仍计 Step；缓存率为有效 prompt/cache 成对字段的总和之比。各组及 timing.effort.downgraded：effort_source=model 且（effort_downgraded=true 或缺失/null）视为降档（已知等档应记录 false）；run_failure_rate=steps_with_failed_run/steps_with_runs，仅关联本 Step 模型响应产生的 Run，任一显式 ok=false 即失败；未知状态仍入分母，并列 steps_with_unknown_run_status；无 Run 不入分母。"]}

    if group_by is not None:
        report['group_by'] = group_by
        report['groups'] = {}
        for key, members in sorted(group_paths.items()):
            group = summarize(members, since, cwd)
            if group['overall']['sessions']:
                report['groups'][key] = group
        report['notes'][0] += (' --group-by 按 header nib_version/system_sha/patches_off 分组，'
            '缺失/无效值为 unknown；patches_off 缺失但 nib_version 或 system_sha 有效时为 none，'
            '显式空补丁集也为 none；补丁数组按去重排序的集合分组，每组重新汇总完整核心报告。')
    return report


def text_report(report):
    t, u = report['overall'], report['usage']
    def fmt(value, suffix=''):
        return 'n/a' if value is None else f'{value:.2f}{suffix}'
    def pct(value):
        return fmt(None if value is None else 100 * value, '%')
    token_total = str(u['total_tokens']) if t['steps_with_usage'] else 'n/a'
    lines = [f"会话 {t['sessions']}（根 {t['root_sessions']} / 子 {t['child_sessions']}）；Turn {t['turns']}；Step {t['steps']}；Run {t['runs']}",
             f"Run 失败 {t['runs_failed']}/{t['runs_with_status']} = {pct(t['run_failure_rate'])}（状态未知 {t['runs_unknown']}）",
             f"Token {token_total}（prompt {u['prompt_tokens']} / completion {u['completion_tokens']}）；缓存命中 {pct(u['cache_hit_rate'])}；usage 覆盖 {t['steps_with_usage']}/{t['steps']} Step",
             f"每 Turn 平均 {fmt(t['avg_steps_per_turn'])} Step；平均耗时 {fmt(t['avg_turn_ms'], ' ms')}（完整计时 {t['timed_turns']}/{t['turns']} Turn，{t['steps_with_ms']} Step）",
             '工具（静态调用点）：' + (', '.join(f'{k} {v}' for k, v in report['tools'].items()) or '无'),
             'bash 命令 Top 10：' + (', '.join(f"{v['command']} {v['count']}" for v in report['bash_top10']) or '无'), '错误分类：']
    structure = report['round_trips']
    steps = structure['steps_per_turn']
    section = ["往返结构：", f"  每 Turn Step: samples={steps['samples']} median={fmt(steps['median'])} p90={fmt(steps['p90'])}"]
    for name, label in (('write_to_validation', '写→仅验证'), ('disjoint_write_files', '连续写不同文件（不相交）')):
        item = structure[name]
        section.append(f"  {label}: {item['count']}/{item['pairs']} = {pct(item['ratio'])}（samples={item['pairs']}）")
    section.extend("  " + note for note in structure['notes'])
    lines[4:4] = section
    for name, item in report['errors'].items():
        lines.append(f"  {name}: {item['count']}")
        lines.extend(f"    [{e['session_id']}] {e['text']}" for e in item['examples'])
    lines.append('最慢的 5 个 Step：')
    lines.extend(f"  {s['session_id']}  {s['ms']} ms" for s in report['slowest_steps'])
    if not report['slowest_steps']:
        lines.append('  无计时记录')
    timing = report['timing']
    lines.append('耗时构成 / 计时 Timing（ms，attempts 为次数；缺失字段不补零）：')
    for name in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms', 'first_data_ms', 'code_first_ms', 'code_span_ms', 'attempts'):
        item = timing[name]
        lines.append(f"  {name}: samples={item['samples']} median={fmt(item['median'])} p90={fmt(item['p90'])}")
    effort = timing['effort']
    lines.append('  Step effort（顶层元数据）：')
    for level, item in effort['by_effort'].items():
        down = item['downgraded']
        lines.append(f"    {level}: steps={item['steps']} model_ms median={fmt(item['model_ms']['median'])} samples={item['model_ms']['samples']} cache_hit_rate={pct(item['cache_hit_rate'])}（{item['prompt_cache_hit_tokens']}/{item['prompt_tokens']}）")
        lines.append(f"      downgraded steps={down['steps']}; 本 Step Run 失败 {down['steps_with_failed_run']}/{down['steps_with_runs']} = {pct(down['run_failure_rate'])}（状态未知 Step={down['steps_with_unknown_run_status']}）")
    if not effort['by_effort']:
        lines.append('    无 effort 记录')
    down = effort['downgraded']
    lines.append(f"  降档 Step 合计 {down['steps']}；本 Step Run 失败 {down['steps_with_failed_run']}/{down['steps_with_runs']} = {pct(down['run_failure_rate'])}（状态未知 Step={down['steps_with_unknown_run_status']}）")
    streaming = timing['streaming']
    lines.append(f"  code streaming (last-first > 50 ms): {streaming['over_50_ms']}/{streaming['samples']} = {pct(streaming['ratio'])}")
    lines.append(f"  工具运行时计时（calls Step={timing['calls_steps']}, omitted={timing['calls_omitted']}）：")
    for name, item in timing['tools'].items():
        lines.append(f"    {name}: count={item['count']} total={item['total_ms']} ms median={fmt(item['median_ms'])} ms")
    if not timing['tools']:
        lines.append('    无计时记录')
    bash = timing['bash']
    lines.append(f"  bash 计时 Top 10（heuristic 字面量首两个单词；matched={bash['matched_calls']}, unmatched={bash['unmatched_calls']}）：")
    for item in bash['top10']:
        lines.append(f"    {item['command']}: count={item['count']} total={item['total_ms']} ms median={fmt(item['median_ms'])} ms")
    if not bash['top10']:
        lines.append('    无可匹配计时记录')
    lines.extend(['口径：'] + ['  ' + note for note in report['notes']])
    if 'groups' in report:
        lines.append(f"分组 group_by={report['group_by']}：")
        for key, group in report['groups'].items():
            lines.append(f"=== {report['group_by']}={key} ===")
            lines.append(text_report(group))
        if not report['groups']:
            lines.append('  无入选分组')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path, help='session JSONL files or directories')
    parser.add_argument('--since', type=date.fromisoformat, metavar='YYYY-MM-DD', help='record date, inclusive, local time; legacy records fall back to file modification time')
    parser.add_argument('--cwd', type=Path, help='exact session working directory')
    parser.add_argument('--group-by', choices=('version', 'system', 'patches'), help='group core reports by session header metadata')
    parser.add_argument('--json', action='store_true', help='emit JSON instead of text')
    args = parser.parse_args()
    inputs = args.paths or [Path(os.environ.get('NIB_HOME', '~/.nib')).expanduser() / 'sessions']
    paths = set()
    for path in inputs:
        path = path.expanduser()
        if path.is_dir():
            paths.update(p.resolve() for p in path.glob('*.jsonl') if not p.name.endswith('.calls.jsonl') and p.is_file())
        elif not path.name.endswith('.calls.jsonl') and path.is_file():
            paths.add(path.resolve())
    report = summarize(sorted(paths), args.since, args.cwd.expanduser().resolve() if args.cwd else None, args.group_by)
    print(json.dumps(report, ensure_ascii=False, indent=2) if args.json else text_report(report))


if __name__ == '__main__':
    main()
