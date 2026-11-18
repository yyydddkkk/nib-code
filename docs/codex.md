# Run nib with a ChatGPT login

Other API-key/custom services: [providers.md](providers.md). Codex adds ChatGPT login/WS extensions to shared Responses; defaults unchanged.

## Signing in

Run `nib`, then `/provider` and choose Codex; or `nib login codex`. nib opens the browser (`open` on macOS, `xdg-open` on Linux) and waits on `127.0.0.1:1455` for the callback (`Waiting for ChatGPT sign-in · Esc cancels`). Without a display, over SSH, or when the browser or port is unavailable it uses device-code login instead: the TUI prints `Open <url> and enter code <code>`; `nib login codex --device` forces it. Success prints `Codex · signed in · <plan>`.

The flow is the Codex CLI's (public client id, PKCE, `https://auth.openai.com`; [ADR 0022](adr/0022-provider-sign-in.md)). Tokens go to `$NIB_HOME/auth.json` (mode 0600). If you already use the Codex CLI, nib reads `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) in place without copying it, and nib's own login takes precedence when both exist. `/provider logout codex` removes only nib's tokens. No telemetry; the only calls are the sign-in, refresh and model requests.

```sh
nib
nib ask 'Hello'
nib ask --json 'Hello'
nib --continue
```

No NIB_API_KEY needed. Nonsecret settings go in `$NIB_HOME/config.toml` (default `~/.nib/config.toml`) [codex]; [configuration](config.md). NIB_BASE_URL/NIB_MODEL/NIB_CONTEXT_WINDOW override files; clear obsolete overrides when switching services.

Default `gpt-6.2-sol`, window 500,000 tokens. Explicit model:

```sh
NIB_MODEL=gpt-6-sol NIB_REASONING_EFFORT=high nib ask 'Hello'
```

Or write `~/.nib/config.toml` (under `NIB_HOME` if set):

```toml
provider = "codex"
effort = "medium"

[codex]
model = "gpt-6.2-sol"
context_window = 500000
```

These settings apply on subsequent launches; environment overrides temporarily, --effort has highest precedence.

