# 0026: Tuning

Status: accepted

nib corrects model habits with prompt patches: each has an id, applies to a set of
[Profiles](0025-model-profiles.md), can be turned off with `NIB_PATCHES_OFF`, and is
recorded in the Session log so `scripts/stats.py` can compare periods with and without it.
That discipline is what lets nib tune per model family without the prompt turning into
an untestable pile. It has three gaps:

- A patch is a single sentence that is either on or off. Real questions have several
  answers: Codex does well with "finish everything, then validate once", while on
  DeepSeek the same sentence makes the model write test scripts and install toolchains,
  doubling tool calls against Pi. Expressing alternatives as combinations of on/off ids
  is clumsy and lets incompatible combinations exist.
- Patches are appended after the base prompt. A sentence that belongs in the middle of
  a bullet has to be split out and reworded to stand alone.
- Prompt text is only one kind of model-specific choice. How results are delivered
  to the model, compaction timing, and runtime nudges differ by family
  too, but they are plain constants or configuration with no switch, no log record and
  no evidence trail.

## Decision

Introduce **Tuning**: every model-specific choice nib makes is a named tuning with a
small set of variants, and a Profile is a choice of variant for each tuning. Prompt
patches become one kind of tuning.

- **Kinds.** A *prompt* tuning fills a named slot in the system template
  (`{validation}`, `{background}`); each variant is the slot's text, possibly empty.
  A *value* tuning is a number or enum read by runtime code
  (`delivery`). Further kinds are added when a real tuning needs one.
- **Defaults.** Each tuning has a default variant; a Profile overrides only where its
  family differs. Unmatched models get the defaults, which hold only what helps every
  model.
- **Overrides for experiments.** `NIB_TUNE=<tuning>=<variant>[,...]` replaces variants
  for one process and its child Sessions. Together with `NIB_PATCHES_OFF`, it supports
  measurement and diagnosis, not persistent user customization. There is no Tuning
  section in `config.toml` or user-defined Profile. Users still choose their model,
  effort, permissions, and budgets, and give project instructions in `AGENTS.md`.
- **Benchmark baseline.** Use the shipped Profile with both experiment switches
  unset for default benchmark results. Label and report runs with overrides
  separately; they can test a candidate default but are not results for the
  shipped Profile.
- **Fixed per Session.** Variants are resolved once when a Session starts and stored in
  the log header; resumed Sessions keep them. The system prompt therefore never changes
  mid-Session and never breaks the prompt cache.
- **Recorded and grouped.** The log header records every tuning's variant, so
  `stats.py --group-by tuning` and Harbor comparisons group runs without bookkeeping
  outside the log.
- **Evidence.** A variant becomes a default only with a recorded comparison: the
  problem, the experiment (model, task set, runs), and the result. Each default records
  the model it was measured on; when the resolved model differs, tests or `stats.py`
  flag the tuning for recheck. Variants without a measured effect are removed.
  `docs/compromises.md` keeps the register.

`NIB_PATCHES_OFF` stays as an alias that selects the empty variant of the named prompt
tunings until existing measurements no longer need it.

## Rollout

1. Done: the `validation` slot has `single` (the original wording), `existing-only`
   and `none` variants. DeepSeek defaults to `none` following the maintainer's selection;
   other families retain `single`. The choice is independent of `delivery` and both
   are recorded and restored together.
2. Move the existing patches (`json-escape`, `no-shell-search`,
   `expected-continuation`) into prompt tunings with on/empty variants.
3. Make `delivery` (`user`, `tool`) the first value tuning; DeepSeek uses `tool`. A raised
   `run_background_after_ms` was measured and rejected: it gives up parallel work instead
   of fixing how results are delivered.
4. Add the model-change recheck.

## Not decided

Whether tool descriptions and request parameters (thinking mapping, output limits)
become tuning kinds is decided when the first family needs a different value.
