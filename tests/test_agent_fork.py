"""Forked tools.agent E2E using loopback mocks and fabricated credentials only.

    zig build && python3 tests/test_agent_fork.py
"""
from mock_http import ThreadingHTTPServer
import http.server
import json
import threading
import unittest

from change_helpers import checked_bash, wait_command
from mock_llm_tool import content
from test_agent_reuse import completions, settled, system
from test_background_agent import BackgroundTests
from test_llm import records


def agent(prompt, **options):
    return "tools.agent(" + json.dumps({"prompt": "child:" + prompt, **options}) + ")"


def fork(prompt, **options):
    return agent(prompt, fork=True, **options)


def messages(body):
    return body.get("messages", body.get("input", []))


def is_result(item):
    return item.get("role") == "tool" or item.get("type") == "function_call_output"


def tool_value(request):
    output = next(m for m in reversed(request["messages"]) if is_result(m))
    return json.loads(output.get("output", content(output)).removeprefix("result: "))


def child_step(items):
    last_user = max(i for i, m in enumerate(items) if m.get("role") == "user")
    return sum(is_result(m) for m in items[last_user + 1:])


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def raw_json_values(text):
    decoder = json.JSONDecoder()
    text = text.strip()
    is_object = text[0] == "{"
    closing = "}" if is_object else "]"
    values = {} if is_object else []
    position = 1
    while True:
        while text[position].isspace():
            position += 1
        if text[position] == closing:
            return values
        if is_object:
            key, position = decoder.raw_decode(text, position)
            while text[position].isspace():
                position += 1
            assert text[position] == ":"
            position += 1
            while text[position].isspace():
                position += 1
        start = position
        _, position = decoder.raw_decode(text, position)
        if is_object:
            values[key] = text[start:position]
        else:
            values.append(text[start:position])
        while text[position].isspace():
            position += 1
        if text[position] == closing:
            return values
        assert text[position] == ","
        position += 1


