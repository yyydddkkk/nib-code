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


def validation_first_words(command):
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()')
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
    except ValueError:
        return None


SHELL_TOKEN = re.compile(r'''(?:\d+)?(?:<<<|<<-?|>>|[<>]&|<>|>\||[<>])|[;&|()]|(?:[^\s;&|()<>\\'"]|\\.|'(?:[^']*)'|"(?:\\.|[^"\\])*")+''', re.S)
SHELL_REDIRECT = re.compile(r'(?:\d+)?(?:<<<|<<-?|>>|[<>]&|<>|>\||[<>])')


def bash_first_words(command):
    words, redirect = [], False
    for match in SHELL_TOKEN.finditer(command):
        raw = match[0]
        if SHELL_REDIRECT.fullmatch(raw):
            redirect = True
            continue
        if redirect:
            redirect = False
            continue
        if raw in ('(', ')'):
            continue
        if raw in (';', '&', '|'):
            return None
        try:
            token, = shlex.split(raw)
        except ValueError:
            return None
        if not words and (re.match(r'^[A-Za-z_][\w]*=', token) or token in ('env', 'sudo', 'command', 'exec', '!')):
            continue
        if re.search(r'[$`]', token):
            return None
        words.append(Path(token).name if not words else token)
        if len(words) == 2:
            break
    return ' '.join(words) or None


def shell_segments(command):
    segment, quote, depth, index = [], None, 0, 0
    heredocs = []
    while index < len(command):
        char = command[index]
        if char == '\\' and quote != "'":
            if index + 1 < len(command):
                if command[index + 1] != '\n':
                    segment.extend(command[index:index + 2])
                index += 2
                continue
        if quote:
            segment.append(char)
            if char == quote:
                quote = None
        elif char in ("'", '"', '`'):
            quote = char
            segment.append(char)
        elif char == '#' and (not segment or segment[-1].isspace()):
            while index < len(command) and command[index] != '\n':
                index += 1
            continue
        elif command[index:index + 2] == '>|':
            segment.extend('>|')
            index += 2
            continue
        elif (command[index:index + 2] == '<<' and command[index:index + 3] != '<<<'
              and (index == 0 or command[index - 1] != '<')):
            strip_tabs = command[index + 2:index + 3] == '-'
            lexer = shlex.shlex(command[index + 2 + strip_tabs:], posix=True, punctuation_chars=';&|()<>')
            lexer.whitespace_split = True
            try:
                delimiter = lexer.get_token()
            except ValueError:
                yield ''
                return
            if not delimiter:
                yield ''
                return
            heredocs.append((delimiter, strip_tabs))
            segment.append(char)
        elif command[index:index + 2] == '$(':
            depth += 1
            segment.extend('$(')
            index += 2
            continue
        elif depth:
            depth += (char == '(') - (char == ')')
            segment.append(char)
        elif char in ';|\n' or command[index:index + 2] == '&&':
            if ''.join(segment).strip():
                yield ''.join(segment)
            segment = []
            if command[index:index + 2] in ('&&', '||', '|&'):
                index += 1
        else:
            segment.append(char)
        if char == '\n' and heredocs and not quote and not depth:
            while heredocs and index < len(command):
                end = command.find('\n', index + 1)
                end = len(command) if end < 0 else end
                line = command[index + 1:end]
                delimiter, strip_tabs = heredocs[0]
                if (line.lstrip('\t') if strip_tabs else line) == delimiter:
                    heredocs.pop(0)
                index = end
        index += 1
    if quote or depth or heredocs:
        yield ''
    elif ''.join(segment).strip():
        yield ''.join(segment)


def bash_command_group(command):
    groups = [bash_first_words(segment) for segment in shell_segments(command)]
    return ' → '.join(groups) if groups and all(groups) else None


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
        return bash_command_group(command)
    except (ValueError, SyntaxError):
        return None


def recorded_bash_commands(path):
    runs = {}
    try:
        with path.with_suffix('.calls.jsonl').open(encoding='utf-8', errors='replace') as stream:
            for line in stream:
                try:
                    call = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if not isinstance(call, dict) or call.get('name') != 'bash':
                    continue
                step, run, index = (call.get(key) for key in ('step', 'run', 'index'))
                if not all(number(value) for value in (step, run, index)):
                    continue
                args = call.get('args')
                command = args.get('command') if isinstance(args, dict) else None
                runs.setdefault((step, run), []).append((index, command))
    except OSError:
        pass
    steps = {}
    for (step, run), calls in runs.items():
        if len({index for index, _ in calls}) == len(calls):
            steps.setdefault(step, {})[run] = [command for _, command in sorted(calls, key=lambda c: c[0])]
    return steps

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
    if not isinstance(command, str) or not command or re.search(r'[$`<>\\\n]', command):
        return False
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()')
        lexer.whitespace_split = True
        if any(token and all(c in ';&|()' for c in token) for token in lexer):
            return False
    except ValueError:
        return False
    group = validation_first_words(command)
    if not group:
        return False
    words = group.split()
    executable = words[0]
    subcommand = words[1] if len(words) > 1 else ''
    families = {'zig': {'build', 'test', 'fmt', 'ast-check'},
                'cargo': {'build', 'test', 'fmt', 'check', 'clippy'},
                'git': {'status', 'diff', 'log', 'fetch', 'show'}, 'go': {'build', 'test', 'fmt', 'vet'},
                'npm': {'test'}, 'npx': {'tsc'},
                'make': {'test', 'check', 'build', 'lint', 'fmt'}}
    if executable == 'gh':
        return bool(re.match(r'^\s*gh\s+pr\s+(?:view|checks)(?:\s|$)', command))
    if executable in {'diff', 'pytest', 'py.test', 'mypy', 'tsc', 'check', 'fmt',
                      'tail', 'cat', 'ls', 'head', 'pwd'}:
        return True
    if executable == 'ruff':
        return subcommand in {'check', 'format'}
    if executable in {'python', 'python3'}:
        return bool(re.match(r'^\s*(?:python3?|/[^ ]*/python3?)\s+(?:-m\s+(?:unittest|pytest)\b|tests/test_[\w.-]+\.py(?:\s|$))', command))
    return subcommand in families.get(executable, set())


def step_structure(codes, cwd=None, *, allow_read=False, allow_empty=False):
    writes, complete, validation, calls = False, True, True, 0
    paths = set()
    for code in codes:
        if not isinstance(code, str):
            complete = validation = False
            continue
        tokens = [m[0] for m in JS_TOKEN.finditer(code)
                  if not m[0].isspace() and not m[0].startswith(('//', '/*'))]
        if allow_read and (any(token in {'if', 'else', 'for', 'while', 'switch', 'case',
                                         'function', 'class', 'try', 'catch', 'throw', 'return', '?'}
                               for token in tokens)
                           or any(tokens[index:index + 2] in (['=', '>'], ['&', '&'], ['|', '|'])
                                  for index in range(len(tokens) - 1))):
            validation = False
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
            if not (allow_read and name == 'read'):
                if name != 'bash' or properties is None or not validation_command(properties.get('command')):
                    validation = False
    return dict(writes=writes, paths=paths if writes and complete else None,
                validation=(bool(calls) or allow_empty) and validation)


def complete_recorded_calls(path):
    runs, metadata = {}, {}
    try:
        with path.with_suffix(".calls.jsonl").open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    call = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if not isinstance(call, dict):
                    continue
                key = call.get("step"), call.get("run")
                if not all(number(value) for value in key):
                    continue
                if isinstance(call.get("meta"), dict):
                    metadata.setdefault(key, []).append(call["meta"])
                elif number(call.get("index")):
                    args = call.get("args")
                    command = args.get("command") if isinstance(args, dict) else None
                    runs.setdefault(key, []).append(dict(index=call["index"], name=call.get("name"),
                                                         args=dict(command=command)))
    except OSError:
        return {}
    complete = {}
    for key, metas in metadata.items():
        if len(metas) != 1 or metas[0].get("incomplete") or metas[0].get("end") not in ("ok", "error"):
            continue
        calls = sorted(runs.get(key, []), key=lambda call: call["index"])
        if [call["index"] for call in calls] == list(range(len(calls))):
            complete[key] = calls
    return complete


