# User directory and configuration

`NIB_HOME` selects the user directory, default `$HOME/.nib`:

```text
~/.nib/
  AGENTS.md       Global instructions
  config.toml     Optional nonsecret runtime configuration
  auth.json       Credentials stored by /provider and nib login (mode 0600)
  sessions/       <32-character-lowercase-hex-ID>.jsonl main logs and matching .calls.jsonl recordings
  reflections.md  Completed /reflect answers and issue publication results
```

No XDG configuration/data reads, old-file searches, or automatic migration. Users move retained instructions/Sessions themselves. `NIB_HOME` does not change the Codex CLI login nib may import: `$CODEX_HOME/auth.json`, default ~/.codex/auth.json.

## `auth.json`

Written by `/provider`, `nib login` and the ChatGPT refresh; mode 0600, replaced atomically (temporary file + rename). Never edit it while nib runs. Shape: `{"keys": {"<service id>": "<key>"}, "tokens": {id_token, access_token, refresh_token, account_id}, "last_refresh": "<RFC 3339>"}`; unknown fields are kept. Key precedence, highest first: the service's environment variable, then `auth.json`, then (Codex only) `$CODEX_HOME/auth.json`, used in place and never copied; nib's own Codex `tokens` outrank the CLI file. Keys are never printed in the TUI, logs, errors, or `/status` (which names only the source), never written to config.toml, and `read`/`edit`/`write` and bash refuse this file. Sign out with `/provider logout <service>` or `nib logout <service>`; it removes only nib's own entry.

New Sessions assemble system from base instructions, `$NIB_HOME/AGENTS.md`, then project AGENTS.md. Project root is the first cwd ancestor containing .git, or cwd if absent. Resume retains logged system. No project `config.toml` yet; project conventions remain in AGENTS.md.

## `config.toml`

Prefer TUI `/provider` for services (including `Add endpoint…`, which appends a `[providers.<id>]` section) and `/model` for models, atomically saving to `config.toml` and starting new Sessions when Steps exist. Direct file/environment edits remain alternatives; NIB_PROVIDER/NIB_MODEL override saved values at startup. Syntax, credential filtering, Session semantics: [providers.md](providers.md).

```toml
# Optional top-level keys
provider = "codex"
effort = "high"
ui = "normal" # normal (default) or simple
open = "zed {path}:{line}" # optional: command run when a file path is clicked

[codex]
model = "gpt-6.1-sol"
base_url = "https://chatgpt.com/backend-api"
context_window = 500000
reasoning_summary = "off" # auto enables readable reasoning summaries
run_tool = "custom" # function falls back to JSON code
transport = "websocket" # Session falls back to SSE after handshake/protocol failure; sse forces HTTP

[chat_completions]
model = "deepseek-flash"
base_url = "https://api.deepseek.com"
context_window = 1000000

[limits]
llm_concurrency = 4
llm_calls_per_run = 100
llm_input_kib = 256
agent_concurrency = 4
# max_steps = 50  # Optional; omission means no Step limit
stream_idle_timeout_s = 300
stream_content_timeout_s = 120
request_timeout_s = 300
run_background_after_ms = 10000
run_output_bytes = 16384

[skills]
hallmark = true # All disabled by default; enable individually by name
```

