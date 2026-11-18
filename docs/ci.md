# CI

CI runs on pull requests, pushes to `main`, and manual dispatches. Feature branches use a PR (including a draft PR) or a manual run, so a push to an open PR does not start a duplicate suite. New commits cancel older runs for the same ref. Tag pushes use the separate release workflow.

Unit tests run on Linux and macOS. Each platform builds its own Debug executable; its e2e jobs wait only for that platform's build and test discovery. Linux e2e can start while macOS is still building. The shared e2e workflow downloads the platform artifact, runs every test in its shard even after a failure, and uploads per-script failure logs.

`scripts/ci_matrix.py` discovers the deduplicated test list from `AGENTS.md`. Linux runs every script in its own job. macOS keeps the existing portable subset in four sequential shards; Linux process-fixture and Linux-calibrated PTY tests remain Linux-only. No test assertions or timing limits are changed by sharding.

## Scheduling estimates

`.github/ci-e2e-seconds.json` contains median Linux e2e test-step durations in seconds from these successful runs on 2026-11-17:

- [44058280793](https://github.com/yyydddkkk/nib-code/actions/runs/44058280793)
- [44056767317](https://github.com/yyydddkkk/nib-code/actions/runs/44056767317)
- [44055291456](https://github.com/yyydddkkk/nib-code/actions/runs/44055291456)

These are initial scheduling weights for macOS, not measured macOS per-script times or performance assertions. Zero-second samples are rounded up to one second. New scripts receive a 10-second estimate and are included automatically. Stale entries do not select extra tests.

Portable scripts are sorted longest-first and assigned to the currently lightest shard, with deterministic tie-breaking. E2E logs print each script's elapsed seconds; use several subsequent macOS runs to refresh the estimates when the balance drifts. Do not lower test timeouts to fit these weights.

Local checks for CI-only changes:

```sh
python3 tests/test_ci.py
actionlint
git diff --check
```