Upstream pi [`catalog/providers/openai-codex.ts`](https://github.com/earendil-works/pi/blob/main/packages/ai/catalog/providers/openai-codex.ts) catalog (November 2026; Codex backend defaults):

| Model | Default window |
|---|---:|
| gpt-6.2-sol | 500,000 |
| gpt-6.2-astra | 272,000 |
| gpt-6.1-terra、`gpt-6.1-sol` | 500,000 |
| gpt-6-astra、gpt-6-sol、gpt-6-luna | 272,000 |
| gpt-5.6-luna、gpt-5.6-sol、gpt-5.6-terra | 272,000 |

GPT-6.2 Sol and Astra both reject reasoning effort `none`; `off` and compaction use `low`. Their OpenAI API windows differ from Codex: both are 1,050,000 tokens with 128,000 maximum output tokens ([Sol](https://developers.openai.com/api/docs/models/gpt-6.2-sol), [Astra](https://developers.openai.com/api/docs/models/gpt-6.2-astra)).

Unknown models require `context_window` or NIB_CONTEXT_WINDOW, without guessing. Availability depends on account.

Control current-process effort without environment variables:

```sh
nib --effort high
nib ask --effort high 'Hello'
```

TUI `/effort` queries, `/effort high` switches; status shows requested effort.

--effort and `/effort` accept default|off|none|minimal|low|medium|high|xhigh|max; model/server determine support. Explicit levels enable thinking and override environment/files. off disables or minimizes by model; default clears overrides for server choice. Display is client request configuration, not server-confirmed reasoning quantity.

TUI switches only while idle, affecting later Turns and children. `/effort <level>` atomically updates only top-level effort in `$NIB_HOME/config.toml`, preserving lines/comments; /effort default deletes it. CLI does not persist. CLI > environment > file > defaults; resume uses launch configuration. Summaries retain independent minimum reasoning.

NIB_THINKING=on defaults medium; NIB_REASONING_EFFORT explicitly selects supported levels. off overrides effort: none where disableable, minimum low for sol/astra. Without environment overrides use file effort, otherwise server defaults.

## Effort and prompt caching

Measured local ~/.nib/sessions Codex/gpt-6.1-sol logs: compare adjacent same-Turn Steps, grouped by actual effort change, measuring later-Step prompt_cache_hit_tokens / prompt_tokens against prior hit rate.

| Adjacent-Step effort | Later-Step samples | Median cache hits | Mean |
|---|---:|---:|---:|
| Same | 1,504 | 96% | — |
| Changed | 12 | 0% | 15% |

Examples: high 99% → medium 0%; medium 96% → low 0% → low 99%. Returning to prior levels partially restores hits (47%–70%). Samples suggest effort-separated caches for this model/transport, not protocol guarantees or Chat Completions/DeepSeek evidence.

Changed requests may charge whole context uncached, increasingly costly with context size. Run effort applies to next requests only; failure/interjections restore user levels, so one reduction usually means two invalidations (return may partially hit). New Codex systems state this in two sentences alongside effort; Chat Completions omits it, and `NIB_PATCHES_OFF` cannot disable it. Prompt changes alter new `system_sha`; resume keeps original system.

**Removal condition:** If these measurements stop showing effort-change invalidation, remove the system hint and update tests/docs.

## Fork and parent cache routing

tools.agent({ prompt, fork: true }) creates independent children but reuses parent `prompt_cache_key`, not new child ids. Inherit complete compacted parent history including initiating assistant/reasoning, then synthetic results/user task; system/schema remain byte-identical. Shared keys aim to route identical prefixes together.

Two real comparisons on 2026-11-04 with gpt-6.1-sol/default effort: same task, parent reads files then delegates the same question using fork: true/false:

| Child | First-request prompt | Cache hits | Child Steps | Child time |
|---|---:|---:|---:|---:|
| Fork, parent about 2k | 2,166 | 1,920 (89%) | 2 | 5.8 s |
| New, same parent | 1,575 | 0 | 2 | 6.7 s |
| Fork, parent about 6.6k | 6,814 | 6,528 (96%) | 1 (no reread) | 3.9 s |
| New, same parent | 1,579 | 0 | 2 | 7.9 s |

Tiny samples show first requests can hit parent prefixes with shared keys, not server guarantees. Observe larger-context benefits through `stats.py` child_costs.by_creation. Reconsider shared keys if fork first-hit rates cease materially exceeding new children.

Model/effort inherit by default with overrides, but differing values lose parent-prefix benefits regardless of shared keys. Codex fork enforces resume model consistency; overrides cannot reuse encrypted parent reasoning across models. Future same-model/effort/prefix comparisons of parent/independent keys should measure first cache/prompt, uncached input, and time; reconsider keys absent benefits. Semantics/confidence: [delegation](tool-delegation.md), [ADR 0015](adr/0015-agent-fork.md).

## Summaries and Session resume

Use current models/prefixes/encrypted reasoning for summaries, preserving cache and avoiding cross-model ciphertext. Disable reasoning if possible, otherwise low. Unlike Chat Completions small total-output caps, Codex follows pi by omitting max_output_tokens for normal server budgets; 32–2048 tokens constrain text in prompts only, leaving reasoning room (pi maxTokens 128000, actual server limits). Empty/truncated/ineffective automatic summaries notice/continue; manual compaction errors.

Sessions record provider/model. Cross-provider resume rejects: use originals or new Sessions. Codex model must match for encrypted reasoning; Chat Completions retains current-model resume behavior. Default Codex since 2026-11-02 (previously DeepSeek); `NIB_PROVIDER=chat_completions` selects that protocol, default DeepSeek.

Missing/malformed credentials prompt `nib login codex`. Access tokens that are JWTs are refreshed with the refresh token when expired or within 60s of expiry, and once after a 401 (a different token already on disk is used as is); the new tokens are written back to the file they came from, preserving its other fields and mode. Opaque tokens are never refreshed on their own. A repeated 401 asks users to run `nib login codex`. There is no cross-process lock: two processes refreshing at once may race on a rotating refresh token. No credentials in logs/argv/child environments. Agents receive effective config via stdin, skip files, read auth.json independently; bash removes common secret variables. read/edit/write reject credential files; bash rejects credential-directory references. Mistake protection, not system sandboxing: [ADR 0006](adr/0006-deny-dangerous-commands.md).

## Stream activity

Reasoning summaries default off; enable under [reasoning summaries](#reasoning-summaries). Encrypted items return unchanged; logs preserve server order to avoid rearranging interleaved commentary/reasoning prefixes; [Session logs](session-log.md#step-transport-fields).

TUI activity updates only for actual reasoning/text/argument deltas and tool progress, not heartbeats/metadata/usage/timing alone. After 30 seconds add · no progress Ns, cleared by content. Show model waiting, Run generation, tools/background tasks and cumulative Turn time; background waits show ids/durations without ETA. TUI-only, no new ask events. Byte/content timeout clocks below/[config.md](config.md) remain independent. Interactions: [tui-ux.md](tui-ux.md).

## Stream failures and retries

Preserve server code/message/incomplete reason from error/response.failed/response.incomplete. Format: `Codex stream failed: <code>: <message>; the Step was not committed.` Trim message at UTF-8 boundaries to about 300 bytes.

Never retry `context_length_exceeded`, `insufficient_quota`, `usage_not_included`, `invalid_prompt`, request 4xx except 429. Retry `server_error`, rate limits, overload/unavailability, unknown codes, IncompleteResponse up to 5 attempts, default waits 1/2/4/8 seconds. Rate-limit try again in Xs/Xms overrides a wait, including decimals. Existing retry events/TUI remain.

A reused WebSocket that closes (`WebSocketClosed` or `EndOfStream`) before any event/content gets one immediate reconnect without backoff or a retry notice. The failed attempt remains in `model_attempts`; a fresh-connection failure and failures after output use normal retry/backoff. SSE fallback rules are unchanged.

Codex may retry after text/reasoning deltas; displayed failed fragments are not rolled back and may duplicate. Reuse requests, clearing failed partials used for cancellation commits; commit only successful complete Steps, final `end.text` rather than all deltas. Chat Completions retries only before deltas.

Unretried/exhausted failures append independent diagnostic (`error_name`, code/message text, attempts, failed step), outside context/committed messages/context_tokens. Resume ignores; stats counts `errors.provider_failure` without Steps/tokens. Cancellation retains interruption commits.

Local verification (temporary fictional credentials only):

```sh
zig build test --summary all
zig build
python3 tests/test_session.py
python3 tests/test_codex.py
zig build -Doptimize=ReleaseFast
```


## Responses WebSocket transport

Default Responses WebSocket configuration:

```toml
[codex]
transport = "websocket"
```

`NIB_CODEX_TRANSPORT=sse` nib ask 'Task' or [codex] transport = "sse" forces HTTP POST/SSE; environment wins. Handshake/protocol failure falls back for Session. Defaults match validated v7 benchmarks: custom Run, 16 KiB, reasoning summaries off. Children inherit effective Config; each `tools.llm` call owns temporary state, never main sockets.

### Protocol and sources

Follow official [openai/codex rust-v0.166.0](https://github.com/openai/codex/tree/rust-v0.166.0):

- [provider.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-client/src/provider.rs#L91): same Responses path, http/https→ws/wss. GET Upgrade at `https://chatgpt.com/backend-api/codex/responses`, TLS WS frames; local mocks use http.
- [client.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/core/src/client.rs#L1635): continue only with equal non-input fields and current input prefixed by prior input+completed output. Retain store:false/prompt_cache_key/reasoning.encrypted_content. Handshake: OpenAI-Beta: responses_websockets=2026-02-06, Authorization, chatgpt-account-id, originator, session-id, x-client-request-id, `x-codex-routing-hint`:`model=<model>` (no fast/tier).
- [common.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/common.rs#L333): flat {"type":"response.create", ...}, no response wrapper. Send `previous_response_id` with shortened input; `generate:false` is warmup only. nib omits optional warmup, including handshake in first requests.
- [responses_websocket.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/endpoint/responses_websocket.rs): same Responses events; top-level errors may carry status/status_code, nested error.code/message. previous_response_not_found/websocket_connection_limit_reached recover. turn-state comes from handshake headers or [response.metadata.headers](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/sse/responses.rs#L214), sent in later same-Turn client_metadata["x-codex-turn-state"]. Clear each new Turn.
- [startup_prewarm.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/core/src/session/startup_prewarm.rs): official background warmup/handoff exists; do not copy its waits directly.

Cross-reference local jcode ws_input.rs/openai_ws_connect.rs and pi getCachedWebSocketInputDelta; official tag wins conflicts.

### Lifecycle, failures, and limits

Each Session serially owns one connection; background agents are separate processes, fork/resume never copy sockets/response ids. Successful responses retain non-input attributes, full sent input, normalized ordered server output, logged in order: messages role/content/phase including empty messages; `function_call` type/call_id/name/arguments; `custom_tool_call` type/call_id/name/input; original reasoning. Replay ordered output, never merged display text, including resume/fork. Prefix mismatch, unknown output, or absent server ids sends full input. Clear continuation around compaction; effort/instructions/tools/schema changes fail attribute matching. Credentials/model/endpoint/cache-key changes close connections.

previous_response_not_found before deltas on incremental requests triggers one full-input resend, never rerunning Runs; full failure returns error. Connection-limit/disconnection/idle timeout use ≤5 retries with new full-input connections. Only explicit handshake failures (unsupported upgrade/invalid accept), WS protocol/oversized-frame errors remember Session SSE fallback. Connection/content-validation errors retain WS retry; InvalidResponse alone never switches. Persist fallback reason/time/diagnostics immediately. After visible deltas, retry cleanup clears partials before SSE; UI may retain fragments, logs commit success only.

Reuse provider/cancel.zig cancel/join: Esc/SIGINT interrupts I/O, discards socket, next Turns send full input. Cancellation does not wait close handshake; normal close replies close then reconnects. provider/idle.zig tracks beneath TLS/HTTP buffering; frames/ping/pong/metadata count byte activity. Separately limit no-content pauses to 120 seconds and attempts to 300; heartbeat/continuous summaries extend neither total deadline. All configurable: [config.md](config.md).

Frames support random client masks, short/16/64-bit lengths, fragmented text, ping/pong/close, UTF-8/control validation. Server-message cap 16 MiB; oversize/binary/extension frames fall back without truncation. No negotiated compression/extensions. Reuse std.http.Client TLS/certs/proxies. Real local ChatGPT gateway verified custom/incremental; v7 formal benchmarks do not cover all proxies, long idle sockets, accounts. No pooled concurrency; one main request per Session. [ADR 0017](adr/0017-codex-websocket.md).

Before reuse, Linux/macOS poll the socket without waiting and inspect buffered TLS plaintext and encrypted input. Pending Ping frames receive Pong; Close/EOF triggers a full-input reconnect with `connection_closed` and no failed attempt. Incomplete pending frames reconnect conservatively rather than waiting. Healthy sockets remain reusable regardless of idle duration. No keepalive pings or background reader are added.

Background results append to committed history only; waiting metadata stays local, so subsequent input may contain only background user messages. Mismatches send full history. Background waits do not run stream idle timers. The server closes idle sockets after an unspecified period: session logs observed closes after 82 seconds or more, while a real TLS comparison successfully reused a socket after 75 seconds. Elapsed idle time alone does not trigger reconnects.

Local `python3 tests/test_codex_websocket.py` covers increments, prefix/config changes, missing-response resend, handshake/protocol fallback, fragments/ping/pong, turn-state, reconnect, fork/resume, SIGINT/Esc continuation, cross-Turn reuse, no requests while background waiting, incremental/background prefix fallback, idle-close reconnect/timeout, heartbeat/metadata content timeout, continuous-reasoning total timeout, exact interleaved-message continuation. Fields/stats: [session-log.md](session-log.md#step-transport-fields).

### Comparing actual transports

Compare same ReleaseFast binary/model/effort; record source commit, wrappers, actual binary hashes. Bench clears external NIB_*; wrappers must set NIB_CODEX_TRANSPORT=sse/websocket. Use independent Sessions/interleaved runs, separating cold first and later Steps.

python3 `scripts/stats.py` `<log-directory>` --group-by transport --json compares actual model_ms/first_data_ms/code_first_ms, checking incremental/input_items/input_bytes/transport_fallback. Group full_reason for full-input causes. SSE fallback Steps include WS costs, not pure SSE. Judge success, Steps, tokens/cache, total wall time together; mocks prove no performance benefit. [Logs](session-log.md#step-transport-fields).

## Reasoning summaries

Default omits `reasoning.summary`, preserving effort, `include:["reasoning.encrypted_content"]`, `store:false`, reasoning history. SSE/WS share construction. No empty TUI blocks/ask reasoning deltas without summaries; encrypted continuation remains.

Enable [codex] reasoning_summary = "auto" inside the section or `NIB_REASONING_SUMMARY=auto`; off disables, environment wins. Even server-default effort with auto sends reasoning:{summary:"auto"}.

Local request-flags comparisons showed earlier first arguments with summaries off, without stable reasoning-token decreases. This does not disable reasoning or guarantee equal whole-task acceleration. Experiments live in adjacent `nib-speed-notes/`; defaults may follow readable-summary preferences.

## Custom Run tool

Default Responses custom emits direct JS, removing function JSON-string escaping. Lark grammar (`SOURCE: /[\s\S]+/`) accepts any non-empty source; outer-form only, no JS validation. Per-Step effort declarations were removed ([ADR 0025](adr/0025-model-profiles.md)); old `// @run:` lines in history replay verbatim and are plain comments if re-run. [codex] run_tool = "function" or `NIB_CODEX_RUN_TOOL=function` falls back; Chat Completions unchanged.

Encode each historical call by its own type: custom_tool_call/custom_tool_call_output versus function_call/function_call_output. Resume never converts old JSON code to custom, nor reverse fallback history. Preserve raw args/encrypted reasoning/cache prefixes, with expected changes only at tool-definition differences. Resume already uses new full-history connections; unchanged same-connection tools allow normalized custom output prefix matching and incremental results.

Internal/main-log `tool_calls[].function.arguments` remains JSON {code}, custom marked `type:"custom"`; retain raw Responses output too. Reuse execution/fork/resume/replay paths. Argument timing measures wire payloads: raw JS UTF-8 custom input versus function JSON args, not normalized JSON lengths.

Model-facing syntax/runtime errors suggest correcting scripts/continuing, without forcing continuation or fixing all premature stops. SyntaxError preserves QuickJS `<run>`:line:column plus nearby UTF-8 source excerpts ≤200 bytes. History/effort/escaping: [ADR 0018](adr/0018-custom-run.md). Protocol: [OpenAI custom tools](https://developers.openai.com/api/docs/guides/function-calling#custom-tools), local Codex CLI 0.166 traces.
