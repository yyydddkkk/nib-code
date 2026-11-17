# Compromise register

See [README.md](README.md#grounded-in-the-present-ready-for-the-future) for principles. Each item is a compromise for current conditions, not part of the design itself. Register new compromises first; when removal conditions hold, delete the code and strike out the entry.

## Model patches

Prompt patches are centralized in `src/session/prompt.zig`'s `patches`; each applies to all [Profiles](../CONTEXT.md) unless its `applies_to` set narrows it. Disable with `NIB_PATCHES_OFF=<id,...|all>` (child Sessions inherit the variable). Verification: disable temporarily, then compare signals using `scripts/stats.py --since` against comparable enabled-period data.

| id / name | Location | Reason | Signal | Removal condition |
|---|---|---|---|---|
| `json-escape` | System prompt, Writing scripts | Models often use template strings for text containing backticks, `${`, or backslashes, causing SyntaxError or altered content | stats error category `js_syntax` | Disabling causes no material increase in `js_syntax` |
| `no-shell-search` | System prompt, Writing scripts | Originally added because rg was absent and returned 127; ripgrep was installed on 2026-11-03, leaving only structured results and credential skipping as reasons | rg/grep bash calls, Run text-parsing errors, tools.grep usage | Disabled models choose reasonably between rg and tools.grep without materially more parsing errors; on removal, describe tools.grep's benefits as facts |
| `expected-continuation` | System prompt, Writing scripts | After successful Runs, models spend another Step on predictable checks/log reads, wasting a model round trip | Step/time share in stats `round_trips.mechanical_followups`; compare `none` with `["expected-continuation"]` (disabled) via `--group-by patches`, keeping other disabled patches identical | Disabled mechanical follow-up Step shares differ little from enabled shares, indicating the hint is no longer needed |
| Reflect reports evidence-backed problems only | `src/tui/reflect.md` | Concern that models invent problems to fulfill reflection; drafts publish automatically | Fraction of automatically submitted issues closed as invalid or duplicate | Further simplifying threshold wording does not increase false positives (template edits only; no switch) |

### expected-continuation baseline and measurement

After implementation review and before enabling the patch, `python3 scripts/stats.py --json` on local `~/.nib/sessions` found 180 Sessions (including children), 3404 Steps; 2849 adjacent candidate Steps after success, with mechanical follow-ups **442/2849 = 15.51%** and candidate-Step time **4,425,959/68,366,301 ms = 6.47%** (all 2849 candidates timed). Sample sources: complete recordings 1592, static extraction 1257, mixed 0; hit sources 280, 162, 0 respectively. Denominator: adjacent same-Turn Steps whose predecessor has at least one Run and all Runs explicitly succeeded, not all Steps; cancellation, filtering, and compaction replacements break pairs.

Measure with `python3 scripts/stats.py --since YYYY-MM-DD --group-by patches` (optionally `--json`). Reuse the conservative write-to-validation classifier, preferring actual tools and `args.command` from complete recordings, otherwise static extraction. Hits require only bash/read with all bash commands validating/checking status. Unclear dynamic/static extraction, compound shell, redirects, and git merge do not hit. Thus this baseline differs from manually counted 316/1757 (about 18%, about 16% of time), including different historical sample scope. Time-share denominator is total candidate-Step duration with `ms`, not model time. Old-log/group differences are signals, not direct causal evidence of patch effects.

## Value tunings

Variants live in `src/session/tuning.zig`; a Profile picks one per tuning, `NIB_TUNE=<tuning>=<variant>[,...]` overrides it for experiments, and the Session log header records the result (`stats.py --group-by tuning`). See [ADR 0026](adr/0026-tuning.md).

| tuning / variant | Model measured | Date | Problem and evidence | Result |
|---|---|---|---|---|
| `delivery`: `tool` for DeepSeek, `user` for the rest | deepseek-flash, effort max | 2026-11-13 | 30 Terminal-Bench 2.1 trials. DeepSeek drops all earlier assistant `reasoning_content` whenever a new user message appears (server side; nib sends it). nib inserted every finished background Run/bash/agent result as a `role: "user"` message at the next Step boundary, whether the model was working or waiting: 49 times, in Steps that were under 8% of all Steps but 36–41% of all uncached input tokens, and the model lost its reasoning chain each time (next request e.g. 98k to 64k tokens, almost entirely a cache miss). Raising the auto-background threshold only trades away parallel work: of 196 Steps taken while an auto-backgrounded Run was pending, 126 did real independent work. | Results ride on the next tool message and `tools.wait()` replaces ending the response, so no mid-Turn user message remains. Measured 2026-11-16 (same model and tasks, 10 trials per variant via `NIB_TUNE`): reasoning resets 16 → 1, their share of uncached input 41% → 5%, total uncached input 1.02M → 0.61M (−40%) with 284 vs 261 Steps; the model called `tools.wait()` 26 times. Pass rates were not comparable (verifier network failures). Recheck when the model changes; compare with `stats.py --group-by tuning` ([ADR 0025](adr/0025-model-profiles.md)). |
| `validation`: `none` for DeepSeek, `single` for the rest | deepseek-flash, effort max | 2026-11-13 | Ten tasks per arm compared the existing guidance, existing-tests-only guidance and no validation guidance. The maintainer selected the no-guidance variant on 2026-11-16. The later nib/Pi comparison used `single`, so it did not retest that variant. | DeepSeek no longer explicitly asks for builds/tests or a full validation pass; models may still validate, and project/user instructions still apply. `existing-only` remains available for comparison. Override with `NIB_TUNE=validation=single`, `existing-only` or `none`; recorded in the Session header. The single-attempt experiment does not establish a stable speed or quality gain. |

## Implementation compromises

| Name | Location | Reason | Removal condition |
|---|---|---|---|
| Subagent depth limit 1 | `src/tools.zig` (agent available only to root Sessions) | Prevent uncontrolled recursive spawning without cost budgets | Replace with budgets once budget limiting exists |
| `/undo` does not resume across Session instances | `src/tools/undo.zig`, `src/session.zig` | In-process stack avoids misusing interrupted/old-version snapshots after restart | Load snapshots once committed Turn/undo transactions have a persistent index and crash recovery |
| Stream idle timeout replaces the underlying HTTP reader's Io vtable | `src/provider/idle.zig` | `std.http.Client` lacks read timeouts; replacing `connection.stream_reader.io` depends on std internals and may break on Zig upgrades | Standard-library HTTP client supports read timeouts/deadlines |
| Reject bash command portions over 256 shell words | `src/tools/policy.zig` | Checker stores command words in a fixed buffer; heredoc bodies are excluded | Checker no longer needs a fixed buffer |

## Hardcoded policies

These are user budgets/preferences currently expressed as constants; they belong in `config.toml`.

llm/agent concurrency, call counts, input sizes, and Step limits are now configurable; see [config.md](config.md#limits). Steps no longer default to 50: omitted `max_steps` means unlimited; explicit range 1–100000, inherited by children from current effective configuration. The sandbox's 8-tool concurrency limit remains a thread-scheduling implementation detail.

| Name | Location | Current value | Removal condition |
|---|---|---|---|
| Concurrent background bash limit, rejecting excess | `src/tools/background.zig` (reuses `sandbox.tool_concurrency`) | 8 | Move to `[limits]` |
| Per-result recording limit; calls files have no total limit or rotation | `src/sandbox/record.zig` | 1 MiB | Move to configuration once storage budgets/cleanup settings exist |
| TUI undo snapshot quotas | `src/tools/undo.zig` | 8 completed edited Turns; 256 paths and 64 MiB original bytes per Turn; 16 MiB per file | Move to configuration with real quota needs and unified Session cleanup settings |
