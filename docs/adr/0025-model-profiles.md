# 0025: Model profiles

Status: accepted

nib was tuned against Codex only. On DeepSeek the same harness loses: in a ten-task
Terminal-Bench 2.1 run against Pi on deepseek-flash, nib passed 8 of 9 comparable
tasks to Pi's 9, used about 55% more input and 80% more output tokens, and timed out
three times while waiting on slow or blocked commands. Models differ in how they cache,
what they do with earlier reasoning, and which habits a prompt must correct, so one
fixed strategy cannot serve them all.

## Decision

Split model-specific behavior out of the core into one profile per model family:
Codex/GPT, DeepSeek, Claude, and a default. The profile is chosen from the model name,
not the provider, so a custom endpoint serving `deepseek-flash` gets the DeepSeek
profile. Unmatched models use the default, which holds only rules that help every
model. Codex is a family like any other, not the default. Profiles are code, not
configuration: users choose a model and nib follows.

A profile states only where it differs from the default, in three groups:

- **Context policy**: how a request is assembled. How background results and user
  interjections enter the history, how reasoning is replayed, whether system or tool
  changes are appended or rewritten, when to compact, and the Run display budget.
- **Behavior**: prompt patches tagged with the families they apply to, model facts the
  prompt states (such as caching), and thresholds for runtime nudges.
- **Request parameters**: thinking and effort mapping, output limits, transport.

Wire encoders under `provider/` stay per protocol and do not read profiles.

Family routing now records the recognized family separately from the applied Profile. Gemini is recognized but uses `default`, as do unknown models. The existing `codex` Profile label denotes the GPT family, not the Codex Provider. No per-model routing is needed. See [Model Profiles](../model-profiles.md) for ownership, evolution, and how the selected strategy reaches the runtime and prompt renderer.

## Evidence rule

Every profile entry follows the existing patch discipline in
[compromises.md](../compromises.md): a recorded problem, the evidence, an environment
switch that turns it off, and a before/after comparison on that family's regression
set. Entries without a measured effect are removed. Model upgrades trigger a recheck.

Tuning is judged by cost per task (uncached input, cached input and output, each at the
provider's price), pass rate, wall time and Steps. Cache hit rate is diagnostic only:
it rewards long contexts and small Steps. Harnesses at 98–99% hit rates on DeepSeek
lose their cache at the same turn boundaries nib does; their contexts are simply four
times longer.

The regression set is the ten Terminal-Bench 2.1 tasks outside the FrontierHarness
selection, run through Harbor, plus the existing nib-bench tasks. Nothing is tuned to a
task; a change must be a general behavior. Paid runs are small and approved per run.

## Findings this rests on

- Switching reasoning effort empties the prompt cache on both Codex and DeepSeek. The
  per-Step effort declaration (`run({effort})`, `// @run`) saves less than the misses
  it causes and is removed outright rather than made per-model.
- DeepSeek drops earlier assistant reasoning whenever a new user message appears, on
  both Chat Completions and Messages. The cache then breaks back to the previous turn's
  first reply. At a Turn start this is unavoidable. Mid-Turn, nib causes it itself by
  inserting background results and interjections as user messages; the DeepSeek
  profile will deliver them without a new user message.
- In nib's DeepSeek logs, 45% of uncached input was avoidable: 22% at Turn starts and
  23% mid-Turn, the latter from effort switches and inserted user messages.

## First steps

1. Remove per-Step effort scheduling.
2. Fix commands that never return because a started daemon keeps stdout open.
3. Tell the model how long a background task has run when it waits on one, with the
   threshold in the profile.
4. Add the profile type and resolution; move the Codex-only cache fact into the Codex
   profile.
5. Audit the base prompt line by line and move Codex-only rules into the Codex profile;
   compare on DeepSeek with and without them.
6. Deliver background results and interjections without a mid-Turn user message for
   DeepSeek. Done as the `delivery = tool` [tuning](0026-tuning.md): results ride on the
   next tool message and `tools.wait()` replaces ending the response; measured against
   the `user` variant with `stats.py --group-by tuning`.
7. Add the uncached-input breakdown (inherent, Turn start, mid-Turn, with causes) to
   `scripts/stats.py`.

## Not decided

Whether `delivery = tool` beats `user` on cost is settled by experiment. Claude's profile
waits for data.
