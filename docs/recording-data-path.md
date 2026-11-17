# Tool-result recording: ownership and direct encoding

## Scope

This investigation compares baseline `091b9a1` with direct JSONL encoding in
`src/sandbox/record.zig`. Recording configuration, environment-variable parsing,
wire format, persistence and replay policy are unchanged. There is no allocator
replacement, buffer pool, scheduler change or QuickJS bridge change.

## Ownership

- `Host.call` returns allocator-owned `ToolResult` bytes. Worker threads publish
  them in scheduler `Call.result`; the eval thread records and delivers them.
  `Recorder.capture` only borrows those bytes for the duration of the call.
- Arguments parsed for recording have their own temporary parsed-JSON arena.
  Hashes cover the entire original result. Only the recorded string is bounded
  to 1 MiB at a UTF-8 boundary. Successful repeats use the existing hash
  reference; errors retain their text. The original tool result is not shortened.
- The Recorder owns its JSONL buffer and hash map. `line` temporarily transfers
  the buffer to `Writer.Allocating`, then transfers it back on every exit.
  Encoding owns no references to the arguments or native result after returning.
  On failure the writer's end rolls back to the original length before ownership
  returns, including failures after relocation and while appending the newline.
  Capacity can grow on failure, but no partial line becomes part of the buffer.
- `capture` still disables recording and warns through the existing `fail` path;
  child failure also disables the parent. Failed recording does not reject the
  tool Promise. `seq` advances only after a complete line. `finish` still handles
  recording I/O failures without turning them into tool failures. This change
  does not add transactional disk writes or change behavior after partial OS I/O.
- Delivery to QuickJS still duplicates a successful JSON result with a NUL
  sentinel before `JS_ParseJSON`. The duplicate is freed immediately after
  parsing. QuickJS owns the resulting objects/strings; `Call.deinit` frees the
  original native result and Promise resolver references after settlement.
  Error and virtual-string results use the existing QuickJS constructors.
- On eval error, cancellation or allocation failure, scheduler teardown requests
  cancellation, joins tool workers, then destroys pending Calls before freeing
  the JS context/runtime. Already delivered Calls are removed from its array.
  The bridge's sentinel allocation can fail with a Call still pending; teardown
  still owns and frees that Call and result. This is not a normal-path leak.
- `Outcome` owns native completion text, console capture and associated metadata;
  it does not retain the native tool result or QuickJS heap. Foreground Run
  execution transfers Outcome to its caller, which frees it after formatting.
  `Job.destroy` joins and calls the existing `releaseExecution` for everything
  still owned by the Job, including its input arena, Recorder, images and changes.
- For background Runs, `Job.completion` formats output into a scratch arena;
  timing-call details can still borrow the Job input arena. Inbox enqueue clones
  the completion into an inbox-owned arena before `releaseExecution`. Scratch
  storage then expires; inbox batches own the copies until consumption/teardown.
  Completion/enqueue errors do not create dangling borrowed values: the Job
  retains its resources until retry or background/session teardown. A completion
  error marked collected can retain execution storage until that teardown; this
  is bounded by Job ownership, not evidence of an unowned allocation.

### Proven error-path fix

Foreground `executeTimed` previously cleared `job.outcome` before the fallible
image handoff. If image cloning ran out of memory, the function returned an
error, neither returned the Outcome nor left it owned by Job, and `Job.destroy`
could no longer free it. `takeJobResult` now completes the image handoff before
moving Outcome. Its regression test injects OOM at image handoff and verifies
that the original Outcome remains Job-owned. No normal completion cleanup was
replaced. RSS retention alone was not used to diagnose a leak.

## Validation

Recorder tests compare exact serialized bytes with the previous encoder, inject
allocation failures at every allocation in a growing escaped line, test an
encoder failure after growth and an allocation failure specifically at the
newline, and verify child/parent disable behavior. Existing tests cover full
hashes, UTF-8 truncation, deduplication across restore and concurrent Run ordering.
A sandbox regression verifies that recording OOM still delivers a complete large
Unicode result to JS. A replay e2e reads and writes an oversized result, verifies
the complete file round-trip, checks the recorded hash/bound/reference, and
checks that replay remains incomplete rather than performing real writes.

## Reproducing measurements

Use the same Zig 0.17 toolchain, ReleaseFast optimization and machine for both
versions. `scripts/bench-record.zig` measures only `Recorder.capture`, not JS,
disk flushes or provider calls. It uses the process allocator wrapped by
`FailingAllocator` solely for counters; production allocators are unchanged.
Both cold buffers/maps (representative of a new Run) and warm retained capacity
are measured. The first batch is excluded; subsequent batches either free that
capacity before timing (`cold: true`) or retain it. The per-batch hash set is
cleared to exercise either unique results or one full result followed by
duplicates. The payload sizes are raw tool-result bytes. Allocation counts
and gross allocated bytes include argument parsing and deduplication, not just
encoding. Successful resize/remap counts are reported separately.

```sh
mkdir -p /tmp/nib-record-bench
git show 091b9a1:src/sandbox/record.zig > /tmp/nib-record-bench/record-before.zig
zig build-exe -O ReleaseFast --dep record -Mroot=scripts/bench-record.zig \
  -Mrecord=/tmp/nib-record-bench/record-before.zig \
  -femit-bin=/tmp/nib-record-bench/bench-before
zig build-exe -O ReleaseFast --dep record -Mroot=scripts/bench-record.zig \
  -Mrecord=src/sandbox/record.zig -femit-bin=/tmp/nib-record-bench/bench-after
/tmp/nib-record-bench/bench-before
/tmp/nib-record-bench/bench-after
```

