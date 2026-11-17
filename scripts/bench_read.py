"""Linux read benchmark: python3 scripts/bench_read.py BEFORE AFTER RESULTS.json.

Run from the repository root with two ReleaseFast binaries and GNU time.
The data file lives in .zig-cache, which must be on a disk-backed filesystem.
"""
import contextlib
import ctypes
import json
import mmap
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from mock_http import ThreadingHTTPServer
from test_files import MockHandler


def measure(before, after, output_path):
    if sys.platform != "linux":
        raise SystemExit("This benchmark requires Linux mincore and GNU time")
    libc = ctypes.CDLL(None, use_errno=True)
    with contextlib.ExitStack() as cleanup:
        server = cleanup.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), MockHandler))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        cleanup.callback(thread.join)
        cleanup.callback(server.shutdown)
        temp = cleanup.enter_context(tempfile.TemporaryDirectory(
            prefix="nib-read-bench-", dir=Path(".zig-cache").resolve()))
        root = Path(temp)
        target = root / "large.txt"
        line = b"x" * 63 + b"\n"
        target.write_bytes(line * (15 * 1024 * 1024 // 64))
        fd = os.open(target, os.O_RDWR)
        cleanup.callback(os.close, fd)
        os.fsync(fd)
        # The benchmark-only mapping queries residency without touching file pages.
        mapping = cleanup.enter_context(mmap.mmap(fd, 0, access=mmap.ACCESS_COPY))
        address = ctypes.addressof(ctypes.c_char.from_buffer(mapping))
        pages = (len(mapping) + mmap.PAGESIZE - 1) // mmap.PAGESIZE

        def resident():
            vector = (ctypes.c_ubyte * pages)()
            if libc.mincore(ctypes.c_void_p(address), ctypes.c_size_t(len(mapping)), vector):
                raise OSError(ctypes.get_errno())
            return sum(value & 1 for value in vector)

        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("NIB_", "OPENAI_", "CODEX_", "DEEPSEEK_"))}
        env.update(HOME=temp, NIB_HOME=str(root / "home"),
                   NIB_PROVIDER="chat_completions", NIB_API_KEY="mock",
                   NIB_BASE_URL=f"http://127.0.0.1:{server.server_port}")
        # Warm executable/library pages and lock directories outside the samples.
        for binary in (before, after):
            warmup = subprocess.run(
                [binary, "ask", "--json", "await tools.read({path:'large.txt',limit:4})"],
                cwd=temp, env=env, capture_output=True, text=True)
            if warmup.returncode:
                raise RuntimeError(warmup.stdout + warmup.stderr)
        tasks = [(cache, offset, binary) for cache in ("hot", "cold")
                 for offset in (1, 245753) for binary in (before, after) for _ in range(20)]
        random.Random(42).shuffle(tasks)
        results = []
        for cache, offset, binary in tasks:
            if cache == "hot":
                os.pread(fd, len(mapping), 0)
            else:
                os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
            initial_pages = resident()
            if initial_pages != (pages if cache == "hot" else 0):
                raise RuntimeError(f"{cache}: unexpected residency {initial_pages}/{pages}")
            args = json.dumps(dict(path="large.txt", offset=offset, limit=4))
            code = ("const start = Date.now(); const p = await tools.read(" + args + ");"
                    "if (p.text.length !== 256 || p.next_offset !== " + str(offset + 4) + ")"
                    " throw new Error('bad page');"
                    "console.log('READ_MS=' + (Date.now() - start));")
            metrics = root / "time.txt"
            start = time.perf_counter_ns()
            process = subprocess.run(
                ["/usr/bin/time", "-f", "%M %I", "-o", str(metrics),
                 binary, "ask", "--json", code],
                cwd=temp, env=env, capture_output=True, text=True)
            elapsed_ms = (time.perf_counter_ns() - start) / 1e6
            if process.returncode:
                raise RuntimeError(process.stdout + process.stderr)
            events = [json.loads(line) for line in process.stdout.splitlines()]
            runs = [event["run_end"] for event in events if "run_end" in event]
            if len(runs) != 1 or not runs[0]["ok"]:
                raise RuntimeError(process.stdout)
            read_ms = int(re.search(r"READ_MS=(\d+)", runs[0]["output"])[1])
            rss, inputs = map(int, metrics.read_text().split())
            results.append(dict(
                cache=cache, offset=offset, binary="before" if binary == before else "after",
                ms=elapsed_ms, read_ms=read_ms, rss_kib=rss, input_blocks=inputs,
                resident_before=initial_pages, resident_after=resident()))
        output = dict(file_bytes=len(mapping), page_bytes=mmap.PAGESIZE,
                      pages=pages, samples=results)
        Path(output_path).write_text(json.dumps(output, indent=2) + "\n")
        for cache in ("hot", "cold"):
            for offset in (1, 245753):
                for binary in ("before", "after"):
                    rows = [r for r in results if (r["cache"], r["offset"], r["binary"])
                            == (cache, offset, binary)]
                    medians = {key: round(statistics.median(r[key] for r in rows), 3)
                               for key in ("ms", "read_ms", "rss_kib",
                                           "input_blocks", "resident_after")}
                    print(cache, offset, binary, medians)


if __name__ == "__main__":
    before, after = (str(Path(path).resolve()) for path in sys.argv[1:3])
    measure(before, after, sys.argv[3])
