# Providers

Service identity is separate from wire protocol: codex, openai, anthropic, deepseek, xai are services; responses, `chat_completions`, `anthropic_messages` are the only three protocols. Built-ins live in `src/provider.zig` definitions, which also generates the service-id enum. Adding an ordinary API-key service using an existing protocol adds one row without extending Session/UI.

## Built-in services

| id | Protocol | Default `base_url` | Credentials | Default model / window |
| --- | --- | --- | --- | --- |
| codex | responses, Codex login/WS extensions | `https://chatgpt.com/backend-api` | ChatGPT sign-in (`/provider`, `nib login codex`) or `CODEX_HOME/auth.json` | `gpt-6.2-sol` / 500000 |
| openai | responses, SSE | `https://api.openai.com/v1` | `OPENAI_API_KEY` | `gpt-6.2-sol` / 1050000 |
| anthropic | `anthropic_messages`, SSE | `https://api.anthropic.com` | `ANTHROPIC_API_KEY` | `claude-sonnet-5-5` / 1000000 |
| deepseek | `chat_completions`, SSE | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` | `deepseek-flash` / 1000000 |
| xai | responses, SSE | `https://api.x.ai/v1` | `XAI_API_KEY` | `grok-4.7` / 500000 |

Snapshot: user-provided models.dev `api.json`, fetched **2026-11-06**. OpenAI additionally lists GPT-6.2 [Sol](https://developers.openai.com/api/docs/models/gpt-6.2-sol)/[Astra](https://developers.openai.com/api/docs/models/gpt-6.2-astra), both window 1050000/output 128000, alongside gpt-6.1-sol/terra. Both GPT-6.2 models reject reasoning effort `none`; `off` uses `low`. Anthropic lists claude-opus-5-5, `claude-sonnet-5-5`, claude-haiku-5-5, claude-fable-5-1, all window 1000000/output 128000. xAI lists grok-4.7/4.6, both window 500000. DeepSeek retains deepseek-flash/deepseek-v4-pro, both window 1000000. Codex also lists GPT-6.2 Sol/Astra with backend-specific windows; see [codex.md](codex.md). This short catalog neither guarantees account access nor calls discovery endpoints.

## Small model

`provider.smallModel` names each service's cheap model: codex and openai `gpt-6-luna`, anthropic `claude-haiku-5-5`, deepseek `deepseek-flash`. Web search and TUI input prediction both use it; prediction is a stateless out-of-Session request (SSE, lowest effort, 15 s timeout). Services without an entry (chat_completions, xai, custom) predict with the Session's current model at the lowest effort.

## Web search

`tools.search` uses the Session's own service and credentials; there is no setting and no fallback. It makes a separate request outside the Session (its usage is not added to Session totals).

| Service | Request |
| --- | --- |
| codex | Responses `web_search` through the Codex backend (`<base_url>/codex/responses`, ChatGPT sign-in), model `gpt-6-luna`; answer plus cited and consulted sources |
| openai | Same Responses request at `<base_url>/responses` with the API key |
| anthropic | Messages request with model `claude-haiku-5-5` and the server-side `web_search_20250305` tool; answer plus cited and found pages |
| deepseek | `POST <base_url>/v1/tools/search` with the API key; results only, no answer. DeepSeek bills each search request ([guide](https://api-docs.deepseek.com/guides/search)) |

Other services, including `chat_completions`, xai and custom endpoints, return `{ ok: false, error: "web search is not available for provider <id>" }`.

## Signing in and choosing

Run `nib`, then `/provider`. The menu lists every built-in service and each custom `[providers.<id>]` with where its credential comes from (`signed in · ChatGPT`, an environment variable name, `key stored`, a host, or `—`); the current one is marked `current`.

- A service without credentials asks for its key in the input area (shown as dots, `Esc` cancels, `Enter` saves to `$NIB_HOME/auth.json`) and then switches to it with its default model. Codex opens the ChatGPT sign-in ([codex.md](codex.md#signing-in)).
- A credentialed service switches directly. `/provider <id>` types the same choice.
- `Add endpoint…` (or `/provider +`) asks for a name, base URL, API key (may be empty for local servers) and protocol (Enter for OpenAI-compatible Chat Completions, `2` Responses, `3` Anthropic Messages), then lists `GET <base>/models` (Anthropic: `/v1/models`) with that key to pick a model. If listing fails it asks for the model id; the context window comes from the listing when present, else asks (Enter for 128000). It appends a `[providers.<id>]` section to `config.toml` and keeps the key in the store. `Esc` at any step writes nothing.
- `/provider logout <id>` removes nib's stored key or ChatGPT login. Environment keys and a Codex CLI login are reported, not deleted. Typing `/provider lo` lists what can be signed out.
- Terminal equivalents: `nib login [service] [--device]` and `nib logout <service>`.

`/model` lists models across configured or signed-in services: built-in catalogs and configured models, custom services' configured models, and the active model. Each row names its service; selecting it switches both service and model. Filter by model name or `service/model`. `/model <model>` typed directly still selects a model of the current service. `/model <service>/<model>` and `/model <service> <model>` still work. Unknown models require configured `context_window` or NIB_CONTEXT_WINDOW. Selection saves atomically to `$NIB_HOME/config.toml`, preserving other settings/comments and current effort. Committed Steps trigger a new Session; old Sessions retain their service and remain resumable. Empty Sessions switch in place; active Turns cannot switch. NIB_PROVIDER/NIB_MODEL still override on next launch, noted in confirmation. Direct file/environment edits remain alternatives.

Without a configured service that has credentials, startup silently uses the first credentialed one: Codex login, then keys for anthropic, openai, deepseek, xai, then custom services. It is not saved until you choose with `/provider` or `/model`. With none, the bottom bar shows `Not signed in`, the welcome line says `No provider · /provider to sign in`, and sending a message opens the `/provider` menu with the draft kept; `nib ask` exits with `No provider · run nib login`.

Alternatively switch in `$NIB_HOME/config.toml`:

```toml
provider = "anthropic"
effort = "high"

[anthropic]
model = "claude-sonnet-5-5"
```

Set `ANTHROPIC_API_KEY` in the environment (or sign in with `/provider`). Environment-only selection also works: `NIB_PROVIDER=openai` with OPENAI_API_KEY. Overrides do not persist. Unknown models need context_window/NIB_CONTEXT_WINDOW; legacy `chat_completions` unknown models retain the 1000000 default.

## OpenAI-compatible endpoints and self-hosting

```toml
provider = "mysite"

[providers.mysite]
protocol = "chat_completions"
base_url = "https://models.example.com/v1"
model = "my-code-model"
context_window = 128000
api_key_env = "MYSITE_API_KEY"
```

Put the key in environment `MYSITE_API_KEY`; configuration stores its name only. protocol/base_url/model/context_window are required; unauthenticated local services omit api_key_env. It is an environment name, not a key. Endpoints added with `/provider` omit api_key_env and keep the key in `auth.json` under the endpoint id; an environment variable named by api_key_env still wins. Ids use ASCII letters/digits/underscore/hyphen; collisions with built-ins or custom error.

`max_output = <positive integer>` (custom services only) sends that value as `max_tokens` on every Session model request of a `chat_completions` or `anthropic_messages` service (`responses` services ignore it); some gateways default to a low limit, while official DeepSeek already defaults to its maximum. Omitted, no limit is sent. Compaction, prediction, `tools.llm` and web search keep their own limits.

`vision = true|false` (custom services only) declares whether the model accepts image input. Omitted, it follows the protocol: true for `responses` and `anthropic_messages`, false for `chat_completions`, where endpoints differ. Built-in rows carry it in the provider/model table: false for `chat_completions` and DeepSeek, true elsewhere. Without vision, attaching an image in the TUI is refused with a notice and `tools.view` returns `{ ok: false, error }`; images already in a resumed Session history become text placeholders.

Chat Completions appends `/chat/completions` to `base_url`; Responses appends `/responses`; Anthropic Messages appends `/v1/messages`, so use a service-root Messages URL. All accept trailing /. Custom Responses uses function Run for endpoints lacking custom tools.

The existing TOML subset adds `[providers.<id>]`, not general nested tables/arrays. Duplicate sections/keys, unknown keys, wrong types, missing fields report path/line. Built-ins still use same-name sections such as [openai], overriding model/base_url/context_window only; Codex extras remain in its documentation.

## Images

User attachments and `tools.view` images are stored under the Session ([session-log.md](session-log.md#images)) and base64-encoded only when a request is built; a missing file becomes a text placeholder.

| Protocol | User attachment | `tools.view` result |
| --- | --- | --- |
| `anthropic_messages` | `image` blocks (base64 source) after the text block | `image` blocks inside the `tool_result` content; the cache breakpoint stays on the last block |
| `responses` | `input_image` data URLs after the `input_text` item | Codex and OpenAI: `input_image` items in the `function_call_output`/`custom_tool_call_output` `output` array; other Responses services: a user message with the image right after the tool outputs |
| `chat_completions` | `image_url` data-URL parts after the text part | a user message with the images right after the last tool message of the group (tool messages cannot carry images) |

Compaction summarizes older images: the summary request replaces each with `[image shot.png 1280×720 omitted]`. Context estimates count 1500 tokens per image.

## Effort and reasoning continuation

`/effort`, --effort, top-level effort, and existing environment precedence still apply.

- Codex retains mappings, custom Run/function fallback, login, WS→SSE fallback.
- OpenAI Responses sends reasoning.effort; off maps to low for known non-disableable models, otherwise none. Default leaves server effort unchanged.
- xAI Responses sends selected effort, omitting unverified off/none/minimal mappings and displaying server default.
- DeepSeek/legacy `chat_completions` retain thinking.type/reasoning_effort. Custom Chat Completions sends reasoning_effort only, off→none, without DeepSeek thinking objects.
- Anthropic families follow pi catalog/families/anthropic.ts. New listed models are adaptive with per-message output_config effort; top-level effort stays low while historical/current effort uses message markers and thinking uses block_binding drop_block. minimal→low; supported models retain xhigh/max. Haiku 5.5 can disable thinking; Opus/Sonnet 5.5/Fable 5.1 off→low. Old budget models use pi minimal=1024, low=2048, medium=8192, high=16384, retaining at least 1024 output tokens and total output ≤128000.

Codex/OpenAI use custom raw-JS Run; xAI, Anthropic, Chat Completions, and custom services use {code} function Run. Preserve historical call/result types. Responses stores complete ordered outputs/encrypted_content; Anthropic stores complete blocks including thinking signatures/redacted_thinking, pairing results by tool_use id. Only complete responses return tool calls; truncated/unfinished inputs never execute.

Anthropic places ephemeral cache_control breakpoints on system, last user/tool_result, and last tool definition. Input tokens = input_tokens + cache_read_input_tokens + cache_creation_input_tokens; cache hits are reads, writes tracked separately. Merge message_start/message_delta usage so final output does not overwrite input-cache counts.

## Credentials, resume, and errors

Children inherit effective configuration through anonymous stdin, skipping files. Pass variable names; each process reads the selected environment key or the key in `auth.json` independently, so stored keys never travel through stdin. Only selected keys enter nib children; bash removes built-in/current custom keys, and read/edit/write/bash refuse `$NIB_HOME/auth.json` like Codex credential files. No secrets in argv/logs/config. Key precedence: environment variable, then `auth.json`, then (Codex only) `CODEX_HOME/auth.json`. Codex independently reads login files; only Codex has a subscription sign-in, and Claude subscriptions are not supported (API keys only).

Legacy provider = "chat_completions", `[chat_completions]`, and `NIB_API_KEY` over `DEEPSEEK_API_KEY` remain compatible; deepseek has its own identity/key. Old Session identities do not convert automatically. Cross-service resume rejects even for matching protocols. Custom logs use `provider:"custom"` plus `custom_provider:"mysite"`, both compared on resume/fork. Responses/Messages also require matching models to protect encrypted/signed continuation.

401 asks users to check the current service's key (its environment variable, or `the key stored by nib`) without exposing authentication response bodies; only Codex rereads or refreshes login once. 429/5xx, network, cancellation, and three timeouts reuse existing policies. Ordinary services do not automatically replay after visible deltas; buffered llm/summaries can retry. See [codex.md](codex.md#stream-failures-and-retries).

nib --help and `/status` show effective service id; `/status` also shows the credential source (`key from ANTHROPIC_API_KEY`, `key stored by nib`, `ChatGPT login stored by nib`, never a key) and cache-write tokens. No model marketplace, background discovery (one `/models` request only while adding an endpoint), or non-Codex OAuth. Design record: [ADR 0022](adr/0022-provider-sign-in.md).
