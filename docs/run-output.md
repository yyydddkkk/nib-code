# Run output budgets and entries

Tool data returned to JS is never truncated for model context. read → JS replacement → write still handles complete data unchanged. Explicit read pagination, grep/glob counts, fetch sizes retain their tool contracts.

## What the model sees

`src/session/output.zig` formats **the whole Run** into configured UTF-8 bytes (default 16 KiB), including headings/separators/omission markers. This exact text is shared by `run_end.output`, logged tool content, and next requests; not a separate budget per tool.

With `max_steps` set and at most 3 Steps remaining, append [N Steps left in this Turn] after formatting, outside budgets and never truncated. run_end/log/request share complete text. No cap means no hint.

Small output retains its format. When truncating:

- Each `console.log/info/warn/error` call is one entry regardless of arguments/lines. Final values/errors are separate; successful undefined adds none.
- Titles identify entry N of T and console/result/error. Preserve short entries first, share remaining budget among others. Long entries retain captured heads/real tails with markers at missing positions, never mislabeling a captured-prefix end as the original tail.
- [25000 of 40000 bytes omitted] under [entry 2 of 3 (console)] means 40000 original body bytes, 25000 hidden; equal counts mean the entire body omitted. Exclude new titles/separators from counts.
- When the omitted part of an entry spans lines, the marker adds them: `[25000 of 40000 bytes omitted · lines 120–480]` names the 1-based lines of that entry's text, from the line cut by the kept head (or the first fully hidden one) to the line cut by the kept tail; partly shown lines count as omitted, so re-reading `A–B` shows everything missing. Lines are real newlines, or `\n` escapes when the entry is JSON-looking text without real newlines (a logged `tools.read` object). For `console.log(r.text)` or a whole logged read at the default offset, entry lines are file lines; with `offset` add `offset − 1`. No range is printed when the omitted bytes stay on one line, when console capture lost bytes inside the entry (its line structure is unknown), or when the text is not recognizably line-structured.
- Console original bytes count formatted arguments joined by spaces plus newline, in UTF-8; results/errors use serialized text. UTF-8 boundary losses also count as omissions.

Printing an entire array is still one entry. Print individual labels for separate locations; filter large bodies in JS or split output across Runs.

Logged `tool_bytes` counts host→JS UTF-8 results (serialized JSON success, error text failure), whether used/awaited or not. Undelivered results count zero; agents count parent returned objects only. `output_bytes` counts actual model tool-result bytes including budgeted markers/errors/no-output notices/labels and unbudgeted remaining-Step hints, not original data size.

Configure `[limits].run_output_bytes` or `NIB_RUN_OUTPUT_BYTES` (16384–16777216). New system prompts reflect effective settings; resumed Sessions retain original system. Minimum preserves heading/marker room; increases affect neither console capture nor JS results. Locate with grep then read ranges; batch long multi-file bodies or print excerpts.

When a Run or background task message exceeds the display budget (or console capture exceeds 64 KiB), nib saves the full UTF-8 output (up to 16 MiB) under `$NIB_HOME/sessions/<session_id>.outputs/<content-hash>.txt` (directory `0700`, file `0600`) and appends `[full output: <path>]` (or `[full output (first 16 MiB): <path>]`) inside the display budget. Untruncated outputs write nothing. Models can inspect omitted sections directly with `tools.read` or `tools.grep` without re-running commands.

## Capture limits

`src/sandbox/console.zig` shares a 64 KiB display capture cap across the Run: fixed first 32 KiB plus rolling last 32 KiB, while spilling the full stream up to 16 MiB only once a Run exceeds 64 KiB so truncated Runs can save omitted middle bytes. Single huge calls and cumulative overflow share the display cap. UTF-8 trimming removes incomplete characters without extra body budget; JS tool returns remain unchanged.

Call details are bounded too: retain all up to 64 calls, otherwise first/last 32, merging middle calls into a range with original byte positions. Example for 10000 calls:

```text
[entries 33-9968 of 10000 (console)]
[19872 of 19872 bytes omitted]
```

Any range body still captured in head/tail shares display allocation normally; above all range text is omitted. Last 32 call details follow; final value/error numbering continues from original call count. Body/detail/format buffers do not grow without bound with call count. Omission counts combine capture and display losses.

Standalone nib js/TUI `/js` show sandbox head/tail with `[console output truncated: N of T bytes omitted]`, including UTF-8 losses in N, without model display formatting; below limits output is unchanged.

## Tool data and explicit limits

