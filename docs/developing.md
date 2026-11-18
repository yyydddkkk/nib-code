# Developing and using nib-dev

## Feature development

Edit and run targeted checks in a feature worktree. For unmerged changes, build and run `./zig-out/bin/nib` in that worktree. Open a PR for the full Linux/macOS [CI gate](ci.md); merging it does not start the same suite again on `main`.

## Daily use from local main

Make sure this repository's **local `main`** already contains the merged changes you want. Run this from the root of any worktree containing the script, on Linux or macOS with Git, Zig 0.17, Bash, and Python 3:

```sh
./scripts/dev-install.sh
```

From another directory, invoke `/path/to/any/nib-worktree/scripts/dev-install.sh`. The script finds the repository from its own location, resolves `refs/heads/main` once, and checks out that exact commit in a temporary, unregistered Git directory. `main` does not need to be checked out anywhere. Neither feature-branch commits nor uncommitted files in any worktree enter the build. Local `main` may lag `origin/main`; the script does not fetch or synchronize either ref and fails if local `main` is missing. Zig may download the committed build's declared dependencies if they are not cached.

The default is Debug at `~/.local/bin/nib-dev`. Use `--release-fast` for ReleaseFast or `--bin-dir /path/to/bin` to choose a different directory (the name is always `nib-dev`). The script prints the commit, mode, and destination. It builds in isolation, then stages and checks the executable with `--version` before atomically replacing `nib-dev`. A failed build, failed validation, or interruption before replacement leaves the old binary in place. Concurrent installs publish complete binaries; the last successful replacement wins. The script never replaces `nib` or restarts existing processes.

- Start with `nib-dev` if the bin directory is on `PATH`, or run `~/.local/bin/nib-dev` directly.
- `nib` and `nib-dev` share `NIB_HOME` (default `~/.nib`) unless you opt out. Run `NIB_HOME="$HOME/.nib-dev" ~/.local/bin/nib-dev` to keep development sessions, settings, and credentials separate. Installation does not change configuration.
- Return to stable by starting `nib`. Use `nib update` for stable updates; rebuild `nib-dev` with the script.
- Remove just the dev executable with `rm -- "$HOME/.local/bin/nib-dev"` (or use your chosen bin directory). This does not remove any session data or configuration.

There are no remote `nib-dev` builds. To publish stable `nib`, follow the separate [release workflow](releasing.md).
