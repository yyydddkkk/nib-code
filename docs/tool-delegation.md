# tools.llm and tools.agent: calls and implementation

TUI `/undo` snapshots follow actual edit/write paths. Parent Turns/children share directories through internal stdin `undo_dir`; new/fork/resumed/background children inherit the current parent Turn directory. This does not aggregate through `run_end.changes` or alter its accounting. Completed writes remain undoable after failure/cancellation. [undo.md](undo.md).

Direct read is cheapest for a few files, with no model call. llm fits bulk single-step judgment/classification/extraction, usually seconds; prefer cheap models/low effort for simple batches, strong models for few hard items. Main loop edits/builds/tests/reviews serially by default. Unless users request delegation, agents serve independent read-only investigations with discardable results that overlap useful main-loop work. Foreground waiting is serial; background work with nothing useful left also extends critical paths. New children reread code, fork inherits parent context, resume keeps child history, neither replacing read/llm. Interfaces still allow user-requested implementation delegation without runtime bans or changed inheritance defaults.

Local `nib-bench/runs/smoke-20261104` parent logs illustrate: timers delegated read-only investigation at Step 1, docs at Step 3, then resumed busy a1 three times (AgentBusy), delegated core scheduler a3 at Step 11, successfully resumed a1 for review at Step 17. Seven calls meant 3 creations, 1 valid continuation, 3 busy returns, not 7 children; parents later slept extensively for implementation/tests. console-tail delegated core capture at Step 1, tried asking about unsettled APIs at Step 4 and urging completion at Step 29, both busy; one child while parent repeatedly slept/read diffs/build logs. Both implementations lay on critical paths. Original prompts stated creation/fork costs without criteria for avoiding delegation; global AGENTS.md already restricted it. Infer only from calls/waits, not internal model motives. Resume starts new Turns after completion, never messages active agents; after busy, wait for results without repeated resume/replacement implementations.

Background bash/agent/Run results deliver automatically. Do not sleep/poll files waiting for them; without independent work reply briefly without tools, letting Session wait on inbox. Bounded sleep is valid for detached service readiness, different from task completion. Sleep never rejects/changes merely because tasks exist, preserving legitimate waits/recording/replay.