def mechanical_step(codes, recorded_step, recordings):
    valid, calls = True, 0
    sources, static_codes = set(), []
    for run, code in enumerate(codes):
        recorded = recordings.get((recorded_step, run)) if isinstance(code, str) else None
        if recorded is None:
            sources.add("static")
            static_codes.append(code)
        else:
            sources.add("recorded")
            calls += len(recorded)
            for call in recorded:
                name, args = call.get("name"), call.get("args")
                if name != "read" and not (name == "bash" and isinstance(args, dict)
                                            and validation_command(args.get("command"))):
                    valid = False
    source = next(iter(sources)) if len(sources) == 1 else "mixed" if sources else "static"
    structure = step_structure(static_codes, allow_read=True, allow_empty=bool(calls))
    return valid and structure["validation"], source


def header_group(header, group_by):
    field = {'version': 'nib_version', 'system': 'system_sha', 'patches': 'patches_off', 'profile': 'profile'}[group_by]
    value = header.get(field)
    if group_by != 'patches':
        return value if isinstance(value, str) and value.strip() else 'unknown'
    label = patches_off_label(header, field, value)
    on = header.get('patches_on')
    if isinstance(on, list) and on and all(isinstance(v, str) and v for v in on) and label != 'unknown':
        return f"{label} on={json.dumps(sorted(set(on)), ensure_ascii=False)}"
    return label


def patches_off_label(header, field, value):
    if field not in header:
        return 'none' if any(isinstance(header.get(k), str) and header[k].strip()
                             for k in ('nib_version', 'system_sha')) else 'unknown'
    if value == [] or value == '':
        return 'none'
    if isinstance(value, list) and all(isinstance(v, str) and v for v in value):
        return json.dumps(sorted(set(value)), ensure_ascii=False)
    return value if isinstance(value, str) and value.strip() else 'unknown'


class ChildCosts:
    def __init__(self):
        self.sessions = []

    def add(self, steps, selected_steps, model_ms, prompt_tokens, uncached_prompt_tokens, parent_system,
            creation, first_request_cache_hit_rate):
        self.sessions.append(dict(steps=steps, selected_steps=selected_steps,
                                  model_ms=model_ms, prompt_tokens=prompt_tokens,
                                  uncached_prompt_tokens=uncached_prompt_tokens, parent_system=parent_system,
                                  creation=creation, first_request_cache_hit_rate=first_request_cache_hit_rate))

    def report(self):
        def summary(sessions):
            full = [s for s in sessions if s['steps'] and s['steps'] == s['selected_steps']]
            result = dict(sessions=len(sessions), full_range_sessions=len(full),
                          partial_range_sessions=sum(s['steps'] != s['selected_steps'] for s in sessions),
                          no_step_sessions=sum(not s['steps'] for s in sessions),
                          steps=distribution([s['steps'] for s in full]))
            for field in ('model_ms', 'prompt_tokens', 'uncached_prompt_tokens'):
                result[field] = distribution([sum(s[field]) for s in full
                                              if len(s[field]) == s['steps']])
            result['first_request_cache_hit_rate'] = distribution(
                [s['first_request_cache_hit_rate'] for s in full
                 if s['first_request_cache_hit_rate'] is not None])
            return result

        def with_creation(sessions):
            groups = {}
            for session in sessions:
                groups.setdefault(session['creation'], []).append(session)
            return dict(summary(sessions),
                        by_creation={key: summary(members) for key, members in sorted(groups.items())})

        groups = {}
        for session in self.sessions:
            groups.setdefault(session['parent_system'], []).append(session)
        return dict(with_creation(self.sessions),
                    by_parent_system={key: with_creation(sessions) for key, sessions in sorted(groups.items())},
                    notes=["Each selected child log with parent_session_id is one sample, foreground or background; count only committed complete Steps. Failed, canceled, or still-running logs also give a lower bound on recorded cost; completion is not inferred.",
                           "Distributions require nonzero Steps and selection of every complete Step; children truncated by --since appear in partial_range_sessions, not whole-session costs. model_ms/prompt_tokens/uncached_prompt_tokens each require valid fields on every Step; missing values are not zero-filled, samples shows coverage; p90=nearest-rank.",
                           "model_ms is cumulative model time (including retries/backoff), not wall time; prompt_tokens is cumulative input (including repeated context and cache), not fees, and excludes parent-session usage and tool-result usage; uncached_prompt_tokens=prompt_tokens-prompt_cache_hit_tokens requires nonnegative integer fields and cache<=prompt.",
                           "by_creation groups child header.forked_from as fork/new: valid {session,message_count} means fork, missing means new (including old logs), explicitly invalid means unknown; session must be a nonempty string and message_count a nonnegative integer. Parent-system groups use the same grouping.",
                           "first_request_cache_hit_rate distributes cache/prompt for each child session's first complete Step (equal session weights); requires full-range sessions and valid first-Step prompt/cache with cache<=prompt and prompt>0. Later valid usage does not substitute; inherited header history is excluded.",
                           "by_parent_system joins parent_session_id to the parent header.system_sha in the input logs; missing parent logs or invalid tags mean unknown, with no fallback to the child system_sha. --group-by still uses each log's own header."])


CACHE_BLOCK = 64
CACHE_CAUSES = ('effort_change', 'compaction', 'background', 'user_message', 'unknown')


