"""Compare ReleaseFast binaries with local mocks; no provider credentials needed.

Usage: python3 scripts/bench-record.py /path/to/nib-before /path/to/nib-after
"""
import json
from pathlib import Path
import statistics
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
import test_replay


def measure(binaries, size, enabled):
    cases = []
    samples = [[] for _ in binaries]
    reference = None
    calls = 64 if size == 128 else 8
    code = (
        f"for(let i=0;i<{calls};i++) {{"
        "const r=await tools.read({path:'fixture-'+i});"
        f"if(r.text.length!=={size}) throw new Error('short result');"
        "} console.log('complete');"
    )
    try:
        for binary in binaries:
            case = test_replay.ReplayTests()
            case.setUp()
            cases.append(case)
            if not enabled:
                case.env["NIB_RECORD"] = "off"
            for i in range(calls):
                (case.cwd / f"fixture-{i}").write_text(chr(65 + i % 26) * size)
        for trial in range(8):
            order = list(range(len(binaries)))
            if trial % 2:
                order.reverse()
            for index in order:
                case = cases[index]
                test_replay.BIN = Path(binaries[index]).resolve()
                start = time.perf_counter_ns()
                session = case.ask([code])
                elapsed = time.perf_counter_ns() - start
                rows = test_replay.jsonl(case.home / "sessions" / f"{session}.jsonl")
                outputs = [m.get("content", "") for r in rows for m in r.get("messages", []) if m["role"] == "tool"]
                assert any("complete" in output for output in outputs), outputs
                if enabled:
                    recording = test_replay.jsonl(case.calls_path(session))
                    for row in recording:
                        if "meta" in row:
                            del row["meta"]["start_ms_epoch"]
                    assert len(recording) == calls + 1
                    if reference is not None:
                        assert reference == recording, "recording format changed"
                    reference = recording
                else:
                    assert not case.calls_path(session).exists()
                if trial:
                    samples[index].append(elapsed / 1e6)
        return [{"binary": str(binary), "size": size, "enabled": enabled,
                 "median_ms": statistics.median(sample), "samples_ms": sample}
                for binary, sample in zip(binaries, samples)]
    finally:
        for case in cases:
            case.doCleanups()


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    for size in (128, 1024 * 1024):
        for enabled in (True, False):
            for result in measure(sys.argv[1:], size, enabled):
                print(json.dumps(result), flush=True)
