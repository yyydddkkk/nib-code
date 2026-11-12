# Session logs, resume, and timing

TUI `/undo` uses independent local snapshots for edit/write effects. Main logs retain conversation and append `source:"undo"` user intent/results; bodies reach later requests, source metadata does not. Resume rebuilds messages, not undo stacks. Storage/conflicts/process boundaries: [undo.md](undo.md).

## Resuming Sessions

Resume current-directory latest root Session (skip children) with nib -c / --continue, or nib --resume <32-character-lowercase-hex-ID>. ask supports options before/after prompt.

New systems concatenate base instructions, global `$NIB_HOME/AGENTS.md` (default `~/.nib/AGENTS.md`), project `AGENTS.md`, later taking precedence. Project root: first cwd ancestor with .git, otherwise cwd. Read only AGENTS.md. Resume keeps original logged system; changes affect new Sessions only.

Codex custom `tool_calls` carry `type:"custom"`; `function.arguments` remains JSON {code}, complete raw JS including optional effort line. Old entries default function. Resume/replay require no migration. Raw Responses outputs/types/argument-byte definitions: [custom Run](codex.md#custom-run-tool).

## Tool recording and offline replay

Main `$NIB_HOME/sessions/<session_id>.jsonl` stores messages/Steps; independent `<session_id>.calls.jsonl` stores actual returns/rejections, mode 0600. Sidecars default on, disableable, independent of main format/resume. nib replay executes saved JS in fresh sandboxes with recorded tools, no models/bash/file writes.

Replay step is **1-based assistant Step ordinal over the Session**, including final answers, never resetting per Turn; run is **0-based `tool_calls` index**. Not `turn_step` or internal tool index. Commands/format/truncation/dedup/undetermined cases: [replay.md](replay.md).

Sidecars may contain undisplayed full files/output/secrets, not sent to providers/reflection. Reflection only reads specified main logs, without sessions enumeration or sidecar/sibling/child reads: prompt constraint, not separate access control. Inspect both before sharing; main redaction does not cover sidecars.

## Experiment tags (header)

First-line headers optionally tag new roots/children; old logs still resume. Recording/stats only, not provider input or changes to execution/system/tools. Resume preserves originals without recomputing/backfilling/rewriting from current builds/environment.

| Field | Meaning |
| --- | --- |
| `nib_version` | `build.zig.zon` version plus injected short git hash, e.g. `0.1.0+abc1234`; version alone if hash unavailable |
| `system_sha` | First 12 lowercase SHA-256 hex characters of rendered `system_template`, including cwd/tools/patches/explicit Step caps, excluding global/project `AGENTS.md`; cwd/tool availability/patches can change it, not just wording |
| `patches_off` | Actually disabled default-on registered `NIB_PATCHES_OFF` ids, deduplicated/sorted; ignore unknowns, expand all; omit when none |
| `patches_on` | Opt-in patches actually enabled by `NIB_PATCHES_ON` (not also named in `NIB_PATCHES_OFF`), deduplicated/sorted; omit when none |

## Commits and interruptions

Logs: `$NIB_HOME/sessions/<ID>.jsonl`, default ~/.nib/sessions/. Every new record has append-time wall-clock Unix-ms at; old missing timestamps remain compatible. stats --since uses at, falling back to mtime for missing/invalid values with counts. Normally commit complete Steps; background results/lifecycles commit separately before next requests. Step-cap cleanup awaits ordinary tasks, independently commits results, ends without requests; detached results wait later Steps/Turns. Final Codex failures append diagnostic: {error_name, message, attempts, step}, preserving server code/reason, without committing input/failed output or changing history/context_tokens. Resume skips; stats `errors.provider_failure` adds no Steps/tokens. Cancellation (Esc/SIGTERM/SIGINT) additionally commits Turn input/streamed text, ending Esc/SIGINT with [interrupted by user], SIGTERM `[interrupted: process terminated]`, discarding unfinished tool calls. Resume never reruns committed Runs; unfinished Steps may already have external effects, never rolled back.

Both transports share `src/provider/cancel.zig` `std.Io.Select`: request task writes live sink, another checks cancel every 20 ms. Cancellation interrupts blocked connect/send/read I/O and joins cleanup before `error.Canceled`, without next-data waits. TUI Esc/ask signals share this, no read timeout/retry changes; commitInterrupted retains streamed text.

## Images

Images are stored in `$NIB_HOME/sessions/<ID>.images/` as `<content-hash>.<ext>` (directory 0700, files 0600). A message's optional `images` array holds references only: `{ path, name, media_type, bytes, width, height }`; user messages carry TUI attachments, tool messages carry `tools.view` images. Logs never contain base64. Resume reads the files when building requests; a file that is gone becomes `[image <name> unavailable: file is gone]`. Restored `view` summaries regain their dimensions from the same references. Background Runs do not attach images.

## Sandbox records

When the OS write sandbox is on but unavailable, the first bash command appends `{"sandbox_unavailable": "<reason>"}` once per process. It carries no history, context, or Step data and is skipped on resume and replay. Behavior: [config.md](config.md#sandbox).

## Background task results

Before agent/bash background start, synchronously append independent background: {id, kind: "agent"|"bash"|"run", state: "started"}. After result insertion append finished/ok; unfinished resume appends lost. Separate Session a1,a2…/b1,b2… counters share foreground/background per type. Resume scans lifecycles/bash/calls[].id and continues each prefix maximum, including old shared-counter logs without filling gaps. Records carry at/turn_step, changing no history/context_tokens. Results separately commit user source: "background", background_kind/id/ok before main requests. Optional `background_ok` lets TUI restore status despite truncated body JSON. Agent body [background agent a1 finished] newline plus truncated {ok,id,text,changes,error?}, no usage. Bash body `{exit_code,output}`, `{superseded_by}`, or {error}, no ok. Unfinished resume never restarts, inserting lost process-ended messages. Source metadata stays local; bodies reach models. No new Turns. Legacy `background_agent` remains countable.

After first child start, parent synchronously logs agent_session:{id:"a1",session:"internal-child-ID"}, outside history/context/Step counts/model input. Continuation keeps ids/mappings through compaction/failure/cancel; resume reconstructs mappings/high-water ids. Models use tasks only, internally nib ask --resume. Same-id background invocations pair in start order. Resume repairs terminal records for committed results before marking truly unfinished calls lost; old results never clear newer recovery state.

Explicit Step caps record `run_results[].remaining_steps` after Step completion, shared across same-Step Runs, omitted unlimited. Replay restores unbudgeted hints from metadata, not current settings/output inference.

## Step timing fields

Optional complete-Step timings support old logs. `model_ms` includes retries/backoff; attempts counts actual attempts. `first_data_ms` is first Sink.onData transport activity (heartbeat/metadata included) relative to Step start, not first content token. code entries {tool_call_id, first_ms, last_ms, progress} use Step-relative times and [ms,cumulative argument UTF-8 bytes]. Arrival-order fixed buffers cap at 1024/call, stride-sample overflow, then uniformly reduce at finish to ≤32 retaining endpoints. Track Codex output_index/Chat tool index; one-shot arguments faithfully first_ms == last_ms, no inferred fragments. Retries retain successful code only, earliest onData across attempts. `run_ms` sums sandbox-start→output-format durations; `run_results[].run_ms` per Run, absent before sandbox. calls retains ≤200 {name, start_ms, end_ms, ok, run_index}, Run-relative times, zero-based run_results index; overflow calls_omitted. ok means tool return/error, not bash exit. Children count parent calls only, no args/results. Optional calls.id stores task ids allocated on foreground agent/all bash startup, including short bash, preventing numbering rollback. Complete/compaction/interruption commits optionally store task_ids: {agent, bash, run} high-water marks, preserving numbering beyond 200 details; old logs may omit. Background calls add background: true/id and timing only until startup returns, not full execution. All timings use monotonic awake ms; fixed buffers reuse scheduling/completion without new locks/per-fragment allocations/prefetch/speculation.

## Tool byte measurements

Optional Step-level `tool_bytes` sums Run bytes; `output_bytes` sums Runs plus first-accounted background-result bodies in that complete Step. `run_results[]` optional bytes exclude background messages. Fields are top-level beside timings, not nested timing. Missing old fields stay missing, not zero.

- `sandbox.Outcome.tool_bytes` accumulates delivered host results as UTF-8 serialized JSON or error text, regardless of usage/await; undelivered zero. Agents count parent objects only, not internal child data.
- Run `output_bytes` counts actual formatted model tool-result UTF-8 including budgeted markers/errors/no output/labels/separators. Harness-rejected Runs record returned output bytes, zero tool bytes.
- Startup {id} counts ordinary results; later agent/bash messages bypass Runs, adding only receiving complete-Step `output_bytes`, not tool/run-results bytes. Count actual body including background prefixes/newlines/truncated JSON/markers; resumed lost messages too. Count once on first complete receiver. Results committed during cap cleanup without receivers, or failed/canceled receiver requests, carry to next complete Step. Resume reconstructs pending bytes from append messages/complete Steps; no loss on exit, history retransmission recount, or interjections. Separate message/lifecycle commits omit byte fields. Failed/canceled incomplete receivers add no invoice/Step bytes; committed messages still restore.
- calls.dispatched defaults true; prequeue quota rejection false, still error-text bytes, excluding llm/agent actual-dispatch counts.
- Optional calls[].result_bytes matches each host contribution to tool_bytes. Old null/absent accepted; new unsettled canceled calls zero. Omitted >200 details do not change Run/Step totals.

## Turn invoice

TUI appends muted invoice after each Turn, e.g.:

```text
12 steps · 3m10s · think 1m40 · tools 1m20 · 3.2M→18k B · 45k tok (91% cached) · llm ×8 · agent ×1
```

Drop whole fields right-to-left without wrapping; hide zero llm/agent counts. Failures/cancel begin failed/canceled; Steps/think/tools/calls count committed complete Steps only. Total monotonic wall time includes whole Turn, not sum of Steps; think/tools reuse model_ms/run_ms. Tokens use Turn cumulative usage after complete Steps, prompt+completion including reported compaction/delegation; cache rate cache-hit/prompt. Unfinished failures/cancel excluded except wall waits.

`TurnSummary.timing` tool_bytes/output_bytes sum complete-Step fields, retaining zero keys even on failure/cancel. output includes new backgrounds; old logs may include Run output only. TUI shows `3.2M→18k B` after tools (tool→output), decimal k/M. Omit only if both zero, retain background-only output.

Session passes values through `turn_end`; TUI never reads cross-thread stats. Invoices are UI-only, outside model history, not rebuilt on resume. ask `end/error.timing` matches; [ask-json.md](ask-json.md).

## Run title tool counts

TUI keeps parent titles, active known states, then run_end.tool_summary: {counts: [{name, count}], omitted, files: [{tool,path}]} from Session. Actual dispatched calls only, excluding false admissions but including execution failure, first-call order. calls cap 200; overflow shows +N without guessed tool names.

Resume maps calls[].run_index to assistant `tool_calls` indices then results by tool_call_id. New run_results[].calls_omitted tracks each Run. Transitional Step-only omitted counts assign directly for single Runs; multiple Runs show tools +N · omitted calls (Run unknown), preserved in assistant step_calls_omitted. Old logs without calls show Run only, no source inference. calls[].path may store actual read/grep/glob paths, omitted roots default .; tool_summary.files deduplicates {tool,path}, old optional. Optional tool-message `tool_summary` preserves UI stats across compaction, never provider input.

## Step effort fields

Complete Steps optionally log `effort`: the actual request level, or `default` when the server picks it. Retries keep it; compaction creates no Step effort. Older logs also carry `effort_source`, `effort_downgraded` and assistant `step_effort.source` from the removed per-Step scheduling ([ADR 0025](adr/0025-model-profiles.md)); readers ignore them and old logs stay resumable.

Assistant `step_effort: {effort}` is UI metadata preserving retained Run levels across compaction; complete-Step top-level fields govern resume. Never sent to providers.

## Session statistics

python3 `scripts/stats.py` [log-file-or-directory] [--since YYYY-MM-DD] [--cwd directory] [`--group-by version|system|patches|profile|transport|incremental|full_reason`] [--json] reads `$NIB_HOME/sessions` (default `~/.nib/sessions`) by default for failures/before-after comparisons. Text/JSON time breakdowns include Step/model/Run median/p90, first-code wait/argument span, runtime tool counts/totals/medians, and fraction of spans >50 ms, each with samples/no old-field zero-fill. Top 10 bash timings (`timing.bash.top10`) split shell &&/||/;/|/newlines outside quotes/heredoc, joins each segment’s first two words with →, e.g. zig fmt x && zig build test → zig fmt → zig build; single segments unchanged. Heuristic labels, whole-call times, no per-segment/branch inference. Prefer actual `args.command` in same-directory `<id>.calls.jsonl`, joining Session Step/Run/bash creation index (not seq; multiple bash require matching counts/no undispatched calls), otherwise static JS literals. timing.bash.sources.recorded/static count successfully grouped sources, sum `matched_calls`; unreliable/ungroupable timings unmatched_calls. Recordings do not change static counts/write→validation metrics; mechanical follow-ups below separately prefer complete recordings.

Cache section (`cache` in `--json`) explains uncached input per complete root-session Step from `usage.prompt_tokens`/`prompt_cache_hit_tokens`, `turn_step`, `effort`, and messages committed between Steps. Expected cache = min(previous Step prompt, this prompt); lost = max(0, expected − hit − 64) (cache block rounding); inherent = max(0, prompt − expected). A Session's first Step is `session_first`. Lost tokens at `turn_step == 1` are `turn_start`, later ones `mid_turn`, attributed to `effort_change`, `compaction` (history-replacement record in between), `background` (user message with `source` background/background_agent), `user_message` (any other user message), else `unknown`. Reports weighted hit rate, prompt/uncached/cached/output totals, shares of uncached input (`rounding` is the remainder, so shares sum to 1), mid-turn loss by cause, the 5 largest losses, and uncached input per Turn (median/p90). Child sessions, Steps without usage, `turn_step`, or an adjacent selected predecessor are excluded, never zero-filled (`skipped_steps`). Honors `--since`, `--cwd`, every `--group-by`. Diagnostic only: judge tuning by cost, not hit rate (ADR 0025).

`child_costs` samples each selected foreground/background child log with parent_session_id. steps/model_ms/prompt_tokens/uncached_prompt_tokens distribute complete-Step counts, cumulative model ms, cached-inclusive input, uncached input with median/p90/samples. Uncached sums per-Step prompt-cache, requiring nonnegative integer fields/cache≤prompt; no missing zeros or quantile subtraction. `full_range_sessions` requires nonzero Steps/all selected; `partial_range_sessions` filtered fragments and `no_step_sessions` enter no distributions. Timing/tokens independently require all corresponding fields valid, so sample counts differ. Only child-Step fields, not parent/tool-result usage; prompt already includes cache. Failed/canceled/running samples are committed-cost lower bounds, not successful/end-to-end cost or fee estimates.

child_costs.by_parent_system joins `parent_session_id` to input parent header system_sha. Supply parents+children when comparing descriptions; absent/invalid parent labels mean unknown without child fallback/guessing. Child hidden-agent hashes may not track description changes. Parent-header lookup ignores date/cwd filters for labeling only; costs stay selected children. `--group-by system` still uses each log’s own hash, distinct from parents. Resume retains original headers/systems/groups.

`tool_data` independently sums valid Step tool_bytes/output_bytes samples/totals, never adding Run/calls or backfilling. `output_tool_ratio` distributes per-Run output/tool for valid fields/tool>0, median/nearest-rank p90/samples, not total ratio; may exceed 1. Tool shares use valid calls[].result_bytes total, grouped name/count; omitted details limit coverage. Skip old missing values without zeros; zero detail bytes means n/a.

`--group-by version|system|patches|profile` uses header nib_version/system_sha/patches_off(+patches_on, shown as `<off> on=[...]`)/profile (the model-family [Profile](../CONTEXT.md) resolved when the Session started), retaining overall/core reports per group via group_by/groups JSON. Missing old tags unknown; newer version/hash headers omitting patches mean none; lists group as sorted sets. transport uses actual complete-Step transports below.

Optional complete-Step `turn_step` is 1-based within Turn; interjections do not start Turns, new resumed Turns reset 1. Old logs estimate user-message boundaries excluding backgrounds and may overcount interjections as Turns.

agents/bash_calls report foreground/background counts and background_steps. Valid calls drive foreground; agents roots only, bash includes children; exclude dispatched=false. Background counts prefer independent started, old fallback background: true/id calls. Join ids to finished/lost/source=background results, supporting old background_agent. Count complete main Steps after starting Step/before result insertion, excluding start/consuming requests; median/p90/samples per task. Require same Session, full selected/uninterrupted pairs, no zero-fill across gaps/incomplete pairs.

`round_trips` distributes selected Steps/Turn (nearest-rank median/p90, zero-Step included), write→validation adjacent pairs/all pairs, disjoint consecutive writes/valid write pairs, all with samples. Same-Turn only, no filters/cancel gaps. Validation heuristics use bash first words/subcommands: build/test/fmt/check, git status/diff/log/fetch/show, gh pr view/checks, tail/cat/ls/head/pwd. All Runs/calls must be recognized validation bash; skip dynamic/compound shell conservatively. Writes require complete direct edit/write literal paths normalized by cwd; disjoint sets mean different files, missing/dynamic skipped, no bash-effect inference.

`round_trips.mechanical_followups` candidates are adjacent complete selected same-Turn Steps, later `turn_step > 1` (estimated order in old logs), earlier ≥1 Run/all explicitly `ok=true`; unknown is not success. No cancellation/filter/compaction/explicit-sequence gaps. Hits later call ≥1 tool, only bash/read, all bash passing shared validation/status classifier. No effect inference; git fetch counts status, merge not; compound shell/redirects/expansions conservatively skipped.

`count/samples/ratio` = hits/candidate Steps/share. `ms/sample_ms/time_ratio` = timed-hit later durations/timed-candidate later durations/share; `timed_count/timed_samples` show coverage. Missing timing not zero; zero total yields null. Neither all-Step nor `model_ms` shares. sources/hit_sources count `recorded/static/mixed` candidate/hit Steps. Complete per-Run recordings prefer actual tools/args.command, including dynamic JS-built commands; otherwise conservative straight-line static extraction excluding control flow/unexecuted function bodies. Partial Run fallback yields mixed. Complete means one end meta ok/error, no incomplete, continuous unique indexes; damaged/incomplete data is not full execution evidence. Tool-free final answers never hit.

All version/system/patches/transport/incremental/full_reason groups recompute all fields and expose this metric in text/JSON. Expanded status classification may increase historical write→validation hits; that old metric stays static bash, excluding read/recordings. [Patch comparison](compromises.md#expected-continuation-baseline-and-measurement).

`timing.effort.by_effort` groups complete-Step effort, Step counts/model_ms distribution including medians/samples, prompt/cache totals/hit rate. Missing effort skips; missing timings still count Steps. Cache rate sums valid paired fields, not per-Step means.

timing.effort.cache_transitions groups header provider/model (each missing/invalid unknown), comparing same_effort/different_effort adjacent selected same-Turn complete Steps by later cache/prompt samples/median/mean. Equal Step weights, not aggregate-token ratios; empty 0/null/null. Both need nonempty effort/nonnegative integer prompt/cache, no completion requirement; later prompt>0. Skip invalid/missing Steps without pairing across them; no cross-Turn/Session/filter/cancel/compaction gaps. Existing `by_effort` rate unchanged. Observe associations, not causal group effects.

Machine events: [ask-json.md](ask-json.md).

## Automatic background Run recording and statistics

Automatic transitions sync `background:{id:"rN",kind:"run",state:"started"}`; current complete-Step run_results records `background_id`, omits undetermined ok, tool content notification, `tool_bytes`:0/empty summary. Never sample moving timings. Ignore unfinished Run effort declarations. Step `run_ms` records foreground wait/output_bytes notification; ordinary completed Runs retain meanings.

Final user messages preserve `background_run:{step,run_index,ok,output,run_ms,tool_bytes,calls,calls_omitted,changes}`; step is original Session-global 1-based, `run_index` 0-based. Output normal final formatting, `run_ms` full original wall duration, calls original-Run-relative, changes original-owned. Independent finished.completion and ask finished events carry same object for parent change aggregation, not extra Steps. Resume trusts committed messages, repairs missing finished; uncommitted results become lost. r ids continue lifecycles/task_ids.run maxima, never reused.

Step/Turn run_ms/tool_bytes/llm/agent counts include foreground-settled Runs only, never overlapping full background durations atop model time. Complete background timings/bytes/calls come from background_run. Final message/envelope bytes enter receiver `output_bytes` with existing carryover through caps/cancel. Early `run_end.ok:true` confirms backgrounding only; completion.ok/background_ok is actual outcome.

`background_runs` shares agents/bash_calls definitions: `background_calls` transitions; `background_steps` complete same-Session model Steps after start/before insertion; `foreground_calls` always 0 (automatic only). Include root/child main Steps separately, never child Steps as parent. Static tools use original source; old Step/calls performance metrics exclude asynchronous completions to avoid duplicates.

Tool-free waiting replies or all-success empty/no-host-call Runs carry assistant `waiting:true`, preserving content/reasoning/phase, never provider metadata. TUI restores notices; stats does not mark Turn completion. Still paid complete Steps.

## Step transport fields

Optional complete-Step transport:sse|websocket, incremental, input_items/input_bytes/transport_fallback. Chat Completions logs sse too; old missing unknown, never inferred from provider/header.

Transport/incremental describe final successful attempts. WS `input_items` counts wire input array entries; `input_bytes` compact UTF-8 JSON including brackets/separators, excluding other fields/frame/TLS/failed-resends. Full WS records too; SSE omits counts. `transport_fallback` names handshake/protocol errors (e.g. WebSocketHandshake, WebSocketProtocol), retained on subsequent Session SSE Steps; `previous_response_not_found` means incremental failed/full resend, possibly still WS. No response ids/routing tokens/auth.

`model_ms` includes handshake/resend/retry/backoff. `first_data_ms` first transport receive including WS heartbeat/metadata, excluding handshake headers; code[].first_ms and other code timing unchanged. Failed-attempt first_data retained; code follows retry resets. attempts counts outer retries only, not in-place previous-response resends. Messages always full local history; server responses unnecessary for resume.

--group-by transport or --group-by incremental filters complete Steps by actual final transport/continuation, then full reports with timing.model_ms/timing.first_data_ms/timing.code_first_ms median/p90/samples. Mixed Sessions may appear in several groups; partial mixed Turns excluded from whole-Turn wall samples, no missing zero-fill or adjacency across filters. incremental keys true|false|unknown: SSE false groups with full WS false, missing never false. Fallback SSE includes prior WS cost, not pure network differences.


`full_reason`: `first_request`, `missing_response_id`, `unsupported_output`, reconnect, `scope_changed`, compaction, `effort_changed`, `properties_changed`, `input_prefix_mismatch`, `previous_response_not_found`, `sse_configured`, sse_fallback. Prefix mismatch also records zero-based wire `mismatch_index`; successful increments omit full_reason. --group-by full_reason uses complete Steps, incremental for success, unknown old fields, same filtering/adjacency rules.

Immediately append transport_fallback, transport_fallback_at (Unix ms), transport_fallback_detail if any, and step, surviving cancel. No usage/model_ms; empty messages, no Steps/history/context replacement. Resume/replay skip history application. Complete Steps retain reason/original time. Immediately record missing-response full resends too. Diagnostics include parse stage/last event/output_index/received/pending counts, never raw frames/auth/routing.

`model_attempts` ordered by outer attempt contain Step-relative start/end, error_name/detail, transport/incremental/full_reason, fallback_reason/at/detail, bytes/content_bytes, first/last_content_ms/max_content_gap_ms/max_gap_ms. Content counts nonempty text/reasoning summaries/args; bytes response bodies, not handshake. Next start minus prior end shows backoff. Exhausted diagnostics retain arrays; Step max_content_gap_ms is final attempt content intervals excluding first waits/backoff. Omit missing optionals, no zeros. Total timeouts cover all I/O; cancel/join before collecting attempts and reusing sinks/allocators.

reasoning.includes_output:true means reasoning.data holds full ordered Responses output array including reasoning/message/function/custom calls. Display content/tool_calls, return array only, avoiding duplicates; encrypted items unchanged. Old unmarked logs retain reasoning-only replay. Fork deep-copies flag/data; token estimates count full arrays once. New readers accept old logs, old binaries may reject new formats.

## Actual background execution intervals

Optional background-bash finished `execution:{start_ms_epoch,end_ms_epoch}`, Unix ms from before spawn through wait return, excluding delivery delay. Omit pre-spawn failures; cancel/timeout end at wait. Present in logs/ask events; agents never misuse bash intervals.

Automatic completion/background_run execution uses Run creation→thread settlement, including pre-transition waits; calls remain original-relative. Not pure tool time: add call offsets to execution.start_ms_epoch and union actual intervals for critical paths; do not treat registration/delivery spans as tools.

Old calls `meta.start_ms_epoch` anchors Runs, completion.calls supplies complete calls including pre-transition. Explicit background bash only approximates from registration/terminal `elapsed_ms`; label estimated/unknown without exact ends, never delivery-as-completion.

## Bash start and supersession events

Each execution independently appends bash events, empty messages, no history/token/Step changes:

- started: Session bN id, Session Run ordinal, full command, start cwd, detached.
- superseded: old id/run, `superseded_by` new bN, `elapsed_ms` monotonic registration→supersession; at most once per old execution.
- finished: id/run/elapsed_ms after group cleanup for normal/failure/timeout/cancel/supersession. Log-write failure may omit.

Top-level at uses ms; old logs lack events. Resume skips history, restores b maxima, never restarts. Main logs now contain full shell commands; inspect sensitive arguments before sharing.

stats `bash_superseded` counts selected superseded events, text “Bash supersessions”. --since filters event at; no Step/Turn/failure counts. Resolve data/background results retain existing recording/message paths; [semantics](tool-delegation.md#identical-commands-supersede-stale-execution).

`task_stop` separately records id/reason/stopped without history; TUI reason user requested stop. Tool run_ok/background_id are local restore metadata, not changes to provider bodies.

Custom headers combine `provider:"custom"` and `custom_provider`; cross-custom-id resume rejects. Optional usage `prompt_cache_write_tokens` defaults zero, already included in prompt totals. stats accumulates cache writes where present.
