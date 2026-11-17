# Native tool scheduling benchmark

This is a measurement experiment, not a worker pool. It runs the real QuickJS bridge, scheduler, thread-per-call dispatch, completion signal, join, and optional Recorder with a native mock Host. No model, API key, network service, shell tool, or file-reading tool participates in the workload. Normal nib builds compile the probes out.

## Reproduce

Use Zig 0.17 and Python 3.11+ on a machine with the Zig dependencies already available:

```sh
zig build test-bench-scheduler -Doptimize=ReleaseFast --summary all
python3 tests/test_bench_scheduler.py
python3 scripts/bench_scheduler.py --samples 100 --warmups 10 --output /tmp/nib-scheduler-bench
```

The runner fixes **ReleaseFast** (Zig 0.17 calls the underlying optimization mode `fast`). On Linux it pins itself and its children to the first four allowed logical CPUs; use `--cpus 0,1,2,3` to choose another fixed set from the allowed affinity. On other platforms affinity is not set. Keep other work off the selected CPUs, use the same power/thermal conditions, and retain the generated environment metadata (including observed Linux governors and frequency limits, which the runner does not change). Do not compare different build modes, CPU sets, or filesystems as if they were the same experiment.

Outputs:

- `raw.jsonl`: absolute monotonic nanosecond timestamps for each observed invocation, plus per-Run durations and calibration samples. This is a private benchmark format, **not** the Session log schema.
- `summary.json`: sample count, nearest-rank p50/p95 in microseconds, run conditions, compiler version, source commit and diff hash, raw-data hash, recording filesystem, and recording size.
- A terminal summary with Run times in milliseconds and call stages in microseconds.

The default makes 100 measured Runs **per workload / recording / probe configuration**, after 10 warmups per configuration. All 16 configurations are rotated between rounds to reduce order bias. Warmups are checked for correctness but excluded from statistics. JSON output happens after the Run clock stops. The output file and temporary recording need enough space (roughly 1 GiB for the temporary recording, plus the raw timestamp output, for the defaults); the temporary recording is removed after completion. The initial build is outside the measured Run intervals.

For a smaller smoke run use `--samples 2 --warmups 1`. The underlying executable can also be run with `zig build bench-scheduler -Doptimize=ReleaseFast -- /absolute/new/calls.jsonl 100 10`. Use a new recording path; the Python runner creates one automatically.

## Fixed workloads

The concurrency limit stays **8**. Short mock calls return allocated JSON `1`; no artificial delay is added.

| Workload | Calls per Run | JS consumption |
| --- | ---: | --- |
| serial | 128 short | sequential `await` |
| parallel | 128 short | enqueue together, individual `.then` callbacks |
| mixed | 4 native workers sleeping 20ms, then 124 short | enqueue together, individual `.then` callbacks |
| large | 16 JSON strings, 256 KiB decoded payload each | enqueue together, validate each string length |

The mixed waits deliberately occupy worker slots: they are not `tools.sleep`, whose timer path does not start a worker. Short and waiting calls are summarized separately. The mock uses the real allocator; `tool` therefore includes result allocation and, for large calls, filling the buffer. Large strings have a fixed-width unique prefix per invocation, so the Recorder cannot collapse them as duplicates. Short results are identical and use the Recorder's normal deduplication behavior. There are no test-only counter atomics in the measured mock; the test build alone enables concurrency counters.

Recording off means `Host.record = null`. Recording on uses an actual Recorder shared across Runs, including `begin`, settlement encoding/hashing, `finish`, writes, and `sync` to a temporary local file. No Recorder encoding implementation or default recording policy is changed. Large result delivery and recording are intentionally visible separately.

## What the clocks mean

Every boundary uses `std.Io.Clock.awake` (monotonic, nanosecond representation). Representation precision is not a claim of nanosecond accuracy. Cross-thread boundaries use the same clock, not wall time or thread CPU time.

