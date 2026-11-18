# Releasing

Stable releases batch useful changes that have already passed PR CI and merged. For daily use of merged changes without publishing a release, [install nib-dev from local main](developing.md).

1. Bump only `.version` in `build.zig.zon` to a stable `X.Y.Z` version (no leading zeros).
2. Add `docs/releases/<version>.md`: start with `# nib <version>` and the English notes, then `---`, then `# nib <version>（中文）` and the same notes in Chinese.
3. Open a metadata-only PR and wait for the [lightweight CI gate](ci.md#release-metadata) to pass. Mixed application or dependency changes take full CI, so land those separately first.
4. After the metadata PR merges, and only with maintainer approval, push tag `v<version>` on the intended `main` commit containing that version and those notes. Merging by itself does not publish a release.

The release workflow checks the tag against the package version, builds stripped Linux (static musl, x86_64 and arm64) and macOS (Apple silicon) binaries, and tests the installer on each platform before publishing the release as latest. Assets contain just `nib`; `SHA256SUMS` covers all three archives. Re-running the workflow replaces assets on an existing release.

The installer verifies SHA-256 by default. `NIB_SKIP_VERIFY=1` disables verification. For local testing, set `NIB_DOWNLOAD_BASE=file:///absolute/path/to/assets` and `NIB_INSTALL_DIR` to a temporary directory.

`nib update [version]` uses the same release assets and checksum verification as the installer, replacing the executable in place. It honors `NIB_DOWNLOAD_BASE` and `NIB_SKIP_VERIFY=1`. HTTP and HTTPS proxies use the standard HTTP client environment settings. Updates run only on request.
