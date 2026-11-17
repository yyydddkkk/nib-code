"""Session E2E checks against mock_llm.py. Run after `zig build`. No API key needed."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import signal
import selectors
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def read_requests(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def replay(path):
    history, records = [], []
    for line in path.read_text().splitlines():
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("repair") or record.get("agent_session") or record.get("bash") or record.get("task_stop"):
            continue
        messages = [dict(message) for message in record["messages"]]
        for message in messages:
            message.pop("step_effort", None)
            message.pop("tool_summary", None)
            message.pop("step_calls_omitted", None)
            message.pop("run_ok", None)
            message.pop("bash_replacements", None)
            if message["role"] == "tool":
                message.pop("background_id", None)
            if "reasoning" in message:
                reasoning = message.pop("reasoning")
                assert reasoning["provider"] == "chat_completions"
                message["reasoning_content"] = reasoning["data"]
        history[record["from"]:] = messages
        records.append(record)
    return history, records


def valid_messages(messages):
    assert messages[0]["role"] == "system"
    i = 1
    while i < len(messages):
        msg = messages[i]
        assert msg["role"] in ("user", "assistant"), msg
        for call in msg.get("tool_calls", []):
            i += 1
            assert messages[i]["role"] == "tool"
            assert messages[i]["tool_call_id"] == call["id"]
        i += 1


def assert_timing(records, *, final_only=False):
    steps = [record for record in records if record["from"] > 0]
    assert len(steps) == 2, steps
    for step in steps:
        assert isinstance(step["model_ms"], int) and 0 <= step["model_ms"] <= step["ms"], step
        assert step["attempts"] == 1, step
        assert isinstance(step["first_data_ms"], int), step
        assert 0 <= step["first_data_ms"] <= step["model_ms"], step
        assert step["run_ms"] == sum(run["run_ms"] for run in step["run_results"]), step
        assert 0 <= step["run_ms"] <= step["ms"], step
        assert step["tool_bytes"] == sum(run["tool_bytes"] for run in step["run_results"]), step
        assert step["output_bytes"] == sum(run["output_bytes"] for run in step["run_results"]), step
        assert step["tool_bytes"] == sum(call["result_bytes"] for call in step["calls"]), step
        outputs = [m["content"] for m in step["messages"] if m["role"] == "tool"]
        assert step["output_bytes"] == sum(len(text.encode("utf-8")) for text in outputs), step
    run_step, text_step = steps
    assert len(run_step["run_results"]) == 1, run_step
    call = next(call for message in run_step["messages"] for call in message.get("tool_calls", []))
    arguments = call["function"]["arguments"]
    assert "计时🙂" in json.loads(arguments)["code"]
    assert len(arguments.encode("utf-8")) > len(arguments)
    assert len(run_step["code"]) == 1, run_step
    code = run_step["code"][0]
    assert code["tool_call_id"] == call["id"], code
    assert run_step["first_data_ms"] <= code["first_ms"] <= code["last_ms"] <= run_step["model_ms"], code
    assert code["first_ms"] - run_step["first_data_ms"] >= 80, run_step
    progress = code["progress"]
    assert progress and progress[0][0] == code["first_ms"] and progress[-1][0] == code["last_ms"], code
    assert progress[-1][1] == len(arguments.encode("utf-8")), code
    assert all(a[0] <= b[0] and a[1] < b[1] for a, b in zip(progress, progress[1:])), code
    if final_only:
        assert code["first_ms"] == code["last_ms"] and len(progress) == 1, code
    else:
        assert code["first_ms"] < code["last_ms"] and code["last_ms"] - code["first_ms"] >= 50, code
        assert len(progress) >= 2, code
    assert [call["name"] for call in run_step["calls"]] == ["bash", "write", "read"], run_step
    for call in run_step["calls"]:
        assert call["ok"] is True and call["run_index"] == 0, call
        duration = call["end_ms"] - call["start_ms"]
        run_ms = run_step["run_results"][call["run_index"]]["run_ms"]
        assert 0 <= call["start_ms"] <= call["end_ms"] <= run_ms, call
        assert run_step["run_ms"] >= duration >= 0, call
        if call["name"] == "bash":
            assert duration >= 50, call
    assert run_step.get("calls_omitted", 0) == 0, run_step
    assert text_step["run_ms"] == 0 and not text_step.get("calls") and not text_step.get("code"), text_step


def assert_turn_timing(terminal, records, *, completed_steps=None):
    timing = terminal["timing"]
    assert set(timing) == {"wall_ms", "model_ms", "run_ms", "tool_bytes", "output_bytes", "llm_calls", "agent_calls"}, timing
    assert all(type(value) is int and value >= 0 for value in timing.values()), timing
    steps = [record for record in records if "model_ms" in record]
    count = terminal["steps"] if completed_steps is None else completed_steps
    steps = steps[-count:] if count else []
    assert len(steps) == count, (terminal, steps)
    for step in steps:
        for key in ("tool_bytes", "output_bytes"):
            assert step[key] == sum(run[key] for run in step["run_results"]), step
        if not step.get("calls_omitted"):
            assert step["tool_bytes"] == sum(call["result_bytes"] for call in step["calls"]), step
        for run, message in zip(step["run_results"], (m for m in step["messages"] if m["role"] == "tool")):
            assert run["output_bytes"] == len(message["content"].encode("utf-8")), (run, message)
    for key in ("model_ms", "run_ms", "tool_bytes", "output_bytes"):
        assert timing[key] == sum(step[key] for step in steps), (timing, steps)
    assert timing["wall_ms"] >= sum(step["ms"] for step in steps), (timing, steps)
    for name in ("llm", "agent"):
        assert timing[name + "_calls"] == sum(
            call["name"] == name and call.get("dispatched", True)
            for step in steps for call in step.get("calls", [])), (timing, steps)


with tempfile.TemporaryDirectory(prefix="nib-session-e2e-") as directory:
    tmp = Path(directory)
    requests_path = tmp / "requests.jsonl"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
    env.update(NIB_PROVIDER="chat_completions", NIB_API_KEY="mock", NIB_BASE_URL=f"http://127.0.0.1:{port}",
               NIB_CONTEXT_WINDOW="128000", NIB_HOME=str(tmp / "nib"), XDG_DATA_HOME=str(tmp / "data"),
               XDG_CONFIG_HOME=str(tmp / "config"), CODEX_HOME=str(tmp / "codex"), HOME=str(tmp))
    server = subprocess.Popen(["python3", str(ROOT / "tests/mock_llm.py"), str(port), str(requests_path)],
                              env=dict(env, MOCK_PROMPT_TOKENS="3300"), stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                time.sleep(.02)
        else:
            raise AssertionError("mock did not start")

        project = tmp / "project"
        project.mkdir()
        (project / ".git").write_text("gitdir: /unused\n")
        (project / "AGENTS.md").write_text("PROJECT_MARKER")
        cwd = project / "sub"
        cwd.mkdir()
        global_agents = tmp / "nib/AGENTS.md"
        global_agents.parent.mkdir(parents=True)
        global_agents.write_text("GLOBAL_MARKER")

        def ask(*args, workdir=cwd, window="128000", ok=True, input=None, overrides=None):
            child_env = dict(env, NIB_CONTEXT_WINDOW=window)
            child_env.update(overrides or {})
            child_env = {key: value for key, value in child_env.items() if value is not None}
            result = subprocess.run([str(BIN), "ask", *args], cwd=workdir,
                                    env=child_env, capture_output=True, timeout=10, input=input)
            assert (result.returncode == 0) == ok, result.stderr.decode()
            return result

        stats_home = tmp / "stats-home"
        stats_started_ms = time.time_ns() // 1_000_000
        for prompt in ("stats good", "stats bad", "stats_missing", "delegate_probe"):
            ask(prompt, overrides={"NIB_HOME": str(stats_home)})
        stats_finished_ms = time.time_ns() // 1_000_000
        stats_paths = list((stats_home / "sessions").glob("[0-9a-f]" * 32 + ".jsonl"))
        assert len(stats_paths) == 5
        step_records = [r for p in stats_paths for r in replay(p)[1] if r["from"] > 0]
        assert len(step_records) == 9
        assert all(type(r.get("at")) is int and stats_started_ms <= r["at"] <= stats_finished_ms
                   for r in step_records), step_records
        assert all(r["usage"]["prompt_tokens"] == 3300 and isinstance(r["ms"], int)
                   and r["ms"] > 0 for r in step_records)
        assert sum(not result["ok"] for r in step_records for result in r["run_results"]) == 1
        report = json.loads(subprocess.check_output(
            ["python3", str(ROOT / "scripts/stats.py"), "--json"],
            env=dict(env, NIB_HOME=str(stats_home))))
        counts = report["overall"]
        for key, value in dict(sessions=5, root_sessions=4, child_sessions=1, turns=5, steps=9,
                               runs=4, runs_failed=1, runs_with_status=4, runs_unknown=0,
                               steps_with_usage=9, steps_with_ms=9, timed_turns=5).items():
            assert counts[key] == value, (key, counts)
        assert counts["run_failure_rate"] == .25
        assert counts["avg_steps_per_turn"] == 1.8 and counts["avg_turn_ms"] > 0
        assert report["usage"] == dict(prompt_tokens=29700, completion_tokens=130,
                                        prompt_cache_hit_tokens=768, total_tokens=29830,
                                        cache_hit_rate=768/29700), report
        assert report["tools"] == dict(agent=1, bash=2)
        assert report["errors"]["js_syntax"]["count"] == 1
        assert report["errors"]["command_not_found"]["count"] == 1
        assert sum(e["count"] for e in report["errors"].values()) == 2
        assert len(report["slowest_steps"]) == 5
        print("Stats E2E passed: Step usage/timing, failed Run status, root/child counts, tokens and diagnostics")

        legacy_agents = tmp / "config/nib/AGENTS.md"
        legacy_agents.parent.mkdir(parents=True)
        legacy_agents.write_text("IGNORED_XDG_MARKER")
        (legacy_agents.parent / "config.toml").write_text("not valid TOML")

        ask("first")
        paths = list((tmp / "nib/sessions").glob("[0-9a-f]" * 32 + ".jsonl"))
        assert len(paths) == 1
        log = paths[0]
        first, initial_records = replay(log)
        header = initial_records[0]
        original_header = log.read_bytes().splitlines()[0]
        system = first[0]["content"]
        assert "effort-specific" not in system and "run's effort" not in system
        base = system.split("\n\nInstructions below apply in order; later instructions take priority.\n", 1)[0]
        version = re.search(r'\.version = "([^"]+)"', (ROOT / "build.zig.zon").read_text())[1]
        assert re.fullmatch(re.escape(version) + r"(?:\+[0-9a-f]+)?", header["nib_version"]), header
        git_commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                                    capture_output=True, text=True)
        if git_commit.returncode == 0:
            assert header["nib_version"] == version + "+" + git_commit.stdout.strip(), header
        assert header["system_sha"] == hashlib.sha256(base.encode()).hexdigest()[:12], header
        assert "patches_off" not in header
        assert header["profile"] == "deepseek", header["profile"]
        assert all(not any(key in record for key in ("nib_version", "system_sha", "patches_off", "profile"))
                   for record in initial_records[1:])
        assert system.index("You are nib") < system.index("GLOBAL_MARKER") < system.index("PROJECT_MARKER")
        assert "async mcp(" not in system and "<mcp_tools>" not in system
        assert "IGNORED_XDG_MARKER" not in system
        global_agents.write_text("CHANGED_GLOBAL")
        ask("--continue", "second")
        req = read_requests(requests_path)[-2]["messages"]
        assert req == first + [{"role": "user", "content": "second"}]
        assert req[0]["content"] == system
        ask("third", "--resume", log.stem, overrides={"NIB_PATCHES_OFF": "all"})
        assert log.read_bytes().splitlines()[0] == original_header
        safe, _ = replay(log)
        ask("reject1", "-c", ok=False)
        assert replay(log)[0] == safe
        ask("reject2", "-c", ok=False)
        safe, _ = replay(log)
        assert safe[-1]["role"] == "tool"
        ask("recovered", "-c")
        assert read_requests(requests_path)[-2]["messages"] == safe + [{"role": "user", "content": "recovered"}]
        safe, _ = replay(log)
        ask("truncated", "-c", ok=False)
        assert replay(log)[0] == safe
        with log.open("a") as stream:
            stream.write('{"from":\n{"repair":')
        ask("after crash", "--resume", log.stem)
        assert read_requests(requests_path)[-2]["messages"] == safe + [{"role": "user", "content": "after crash"}]
        assert '"repair":true' in log.read_text()
        with log.open() as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            ask("locked", "--resume", log.stem, ok=False)
        other = tmp / "other"
        other.mkdir()
        ask("no session", "-c", workdir=other, ok=False)
        ask("one", workdir=other, window="6656")
        ask("one", "--continue", workdir=other, window="6656")
        result = ask("two" + " " * 6336, "--continue", workdir=other, window="6656")
        assert b"compacted context:" in result.stderr, result.stderr
        compact_log = next(p for p in (tmp / "nib/sessions").glob("[0-9a-f]" * 32 + ".jsonl") if p != log)
        compacted, records = replay(compact_log)
        replacements = [r for r in records[1:] if r["messages"][0].get("content", "").startswith("Earlier session summary:")]
        assert len(replacements) == 1
        assert replacements[0]["context_tokens"] <= 3328
        assert compacted[1]["content"].startswith("Earlier session summary:")
        ask("three", "-c", workdir=other, window="6656")
        assert read_requests(requests_path)[-2]["messages"] == compacted + [{"role": "user", "content": "three"}]
        def events(result):
            assert result.stderr == b"", result.stderr
            assert result.stdout.endswith(b"\n")
            parsed = [json.loads(line) for line in result.stdout.splitlines()]
            assert all(len(event) == 1 for event in parsed), parsed
            return parsed

        summary_home = tmp / "summary-home"
        (cwd / "summary.txt").write_text("old")
        for prompt, expected in [
                ("run_summary_test", {"counts": [{"name": "edit", "count": 1}, {"name": "bash", "count": 1}], "omitted": 0, "files": []}),
                ("run_summary_overflow", {"counts": [{"name": "read", "count": 200}], "omitted": 3, "files": [{"tool": "read", "path": "summary.txt"}]})]:
            summary_events = events(ask("--json", prompt, overrides={"NIB_HOME": str(summary_home)}))
            run_end = next(event["run_end"] for event in summary_events if "run_end" in event)
            assert run_end["tool_summary"] == expected, run_end
            summary_id = summary_events[0]["start"]["session_id"]
            summary_records = replay(summary_home / "sessions" / f"{summary_id}.jsonl")[1]
            step = next(record for record in summary_records if record.get("calls"))
            assert step["run_results"][0]["calls_omitted"] == expected["omitted"], step
            assert step["messages"][-1]["tool_summary"] == expected, step
        print("Run summary E2E passed: source text ignored, actual calls and bounded overflow")

        streamed = events(ask("--json", "-", input=b"stdin prompt\nsecond line"))
        session_id = streamed[0]["start"]["session_id"]
        assert len(session_id) == 32 and all(c in "0123456789abcdef" for c in session_id)
        final = streamed[-1]["end"]
        assert final["steps"] == 2 and final["usage"] == {
            "prompt_tokens": 6600, "completion_tokens": 30, "prompt_cache_hit_tokens": 192}
        assert "hello from bash" in final["text"], final
        assert any(e.get("delta", {}).get("kind") == "reasoning" for e in streamed)
        assert [e["step"] for e in streamed if "step" in e] == [
            {"n": 1, "effort": "default"},
            {"n": 2, "effort": "default"},
        ], streamed
        assert all(isinstance(e["run_start"], str) for e in streamed if "run_start" in e), streamed
        assert next(i for i, e in enumerate(streamed) if "step" in e) < next(
            i for i, e in enumerate(streamed) if "delta" in e), streamed
        run_start = next(i for i, event in enumerate(streamed) if "run_start" in event)
        reported = [event["usage"] for event in streamed[:run_start] if "usage" in event]
        assert reported[0] == dict(prompt_tokens=0, completion_tokens=0, prompt_cache_hit_tokens=0)
        assert reported[-1] == dict(prompt_tokens=3300, completion_tokens=20, prompt_cache_hit_tokens=64)
        assert streamed[-2]["usage"] == final["usage"]
        assert any(e.get("run_end", {}).get("ok") for e in streamed)
        assert read_requests(requests_path)[-2]["messages"][-1]["content"] == "stdin prompt\nsecond line"
        assert (tmp / "nib/sessions" / (session_id + ".jsonl")).exists()
        assert_turn_timing(final, replay(tmp / "nib/sessions" / f"{session_id}.jsonl")[1])
        resumed = events(ask("--resume", session_id, "--json", "json resume"))
        assert resumed[0]["start"]["session_id"] == session_id
        assert_turn_timing(resumed[-1]["end"], replay(tmp / "nib/sessions" / f"{session_id}.jsonl")[1])
        failed = events(ask("reject1", "--json", ok=False))
        assert "start" in failed[0] and "error" in failed[-1]
        assert not any("end" in e for e in failed)
        assert [e["step"] for e in failed if "step" in e] == [
            {"n": 1, "effort": "default"}], failed
        assert_turn_timing(failed[-1]["error"], [])
        failed_step = events(ask("reject2", "--json", ok=False))
        failed_id = failed_step[0]["start"]["session_id"]
        assert_turn_timing(failed_step[-1]["error"], replay(tmp / "nib/sessions" / f"{failed_id}.jsonl")[1])
        missing = events(ask("--json", ok=False))[0]["error"]
        assert missing["message"] == "MissingPrompt" and "timing" not in missing
        json_cwd = tmp / "json"
        json_cwd.mkdir()
        compact_json = events(ask("json compact", "--json", workdir=json_cwd, window="4352"))
        assert any("notice" in e for e in compact_json)
        assert [e["step"]["n"] for e in compact_json if "step" in e] == list(
            range(1, compact_json[-1]["end"]["steps"] + 1)), compact_json
        print("JSON E2E passed: NDJSON events, stdin, final text/usage/steps, resume, errors and notices")
        for case, expected_ok, expected_output in (
                ("run_drain_read_failure", False, "FileNotFound"),
                ("run_drain_reject_continuation", False, "original rejection"),
                ("run_drain_fulfill_continuation", True, "fulfilled")):
            drain_cwd = tmp / case
            drain_cwd.mkdir()
            drained = events(ask("--json", case, workdir=drain_cwd,
                                 overrides={"NIB_HOME": str(tmp / (case + "-home"))}))
            runs = [event["run_end"] for event in drained if "run_end" in event]
            assert len(runs) == 1, drained
            assert runs[0]["ok"] is expected_ok, runs[0]
            assert expected_output in runs[0]["output"], runs[0]
            assert "stopped before completion" not in runs[0]["output"], runs[0]
            assert (drain_cwd / "marker").read_text() == "finished\n", runs[0]
        print("Run drain E2E passed: failed read leaves sibling bash running; reject/fulfill drain continuation calls")
        timing_home = tmp / "timing-home"
        timed = events(ask("--json", "timing", overrides={"NIB_HOME": str(timing_home)}))
        timed_id = timed[0]["start"]["session_id"]
        _, timed_records = replay(timing_home / "sessions" / f"{timed_id}.jsonl")
        assert_timing(timed_records)
        assert_turn_timing(timed[-1]["end"], timed_records)
        print("Chat Completions timing E2E passed: streamed UTF-8 arguments, model latency and per-tool Run timing")

        before = len(read_requests(requests_path))
        delegated = events(ask("--json", "delegate"))
        parent_id = delegated[0]["start"]["session_id"]
        final = delegated[-1]["end"]
        assert final["usage"] == {"prompt_tokens": 19800, "completion_tokens": 90, "prompt_cache_hit_tokens": 576}, final
        assert final["steps"] == 2
        assert_turn_timing(final, replay(tmp / "nib/sessions" / f"{parent_id}.jsonl")[1])
        assert final["timing"]["agent_calls"] == 2
        assert "child alpha" in final["text"] and "child beta" in final["text"]
        children = [r for r in read_requests(requests_path)[before:] if r["messages"][-1].get("content", "").startswith("child ")]
        assert len(children) == 2
        assert abs(children[0]["received"] - children[1]["received"]) < .25
        child_steps = [r for r in read_requests(requests_path)[before:]
                       if next(m["content"] for m in reversed(r["messages"]) if m["role"] == "user").startswith("child ")]
        intervals = []
        for name in ("child alpha", "child beta"):
            steps = [r["received"] for r in child_steps
                     if next(m["content"] for m in reversed(r["messages"]) if m["role"] == "user") == name]
            intervals.append((min(steps), max(steps)))
        span = max(end for _, end in intervals) - min(start for start, _ in intervals)
        serial = sum(end - start for start, end in intervals)
        print(f"Two children first-to-second request: parallel span={span*1000:.1f} ms, summed work={serial*1000:.1f} ms")
        for request in children:
            assert "async agent({" not in request["messages"][0]["content"]
        run_output = next(e["run_end"]["output"] for e in delegated if "run_end" in e)
        returned = json.loads(run_output.removeprefix("result: "))
        assert {child["id"] for child in returned} == {"a1", "a2"}, returned
        assert all("session" not in child for child in returned), returned
        for child in returned:
            result = json.loads(child["text"].split("result: ", 1)[1])
            assert result["agent"] == "undefined" and "agent" not in result["keys"]
            assert child["usage"]["prompt_tokens"] == 6600
        child_logs = [p for p in (tmp / "nib/sessions").glob("[0-9a-f]" * 32 + ".jsonl")
                      if replay(p)[1][0].get("parent_session_id") == parent_id]
        assert len(child_logs) == 2
        returned_bytes = sum(len(json.dumps(child, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
                             for child in returned)
        child_bytes = sum(record.get("tool_bytes", 0) for path in child_logs for record in replay(path)[1])
        assert child_bytes > 0
        assert final["timing"]["tool_bytes"] == returned_bytes, (final, returned_bytes, child_bytes)
        before = len(read_requests(requests_path))
        many = events(ask("delegate_many", "--json"))[-1]["end"]
        assert many["usage"]["prompt_tokens"] == 46200
        children = [r for r in read_requests(requests_path)[before:]
                    if r["messages"][-1].get("content", "").startswith("child ")]
        assert len(children) == 6
        starts = sorted(r["received"] for r in children)
        assert starts[3] - starts[0] < .25 and starts[4] - starts[0] >= .3, starts
        failed_events = events(ask("--json", "delegate_failure"))
        failed_run = next(e["run_end"] for e in failed_events if "run_end" in e)
        assert failed_run["ok"], failed_run
        failed_result = json.loads(failed_run["output"].removeprefix("result: "))
        assert isinstance(failed_result, dict), failed_result
        assert failed_result["ok"] is False and "HTTP 400" in failed_result["error"], failed_result
        assert failed_result["id"] == "a1" and "session" not in failed_result, failed_result
        failed_child = failed_events[-1]["end"]
        assert "HTTP 400" in failed_child["text"]
        assert failed_child["usage"] == {"prompt_tokens": 9900, "completion_tokens": 50, "prompt_cache_hit_tokens": 256}
        human = ask("delegate")
        assert b"in=19800" in human.stderr and b"out=90" in human.stderr
        print("Subagent E2E passed: concurrent results, usage including failure, parent log, hidden API and four-child cap")

        progress_cwd = cwd / "progress"
        progress_cwd.mkdir()
        live = subprocess.Popen([str(BIN), "ask", "--json", "delegate_progress"],
                                cwd=progress_cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        seen, updates, pending = [], [], b""
        with selectors.DefaultSelector() as selector:
            selector.register(live.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 25
            while True:
                assert time.monotonic() < deadline, seen
                if not selector.select(timeout=.2):
                    continue
                chunk = os.read(live.stdout.fileno(), 65536)
                if not chunk:
                    break
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    event = json.loads(line)
                    seen.append(event)
                    if "progress" not in event:
                        continue
                    p = event["progress"]
                    updates.append((time.monotonic(), p))
                    assert not any("run_end" in e for e in seen), seen
                    if len(updates) == 1:
                        assert live.poll() is None, "progress was buffered until exit"
                        assert not (progress_cwd / "progress-alpha.txt").exists() or p["step"] <= 1
                        active_child_logs = [p for p in (tmp / "nib/sessions").glob("[0-9a-f]" * 32 + ".jsonl")
                                             if (records := replay(p)[1])
                                             and records[0].get("parent_session_id") == seen[0]["start"]["session_id"]]
                        assert len(active_child_logs) <= 2
                        assert all(len(replay(p)[0]) < 8 for p in active_child_logs), "children already finished"
        assert not pending
        assert live.wait(timeout=5) == 0, live.stderr.read()
        assert len(updates) >= 6, updates
        assert {p["id"] for _, p in updates} == {"a1", "a2"}, updates
        assert all(p["background"] is False and "agent" not in p and "background_id" not in p
                   for _, p in updates), updates
        for agent in ("a1", "a2"):
            samples = [(stamp, p) for stamp, p in updates if p["id"] == agent]
            assert samples and all(b[0] - a[0] >= .95 for a, b in zip(samples, samples[1:])
                                   if b[1]["state"] in ("queued", "working")), samples
            assert samples[-1][1]["state"] == "done", samples
            assert {p["prompt"] for _, p in samples} <= {"child progress alpha", "child progress beta"}
            assert any(p["step"] >= 3 for _, p in samples), samples
            assert any("edit" in p["tools"] and p["files"] == ["progress-" + p["prompt"].split()[-1] + ".txt"]
                       and p["usage"]["prompt_tokens"] == 6600 for _, p in samples), samples
        assert any(p["state"] == "done" for _, p in updates), updates
        final = seen[-1]["end"]
        assert final["steps"] == 2
        assert final["usage"] == dict(prompt_tokens=33000, completion_tokens=170, prompt_cache_hit_tokens=832), final
        output = json.loads(next(e["run_end"]["output"] for e in seen if "run_end" in e).removeprefix("result: "))
        assert len(output) == 2
        assert {child["id"] for child in output} == {p["id"] for _, p in updates}, (output, updates)
        assert all("session" not in child for child in output), output
        for child in output:
            assert child["usage"] == dict(prompt_tokens=13200, completion_tokens=70, prompt_cache_hit_tokens=320), child
            assert "exit_code" in child["text"]
        assert all((progress_cwd / ("progress-" + name + ".txt")).read_text() == "two" for name in ("alpha", "beta"))
        print("Subagent progress E2E passed: live multi-step progress before completion, tools/files, per-child throttle, done state, unchanged result/usage accounting")

        partial_path = cwd / "child-partial.txt"
        timeout_events = events(ask("--json", "delegate_timeout " + str(partial_path)))
        timeout_run = next(e["run_end"] for e in timeout_events if "run_end" in e)
        assert timeout_run["ok"], timeout_run
        timeout_result = json.loads(timeout_run["output"].removeprefix("result: "))
        assert timeout_result["ok"] is False, timeout_result
        assert set(timeout_result) == {"id", "ok", "error", "text", "usage", "changes"}, timeout_result
        assert timeout_result["id"] == "a1", timeout_result
        timeout_message = timeout_result["error"]
        match = re.search(r"stopped due to timeout after (\d+) ms \(limit 1600 ms\)", timeout_message)
        assert match and 1600 <= int(match[1]) < 4500, timeout_message
        assert "Files it changed may be incomplete; inspect them" in timeout_message, timeout_message
        assert partial_path.read_bytes() == b"partial"
        timed_pid = int(Path(str(partial_path) + ".pid").read_text())
        status = Path(f"/proc/{timed_pid}/stat")
        assert not status.exists() or status.read_text().split()[2] == "Z", status.read_text()
        timeout_parent = timeout_events[0]["start"]["session_id"]
        timeout_children = [p for p in (tmp / "nib/sessions").glob("[0-9a-f]" * 32 + ".jsonl")
                            if replay(p)[1][0].get("parent_session_id") == timeout_parent]
        assert len(timeout_children) == 1, timeout_children
        child_log = timeout_children[0]
        child_history, _ = replay(child_log)
        assert child_history[-1]["content"].endswith("[interrupted: process terminated]"), child_history[-1]
        assert timeout_events[-1]["end"]["usage"]["prompt_tokens"] == 9900, timeout_events[-1]

        forced_timeout = events(ask("--json", "delegate_timeout_stall"))
        forced_run = next(e["run_end"] for e in forced_timeout if "run_end" in e)
        assert forced_run["ok"], forced_run
        forced_result = json.loads(forced_run["output"].removeprefix("result: "))
        assert forced_result["ok"] is False, forced_result
        forced_message = forced_result["error"]
        assert forced_result["id"] == "a1" and "session" not in forced_result, forced_result
        assert "stopped due to timeout" in forced_message and "may be incomplete" in forced_message, forced_message
        assert forced_timeout[-1]["end"]["usage"]["prompt_tokens"] == 9900, forced_timeout[-1]
        print("Subagent timeout E2E passed: explicit limit, elapsed time/id, incomplete-file warning, process cleanup and usage after forced termination")

        pidfile = tmp / "child-bash.pid"
        parent = subprocess.Popen([str(BIN), "ask", "--json", "delegate_cancel " + str(pidfile)],
                                  cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(500):
                if pidfile.exists():
                    break
                assert parent.poll() is None
                time.sleep(.01)
            else:
                raise AssertionError("child bash did not start")
            bash_pid = int(pidfile.read_text())
            nib_children = set()
            for task in Path(f"/proc/{parent.pid}/task").iterdir():
                try:
                    nib_children.update(map(int, (task / "children").read_text().split()))
                except FileNotFoundError:
                    pass
            assert nib_children
            parent.terminate()
            output, errors = parent.communicate(timeout=5)
            assert parent.returncode != 0 and errors == b"", errors
            cancellation = json.loads(output.splitlines()[-1])["error"]
            assert cancellation["usage"] == {"prompt_tokens": 6600, "completion_tokens": 40, "prompt_cache_hit_tokens": 128}, cancellation
            for pid in nib_children | {bash_pid}:
                status = Path(f"/proc/{pid}/stat")
                assert not status.exists() or status.read_text().split()[2] == "Z", (pid, status.read_text())
            print("Subagent cancellation E2E passed: parent, child nib and running bash terminate")
        finally:
            if parent.poll() is None:
                parent.kill()
                parent.wait()

        before = len(read_requests(requests_path))
        stalled = subprocess.Popen([str(BIN), "ask", "--json", "delegate_stall"],
                                   cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(500):
                if any(r["messages"][-1]["role"] == "tool" and
                       next(m["content"] for m in reversed(r["messages"]) if m["role"] == "user") == "child stall2"
                       for r in read_requests(requests_path)[before:]):
                    break
                assert stalled.poll() is None
                time.sleep(.01)
            else:
                raise AssertionError("child did not enter stalled HTTP read")
            stalled.terminate()
            output, errors = stalled.communicate(timeout=5)
            assert stalled.returncode != 0 and errors == b"", errors
            failure = json.loads(output.splitlines()[-1])["error"]
            assert failure["usage"] == {"prompt_tokens": 6600, "completion_tokens": 40, "prompt_cache_hit_tokens": 128}, failure
            print("Forced child termination E2E passed: completed usage survives stalled HTTP")
        finally:
            if stalled.poll() is None:
                stalled.kill()
                stalled.wait()

        for sig, marker in ((signal.SIGINT, "[interrupted by user]"),
                            (signal.SIGTERM, "[interrupted: process terminated]")):
            interrupted = subprocess.Popen([str(BIN), "ask", "--json", "interrupt stalled"],
                                           cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                session_id = json.loads(interrupted.stdout.readline())["start"]["session_id"]
                while "partial answer" not in interrupted.stdout.readline().decode():
                    assert interrupted.poll() is None
                started = time.monotonic()
                interrupted.send_signal(sig)
                remaining, errors = interrupted.communicate(timeout=2)
                terminal = json.loads(remaining.splitlines()[-1])["error"]
                assert_turn_timing(terminal, [], completed_steps=0)
                elapsed = time.monotonic() - started
                assert elapsed < 2, elapsed
                assert interrupted.returncode != 0 and errors == b"", errors
                print(f"Stalled stream cancellation: {sig.name} exited in {elapsed:.3f} s")
            finally:
                if interrupted.poll() is None:
                    interrupted.kill()
                    interrupted.wait()
            interrupted_log = tmp / "nib/sessions" / f"{session_id}.jsonl"
            kept, _ = replay(interrupted_log)
            assert kept[-2] == {"role": "user", "content": "interrupt stalled"}, kept
            assert kept[-1]["content"] == "partial answer\n\n" + marker, kept[-1]
            assert kept[-1]["reasoning_content"] == "Let me think.", kept[-1]
            ask("after interrupt", "--resume", session_id)
            assert read_requests(requests_path)[-2]["messages"] == kept + [{"role": "user", "content": "after interrupt"}]
        print("Interrupted Turn E2E passed: SIGINT/SIGTERM exit within 2 s during a 30 s stalled read, keep partial text and resume safely")

        (cwd / "same.txt").write_text("x\n")
        edited = events(ask("--json", "edit_test"))
        end = next(e["run_end"] for e in edited if "run_end" in e)
        assert end["changes"] == [{"path": "notes.txt", "added": 3, "removed": 1, "created": True,
                                   "diff": "+a\n+b\n…\n a\n-b\n+B\n"}], end
        (cwd / "notes.txt").write_text("a\nc\n")
        human = ask("edit_test")
        assert b"changed notes.txt +2 \xe2\x88\x922" in human.stderr, human.stderr
        print("Change E2E passed: successful edit/write diffs accumulate per operation; unchanged calls are omitted")

        contents = ["你" * 16000, "x" * 48000]
        for name, content in zip(("bytes-a.txt", "bytes-b.txt"), contents):
            (cwd / name).write_text(content)
        measured = events(ask("--json", "tool_bytes_test"))
        measured_id = measured[0]["start"]["session_id"]
        _, measured_records = replay(tmp / "nib/sessions" / f"{measured_id}.jsonl")
        terminal = measured[-1]["end"]
        assert_turn_timing(terminal, measured_records)
        expected = sum(len(json.dumps(dict(text=text, next_offset=None),
                                      ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
                       for text in contents)
        assert terminal["timing"]["tool_bytes"] == expected == 96060, terminal
        assert terminal["timing"]["output_bytes"] == len('result: "ok"'.encode("utf-8")) == 12, terminal
        assert read_requests(requests_path)[-1]["messages"][-1]["content"] == 'result: "ok"'
        print("Tool bytes E2E passed: 96060 bytes processed in JS, only 12 bytes enter context")

        multi = events(ask("--json", "tool_bytes_multi"))
        multi_id = multi[0]["start"]["session_id"]
        _, multi_records = replay(tmp / "nib/sessions" / f"{multi_id}.jsonl")
        assert_turn_timing(multi[-1]["end"], multi_records)
        multi_step = next(record for record in multi_records if record.get("run_results"))
        results = multi_step["run_results"]
        assert [run["ok"] for run in results] == [True, False, False, False, True], results
        assert [run["tool_bytes"] for run in results] == [48030, 0, 0, 0, 48030], results
        assert all(run["output_bytes"] > 0 for run in results), results
        assert [call["run_index"] for call in multi_step["calls"]] == [0, 4], multi_step
        print("Multi-Run bytes E2E passed: separate Run totals include harness rejection text")

        limited = events(ask("--json", "output_limit_test"))
        run_end = next(e["run_end"] for e in limited if "run_end" in e)
        assert run_end["ok"], run_end
        output = run_end["output"]
        assert "bytes omitted" in output and len(output.encode("utf-8")) <= 16384, output[:100]
        assert output.startswith('[entry 1 of 1 (result)]\n"' + 'x' * 100), output[:100]
        assert output.endswith('x' * 100 + '"\n'), output[-110:]
        requests = read_requests(requests_path)
        assert requests[-1]["messages"][-1]["content"] == output
        limited_id = limited[0]["start"]["session_id"]
        _, limited_records = replay(tmp / "nib/sessions" / f"{limited_id}.jsonl")
        assert_turn_timing(limited[-1]["end"], limited_records)
        assert limited[-1]["end"]["timing"]["output_bytes"] == len(output.encode("utf-8"))
        assert limited[-1]["end"]["timing"]["tool_bytes"] > 32768
        print("Run output E2E passed: JS receives complete bash data; only model-facing output is truncated")

        middle = "你" * 12000 + "-middle-tail"
        for name, content in (("left", "short-left"), ("middle", middle), ("right", "short-right")):
            (cwd / f"{name}.txt").write_text(content)
        entries = events(ask("--json", "output_entries_test"))
        run_end = next(e["run_end"] for e in entries if "run_end" in e)
        assert run_end["ok"], run_end
        output = run_end["output"]
        assert len(output.encode("utf-8")) <= 16384
        assert output.startswith("[entry 1 of 3 (console)]\nleft short-left\n")
        assert "[entry 2 of 3 (console)]\nmiddle " in output
        assert "-middle-tail\n[entry 3 of 3 (console)]\nright short-right\n" in output
        omitted = re.search(r"\[(\d+) of (\d+) bytes omitted\]", output)
        assert omitted and 0 < int(omitted[1]) < int(omitted[2]), output[:100]
        assert int(omitted[2]) == len(("middle " + middle + "\n").encode("utf-8"))
        assert (cwd / "middle-copy.txt").read_text() == middle
        requests = read_requests(requests_path)
        assert requests[-1]["messages"][-1]["content"] == output
        print("Entry output E2E passed: concurrent reads stay complete in JS and round-trip losslessly; model sees numbered entries and omission bytes")

        started = time.monotonic()
        fetched = events(ask("--json", "fetch_test"))
        elapsed = time.monotonic() - started
        output = json.loads(next(e["run_end"]["output"] for e in fetched if "run_end" in e).removeprefix("result: "))
        assert output["url"] == f"http://127.0.0.1:{port}/page" and output["status"] == 200, output
        assert output["text"].startswith("# Mock page\n\nAccept: text/markdown") and "menu" not in output["text"], output
        assert output["slow"] == "fetch: timed out after 300 ms" and elapsed < 2.5, (output, elapsed)
        assert output["truncated"] is False, output
        assert output["large"] == {"length": 1048576, "truncated": True, "clean": True}, output
        print(f"Fetch E2E passed: redirect, HTML to Markdown, Accept header and timeout of a stalled read ({elapsed:.2f} s)")

        startup = []
        for _ in range(10):
            started = time.monotonic()
            probe = subprocess.Popen([str(BIN), "ask", "--json", "-"], cwd=cwd,
                                     env=dict(env, NIB_AGENT_DEPTH="1", NIB_PARENT_SESSION_ID=parent_id),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                probe.stdin.write(b"child probe")
                probe.stdin.close()
                assert "start" in json.loads(probe.stdout.readline())
                startup.append((time.monotonic() - started) * 1000)
                remaining = probe.stdout.read()
                assert "end" in json.loads(remaining.splitlines()[-1])
                assert probe.stderr.read() == b"" and probe.wait(timeout=5) == 0
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
        print(f"Child startup to start event (10 runs, includes log sync; no TLS): median={sorted(startup)[5]:.2f} ms, range={min(startup):.2f}–{max(startup):.2f} ms")
        root_logs = [p for p in (tmp / "nib/sessions").glob("[0-9a-f]" * 32 + ".jsonl")
                     if replay(p)[1][0].get("cwd") == str(cwd) and
                     replay(p)[1][0].get("parent_session_id") is None]
        latest_root = max(root_logs, key=lambda p: p.stat().st_mtime_ns)
        continued = events(ask("--json", "-c", "after delegation"))
        assert continued[0]["start"]["session_id"] == latest_root.stem
        resumed_child = events(ask("--json", "--resume", child_logs[0].stem, "child resumed"))
        child_output = next(e["run_end"]["output"] for e in resumed_child if "run_end" in e)
        assert json.loads(child_output.removeprefix("result: "))["agent"] == "undefined"
        for child_log in child_logs:
            child_header = replay(child_log)[1][0]
            child_base = child_header["messages"][0]["content"].split(
                "\n\nInstructions below apply in order; later instructions take priority.\n", 1)[0]
            assert child_header["nib_version"] == header["nib_version"]
            assert child_header["system_sha"] == hashlib.sha256(child_base.encode()).hexdigest()[:12]
        patches_home = tmp / "patches-home"
        ask("patch labels", overrides={"NIB_HOME": str(patches_home), "NIB_PATCHES_OFF": "all"})
        patches_header = replay(next((patches_home / "sessions").glob("[0-9a-f]" * 32 + ".jsonl")))[1][0]
        patch_ids = re.findall(r'\.id = "([^"]+)"', (ROOT / "src/session/prompt.zig").read_text().split("fn patchLines", 1)[0])
        assert "expected-continuation" in patches_header["patches_off"], patches_header
        assert patches_header["patches_off"] == sorted(patch_ids), patches_header
        assert patches_header["system_sha"] != header["system_sha"]
        changed_base = patches_header["messages"][0]["content"].split(
            "\n\nInstructions below apply in order; later instructions take priority.\n", 1)[0]
        assert patches_header["system_sha"] == hashlib.sha256(changed_base.encode()).hexdigest()[:12]
        child_patches = events(ask("--json", "child patches", overrides={
            "NIB_HOME": str(patches_home), "NIB_PATCHES_OFF": "all",
            "NIB_AGENT_DEPTH": "1", "NIB_PARENT_SESSION_ID": log.stem}))
        child_patch_log = patches_home / "sessions" / (child_patches[0]["start"]["session_id"] + ".jsonl")
        child_patch_header = replay(child_patch_log)[1][0]
        assert child_patch_header["parent_session_id"] == log.stem
        assert child_patch_header["patches_off"] == sorted(patch_ids)
        assert child_patch_header["nib_version"] == header["nib_version"]
        legacy_records = replay(child_patch_log)[1]
        for key in ("nib_version", "system_sha", "patches_off"):
            legacy_records[0].pop(key)
        child_patch_log.write_text("\n".join(map(json.dumps, legacy_records)) + "\n")
        legacy_header = child_patch_log.read_bytes().splitlines()[0]
        ask("--resume", child_patch_log.stem, "legacy resume", overrides={"NIB_HOME": str(patches_home)})
        assert child_patch_log.read_bytes().splitlines()[0] == legacy_header
        print("Experiment header E2E passed: version/base hash, all patches, children and frozen/legacy resume header")
        print("Subagent resume E2E passed: --continue skips children, explicit child resume retains depth")
        config_path = tmp / "nib/config.toml"
        config_text = ('# Keep this comment and both provider sections.\n'
                       'provider = "chat_completions"\neffort = "high"\n'
                       '[codex]\nmodel = "gpt-6.1-sol"\n'
                       '[chat_completions]\nmodel = "file-chat-model"\n'
                       f'base_url = "http://127.0.0.1:{port}"\ncontext_window = 128000\n')
        config_path.write_text(config_text)
        file_env = {key: None for key in ("NIB_PROVIDER", "NIB_MODEL", "NIB_BASE_URL", "NIB_CONTEXT_WINDOW")}
        configured = events(ask("--json", "model from file", overrides=file_env))
        configured_id = configured[0]["start"]["session_id"]
        assert replay(tmp / "nib/sessions" / f"{configured_id}.jsonl")[1][0]["model"] == "file-chat-model"
        assert read_requests(requests_path)[-1]["thinking"] == {"type": "enabled"}
        overridden = events(ask("--json", "env overrides file",
                                overrides=dict(file_env, NIB_MODEL="env-chat-model", NIB_THINKING="off")))
        overridden_id = overridden[0]["start"]["session_id"]
        assert replay(tmp / "nib/sessions" / f"{overridden_id}.jsonl")[1][0]["model"] == "env-chat-model"
        assert read_requests(requests_path)[-1]["thinking"] == {"type": "disabled"}
        ask("CLI overrides env", "--effort", "high", overrides=dict(file_env, NIB_THINKING="off"))
        assert read_requests(requests_path)[-1]["thinking"] == {"type": "enabled"}
        assert config_path.read_text() == config_text
        assert not (tmp / "data/nib").exists()
        assert (legacy_agents.parent / "config.toml").read_text() == "not valid TOML"
        assert not (tmp / ".nib").exists()
        print("Configuration E2E passed: NIB_HOME, ignored XDG paths, file model, env/CLI precedence and ephemeral CLI effort")
        config_path.write_text('# header\napi_key = "not-a-real-key"\n')
        failed = events(ask("--json", "invalid config", ok=False))
        message = failed[-1]["error"]["message"]
        assert f"{config_path}:2:" in message and "NIB_API_KEY" in message, failed
        assert "not-a-real-key" not in message
        envelope = {"prompt": "inherited configuration", "config": {
            "provider": "chat_completions", "base_url": f"http://127.0.0.1:{port}",
            "api_key": "mock", "model": "inherited-model", "context_window": 128000,
            "thinking": True, "reasoning_effort": "high"}}
        inherited = events(ask("--json", "--agent-input", "-", input=json.dumps(envelope).encode(),
                               overrides={"NIB_AGENT_DEPTH": "1", "NIB_PROVIDER": "invalid-env-provider"}))
        inherited_id = inherited[0]["start"]["session_id"]
        assert replay(tmp / "nib/sessions" / f"{inherited_id}.jsonl")[1][0]["model"] == "inherited-model"
        config_path.write_text(config_text)
        fallback = events(ask("--json", "default home", overrides={"NIB_HOME": None}))
        assert (tmp / ".nib/sessions" / (fallback[0]["start"]["session_id"] + ".jsonl")).exists()
        print("Configuration boundaries passed: path/line diagnostics, child stdin bypass and HOME/.nib fallback")
        for request in read_requests(requests_path):
            valid_messages(request["messages"])
        for path in (tmp / "nib/sessions").glob("[0-9a-f]" * 32 + ".jsonl"):
            valid_messages(replay(path)[0])
        print("Session E2E passed: resume/id/cwd, frozen AGENTS, failed Steps, truncated stream, crash repair, lock, automatic compaction and replay")
    finally:
        server.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            server.wait(timeout=3)
        if server.poll() is None:
            server.kill()
            server.wait()