class CacheStats:
    def __init__(self):
        self.steps = self.skipped = 0
        self.prompt = self.uncached = self.cached = self.output = 0
        self.session_first = self.inherent = self.rounding = 0
        self.turn_start = self.mid_turn = 0
        self.causes = dict.fromkeys(CACHE_CAUSES, 0)
        self.largest = []
        self.turns = []

    @staticmethod
    def new_session():
        return dict(previous=None, effort=None, causes=set(), first=True, uncached=None)

    @staticmethod
    def note_messages(state, messages):
        for m in messages:
            if m['role'] == 'user':
                background = m.get('source') in ('background', 'background_agent')
                state['causes'].add('background' if background else 'user_message')

    @staticmethod
    def note_compaction(state):
        state['causes'] = {'compaction'}

    @staticmethod
    def reset(state):
        state.update(previous=None, effort=None, causes=set(), first=False)

    def finish_turn(self, state):
        if state['uncached'] is not None:
            self.turns.append(state['uncached'])
        state['uncached'] = None

    def add(self, state, record, session, turn_step):
        if turn_step == 1:
            self.finish_turn(state)
        causes, state['causes'] = state['causes'], set()
        previous, state['previous'] = state['previous'], None
        first, state['first'] = state['first'], False
        effort = record.get('effort')
        effort = effort if isinstance(effort, str) and effort.strip() else None
        previous_effort, state['effort'] = state['effort'], effort
        u = record.get('usage')
        if not (isinstance(u, dict) and all(number(u.get(k)) for k in TOKEN_KEYS)
                and u['prompt_tokens'] > 0 and u['prompt_cache_hit_tokens'] <= u['prompt_tokens']):
            return
        prompt, hit = u['prompt_tokens'], u['prompt_cache_hit_tokens']
        state['previous'] = prompt
        if not first and (previous is None or not number(turn_step) or turn_step < 1):
            self.skipped += 1
            return
        uncached = prompt - hit
        self.steps += 1
        self.prompt += prompt
        self.uncached += uncached
        self.cached += hit
        self.output += u['completion_tokens']
        state['uncached'] = (state['uncached'] or 0) + uncached
        if first:
            self.session_first += uncached
            return
        expected = min(previous, prompt)
        lost = max(0, expected - hit - CACHE_BLOCK)
        inherent = max(0, prompt - expected)
        self.inherent += inherent
        self.rounding += uncached - inherent - lost
        if not lost:
            return
        if turn_step == 1:
            cause = 'turn_start'
            self.turn_start += lost
        else:
            if effort is not None and previous_effort is not None and effort != previous_effort:
                cause = 'effort_change'
            else:
                cause = next((c for c in ('compaction', 'background', 'user_message') if c in causes), 'unknown')
            self.mid_turn += lost
            self.causes[cause] += lost
        self.largest.append(dict(session_id=session[:8], turn_step=turn_step, previous_prompt=previous,
                                 prompt_tokens=prompt, prompt_cache_hit_tokens=hit, lost=lost, cause=cause))
        self.largest.sort(key=lambda item: -item['lost'])
        del self.largest[5:]

    def report(self):
        def share(value, whole):
            return value / whole if whole else None
        return dict(
            steps=self.steps, skipped_steps=self.skipped,
            prompt_tokens=self.prompt, uncached_input_tokens=self.uncached,
            cached_input_tokens=self.cached, output_tokens=self.output,
            hit_rate=share(self.cached, self.prompt),
            tokens=dict(session_first=self.session_first, inherent=self.inherent,
                        turn_start=self.turn_start, mid_turn=self.mid_turn, rounding=self.rounding),
            shares={name: share(value, self.uncached) for name, value in
                    dict(session_first=self.session_first, inherent=self.inherent,
                         turn_start=self.turn_start, mid_turn=self.mid_turn, rounding=self.rounding).items()},
            mid_turn_causes={name: dict(tokens=tokens, share=share(tokens, self.mid_turn))
                             for name, tokens in self.causes.items()},
            largest_losses=self.largest,
            uncached_per_turn=distribution(self.turns),
            notes=["Root-session complete Steps with prompt_tokens>0 and cache-hit<=prompt; child sessions excluded. Expected cache = min(previous Step prompt, this prompt); lost = max(0, expected - hit - 64) (64-token cache block rounding); inherent = max(0, prompt - expected). A Session's first Step is session_first (prompt - hit). rounding = uncached - inherent - lost (tolerance; negative when hit exceeds expected), so shares of uncached input sum to 1.",
                   "Losses at turn_step==1 are turn_start; later ones are mid_turn, attributed from changes since the previous Step, first match: effort_change (top-level effort differs), compaction (history replacement), background (background/background_agent user message), user_message (other user message: interjection, undo), else unknown. Steps without an adjacent selected predecessor (filter, interruption, missing usage) or turn_step are excluded from the section, never zero-filled; skipped_steps counts them. uncached_per_turn sums uncached input per root Turn."])


class EffortStats:
    def __init__(self):
        self.groups = {}
        self.cache_transitions = {}

    def add(self, record):
        effort = record.get('effort')
        if not isinstance(effort, str) or not effort.strip():
            return
        group = self.groups.setdefault(effort, dict(steps=0, model_ms=[], steps_with_cache_usage=0,
            prompt_tokens=0, prompt_cache_hit_tokens=0))
        group['steps'] += 1
        if number(record.get('model_ms')):
            group['model_ms'].append(record['model_ms'])
        usage = record.get('usage')
        if isinstance(usage, dict) and all(number(usage.get(k)) for k in CACHE_TOKEN_KEYS):
            group['steps_with_cache_usage'] += 1
            for key in CACHE_TOKEN_KEYS:
                group[key] += usage[key]

    def add_transition(self, previous, record, header):
        if previous is None:
            return
        for step in (previous, record):
            effort, usage = step.get('effort'), step.get('usage')
            if (not isinstance(effort, str) or not effort.strip() or not isinstance(usage, dict)
                    or not all(number(usage.get(key)) for key in CACHE_TOKEN_KEYS)):
                return
        usage = record['usage']
        if usage['prompt_tokens'] <= 0:
            return
        group = tuple(header.get(key) if isinstance(header.get(key), str) and header[key].strip()
                      else 'unknown' for key in ('provider', 'model'))
        transitions = self.cache_transitions.setdefault(group, dict(same_effort=[], different_effort=[]))
        kind = 'same_effort' if previous['effort'] == record['effort'] else 'different_effort'
        transitions[kind].append(usage['prompt_cache_hit_tokens'] / usage['prompt_tokens'])

    def report(self):
        groups = {}
        for effort, group in sorted(self.groups.items()):
            groups[effort] = dict(group, model_ms=distribution(group['model_ms']),
                cache_hit_rate=group['prompt_cache_hit_tokens'] / group['prompt_tokens']
                               if group['prompt_tokens'] else None)
        def cache_summary(values):
            return dict(samples=len(values), median=median(values) if values else None,
                        mean=sum(values) / len(values) if values else None)

        return dict(by_effort=groups,
                    cache_transitions=[dict(provider=provider, model=model,
                        **{kind: cache_summary(values) for kind, values in transitions.items()})
                        for (provider, model), transitions in sorted(self.cache_transitions.items())])


class ToolData:
    def __init__(self):
        self.step_bytes = {key: dict(samples=0, total_bytes=0)
                           for key in ('tool_bytes', 'output_bytes')}
        self.ratios = []
        self.tools = {}

    def add(self, record):
        for key, item in self.step_bytes.items():
            if number(record.get(key)):
                item['samples'] += 1
                item['total_bytes'] += record[key]
        results = record.get('run_results')
        for result in results if isinstance(results, list) else []:
            if not isinstance(result, dict):
                continue
            tool, output = result.get('tool_bytes'), result.get('output_bytes')
            if number(tool) and tool > 0 and number(output):
                self.ratios.append(output / tool)
        calls = record.get('calls')
        for call in calls if isinstance(calls, list) else []:
            if not isinstance(call, dict):
                continue
            name, size = call.get('name'), call.get('result_bytes')
            if isinstance(name, str) and name and number(size):
                item = self.tools.setdefault(name, dict(count=0, result_bytes=0))
                item['count'] += 1
                item['result_bytes'] += size

    def report(self):
        total = sum(item['result_bytes'] for item in self.tools.values())
        return dict(step_bytes={key: dict(item) for key, item in self.step_bytes.items()},
                    output_tool_ratio=distribution(self.ratios),
                    result_bytes=total,
                    tools={name: dict(item, ratio=item['result_bytes'] / total if total else None)
                           for name, item in sorted(self.tools.items())},
                    notes=["Step-level tool_bytes/output_bytes accumulate independently, without adding Run or calls values or backfilling from other levels; missing or invalid fields are skipped.",
                           "output_tool_ratio is output_bytes/tool_bytes per Run (not a ratio of totals), requiring valid fields and tool_bytes>0; p90=nearest-rank; it may exceed 1. Tool shares use the sum of valid calls[].result_bytes, grouped by name, independent of timing; missing or omitted calls are not zero-filled, and zero total bytes means n/a."])


