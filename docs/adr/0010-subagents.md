---
status: accepted
date: 2026-11-01
---

# Subagents: tools.agent spawns an independent nib subprocess

Runs may call await tools.agent({ prompt, resume, timeout_ms: 1800000, model, effort, background: false }). Optional string resume is omitted to create a child, or uses a current-parent agent task id such as a1; timeout_ms defaults to 30 minutes. Only creation allocates an id; continuation retains it. Each call starts an independent nib subprocess for one complete Turn. Foreground success returns `{ ok: true, id, text, usage, changes }`, child failure `{ ok: false, id, error, text, usage, changes }`, with the original task id on continuation. Only argument errors/user cancellation reject; child failures do not cancel sibling tasks in the Run. Omitted model/effort inherit the parent's current effective configuration, including on continuation, without retaining previous child overrides. Overrides affect this call only, never switch provider, and use existing effort validation/mapping as tools.llm does. Continuation preserves provider consistency and only replays encrypted or signed data from the selected model. Parent/child communicate through nib ask --json NDJSON. New children do not inherit parent history; continuation retains child history/original system. Background registration returns { id }; completion carries that id without usage. Foreground results, background start/completion, progress, and TUI tree retain a1 when continuing it. Results, errors, and background messages never expose internal child-Session IDs to models; see [tool-delegation.md](../tool-delegation.md).

**Continuation and exclusion:** Parent logs persist task-id/internal-child-id mappings. resume resolves an existing current-parent agent mapping and starts nib ask --resume `<internal-child-Session-ID>` in a new process, without persistent workers. Missing tasks, foreign agents (including non-agent tasks), or absent mappings return `ok:false`, without rejection/background registration; internal child IDs cannot resume tasks directly. Only children whose logged `parent_session_id` equals the current parent id may continue. Parent resume reconstructs mappings, allowing original children to continue; root Sessions/other parents' children return ok:false. Reserve the target before waiting for concurrency slots; one in-flight call per agent includes queued, foreground, and background calls. Busy immediately returns `ok:false` without queuing, background registration, or new ids. Foreground/background share reservations, released on completion/failure/cancellation. Exclusive log locks additionally prevent concurrent cross-process/CLI resume. Failure/timeout/cancellation preserve existing mappings; recoverable logs remain resumable. Creation failing before obtaining an internal child id has no mapping. usage/changes cover only this invocation, excluding prior history. Stopping does not roll back files; pre-interruption changes may be incompletely logged/reported.

**Why:** Parallel delegation, e.g. `Promise.all(tasks.map(t => tools.agent({ prompt: t })))`, is a major code-driven benefit. Subprocesses match [0005](0005-process-per-session.md): failure isolation, memory reclaimed on exit, process-group cancellation, millisecond Zig startup. Final-result returns avoid persistent-agent/message concepts and fit await/Promise.all naturally.

**Implementation:** Depth limit 1, passed via `NIB_AGENT_DEPTH`; the table generates descriptions and JS APIs by depth, hiding agent entirely in children. At most 4 concurrent children, excess queued (8 total tool slots). Start the current executable as nib ask --json -, sending prompt/effective provider configuration through stdin JSON. Children skip configuration-file reads, avoiding drift, command-line limits, and secret environment inheritance ([0011](0011-provider-wire-protocols.md)). Reuse `src/tools/process.zig` groups, 20 ms polling, timeouts, and reaping; stdin writes also obey cancellation/timeouts.

**Implementation adjustments:**
- Nested groups are not killed automatically with outer groups. Send SIGTERM to child nib's group so it cancels its tool groups, then SIGKILL after 500 ms; blocked HTTP children remain reapable.
- Add cumulative usage events beside start/end/error; errors also carry usage/steps. Parents retain reported usage when children are killed during network waits, without guessing unreported server tokens.
- Child headers record parent_session_id. Ordinary --continue skips children to avoid resuming delegation accidentally; explicit child resume retains depth limits.