read returns { text, next_offset }, preserving requested offset/limit lines (default 2000), separate next-page start or null at EOF, file cap 16 MiB + 1 byte (inclusive). bash `{ exit_code, output }` preserves output, errors above 16 MiB with redirection advice. Explicit bounds: grep text/context ≤500 bytes; grep/glob truncated marks count limits; fetch text ≤1 MiB with { url, status, content_type, text, truncated }, no notices mixed into text, downloads >5 MiB error.

Search fields/UTF-8 columns: [ADR 0012](adr/0012-search-and-fetch-tools.md).

## Web search

`tools.search({ query, count = 10 })` searches the web with the current Session's provider credentials and returns `{ ok: true, answer?, results: [{ title, url, date?, summary }] }` or `{ ok: false, error }`. Provider and network failures are data; a missing or out-of-range argument (count 1–50, DeepSeek query ≤128 characters) rejects. Results are untrusted external data. A model answer produced without an actual search call is `ok: false`, never presented as results. Each search has a 60 s limit and honors cancellation; recording and replay work like any other tool. Provider routes: [providers.md](providers.md#web-search).

## Images (`tools.view`)

`view({ path })` returns only `{ ok, path, width, height, bytes }` to JS, or `{ ok: false, error }` as data for a missing file, unsupported format, file over 5 MB, a model without image input, or a Run that already viewed 4 images (`src/image.zig` `max_per_run`). Formats are png, jpeg, gif and webp; dimensions come from the file header and pixels are never decoded or resized. The image is stored in the Session and attached to the Run's tool result, so it reaches the next request as an image (encodings: [providers.md](providers.md#images)). Images do not count against the display budget; their request cost is estimated at 1500 tokens each. A Run that moves to the background keeps its text result; images viewed by it are not attached. The Run block lists `view <path> · <width>×<height>` beside read lines. `read` is unchanged and still rejects binary data.

## File replacement, Session versions, and cross-process coordination

edit/write write complete contents to random same-directory `.nib-*` files, then atomic same-directory rename, cleaning up on failure. Preserve existing permission bits; follow symlinks to real targets without replacing links. New inodes break hard-link sharing; other links keep old contents. File tools do not fsync: atomic visibility is not power-loss durability. Configuration writes retain fsync.

Sessions track last-observed inode/size/nanosecond mtime by canonical real path, updated by successful read (even one page), edit, write. Overwriting write compares current/observed versions and rejects external changes, requiring reread/new-content-based writes. Unobserved existing files still allow direct write; missing targets are creation. edit reads latest locked content and matches old_text, never replacing from stale Session snapshots; success updates versions.

read scans with a fixed 16 KiB buffer, collecting only requested lines without truncating long lines. Regular files with useful size metadata can stop after the page and lookahead; size-less streams scan to EOF to enforce the same input cap. The existing inclusive implementation boundary is 16 MiB + 1 byte. Size is checked before and after scanning; growth beyond the cap fails with `StreamTooLong`, and an observed inode/size/mtime change during reading fails with `FileChangedDuringRead` without refreshing the Session observation. See [read measurements](read-streaming.md).

read/edit/write share cross-process advisory locks in `$NIB_HOME/locks/` (default `~/.nib/locks/`), named by canonical-path SHA-256 hex. Independent nib processes, children, relative/symlink aliases sharing NIB_HOME coordinate on one lock. read locks keep returned bytes/versions consistent among participating writers. Persist lock files; release unlocks/closes without unlink to avoid waiting/new writers locking different inodes. Lock waits remain cancelable.

Locks coordinate only cooperating file tools sharing NIB_HOME; bash/editors/external programs do not participate automatically. Version checks detect prior changes, but uncooperative writes between check/rename remain possible. No absolute external-concurrency protection. Wait for external work and reread before edits when preserving its results.

Local regression needs no provider/key: build then python3 tests/test_files.py. Temporary NIB_HOME tests cover high-frequency multiprocess edits, aliases/symlinks, stale write/reread, paginated versions, permissions/hard links, cancelable lock waits, concurrent atomic-replacement reads.

## Credential masking

Before any display or capture truncation, nib replaces recognized credentials with `[REDACTED]` in console entries, Run results and rendered errors (including source excerpts), after-edit hook failure output, and background Bash/agent completion text. The same masked output reaches the model, TUI, `ask --json`, Session log, `tools.wait()` completion, and saved output files. Raw tool byte counts are unchanged; output limits and omission counts use the masked text.

