#!/usr/bin/env python3
"""Correctness tests for the model-free benchmark's statistics and raw data checks."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "bench_scheduler", Path(__file__).resolve().parents[1] / "scripts/bench_scheduler.py"
)
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class BenchmarkStatistics(unittest.TestCase):
    def test_nearest_rank_and_nanosecond_conversion(self):
        self.assertEqual(bench.summary(list(range(1000, 21000, 1000))),
                         dict(n=20, p50_us=10.0, p95_us=19.0))
        self.assertEqual(bench.summary([42]), dict(n=1, p50_us=0.042, p95_us=0.042))
        with self.assertRaises(ValueError):
            bench.summary([])

    def rows(self):
        yield dict(kind="calibration", clock_pair_ns=[20, 30], mark_pair_ns=[25, 35],
                   ack_batch_ns=[1000, 2000], loop_batch_ns=[500, 600], ack_batch_calls=100000)
        slot = dict(enqueued=100, dispatch=200, spawn_begin=210, spawn_end=500,
                    worker_enter=300, tool_begin=310, tool_end=400,
                    join_begin=510, join_end=520, deliver=530,
                    record_begin=540, record_end=550, bridge_begin=560,
                    bridge_end=570, received=580)
        for workload in ("serial", "parallel", "mixed", "large"):
            for recorded in (False, True):
                for traced in (False, True):
                    s = slot.copy()
                    if not recorded:
                        s.update(record_begin=0, record_end=0)
                    yield dict(kind="run", workload=workload, recorded=recorded,
                               traced=traced, round=0, run_ns=1000, eval_ns=900,
                               record_finish_ns=90,
                               slots=[s.copy() for _ in range(16 if workload == "large" else 128)] if traced else [])

    def aggregate(self, rows):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "raw.jsonl"
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            return bench.aggregate(path, 1)

    def test_direct_intervals_and_mixed_groups(self):
        result = self.aggregate(self.rows())
        row = next(r for r in result["calls"] if r["workload"] == "mixed" and not r["recorded"] and r["kind"] == "short")
        self.assertEqual(row["metrics"]["tool"], dict(n=124, p50_us=0.09, p95_us=0.09))
        self.assertEqual(row["metrics"]["spawn_api"]["p50_us"], 0.29)
        self.assertEqual(row["metrics"]["dispatch_to_worker"]["p50_us"], 0.1)
        self.assertNotIn("record_settle", row["metrics"])
        wait = next(r for r in result["calls"] if r["workload"] == "mixed" and r["recorded"] and r["kind"] == "wait")
        self.assertEqual(wait["metrics"]["tool"]["n"], 4)

    def test_rejects_missing_duplicate_and_negative_intervals(self):
        rows = list(self.rows())
        with self.assertRaises(ValueError):
            self.aggregate(rows[:-1])
        with self.assertRaises(ValueError):
            self.aggregate(rows + [rows[-1]])
        rows[-1]["round"] = 1
        with self.assertRaises(ValueError):
            self.aggregate(rows)
        rows[-1]["round"] = 0
        traced = next(r for r in rows if r.get("traced"))
        traced["slots"][0]["received"] = 1
        with self.assertRaises(ValueError):
            self.aggregate(rows)


if __name__ == "__main__":
    unittest.main()