The end-to-end harness accepts separately saved `zig build -Doptimize=ReleaseFast`
binaries for baseline and candidate. It uses local mock HTTP, isolated temporary
homes, full JS length checks, and asserts identical recordings except for the
start timestamp. It includes process startup, file reads, QuickJS, hashing,
recording flush/sync, session logs and mock-provider round trips. Each binary
has its own temporary home and mock server. The first session warms up; seven
subsequent sessions supply the timing samples, alternating binary order.

```sh
python3 scripts/bench-record.py /path/to/nib-before /path/to/nib-after
```

The removed explicit copy is exactly the encoded JSON byte count (recorded bytes
minus one newline per capture). This excludes any allocator-internal relocation,
argument parsing, JSON escaping, hash input reads and the unchanged sentinel
copy. It is a source-level byte count verified against equal recorded lengths
and buffer SHA-256, not a claim to measure all memory traffic.

Local validation passed: `zig build -Doptimize=ReleaseFast`,
`zig build test --summary all` (714 tests), `python3 tests/test_replay.py`
(24 tests), `python3 tests/test_sandbox.py` (11 tests), and
`python3 tests/test_background_run.py` (27 tests). `zig fmt`, Python bytecode
compilation and `git diff --check` also passed.

## Measured results

Machine: Intel Core 5 220H, Linux x86_64; Zig 0.17.0, ReleaseFast native for both
versions. Seven trials alternated baseline/candidate order, without concurrent
builds/tests. Raw samples, exact counters and binary SHA-256 are in
[recording-data-path-results.json](recording-data-path-results.json). All buffer
lengths and SHA-256 matched between versions; the allocation counters were
identical across all seven trials.

### Capture only, recording enabled

Each 128 B trial contains 128,000 captures (2,000 batches of 64); each 1 MiB
trial contains 240 captures (30 batches of 8). Duplicates mean one full result
per batch followed by hash references. Times below are median total milliseconds,
not per-call latency. Gross allocated bytes are allocation traffic, not peak
live memory or RSS. Cold measurements exclude freeing the previous batch but
include allocating/growing the next Run's buffer/map.

| Result | Repeats | Buffer | Baseline ms | Direct ms | Change |
| --- | --- | --- | ---: | ---: | ---: |
| 128 B | Unique | Cold | 131.750 | 113.552 | -13.8% |
| 128 B | Duplicated | Cold | 125.458 | 108.037 | -13.9% |
| 1 MiB | Unique | Cold | 437.756 | 351.688 | -19.7% |
| 1 MiB | Duplicated | Cold | 189.741 | 182.148 | -4.0% |
| 128 B | Unique | Warm | 124.627 | 108.797 | -12.7% |
| 128 B | Duplicated | Warm | 125.334 | 106.762 | -14.8% |
| 1 MiB | Unique | Warm | 376.314 | 303.595 | -19.3% |
| 1 MiB | Duplicated | Warm | 187.890 | 174.697 | -7.0% |

Cold-buffer allocation traffic for the same trials:

| Result | Repeats | Allocations, before → after | Gross bytes, before → after | Removed explicit copy bytes |
| --- | --- | ---: | ---: | ---: |
| 128 B | Unique | 790,000 → 538,000 | 417,260,000 → 331,946,000 | 41,176,000 |
| 128 B | Duplicated | 908,000 → 656,000 | 411,046,000 → 327,868,000 | 34,624,000 |
| 1 MiB | Unique | 1,530 → 1,080 | 708,382,830 → 377,992,770 | 251,704,320 |
| 1 MiB | Duplicated | 1,710 → 1,260 | 94,959,930 → 47,652,960 | 31,519,320 |

The removed append-copy byte count is the same for warm buffers. Warm buffers
avoid allocating the recording capacity during timing, so the large unique
case's gross allocation traffic drops from 377,985,840 to 401,520 bytes. That
number does **not** mean a fresh Run allocates only 401,520 bytes; use the cold
row for fresh Runs. Argument parsing and duplicate-reference allocation remain.

### End to end

Seven alternating samples per binary/case, after one warmup each. These sessions
use 64 reads of 128 B or 8 reads of 1 MiB. Native read-result JSON adds its own
fields; a 1 MiB file therefore exercises the recording-only truncation boundary
while the JS length assertion still sees the whole file.

| File / calls | Recording | Baseline median ms | Direct median ms |
| --- | --- | ---: | ---: |
| 128 B / 64 | Enabled | 12.409 | 11.962 |
| 1 MiB / 8 | Enabled | 52.272 | 51.082 |
| 128 B / 64 | Disabled | 11.077 | 11.507 |
| 1 MiB / 8 | Disabled | 30.163 | 29.145 |

The end-to-end timing differences are small relative to sample variation; they
are not evidence of a general user-visible speedup. Preliminary sequential runs
even reversed the large-result direction, motivating alternating order. The
reliable benefit is reduced allocation/copy traffic with a small local change.
With recording disabled, every cold/warm, small/large, unique/duplicate
microbenchmark reports zero allocations, allocated bytes and resize/remap calls
in both versions. The existing early return remains before parsing or hashing;
there is no new production work on that path. Sub-millisecond disabled
microbenchmark timings and small e2e differences should not be interpreted as
meaningful speed changes.
