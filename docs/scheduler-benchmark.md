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

Measured **2026-11-17**, commit `0bf322f33ed4b1c36653fbcd063a0d6f44560df2`, with a clean working tree in both repetitions. Zig 0.17.0, ReleaseFast, Linux 7.0.0-42, Intel Core 5 220H, affinity **0,1,2,3**, concurrency 8. The observed governor was `powersave`, with 400MHz–4.9GHz limits, unchanged across the experiment. Frequency/turbo were not locked, so these are fixed-affinity, not fixed-frequency measurements. One-minute system load was approximately 1.02–1.29; the host was not an isolated real-time environment.

Both repetitions used `/tmp` on **tmpfs**. Recorder writes and `sync` were exercised, but tmpfs does **not** model durable-disk sync latency. To measure that separately, set `TMPDIR` to a local disk directory and retain the same CPU/build/load settings; do not pool the results with tmpfs samples.

Complete statistics, conditions, and raw hashes: [repetition 1](measurements/scheduler-native-2026-11-17-1.json), [repetition 2](measurements/scheduler-native-2026-11-17-2.json). Raw timestamps remain in `/tmp/nib-scheduler-bench-published-{1,2}/raw.jsonl` on the measurement host; the runner regenerates this format. The JSON summaries retain all phases, including dispatch-to-worker, join, settlement recording, bridge, eval, and finish. These results are two same-source repetitions, not different implementations.

### Model-free Run end to end

Probes **off**; **100 Runs per row per repetition**, after 10 warmups. Cells are **p50 / p95, milliseconds**. Recording includes finish/write/sync.

| Workload | Recording | Repetition 1 | Repetition 2 |
| --- | --- | ---: | ---: |
| large | off | 3.846 / 4.697 | 3.810 / 4.498 |
| large | on | 16.612 / 22.711 | 14.582 / 21.912 |
| mixed | off | 20.991 / 21.178 | 20.999 / 21.137 |
| mixed | on | 20.899 / 21.105 | 20.895 / 21.111 |
| parallel | off | 9.619 / 10.739 | 9.280 / 10.782 |
| parallel | on | 9.124 / 10.056 | 8.733 / 9.763 |
| serial | off | 3.721 / 4.851 | 3.662 / 4.526 |
| serial | on | 3.591 / 4.278 | 3.561 / 4.288 |

### Direct per-call boundaries

Probes **on**, repetition 1. Cells are **p50 / p95, microseconds**; `n` is the number of individual calls, not independent Runs. Calls in a Run are correlated. The second repetition's complete per-call distributions are in its JSON summary. Queueing is expected to grow across a batch of 128 calls.

| Workload / kind | Recording | n | Queue | Spawn API | Dispatch → tool | Tool | Return → JS |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| large / large | off | 1600 | 1065.297 / 3049.804 | 72.067 / 137.583 | 76.776 / 144.690 | 68.804 / 129.463 | 1083.546 / 2150.639 |
| large / large | on | 1600 | 1122.122 / 8937.194 | 111.319 / 174.279 | 118.727 / 183.879 | 98.751 / 153.976 | 3551.877 / 6319.388 |
| mixed / short | off | 12400 | 2930.159 / 4987.600 | 47.343 / 65.507 | 50.260 / 69.723 | 0.114 / 0.223 | 91.621 / 134.939 |
| mixed / wait | off | 400 | 332.066 / 460.513 | 58.153 / 91.760 | 70.171 / 115.360 | 20059.492 / 20170.020 | 56.876 / 144.672 |
| mixed / short | on | 12400 | 3069.118 / 5327.293 | 47.859 / 69.795 | 50.780 / 74.009 | 0.120 / 0.246 | 100.398 / 150.220 |
| mixed / wait | on | 400 | 340.595 / 531.967 | 61.314 / 100.479 | 69.179 / 106.722 | 20056.185 / 20104.525 | 52.894 / 151.635 |
| parallel / short | off | 12800 | 4243.846 / 7871.611 | 63.377 / 76.373 | 67.255 / 81.597 | 0.130 / 0.320 | 267.369 / 437.082 |
| parallel / short | on | 12800 | 4348.605 / 8098.638 | 63.804 / 77.144 | 67.845 / 82.528 | 0.134 / 0.323 | 276.706 / 447.416 |
| serial / short | off | 12800 | 0.392 / 0.669 | 14.976 / 19.769 | 18.292 / 23.841 | 0.174 / 0.260 | 4.017 / 5.673 |
| serial / short | on | 12800 | 0.367 / 0.558 | 13.994 / 21.144 | 17.205 / 24.550 | 0.160 / 0.239 | 4.768 / 6.482 |

