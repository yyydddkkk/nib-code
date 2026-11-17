# nibcode documentation

These documents are **reference and guidance, not rules**. They record why choices were made, without preventing better choices later.

## Reading and writing these documents

1. **ADRs record reasons, not commands.** Each states the decision, rationale, confidence, and reconsideration conditions. Overturning a decision does not require persuading the document; check whether its reconsideration assumptions still hold.
2. **Date facts and cite sources.** Distinguish measurements, primary sources (official docs/source), secondary sources, and inference. Secondary sources and inferences may be wrong.
3. **Avoid “must” and “forbidden” in docs.** Tests enforce actual constraints. Documented numbers are observations; large changes warrant thought, not prohibition.
4. **Code and measurements decide; docs explain.** Identify discrepancies and update or retire docs in the same change. Stale documentation is worse than none.
5. **Keep it short.** Aim for an ADR within one screen. Longer documents are more easily mistaken for specifications.

These principles also apply to agents: documentation is background; raise conflicts with evidence rather than following it blindly. Published documentation and release notes are written in English.

## What we mean by minimalism

Minimalism means elegant design and architecture, not rigid line counts. We judge it by:

- **Few concepts, each with one responsibility.** Session, Turn, Step, Run, and Tool have clear boundaries (see [CONTEXT.md](../CONTEXT.md)). Before adding a concept, ask whether existing ones suffice.
- **Deep modules.** Simple interfaces hide complexity. For example, the UI needs only `Session.turn`, `Session.compact`, and an event Sink.
- **One definition per thing.** Tool names, model-facing descriptions, and implementation entry points share one table in `tools.zig`; descriptions are generated from it, implementations live under tools/.
- **Consistent language.** If models write JS, their interface descriptions also use JS.
- **No design for absent needs or special cases without evidence.**

Line count is only an observation: sudden growth warrants design review, but minimizing it is not itself the goal.

## Grounded in the present, ready for the future

nib targets increasingly capable models: provide facts and capabilities without making judgments for them. Ask of a design: would a perfect model still need this?

What remains belongs to the design: facts models cannot see (limits, costs, timing, truncation, inputs actually received on errors), capability extensions (llm, agent, per-Step effort, interjections), boundaries (irreversible/external operations, credentials, untrusted external content), user policies (budgets, limits, automatic publication), and corrections to stale information (e.g. a Run failure or user interjection invalidates an earlier effort reduction).

Present-day compromises are valuable but should be identifiable, measurable, and removable. Three categories: model patches (current model mistakes), implementation compromises (our implementation needs improvement), and hardcoded policies (values users should configure). Register each in [compromises.md](compromises.md), with location, reason, signal, and removal condition; unregistered compromises do not enter code. Prompt model patches live in `src/session/prompt.zig`'s patches, disabled through `NIB_PATCHES_OFF` to compare continued necessity using scripts/stats.py.

Tool descriptions and system prompts state facts and costs for models to weigh, without prescribing when to use capabilities.

## Index

