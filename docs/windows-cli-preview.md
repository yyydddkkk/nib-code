# Windows x64 preview

This is a native preview, not full Windows support. Starting with builds newer than 0.23.0, run `nib.exe` in Windows Terminal to open the interactive TUI. The 0.23.0 release is CLI-only. Download `nib-x86_64-windows-preview.zip` from [GitHub Releases](https://github.com/yyydddkkk/nib-code/releases), verify it against `SHA256SUMS`, and extract `nib.exe`. It does not require WSL or Git Bash to start. `tools.bash` requires Git for Windows installed at its default system-wide location; nib never uses PowerShell, WSL, or a `bash.exe` found through `PATH` as a substitute. In the TUI use `/provider` to set an API key or use the Codex device-code flow; browser callback sign-in and the `nib login` command are not supported. Use the terminal's paste action for text. Pasting an image from the system clipboard is not supported; a pasted image-file path can still attach a file. Hooks, external subagents, MCP stdio and in-place updates are not part of the preview. Windows refuses `workspace` isolation rather than falling back to unsandboxed execution. Files under `NIB_HOME` inherit Windows ACLs; they do not get POSIX modes.

Build from Linux or Windows with Zig 0.17:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

On Windows, run the offline smoke tests with the resulting executable:

```powershell
python tests/test_windows_cli.py zig-out/bin/nib.exe
python -m pip install pywinpty==3.1.2 pyte==0.8.2
python tests/test_windows_tui.py zig-out/bin/nib.exe
```

The TUI test uses native ConPTY to check editing, exact Unicode multiline paste without auto-submission, resizing with a live draft, and clean exit.

The test uses a local mock provider and checks `--version`, `js`, `ask`, session resume and lock contention, file tools in a directory with spaces and non-ASCII characters, and an idle response followed by a successful retry. On native Windows the test also checks that Bash descendants are terminated after shell exit, `tools.stop`, Ctrl+C, timeout, or abrupt nib termination. Ctrl+C during `nib ask` saves the interrupted turn so the session can be resumed. A Job Object controls process lifetime, not file access. Add `--basic` to check only `--version` and `js`. For a local Wine check, pass `--runner /path/to/wine`. Wine 10 returns `STATUS_NOT_IMPLEMENTED` for the `NtLockFile` call Zig uses to lock session logs; this is not a substitute for a native Windows `ask` check. Do not remove session locking to make the Wine smoke pass.