The matcher recognizes `ghp_`, `gho_`, `ghu_`, and `ghs_` with exactly 36 ASCII letters or digits, and `sk-proj-` and `sk-svcacct-` with at least 24 ASCII letters, digits, underscores or hyphens. Token boundaries are based on ASCII letters, digits, underscores, and hyphens. Generic `sk-` strings, `Bearer` headers, and `password=` assignments are not recognized by those forms alone.

This is accidental-disclosure protection, not a security boundary. It does not rewrite source files, Run scripts, raw tool values and arguments, chat, diffs, images, Bash command summaries, user-written files, or earlier logs and artifacts. It cannot recover tokens clipped by a tool, split across console calls, or intentionally encoded. Opt-in [raw replay recordings](replay.md) may contain credentials; do not share them unreviewed.

## Run completion summaries

Foreground and automatic background Runs reserve display space for observed exceptions to an otherwise quiet completion:

- For settled `tools.bash` calls, nonzero exits and timeouts are counted separately. A successful JavaScript Run still reports `ok: true`; shell results are unchanged. Pending or superseded calls and separately delivered background Bash jobs do not count.
- For a failed Run, a short, masked list shows confirmed file changes tracked from `tools.write` and `tools.edit`. A syntax error does not execute any tools. This list does not account for side effects from Bash, MCP, or other tools; rerunning executes from the beginning and may repeat prior effects.

The summary is outside the clipped console/result body but shares its display budget. Full-output references and raw tool results are unchanged.

## Run execution budgets and cancellation

After top-level fulfillment/rejection, drain in-flight/queued tools, remaining JS jobs, and continuation-created calls until no work remains. Any call failure leaves others running, not just agent failures. Preserve original top-level rejection despite later success/failure. `Promise.all` early rejection does not stop side effects; failed Runs may keep writing. Foreground agents still finish/count usage, with Esc available. Cross-Run background lifecycle: [tool-delegation.md](tool-delegation.md).

User cancellation/JS timeout stops whole-Run active/queued tools; individual tool timeout, supersession, id stop affect targets only. Whole-Run interruption with unfinished calls retains:

```text
[stopped before completion: bash #0, agent #2]
```

Indices are 0-based creation order across all Run tools, not per-tool/background ids. Omit calls delivered to JS; list undelivered calls in creation order, including queued or completed-but-undelivered. Cap at 4 KiB with ..., N more, preserving space for errors/console. Reserve the whole line within model budgets so body truncation cannot remove it, distinguishing completed effects from potentially partial calls. Normal fulfilled/rejected draining adds no line.

Default 5-minute Run timeout accumulates QuickJS segments (initial script, jobs, result parse/resolve, serialization, error conversion), excluding tool/sleep waits, never resetting per await. It interrupts JS loops; bash/fetch/agent own deadlines. Check cancellation at ≤20 ms while waiting; Esc/SIGINT/SIGTERM remain effective with paused budgets.

## Bash working directory

