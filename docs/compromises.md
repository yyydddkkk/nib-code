# Compromise register

See [README.md](README.md#grounded-in-the-present-ready-for-the-future) for principles. Each item is a compromise for current conditions, not part of the design itself. Register new compromises first; when removal conditions hold, delete the code and strike out the entry.

## Model patches

Prompt patches are centralized in `src/session/prompt.zig`'s `patches`; each applies to all [Profiles](../CONTEXT.md) unless its `applies_to` set narrows it. Disable with `NIB_PATCHES_OFF=<id,...|all>` (child Sessions inherit the variable). Patches with `default_on = false` are opt-in: enable with `NIB_PATCHES_ON=<id,...>`; `NIB_PATCHES_OFF` wins when both name an id. The session header records `patches_off` and `patches_on`. Verification: disable temporarily, then compare signals using `scripts/stats.py --since` against comparable enabled-period data.

| id / name | Location | Reason | Signal | Removal condition |
|---|---|---|---|---|
| `json-escape` | System prompt, Writing scripts | Models often use template strings for text containing backticks, `${`, or backslashes, causing SyntaxError or altered content | stats error category `js_syntax` | Disabling causes no material increase in `js_syntax` |
| `no-shell-search` | System prompt, Writing scripts | Originally added because rg was absent and returned 127; ripgrep was installed on 2026-11-03, leaving only structured results and credential skipping as reasons | rg/grep bash calls, Run text-parsing errors, tools.grep usage | Disabled models choose reasonably between rg and tools.grep without materially more parsing errors; on removal, describe tools.grep's benefits as facts |
| `expected-continuation` | System prompt, Writing scripts | After successful Runs, models spend another Step on predictable checks/log reads, wasting a model round trip | Step/time share in stats `round_trips.mechanical_followups`; compare `none` with `["expected-continuation"]` (disabled) via `--group-by patches`, keeping other disabled patches identical | Disabled mechanical follow-up Step shares differ little from enabled shares, indicating the hint is no longer needed |
| `run-build-test` | System prompt, patch list | The base prompt says one Run can read and edit; this patch adds that it can then build and test. On Terminal-Bench with deepseek-flash, nib writes extra test scripts, installs toolchains to verify and revalidates repeatedly, using about twice the tool calls of Pi, whose prompt has no verification guidance | Tool calls and Steps per Turn, extra test-script writes, toolchain installs, via `--group-by patches` | Disabling does not change Steps per Turn or task success |
| `single-validation` | System prompt, patch list | Models run full builds/tests piecemeal; this asks for one validation after implementation and fixtures are complete. Same Terminal-Bench evidence as above | Same as `run-build-test`; also builds/tests per Turn | Disabling does not increase repeated full validations |
| `existing-tests-only` (opt-in, off by default) | System prompt, patch list | Candidate to curb verification overhead: run the project's existing tests, no new test scripts or toolchain installs unless asked | Same as above; compare `["run-build-test","single-validation"] on=["existing-tests-only"]` against `none` on the same model/tasks | Enable by default if it reduces tool calls without lowering task success; delete if it does not |
| Reflect reports evidence-backed problems only | `src/tui/reflect.md` | Concern that models invent problems to fulfill reflection; drafts publish automatically | Fraction of automatically submitted issues closed as invalid or duplicate | Further simplifying threshold wording does not increase false positives (template edits only; no switch) |

Validation A/B on DeepSeek, no rebuild: `NIB_PATCHES_OFF=run-build-test,single-validation NIB_PATCHES_ON=existing-tests-only nib ...` versus the default; compare with `python3 scripts/stats.py --group-by patches`, keeping model, effort and tasks identical.

### expected-continuation baseline and measurement

After implementation review and before enabling the patch, `python3 scripts/stats.py --json` on local `~/.nib/sessions` found 180 Sessions (including children), 3404 Steps; 2849 adjacent candidate Steps after success, with mechanical follow-ups **442/2849 = 15.51%** and candidate-Step time **4,425,959/68,366,301 ms = 6.47%** (all 2849 candidates timed). Sample sources: complete recordings 1592, static extraction 1257, mixed 0; hit sources 280, 162, 0 respectively. Denominator: adjacent same-Turn Steps whose predecessor has at least one Run and all Runs explicitly succeeded, not all Steps; cancellation, filtering, and compaction replacements break pairs.

Measure with `python3 scripts/stats.py --since YYYY-MM-DD --group-by patches` (optionally `--json`). Reuse the conservative write-to-validation classifier, preferring actual tools and `args.command` from complete recordings, otherwise static extraction. Hits require only bash/read with all bash commands validating/checking status. Unclear dynamic/static extraction, compound shell, redirects, and git merge do not hit. Thus this baseline differs from manually counted 316/1757 (about 18%, about 16% of time), including different historical sample scope. Time-share denominator is total candidate-Step duration with `ms`, not model time. Old-log/group differences are signals, not direct causal evidence of patch effects.

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
