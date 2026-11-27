# Releasing

Stable releases batch useful changes that have already passed PR CI and merged. For daily use without publishing a release, [install `nib-dev` from local `dev`](developing.md).

1. Bump only `.version` in `build.zig.zon` to a stable `X.Y.Z` version (no leading zeros).
2. Add `docs/releases/<version>.md`: start with `# nib <version>` and the English notes, then `---`, then `# nib <version>（中文）` and the same notes in Chinese.
3. Open a metadata-only PR and wait for the [lightweight CI gate](ci.md#release-metadata) to pass. Mixed application or dependency changes take full CI, so land those separately first.
4. After the metadata PR merges, and only with maintainer approval, push tag `v<version>` on the intended `main` commit containing that version and those notes. Merging by itself does not publish a release.

The release workflow checks the tag against the package version, builds stripped Linux (static musl, x86_64 and arm64) and macOS (Apple silicon) binaries, and tests the installer on each platform. It also builds the Windows x64 preview and runs the offline ConPTY TUI, CLI, and process-tree smoke tests against the unzipped executable on Windows. `SHA256SUMS` covers all four archives. The Windows zip contains only `nib.exe`; the release job also exercises the PowerShell installer and self-updater. See the [preview limitations](windows-cli-preview.md). A release is published as latest only after the checks pass. The workflow does not overwrite published assets. Package manifests pin the ZIP by SHA-256, so publish a new version if an asset needs to change.

The installer verifies SHA-256 by default. `NIB_SKIP_VERIFY=1` disables verification. For local testing, set `NIB_DOWNLOAD_BASE=file:///absolute/path/to/assets` and `NIB_INSTALL_DIR` to a temporary directory.

For standalone installations, `nib update [version]` uses the same release assets and checksum verification as the installer, replacing the executable in place. It honors `NIB_DOWNLOAD_BASE` and `NIB_SKIP_VERIFY=1`. HTTP and HTTPS proxies use the standard HTTP client environment settings. Updates run only on request.

## WinGet (Windows x64 preview)

The [initial manifest](../packaging/winget/manifests/y/yyydddkkk/nib/0.26.0) packages the published ZIP as a portable executable with the `nib` command. It does not run `install.ps1`. The `yyydddkkk.nib` package is not available from the `winget` source until Microsoft accepts the manifest in [winget-pkgs](https://github.com/microsoft/winget-pkgs).

1. On Windows, validate and test the manifest in a clean environment using the [WinGet submission guide](https://learn.microsoft.com/windows/package-manager/package/repository). For a local install, enable local manifests with `winget settings --enable LocalManifestFiles` from an elevated terminal, then run the following from a regular PowerShell in the nib checkout:

   ```powershell
   $manifest = '.\packaging\winget\manifests\y\yyydddkkk\nib\0.26.0'
   winget validate --manifest $manifest
   winget install --manifest $manifest --scope user
   ```

   In a fresh terminal, check that `nib --version` prints `nib 0.26.0`. Then run `winget uninstall --id yyydddkkk.nib --exact` and check that `Get-Command nib` no longer finds it. If you enabled local manifests only for this test, turn them off with `winget settings --disable LocalManifestFiles` from an elevated terminal.
2. Copy the three YAML files to `manifests/y/yyydddkkk/nib/0.26.0/` in a fork of `microsoft/winget-pkgs` and open a PR. Once `winget show --id yyydddkkk.nib --exact --source winget` finds the package, document `winget install --id yyydddkkk.nib --exact --source winget` as an installation option. WinGet users should use `winget upgrade --id yyydddkkk.nib --exact --source winget`, not `nib update`, so the installed version stays in sync with WinGet.
3. For future versions, copy the manifest to a new version directory, update the version and versioned URLs, and use the Windows ZIP hash from that release's `SHA256SUMS`. Verify the downloaded ZIP against that hash before submitting the new version. Do not rerun the old v0.26.0 release workflow after submission: it predates the no-overwrite change.