class AgentStats:
    def __init__(self):
        self.counts = {kind: dict(foreground_calls=0, background_calls=0, steps=[])
                       for kind in ('agent', 'bash', 'run')}

    def add(self, record, completed_steps, include, pending, seen, is_step=False, allow_agent=True):
        if not include:
            pending.clear()
            return
        event = record.get('background') or record.get('background_agent')
        if isinstance(event, dict):
            task_id, state = event.get('id'), event.get('state')
            kind = event.get('kind', 'agent')
            if isinstance(task_id, str) and task_id and isinstance(kind, str) and kind in self.counts and (kind != 'agent' or allow_agent):
                if state == 'started':
                    seen.add(task_id)
                    self.counts[kind]['background_calls'] += 1
                    pending[task_id] = dict(kind=kind, launch=completed_steps + 1,
                                            terminal=False, result=None)
                elif state in ('finished', 'lost') and task_id in pending:
                    pending[task_id]['terminal'] = True
                    self.complete(task_id, pending)
            return
        for message in record['messages']:
            if message.get('source') not in ('background', 'background_agent'):
                continue
            task_id = message.get('background_id', message.get('background_agent_id'))
            kind = message.get('background_kind', 'agent')
            if isinstance(task_id, str) and task_id in pending and pending[task_id]['kind'] == kind:
                pending[task_id]['result'] = completed_steps
                self.complete(task_id, pending)
        if not is_step:
            return
        calls = record.get('calls')
        for call in calls if isinstance(calls, list) else []:
            if not isinstance(call, dict) or call.get('dispatched') is False:
                continue
            kind = call.get('name')
            if not isinstance(kind, str) or kind not in self.counts or (kind == 'agent' and not allow_agent):
                continue
            if call.get('background') is True:
                task_id = call.get('id')
                if isinstance(task_id, str) and task_id and task_id not in seen:
                    self.counts[kind]['background_calls'] += 1
                    pending[task_id] = dict(kind=kind, launch=completed_steps + 1,
                                            terminal=True, result=None)
            else:
                self.counts[kind]['foreground_calls'] += 1

    def complete(self, task_id, pending):
        item = pending[task_id]
        if item['terminal'] and item['result'] is not None:
            if item['result'] >= item['launch']:
                self.counts[item['kind']]['steps'].append(item['result'] - item['launch'])
            del pending[task_id]

    def report(self, kind='agent'):
        counts = self.counts[kind]
        return dict(foreground_calls=counts['foreground_calls'],
                    background_calls=counts['background_calls'],
                    background_steps=distribution(counts['steps']),
                    notes=["Foreground counts use valid calls[]; agent counts only root sessions, bash includes children. Background counts prefer background.started lifecycle records, falling back to calls[] for old logs; dispatched=false is excluded, and missing details do not add foreground calls.",
                           "background_steps joins started, finished/lost, and source=background result messages by id; old logs join calls[].id to result messages. Count only complete main-model Steps after the starting Step and before result insertion, in the same root session, fully selected and uninterrupted."])


class Timing:
    def __init__(self):
        self.values = {key: [] for key in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms',
                                         'first_data_ms', 'max_gap_ms', 'code_first_ms', 'code_span_ms', 'attempts')}
        self.effort = EffortStats()
        self.tools = {}
        self.bash = {}
        self.calls_steps = self.calls_omitted = self.bash_unmatched = 0
        self.bash_sources = Counter(recorded=0, static=0)

    def add(self, record, sources, run_statuses=(), recorded_commands=None):
        self.effort.add(record)
        for key in ('model_ms', 'run_ms', 'first_data_ms', 'max_gap_ms', 'attempts'):
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
        recorded_commands = recorded_commands or {}
        bash_ordinals = Counter()
        ambiguous_runs = {c.get('run_index') for c in calls if isinstance(c, dict)
                          and c.get('name') == 'bash' and c.get('dispatched') is False
                          and number(c.get('run_index'))}
        for call in calls:
            if not isinstance(call, dict):
                continue
            index = call.get('run_index')
            ordinal = bash_ordinals[index] if number(index) else 0
            if call.get('name') == 'bash' and number(index):
                bash_ordinals[index] += 1
            name, start, end = call.get('name'), call.get('start_ms'), call.get('end_ms')
            if not isinstance(name, str) or not name or not number(start) or not number(end) or end < start:
                continue
            duration = end - start
            self.tools.setdefault(name, []).append(duration)
            if name != 'bash':
                continue
            group = None
            group_source = 'static'
            recorded = recorded_commands.get(index) if number(index) else None
            if (recorded is not None and len(recorded) == bash_per_run[index]
                    and (len(recorded) == 1 or index not in ambiguous_runs)
                    and isinstance(recorded[ordinal], str)):
                group = bash_command_group(recorded[ordinal])
                group_source = 'recorded'
            elif number(index) and index < len(results) and bash_per_run[index] == 1:
                result = results[index]
                call_id = result.get('tool_call_id') if isinstance(result, dict) else None
                source = sources.get(call_id) if isinstance(call_id, str) else None
                if source is not None:
                    group = bash_timing_group(source)
            if group is None:
                self.bash_unmatched += 1
            else:
                self.bash.setdefault(group, []).append(duration)
                self.bash_sources[group_source] += 1

    def report(self):
        def tool_summary(values):
            return dict(count=len(values), total_ms=sum(values), median_ms=median(values))
        spans = self.values['code_span_ms']
        streamed = sum(span > 50 for span in spans)
        summaries = {key: distribution(values) for key, values in self.values.items()}
        summaries['max_gap_ms']['max'] = max(self.values['max_gap_ms'], default=None)
        return dict(summaries,
                    effort=self.effort.report(),
                    calls_steps=self.calls_steps, calls_omitted=self.calls_omitted,
                    tools={name: tool_summary(values) for name, values in sorted(self.tools.items())},
                    streaming=dict(samples=len(spans), over_50_ms=streamed,
                                   ratio=streamed / len(spans) if spans else None),
                    bash=dict(heuristic=True, sources=dict(self.bash_sources),
                              matched_calls=sum(map(len, self.bash.values())),
                              unmatched_calls=self.bash_unmatched,
                              top10=[dict(command=name, **tool_summary(values)) for name, values in
                                     sorted(self.bash.items(), key=lambda p: (-sum(p[1]), p[0]))[:10]]))


READ_PATH = re.compile(r'''\btools\.read\s*\(\s*\{[^{}]*?["']?path["']?\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')''', re.S)
OMITTED_MARKER = re.compile(r'\[\d+ of \d+ bytes omitted')
EXPLORE_TOOLS = frozenset(('read', 'grep', 'glob'))


class Exploration:
    """Root-Session exploration cost: Steps before the first edit, re-reads, display truncation."""

    def __init__(self):
        self.turns = 0
        self.edit_positions = []
        self.reads = self.rereads = self.unknown_reads = 0
        self.runs = dict(all=[0, 0], explore=[0, 0])

    @staticmethod
    def new_turn():
        return dict(edit=None, steps=[])

    def add_step(self, turn, position, record, runs, outputs):
        calls = [c for c in record.get('calls') or [] if isinstance(c, dict)]
        by_run = {}
        for call in calls:
            by_run.setdefault(call.get('run_index'), []).append(call)
        edited = any(c.get('name') in ('edit', 'write') and c.get('dispatched') is not False for c in calls)
        if not calls:
            edited = any(name in ('edit', 'write') for _, code, _ in runs if isinstance(code, str)
                         for name in TOOL_CALL.findall(code))
        reads = []
        for index, (call_id, code, _) in enumerate(runs):
            run_calls = by_run.get(index, [])
            read_calls = [c for c in run_calls if c.get('name') == 'read' and c.get('dispatched') is not False]
            literal = [literal_string(m) for m in READ_PATH.findall(code)] if isinstance(code, str) else []
            if not calls:
                reads.extend(path if isinstance(path, str) else None for path in literal)
            for n, call in enumerate(read_calls):
                path = call.get('path')
                if not isinstance(path, str) and len(literal) == len(read_calls):
                    path = literal[n]
                reads.append(path if isinstance(path, str) else None)
        turn['steps'].append((position, reads))
        if edited and turn['edit'] is None:
            turn['edit'] = position
        results = record.get('run_results') if isinstance(record.get('run_results'), list) else []
        for index, (call_id, _, _) in enumerate(runs):
            result = results[index] if index < len(results) and isinstance(results[index], dict) else {}
            text = outputs.get(call_id)
            if text is not None:
                hit = bool(OMITTED_MARKER.search(text))
            elif number(result.get('tool_bytes')) and number(result.get('output_bytes')):
                hit = result['tool_bytes'] > result['output_bytes']
            else:
                continue
            names = ({c.get('name') for c in by_run.get(index, [])} if calls else
                     set(TOOL_CALL.findall(runs[index][1])) if isinstance(runs[index][1], str) else set())
            kinds = ['all'] + (['explore'] if names and names <= EXPLORE_TOOLS and not record.get('calls_omitted') else [])
            for kind in kinds:
                self.runs[kind][0] += hit
                self.runs[kind][1] += 1

    def finish_turn(self, turn):
        self.turns += 1
        if turn['edit'] is None:
            return
        self.edit_positions.append(turn['edit'])
        seen = set()
        for position, reads in turn['steps']:
            if position >= turn['edit']:
                break
            for path in reads:
                if path is None:
                    self.unknown_reads += 1
                    continue
                self.reads += 1
                self.rereads += path in seen
                seen.add(path)

    def report(self):
        def share(pair):
            return dict(count=pair[0], runs=pair[1], ratio=pair[0] / pair[1] if pair[1] else None)
        return dict(
            turns=self.turns,
            steps_before_first_edit=distribution(self.edit_positions),
            turns_without_edit=dict(count=self.turns - len(self.edit_positions), turns=self.turns,
                                    ratio=(self.turns - len(self.edit_positions)) / self.turns if self.turns else None),
            reread_before_first_edit=dict(rereads=self.rereads, reads=self.reads, unknown_path_reads=self.unknown_reads,
                                          ratio=self.rereads / self.reads if self.reads else None),
            truncated_runs=share(self.runs['all']),
            truncated_explore_runs=share(self.runs['explore']),
            notes=["Root-Session Turns only. steps_before_first_edit is the 1-based Step of the first edit/write call in each Turn that has one; turns_without_edit are excluded from it. Re-reads count read calls whose path was read earlier in the same Turn, using only Steps before the first edit (Turns without edits are excluded); paths come from calls[].path, else literal tools.read({path}) in the Run code, else the read is counted as unknown. Truncated Runs contain the omitted-bytes marker in the logged tool message (fallback tool_bytes>output_bytes); explore Runs call only read/grep/glob."])


