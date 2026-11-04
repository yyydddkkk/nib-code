"""Codex Responses E2E with fabricated credentials. Run after `zig build`.

    python3 tests/test_codex.py
"""
import json
import os
from pathlib import Path
import socket
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def auth(path, token="fake-access-initial", account="fake-account-initial"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"tokens": {"access_token": token, "account_id": account,
                                         "refresh_token": "fake-refresh", "id_token": "fake-id"}}))


def replay(path):
    history, records = [], []
    for line in path.read_text().splitlines():
        record = json.loads(line)
        records.append(record)
        if not record.get("repair") and not record.get("diagnostic"):
            history[record["from"]:] = record["messages"]
    return history, records


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


with tempfile.TemporaryDirectory(prefix="nib-codex-e2e-") as directory:
    tmp = Path(directory)
    auth_path = tmp / "codex/auth.json"
    auth(auth_path)
    requests_path = tmp / "requests.jsonl"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
    env.update(NIB_PROVIDER="codex", NIB_BASE_URL=f"http://127.0.0.1:{port}",
               CODEX_HOME=str(auth_path.parent), HOME=str(tmp), NIB_HOME=str(tmp / "nib"), XDG_DATA_HOME=str(tmp / "data"),
               XDG_CONFIG_HOME=str(tmp / "config"))
    cwd = tmp / "project"
    cwd.mkdir()
    server = subprocess.Popen(["python3", str(ROOT / "tests/mock_codex.py"), str(port), str(requests_path)],
                              env=dict(env, MOCK_CODEX_AUTH=str(auth_path)), stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                time.sleep(.02)
        else:
            raise AssertionError("Codex mock did not start")

        def requests():
            return [json.loads(line) for line in requests_path.read_text().splitlines()]

        def assert_cache_key(recorded, session_id):
            assert recorded
            for request in recorded:
                assert request["body"]["prompt_cache_key"] == session_id, request
                headers = {k.lower(): v for k, v in request["headers"].items()}
                assert headers["session-id"] == session_id, headers
                assert headers["x-client-request-id"] == session_id, headers

        def ask(prompt, *args, ok=True, overrides=None, workdir=cwd):
            child_env = dict(env, **(overrides or {}))
            child_env = {key: value for key, value in child_env.items() if value is not None}
            result = subprocess.run([str(BIN), "ask", "--json", prompt, *args], cwd=workdir,
                                    env=child_env, capture_output=True, timeout=20)
            assert result.stderr == b"", result.stderr
            events = [json.loads(line) for line in result.stdout.splitlines()]
            assert events and all(len(event) == 1 for event in events), result.stdout
            assert (result.returncode == 0) == ok, events
            assert ("end" if ok else "error") in events[-1], events
            return events

        summaries = ask("plain text", "--effort", "high", overrides={"NIB_THINKING": "off"})
        assert requests()[-1]["body"]["reasoning"] == {"effort": "high", "summary": "auto"}
        reasoning_deltas = [e["delta"]["text"] for e in summaries if e.get("delta", {}).get("kind") == "reasoning"]
        assert reasoning_deltas == ["Mock ", "reaso", "ning."] * 2, summaries
        text_deltas = [e["delta"]["text"] for e in summaries if e.get("delta", {}).get("kind") == "text"]
        assert "".join(text_deltas) == "Mock text complete.", summaries
        assert summaries[-1]["end"]["text"] == "Mock text complete.", summaries
        ask("plain text", "--effort", "off")
        assert requests()[-1]["body"]["reasoning"]["effort"] == "low"
        defaults = ask("plain text", "--effort", "default", overrides={"NIB_REASONING_EFFORT": "high"})
        assert "reasoning" not in requests()[-1]["body"]
        assert "summary" not in requests()[-1]["body"]
        assert not any(e.get("delta", {}).get("kind") == "reasoning" for e in defaults), defaults
        invalid = ask("plain text", "--effort", "hgh", ok=False)
        assert "--effort" in invalid[-1]["error"]["message"]

        plain = ask("plain text", "--effort", "high")
        assert plain[-1]["end"]["text"] == "Mock text complete."
        assert "".join(e["delta"]["text"] for e in plain if e.get("delta", {}).get("kind") == "text") == "Mock text complete."
        assert plain[-1]["end"]["usage"] == {"prompt_tokens": 3300, "completion_tokens": 20, "prompt_cache_hit_tokens": 64}
        assert any(e.get("usage", {}).get("prompt_cache_hit_tokens") == 64 for e in plain)
        request = requests()[-1]
        headers, body = {k.lower(): v for k, v in request["headers"].items()}, request["body"]
        assert request["path"] == "/codex/responses", request
        assert headers["authorization"] == "Bearer fake-access-initial"
        assert headers["chatgpt-account-id"] == "fake-account-initial"
        assert headers["openai-beta"] == "responses=experimental" and headers["originator"] == "nib"
        assert body["model"] == "gpt-6.1-sol" and body["store"] is False and body["stream"] is True
        assert "You are nib" in body["instructions"]
        assert "reasoning.encrypted_content" in body["include"]
        assert "messages" not in body
        tool = body["tools"][0]
        assert tool["type"] == "function" and tool["name"] == "run" and tool["strict"] is False
        assert "description" in tool and "parameters" in tool and "function" not in tool
        session = plain[0]["start"]["session_id"]
        assert_cache_key([request], session)
        history, records = replay(tmp / f"nib/sessions/{session}.jsonl")
        assert records[0]["provider"] == "codex" and records[0]["model"] == "gpt-6.1-sol"
        reasoning = history[-1]["reasoning"]
        assert reasoning["provider"] == "codex"
        items = json.loads(reasoning["data"])
        assert len(items) == 2 and all(item["encrypted_content"].startswith("fake-encrypted-") for item in items)
        assert items[0]["summary"] == [{"type": "summary_text", "text": "Mock reasoning."}]
        ask("plain text", "--resume", session)
        assert_cache_key(requests()[-1:], session)
        assert all(item in requests()[-1]["body"]["input"] for item in items)
        assert next(item for item in requests()[-1]["body"]["input"] if item.get("role") == "assistant")["phase"] == "final_answer"
        disabled = ask("plain text", overrides={"NIB_MODEL": "gpt-6.1-terra", "NIB_THINKING": "off"})
        assert requests()[-1]["body"]["reasoning"] == {"effort": "none", "summary": "auto"}
        assert not any(e.get("delta", {}).get("kind") == "reasoning" for e in disabled)

        before = len(requests())
        ask("plain text", overrides={"NIB_MODEL": "gpt-6.1-sol", "NIB_THINKING": "off"})
        assert requests()[-1]["body"]["reasoning"]["effort"] == "low"
        large = ask("large reasoning")
        large_id = large[0]["start"]["session_id"]
        large_history, _ = replay(tmp / f"nib/sessions/{large_id}.jsonl")
        assert len(json.loads(large_history[-1]["reasoning"]["data"])[0]["encrypted_content"]) > 100000
        ask("plain text", "--resume", large_id)
        assert json.loads(large_history[-1]["reasoning"]["data"])[0] in requests()[-1]["body"]["input"]

        before = len(requests())
        tool_events = ask("tool roundtrip")
        assert tool_events[-1]["end"]["steps"] == 2
        assert [e["step"] for e in tool_events if "step" in e] == [
            {"n": 1, "effort": "default", "source": "default"},
            {"n": 2, "effort": "default", "source": "default"},
        ], tool_events
        assert all(isinstance(e["run_start"], str) for e in tool_events if "run_start" in e), tool_events
        assert next(i for i, e in enumerate(tool_events) if "step" in e) < next(
            i for i, e in enumerate(tool_events) if "delta" in e), tool_events
        assert tool_events[-1]["end"]["usage"] == {"prompt_tokens": 6600, "completion_tokens": 40, "prompt_cache_hit_tokens": 128}
        assert "hello from codex mock" in tool_events[-1]["end"]["text"]
        steps = requests()[before:]
        tool_id = tool_events[0]["start"]["session_id"]
        assert tool_id != session
        assert_cache_key(steps, tool_id)
        second_input = steps[1]["body"]["input"]
        call = next(item for item in second_input if item.get("type") == "function_call")
        result = next(item for item in second_input if item.get("type") == "function_call_output")
        assert result["call_id"] == call["call_id"] and json.loads(call["arguments"])["code"]
        assert any(item.get("encrypted_content") for item in second_input)
        print("Codex stream, request headers/schema, tools, encrypted reasoning resume and cache usage passed")

        timing_home = tmp / "timing-home"
        for prompt in ("timing", "timing final only"):
            timed = ask(prompt, overrides={"NIB_HOME": str(timing_home)})
            timed_id = timed[0]["start"]["session_id"]
            _, timed_records = replay(timing_home / "sessions" / f"{timed_id}.jsonl")
            assert_timing(timed_records, final_only=prompt == "timing final only")
        print("Codex timing E2E passed: streamed/final-only UTF-8 arguments, model latency and per-tool Run timing")

        before = len(requests())
        interrupted = subprocess.Popen([str(BIN), "ask", "--json", "interrupt stalled"],
                                       cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            interrupted_id = json.loads(interrupted.stdout.readline())["start"]["session_id"]
            while "partial answer" not in interrupted.stdout.readline().decode():
                assert interrupted.poll() is None
            started = time.monotonic()
            interrupted.send_signal(signal.SIGTERM)
            output, errors = interrupted.communicate(timeout=2)
            elapsed = time.monotonic() - started
            assert elapsed < 2, elapsed
            assert interrupted.returncode != 0 and errors == b"", errors
            assert "error" in json.loads(output.splitlines()[-1]), output
        finally:
            if interrupted.poll() is None:
                interrupted.kill()
                interrupted.wait()
        kept, _ = replay(tmp / f"nib/sessions/{interrupted_id}.jsonl")
        assert kept[-2] == {"role": "user", "content": "interrupt stalled"}, kept
        assert kept[-1]["content"] == "partial answer\n\n[interrupted: process terminated]", kept[-1]
        assert len(requests()) == before + 1
        print(f"Codex stalled stream cancellation passed: SIGTERM exited in {elapsed:.3f} s and kept partial text")

        for prompt, delay in (("stream retry server", 1000), ("stream retry disconnect", 1000), ("stream rate retry", 30)):
            before = len(requests())
            recovered = ask(prompt)
            assert len(requests()) == before + 2, recovered
            assert [e["step"] for e in recovered if "step" in e] == [
                {"n": 1, "effort": "default", "source": "default"}], recovered
            retry_index = next(i for i, event in enumerate(recovered) if "retry" in event)
            assert sum("delta" in event for event in recovered[:retry_index]) >= 2, recovered
            retries = [event["retry"] for event in recovered if "retry" in event]
            assert len(retries) == 1 and retries[0]["attempt"] == 1 and retries[0]["delay_ms"] == delay, recovered
            expected_code = "server_error" if prompt == "stream retry server" else "IncompleteResponse" if prompt == "stream retry disconnect" else "rate_limit_exceeded"
            assert expected_code in retries[0]["reason"]
            assert recovered[-1]["end"]["text"] == "Mock text complete.", recovered
            assert recovered[-1]["end"]["steps"] == 1
            assert recovered[-1]["end"]["usage"] == dict(prompt_tokens=3300, completion_tokens=20, prompt_cache_hit_tokens=64)
            assert requests()[-1]["body"] == requests()[-2]["body"]
            recovered_log = tmp / ("nib/sessions/" + recovered[0]["start"]["session_id"] + ".jsonl")
            recovered_history, recovered_records = replay(recovered_log)
            assert not any(r.get("diagnostic") for r in recovered_records)
            recovered_steps = [record for record in recovered_records if record["from"] > 0]
            assert len(recovered_steps) == 1, recovered_steps
            measured = recovered_steps[0]
            assert measured["attempts"] == 2, measured
            assert delay <= measured["model_ms"] <= measured["ms"], measured
            assert 0 <= measured["first_data_ms"] <= measured["model_ms"], measured
            assert measured["run_ms"] == 0 and not measured.get("code") and not measured.get("calls"), measured
            assert all("failed attempt prefix" not in m.get("content", "") for m in recovered_history)

        for prompt, code, message, count in (("stream context fatal", "context_length_exceeded", "mock context budget exceeded", 1),
                                             ("stream rate exhausted", "rate_limit_exceeded", "mock limit; try again in 20ms", 5)):
            before = len(requests())
            failed = ask(prompt, ok=False)
            assert len(requests()) == before + count, failed
            retries = [event["retry"] for event in failed if "retry" in event]
            assert len(retries) == count - 1, failed
            if retries:
                assert all(event["delay_ms"] == 20 for event in retries), failed
            detail = f"Codex stream failed: {code}: {message}; the Step was not committed."
            assert failed[-1]["error"]["message"] == detail, failed
            assert failed[-1]["error"]["steps"] == 0
            failed_id = failed[0]["start"]["session_id"]
            failed_log = tmp / f"nib/sessions/{failed_id}.jsonl"
            failed_history, failed_records = replay(failed_log)
            assert len(failed_history) == 1 and failed_history[0]["role"] == "system"
            diagnostic = failed_records[-1]["diagnostic"]
            assert diagnostic["message"] == detail and diagnostic["attempts"] == count and diagnostic["step"] == 1
            report = json.loads(subprocess.check_output(["python3", str(ROOT / "scripts/stats.py"), str(failed_log), "--json"]))
            assert report["errors"]["provider_failure"]["count"] == 1, report
            assert report["overall"]["steps"] == 0 and report["usage"]["total_tokens"] == 0, report
            ask("plain text", "--resume", failed_id)
            assert requests()[-1]["body"]["input"] == [{"role": "user", "content": "plain text"}], requests()[-1]
        retrying = subprocess.Popen([str(BIN), "ask", "--json", "stream retry cancel"], cwd=cwd, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            retry_id = json.loads(retrying.stdout.readline())["start"]["session_id"]
            while True:
                event = json.loads(retrying.stdout.readline())
                if "retry" in event:
                    assert event["retry"]["delay_ms"] == 10000
                    break
            retrying.send_signal(signal.SIGTERM)
            output, errors = retrying.communicate(timeout=2)
            assert retrying.returncode != 0 and errors == b"", errors
            assert "error" in json.loads(output.splitlines()[-1]), output
        finally:
            if retrying.poll() is None:
                retrying.kill()
                retrying.wait()
        retry_history, retry_records = replay(tmp / f"nib/sessions/{retry_id}.jsonl")
        assert retry_history[-2] == {"role": "user", "content": "stream retry cancel"}, retry_history
        assert retry_history[-1]["content"] == "[interrupted: process terminated]", retry_history[-1]
        assert not any(record.get("diagnostic") for record in retry_records)
        print("Codex mid-stream recovery passed: partial deltas, server errors/disconnects, rate-limit hints, fatal context errors and diagnostic-only logs/stats")

        before = len(requests())
        delegated = ask("delegate", overrides={"NIB_MODEL": "gpt-6-sol", "NIB_REASONING_EFFORT": "high"})
        assert delegated[-1]["end"]["usage"]["prompt_tokens"] == 9900
        steps = requests()[before:]
        assert len(steps) == 3
        for request in steps:
            assert request["body"]["model"] == "gpt-6-sol" and request["body"]["reasoning"]["effort"] == "high"
            assert {k.lower(): v for k, v in request["headers"].items()}["authorization"] == "Bearer fake-access-initial"
        assert sum("async agent({" not in r["body"]["instructions"] for r in steps) == 1
        parent_id = delegated[0]["start"]["session_id"]
        child_logs = [p for p in (tmp / "nib/sessions").glob("*.jsonl")
                      if not p.name.endswith(".calls.jsonl")
                      and json.loads(p.read_text().splitlines()[0]).get("parent_session_id") == parent_id]
        assert len(child_logs) == 1
        child_id = child_logs[0].stem
        assert child_id != parent_id
        for request in steps:
            assert_cache_key([request], child_id if "async agent({" not in request["body"]["instructions"] else parent_id)

        before = len(requests())
        compact_dir = tmp / "compact"
        compact_dir.mkdir()
        for index in range(3):
            compact = ask(f"compact {index}", overrides={"NIB_CONTEXT_WINDOW": "4096"}, workdir=compact_dir,
                *(["--continue"] if index else []))
            if index == 0:
                compact_id = compact[0]["start"]["session_id"]
            assert compact[0]["start"]["session_id"] == compact_id
        assert compact_id not in (session, tool_id, parent_id, child_id)
        assert_cache_key(requests()[before:], compact_id)
        summaries = [r["body"] for r in requests()[before:] if not r["body"].get("tools")]
        assert summaries and all(body["reasoning"]["effort"] == "low" and body["model"] == "gpt-6.1-sol" for body in summaries), summaries
        assert all("max_tokens" not in body and "max_output_tokens" not in body for body in summaries)
        assert all("Keep the summary within" in body["input"][-1]["content"] for body in summaries)
        for scenario in ("summary empty", "summary truncated"):
            failure_dir = tmp / scenario.replace(" ", "-")
            failure_dir.mkdir()
            ask(scenario, overrides={"NIB_CONTEXT_WINDOW": "4096"}, workdir=failure_dir)
            continued = ask("continue after summary failure", "--continue", overrides={"NIB_CONTEXT_WINDOW": "4096"}, workdir=failure_dir)
            assert any("automatic compaction failed, continuing" in event.get("notice", "") for event in continued), continued
            assert "end" in continued[-1]
        print("Codex child configuration and automatic compaction with the same model and minimal reasoning passed")

        before = len(requests())
        ask("rotate auth")
        rotated = requests()[before:]
        assert len(rotated) == 2
        assert {k.lower(): v for k, v in rotated[1]["headers"].items()}["authorization"] == "Bearer fake-access-rotated"
        assert {k.lower(): v for k, v in rotated[1]["headers"].items()}["chatgpt-account-id"] == "fake-account-rotated"
        before = len(requests())
        failed = ask("reject auth", ok=False)
        assert len(requests()) - before == 2
        message = failed[-1]["error"]["message"].lower()
        assert "codex" in message and ("login" in message or "log in" in message)
        for contents in (None, "not-json fake-invalid-secret", json.dumps({"tokens": {"access_token": "fake-invalid-secret"}})):
            if contents is None:
                auth_path.unlink()
            else:
                auth_path.write_text(contents)
            before = len(requests())
            failed = ask("plain text", ok=False)
            assert len(requests()) == before
            message = failed[-1]["error"]["message"].lower()
            assert "codex" in message and ("login" in message or "log in" in message), failed
            assert "fake-invalid-secret" not in json.dumps(failed)
        auth(auth_path)
        blocked = ask("read auth " + str(auth_path))
        assert "fake-access-initial" not in json.dumps(blocked)
        assert "denied" in blocked[-1]["end"]["text"].lower(), blocked
        checked = ask("bash env", overrides={"NIB_API_KEY": "fake-nib-secret", "DEEPSEEK_API_KEY": "fake-deepseek-secret", "OPENAI_API_KEY": "fake-openai-secret"})
        output = next(event["run_end"]["output"] for event in checked if "run_end" in event)
        for key in ("NIB_API_KEY", "DEEPSEEK_API_KEY", "OPENAI_API_KEY"):
            assert key not in output, output
        cross = ask("plain text", "--resume", session, ok=False, overrides={"NIB_PROVIDER": "chat_completions", "NIB_API_KEY": "mock"})
        message = cross[-1]["error"]["message"]
        assert "SessionProviderMismatch" in message or "different provider" in message, cross
        log = tmp / f"nib/sessions/{session}.jsonl"
        committed_history, _ = replay(log)
        for prompt in ("stream incomplete", "stream failed", "stream truncated"):
            committed = log.read_bytes()
            before = len(requests())
            failed = ask(prompt, "--resume", session, ok=False)
            assert not any("end" in event for event in failed), failed
            assert log.read_bytes().startswith(committed), prompt
            history, records = replay(log)
            assert history == committed_history, prompt
            expected = 5 if prompt == "stream truncated" else 1
            assert len(requests()) == before + expected, failed
            assert records[-1]["diagnostic"]["message"] == failed[-1]["error"]["message"]
            assert records[-1]["diagnostic"]["attempts"] == expected
        before = len(requests())
        changed_model = ask("plain text", "--resume", session, ok=False, overrides={"NIB_MODEL": "gpt-6-sol"})
        assert "different model" in changed_model[-1]["error"]["message"]
        assert len(requests()) == before
        print("Codex 401 reread, repeated-401 login guidance, credentials and tool isolation passed")

        config_path = tmp / "nib/config.toml"
        config_text = ('# Keep this comment and both provider sections.\n'
                       'provider = "codex"\neffort = "high"\n'
                       '[codex]\nmodel = "gpt-6-sol"\n'
                       f'base_url = "http://127.0.0.1:{port}"\ncontext_window = 272000\n'
                       '[chat_completions]\nmodel = "unused-chat-model"\n')
        config_path.write_text(config_text)
        file_env = {key: None for key in ("NIB_PROVIDER", "NIB_MODEL", "NIB_BASE_URL", "NIB_CONTEXT_WINDOW")}
        ask("plain text", overrides=file_env)
        body = requests()[-1]["body"]
        assert body["model"] == "gpt-6-sol" and body["reasoning"]["effort"] == "high", body
        ask("plain text", overrides=dict(file_env, NIB_MODEL="gpt-6.1-terra", NIB_REASONING_EFFORT="low"))
        body = requests()[-1]["body"]
        assert body["model"] == "gpt-6.1-terra" and body["reasoning"]["effort"] == "low", body
        ask("plain text", "--effort", "high", overrides=dict(file_env, NIB_REASONING_EFFORT="low"))
        assert requests()[-1]["body"]["reasoning"]["effort"] == "high"
        assert config_path.read_text() == config_text
        assert not (tmp / "data/nib").exists() and not (tmp / "config/nib").exists()
        assert not (tmp / ".nib").exists()
        print("Codex configuration E2E passed: NIB_HOME, file model, env/CLI precedence and ephemeral CLI effort")
    finally:
        server.terminate()
        server.wait(timeout=5)