- [principles.md](principles.md): product principles — focused, small and refined, quiet, together
- [CONTEXT.md](../CONTEXT.md): shared terminology
- [adr/](adr/): architecture decision records
  - [0001 Zig, from scratch](adr/0001-zig-from-scratch.md)
  - [0002 Expose only run(code): JS in QuickJS](adr/0002-run-code-only.md)
  - [0003 Fresh sandbox per Run](adr/0003-stateless-runs.md)
  - [0004 Two isolation layers](adr/0004-two-layer-isolation.md) (language isolation plus an opt-in OS write sandbox: Landlock / sandbox-exec)
  - [0005 One process per Session](adr/0005-process-per-session.md)
  - [0006 No approvals; host rejection of dangerous commands](adr/0006-deny-dangerous-commands.md)
  - [0007 Stable system; complete-Step compaction](adr/0007-context-compaction.md)
  - [0008 Thinking models; deepseek-flash default](adr/0008-thinking-models.md)
  - [0009 Concurrent tools with JS ordering](adr/0009-concurrent-tools.md)
  - [0010 Subagents: independent nib subprocesses](adr/0010-subagents.md)
  - [0011 One Provider interface, two wire protocols](adr/0011-provider-wire-protocols.md)
  - [0012 Native Zig grep, glob, and fetch](adr/0012-search-and-fetch-tools.md)
  - [0013 tools.llm: lightweight single-step map](adr/0013-llm-functions.md)
  - [0014 Session background tasks and stop by id](adr/0014-session-background-jobs.md)
  - [0015 Agent fork: parent context reuse](adr/0015-agent-fork.md)
  - [0016 New identical commands supersede stale bash](adr/0016-superseded-bash.md)
  - [0017 Codex WebSocket default, disposable continuation](adr/0017-codex-websocket.md)
  - [0018 Codex custom Run reuses execution/history](adr/0018-custom-run.md)
  - [0019 Skills: index in system, read on demand](adr/0019-skills.md)
  - [0020 Providers are data; at most three wire protocols](adr/0020-providers.md)
  - [0021 Images: attach by path or clipboard, store by reference, view separate from read](adr/0021-images.md)
  - [0022 Provider sign-in: /provider, credential store, nib-owned Codex OAuth](adr/0022-provider-sign-in.md)
  - [0024 Opt-in MCP tools](adr/0024-mcp-tools.md)
- [ask-json.md](ask-json.md): ask --json NDJSON events, progress, usage
- [session-log.md](session-log.md): logs, resume/cancellation, timing, measurement definitions
- [undo.md](undo.md): per-Turn TUI edit/write undo, conflict rejection, quotas, recovery boundaries
- [replay.md](replay.md): recording, offline Run replay, diagnostic scripts, privacy boundaries
- [reflect.md](reflect.md): read-only reflection, saved answers, automatic issue publication
- [mcp.md](mcp.md): opt-in servers, context index, transports, protocol detection, lifecycle, sandbox, and limits
- [config.md](config.md): `NIB_HOME`, files, environment, precedence, effort persistence
- [codex.md](codex.md): local Codex login, configuration, credential boundaries
- [run-output.md](run-output.md): data integrity, explicit limits, Run display budgets, execution timeouts
- [tool-delegation.md](tool-delegation.md): read / llm / agent choices, interfaces, delegation implementation
- [compromises.md](compromises.md): model patches, implementation compromises, hardcoded policies
- [releases/](releases/): release notes ([0.4.0](releases/0.4.0.md), [0.3.0](releases/0.3.0.md), [0.2.0](releases/0.2.0.md))

## Choices without ADRs

These are easily reversible; a note suffices:

- **Unified user directory `NIB_HOME` (default ~/.nib).** Like ~/.codex / ~/.claude, keep global instructions, nonsecret configuration, and Sessions together for discovery/backup. No XDG paths or automatic migration. `config.toml` uses a small custom TOML subset rather than a dependency for a few scalar keys. No API keys/tokens in editable, backed-up configuration; Codex owns its login. TUI `/effort` saves confirmed choices automatically, atomically updating top-level effort while preserving other lines; default deletes the key, CLI overrides do not persist. Defer project configuration and another merge policy; use `AGENTS.md` for project conventions. Format/precedence: [config.md](config.md).
- Providers support Codex Responses (default, gpt-6.1-sol) and Chat Completions (DeepSeek); see [0011](adr/0011-provider-wire-protocols.md).
- TUI uses libvaxis. / commands: `/help`, `/new`, `/resume <id>`, `/compact`, `/effort [level]`, `/copy`, `/reflect [focus]`, `/js <code>`, `/tasks`, `/stop <id>`, `/undo`, `/status`, defined in one `src/tui/commands.zig` table generating help, command candidates, and argument candidates. Typing / lists prefix matches above input: ↑↓ select, Tab completes, Enter executes (commands needing arguments complete first and wait), Esc closes. `/resume` lists Sessions with user messages in the current directory, newest first; empty Sessions are excluded, also by -c. `/help` and `/copy` work during Turns; `/copy` uses terminal OSC 52 and has no effect without terminal support.

  Layout: transcript, one reserved status row, / menu, rounded input flush with the last row, hints. The status row holds the activity line when busy, browsing history, or showing temporary feedback, and is blank otherwise; while it has text, a blank row above it separates it from the transcript. Busy shows spinner, phase (waiting for model / generating response / writing Run / running tools / waiting for background / retrying / compacting), cumulative Turn time, and Esc to cancel; history shows ↑ history · PgDn to return; copy feedback shares the row. These states may coexist. Input uses at least one line and at most 1/3 screen height, scrolling internally to keep the cursor visible; empty input shows muted Message nib · / for commands. The bottom border shows model and context percentage from available usage, with concise Turn-footer statistics; detailed timing, Steps, and cache data live in /status. Update after each request's usage and complete Step commit, without waiting for Turn end; ctx estimates latest committed context and refreshes after compaction. Do not infer unreported tokens from streamed text. Omit fields right-to-left when space runs out, truncating model names only if needed and preserving corners. Below 8 rows hide hints; below 6 rows or 8 columns degrade to › . Hints list only implemented send/newline/command/ctrl+o actions.

  User messages use ›, a left blue bar, and subtle shading; body text keeps default foreground without whole-message bold. Blend terminal-reported backgrounds slightly with blue for light/dark themes; without reports, retain the bar. Messages over 5 lines or 800 Unicode characters collapse by default to their first line plus muted … +N lines; truncate the first line to available columns using identical live/replay rules, opened by click like Runs. Reasoning is hidden from the transcript, including restored history, without affecting model reasoning, logs, or thinking activity. Runs keep stable parent titles, summarize actual calls, avoid duplicate read/search paths in titles, and list changes separately, e.g. src/a.zig +3 −1. Click a Run (Ctrl+O for the latest) expands Changes / Result / Script; long diffs state preview scope (at most 60 lines). Subagent trees always remain below Runs, independent of expansion, one row per task with id, prompt summary, state, Step, and latest tools/files, truncating rather than wrapping on narrow screens. Final states persist after Run completion; restored history keeps recorded background/supersession states.

  Changes accumulate before/after line differences for each successful edit/write in this Session, summing by path; edits later reverted count in both directions. No reread at Run end. Bash, external processes, and child Sessions (including background tasks) do not contribute to foreground Run changes, but may appear as unchanged context in later operations. Diffs concatenate operations, capped at 200 change/context lines per path; see [ask-json.md](ask-json.md). Ordinary Run changes are not logged and disappear on resume; automatic background Run changes persist with final background messages (see [run-output.md](run-output.md#long-runs-automatically-move-to-the-background)).

  Mouse reporting is enabled: wheel scrolls the transcript; left drag selects continuous text with inverse highlighting, anchored to historical entries/lines. Holding left while scrolling extends selections across screens; release copies and shows copied N chars. Reverse drag works; wide characters copy once, trailing spaces are trimmed per line, and screen-line newlines remain. Copy sends OSC 52 first (including SSH); in graphical Sessions also writes via stdin to `wl-copy` on Wayland, otherwise xsel/xclip on X11. Missing/failed local tools leave OSC 52 attempted; terminals may disable or lack it. Clicks, keys, and resizes clear selection; scrolling clears released selections. Transcript drags pause bottom following and copy the complete historical range, including offscreen lines; input/other regions use screen coordinates. PgUp moves half a screen, PgDn returns directly to bottom from history, shift+↑↓ scrolls 3 lines. Browsing anchors the viewport to the top entry so new content does not move it; bottom restores following.

  Enter sends ordinary messages, immediately clearing input even during a Turn and showing the user message with muted queued. Session inserts queued messages in submission order before the next Step's request, after prior tool results, then removes markers without interrupting active requests/Runs. After a final answer, remaining messages join with blank lines as the next Turn. Esc returns uninserted messages joined by blank lines to input, followed by any existing draft, awaiting user resubmission; failures do likewise without automatic retry. Inserted messages log as ordinary user messages and restore in order; ask --json has no interactive queue and unchanged events. shift+enter / alt+enter / ctrl+j insert newlines; pasted carriage returns never submit. Bracketed pastes over 5 lines or 800 Unicode characters become [Pasted #1 · 214 lines] blocks (single lines show characters), numbered increasingly within each draft; short pastes insert directly. Left/right movement skips blocks atomically; Backspace/Delete removes whole blocks, never editing inside labels. Editor stores label byte ranges and separate originals without private-use Unicode codepoints; matching ordinary text is not mistaken for a block. Sending expands originals, so model/log receive originals only. ↑ on the first line and ↓ on the last browse in-process history; live drafts preserve blocks and numbering. Restored long user messages each become one block; short messages remain verbatim, without separate cross-process history. Assistant rendering supports basic Markdown: fenced code including unclosed fences, inline code, bold, headings.
- Session persistence, resume, and project instructions are implemented (2026-11-01, primary source: `src/session.zig`, `src/session/log.zig`, `src/session/instructions.zig`, `src/main.zig`). Complete Steps sync to disk. See [session-log.md](session-log.md); run zig build, then `python3 tests/test_session.py` for e2e verification. `python3 tests/test_interjections.py` uses PTY/local mocks for interjections, automatic continuation, Esc restoration, and logged interjection resume.

## Deferred ideas

Ideas not implemented now. Each records why deferred and when to reconsider, avoiding both forgetting and mistaking them for committed plans.

- **Streaming execution / speculative prefetch.** Task-provided sample: 114 Steps, 3708 seconds total. Read-only prefetch could save at most about 1.6 seconds (0.04%); median run argument generation 0.7 seconds; read/grep nearly free; slow bash mostly follows edit. Benefits do not justify partial argument parsing, dependency decisions, and cancellation/side-effect boundaries yet. Reconsider only workloads combining long code generation with early slow read-only tools. Fields/definitions: [session-log.md](session-log.md).

Second-phase input plans:

- **Withdraw individual uninserted messages.** Step-boundary interjections, end continuation, and Esc restoration exist; individual queued-message selection/withdrawal awaits real demand for finer control.
- **@ file references.** Reuse / menu and `walk.zig`, inserting paths only. First finish compatibility between the single candidate menu and new layout, then add triggers/path filters.
- **Cross-process input history `~/.nib/history.jsonl` and ctrl+r search.** Current scope is in-process drafts and Session-log resume. Persistent history needs sensitive-input handling, retention, and multiprocess appends; search needs separate interaction state, designed together in phase two.
- **ctrl+g edits drafts through $EDITOR.** Needs terminal suspension/restoration, temporary cleanup, and reimport after paste expansion; integrate once the draft model stabilizes in phase two.

Run tool concurrency, nib ask --json, and `tools.agent` are implemented; see ADR 0009–0010, [ask-json.md](ask-json.md), and [tool-delegation.md](tool-delegation.md). After zig build, `python3 tests/test_session.py` checks resume, machine events, subagent concurrency/depth/usage/cancellation, and startup overhead, entirely with local mocks and no real keys. Other deferred alternatives live in their ADRs: daemon ([0005](adr/0005-process-per-session.md)), cross-Run variables ([0003](adr/0003-stateless-runs.md)), hybrid native calls and Python runtime ([0002](adr/0002-run-code-only.md)).

## Measurements

Observations, not goals or prohibitions. Numbers change; prefer latest measurements and date updates.

Use `python3 scripts/stats.py` for read-only real-log statistics, accepting one or more files/directories. --cwd matches working directories exactly; `--since YYYY-MM-DD` selects each record's at from local midnight inclusively. Resuming old Sessions does not count timestamped historical Steps in the new interval; missing/invalid at falls back to file mtime and may mix in history. Text/JSON `time_filter` report timestamp/fallback record counts and fallback complete-Step counts; exclude headers, repairs, and compaction replacements, but include diagnostics and interruptions. Before/after prompt/tool changes, run `python3 scripts/stats.py` snapshot-directory --json > before.json / `after.json` on snapshots with matching cwd/model/task type. Compare Run failure rate, error categories, average Steps/time, tokens/cache hits, checking sample size and field coverage.

Every new record has at (Unix milliseconds at append, not request start): headers, complete Steps, diagnostics, interruptions, replacements. Resume accepts old records without it. Complete Steps optionally carry usage (this request's prompt/completion/cache-hit tokens, without recounting children), ms (monotonic request start through retries and all Runs, excluding compaction/log writes), and run_results: [{tool_call_id, ok}]. Old records replay unchanged without zero-filled fields; failure rates use explicitly classified Runs only, listing unknown old statuses separately. Turn counts include Turns with selected nondiagnostic records; average Steps uses selected complete Steps. Average Turn time uses only finished Turns with all Steps selected and timed; Turns crossing filter boundaries are excluded. Session counts include selected headers or nonreplacement records. Compaction replacements are not new Turns/Steps and do not erase historical work.

Tool/bash statistics estimate JS/static-shell call sites, not actual loop/dynamic execution counts. Errors count diagnostic signatures per Run (categories may overlap), with interruptions separate; source/read bodies are not matched as failures. Caught JS tool errors and bash exit_code 127 may classify without failing a Run. Synthetic-log tests: `python3 tests/test_stats.py`; real Step metadata/mock counts: tests/test_session.py.

| Item | Measurement | Alert threshold | Method |
|---|---|---|---|
| Source lines (`src/` + `build.zig`, including tests) | 3766 (2026-11-01, after concurrency, NDJSON, subagents) | — | `wc -l build.zig src/**/*.zig` (zsh) |
| TUI frame draw, 5000 entries, 100×24 | Bottom following 102.5 → 29.7 µs; 1200 lines up 1149.5 → 57.2 µs (2026-11-01, ReleaseFast, before → after height cache) | — | After warmup, median of 5 group means, 32 frames/group, draw only (feat/tui-polish report) |
| nib js '1+1' mean including startup | 1.6 ms (2026-11-01, ReleaseFast) | — | Average of 100 iterations |
| Tool Promise.all / successive await: two sleep 0.3 | 307 / 611 ms (2026-11-01, Debug) | — | `src/tools.zig` tests, ADR 0009 |
| Child startup to NDJSON start (including log sync, no TLS) | Debug median 11.82 ms; ReleaseFast median 1.30 ms (2026-11-01) | — | `tests/test_session.py`, 10 runs, ADR 0010 |
| Above command peak RSS | 3.7 MB (2026-11-01) | — | `/usr/bin/time -f %M` |
| Binary size (ReleaseFast, stripped) | 1.9 MB (2026-11-01) | — | ls -l after strip |
| Idle TUI PSS (one Turn, no TLS) | 3.08 MB/process, 30.8 MB for 10 (2026-11-01, ReleaseFast) | — | 10 TUIs each completing one local-mock Turn; read `/proc/<pid>/smaps_rollup` Pss |
| One HTTPS request peak RSS (including TLS) | 7.6 MB (2026-11-01, ReleaseFast) | — | `/usr/bin/time -f %M nib ask hi` (invalid key, 401) |

See [tui-ux.md](tui-ux.md) for background-task management, waiting phases, and recovery notices.