| Reported metric | Direct boundaries |
| --- | --- |
| `queue` | successful append to scheduler queue → start of dispatch for that invocation |
| `spawn_api` | immediately before `Thread.spawn` → immediately after it returns |
| `dispatch_to_worker` | dispatch → first timestamp inside worker entry |
| `dispatch_to_tool` | dispatch → immediately before Host tool function |
| `tool` | immediately before Host call → immediately after its return |
| `return_to_js` | Host return → native acknowledgement called first in that invocation's JS continuation |
| `return_to_delivery` | Host return → entry to delivery, after ready-queue selection and join |
| `join` | immediately around `thread.join` |
| `record_settle` | immediately around `Recorder.settle`, only with recording on |
| `bridge` | result conversion / QuickJS JSON parse → promise resolve/reject and freeing temporary JS values |
| `resolve_to_js` | bridge end → JS continuation acknowledgement |
| `eval_ns` | immediately around `sandbox.eval`, including QuickJS setup/teardown and all workers draining |
| `record_finish_ns` | directly around optional `Recorder.finish` (including writes and sync); off is an empty bracket |
| `run_ns` | before optional `Recorder.begin` through eval and optional finish, excluding report serialization and Outcome disposal |

`run_ns` is the complete **model-free Run harness** interval, not a Session Turn with model latency, prompt assembly, TUI events, or transcript formatting. The ordinary `RunTiming` collector remains enabled in every configuration, with all calls below its 200-entry cap.

`queue` includes time spent creating the rest of the JS promises and time waiting behind the eight active calls. It is not exclusively contention on a native queue. `return_to_js` includes completion publication/wakeup, waiting behind other results, join, recording when enabled, JSON conversion, call cleanup, and QuickJS promise jobs. The acknowledgement adds one native JS callback at the consumption boundary. It does not pretend that promise settlement is already JS consumption.

**Thread creation API latency and dispatch-to-entry latency are different, overlapping intervals.** A worker can enter or even return before `Thread.spawn` returns. Tests explicitly accept both orders. Dispatch-to-entry includes creation and OS scheduling; it is not an isolated measurement of time spent runnable on the kernel's run queue. Do not add their percentiles, subtract their totals, or describe `dispatch_to_worker` as just thread creation. Similarly, result delivery and dispatch for different calls overlap. The phase metrics are measured from each call's own boundaries, not inferred by subtracting a few aggregate runtimes.

The scheduler's condition signal wakes completion delivery. Its 20ms timeout is only an upper bound for a wait without a signal, not a fixed per-call sleep. The benchmark does not change this mechanism.

## Observer overhead and correctness

Calibration reports 10,000 adjacent clock-read intervals and 10,000 adjacent timestamp-and-store intervals. It also measures 100 complete evals containing 100,000 empty acknowledgement callbacks each, alongside 100 evals containing the matching bare JS loop, with their order alternated. These batch durations include QuickJS setup/teardown, loop execution, and result conversion: they expose the empty callback's cost scale, not an exact per-callback correction. The callback batch uses a null probe; timestamp/store costs are covered separately. None of these measurements is subtracted from phase samples. Probed and unprobed Runs use the same executable, fixture, JS acknowledgement callback, ordinary timing collector, and recording configuration. Their end-to-end distributions show the marginal effect of timestamp/store instrumentation and cross-thread cache traffic. Noise can exceed that difference; do not subtract medians to manufacture exact per-call overhead.

The unprobed configuration still executes an empty acknowledgement callback and nullable probe checks compiled into the **benchmark binary**. It is not a separate production throughput measurement. Normal nib has the probe option hardcoded off, a zero-size `void` Host field, no acknowledgement native installed, and no probe allocations, locks, clock reads, or logging. Benchmark slots are allocated once by the harness, indexed by stable creation index, and read only after eval has joined all workers. Parent and worker write distinct fields.

Correctness checks cover every workload with recording on/off, all expected deliveries, per-call stage ordering, missing/duplicate/out-of-range acknowledgements, both worker/spawn return orders, the eight-call concurrency bound, and separation of long waits from short calls. Every measured and warmup Run also validates stage order, result values/counts, and Recorder status. Python tests cover nearest-rank quantiles, units, grouping, and rejecting incomplete/duplicate/invalid raw data. Production tests verify the acknowledgement native is absent and the probe field occupies zero bytes.

## Results and decision

Results for this experiment are recorded below after running the fixed conditions above. They describe native scheduling and delivery on that machine, not model-backed task speed, and cannot by themselves establish the speedup of a worker pool.
