"""File-tool Session E2E via local HTTP mock; no API key. Run after `zig build`."""
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler
from mock_http import ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def js_call(name, **args):
    return "await tools." + name + "(" + json.dumps(args) + ")"


def command(*args):
    return shlex.join([str(arg) for arg in args])


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        prompt = next(message["content"] for message in reversed(messages)
                      if message["role"] == "user")
        try:
            plan = json.loads(prompt)
        except ValueError:
            plan = None
        codes = plan["runs"] if isinstance(plan, dict) and "runs" in plan else [prompt]
        completed = sum(message["role"] == "tool" for message in messages)
        if completed < len(codes):
            delta = {"tool_calls": [{
                "index": 0, "id": "files_run_" + str(completed), "type": "function",
                "function": {"name": "run",
                             "arguments": json.dumps({"code": codes[completed]})},
            }]}
            reason = "tool_calls"
        else:
            delta = {"content": "done"}
            reason = "stop"
        events = [
            {"choices": [{"index": 0, "delta": delta}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": reason}],
             "usage": {"prompt_tokens": 100, "completion_tokens": 20}},
        ]
        body = ("".join("data: " + json.dumps(event) + "\n\n" for event in events)
                + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BIN.is_file():
            raise RuntimeError("Build nib first with `zig build`")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nib-files-")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        self.home = self.tmp / "nib"
        self.home.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("NIB_", "OPENAI_", "DEEPSEEK_", "CODEX_"))}
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop_server():
            server.shutdown()
            server.server_close()
            thread.join()
        self.addCleanup(stop_server)
        self.env.update(
            NIB_PROVIDER="chat_completions", NIB_API_KEY="mock",
            NIB_BASE_URL=f"http://127.0.0.1:{server.server_port}",
            NIB_CONTEXT_WINDOW="128000", NIB_HOME=str(self.home), HOME=str(self.tmp),
            XDG_DATA_HOME=str(self.tmp / "data"), XDG_CONFIG_HOME=str(self.tmp / "config"),
            CODEX_HOME=str(self.tmp / "codex"))

    def start(self, code):
        process = subprocess.Popen([str(BIN), "ask", "--json", code], cwd=self.cwd, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate()
        self.addCleanup(cleanup)
        return process

    def finish(self, process, timeout=30):
        output, error = process.communicate(timeout=timeout)
        self.assertEqual(process.returncode, 0, output + error)
        events = [json.loads(line) for line in output.splitlines()]
        runs = [event["run_end"] for event in events if "run_end" in event]
        self.assertTrue(runs, output + error)
        for run in runs:
            self.assertIs(run["ok"], True, output + error)
        self.assertTrue(any("end" in event for event in events), output + error)
        return output

    def run_js(self, code):
        return self.finish(self.start(code))

    def wait_for(self, predicate, process=None, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if process is not None and process.poll() is not None:
                output, error = process.communicate()
                self.fail("nib exited before ready: " + output + error)
            time.sleep(.01)
        self.fail("timed out waiting for nib")

    def barrier(self, ready):
        shell = "touch " + shlex.quote(ready) + "; while [ ! -f release ]; do sleep .01; done"
        return js_call("bash", command=shell) + ";\n"

    def test_finish_rejects_run_failure_despite_final_success(self):
        process = self.start("throw new Error('intentional Run failure')")
        with self.assertRaisesRegex(AssertionError, "intentional Run failure"):
            self.finish(process)
        self.assertEqual(process.returncode, 0)

    def test_cross_process_edits_coordinate_aliases_and_symlinks(self):
        (self.cwd / "sub").mkdir()
        (self.cwd / "link").symlink_to("shared")
        (self.cwd / "directory-link").symlink_to("sub", target_is_directory=True)
        paths = ["shared", "./sub/../shared", "link", "directory-link/../shared"]
        markers = ["<worker-" + str(i) + ">" for i in range(len(paths))]
        original = "\n".join(markers * 2) + "\n"
        target = self.cwd / "shared"
        target.write_text(original)
        rounds = 150
        workers = []
        for index, path in enumerate(paths):
            code = self.barrier("ready-" + str(index))
            code += "const path = " + json.dumps(path) + ";\n"
            code += "const marker = " + json.dumps(markers[index]) + ";\n"
            code += ("for (let i = 0; i < " + str(rounds) + "; i++) {\n"
                     "  const result = await tools.edit({path, old_text: marker,\n"
                     "    new_text: marker + '[addition-" + str(index) + "-' + i + ']', all: true});\n"
                     "  if (result.replaced !== 2) throw new Error('lost marker');\n"
                     "}\n")
            workers.append(self.start(code))
        for index, worker in enumerate(workers):
            self.wait_for(lambda i=index: (self.cwd / ("ready-" + str(i))).exists(), worker)
        (self.cwd / "release").touch()
        for worker in workers:
            self.finish(worker, timeout=60)
        actual = target.read_text()
        expected = original
        for index, marker in enumerate(markers):
            for iteration in range(rounds):
                addition = f"[addition-{index}-{iteration}]"
                self.assertEqual(actual.count(addition), 2, addition)
                expected = expected.replace(marker, marker + addition)
        self.assertEqual(actual, expected)
        self.assertTrue((self.cwd / "link").is_symlink())
        locks = list((self.home / "locks").iterdir())
        self.assertEqual([p.name for p in locks],
                         [hashlib.sha256(os.fsencode(target.resolve())).hexdigest()])
        self.assertEqual(list(self.cwd.glob(".nib-*")), [])

    def check_stale_write(self, modification):
        target = self.cwd / "observed"
        target.write_text("before\n")
        code = js_call("read", path="observed") + ";\n"
        code += "const external = " + js_call("bash", command=modification) + ";\n"
        code += "if (external.exit_code !== 0) throw new Error(external.output);\n"
        code += "let rejected = false;\ntry {\n"
        code += js_call("write", path="observed", content="STALE\n") + ";\n"
        code += ("} catch (error) {\n"
                 "  if (!/changed|stale/i.test(String(error))) throw error;\n"
                 "  rejected = true;\n}\n"
                 "if (!rejected) throw new Error('stale write was accepted');\n")
        code += "const current = " + js_call("read", path="./observed") + ";\n"
        code += "if (current.text !== 'others\\n') throw new Error('external content lost');\n"
        code += js_call("write", path="observed", content="fresh\n") + ";\n"
        self.run_js(code)
        self.assertEqual(target.read_text(), "fresh\n")

    def test_observation_survives_run_boundaries(self):
        target = self.cwd / "observed"
        target.write_text("before\n")
        modification = command(sys.executable, "-c",
                               "from pathlib import Path; Path('observed').write_text('external change')")
        first = js_call("read", path="observed")
        second = js_call("bash", command=modification) + ";\n"
        second += "let rejected = false; try { " + js_call("write", path="observed", content="stale")
        second += "; } catch (error) { if (!String(error).includes('changed since')) throw error; rejected = true; }\n"
        second += "if (!rejected) throw new Error('observation lost between Runs');\n"
        second += js_call("read", path="observed") + ";\n"
        second += js_call("write", path="observed", content="fresh")
        self.run_js(json.dumps({"runs": [first, second]}))
        self.assertEqual(target.read_text(), "fresh")

    def test_stale_write_after_bash_same_size_modification(self):
        python = ("import os; from pathlib import Path; p=Path('observed'); s=p.stat(); "
                  "p.write_text('others\\n'); "
                  "os.utime(p, ns=(s.st_atime_ns, s.st_mtime_ns + 1000000000))")
        self.check_stale_write(command(sys.executable, "-c", python))

    def test_stale_write_after_separate_nib_process(self):
        child = js_call("write", path="observed", content="others\n")
        self.check_stale_write(command("env", "NIB_API_KEY=mock", BIN, "ask", "--json", child)
                               + " > /dev/null")

    def test_read_page_records_version_and_edit_refreshes_it(self):
        target = self.cwd / "paged"
        target.write_text("first\nsecond\n" + "unread tail\n" * 10000)
        modify = command(sys.executable, "-c",
                         "from pathlib import Path; Path('paged').write_text('external\\nsecond\\n')")
        code = "const page = " + js_call("read", path="paged", offset=2, limit=1) + ";\n"
        code += "if (page.text !== 'second\\n' || page.next_offset !== 3) throw new Error('bad page');\n"
        code += js_call("bash", command=modify) + ";\n"
        code += "let rejected = false; try { " + js_call("write", path="paged", content="stale")
        code += "; } catch (error) { if (!/changed|stale/i.test(String(error))) throw error; rejected = true; }\n"
        code += "if (!rejected) throw new Error('paged read did not record version');\n"
        code += js_call("edit", path="paged", old_text="external", new_text="edited") + ";\n"
        code += js_call("write", path="paged", content="after edit\n") + ";\n"
        code += js_call("write", path="paged", content="after write\n") + ";\n"
        self.run_js(code)
        self.assertEqual(target.read_text(), "after write\n")

    def test_unseen_write_permissions_symlinks_and_hardlinks(self):
        target = self.cwd / "target"
        target.write_text("original\n")
        target.chmod(0o751)
        inode = target.stat().st_ino
        os.link(target, self.cwd / "hardlink")
        (self.cwd / "symlink").symlink_to("target")
        code = js_call("write", path="symlink", content="replacement\n") + ";\n"
        code += js_call("edit", path="symlink", old_text="replacement", new_text="edited") + ";\n"
        code += js_call("write", path="nested/new", content="created\n") + ";\n"
        self.run_js(code)
        self.assertEqual(target.read_text(), "edited\n")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o751)
        self.assertNotEqual(target.stat().st_ino, inode)
        self.assertEqual((self.cwd / "hardlink").read_text(), "original\n")
        self.assertEqual((self.cwd / "hardlink").stat().st_ino, inode)
        self.assertTrue((self.cwd / "symlink").is_symlink())
        self.assertEqual((self.cwd / "nested/new").read_text(), "created\n")
        self.assertEqual(list(self.cwd.rglob(".nib-*")), [])

    def test_lock_wait_sigterm_is_prompt_for_read_edit_write(self):
        target = self.cwd / "locked"
        target.write_text("unchanged\n")
        locks = self.home / "locks"
        locks.mkdir()
        lock_path = locks / hashlib.sha256(os.fsencode(target.resolve())).hexdigest()
        operations = [js_call("read", path="locked"),
                      js_call("edit", path="locked", old_text="unchanged", new_text="edited"),
                      js_call("write", path="locked", content="written\n")]
        for index, operation in enumerate(operations):
            with self.subTest(operation=operation), lock_path.open("a+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                inode = lock_path.stat().st_ino
                ready = self.cwd / ("waiting-" + str(index))
                code = js_call("bash", command=command("touch", ready)) + ";\n" + operation
                process = self.start(code)
                self.wait_for(ready.exists, process)
                time.sleep(.2)
                self.assertIsNone(process.poll(), "tool did not wait for Python flock")
                started = time.monotonic()
                process.send_signal(signal.SIGTERM)
                output, error = process.communicate(timeout=3)
                self.assertLess(time.monotonic() - started, 3)
                self.assertNotEqual(process.returncode, 0, output + error)
                self.assertEqual(target.read_text(), "unchanged\n")
                self.assertEqual(lock_path.stat().st_ino, inode)
        self.run_js(js_call("edit", path="locked", old_text="unchanged", new_text="available"))
        self.assertEqual(target.read_text(), "available\n")
        self.assertEqual(lock_path.stat().st_ino, inode)

    def test_atomic_replace_never_exposes_partial_bytes_to_reader(self):
        target = self.cwd / "atomic"
        contents = {b"a" * (96 * 1024), b"b" * (128 * 1024)}
        target.write_bytes(b"a" * (96 * 1024))
        stop = threading.Event()
        failures = []
        observations = set()

        def reader():
            try:
                while not stop.is_set():
                    data = target.read_bytes()
                    if data not in contents:
                        failures.append("partial file: " + str(len(data)) + " bytes")
                        return
                    observations.add(len(data))
            except Exception as error:
                failures.append(repr(error))

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        try:
            self.run_js("for (let i = 0; i < 100; i++) {\n"
                        "  await tools.write({path: 'atomic', content: i % 2 ? 'a'.repeat(98304) : 'b'.repeat(131072)});\n"
                        "}\n")
        finally:
            stop.set()
            thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        self.assertIn(96 * 1024, observations)
        self.assertIn(128 * 1024, observations)
        self.assertEqual(list(self.cwd.glob(".nib-*")), [])


if __name__ == "__main__":
    unittest.main()