class Mock(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        self.requests, self.errors = [], []
        self.lock = threading.Lock()
        self.plans = {}
        self.handlers = {}
        self.tokens = {}
        self.holding = threading.Event()
        self.release = threading.Event()
        super().__init__(("127.0.0.1", 0), Handler)

    def plan(self, prompt, *steps):
        self.plans[prompt] = iter(steps)

    def observed(self, prompt):
        with self.lock:
            return [r for r in self.requests if r["prompt"] == prompt]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.server.errors.append(repr(error))
            self.send_error(500, str(error))

    def respond(self):
        body_text = self.rfile.read(int(self.headers["Content-Length"])).decode("utf-8")
        body = json.loads(body_text)
        raw_fields = raw_json_values(body_text)
        raw_items = raw_json_values(raw_fields["messages" if "messages" in body else "input"])
        items = messages(body)
        summary = not body.get("tools")
        prompt = "summary" if summary else next(
            content(m) for m in reversed(items)
            if m.get("role") == "user" and content(m).startswith(("parent:", "child:")))
        with self.server.lock:
            serial = len(self.server.requests)
            self.server.requests.append(dict(prompt=prompt, body=body, messages=items, body_text=body_text,
                                             raw_fields=raw_fields, raw_messages=raw_items))
        code, text = None, "done:" + prompt
        if summary:
            text = "Fork compaction summary: old work completed; continue current task."
        elif prompt in self.server.handlers:
            code, text = self.server.handlers[prompt](items)
        elif prompt in self.server.plans:
            code = next(self.server.plans[prompt], None)
        elif prompt.startswith("child:"):
            raise AssertionError("unexpected child request: " + prompt)
        else:
            raise AssertionError("unexpected parent request: " + prompt)
        self.reply(body, serial, code, text, self.server.tokens.get(prompt, 100))

    def reply(self, body, serial, code, text, tokens):
        codes = code if isinstance(code, list) else ([] if code is None else [code])
        calls = []
        for index, entry in enumerate(codes):
            run_args = entry if isinstance(entry, dict) else {"code": entry}
            call_id = "fork_call_" + str(serial) + ("_" + str(index) if len(codes) > 1 else "")
            calls.append({"index": index, "id": call_id, "type": "function",
                          "function": {"name": "run", "arguments": json.dumps(run_args)}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        sequence = 0

        def event(kind=None, **fields):
            nonlocal sequence
            if kind:
                fields = {"type": kind, "sequence_number": sequence, **fields}
            data = (("event: " + kind + "\n" if kind else "") +
                    "data: " + json.dumps(fields) + "\n\n").encode()
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
            sequence += 1

        if "messages" in body:
            event(choices=[{"delta": {"reasoning_content": "fork-reasoning-" + str(serial)}}])
            for offset in range(0, len(text), 4096):
                event(choices=[{"delta": {"content": text[offset:offset + 4096]}}])
            if calls:
                event(choices=[{"delta": {"tool_calls": calls}}])
            event(choices=[{"delta": {}, "finish_reason": "tool_calls" if calls else "stop"}],
                  usage={"prompt_tokens": tokens, "completion_tokens": 20, "prompt_cache_hit_tokens": 8})
            data = b"data: [DONE]\n\n"
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        else:
            response_id = "fork_response_" + str(serial)
            event("response.created", response={"id": response_id, "status": "in_progress", "output": []})
            output = []
            for part in range(2):
                item = {"id": f"rs_{serial}_{part}", "type": "reasoning",
                        "summary": [{"type": "summary_text", "text": f"fork-reasoning-{serial}-{part}"}],
                        "encrypted_content": f"fake-fork-encrypted-{serial}-{part}"}
                event("response.output_item.added", output_index=len(output),
                      item={"id": item["id"], "type": "reasoning", "summary": []})
                event("response.output_item.done", output_index=len(output), item=item)
                output.append(item)
            item = {"id": "msg_" + str(serial), "type": "message", "role": "assistant",
                    "status": "completed",
                    "content": [{"type": "output_text", "text": text, "annotations": []}]}
            event("response.output_item.added", output_index=len(output),
                  item={**item, "content": [], "status": "in_progress"})
            event("response.output_text.delta", item_id=item["id"], output_index=len(output), content_index=0, delta=text)
            event("response.output_item.done", output_index=len(output), item=item)
            output.append(item)
            for call in calls:
                item = {"id": "fc_" + call["id"], "type": "function_call",
                        "call_id": call["id"], "name": call["function"]["name"],
                        "arguments": call["function"]["arguments"], "status": "completed"}
                event("response.output_item.added", output_index=len(output),
                      item={**item, "arguments": "", "status": "in_progress"})
                event("response.function_call_arguments.delta", output_index=len(output),
                      item_id=item["id"], delta=item["arguments"])
                event("response.output_item.done", output_index=len(output), item=item)
                output.append(item)
            event("response.completed", response={"id": response_id, "status": "completed", "output": output,
                  "usage": {"input_tokens": tokens, "output_tokens": 20, "input_tokens_details": {"cached_tokens": 8}}})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


class ForkTests:
    setUp = BackgroundTests.setUp
    start = BackgroundTests.start
    finish = BackgroundTests.finish

    def mock(self):
        mock = Mock()
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        self.env["NIB_BASE_URL"] = "http://127.0.0.1:" + str(mock.server_port)
        self.env["NIB_CODEX_TRANSPORT"] = "sse"
        if self.provider == "codex":
            self.env["NIB_MODEL"] = "gpt-6.1-sol"

        def cleanup():
            mock.release.set()
            mock.shutdown()
            mock.server_close()
            thread.join(timeout=3)
            self.assertFalse(mock.errors, mock.errors)
        self.addCleanup(cleanup)
        return mock

    def outputs(self, events):
        runs = [e["run_end"] for e in events if "run_end" in e]
        for run in runs:
            self.assertTrue(run["ok"], run)
        return [json.loads(r["output"].removeprefix("result: ")) for r in runs]

    def assert_result(self, result, task_id="a1"):
        self.assertIs(result["ok"], True, result)
        self.assertEqual(result["id"], task_id, result)
        self.assertNotIn("session", result)
        self.assertIsInstance(result["text"], str)
        self.assertIsInstance(result["changes"], list)

    def assert_prefix(self, child, parent):
        body, parent_body = child["body"], parent["body"]
        self.assertEqual(system(body), system(parent_body))
        self.assertTrue(body["tools"])
        self.assertEqual(body["tools"], parent_body["tools"])
        self.assertTrue(json_bytes(system(body)) == json_bytes(system(parent_body)), "system compact UTF-8 differs")
        self.assertTrue(json_bytes(body["tools"]) == json_bytes(parent_body["tools"]), "tools compact UTF-8 differs")
        self.assertTrue(child["raw_fields"]["tools"].encode("utf-8") ==
                        parent["raw_fields"]["tools"].encode("utf-8"), "tools wire bytes differ")
        if self.provider == "codex":
            self.assertTrue(child["raw_fields"]["instructions"].encode("utf-8") ==
                            parent["raw_fields"]["instructions"].encode("utf-8"), "system wire bytes differ")
        else:
            child_system = [raw_json_values(raw)["content"].encode("utf-8")
                            for raw, item in zip(child["raw_messages"], child["messages"]) if item.get("role") == "system"]
            parent_system = [raw_json_values(raw)["content"].encode("utf-8")
                             for raw, item in zip(parent["raw_messages"], parent["messages"]) if item.get("role") == "system"]
            self.assertEqual(child_system, parent_system, "system wire bytes differ")
        if self.provider == "codex":
            self.assertTrue(body["prompt_cache_key"])
            self.assertEqual(body["prompt_cache_key"], parent_body["prompt_cache_key"])
        elif "prompt_cache_key" in parent_body:
            self.assertEqual(body.get("prompt_cache_key"), parent_body["prompt_cache_key"])
        parent_items, child_items = parent["messages"], child["messages"]
        last_result = max(i for i, item in enumerate(parent_items) if is_result(item))
        first_result = last_result
        while first_result > 0 and is_result(parent_items[first_result - 1]):
            first_result -= 1
        real_results = parent_items[first_result:last_result + 1]
        prefix = parent_items[:first_result]
        self.assertTrue(json_bytes(child_items[:first_result]) == json_bytes(prefix), "history compact UTF-8 differs")
        self.assertTrue([raw.encode("utf-8") for raw in child["raw_messages"][:first_result]] ==
                        [raw.encode("utf-8") for raw in parent["raw_messages"][:first_result]],
                        "history wire bytes differ")
        tail = child_items[first_result:]
        self.assertEqual(len(tail), len(real_results) + 1, tail)
        for synthetic, real in zip(tail[:-1], real_results):
            self.assertTrue(is_result(synthetic), tail)
            self.assertTrue(synthetic.get("output", content(synthetic)), tail)
            self.assertNotEqual(synthetic.get("output", content(synthetic)), real.get("output", content(real)))
        self.assertEqual(tail[-1]["role"], "user")
        self.assertEqual(content(tail[-1]), child["prompt"])
        id_field = "call_id" if self.provider == "codex" else "tool_call_id"
        call_ids = [m[id_field] for m in real_results]
        self.assertEqual([m[id_field] for m in tail[:-1]], call_ids)
        if self.provider == "codex":
            self.assertEqual([m["call_id"] for m in prefix[-len(call_ids):]
                              if m.get("type") == "function_call"], call_ids)
            reasoning = [m for m in prefix if m.get("type") == "reasoning"]
            self.assertGreaterEqual(len(reasoning), 2)
            self.assertTrue(all(m.get("encrypted_content", "").startswith("fake-fork-encrypted-") for m in reasoning))
            self.assertTrue(all(m.get("summary") for m in reasoning))
        else:
            self.assertEqual([call["id"] for call in prefix[-1]["tool_calls"]], call_ids)
            self.assertTrue(prefix[-1]["reasoning_content"].startswith("fork-reasoning-"))
        return prefix

    def assert_agent_disabled(self, request, count):
        output = next(m for m in reversed(request["messages"]) if is_result(m))
        rejected = json.loads(output.get("output", content(output)).removeprefix("result: "))
        self.assertEqual(len(rejected), count)
        for result in rejected:
            self.assertIs(result["resolved"], False, result)
            self.assertRegex(result["error"].lower(), "agent")
            self.assertRegex(result["error"].lower(), "disabled|not allowed|unavailable|cannot|forbidden")

    def child_log(self, parent_id):
        paths = [p for p in (self.home / "sessions").glob("?" * 32 + ".jsonl")
                 if records(p)[0].get("parent_session_id") == parent_id]
        self.assertEqual(len(paths), 1, paths)
        return paths[0]

    def test_multiple_forks_share_current_assistant_prefix_and_original_system(self):
        (self.home / "AGENTS.md").write_text("ORIGINAL_FORK_GLOBAL: 中文🙂\n")
        (self.cwd / "AGENTS.md").write_text("ORIGINAL_FORK_PROJECT: 缓存前缀\n")
        mock = self.mock()
        changed = ("await tools.write(" + json.dumps({"path": str(self.home / "AGENTS.md"),
                   "content": "REPLACED_FORK_GLOBAL"}) + "); await tools.write(" +
                   json.dumps({"path": "AGENTS.md", "content": "REPLACED_FORK_PROJECT"}) +
                   '); "PARENT_HISTORY_MARKER"')
        mock.plan("parent:multiple", changed,
                  "const one = await " + fork("one") + "; const two = await " + fork("two") +
                  "; const parallel = await Promise.all([" + fork("three") + ", " + fork("four") +
                  "]); [one, two, ...parallel]")
        for name in ("one", "two", "three", "four"):
            mock.plan("child:" + name)
        events = self.finish(self.start("parent:multiple"))
        results = self.outputs(events)[-1]
        self.assertEqual(len(results), 4)
        self.assertEqual({r["id"] for r in results}, {"a1", "a2", "a3", "a4"})
        parent = mock.observed("parent:multiple")[-1]
        prefixes = []
        for name, result in zip(("one", "two", "three", "four"), results):
            self.assert_result(result, result["id"])
            self.assertEqual(result["changes"], [])
            self.assertEqual(result["text"], "done:child:" + name)
            child = mock.observed("child:" + name)[0]
            prefixes.append(self.assert_prefix(child, parent))
            inherited_system = system(child["body"])
            self.assertIn("ORIGINAL_FORK_GLOBAL", inherited_system)
            self.assertIn("ORIGINAL_FORK_PROJECT", inherited_system)
            self.assertNotIn("REPLACED_FORK_", inherited_system)
            self.assertIn("PARENT_HISTORY_MARKER", json.dumps(child["messages"]))
        self.assertTrue(all(p == prefixes[0] for p in prefixes))
        self.assertEqual([results[i]["id"] for i in range(2)], ["a1", "a2"])

    def test_second_outer_run_forks_full_assistant_without_any_current_real_results(self):
        mock = self.mock()
        path = self.cwd / "first-outer-run-result.txt"
        private_result = "FIRST_OUTER_REAL_RESULT: 仅父请求可见🙂\n"
        path.write_text(private_result)
        codes = ["await tools.read(" + json.dumps({"path": path.name}) + ")",
                 "await " + fork("second-outer-run")]
        mock.plan("parent:outer-runs", codes)
        mock.plan("child:second-outer-run")
        events = self.finish(self.start("parent:outer-runs"))
        outputs = self.outputs(events)
        self.assertEqual(len(outputs), 2)
        self.assertEqual(outputs[0], {"text": private_result, "next_offset": None})
        self.assert_result(outputs[1])
        parents = mock.observed("parent:outer-runs")
        children = mock.observed("child:second-outer-run")
        self.assertEqual(len(parents), 2)
        self.assertEqual(len(children), 1)
        self.assertEqual([r["prompt"] for r in mock.requests],
                         ["parent:outer-runs", "child:second-outer-run", "parent:outer-runs"])
        child, parent = children[0], parents[1]
        prefix = self.assert_prefix(child, parent)
        if self.provider == "codex":
            calls = [m for m in prefix if m.get("type") == "function_call"]
            call_ids = [m["call_id"] for m in calls]
            arguments = [m["arguments"] for m in calls]
            id_field = "call_id"
        else:
            calls = prefix[-1]["tool_calls"]
            call_ids = [m["id"] for m in calls]
            arguments = [m["function"]["arguments"] for m in calls]
            id_field = "tool_call_id"
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(set(call_ids)), 2)
        self.assertEqual([json.loads(args)["code"] for args in arguments], codes)
        self.assertFalse(any(is_result(m) for m in prefix))
        synthetic = child["messages"][len(prefix):-1]
        real = parent["messages"][len(prefix):]
        self.assertEqual(len(synthetic), 2)
        self.assertEqual(len(real), 2)
        self.assertEqual([m[id_field] for m in synthetic], call_ids)
        self.assertEqual([m[id_field] for m in real], call_ids)
        self.assertEqual([json.loads(m.get("output", content(m)).removeprefix("result: ")) for m in real], outputs)
        self.assertNotIn("FIRST_OUTER_REAL_RESULT", json.dumps(child["messages"]))
        self.assertNotIn("done:child:second-outer-run", json.dumps(child["messages"]))
        self.assertEqual(content(child["messages"][-1]), "child:second-outer-run")

    def test_fork_resume_presence_conflicts_and_non_boolean_fork_reject(self):
        mock = self.mock()
        bad = [agent("forbidden", fork=value, resume="a1") for value in (True, False)]
        bad += [agent("forbidden", fork=True, resume=value) for value in (None, 42, "missing")]
        bad += [agent("forbidden", fork=value) for value in (None, 1, "true", [], {})]
        mock.plan("parent:invalid", "const rejected = [" + ",".join("await " + settled(c) for c in bad) +
                  "]; [rejected, await " + fork("valid") + "]")
        mock.plan("child:valid")
        rejected, valid = self.outputs(self.finish(self.start("parent:invalid")))[0]
        self.assertEqual(len(rejected), len(bad))
        for result in rejected:
            self.assertIs(result["resolved"], False, result)
            self.assertTrue(result["error"], result)
        for result in rejected[:2]:
            self.assertIn("fork", result["error"].lower())
            self.assertIn("resume", result["error"].lower())
        self.assert_result(valid)
        self.assertFalse(mock.observed("child:forbidden"))

    def test_fork_keeps_agent_tool_but_runtime_rejects_nested_delegation(self):
        mock = self.mock()
        probes = [agent("forbidden"), fork("forbidden"), agent("forbidden", background=True),
                  agent("forbidden", resume="a1")]
        mock.plan("parent:nested", "await " + fork("probe"))
        mock.plan("child:probe", "[" + ",".join("await " + settled(c) for c in probes) + "]")
        events = self.finish(self.start("parent:nested"))
        self.assert_result(self.outputs(events)[0])
        child = mock.observed("child:probe")
        self.assertEqual(len(child), 2)
        self.assert_agent_disabled(child[-1], len(probes))
        self.assertFalse(mock.observed("child:forbidden"))
        self.assert_prefix(child[0], mock.observed("parent:nested")[-1])

    def test_fork_can_resume_without_recopying_parent_history(self):
        mock = self.mock()
        mock.plan("parent:reuse", "await " + fork("seed"),
                  '"PARENT_AFTER_FORK_MARKER"', "await " + agent("next", resume="a1"))
        mock.plan("child:seed", 'console.log("CHILD_PRIVATE_HISTORY_MARKER"); await tools.write(' +
                  json.dumps({"path": "fork-note.txt", "content": "kept\n"}) + ")")
        mock.plan("child:next")
        events = self.finish(self.start("parent:reuse"))
        first, _, second = self.outputs(events)
        self.assert_result(first)
        self.assert_result(second)
        self.assertEqual(first["changes"], [{"path": "fork-note.txt", "added": 1, "removed": 0, "created": True}])
        self.assertEqual(second["changes"], [])
        seed, following = mock.observed("child:seed")[0], mock.observed("child:next")[0]
        self.assertEqual(following["messages"][:len(seed["messages"])], seed["messages"])
        self.assertIn("CHILD_PRIVATE_HISTORY_MARKER", json.dumps(following["messages"]))
        self.assertNotIn("PARENT_AFTER_FORK_MARKER", json.dumps(following["messages"]))
        self.assertEqual(content(following["messages"][-1]), "child:next")
        self.assertEqual(system(seed["body"]), system(following["body"]))
        if self.provider == "codex":
            self.assertEqual(seed["body"]["prompt_cache_key"], following["body"]["prompt_cache_key"])
        self.child_log(events[0]["start"]["session_id"])

    def test_background_fork_delivers_a1_then_resumes_foreground(self):
        mock = self.mock()

        def held(items):
            mock.holding.set()
            if not mock.release.wait(10):
                raise AssertionError("test did not release background fork")
            return None, "done:child:held"

        def parent(items):
            if not any(is_result(m) for m in items):
                return "await " + fork("held", background=True), "starting background fork"
            done = completions(items)
            if not done:
                if not mock.holding.wait(5):
                    raise AssertionError("background fork did not request")
                mock.release.set()
                return "await tools.sleep(30); null", "waiting for completion"
            if not mock.observed("child:after-background"):
                return "await " + agent("after-background", resume="a1"), "resuming fork"
            return None, "background complete"

        mock.handlers["child:held"] = held
        mock.handlers["parent:background"] = parent
        mock.plan("child:after-background")
        events = self.finish(self.start("parent:background"))
        output = self.outputs(events)
        self.assertEqual(output[0], {"id": "a1"})
        self.assert_result(output[-1])
        parent_requests = mock.observed("parent:background")
        self.assert_prefix(mock.observed("child:held")[0], parent_requests[1])
        done = completions(parent_requests[-1]["messages"])
        self.assertEqual(len(done), 1)
        self.assert_result(done[0])
        lifecycle = [e["background"] for e in events if "background" in e]
        self.assertEqual([(e["id"], e["state"]) for e in lifecycle], [("a1", "started"), ("a1", "finished")])
        seed = mock.observed("child:held")[0]["messages"]
        following = mock.observed("child:after-background")[0]["messages"]
        self.assertEqual(following[:len(seed)], seed)

    def test_parent_resume_restores_fork_mapping_and_next_task_id(self):
        (self.home / "AGENTS.md").write_text("ORIGINAL_FORK_RECOVERY_SYSTEM")
        mock = self.mock()
        mock.plan("parent:seed", "await " + fork("seed"))
        mock.plan("child:seed")
        events = self.finish(self.start("parent:seed"))
        self.assert_result(self.outputs(events)[0])
        parent_id = events[0]["start"]["session_id"]
        child_path = self.child_log(parent_id)
        before = child_path.read_bytes()
        (self.home / "AGENTS.md").write_text("REPLACED_FORK_RECOVERY_SYSTEM")
        mock.plan("parent:recover", "await " + agent("recovered", resume="a1"), "await " + fork("fresh"))
        mock.plan("child:recovered", "[await " + settled(agent("forbidden")) +
                  ", await " + settled(fork("forbidden")) + "]")
        mock.plan("child:fresh")
        resumed = self.finish(self.start("--resume", parent_id, "parent:recover"))
        old, fresh = self.outputs(resumed)
        self.assert_result(old)
        self.assert_result(fresh, "a2")
        self.assertEqual(resumed[0]["start"]["session_id"], parent_id)
        self.assertTrue(child_path.read_bytes().startswith(before))
        seed, recovered = mock.observed("child:seed")[0], mock.observed("child:recovered")[0]
        self.assertEqual(recovered["messages"][:len(seed["messages"])], seed["messages"])
        self.assertIn("ORIGINAL_FORK_RECOVERY_SYSTEM", system(recovered["body"]))
        self.assertNotIn("REPLACED_FORK_RECOVERY_SYSTEM", system(recovered["body"]))
        self.assertEqual(seed["body"]["tools"], recovered["body"]["tools"])
        self.assert_agent_disabled(mock.observed("child:recovered")[-1], 2)
        self.assertFalse(mock.observed("child:forbidden"))
        self.assert_prefix(mock.observed("child:fresh")[0], mock.observed("parent:recover")[-1])
        if self.provider == "codex":
            self.assertEqual(seed["body"]["prompt_cache_key"], recovered["body"]["prompt_cache_key"])

    def assert_stale_write(self, result, path):
        self.assertIs(result["resolved"], False, result)
        self.assertIn(path.name, result["error"])
        self.assertIn("changed since this session last read or wrote", result["error"])

    def test_background_fork_inherits_parent_file_version_without_reading(self):
        mock = self.mock()
        path = self.cwd / "inherited-version.txt"
        original, updated = "V1 read by parent\n", "V2 written by parent while fork is paused\n"
        path.write_text(original)
        read = "tools.read(" + json.dumps({"path": path.name}) + ")"
        parent_write = "tools.write(" + json.dumps({"path": path.name, "content": updated}) + ")"
        stale_write = "tools.write(" + json.dumps({"path": path.name, "content": "fork based on V1\n"}) + ")"

        def parent(items):
            step = sum(is_result(m) for m in items)
            if step == 0:
                return "await " + read, "parent observes V1"
            if step == 1:
                return "await " + fork("inherited-version", background=True), "fork inherits V1 observation"
            if step == 2:
                if not mock.holding.wait(5):
                    raise AssertionError("fork did not pause before its first write")
                return "await " + parent_write, "parent replaces V1 with V2"
            mock.release.set()
            if not completions(items):
                return "await tools.sleep(30); null", "waiting for inherited stale write"
            return None, "done:parent:inherited-version"

        def child(items):
            if child_step(items) == 0:
                mock.holding.set()
                if not mock.release.wait(5):
                    raise AssertionError("parent did not write V2")
                return "await " + settled(stale_write), "write using inherited V1 without rereading"
            return None, "done:child:inherited-version"

        mock.handlers["parent:inherited-version"] = parent
        mock.handlers["child:inherited-version"] = child
        events = self.finish(self.start("parent:inherited-version"))
        outputs = self.outputs(events)
        self.assertEqual(outputs[0]["text"], original)
        self.assertEqual(outputs[1], {"id": "a1"})
        self.assertEqual(outputs[2], {"bytes": len(updated.encode("utf-8"))})
        child_requests = mock.observed("child:inherited-version")
        self.assertEqual(len(child_requests), 2)
        self.assert_stale_write(tool_value(child_requests[-1]), path)
        self.assertEqual(path.read_text(), updated)
        parent_requests = mock.observed("parent:inherited-version")
        self.assert_prefix(child_requests[0], parent_requests[2])
        done = completions(parent_requests[-1]["messages"])
        self.assertEqual(len(done), 1)
        self.assert_result(done[0])
        self.assertEqual(done[0]["changes"], [])
        child_rows = records(self.child_log(events[0]["start"]["session_id"]))
        calls = [call for row in child_rows for call in row.get("calls", [])]
        self.assertEqual([call["name"] for call in calls], ["write"])
        self.assertIs(calls[0]["ok"], False)

    def test_two_forks_inherit_v1_and_only_one_direct_write_wins(self):
        mock = self.mock()
        path = self.cwd / "two-inherited-versions.txt"
        initial = "shared V1\n"
        path.write_text(initial)
        mock.plan("parent:two-versions", "await tools.read(" + json.dumps({"path": path.name}) + ")",
                  "await Promise.all([" + fork("writer-one") + ", " + fork("writer-two") + "])")
        values = {"writer-one": "first fork replacement\n", "writer-two": "second fork replacement is different\n"}
        for name, value in values.items():
            write = "tools.write(" + json.dumps({"path": path.name, "content": value}) + ")"
            mock.plan("child:" + name, "await " + settled(write))
        events = self.finish(self.start("parent:two-versions"))
        outputs = self.outputs(events)
        self.assertEqual(outputs[0]["text"], initial)
        agents = outputs[1]
        self.assertEqual({r["id"] for r in agents}, {"a1", "a2"})
        attempts = {name: tool_value(mock.observed("child:" + name)[-1]) for name in values}
        winners = [name for name, result in attempts.items() if result["resolved"]]
        self.assertEqual(len(winners), 1, attempts)
        winner = winners[0]
        self.assertEqual(path.read_text(), values[winner])
        for name, result, agent_result in zip(values, attempts.values(), agents):
            self.assert_result(agent_result, agent_result["id"])
            self.assert_prefix(mock.observed("child:" + name)[0], mock.observed("parent:two-versions")[-1])
            if name == winner:
                self.assertEqual(result["value"], {"bytes": len(values[name].encode("utf-8"))})
                self.assertEqual(agent_result["changes"], [{"path": path.name, "added": 1, "removed": 1, "created": False}])
            else:
                self.assert_stale_write(result, path)
                self.assertEqual(agent_result["changes"], [])

    def test_fork_inherits_parent_effort_and_explicit_override_wins(self):
        mock = self.mock()
        mock.plan("parent:step-effort", "null",
                  "const implicit = await " + fork("implicit") +
                  "; const background = await " + fork("background", background=True) +
                  "; const explicit = await " + fork("explicit-low", effort="low") +
                  "; [implicit, background, explicit]")
        for name in ("implicit", "background", "explicit-low"):
            mock.plan("child:" + name)
        events = self.finish(self.start("parent:step-effort"))
        results = self.outputs(events)[1]
        self.assert_result(results[0])
        self.assertEqual(results[1], {"id": "a2"})
        self.assert_result(results[2], "a3")
        parent_requests = mock.observed("parent:step-effort")

        def effort(body):
            return body.get("reasoning", {}).get("effort") if self.provider == "codex" else body.get("reasoning_effort")

        self.assertEqual([effort(r["body"]) for r in parent_requests[:3]], ["high", "high", "high"])
        for name, expected in (("implicit", "high"), ("background", "high"), ("explicit-low", "low")):
            child = mock.observed("child:" + name)[0]
            self.assertEqual(effort(child["body"]), expected, name)
            self.assert_prefix(child, parent_requests[2])
        done = completions(parent_requests[-1]["messages"])
        self.assertEqual(len(done), 1)
        self.assert_result(done[0], "a2")

    def test_queued_background_fork_freezes_history_versions_and_effort(self):
        (self.home / "config.toml").write_text("[limits]\nagent_concurrency = 1\n")
        mock = self.mock()
        path = self.cwd / "queued-version.txt"
        initial, updated = "V1 at enqueue\n", "V2 observed by parent after enqueue\n"
        path.write_text(initial)
        read = "tools.read(" + json.dumps({"path": path.name}) + ")"
        parent_write = "tools.write(" + json.dumps({"path": path.name, "content": updated}) + ")"
        queued_write = "tools.write(" + json.dumps({"path": path.name, "content": "stale queued fork overwrite\n"}) + ")"

        def blocker(items):
            mock.holding.set()
            if not mock.release.wait(5):
                raise AssertionError("parent did not release occupied agent slot")
            return None, "done:child:slot-blocker"

        def parent(items):
            step = sum(is_result(m) for m in items)
            if step == 0:
                return "await " + read, "parent observes V1 before queue"
            if step == 1:
                return "await " + agent("slot-blocker", background=True), "occupy only agent slot"
            if step == 2:
                if not mock.holding.wait(5):
                    raise AssertionError("blocking child did not occupy the agent slot")
                return "await " + fork("queued-snapshot", background=True), "enqueue fork"
            if step in (3, 4):
                if mock.observed("child:queued-snapshot"):
                    raise AssertionError("queued fork ran before the agent slot was released")
                if step == 3:
                    return ("const written = await " + parent_write + "; const reread = await " + read +
                            '; ({written, reread, marker: "POST_QUEUE_STEP_ONE"})'), "advance parent file observation to V2"
                return '"POST_QUEUE_STEP_TWO"', "parent advances another Step"
            mock.release.set()
            if {r["id"] for r in completions(items)} != {"a1", "a2"}:
                return "await tools.sleep(30); null", "waiting for queued fork"
            return None, "done:parent:queued-snapshot"

        mock.handlers["parent:queued-snapshot"] = parent
        mock.handlers["child:slot-blocker"] = blocker
        mock.plan("child:queued-snapshot", "await " + settled(queued_write))
        events = self.finish(self.start("parent:queued-snapshot"))
        outputs = self.outputs(events)
        self.assertEqual(outputs[0]["text"], initial)
        self.assertEqual(outputs[1:3], [{"id": "a1"}, {"id": "a2"}])
        self.assertEqual(outputs[3]["reread"]["text"], updated)
        self.assertEqual(outputs[4], "POST_QUEUE_STEP_TWO")
        parent_requests = mock.observed("parent:queued-snapshot")
        queued = mock.observed("child:queued-snapshot")
        self.assertEqual(len(queued), 2)
        self.assert_prefix(queued[0], parent_requests[3])
        self.assertNotIn("POST_QUEUE_STEP_", json.dumps(queued[0]["messages"]))
        self.assertLess(mock.requests.index(parent_requests[5]), mock.requests.index(queued[0]))
        self.assert_stale_write(tool_value(queued[-1]), path)
        self.assertEqual(path.read_text(), updated)
        effort = (queued[0]["body"].get("reasoning", {}).get("effort") if self.provider == "codex"
                  else queued[0]["body"].get("reasoning_effort"))
        self.assertEqual(effort, "high")
        done = completions(parent_requests[-1]["messages"])
        self.assertEqual({r["id"] for r in done}, {"a1", "a2"})
        fork_result = next(r for r in done if r["id"] == "a2")
        self.assert_result(fork_result, "a2")
        self.assertEqual(fork_result["changes"], [])

    def test_large_current_assistant_does_not_compact_before_first_fork_request(self):
        window = 65536
        self.env["NIB_CONTEXT_WINDOW"] = str(window)
        mock = self.mock()
        large_text = "CURRENT_ASSISTANT_UTF8_PREFIX:" + "界🙂" * 30000
        self.assertGreater(len(large_text.encode("utf-8")) // 3, window * 3 // 4)
        self.assertLess(len(large_text) // 3, window * 3 // 4)

        def parent(items):
            complete_steps = sum(is_result(m) for m in items)
            if complete_steps < 3:
                return "null", "COMPLETE_PARENT_STEP_" + str(complete_steps)
            if complete_steps == 3:
                return "await " + fork("large-prefix"), large_text
            return None, "done:parent:large-prefix"

        mock.handlers["parent:large-prefix"] = parent
        mock.plan("child:large-prefix")
        events = self.finish(self.start("parent:large-prefix"))
        self.assert_result(self.outputs(events)[-1])
        parent_requests = mock.observed("parent:large-prefix")
        self.assertEqual(len(parent_requests), 5)
        self.assertEqual(sum(is_result(m) for m in parent_requests[3]["messages"]), 3)
        request_order = [r["prompt"] for r in mock.requests]
        self.assertEqual(request_order, ["parent:large-prefix"] * 4 +
                         ["child:large-prefix", "parent:large-prefix"])
        self.assertFalse(mock.observed("summary"), "fork must not summarize before its first model request")
        self.assertFalse(any("compact" in e.get("notice", "").lower() for e in events))
        child = mock.observed("child:large-prefix")[0]
        prefix = self.assert_prefix(child, parent_requests[-1])
        self.assertIn(large_text, [content(m) for m in prefix if m.get("role") == "assistant"])
        self.assertEqual(sum(is_result(m) for m in prefix), 3)
        parent_id = events[0]["start"]["session_id"]
        parent_rows = records(self.home / "sessions" / (parent_id + ".jsonl"))
        completed = [r for r in parent_rows if r.get("turn_step") in (1, 2, 3)]
        self.assertEqual([r["turn_step"] for r in completed], [1, 2, 3])
        self.assertTrue(all(r["context_tokens"] < window * 3 // 4 for r in completed))
        inherited = records(self.child_log(parent_id))[0]
        self.assertGreater(inherited["context_tokens"], window * 3 // 4)
        for index in range(3):
            self.assertIn("COMPLETE_PARENT_STEP_" + str(index), [content(m) for m in prefix])

    def test_shared_cwd_rejects_stale_fork_write_after_parent_wins(self):
        mock = self.mock()
        path = self.cwd / "fork-race.txt"
        initial, winner = "original shared file\n", "parent won the shared cwd write race\n"
        path.write_text(initial)
        read = 'tools.read({path: "fork-race.txt"})'
        parent_write = "tools.write(" + json.dumps({"path": path.name, "content": winner}) + ")"
        fork_write = "tools.write(" + json.dumps({"path": path.name, "content": "stale fork must not overwrite\n"}) + ")"

        def parent(items):
            step = sum(is_result(m) for m in items)
            if step == 0:
                return "await " + read, "parent reads original"
            if step == 1:
                return "await " + fork("race-reader", background=True), "start shared cwd fork"
            if step == 2:
                if not mock.holding.wait(5):
                    raise AssertionError("fork did not finish reading the original file")
                return "await " + parent_write, "parent writes after both reads"
            mock.release.set()
            if not completions(items):
                return "await tools.sleep(30); null", "waiting for stale fork attempt"
            return None, "done:parent:write-race"

        def child(items):
            last_user = max(i for i, m in enumerate(items) if m.get("role") == "user")
            step = sum(is_result(m) for m in items[last_user + 1:])
            if step == 0:
                return "await " + read, "fork reads original"
            if step == 1:
                mock.holding.set()
                if not mock.release.wait(5):
                    raise AssertionError("parent did not finish the winning write")
                return "[await " + settled(fork_write) + ", await " + read + "]", "fork tries stale write then rereads"
            return None, "done:child:race-reader"

        mock.handlers["parent:write-race"] = parent
        mock.handlers["child:race-reader"] = child
        events = self.finish(self.start("parent:write-race"))
        outputs = self.outputs(events)
        self.assertEqual(outputs[0]["text"], initial)
        self.assertEqual(outputs[1], {"id": "a1"})
        self.assertEqual(outputs[2], {"bytes": len(winner.encode("utf-8"))})
        child_requests = mock.observed("child:race-reader")
        self.assertEqual(len(child_requests), 3)
        child_read = next(m for m in reversed(child_requests[1]["messages"]) if is_result(m))
        read_result = json.loads(child_read.get("output", content(child_read)).removeprefix("result: "))
        self.assertEqual(read_result["text"], initial)
        child_write = next(m for m in reversed(child_requests[2]["messages"]) if is_result(m))
        rejected, reread = json.loads(child_write.get("output", content(child_write)).removeprefix("result: "))
        self.assertIs(rejected["resolved"], False, rejected)
        self.assertIn(path.name, rejected["error"])
        self.assertIn("changed since this session last read or wrote", rejected["error"])
        self.assertEqual(reread["text"], winner)
        self.assertEqual(path.read_text(), winner)
        parent_requests = mock.observed("parent:write-race")
        self.assert_prefix(child_requests[0], parent_requests[2])
        done = completions(parent_requests[-1]["messages"])
        self.assertEqual(len(done), 1)
        self.assert_result(done[0])
        self.assertEqual(done[0]["changes"], [])

    def test_fork_after_automatic_compaction_uses_compacted_parent_prefix(self):
        self.env["NIB_CONTEXT_WINDOW"] = "65536"
        mock = self.mock()
        mock.handlers["parent:old"] = lambda _: (None, "OLD_HISTORY_TO_COMPACT" + "x" * 24000)
        mock.plan("parent:middle")
        mock.plan("parent:trigger")
        mock.tokens["parent:trigger"] = 60000
        session = None
        for prompt in ("parent:old", "parent:middle", "parent:trigger"):
            events = self.finish(self.start(*(["--resume", session] if session else []), prompt))
            session = events[0]["start"]["session_id"]
        mock.plan("parent:compacted-fork", "await " + fork("compacted"))
        mock.plan("child:compacted")
        events = self.finish(self.start("--resume", session, "parent:compacted-fork"))
        self.assert_result(self.outputs(events)[0])
        self.assertTrue(mock.observed("summary"))
        self.assertTrue(any("compacted context:" in e.get("notice", "") for e in events), events)
        child = mock.observed("child:compacted")[0]
        self.assert_prefix(child, mock.observed("parent:compacted-fork")[-1])
        self.assertTrue(any(content(m).startswith("Earlier session summary:") for m in child["messages"]))
        self.assertNotIn("OLD_HISTORY_TO_COMPACT", json.dumps(child["messages"]))


class ChatForkTests(ForkTests, unittest.TestCase):
    provider = "chat_completions"

    def test_tool_delivery_fork_advertises_and_executes_wait(self):
        self.env["NIB_MODEL"] = "deepseek-flash"
        mock = self.mock()
        mock.plan("parent:fork-wait", "await " + fork("fork-wait"))
        mock.plan("child:fork-wait",
                  "await tools.bash({command: 'printf fork-wait-result', background: true}); "
                  "await tools.wait()")
        events = self.finish(self.start("parent:fork-wait"))
        self.assert_result(self.outputs(events)[0])

        seed, waited, *_ = mock.observed("child:fork-wait")
        prompt = system(seed["body"])
        self.assertIn("async wait(", prompt)
        self.assertIn("call `await tools.wait()`", prompt)
        output = content(waited["messages"][-1])
        self.assertTrue(output.startswith("result: "), output)
        result = json.loads(output.removeprefix("result: "))
        self.assertIs(result["ok"], True, result)
        task, = result["results"]
        self.assertEqual((task["id"], task["kind"]), ("b1", "bash"))
        self.assertIs(task["ok"], True, task)
        self.assertIn("fork-wait-result", task["output"])

    def test_tool_delivery_ordinary_child_waits_without_tools(self):
        self.env["NIB_MODEL"] = "deepseek-flash"
        (self.home / "config.toml").write_text("[limits]\nrun_background_after_ms = 50\n")
        mock = self.mock()
        mock.plan("parent:ordinary-child", "await " + agent("ordinary-child"))
        gate = self.cwd / "release-child-run"

        def child(_items):
            step = len(mock.observed("child:ordinary-child"))
            if step == 1:
                return "({exposed: 'wait' in tools, type: typeof tools.wait})", "Checking API"
            if step == 2:
                return checked_bash(wait_command(gate.name)) + "'child-run-result'", "Starting long Run"
            gate.touch()
            return None, "Done"

        mock.handlers["child:ordinary-child"] = child
        self.finish(self.start("parent:ordinary-child"))

        seed, probed, registered, completed = mock.observed("child:ordinary-child")
        prompt = system(seed["body"])
        self.assertIn("Results are appended to a later Run's output", prompt)
        self.assertIn("reply briefly without tools", prompt)
        self.assertNotIn("async wait(", prompt)
        self.assertNotIn("tools.wait(", prompt)
        self.assertEqual(tool_value(probed), {"exposed": False, "type": "undefined"})
        notice = content(registered["messages"][-1])
        self.assertIn("continuing in background as r1", notice)
        self.assertIn("reply briefly without tools", notice)
        self.assertNotIn("tools.wait(", notice)
        delivered = completed["messages"][-1]
        self.assertEqual(delivered["role"], "user")
        self.assertIn("child-run-result", content(delivered))


class CodexForkTests(ForkTests, unittest.TestCase):
    provider = "codex"

    def test_codex_model_mismatch_is_data_but_effort_override_is_allowed(self):
        mock = self.mock()
        mock.plan("parent:options", "[await " + settled(fork("forbidden", model="gpt-6-sol")) +
                  ", await " + fork("low-effort", model="gpt-6.1-sol", effort="low") + "]")
        mock.plan("child:low-effort")
        failed, success = self.outputs(self.finish(self.start("parent:options")))[0]
        self.assertIs(failed["resolved"], True, failed)
        self.assertIs(failed["value"]["ok"], False, failed)
        self.assertRegex(failed["value"]["error"].lower(), "model")
        self.assert_result(success, success["id"])
        self.assertFalse(mock.observed("child:forbidden"))
        child, parent = mock.observed("child:low-effort")[0], mock.observed("parent:options")[-1]
        self.assert_prefix(child, parent)
        self.assertEqual(child["body"]["model"], parent["body"]["model"])
        self.assertEqual(child["body"]["reasoning"]["effort"], "low")
        self.assertEqual(parent["body"]["reasoning"]["effort"], "high")


if __name__ == "__main__":
    unittest.main()
