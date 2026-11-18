# Tool recording and offline Run replay

nib replay reruns saved JavaScript in fresh QuickJS sandboxes, substituting recorded tool returns for real tools. Inspect control flow, result handling, formatting, and first call divergence. No provider/model requests or real read/grep/bash/fetch/write/llm/agent execution.

## Usage

```sh
# Record tool arguments/results before replaying (local logs may contain secrets)
NIB_RECORD=on nib ask 'inspect the project'

# ID is the full 32-character lowercase hexadecimal Session ID
nib replay <session_id> --run 1:0
nib replay <session_id> --run 1:0 --json
nib replay <session_id> --all --json
nib replay <session_id> --run 1:0 --script diagnose.js --json
```

`--run <step>:<run>` uses different bases:

- step: **1-based assistant Step ordinal** across the Session, including Run-free final answers and continuing across Turns/resume. Not per-Turn `turn_step` or JSONL line number. Retained messages rewritten by compaction/repair are not new Steps.
- run: **0-based `tool_calls` array index** in that assistant message, not a tool-call index within the Run.

Example: first assistant Step has Runs `1:0` and `1:1`; next Step is a final answer; the first Run in a resumed new Turn is 3:0.

Choose --run or --all; --script requires --run. Replay uses only `NIB_HOME` to locate logs, without keys/available providers. Defaults: [config.md](config.md).

### Strict replay

Without --script, execute original main-log Run code. Match calls in creation order by index, tool name, structural JSON args (object order irrelevant, array order significant). Settle Promises in recorded seq order to reproduce observed concurrency ordering, not wall time. Record the first mismatch as divergence; never try real tools.

`tools.sleep(ms)` also records normal arguments/results/rejections. Replay returns recordings without timers/waits or advancing fixed `Date.now()`; bound polling by count rather than wall deadlines alone.

Format with normal Run rules and compare byte-for-byte against the Run’s own output in the main log, excluding any folded Inbox text. Background Runs use their final committed completion, not the original registration notice. Matching calls with different final output also diverge; match means more than identical arguments.

### Diagnostic scripts

`--script diagnose.js` replaces original code, still offline. Look up results by **tool name + JSON args**, reusable without original order or consumption. Repeated identical args use the first entry; script mode does not reconstruct original races.

Misses reject with not recorded; `try/catch` may inspect them, without real file/command/network fallback. Example:

```js
const first = await tools.read({path: "sample.txt"});
console.log(first.text);
try {
  await tools.read({path: "not-in-this-recording.txt"});
} catch (e) {
  console.log(e.message);
}
```

Script mode changes the program, so output equivalence is not judged; match is null.

## Files and format

Recording defaults **off**. Set `NIB_RECORD=on` when executing the original Session to enable tool argument/result sidecars; `NIB_RECORD=off` disables them. For compatibility, other explicitly set values (even empty, `0`, `false`, or `OFF`) retain their old enabling behavior; use `on`/`off`. No TOML key or CLI recording flag. New, forked, and resumed child agents inherit the current process environment and write separate calls files. Resume/continue uses the current environment, not the original Session's setting or the presence of an old sidecar.

When recording is disabled, normal execution does not create, read, restore, truncate, or delete sidecars, and skips recording hashes, encoding, and sync. Main logs, resume, background state, and timing/byte-count/product-analysis metrics continue unchanged. `nib replay` itself still reads existing recordings with `NIB_RECORD` unset or off.

**Unrecorded tool returns cannot be fully replayed after the fact.** Set `NIB_RECORD=on` before the Runs you need to replay; turning it on during resume records only subsequent Runs. The main log's model-visible output is not a substitute for actual tool returns.

A main log per Session, plus an independent sidecar only when recording is enabled:

```text
$NIB_HOME/sessions/<session_id>.jsonl        Main log: messages, code, model-visible Run output
$NIB_HOME/sessions/<session_id>.calls.jsonl  Sidecar: calls/actual returns, created mode 0600
```

