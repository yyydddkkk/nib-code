#!/usr/bin/env python3
"""Build and measure the native scheduler without a model or external service."""

import argparse
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
STAGES = {
    "queue": ("enqueued", "dispatch"),
    "spawn_api": ("spawn_begin", "spawn_end"),
    "dispatch_to_worker": ("dispatch", "worker_enter"),
    "dispatch_to_tool": ("dispatch", "tool_begin"),
    "tool": ("tool_begin", "tool_end"),
    "return_to_js": ("tool_end", "received"),
    "return_to_delivery": ("tool_end", "deliver"),
    "join": ("join_begin", "join_end"),
    "record_settle": ("record_begin", "record_end"),
    "bridge": ("bridge_begin", "bridge_end"),
    "resolve_to_js": ("bridge_end", "received"),
}


def summary(values):
    values = sorted(values)
    if not values:
        raise ValueError("empty metric")
    return {
        "n": len(values),
        "p50_us": values[math.ceil(len(values) * 0.50) - 1] / 1000,
        "p95_us": values[math.ceil(len(values) * 0.95) - 1] / 1000,
    }


def aggregate(path, samples):
    metrics = collections.defaultdict(lambda: collections.defaultdict(list))
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    seen = set()
    calibration = None
    with path.open() as stream:
        for line in stream:
            row = json.loads(line)
            if row["kind"] == "calibration":
                if calibration is not None:
                    raise ValueError("duplicate calibration")
                calibration = {
                    key: summary(row[key])
                    for key in ("clock_pair_ns", "mark_pair_ns", "ack_batch_ns", "loop_batch_ns")
                }
                calibration["ack_batch_calls"] = row["ack_batch_calls"]
                continue
            if not 0 <= row["round"] < samples:
                raise ValueError("unexpected round")
            key = (row["workload"], row["recorded"], row["traced"])
            identity = (*key, row["round"])
            if identity in seen:
                raise ValueError(f"duplicate run {identity}")
            seen.add(identity)
            for name in ("run_ns", "eval_ns", "record_finish_ns"):
                metrics[key][name].append(row[name])
            expected = 16 if row["workload"] == "large" else 128
            if len(row["slots"]) != (expected if row["traced"] else 0):
                raise ValueError("incomplete slots")
            for index, slot in enumerate(row["slots"]):
                kind = "wait" if row["workload"] == "mixed" and index < 4 else "short"
                if row["workload"] == "large":
                    kind = "large"
                call_key = (*key[:2], kind)
                for name, (start, end) in STAGES.items():
                    if name == "record_settle" and not row["recorded"]:
                        continue
                    if slot[start] <= 0 or slot[end] < slot[start]:
                        raise ValueError(f"invalid {name} timestamps")
                    groups[call_key][name].append(slot[end] - slot[start])
    if len(seen) != samples * 16 or calibration is None:
        raise ValueError("missing runs or calibration")
    runs = []
    for (workload, recorded, traced), values in sorted(metrics.items()):
        if len(values["run_ns"]) != samples:
            raise ValueError("missing configuration samples")
        runs.append(dict(workload=workload, recorded=recorded, traced=traced,
                         metrics={k: summary(v) for k, v in values.items()}))
    calls = []
    for (workload, recorded, kind), values in sorted(groups.items()):
        calls.append(dict(workload=workload, recorded=recorded, kind=kind,
                          metrics={k: summary(v) for k, v in values.items()}))
    return dict(calibration=calibration, runs=runs, calls=calls)


def environment():
    cpu = platform.processor()
    if Path("/proc/cpuinfo").exists():
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    power = {}
    if hasattr(os, "sched_getaffinity"):
        for index in sorted(os.sched_getaffinity(0)):
            directory = Path(f"/sys/devices/system/cpu/cpu{index}/cpufreq")
            power[str(index)] = {
                name: (directory / name).read_text().strip()
                for name in ("scaling_governor", "scaling_min_freq", "scaling_max_freq")
                if (directory / name).exists()
            }
    return dict(
        platform=platform.platform(), cpu=cpu, power=power,
        affinity=sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        load=os.getloadavg(),
        zig=subprocess.check_output(["zig", "version"], text=True).strip(),
        commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        diff_sha256=hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)).hexdigest(),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=100)
    parser.add_argument("--warmups", type=int, default=10)
    parser.add_argument("--output", type=Path, default=Path("/tmp/nib-scheduler-bench"))
    parser.add_argument("--cpus", help="Linux logical CPUs, comma-separated; default: first four allowed CPUs")
    args = parser.parse_args()
    if args.samples < 1 or args.warmups < 0:
        parser.error("samples must be positive and warmups nonnegative")
    if hasattr(os, "sched_setaffinity"):
        cpus = {int(x) for x in args.cpus.split(",")} if args.cpus else set(sorted(os.sched_getaffinity(0))[:4])
        os.sched_setaffinity(0, cpus)
    elif args.cpus:
        parser.error("--cpus requires sched_setaffinity")
    args.output.mkdir(parents=True, exist_ok=True)
    raw = args.output / "raw.jsonl"
    before = environment()
    command = ["zig", "build", "bench-scheduler", "-Doptimize=ReleaseFast", "--"]
    with tempfile.TemporaryDirectory(prefix="nib-scheduler-record-") as tmp:
        recording = Path(tmp) / "calls.jsonl"
        command += [str(recording), str(args.samples), str(args.warmups)]
        started = time.monotonic_ns()
        with raw.open("w") as stream:
            subprocess.run(command, cwd=ROOT, stdout=stream, check=True)
        elapsed = time.monotonic_ns() - started
        recording_bytes = recording.stat().st_size
        filesystem = subprocess.check_output(["df", "-T", tmp], text=True, env=dict(os.environ, LC_ALL="C")) if platform.system() == "Linux" else None
    result = aggregate(raw, args.samples)
    with raw.open("rb") as stream:
        raw_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    result["conditions"] = dict(
        before=before, after=environment(), command=command,
        samples=args.samples, warmups=args.warmups, build="ReleaseFast",
        concurrency=8, short_calls=128, mixed_waits=4, wait_ms=20,
        large_calls=16, large_payload_bytes=262144, recording_bytes=recording_bytes,
        recording_filesystem=filesystem, build_and_measure_ns=elapsed,
        raw_sha256=raw_sha256,
    )
    report = args.output / "summary.json"
    report.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Raw timestamps: {raw}\nSummary: {report}")
    print("Run (ms): workload recording probe n p50 p95")
    for row in result["runs"]:
        m = row["metrics"]["run_ns"]
        print(f"{row['workload']:8} {str(row['recorded']):5} {str(row['traced']):5} {m['n']:4} {m['p50_us']/1000:9.3f} {m['p95_us']/1000:9.3f}")
    print("Calls (us): workload recording kind stage n p50 p95")
    for row in result["calls"]:
        for stage, m in row["metrics"].items():
            print(f"{row['workload']:8} {str(row['recorded']):5} {row['kind']:5} {stage:20} {m['n']:6} {m['p50_us']:10.3f} {m['p95_us']:10.3f}")
    print("Calibration (us):", json.dumps(result["calibration"]))


if __name__ == "__main__":
    main()