`tools.bash({ command, cwd })` uses the Session directory by default. Relative `cwd` paths are resolved from that directory. The directory must exist; invalid directories and unknown options reject before launch. `cwd` applies only to that command, including background commands. It does not change the Session directory or add a writable sandbox root. Bash start records log the resolved directory, which is also used to match [superseded commands](tool-delegation.md#identical-commands-supersede-stale-execution).

## Bash execution deadlines

Ordinary foreground/explicit-background bash without timeout_ms defaults to 1800000 ms (30 minutes). Automatic Run backgrounding changes delivery only, never deadlines. Cold-cache concurrent smoke tests hit the old 120-second limit on first zig build test; reruns still took 130 seconds. Increase 15-fold to agent’s 30-minute budget for cold builds/contention while bounding ordinary commands. This is budget policy, not guaranteed completion; known longer work needs explicit timeout_ms.

Explicit positive timeout_ms applies from command start. Reject negatives; zero only with background:true, detached:true. Detached defaults zero for Session services. Timeout/stop/cancellation/Turn failure/Session exit clean groups; ordinary Turn cleanup waits for non-detached results, normal shell exits clean groups including nohup/& descendants; the call returns when the shell exits, draining output for at most 500 ms more, so daemons that left the group (setsid, services) keep running and cannot hold the call open. Output cap remains 16 MiB.

A command timeout resolves to `{ timed_out: true, elapsed_ms, exit_code: null, output }`, including stdout and stderr captured before the process group was stopped. It does not fail the JS Run; the script can inspect the result and decide what to do. An explicit background command delivers the same result with a failed completion (`ok: false`) and `timed_out` task status. Cancellation and whole-Run timeouts are unchanged. The usual output display limits apply to what is shown, and output redirected by the command is not read back.

## Delays and polling within Runs

`await tools.sleep(ms)` returns null; ms must be integer 0..2147483647. Missing/nonnumeric/nonfinite/fractional/out-of-range values reject without coercion. Zero is asynchronous too.

Native sandbox event-loop timers use no processes/threads/tool slots; prefer over bash sleep/JS busy waits. Waiting calls no model and uses no tokens but adds Run wall time; JS budgets pause, polling JS still accumulates, read/fetch retain costs.

Do not sleep waiting for background bash/agent/Run completion; Session delivers automatically. Without independent work, reply briefly without tools and Session waits locally for inbox then continues. Sleep remains for service-readiness probes: services may run indefinitely yet accept requests. Blocking sleep whenever tasks exist cannot distinguish cases, so system/tool/background notices explain without changing returns/timing/recording/replay.

Example: poll local HTTP status at most 10 times, 1 second between; retry non-200, but connection/other errors still reject/end Run:

```js
let ready = false;
for (let attempt = 0; attempt < 10; attempt++) {
  const result = await tools.fetch({url: "http://127.0.0.1:8080/health"});
  if (result.status === 200) {
    ready = true;
    break;
  }
  if (attempt < 9) await tools.sleep(1000);
}
if (!ready) throw new Error("service not ready after 10 checks");
console.log("service ready");
```

Normal Run completion drains scheduled sleep even without await; it is not cross-Run background work. Cancellation/JS timeout discards unexpired timers promptly. Top-level rejection drains issued tools but drops unexpired timers (no effects yet; continuations not begun). Cancellation checks stay ≤20 ms. Sleep uses standard tool timing/result-byte/recording/replay; replay settles recordings without waiting; [replay.md](replay.md).

## Long Runs automatically move to the background

Model Runs exceeding `[limits].run_background_after_ms` (default 10000) while waiting for tools/sleep automatically move wholesale to background with Session r1… ids. Current Steps receive explicit registration notices: captured output retained, final messages automatic; models can continue useful work without ps/log cat/tail/sleep/empty Runs/timeout reruns or premature redirected-log reads. Capture tests directly unless exceeding 16 MiB. Registration does not mean execution success. Continuous JS is not moved midway and retains JS budgets; waits/main-thread polling are about 20 ms.

Keep original Sandbox/Promises/arguments/results: `await tools.bash(...)` receives its normal command result (including a structured timeout), never an automatic Run ID. Drain, budgets, deadlines, capture stay unchanged. Capture pre/post-threshold console together, displayed once in final results; early notices contain no partial console.

Background Runs own cancellation, llm limits, changes, timing, recording buffers; Session agent/background-bash concurrency, ids, observations, usage stay shared. At most 8 automatic Runs independently of 8 background bash; at capacity new Runs wait foreground without failure/background queuing. Each Sandbox still executes ≤8 tools. Backgrounding consumes no extra Step; subsequent model requests consume Steps normally.

On completion, `session/output.zig` formats the Run result within budget and queues it in the Inbox with an unbudgeted `[background run rN finished]` header. Under `delivery = user`, unclaimed results are inserted as user messages. The registration notice and result each display once. Step-limit cleanup waits for delivery without more requests. Esc/SIGINT/SIGTERM, Turn failure, Session exit/switch cancel/join Runs/tools, cleaning bash groups; SIGKILL cannot clean up. tools.stop({id:"r1",reason:"Tests failed; inputs need changes"}) can stop another background Run, still delivering cancellation, never itself. No file/shell rollback.

### Waiting for background results

In root and forked Sessions, use `await tools.wait(['b1'])` to wait for a specific task in the same Turn, or `await tools.wait()` to wait for every pending non-detached task except the calling Run. This works with either delivery mode. It returns `{ ok:true, results:[{ id, kind, ok, output }], not_pending?:[id] }`. A result already queued can be claimed immediately; unknown or already delivered IDs go to `not_pending`. The `output` is the result text without its header line.

Claimed results are not delivered again. Each still gets a `background` event, and the delivery is logged with the consuming Run (or its eventual delivery if it had already moved to the background). A Run blocked in `wait` is never automatically moved to the background, and `wait` ends with the Run on cancellation.

A tool-free reply is a fallback and is how ordinary child Sessions wait. A successful empty Run with no output or host calls also triggers this fallback. If a non-detached result is pending, the Session stores the reply with `waiting:true`, displays a notice rather than a final answer, and waits locally for results or a user interjection before the next request.

### Delivery `tool`

DeepSeek drops all earlier `reasoning_content` whenever a new user message appears, so the DeepSeek Profile uses the `delivery = tool` [tuning](adr/0026-tuning.md). Other families default to `delivery = user`. `NIB_TUNE=delivery=user|tool` overrides the mode when starting a Session; the choice is logged in the header and never changes mid-Session.

- Unclaimed background results (same `[background … finished]` text and size limits as the user message) and user messages enqueued mid-Turn (header `[user message]`) are not inserted as user messages. After the Step's Runs finish, queued items are appended, in arrival order after the Run's own output, to the content of that Step's last tool message, so the next request carries them without a new user message. The same Step commit records the original Run output and the background deliveries. Background events and the provider message roles are unchanged.
- The Turn's first Step is unchanged: interjections queued before the Turn starts are still user messages.
- Fallback: a reply without a tool call (or a Step whose Runs were all empty) while results are pending keeps the `user` behavior: the Session waits locally and inserts a normal user message. An interjection that arrives when the reply has no tool call becomes a normal user message in the same way (or the next Turn).
- After a resume, a folded result appears inside the tool message it rode on rather than as a separate transcript entry.

All successful edit/write, including pre-background changes, belong to that Run; final events/log `completion.changes` retain operation counts/diffs. Temporary notices claim no changes. TUI background results show output/changes, including resume; child results aggregate them too. Bash changes remain excluded.

Runs share cwd/files, possibly concurrently. file_state mutex protects tables; path locks serialize individual operations, and write detects changes since latest Session observation. But other Runs update shared observations, so this is not per-script optimistic transaction isolation or complete semantic conflict detection. Bash ignores locks. After edit/write, rerun identical command/cwd to stop old bash under [supersession](tool-delegation.md#identical-commands-supersede-stale-execution), returning `{superseded_by}`; only matching bash stops, original continuations/effects remain. Reread/check current files as needed before processing results.

Exit never restores JS heaps/restarts commands; undelivered tasks resume as lost, committed results never redeliver. Replay does not reproduce wall-time transitions: locate original Step/Run, execute full scripts, compare final output, never early notices before final commit.

TUI original Runs show neutral → run background → rN for registration; final entries show source Run → rN, including resume. Superseded bash shows b1 superseded by b2 with neutral arrows/tree replacement ids, not failure.

## After-edit hooks

A failed configured `after_edit` hook adds `{"hook":{"command":"...","exit_code":1,"output":"..."}}` to its Run result. Exit code 124 denotes timeout. Complete captured output remains available until model-side rendering applies the normal Run display budget. Successful hooks add no result data. Commands run once per settled Run containing edit/write changes; child Sessions report their own hooks. Replay does not run hooks.

## MCP tools

`tools.mcp("server.tool", args)` returns `{ok, content, structured?, error?}`; `tools.mcp_schema("server.tool")` returns its full input JSON Schema. Servers must be enabled in configuration. Server/transport failures return data; malformed arguments reject. Text remains complete inside JS and uses the shared Run display budget. MCP images use the same image store and four-image limit as view; nonvision models get `[image omitted]`. Calls/results are recorded and replayed normally. Wire requests time out after 60 seconds (stdio discovery probe: two seconds); wire messages over 16 MiB fail without truncation. See [MCP tools](mcp.md).

## Repairing failed scripts

The model can call `rerun({base: "12:0", edits: [{old_text: "...", new_text: "..."}]})`.
A completed script failure includes its Session-scoped source reference: the 1-based
assistant Step ordinal and 0-based Run index, as in replay. Each edit must have
nonempty `old_text` matching exactly once. Each edit searches the copy left by the
previous edits. Rejected edits report their 1-based index in the submitted order
without echoing `old_text`, and execute nothing. Syntax errors can include a
bounded source-line excerpt with a caret when the column can be mapped accurately. Successful, pending, unknown and foreign
sources are rejected. Older logs without explicit source/terminal metadata cannot
provide bases.

This starts a new ordinary Run in a fresh Sandbox, from the beginning. Syntax and
runtime failures can be repaired; prior effects may repeat. The original source and
result remain unchanged. A failed repair gets its own reference. Local log metadata
stores the base, original arguments and full resolved source; model-visible arguments
stay unchanged. Resume resolves the same references, and offline replay executes the
recorded source against recorded tool results rather than applying the edits again.
