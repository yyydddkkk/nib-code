# CI

| Trigger | Checks |
|---|---|
| Normal PR, including draft PRs | Tooling checks, full Linux/macOS validation, and `CI gate`. |
| Release-metadata-only PR | Tooling and release-metadata checks, then `CI gate`; no application builds, unit tests, or e2e tests. |
| Push to `main` | No automatic CI run after merge. Application changes go through PR CI, not direct pushes. |
| Manual `CI` run on a selected branch or tag, including `main` | Full validation and `CI gate`; no base comparison or metadata shortcut. |
| Push of a `v*` tag | Separate `Release` workflow: version/tag and notes checks, platform builds, checksums, installation smoke checks, and publication. |

Feature-branch pushes do not separately trigger CI. New runs cancel older runs for the same workflow and ref. Use **Actions → CI → Run workflow** or `gh workflow run ci.yml --ref main` to deliberately validate `main` again. These triggers remove the duplicate post-merge suite and the wait for application tests on release-metadata-only PRs; they do not make individual tests faster.

**Merge and direct-push policy.** Wait for a green `CI gate` for the PR revision being merged. Direct application pushes to `main` are not a normal path. If a maintainer approves an exception, push the proposed commit to a separate branch, dispatch full CI there, and verify that it passed on the exact SHA before pushing that SHA to `main`. Without branch protection, this is a maintainer policy, not a technical barrier. To enforce the normal path, configure `main` to require a PR and the `CI gate` check; use that aggregate check instead of any individual unit, build, or e2e checks as required contexts. Repository settings are not managed by this workflow.

## Release metadata

The classifier compares the PR head to the merge base, and the pinned PR merge result to its base parent. Both diffs must contain only the package `.version` value and its matching `docs/releases/<version>.md` note. All other manifest bytes must be unchanged. The new version has stable `X.Y.Z` syntax, and the UTF-8 note must have matching English and Chinese headings and nonempty sections with a `---` separator. Review the translations in the PR; CI only checks their structure.

Dependency edits, mixed or unknown changes (including notes without a version edit), and unavailable or mismatched comparisons take the full path. A recognized version-only attempt with invalid metadata also takes the full path and fails the gate with a diagnostic; repair the metadata rather than relying on a passing test suite. The workflow is not skipped at the trigger level, so the same gate resolves for both paths.

## Full validation

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
python3 tests/test_release_metadata.py
python3 tests/test_dev_install.py
actionlint
git diff --check
```