def records(path):
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
                if isinstance(record.get('bash'), dict) and record['bash'].get('state') in ('started', 'finished', 'superseded'):
                    yield record
                    continue
                event = record.get('background') or record.get('background_agent')
                if (isinstance(event, dict) and isinstance(event.get('id'), str)
                        and event.get('state') in ('started', 'finished', 'lost')):
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


def transport_group(record):
    value = record.get('transport')
    return value if value in ('sse', 'websocket') else 'unknown'


def step_group(record, field):
    if field == 'transport':
        return transport_group(record)
    if field == 'full_reason':
        value = record.get('full_reason')
        return value if isinstance(value, str) and value else 'incremental' if record.get('incremental') is True else 'unknown'
    value = record.get('incremental')
    return str(value).lower() if isinstance(value, bool) else 'unknown'


def summarize(paths, since=None, cwd=None, group_by=None, *, _systems=None, _step_filter=None):
    if group_by not in (None, 'version', 'system', 'patches', 'profile', 'transport', 'incremental', 'full_reason'):
        raise ValueError('invalid group_by')
    paths = list(paths)
    if _systems is None:
        _systems = {}
        for path in paths:
            if path.name.endswith('.calls.jsonl'):
                continue
            header = next(records(path), None)
            if header and header.get('messages') and header['messages'][0]['role'] == 'system':
                _systems[path.stem] = header_group(header, 'system')
    group_paths = {}
    adjacent_pairs = write_validation_pairs = file_pairs = disjoint_pairs = 0
    mechanical = dict(count=0, samples=0, ms=0, sample_ms=0, timed_samples=0, timed_count=0,
                      sources=dict(recorded=0, static=0, mixed=0),
                      hit_sources=dict(recorded=0, static=0, mixed=0))
    totals = dict(sessions=0, root_sessions=0, child_sessions=0, turns=0, steps=0, runs=0,
                  runs_failed=0, runs_with_status=0, runs_unknown=0, steps_with_usage=0,
                  steps_with_ms=0, timed_turns=0)
    cutoff_ms = int(datetime.combine(since, datetime.min.time()).timestamp() * 1000) if since else None
    time_filter = dict(selected_records_with_at=0, selected_records_using_mtime=0,
                       selected_steps_using_mtime=0)
    usage = dict.fromkeys(TOKEN_KEYS, 0)
    tool_counts, bash_counts = Counter(), Counter()
    timing = Timing()
    tool_data = ToolData()
    bash_superseded = 0
    agents = AgentStats()
    child_costs = ChildCosts()
    exploration = Exploration()
    cache_stats = CacheStats()
    errors = {name: {'count': 0, 'examples': []} for name in ERRORS}
    slowest, turn_steps, turn_times = [], [], []

    def error(name, text, session):
        item = errors[name]
        item['count'] += 1
        example = {'session_id': session[:8], 'text': ' '.join(text.split())[:180]}
        if len(item['examples']) < 2 and example not in item['examples']:
            item['examples'].append(example)

    for path in paths:
        if path.name.endswith('.calls.jsonl'):
            continue
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
        if group_by is not None and group_by not in ('transport', 'incremental', 'full_reason'):
            group_paths.setdefault(header_group(header, group_by), []).append(path)

        def selected(record):
            at = record.get('at')
            return ((cutoff_ms is None or (at if number(at) else mtime_ms) >= cutoff_ms)
                    and (_step_filter is None or step_group(record, _step_filter[0]) == _step_filter[1]))

        session_selected = selected(header)
        length = header['from'] + len(header['messages'])
        current = None
        session_step = 0
        cache_state = CacheStats.new_session()
        is_root = not header.get('parent_session_id')
        child_selected_steps = 0
        child_model_ms, child_prompt_tokens, child_uncached_prompt_tokens = [], [], []
        child_first_request_cache_hit_rate = None
        recorded_steps = 0
        recorded_commands = recorded_bash_commands(path)
        mechanical_recordings = complete_recorded_calls(path)
        pending_agents = {}
        seen_agents = set()

        def finish_turn():
            if current is not None and current['selected']:
                if not header.get('parent_session_id'):
                    exploration.finish_turn(current['exploration'])
                totals['turns'] += 1
                turn_steps.append(current['steps'])
                if (current['complete'] and current['steps'] and
                        current['steps'] == current['full_steps'] == current['timed']):
                    turn_times.append(current['ms'])

        for record in log:
            include = selected(record)
            if not include:
                CacheStats.reset(cache_state)
            if not include and current is not None:
                current['previous_effort'] = None
                current['mechanical_previous'] = None
            has_at = number(record.get('at'))
            if isinstance(record.get('bash'), dict):
                if include and record['bash'].get('state') == 'superseded':
                    bash_superseded += 1
                if include:
                    session_selected = True
                    time_filter['selected_records_with_at' if has_at else 'selected_records_using_mtime'] += 1
                continue
            diagnostic = isinstance(record.get('diagnostic'), dict)
            lifecycle = isinstance(record.get('background') or record.get('background_agent'), dict)
            if not diagnostic and not lifecycle:
                messages = record['messages']
                replacement = record['from'] < length
                length = record['from'] + len(messages)
                if replacement:
                    if include:
                        CacheStats.note_compaction(cache_state)
                    if current is not None:
                        current['previous_effort'] = None
                        current['mechanical_previous'] = None
                    continue
                recorded_step = recorded_steps + 1
                recorded_steps += sum(m['role'] == 'assistant' for m in messages)
            if include:
                session_selected = True
                time_filter['selected_records_with_at' if has_at else 'selected_records_using_mtime'] += 1
            if diagnostic:
                if include:
                    error('provider_failure', record['diagnostic']['message'], path.stem)
                continue
            if lifecycle:
                agents.add(record, session_step, include, pending_agents, seen_agents,
                           allow_agent=not header.get('parent_session_id'))
                continue
            if include:
                CacheStats.note_messages(cache_state, messages)
            turn_step = record.get('turn_step')
            explicit_turn = number(turn_step) and turn_step > 0
            new_turn = (turn_step == 1 if explicit_turn else any(m['role'] == 'user' and m.get('source') not in ('background', 'background_agent', 'undo') for m in messages))
            if new_turn or (explicit_turn and current is None):
                finish_turn()
                current = dict(steps=0, full_steps=0, timed=0, ms=0, complete=False, selected=False,
                               previous=None, previous_effort=None, mechanical_previous=None,
                               exploration=Exploration.new_turn())
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
                        current['previous_effort'] = None
                        current['mechanical_previous'] = None
            is_step = any(m['role'] == 'assistant' for m in messages) and not interrupted
            if interrupted:
                CacheStats.reset(cache_state)
            if interrupted:
                pending_agents.clear()
            agents.add(record, session_step, include, pending_agents, seen_agents, is_step,
                       allow_agent=not header.get('parent_session_id'))
            if not is_step:
                continue
            session_step += 1
            if include and header.get('parent_session_id'):
                child_selected_steps += 1
                if number(record.get('model_ms')):
                    child_model_ms.append(record['model_ms'])
                child_usage = record.get('usage')
                if isinstance(child_usage, dict) and number(child_usage.get('prompt_tokens')):
                    child_prompt_tokens.append(child_usage['prompt_tokens'])
                    cache = child_usage.get('prompt_cache_hit_tokens')
                    if number(cache) and cache <= child_usage['prompt_tokens']:
                        child_uncached_prompt_tokens.append(child_usage['prompt_tokens'] - cache)
                        if session_step == 1 and child_usage['prompt_tokens'] > 0:
                            child_first_request_cache_hit_rate = cache / child_usage['prompt_tokens']
            if current is not None:
                current['full_steps'] += 1
                current['complete'] = any(m['role'] == 'assistant' and not m.get('tool_calls') and not m.get('waiting') for m in messages)
            if not include:
                if current is not None:
                    current['previous'] = None
                continue
            if group_by in ('transport', 'incremental', 'full_reason'):
                group_paths.setdefault(step_group(record, group_by), set()).add(path)
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
                writes = u.get('prompt_cache_write_tokens', 0)
                if number(writes) and writes > 0:
                    usage['prompt_cache_write_tokens'] = usage.get('prompt_cache_write_tokens', 0) + writes
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
            sources, run_statuses, step_codes, step_runs = {}, [], [], []
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
                    step_runs.append((call_id, None, None))
                    if ok is not None:
                        totals['runs_with_status'] += 1
                        totals['runs_failed'] += not ok
                    try:
                        args = json.loads(function.get('arguments', ''))
                    except (ValueError, TypeError, RecursionError):
                        args = None
                    code = args.get('code') if isinstance(args, dict) else None
                    step_codes.append(code)
                    step_runs[-1] = (call_id, code, None)
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
            timing.add(record, sources, run_statuses, recorded_commands.get(recorded_step))
            if current is not None and not header.get('parent_session_id'):
                exploration.add_step(current['exploration'], turn_step if explicit_turn else current['full_steps'],
                                     record, step_runs, outputs)
            tool_data.add(record)
            if is_root and current is not None:
                cache_stats.add(cache_state, record, path.stem, turn_step if explicit_turn else None)
            if current is not None:
                timing.effort.add_transition(current['previous_effort'], record, header)
                current['previous_effort'] = record
                structure = step_structure(step_codes, header.get('cwd') if isinstance(header.get('cwd'), str) else None)
                previous = current['previous']
                if previous is not None:
                    adjacent_pairs += 1
                    write_validation_pairs += previous['writes'] and structure['validation']
                    if previous['paths'] is not None and structure['paths'] is not None:
                        file_pairs += 1
                        disjoint_pairs += previous['paths'].isdisjoint(structure['paths'])
                current['previous'] = structure
                previous_mechanical = current['mechanical_previous']
                position = turn_step if explicit_turn else current['full_steps']
                if (position > 1 and previous_mechanical is not None
                        and previous_mechanical['position'] == position - 1
                        and previous_mechanical['ok']):
                    hit, source = mechanical_step(step_codes, recorded_step, mechanical_recordings)
                    mechanical['samples'] += 1
                    mechanical['sources'][source] += 1
                    mechanical['count'] += hit
                    mechanical['hit_sources'][source] += hit
                    if number(ms):
                        mechanical['timed_samples'] += 1
                        mechanical['sample_ms'] += ms
                        mechanical['timed_count'] += hit
                        mechanical['ms'] += ms if hit else 0
                current['mechanical_previous'] = dict(
                    position=position, ok=bool(run_statuses) and all(ok is True for ok in run_statuses))
        finish_turn()
        cache_stats.finish_turn(cache_state)
        if session_selected:
            totals['sessions'] += 1
            totals['child_sessions' if header.get('parent_session_id') else 'root_sessions'] += 1
            if header.get('parent_session_id'):
                parent_id = header['parent_session_id']
                parent_system = _systems.get(parent_id, 'unknown') if isinstance(parent_id, str) else 'unknown'
                fork = header.get('forked_from')
                creation = ('new' if 'forked_from' not in header else
                            'fork' if isinstance(fork, dict) and isinstance(fork.get('session'), str)
                            and fork['session'].strip() and number(fork.get('message_count')) else 'unknown')
                child_costs.add(session_step, child_selected_steps, child_model_ms,
                                child_prompt_tokens, child_uncached_prompt_tokens, parent_system,
                                creation, child_first_request_cache_hit_rate)
    totals['runs_unknown'] = totals['runs'] - totals['runs_with_status']
    totals['run_failure_rate'] = totals['runs_failed'] / totals['runs_with_status'] if totals['runs_with_status'] else None
    totals['avg_steps_per_turn'] = sum(turn_steps) / len(turn_steps) if turn_steps else None
    totals['timed_turns'] = len(turn_times)
    totals['avg_turn_ms'] = sum(turn_times) / len(turn_times) if turn_times else None
    usage['total_tokens'] = usage['prompt_tokens'] + usage['completion_tokens']
    usage['cache_hit_rate'] = usage['prompt_cache_hit_tokens'] / usage['prompt_tokens'] if usage['prompt_tokens'] else None
    mechanical['ratio'] = mechanical['count'] / mechanical['samples'] if mechanical['samples'] else None
    mechanical['time_ratio'] = mechanical['ms'] / mechanical['sample_ms'] if mechanical['sample_ms'] else None
    def pair_summary(count, pairs):
        return dict(count=count, pairs=pairs, ratio=count / pairs if pairs else None)

    report = {'overall': totals, 'usage': usage, 'time_filter': time_filter, 'tools': dict(sorted(tool_counts.items())),
            'bash_superseded': bash_superseded,
            'bash_top10': [{'command': k, 'count': v} for k, v in sorted(bash_counts.items(), key=lambda p: (-p[1], p[0]))[:10]],
            'errors': errors, 'slowest_steps': slowest, 'timing': timing.report(),
            'tool_data': tool_data.report(), 'child_costs': child_costs.report(),
            'agents': agents.report(), 'bash_calls': agents.report('bash'), 'background_runs': agents.report('run'),
            'exploration': exploration.report(), 'cache': cache_stats.report(),
            'round_trips': dict(steps_per_turn=distribution(turn_steps),
                               write_to_validation=pair_summary(write_validation_pairs, adjacent_pairs),
                               mechanical_followups=mechanical,
                               disjoint_write_files=pair_summary(disjoint_pairs, file_pairs),
                               notes=["Mechanical follow-up samples are adjacent Steps in the same Turn, with later turn_step>1 (estimated from Turn order for old logs), and at least one Run in the earlier Step, all explicitly ok=true; do not cross filters, cancellations, or compaction replacements. A hit later Step calls only bash/read; all bash commands use the write-to-validation validation/status heuristic; no calls means no hit. ratio=count/samples; time_ratio=later-Step ms for timed hits/later-Step ms for timed samples, with no zero-fill. Complete per-Run recordings prefer actual tools and args.command; missing/incomplete recordings fall back to static extraction; sources/hit_sources count sampled/hit Steps as recorded/static/mixed (some Runs fall back).",
                                      "Step distributions use selected Turns (including zero-Step Turns; old logs estimate boundaries from user messages); adjacent pairs stay within a Turn and do not cross filtering/cancellation gaps. Write-to-validation uses all adjacent pairs as denominator; the later Step contains only static validation bash, using the first-two-words heuristic.",
                                      "Consecutive-write samples require complete literal paths in direct edit/write calls on both sides (normalized by cwd); only disjoint file sets count as different files. Dynamic/unknown calls are skipped; bash side effects are not inferred, and fmt counts as validation."]),
            'notes': ["Only selected records count; failure rates use explicit run_results only; token=prompt+completion (cache is not added again), cache rate uses prompt as denominator; error categories may overlap, and tool/command counts are static estimates.",
                      "Average Turn time includes only finished Turns with all Steps selected and ms present; --since uses record at (local dates), with missing or invalid at falling back to file modification time.",
                      f"Time sources: {time_filter['selected_records_with_at']} records by at, {time_filter['selected_records_using_mtime']} records using file time (including {time_filter['selected_steps_using_mtime']} complete Steps); timing uses valid fields only, without zero-fill; p90=nearest-rank; first_data_ms is the first receipt of any stream data, not a content token; model_ms includes retries/backoff.",
                      "run_ms is total Run time within a Step; run_result_ms is per Run; code_first_ms is the wait for the first code fragment, code_span_ms=last-first, and streaming is the fraction >50 ms. calls includes failures; parallel durations can overlap. Bash timing splits on &&/||/;/|/newlines (excluding quoted text and heredoc bodies), joining each segment's first two words with \u2192; prefer actual args.command from calls.jsonl, falling back to static literals for old logs. timing.bash.sources counts successfully grouped recorded/static entries; unjoinable or ungroupable entries are unmatched. Durations remain whole-bash durations, not subcommand durations. Write-to-validation still uses only static extraction; the shared classifier also recognizes git status/log/fetch/show, gh pr view/checks, and tail/cat/ls/head/pwd. These status commands may increase hits; read still does not count as validation-only. timing.effort.by_effort groups complete Steps by top-level effort, skipping missing effort but counting Steps without timing; cache rate is the ratio of sums of valid prompt/cache pairs. timing.effort.cache_transitions groups by header provider/model (unknown if missing), comparing equal/different effort in adjacent selected complete Steps of the same Turn, and reports samples/median/mean of later-Step cache/prompt (equal Step weights, not token weights). Skip pairs missing effort or valid prompt/cache; later prompt must be positive. Do not cross filters/cancellations/compaction gaps or zero-fill."]}

    if group_by is not None:
        report['group_by'] = group_by
        report['groups'] = {}
        for key, members in sorted(group_paths.items()):
            group = summarize(members, since, cwd, _systems=_systems,
                              _step_filter=(group_by, key) if group_by in ('transport', 'incremental', 'full_reason') else None)
            if group['overall']['sessions']:
                report['groups'][key] = group
        report['notes'][0] += (' --group-by transport/incremental/full_reason groups complete Steps by actual transport/continuation state; one session may appear in multiple groups; missing fields mean unknown. Filter by record; mixed-transport Turns are not complete wall-time samples. Other groups use header nib_version/system_sha/patches_off/profile; '
            'missing/invalid values mean unknown; missing patches_off with valid nib_version or system_sha means none; '
            'explicitly empty patch sets also mean none; patch arrays group as deduplicated sorted sets, with the complete core report recomputed per group.')
    return report