Append JSONL per Run, flushing/syncing at Run end. Main logs commit only complete Steps; crashes in later Runs of a Step may leave sidecars ahead. When recording is enabled, the first recording after resume truncates from the first sidecar line with step >= new Step determined by main log, rebuilding dedup only from retained data. Later Runs in the same Recorder do not rescan, preserving earlier uncommitted Runs from this execution. Even tool-free Runs save metadata for pure-JS/time-dependent positioning. Recording failures warn/disable further recording, never fail tools/Sessions. Old logs without sidecars remain resumable but cannot invent recordings.

Every line carries step/run. Each Run writes zero or more call rows, then **one final metadata row**; no type field or separate start/end rows.

| Row | Fields | Meaning |
| --- | --- | --- |
| Call | step, run, index, seq, name, args, ok, result / error | Actual result/rejection, optionally sha256/truncated |
| Metadata | step, run, `meta: {start_ms_epoch, end, incomplete?}` | Run-start Unix ms and termination: ok/error/timeout/cancelled; incomplete: true only for created tools not delivered to JS |

index is 0-based Promise creation order; seq is 0-based observed settlement order, potentially different under concurrency. args is a JSON value, not string. First `ok=true` result is **raw serialized tool-return JSON text as a string**; duplicates use `{"same_as":"<sha256>"}` inside result, not top-level. `ok=false` error remains rejection text, **never deduplicated**. Replay restores JS values/rejected Promises.

```json
{"step":1,"run":0,"index":0,"seq":0,"name":"read","args":{"path":"a.txt"},"ok":true,"result":"{\"text\":\"hello\"}","sha256":"<sha256>","truncated":false}
{"step":1,"run":0,"index":1,"seq":1,"name":"read","args":{"path":"a.txt"},"ok":true,"result":{"same_as":"<sha256>"},"sha256":"<sha256>","truncated":false}
{"step":1,"run":0,"index":2,"seq":2,"name":"bash","args":{},"ok":false,"error":"denied","sha256":"<error-sha256>","truncated":false}
{"step":1,"run":0,"meta":{"start_ms_epoch":1700000000123,"end":"ok"}}
{"step":1,"run":1,"meta":{"start_ms_epoch":1700000000456,"end":"ok"}}
```

Deduplicate full raw JSON text SHA-256 within Sessions across Runs/resume. Resume reconstructs hashes from call-row sha256, excluding rejects. References target only earlier results. Internal loading separates result strings/same_as references so replay core is disk-format-independent.

First results and each error retain at most **1 MiB (1,048,576 bytes)**, UTF-8-boundary truncated with truncated=true. sha256 hashes full originals, not prefixes. Errors also truncate to bound disk but retain text even if repeated. Truncated results may be invalid JSON; replay returns such prefixes as JS strings. References inherit truncation.

1 MiB bounds retained raw text, not encoded JSONL line size; escaping may enlarge lines. Args stay complete without a separate cap. No whole-Run/Session cap or rotation yet. In-memory accumulation until synchronous Run-end writes means many calls still increase memory/disk.

Record only at shared settlement delivery, not worker-completed results undelivered to JS. At eval exit compare created/delivered totals; mismatch adds meta.incomplete: true even if only the highest index is missing without holes. Cancellation/JS timeout can leave calls undelivered. Ordinary errors do not stop siblings: `Promise.all` read rejection still waits for bash, and direct throw after tool creation still drains, so those error recordings remain complete/matchable. Missing entries yield incomplete=true/match=null; preserve discovered divergence diagnostically without treating it as conclusive.

Load calls before final meta fills Run metadata. Missing meta/references or truncated entries mark `incomplete=true`; absent metadata does not imply time (internal placeholder 0) or complete matches. --all traverses recorded Runs, including metadata-only Runs; total excludes unrecorded Runs (unset or `NIB_RECORD=off`), rather than counting all main-log Runs. Recording limits affect neither original JS data nor model budgets; [run-output.md](run-output.md).