Cost reference: all 105 local `~/.nib/sessions` children at analysis time (0.2.0 era, mostly gpt-6.1-sol/high with some overrides and missing old metadata), replacing only 6 [#37](https://github.com/yyydddkkk/nib-code/issues/37) samples. Command:

```sh
python3 scripts/stats.py ~/.nib/sessions --json
```

Per-child `child_costs` measurements (nearest-rank p90):

| Metric | Median | p90 | Valid children |
| --- | ---: | ---: | ---: |
| Complete Steps | 12 | 24 | 105 |
| Cumulative model time | 179,088 ms (about 3 minutes) | 406,863 ms (about 7 minutes) | 87 |
| Prompt tokens including cache | 299,991 (about 300k) | 825,096 (about 830k) | 101 |
| Uncached prompt tokens | 43,350 (about 43k) | 75,479 (about 75k) | 101 |

Input sums requests including repeated context; uncached subtracts prompt_cache_hit_tokens from `prompt_tokens` per Step, then sums per child. Show both: uncached usually drives cost/latency, but cached input is not free and total tokens are not fees. Model time excludes tools and is not end-to-end wall time; measured p90 is about 7 minutes, replacing initial 9-minute estimates. No zero-fill; metrics use independent valid samples, so never subtract their quantiles. Failed/canceled logs give recorded-cost lower bounds.

Initial roughly 6 read-only Steps consumed about 22% of these 105 new-child durations; complete tasks about 12 Steps/3 minutes/290k cumulative prompt tokens. Fork aims to reduce rereading, not a measured savings rate; longer inherited history/caching needs comparison.

### `child_costs` groups and valid samples

Each selected child log with `parent_session_id` is one `child_costs` sample, foreground/background; resume stays in that log rather than splitting by invocation. `by_creation` uses child header creation metadata:

| Group | Definition |
| --- | --- |
| fork | `forked_from` object with nonempty session string and nonnegative integer `message_count` |
| new | No `forked_from`, including old logs |
| unknown | Explicit `forked_from` with invalid structure/values |

Emit observed groups only; unknown/missing old metadata are not verified fork comparisons. child_costs.by_parent_system groups experiments by parent `system_sha`, with identical `by_creation` within each. Join `parent_session_id` to input parent logs; absent/invalid parents mean unknown, without child-system fallback.

Global, parent-system, and fork/new/unknown groups contain these independent { samples, median, p90 } distributions, e.g. `child_costs.by_creation.fork.first_request_cache_hit_rate.samples`:

| JSON metric | Per-child value and eligibility |
| --- | --- |
| steps (Step) | Committed complete Steps, excluding inherited header history |
| `model_ms` | Sum complete-Step model ms including retries/backoff, excluding tools, not wall time |
| `prompt_tokens` (prompt) | Sum complete-Step input including cache/repeated context, not fees |
| `uncached_prompt_tokens` (uncached) | Sum per-Step `prompt_tokens - prompt_cache_hit_tokens`; both nonnegative integers, cache ≤ prompt |
| `first_request_cache_hit_rate` | First complete-Step cache/prompt; valid fields, cache ≤ prompt, prompt > 0; equal child weights, not aggregate-token ratio |

Distributions require nonzero Steps and every complete Step selected. sessions counts selected child logs; `full_range_sessions` counts eligible full-range/nonzero children; `partial_range_sessions` counts --since/filter truncation; `no_step_sessions` counts no complete Steps. Last two do not enter distributions; fragments are not whole-task costs.

model_ms/prompt/uncached independently require corresponding valid fields on all complete Steps; never zero-fill/add parent or tool-result usage. First-hit rate checks only the first complete Step, ignoring later missing fields and never substituting later valid usage. samples vary by metric; empty is 0/null/null, nearest-rank p90. Failed/canceled/running logs remain lower bounds. Observations, not automatic choice thresholds; [Session statistics](session-log.md#session-statistics).

## Interfaces and limits

await tools.llm({ prompt, input, schema, model, effort }) returns { text, data, usage }, one tool-free request. prompt required, input optional: strings verbatim, other JSON-serializable values encoded separately. No history/project AGENTS.md/nib system inheritance. Without model, the provider's small model (`provider.smallModel`: codex/openai gpt-6-luna, anthropic claude-haiku-5-5, deepseek deepseek-flash) runs at its own default effort, never the Session's; providers without one use the Session's model and effort. An explicit model inherits the Session's effort; explicit effort always applies. Overrides are local. Host sends within current process without exposing credentials to JS; children also have llm. Optional object schema: Responses strict json_schema, Chat Completions json_object plus prompt constraints, Anthropic prompt constraints. Server subsets still apply (Responses additionalProperties:false/required). Host validates JSON, not full schemas; data parsed or null without schema. Parse failure retries once with error, then rejects with bounded raw excerpt; both reported usages aggregate with agents into Turn/TUI/ask snapshots, calls name llm. Cache key `<session_id>:llm` isolates main context.

llm [limits](config.md#limits): configurable concurrency default 4/process, queue beyond without request-time charging; default 100 calls/Run, reject before sandbox queuing beyond; prompt+serialized input default 256 KiB UTF-8, configurable, reject without truncation. Provider timeouts retained (currently no extra read timeout); `src/provider/retry.zig` shares main retry/backoff/server-delay handling. Esc/SIGINT/SIGTERM cancel active/queued calls. Runs stay stateless, intermediate JSON files; [ADR 0013](adr/0013-llm-functions.md).

Root Sessions call await tools.agent({ prompt, resume, fork, timeout_ms: 1800000, model, effort, background: false }). Optional boolean fork defaults false. Optional resume omitted creates children (fork chooses inherited context); task id a1 continues matching child history/original system with appended prompt. Only creation allocates ids; continuation retains a1 in foreground/background confirmations/completion/progress/tree. Each invocation starts independent nib for one Turn, internally nib ask --resume `<internal-child-ID>`, no persistent worker. Ordinary children read instructions independently without parent history; fork differences follow.

`fork:true` inherits complete current compacted parent history, never reconstructing discarded originals; system/schema byte-identical. Capture includes initiating assistant, reasoning including encrypted Codex items, tool calls. Synthetic results close those calls, then append task user prompt; not real unfinished parent results or rerunning parent Runs.

Each fork creates independent child/new aN, later resumable. Passing fork and resume together rejects even fork:false. Ordinary child depth applies, no recursion despite inherited agent descriptions/schema. Shared cwd, no worktree; copied capture-point observations mean inherited files remain observed and direct writes stay stale-checked. Existing locks/atomic replacement/stale checks persist without workspace isolation or bash/editor coordination.

Copy observations only on fork creation, never log them; later resume restarts observations like ordinary resume.

Fork model/effort inherit the parent's configuration; overrides win. Both must match for parent-prefix benefits. Responses and Messages require the parent model for a fork, even with an override. Codex shares parent `prompt_cache_key` for routing, but hit/savings remain measured hypotheses, not guarantees; [codex.md](codex.md#fork-and-parent-cache-routing), [ADR 0015](adr/0015-agent-fork.md).

Foreground success { ok: true, id, text, usage, changes }; timeout/crash/nonzero/NDJSON error { ok: false, id, error, text, usage, changes }, without rejection/sibling cancellation. id is task id, never internal child ids in results/errors/background. Only argument errors (including malformed resume) and user cancellation reject. Successful text=end.text; failures keep received final text deltas excluding reasoning/tool code, otherwise empty. error preserves cause, actual time including grace, task id, possible incomplete files. usage/changes this invocation only, no prior-history recounting.

Parent logs persist/reconstruct task/internal-child mappings; models use task ids only. Child `parent_session_id` must match. Missing/foreign/non-agent/unmapped targets return `ok:false`, not reject; internal ids cannot resume. Resumed parents keep original children; root/other-parent children reject as data. Reserve target before concurrency waits: one active/queued/foreground/background call per agent; busy immediately `ok:false` without queue/new ids. Release on success/failure/cancel, shared paths; exclusive log locks also prevent multiprocess/CLI overlap. Failures/timeouts/cancel retain mappings; resumable logs remain reusable, but no received internal id means no mapping. No rollback or completeness guarantee for interrupted changes.

Optional timeout_ms defaults 30 minutes excluding queues. Omitted model/effort inherit current parent settings even on resume, not prior child overrides; overrides affect only current child, never parent/provider. Existing validation/mapping applies. Provider must match the log. Responses and Messages replay encrypted or signed history only from the selected model ([providers.md](providers.md)). Child concurrency default 4/configurable (8 total tools). Children share cwd/effective provider/model/limits via stdin, skip config files, independently read Codex login. `NIB_AGENT_DEPTH` increments from 0; at 1 new-child descriptions/API remove agent. Fork preserves schema but runtime still rejects recursion. `NIB_PARENT_SESSION_ID` writes child headers. Explicit child --resume retains depth; --continue skips children.

background defaults false/foreground wait. true returns {id} after registration, preserving a1 on continuation; busy/missing/foreign agents return `ok:false` without registration. Parent owns children across Runs while model continues Steps, no query/wait tools. Before next main request insert user `[background agent <id> finished]` plus truncated {ok,id,text,changes,error?}, no usage. Never insert during response/Run or as new user Turns. Tool-free answers with pending tasks wait for next inbox item (result/interjection), FIFO then next Step, without waiting for all tasks.

Background shares agent concurrency/model/effort/timeout/cancellation; ending individual sandboxes does not cancel tasks. Parent Turn failure/cancel or Session exit stops/cleans unfinished children. Resume retains logged results, never restarts tasks, inserts [background agent `<id>` lost: process ended]. Lifecycles: [ask-json.md](ask-json.md); sources/accounting: [session-log.md](session-log.md).

Background bash also returns {id} immediately, independent agent concurrency. Agents a1,a2… and bash b1,b2… use Session counters: agent creation only, continuation retains; all bash allocate at start, foreground shown after 3 seconds. Counters survive Runs/Turns, resume each prefix max, compatible with old shared counters without filling gaps. At most 8 background bash, excess immediate rejection/no queue; available in children. Results insert sourced user messages before requests; unfinished resume becomes lost. Background lifecycle events apply.

Detached background bash survives Runs/normal Turns; answers/Step-limit cleanup await only ordinary tasks, listing only actual waits. Requires `background:true`, default `timeout_ms:0`, optional positive. Ordinary foreground/background defaults 1800000 ms, never reset/shortened by Run backgrounding; explicit positives win. Rationale/cleanup: [run-output.md](run-output.md#bash-execution-deadlines). Share b counters/concurrency/output caps. Completion enters inbox once, no idle auto-Turn, consumed next Step/Turn. Failure/cancel/exit/switch cleans all; ask exits Session after answer, no cross-process survival. Resume never restarts, uses lost.

`tools.stop({id,reason}) → {id,stopped,reason,notice?}` requires nonblank string, else reject without stop. All explicit stops need concrete reasons, without command-purpose guessing; long/silent alone is not a hang. User requests/observed failures/changed needs qualify. Unfinished test cancellation loses progress, proves no pass, and restarting repeats unfinished work; files/build caches do not roll back. Retain reason and actual-stop notice. Cancel/join one background a/b task and clean groups; active→`stopped:true`, known finished→false, unknown rejects. Concurrent stops join once and deliver completion once. Release agent occupancy before returning without deleting identity. Start/stop use ordinary settlement/recording; background bodies count receiving-Step output_bytes. [ADR 0014](adr/0014-session-background-jobs.md).

`tools.wait(ids?) → { ok, results: [{ id, kind, ok, output }], not_pending? }` exists only under `delivery = tool` ([run-output.md](run-output.md#delivery-tool)) at depth 0: it blocks until the named background Run/bash/agent tasks (default: all pending non-detached tasks except the calling Run) have finished and returns their results, which are then not delivered again. Unknown or already delivered ids go to `not_pending`. It honors cancellation, and a Run blocked in it is never automatically backgrounded.

Execution failures normally become result messages. Internal worker failures preventing inbox generation/writes (e.g. allocation) report once via polling, remove pending-result membership, never repeatedly error in later Runs.

changes aggregates received `run_end.changes` from all child Runs including failed ones, first-path order [{ path, added, removed, created }], summing counts/OR created, no diffs. Runs compare immediate successful edit/write before/after, not net Run/Session diffs; reverted edits count both, failed calls none. Operation diffs concatenate with …, capped per Run/path at 200 change/context lines excluding markers, without count changes; [ask-json.md](ask-json.md).

No Run-end rereads. Bash/external/parent/sibling/background changes between/after writes are not current-Session changes, though later diffs may show unchanged context. Background agents own/report their Runs, not starting/concurrent foreground Runs; child changes exclude concurrent parent/bash. Records prove neither current disk state nor ownership. write before-read cap 16 MiB; unreadable/oversized before may still write successfully without changes accounting. Interrupted pre-run_end edits may be absent; inspect partial files after failure.

## Progress, usage, and cancellation

Any tool failure leaves sibling calls running, beyond `ok:false` agents. Fulfill/reject both drain queued/active tools, jobs, new continuation calls; preserve original rejection. `Promise.all` read/llm rejection still waits for foreground agents and their remaining time/usage, with Esc available.

llm/agent usage aggregates per Turn. User cancellation/JS timeout stops whole Runs; individual timeout/supersession/id stop affects only targets. Unfinished interruption retains `[stopped before completion: bash #0, agent #2]`, 0-based all-tool creation order, not background ids. [run-output.md](run-output.md).

Observe complete NDJSON lines live; final parsing/accounting unchanged. Mutex-protected per-invocation latest snapshots separate repeated ids; tool threads update queues, never Session sinks. Run threads forward about every 20 ms during Promise/tool waits, outside JS budgets. Before eval return stop/join foreground threads; parent owns background agents beyond Run. Clear progress queues at Turn end, retaining original-Run background progress until insertion. TUI copies events into its loop, always shows trees under initiating Runs, one fixed row/task in creation order, id-updated. Resume a1 stays a1. Agent row: “  ├─ a1 prompt summary · state · step N · tools changed-files”; bash: “  └─ b2 bash command-summary · duration · state”, branches by position. Foreground bash appears after 3 seconds, updates every second, retains terminal status; shorter commands remain hidden, Run titles unchanged. Times under 60 seconds use `42.3s`, otherwise 3m12s. Ordinary backgrounds show background before delivery; active detached shows detached, then final status. Prompt/command previews ≤40 Unicode characters; narrow screens shrink them then trailing file info, preserving id/status/Step/time, never wrap. ctrl+o toggles code/result/diff, not trees. Ended Runs restore tool/time/change summaries and last child state; historical Runs do not rebuild trees. Background result titles retain ids: ✓ b2 bash · ok · output-preview; ✗ a2 agent · failed · text-preview; ✗ a2 agent · lost. ctrl+o shows full JSON; history uses same formatting. Latest-Run tools and edit/write paths do not mean current command or percent complete.

Bash/children reuse std child waits/process groups. Every bash, including detached, cleans whole groups on shell exit, even success/nohup/&; after main exit drain buffered pipes only, never wait same-group descendants. Services run foreground inside commands; server & exit 0 ends tasks/cleans services. Stop/timeouts/Turn cancel/failure/Session exit also clean groups. Child nib gets SIGTERM and 500 ms to cancel tools before force kill. Usage is received cumulative snapshots, not unreported server tokens. read/edit/write coordinate shared NIB_HOME through persistent canonical-path SHA-256 advisory locks under `$NIB_HOME/locks/`, shared aliases/symlinks, never unlink on release. Same-directory `.nib-*` plus rename; track inode/size/ns mtime; stale observed write rejects until reread, unobserved files allow direct writes. Bash/editors ignore locks; checks detect prior changes, not check→rename races with noncooperators. Permissions/symlinks/hard links/durability: [run-output.md](run-output.md#file-replacement-session-versions-and-cross-process-coordination).

## Generating tool descriptions

New systems generate llm model lists in `src/tools.zig` from effective provider config. Built-ins use `src/provider.zig` tables (Codex original catalog `src/provider/responses.zig`); legacy Chat Completions includes at least `src/provider/openai.zig` default plus deduplicated configured model. Common effort descriptions list low/medium/high; omissions inherit. Full mappings: [config.md](config.md), [codex.md](codex.md). Choices stay within providers.

Encode model names as JSON strings, never raw configuration insertion. Root/new children share generation, default children hiding agent. Fork reuses system/schema, runtime enforcing no recursion. Resume retains original logged system/history. [ADR 0010](adr/0010-subagents.md), [0013](adr/0013-llm-functions.md), [0015](adr/0015-agent-fork.md).

## Automatic background Runs

Long Runs need no model `background:true`: after configurable 10 seconds while awaiting tools, original scripts continue with early rN notifications. Awaited types unchanged, console/changes delivered together later. Shared cwd/observations; continue work without polling, edit/write then identical command supersedes below. Limits/conflicts/cancel/budgets/resume: [run-output.md](run-output.md#long-runs-automatically-move-to-the-background).

stop accepts other background rN, never self. Runs are non-detached; answers/Step caps await delivery. Continuations may launch explicit ordinary/detached bash/agents. Only Session main threads forward progress/usage/results to sinks, never background sandboxes/tool threads.

Tool-free text with pending ordinary tasks always commits waiting Steps/local waits regardless of wording/length. A Step whose Runs all succeed with no output/actual host calls (empty Runs/blank printing) also waits without model requests. Output or actual tools count normal work; git/read/stop are not automatically waiting. Resume after inbox/interjections; detached retains cross-Turn behavior.

## Identical commands supersede stale execution

New same-Session bash stops active earlier-Run bash groups when command strings/start cwd match exactly and successful edit/write changed files since old start. Rerun validation directly after edits. No language/purpose classification or shell cd/args/redirect parsing. Same-Run parallels never supersede; no-change repetitions neither supersede nor cache. Either detached excludes matching.

Old calls resolve `{superseded_by:"bN"}` without exit_code/output/error: updated validation replaces it, neither pass nor failure. Background messages carry `background_ok:true`; automatic Run awaits get identical data/continue, script determines final state. Check `if (!r.superseded_by && r.exit_code !== 0) ...`; older unconditional checks may throw. Only matching bash stops, not Run/siblings; continuations can still cause effects.

Advance change generation after successful edit/write independently of UI changes accounting; read ≤16 MiB to compare before. Invalid edits/failed writes/known-identical overwrites do not advance; empty creation does. Unreadable/oversized before makes successful write conservatively advance. Session evidence, no dependencies; any edit/write may stale commands, not detectable bash/user/other-Session/child writes. Reuse stop/cancel cleanup, 20 ms flag polls, no waiting for natural exit. Supersede every matching old command once; concurrency admission still applies. Existing effects remain. [ADR 0016](adr/0016-superseded-bash.md), [log events/stats](session-log.md#bash-start-and-supersession-events).

API-key configuration sends names only via stdin; children read keys independently, only selected keys enter nib, bash removes them. Cache-write usage: [providers.md](providers.md).