Collect NDJSON line by line, returning received text/usage and all this call's Run changes. Sum added/removed by path, OR created, omit diff; edit/write only, excluding bash, not net start/end diffs. Shared executor output limit: 8 MiB. Independent child timeout_ms defaults to 30 minutes from process execution, excluding slot queues; waiting consumes no Run JS budget ([0009](0009-concurrent-tools.md)). Parent Turns aggregate child reported usage for success/failure/before cancellation, shared by CLI/TUI. Parent/child share cwd/filesystem, not parent history. File tools coordinate independent processes/children through canonical-path advisory locks under shared NIB_HOME; bash does not participate. See [run-output.md](../run-output.md#file-replacement-session-versions-and-cross-process-coordination).

**Timeout diagnostics and task boundaries (2026-11-02):** Real tasks hit the old 5-minute limit, leaving partial files; a unified total limit killed valid work and obscured causes. Use configurable per-delegation limits, default 30 minutes, retaining SIGTERM → 500 ms grace → SIGKILL. Parent mappings/start events retain internal child ids; model-facing timeout errors show actual time including grace, configured limit, task id, and possible incomplete files, without internal ids. Creation stopped before start/internal-id receipt has no resumable mapping. Incomplete NDJSON tails after forced kill do not replace timeout diagnostics; complete usage already received still aggregates.

ask records signals: SIGTERM logs `[interrupted: process terminated]`; SIGINT/TUI Esc retain [interrupted by user], avoiding mislabeling parent stops as user cancellations. Children cannot see sibling history and lack cross-file coordination; dependent edits may be incompatible. Stopping does not roll back files, and longer defaults do not guarantee completion.

Measured that day with mocks: explicit 1600 ms delegation timeout covers active-bash cleanup, partial-file warnings, actual duration/id, forced kill of blocked HTTP, and retained usage. Distinct SIGINT/SIGTERM stream-interruption markers and resume passed. The default 30-minute wait was not actually exercised.

**Rejected alternatives:**
- In-process threads save TLS handshakes/share connections but require thread safety and let child crashes kill parents.
- Persistent children plus messages (prime-agent `rlm.spawn` + `agent_message`; primary local `pa-core/src/prompts/layers/core.md`) are stronger but add handles, routing, lifecycle.

**Dependencies:** [0009](0009-concurrent-tools.md) concurrency; nib ask --json.

**Confidence:** Measured locally (2026-11-01, Debug, `tests/test_session.py` + `mock_llm.py`): two children with `sleep 0.3` spanned 552.7 ms between first/second requests versus 1104.6 ms summed work; parent input 6600 → 19800, output 30 → 90. Six children ran in two batches, at most 4. Depth filtering, results, log association, failed usage, canceling active bash, blocked-HTTP forced-kill usage, and resume passed. Debug/ReleaseFast passed 53 unit tests and Session e2e.

Startup to start event (10 runs, including log sync, excluding model/TLS): Debug median 11.82 ms, range 8.82–19.83; ReleaseFast median 1.30 ms, range 0.85–1.48. Measurement used the same current executable, stdin, and depth environment. Locks/depth/cancellation are not system isolation; parent SIGKILL prevents cleanup. Real HTTPS handshake costs remain unmeasured; local HTTP is not real model latency.

**Real API verification (2026-11-01, `deepseek-flash`, ReleaseFast):** Task: delegate two parallel agents to summarize src/js.zig concurrency and src/tools.zig's tool table, then combine into a paragraph.
- The model independently wrote `Promise.all` over two tools.agent calls in one script, returning structured results; parent used 2 Steps.
- Whole-Turn input 46,283 tokens (25,216 cached, about 54%), output 2,472. Child inputs 19,607 + 21,349, about 89%, mainly reading 18–28 KB sources and repeatedly carrying them across Steps. Under 1 US cent at flash prices.
- Code spot checks confirmed 20 ms waits, root_only/makeApi(depth) filtering, 16 KB truncation, and the then-5-minute timeout (now replaced above). One error mischaracterized “still awaiting something that can never settle” as a validation-in-progress error; the parent missed it. Useful results are not infallible.
- Observed gap: nib ask showed no child progress (start/end, Steps, tokens), leaving users uninformed during long work.

**When to reconsider:**
- Real tasks require mid-task parent/child communication: consider persistent agents/messages;
- Measured startup plus handshake overhead becomes material: consider in-process execution or connection reuse.
