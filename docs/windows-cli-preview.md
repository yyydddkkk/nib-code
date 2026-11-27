# Windows x64 CLI experiment

This is a build experiment, not a supported release. It does not require WSL or Git Bash to start. Interactive sign-in, the TUI, shell commands, hooks, external subagents, MCP stdio, and in-place updates are not part of the preview. Windows refuses `ask` with `workspace` isolation rather than falling back to unsandboxed execution. Files under `NIB_HOME` inherit Windows ACLs; they do not get POSIX modes.

Build from Linux or Windows with Zig 0.17:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

On Windows, run the offline smoke test with the resulting executable:

```powershell
python tests/test_windows_cli.py zig-out/bin/nib.exe
```

The test uses a local mock provider and checks `--version`, `js`, `ask`, session resume, and file tools in a directory with spaces and non-ASCII characters. Add `--basic` to check only `--version` and `js`. For a local Wine check, pass `--runner /path/to/wine`. Wine 10 returns `STATUS_NOT_IMPLEMENTED` for the `NtLockFile` call Zig uses to lock session logs; this is not a substitute for a native Windows `ask` check. Do not remove session locking to make the Wine smoke pass.