def text_report(report):
    t, u = report['overall'], report['usage']
    def fmt(value, suffix=''):
        return 'n/a' if value is None else f'{value:.2f}{suffix}'
    def pct(value):
        return fmt(None if value is None else 100 * value, '%')
    def ratio_fmt(value):
        return 'n/a' if value is None else f'{value:.6g}'
    token_total = str(u['total_tokens']) if t['steps_with_usage'] else 'n/a'
    lines = [f"Sessions {t['sessions']} (root {t['root_sessions']} / child {t['child_sessions']}); Turn {t['turns']}; Step {t['steps']}; Run {t['runs']}",
             f"Run failures {t['runs_failed']}/{t['runs_with_status']} = {pct(t['run_failure_rate'])} (unknown status {t['runs_unknown']})",
             f"Token {token_total} (prompt {u['prompt_tokens']} / completion {u['completion_tokens']}); cache hits {pct(u['cache_hit_rate'])}; usage coverage {t['steps_with_usage']}/{t['steps']} Step",
             f"Average per Turn {fmt(t['avg_steps_per_turn'])} Steps; average time {fmt(t['avg_turn_ms'], ' ms')} (fully timed {t['timed_turns']}/{t['turns']} Turns, {t['steps_with_ms']} Steps)",
             'Tools (static call sites): ' + (', '.join(f'{k} {v}' for k, v in report['tools'].items()) or 'None'),
             'Top 10 bash commands: ' + (', '.join(f"{v['command']} {v['count']}" for v in report['bash_top10']) or 'None')]
    lines.append(f"Bash supersessions: {report['bash_superseded']}")
    for name, key in (('Agent', 'agents'), ('Bash', 'bash_calls'), ('Run', 'background_runs')):
        calls = report[key]
        overlap = calls['background_steps']
        lines.extend([f"{name} calls: foreground {calls['foreground_calls']} / background {calls['background_calls']}",
                      f"{'' if key == 'agents' else name + ' '}Main-model Steps during background work: samples={overlap['samples']} median={fmt(overlap['median'])} p90={fmt(overlap['p90'])}"])
    lines.extend('  ' + note for note in report['agents']['notes'])
    costs = report['child_costs']
    lines.append('Recorded child-session costs (per child; not fees):')
    cost_groups = []
    for label, item in [('all', costs)] + list(costs['by_parent_system'].items()):
        cost_groups.append((f'parent_system={label}', item))
        cost_groups.extend((f'parent_system={label} creation={kind}', group)
                           for kind, group in item['by_creation'].items())
    for label, item in cost_groups:
        lines.append(f"  {label}: sessions={item['sessions']} full_range={item['full_range_sessions']} partial_range={item['partial_range_sessions']} no_steps={item['no_step_sessions']}")
        for field in ('steps', 'model_ms', 'prompt_tokens', 'uncached_prompt_tokens', 'first_request_cache_hit_rate'):
            value = item[field]
            format_value = pct if field == 'first_request_cache_hit_rate' else fmt
            lines.append(f"    {field}: samples={value['samples']} median={format_value(value['median'])} p90={format_value(value['p90'])}")
    lines.extend('  ' + note for note in costs['notes'])
    ex = report['exploration']
    steps_to_edit = ex['steps_before_first_edit']
    reread = ex['reread_before_first_edit']
    lines.append('Exploration (root Turns):')
    lines.append(f"  Step of first edit: samples={steps_to_edit['samples']} median={fmt(steps_to_edit['median'])} p90={fmt(steps_to_edit['p90'])}; Turns without edit {ex['turns_without_edit']['count']}/{ex['turns_without_edit']['turns']} = {pct(ex['turns_without_edit']['ratio'])}")
    lines.append(f"  Re-read before first edit: {reread['rereads']}/{reread['reads']} reads = {pct(reread['ratio'])} (unknown path {reread['unknown_path_reads']})")
    for label, key in (('all Runs', 'truncated_runs'), ('read/grep/glob-only Runs', 'truncated_explore_runs')):
        item = ex[key]
        lines.append(f"  Truncated output, {label}: {item['count']}/{item['runs']} = {pct(item['ratio'])}")
    lines.extend('  ' + note for note in ex['notes'])
    structure = report['round_trips']
    steps = structure['steps_per_turn']
    section = ["Round-trip structure:", f"  Steps per Turn: samples={steps['samples']} median={fmt(steps['median'])} p90={fmt(steps['p90'])}"]
    for name, label in (('write_to_validation', 'write→validation only'), ('disjoint_write_files', 'consecutive writes to different files (disjoint)')):
        item = structure[name]
        section.append(f"  {label}: {item['count']}/{item['pairs']} = {pct(item['ratio'])} (samples={item['pairs']})")
    followups = structure["mechanical_followups"]
    section.append(f"  Mechanical follow-up Steps after success (mechanical follow-ups): {followups['count']}/{followups['samples']} = {pct(followups['ratio'])}; Step time {followups['ms']}/{followups['sample_ms']} ms = {pct(followups['time_ratio'])} (timed {followups['timed_count']}/{followups['timed_samples']})")
    for key, label in (("sources", "sample sources"), ("hit_sources", "hit sources")):
        section.append(f"    {label}: " + ", ".join(f"{name}={count}" for name, count in followups[key].items()))
    section.extend("  " + note for note in structure['notes'])
    lines[4:4] = section
    cache = report['cache']
    lines.append('Cache (root Steps; uncached input breakdown, tokens; not fees):')
    lines.append(f"  Steps {cache['steps']} (excluded {cache['skipped_steps']}); prompt {cache['prompt_tokens']} / uncached {cache['uncached_input_tokens']} / cached {cache['cached_input_tokens']} / output {cache['output_tokens']}; weighted hit rate {pct(cache['hit_rate'])}")
    lines.append('  Uncached input: ' + ', '.join(f"{name} {pct(cache['shares'][name])} ({cache['tokens'][name]})" for name in cache['tokens']))
    lines.append('  Mid-turn loss by cause: ' + ', '.join(f"{name} {item['tokens']} ({pct(item['share'])})" for name, item in cache['mid_turn_causes'].items()))
    turn = cache['uncached_per_turn']
    lines.append(f"  Uncached input per Turn: samples={turn['samples']} median={fmt(turn['median'])} p90={fmt(turn['p90'])}")
    lines.append('  5 largest losses (session, turn_step, prev prompt, prompt, hit, cause):')
    lines.extend(f"    {e['session_id']}  step {e['turn_step']}  {e['previous_prompt']} -> {e['prompt_tokens']}  hit {e['prompt_cache_hit_tokens']}  lost {e['lost']}  {e['cause']}" for e in cache['largest_losses'])
    if not cache['largest_losses']:
        lines.append('    None')
    lines.extend('  ' + note for note in cache['notes'])
    lines.append('Error categories:')
    for name, item in report['errors'].items():
        lines.append(f"  {name}: {item['count']}")
        lines.extend(f"    [{e['session_id']}] {e['text']}" for e in item['examples'])
    lines.append('5 slowest Steps:')
    lines.extend(f"  {s['session_id']}  {s['ms']} ms" for s in report['slowest_steps'])
    if not report['slowest_steps']:
        lines.append('  No timing records')
    timing = report['timing']
    lines.append('Time breakdown / Timing (ms; attempts are counts; missing fields are not zero-filled):')
    for name in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms', 'first_data_ms', 'max_gap_ms', 'code_first_ms', 'code_span_ms', 'attempts'):
        item = timing[name]
        maximum = f" max={fmt(item['max'])}" if name == 'max_gap_ms' else ''
        lines.append(f"  {name}: samples={item['samples']} median={fmt(item['median'])} p90={fmt(item['p90'])}{maximum}")
    effort = timing['effort']
    lines.append('  Step effort (top-level metadata):')
    for level, item in effort['by_effort'].items():
        lines.append(f"    {level}: steps={item['steps']} model_ms median={fmt(item['model_ms']['median'])} samples={item['model_ms']['samples']} cache_hit_rate={pct(item['cache_hit_rate'])} ({item['prompt_cache_hit_tokens']}/{item['prompt_tokens']})")
    if not effort['by_effort']:
        lines.append('    No effort records')
    lines.append('    effort cache transitions (adjacent fully selected complete Steps in the same Turn; later-Step cache/prompt):')
    for item in effort['cache_transitions']:
        lines.append(f"      provider={item['provider']} model={item['model']}")
        for kind in ('same_effort', 'different_effort'):
            summary = item[kind]
            lines.append(f"        {kind}: samples={summary['samples']} median={pct(summary['median'])} mean={pct(summary['mean'])}")
    if not effort['cache_transitions']:
        lines.append('      No valid transition samples')
    streaming = timing['streaming']
    lines.append(f"  code streaming (last-first > 50 ms): {streaming['over_50_ms']}/{streaming['samples']} = {pct(streaming['ratio'])}")
    lines.append(f"  Tool runtime timing (calls Steps={timing['calls_steps']}, omitted={timing['calls_omitted']}):")
    for name, item in timing['tools'].items():
        lines.append(f"    {name}: count={item['count']} total={item['total_ms']} ms median={fmt(item['median_ms'])} ms")
    if not timing['tools']:
        lines.append('    No timing records')
    bash = timing['bash']
    lines.append(f"  Top 10 bash timings (heuristic first two words per segment →; recorded={bash['sources']['recorded']}, static={bash['sources']['static']}; matched={bash['matched_calls']}, unmatched={bash['unmatched_calls']}):")
    for item in bash['top10']:
        lines.append(f"    {item['command']}: count={item['count']} total={item['total_ms']} ms median={fmt(item['median_ms'])} ms")
    if not bash['top10']:
        lines.append('    No matching timing records')
    data = report['tool_data']
    lines.append('Tool data metrics (bytes; missing fields are not zero-filled):')
    for name, item in data['step_bytes'].items():
        lines.append(f"  Step {name}: samples={item['samples']} total={item['total_bytes']} bytes")
    ratio = data['output_tool_ratio']
    lines.append(f"  Per-Run output_bytes/tool_bytes: samples={ratio['samples']} median={ratio_fmt(ratio['median'])} p90={ratio_fmt(ratio['p90'])}")
    lines.append(f"  Tool result_bytes shares (total {data['result_bytes']} bytes):")
    for name, item in data['tools'].items():
        lines.append(f"    {name}: count={item['count']} result_bytes={item['result_bytes']} ratio={pct(item['ratio'])}")
    if not data['tools']:
        lines.append('    No byte records')
    lines.extend('  ' + note for note in data['notes'])
    lines.extend(['Methodology:'] + ['  ' + note for note in report['notes']])
    if 'groups' in report:
        lines.append(f"Groups group_by={report['group_by']}:")
        for key, group in report['groups'].items():
            lines.append(f"=== {report['group_by']}={key} ===")
            lines.append(text_report(group))
        if not report['groups']:
            lines.append('  No selected groups')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path, help='session JSONL files or directories')
    parser.add_argument('--since', type=date.fromisoformat, metavar='YYYY-MM-DD', help='record date, inclusive, local time; legacy records fall back to file modification time')
    parser.add_argument('--cwd', type=Path, help='exact session working directory')
    parser.add_argument('--group-by', choices=('version', 'system', 'patches', 'profile', 'transport', 'incremental', 'full_reason'), help='group by session metadata, actual Step transport, incremental state or full-request reason')
    parser.add_argument('--json', action='store_true', help='emit JSON instead of text')
    args = parser.parse_args()
    inputs = args.paths or [Path(os.environ.get('NIB_HOME', '~/.nib')).expanduser() / 'sessions']
    paths = set()
    for path in inputs:
        path = path.expanduser()
        if path.is_dir():
            paths.update(p.resolve() for p in path.glob('*.jsonl') if p.is_file() and not p.name.endswith('.calls.jsonl'))
        elif path.is_file() and not path.name.endswith('.calls.jsonl'):
            paths.add(path.resolve())
    report = summarize(sorted(paths), args.since, args.cwd.expanduser().resolve() if args.cwd else None, args.group_by)
    print(json.dumps(report, ensure_ascii=False, indent=2) if args.json else text_report(report))


if __name__ == '__main__':
    main()