Only the selected provider section applies; switching need not rewrite others. Without environment/file settings the service is codex (`gpt-6.1-sol`, window 500000 tokens) when signed in; otherwise startup uses the first credentialed service without saving it ([providers.md](providers.md#signing-in-and-choosing)). Codex windows depend on model; unknown models require `context_window` or NIB_CONTEXT_WINDOW. Models/resume/credentials: [codex.md](codex.md), [ADR 0011](adr/0011-provider-wire-protocols.md).

Built-ins: codex (default), openai, anthropic, deepseek, xai. Legacy chat_completions is a DeepSeek-compatible entry retaining independent Session identity. Tables/windows/authentication/effort/custom examples: [providers.md](providers.md).

```toml
provider = "openai"

[openai]
model = "gpt-6.1-sol"

# For your OpenAI-compatible endpoint, set top-level provider to mysite
[providers.mysite]
protocol = "chat_completions"
base_url = "https://models.example.com/v1"
model = "my-code-model"
context_window = 128000
api_key_env = "MYSITE_API_KEY"
```

openai uses `OPENAI_API_KEY`; mysite uses MYSITE_API_KEY. Never write key contents to files. Custom protocol/base_url/model/context_window are required; omit api_key_env for unauthenticated local services. Optional `vision = true|false` declares image input support and optional `max_output = <integer>` sets the output token limit ([providers.md](providers.md)). `NIB_PROVIDER`=mysite overrides the top-level choice.

Dependency-free TOML subset: blank lines, # comments, single-line double-quoted strings (escapes `\"`, `\\`, `\n`), signed decimal integers with underscore grouping, true/false. Only [skills]/[mcp] name keys and a custom provider's `vision` accept booleans; other keys use strings/positive integers and reject booleans by type. Accept only top-level provider/effort; model/base_url/context_window in built-in same-name sections; [codex] additionally transport = "sse"|"websocket", reasoning_summary = "off"|"auto", run_tool = "custom"|"function"; the [limits] keys below; [skills] switches; [sandbox] `mode`/`writable`; [hooks] `after_edit`/`turn_end`; and `[providers.<id>]` protocol/base_url/model/context_window/api_key_env/vision (boolean)/max_output (positive integer). Arrays only as single-line lists of strings, for `[sandbox].writable`, hook commands, and `[mcp.<id>]` args/env. MCP server definitions accept command/args/env or url/header_env; `[mcp]` holds opt-in switches. No general nested tables, multiline strings, or full TOML. Unknown/duplicate keys/sections and malformed syntax report path/line rather than silently ignoring.

## [skills]

Skills default off. Keys are names; only true enables, false/absence disables. Enabled missing files stay outside the prompt index; `/status` shows missing. No environment/project switches.

TUI `/skills` lists discoveries/switches; `/skills on <name>` and `/skills off <name>` save atomically, preserving other lines. New Sessions only; current/resumed Sessions retain original system. Format/directories/precedence: [skills.md](skills.md).

## [sandbox]

```toml
[sandbox]
mode = "workspace"          # opt in; default "off"
writable = ["~/data/shared"] # extra writable roots; absolute or ~/...
```

The sandbox defaults off: nib runs with your permissions, without sandbox probing, wrappers, path checks, or unavailable notices/log records. `/status` shows `Sandbox: off`. Opt in with `mode = "workspace"` or `NIB_SANDBOX=workspace`; `/status` then shows `Sandbox: workspace` when available. The destructive-command deny-list and credential protections apply in both modes.

In workspace mode, reads and network remain open. bash (foreground and background), hooks, MCP stdio servers, and every subagent Session can write only to:

- the project directory (first cwd ancestor containing `.git`, else cwd); for a linked git worktree also its gitdir and common dir;
- `/tmp`, `/var/tmp`, `$TMPDIR`, `/dev/shm`, and `/dev/null`, `/dev/zero`, `/dev/full`, tty/pty devices (macOS: `/private/tmp`, `/private/var/tmp`, `/private/var/folders`, `/dev/fd`);
- per-user build and package caches, when they exist: `~/.cache`, `~/.npm`, `~/.cargo/registry`, `~/.cargo/git`, `~/.rustup`, `~/go/pkg`, `~/.gradle`, `~/.m2`, `~/.bun/install/cache`, `~/.yarn`, `~/.pnpm-store`, `~/.local/share/pnpm`, `~/.local/share/uv` (macOS also `~/Library/Caches`, `~/Library/Developer`), plus `$XDG_CACHE_HOME`, `$ZIG_GLOBAL_CACHE_DIR`, `$CARGO_HOME/registry`, `$CARGO_HOME/git`, `$RUSTUP_HOME`, `$GOPATH/pkg`, `$GOCACHE`, `$GOMODCACHE`, `$GRADLE_USER_HOME`, `$npm_config_cache`, `$PIP_CACHE_DIR`, `$UV_CACHE_DIR`;
- `writable` entries. Missing paths are skipped.

Executable directories `~/.cargo/bin`, `~/.bun/bin`, `~/go/bin`, and `~/.local/bin` are not cache roots. Explicit writable roots or a project containing them can still grant access.

`$NIB_HOME` is not in the list: nib itself writes it, commands cannot. Denied writes fail as ordinary `EACCES`/`EPERM`; nothing is added to tool results. The in-process edit/write tools apply the same roots by canonical path (symlinks and `..` resolved) and return an error.

Linux uses Landlock (kernel 5.19+ with Landlock enabled, ABI 2+), applied in the bash child only. macOS uses `sandbox-exec` with a generated profile. If neither works, commands run unsandboxed, one dim notice appears per Session, the Session log records `sandbox_unavailable`, and `/status` shows `Sandbox: workspace · bash unavailable`. Edit/write checks still apply. Rationale: [ADR 0004](adr/0004-two-layer-isolation.md).

`NIB_SANDBOX=off|workspace` overrides `mode`. Children inherit the effective mode and roots through stdin.

## [limits]

[limits] applies to effective configuration independently of provider. Each may be omitted; defaults follow. Explicit values must be positive integers within range:

| Key | Meaning | Default | Range |
| --- | --- | --- | --- |
| `run_output_bytes` | Model display bytes per Run/background result message; JS tool data unchanged | 16384 | 16384–16777216 |
| `llm_concurrency` | Concurrent `tools.llm` requests per process; excess queues | 4 | 1–64 |
| `llm_calls_per_run` | `tools.llm` calls per Run; excess rejects | 100 | 1–10000 |
| `llm_input_kib` | UTF-8 prompt + serialized input cap per call (KiB); excess rejects, never truncates | 256 | 1–65536 |
| `agent_concurrency` | Concurrent children per process; excess queues | 4 | 1–64 |
| `max_steps` | Steps per Turn; exhaustion returns TooManySteps; omission means unlimited (internal null) | Unlimited | 1–100000 |
| `run_background_after_ms` | Model-initiated Run automatically backgrounds after this wall time while waiting for tools | 10000 | 1–3600000 |
| `stream_content_timeout_s` | Seconds without nonempty reasoning/text/tool-argument deltas; heartbeat/metadata do not reset | 120 | 1–3600 |
| `request_timeout_s` | Total seconds per model attempt; reasoning does not extend it; cancel/join then retry by policy | 300 | 1–3600 |
| `stream_idle_timeout_s` | Seconds without stream bytes, including first-data wait; heartbeat/metadata reset; timeout retries as disconnection | 300 | 1–3600 |

Automatic background thresholds use [limits] and child inheritance, without environment/CLI switches; large values allow foreground comparison. nib js, TUI `/js`, offline replay stay synchronous; active JS segments are not interrupted at wall thresholds. See [run-output.md](run-output.md#long-runs-automatically-move-to-the-background).

All three deadlines apply to main-model, `tools.llm`, and compaction requests over WS/SSE, resetting each retry. Total deadlines cover connection/send/headers/body; idle deadlines check receiving streams. Idle timeouts share disconnection retries/backoff. Chat Completions does not replay after visible deltas; buffered llm/summaries can retry safely.

Bytes cannot distinguish progress from heartbeats; continuous summaries cannot guarantee completion. Hence separate byte-idle/content-idle/total limits. Content/request defaults 120/300 seconds leave about twice the longest first-code wait/successful request observed on 2026-11-05. Legitimate silent reasoning/long requests can still interrupt; raise limits for actual tasks. Total 300 seconds is nib policy, not Codex CLI default: [rust-v0.166.0](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-client/src/provider.rs#L86) has no stream-request total timeout. Up to 5 attempts plus backoff reset timers, so a Step may still wait about 25 minutes. Per-attempt diagnostics: [logs](session-log.md#step-transport-fields).

`NIB_RUN_OUTPUT_BYTES` overrides `run_output_bytes`; other limits have no environment/CLI overrides. Effective limits pass via stdin to children, which skip config reads. Missing `max_steps` remains null in children; explicit limits inherit. Sandbox 8-tool concurrency is thread scheduling, outside this section.

Explicit `max_steps` enters new-Session system prompts per Turn. With at most 3 Steps left, append remaining counts to each Run output outside display budgets. Exhaustion stops model requests; active background agent/bash finish first, results enter history/logs for next Turn. Still end with TooManySteps / stopped after N steps, listing waited task types/IDs if any. Esc immediately cancels Turn/tasks during waits. Without limits, no hints or Step cap. Resume retains original system; if current limits differ, prepend current budget facts to each Turn input to avoid stale limits.

Configuration stores no secrets and accepts no API-key/token/password/credential fields. Keys live in the environment or `auth.json`: Chat Completions uses `NIB_API_KEY` / `DEEPSEEK_API_KEY`; Codex uses its sign-in. Keep secrets out of URLs.

## Override precedence

Highest first:

1. CLI `--effort <level>` (TUI startup and ask).
2. Environment: `NIB_PROVIDER`, `NIB_MODEL`, `NIB_BASE_URL`, `NIB_CONTEXT_WINDOW`, `NIB_THINKING`, `NIB_REASONING_EFFORT`, `NIB_CODEX_TRANSPORT`, `NIB_CODEX_RUN_TOOL`, `NIB_REASONING_SUMMARY`, NIB_RUN_OUTPUT_BYTES, `NIB_SANDBOX`.
3. `$NIB_HOME/config.toml`。
4. Built-in defaults.

Environment thinking/effort suppress file effort. `NIB_THINKING=off` overrides environment effort; explicit CLI effort overrides both. Without reasoning configuration use server defaults. CLI --effort default clears process thinking/effort overrides without editing files.

Children inherit effective provider/model/limits through anonymous stdin, skipping files so mid-execution file changes cannot alter configuration. Each independently reads selected environment keys; stdin contains no secrets. Codex credentials are independently read too.

## Environment variables

| Variable | Meaning |
|---|---|
| `NIB_RECORD` | Recording defaults on; only off disables, without deleting calls files; [replay.md](replay.md) |
| `NIB_HOME` | User directory, default ~/.nib (holds `auth.json`); the Codex CLI login location is unchanged |
| `NIB_AUTH_ISSUER` / `NIB_AUTH_PORT` / `NIB_AUTH_NO_BROWSER` | Tests only: OAuth issuer URL (default `https://auth.openai.com`), callback port (default 1455), and skip the browser to force the device-code flow |
| `NIB_PROVIDER` | codex / openai / anthropic / deepseek / xai / chat_completions or configured custom id |
| `NIB_BASE_URL` | Current provider endpoint |
| `NIB_CODEX_TRANSPORT` | websocket (default) or sse; overrides [codex].transport; Session SSE fallback after handshake/protocol failure; [transport](codex.md#responses-websocket-transport) |
| `NIB_CODEX_RUN_TOOL` | custom (default, direct JS) or function (JSON code); overrides `[codex].run_tool`, preserving history types; Chat Completions always function |
| `NIB_REASONING_SUMMARY` | off (default, omit summary) or auto; overrides `[codex].reasoning_summary`, preserving effort/encrypted continuation |
| `NIB_SANDBOX` | off (default) or workspace; overrides `[sandbox].mode`; [details](#sandbox) |
| `NIB_RUN_OUTPUT_BYTES` | Model display bytes, 16384–16777216; overrides `[limits].run_output_bytes`, default 16384; JS data/console capture unchanged |
| `NIB_MODEL` | Current provider model |
| `NIB_CONTEXT_WINDOW` | Context tokens; DeepSeek default 1000000 |
| `NIB_THINKING` | on / off; unset uses server defaults absent other reasoning settings |
| `NIB_REASONING_EFFORT` | Reasoning level, e.g. low / high / max |
| `CODEX_HOME` | Codex CLI login directory containing `auth.json`, read as a fallback; default `~/.codex/auth.json` |
| `NIB_API_KEY` / `DEEPSEEK_API_KEY` | Legacy chat_completions prefers `NIB_API_KEY`; deepseek uses `DEEPSEEK_API_KEY` or a stored key |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `XAI_API_KEY` | Corresponding built-in keys; outrank `auth.json` |
| `NIB_PATCHES_OFF` | Disable prompt patches: all or comma-separated ids; [compromises.md](compromises.md) |
| `NIB_PATCHES_ON` | Enable opt-in prompt patches: comma-separated ids; `NIB_PATCHES_OFF` wins; [compromises.md](compromises.md) |
| `NIB_ISSUE_REPO` | Enables `/reflect` and issue publication to owner/name; unset or off disables it; [reflect.md](reflect.md) |

## Tool-result recording

Recording defaults on. `NIB_RECORD=off` disables subsequent recording without deleting sidecars. Other values behave like unset/on; no TOML key. Write `$NIB_HOME/sessions/<session_id>.calls.jsonl`, created mode 0600, independently of main logs/resume. It may contain complete files, output, and secrets beyond display budgets; inspect/delete prior data separately. Sidecars are neither automatically sent to providers nor enumerated by /reflect.

Offline commands, JSONL, SHA-256 deduplication, per-item 1 MiB truncation, privacy/capability boundaries: [replay.md](replay.md).

## Run effort

The `run` tool takes only `code`; the model cannot change reasoning effort per Step. Every Step requests the user's effort (`/effort`, `--effort`, config `effort`), and `tools.llm` keeps its own policy. Per-Step scheduling was removed by [ADR 0025](adr/0025-model-profiles.md): switching effort empties the provider prompt cache on Codex and DeepSeek. A first line `// @run: …` is an ordinary JS comment, and an `effort` argument in `run` arguments from old history is ignored.

TUI Run summaries and logs record the effort of the request that produced them; old logs without it show none.

## Effort persistence

--effort and TUI `/effort` accept default|off|none|minimal|low|medium|high|xhigh|max; model/server determines supported levels.

- nib --effort high and nib ask --effort high ... affect this process only, without persistence.
- TUI `/effort` queries current request settings without writing.
- TUI `/effort high` switches while idle for later Turns, atomically saving top-level effort only, preserving other lines/comments without serializing environment/effective configuration wholesale.
- TUI `/effort default` clears process thinking/effort and removes file top-level effort, preserving the rest. Next startup follows normal precedence; environment may override again.

Children inherit effective configuration; summaries use independent minimum reasoning. Resume uses current launch settings within provider/Codex-model boundaries; [codex.md](codex.md).

Read/validate current files before writeback, replacing only effort value byte ranges (preserve same-line comments on deletion); if absent insert at top-level end before first section. Write full contents to same-directory temporary file, sync, rename; failures clean up temporary files, never partially overwrite originals. Save failures show in transcript without reverting current effort. No cross-process lock: simultaneous nib/editor saves may overwrite earlier saves. File cap 1 MiB; no automatic migration/project config.

## [hooks]

Hooks are off unless configured. Values are single-line arrays of shell commands:

```toml
[hooks]
after_edit = ["zig fmt {files}"]
turn_end = ["notify-send nib 'Turn finished'"]
```

Commands run sequentially through `/bin/sh -c` in the project directory, using bash's OS write sandbox, writable roots, and API-key filtering. Each command has a fixed 30-second timeout; execution stops at the first failure. Success is silent.

`after_edit` runs once after each Run settles if edit/write changed files. `{files}` expands to shell-quoted paths relative to the project directory; `NIB_FILES` contains those paths separated by newlines, and `NIB_EVENT=after_edit`. A failure adds a `hook` payload to that Run's model output and a warning line in its TUI block. Child Sessions run and report their own after-edit hooks, including background Runs. Hook writes are not captured for `/undo`; reread formatted files as needed.

`turn_end` runs only for root Sessions in the TUI and `nib ask`, after completion, failure, or cancellation. It receives `NIB_EVENT=turn_end` and `NIB_TURN_STATUS=completed|failed|cancelled`. A background thread discards output and never sends failures to the model; the TUI shows `hook turn_end · exit N`. The whole turn-end sequence shares a 30-second deadline, so ask waits at most that deadline before exiting. Session shutdown joins outstanding hook threads. Offline replay never executes hooks.

Session logs record the event, expanded command, exit code (124 for timeout), and duration in milliseconds, without command output. `/status` shows configured hook counts only when nonempty.

## MCP servers

`[mcp.<id>]` configures a stdio command or Streamable HTTP URL; `[mcp] <id> = true` enables it (default false). `/mcp` lists servers; `/mcp on <id>` and `/mcp off <id>` persist switches for new Sessions. Current/resumed Sessions retain their snapshot. See [MCP tools](mcp.md) for configuration, environment credentials, protocol detection, sandboxing, and limits.

### `open`

`open = "zed {path}:{line}"` makes file paths in the TUI clickable (see [tui-ux.md](tui-ux.md)). The value is a command template: it is split on whitespace into arguments (no shell, so there is no quoting), `{path}` becomes the absolute path and `{line}` the line from a `:line` suffix (1 when absent) in every argument. The command starts detached with stdin, stdout and stderr closed, so it must open a GUI editor or an already running one; it is not waited for. Unset by default, which leaves paths as plain text. An empty value is a configuration error.

`/simple` and Ctrl+S atomically persist the top-level `ui` choice for the next launch. Invalid values are configuration errors.