In recording-off serial calls, dispatch-to-**worker entry** was 18.193 / 23.721µs, versus spawn API 14.976 / 19.769µs. For parallel calls those intervals were 67.189 / 81.524µs and 63.377 / 76.373µs. These are distinct direct observations, not a decomposition of kernel scheduling time. Repetition 2 reproduced the short-call scale: serial spawn p50 14.817µs versus tool 0.178µs; parallel spawn p50 61.906µs versus tool 0.126µs.

For large results with recording on, direct `record_settle` was **472.983 / 634.317µs**, bridge **217.487 / 294.005µs**, and return-to-delivery **2867.445 / 5465.828µs**. Repetition 2 gave settlement **454.419 / 594.387µs** and bridge **208.561 / 274.289µs**. The latter backlog is waiting behind other completions as well as completion signalling/join, not a fixed scheduler sleep. Short serial settlement, by contrast, was **1.062 / 1.676µs**. These direct measurements prevent attributing encoding/hash/bridge work to thread creation.

### Observed measurement overhead

- Adjacent clock reads and local timestamp/store intervals: **10,000 samples each per repetition**. Both p50/p95 were **14 / 15ns** in repetition 1 and **16 / 17ns** in repetition 2. This is a local calibration, not a measurement of cross-thread cache effects.
- Empty acknowledgement batches, **100 eval samples of 100,000 callbacks each**: **4.759 / 5.045ms**; matching bare loops **2.160 / 2.293ms**. Repetition 2: **4.939 / 5.201ms** and **2.222 / 2.393ms**. These are complete batch eval durations, not exact callback latency obtained by subtraction.
- Probe-on/off Run distributions are retained for every configuration. For example, repetition 1 recording-off serial was **3.582 / 4.465ms on** versus **3.721 / 4.851ms off**; parallel **9.003 / 9.825ms on** versus **9.619 / 10.739ms off**. The apparent negative cost demonstrates that order/frequency/scheduling noise is larger than any reliably isolated marginal probe cost here, not that instrumentation is free or makes scheduling faster.
- Large recording-off Runs showed a material observer sensitivity: **4.823 / 7.013ms on** versus **3.846 / 4.697ms off** in repetition 1, and **4.326 / 7.663ms on** versus **3.810 / 4.498ms off** in repetition 2. Do not use probed end-to-end times as production throughput, call all observer overhead negligible from the clock calibration, or interpret small differences as optimization wins. A worker-reuse comparison must retain probe-off controls and repeat both arms.

### Decision: worth experimenting with worker reuse for short calls

**Proceed only to a separate, opt-in worker-reuse experiment; do not change the production default in this phase.** Both repetitions show startup/dispatch and completion handling on a much larger scale than the sub-microsecond short mock function. Short-call settlement/bridge are directly observed to be much smaller than startup, so recording is not a sufficient explanation for this short-call result. Reuse is a plausible target worth measuring, not an established speedup: this experiment has no pool arm and cannot predict its queue, wakeup, or contention costs.

Scope the next experiment to the same eight-worker bound and unchanged result/recording semantics. Require probe-off end-to-end improvements reproduced in both serial and concurrent short workloads, no starvation of short work in the mixed workload, no correctness/cancellation/drain regression, and no material p95 regression for large results. Keep a pool experimental until that comparison succeeds. No pool implementation is included here.

**Do not generalize this decision to large results or long waits.** Large-result recording/bridging and delivery backlog are substantial, and a worker pool would not remove JSON parsing, encoding, hashing, or durable recording cost. Mixed Run p50 remains around 21ms because four actual 20ms waits dominate; that does not imply a 20ms per-call scheduler tax. These native mocks do not establish the effect on model-backed coding tasks.

### Validation

- ReleaseFast benchmark correctness: **3/3 tests**; statistics/raw-data checks: **3/3 tests**.
- Production ReleaseFast unit suite: **708/708 tests**; `zig build -Doptimize=ReleaseFast` succeeded.
- Related local-mock e2e: replay **23/23**, background Run **27/27**.
- Zig formatting and `git diff --check` passed. CI runs production tests plus the benchmark correctness tests on Linux/macOS; performance numbers are not CI thresholds.