## JSON reports

--run ... --json emits one object, not ask NDJSON:

```json
{"run":"1:0","match":true,"incomplete":false,"uses_time":false,"uses_random":false,"output":"...","end":"ok"}
```

| Field | Meaning |
| --- | --- |
| run | `step:run` locator |
| match | true: complete equal replay; false: conclusive divergence; null: undetermined/script mode |
| divergence | Optional first call/settlement/output mismatch; call mismatches include index, expected name/args, actual name/args; too few calls show first unused record and actual no call, excess calls expected no call |
| incomplete | Recording/settlement incomplete; replay is not complete evidence |
| `uses_time` / `uses_random` | Whether replay accessed substituted time/random APIs |
| output | Normally formatted Run output including captured console |
| end | Optional original termination reason |

Absent optional fields may serialize null. --all --json summarizes total/matched/divergences/undetermined, per-Run reports, differences: [{run, divergence}]. divergences remains a conclusive-divergence count; differences lists detected call/output mismatches, including incomplete-recording call mismatches without claiming conclusive matches. Undetermined entries are separate, not matched; absent metadata/source/tool results cannot become empty-value successes.

Plain single-Run output shows match/diff/undetermined, optionally incomplete; original timeout/cancelled explicitly show end=timeout/end=cancelled. Plain --all lists divergences/abnormal endings after totals.

### Time and randomness

`Date.now()` and no-argument `new Date()` freeze at `start_ms_epoch`; repeated accesses agree. `Math.random()` uses deterministic substitution. Access marks uses_time/uses_random to explain differences. These are not original per-access values; programs depending on advancing time, original randomness, or scheduling may not match. Timeout/cancellation/incomplete recordings do not prove reproduced execution.

Replay uses normal default sandbox limits, including 5-minute JS budgets. Original cancellation signals/tool durations are not replayed, so interruption positions may differ; successful replay still leaves originally incomplete recordings incomplete with match=null.

## Privacy and capability boundaries

- Default recording adds disk copies of **actual tool returns**, potentially code/full files/bash output/URLs/personal data/credentials hidden by model truncation. 0600 restricts other local users, not encryption or current-user/backup/tool reads.
- Sidecars do not automatically enter provider requests/resume history/reflection. Reflection permits only the specified main log, no sessions enumeration or calls/sibling/child logs. Session lists/stats skip calls too; public issues retain redaction. These are prompt/dataflow boundaries, not malicious-model filesystem isolation.
- Disabling does not delete recordings. Inspect main/sidecar files separately before sharing/backup/cleanup; redacted main logs do not imply redacted sidecars. Never upload `.calls.jsonl` to public issues.
- Replay **cannot replay models**, restore reasoning, or test another model’s decisions: saved Runs are not reproducible provider requests.
- Replay **cannot validate tool implementations** or external correctness; returns are inputs, without rereading files/network/bash.
- Replay **cannot reproduce bash side effects** or edit/write projects. Matches prove equal JS output under recorded data/replay semantics, not equal real-world state.
- Background agent/bash record only startup {id} returned to JS; later inserted messages bypass Runs/calls and live in main logs.

Local mocks, fixed time, first argument divergence, `/reflect` marker privacy regressions: after zig build, run python3 tests/test_replay.py.

Automatic background recordings retain original global Step/Run ids; Run blocks may append out of Step order by completion. Within-Run index/seq/shared settlement remain unchanged. Resume removes all uncommitted-Step recordings while preserving interleaved committed earlier Steps; cross-Run dedup never references later Steps. Replay does not wait thresholds/start tasks; compare final full-script output with committed background_run.output, never early notifications when final results are undelivered. Canceled/lost incomplete recordings retain existing incomplete/stopped semantics.

Footer `meta.run_output_bytes` saves Run budgets; offline replay uses them, defaulting old recordings to 16384. Formatting only, not recorded-data truncation. New diagnostics may alter old error-Run displays; source/tool recordings remain replayable offline.
