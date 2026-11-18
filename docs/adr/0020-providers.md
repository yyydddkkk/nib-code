---
status: accepted
date: 2026-11-05
---

# Providers are data; at most three wire protocols

**Decision:** Keep a small service collection. Provider tables hold identity/defaults; protocols handle requests, responses, reasoning continuation, and usage. Support only responses, `chat_completions`, anthropic_messages. Codex adds ChatGPT login and dedicated WebSocket to Responses, without duplicating serialization/event parsing. Session/Sandbox/Run gain no service branches; same-protocol services add one table row.

## Services and models

Built-in rows include id, display name, protocol, base_url, api_key_env list, default_model, and a few models with context_window. Snapshot: 2026-11-06; this is not discovery or an account-access guarantee.

| id | Display name | protocol | base_url | Credentials | Default model |
| --- | --- | --- | --- | --- | --- |
| codex | Codex | responses | https://chatgpt.com/backend-api | CODEX_HOME/auth.json | gpt-6.2-sol |
| openai | OpenAI | responses | https://api.openai.com/v1 | OPENAI_API_KEY | gpt-6.2-sol |
| anthropic | Anthropic | `anthropic_messages` | https://api.anthropic.com | ANTHROPIC_API_KEY | claude-sonnet-5-5 |
| deepseek | DeepSeek | `chat_completions` | https://api.deepseek.com | DEEPSEEK_API_KEY | deepseek-flash |
| xai | xAI | responses | https://api.x.ai/v1 | XAI_API_KEY | grok-4.7 |

Model snapshot: user-provided models.dev api.json, fetched 2026-11-06. Anthropic defaults to claude-sonnet-5-5, listing claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5, claude-fable-5-1, all window 1000000/output 128000. OpenAI API now defaults to gpt-6.2-sol, adding gpt-6.2-sol/astra from the official model docs, both window 1050000/output 128000; gpt-6.1-sol/terra remain listed. xAI defaults to grok-4.7, listing grok-4.7/4.6, both window 500000. Codex now defaults to gpt-6.2-sol (500000), also listing gpt-6.2-astra (272000), per upstream pi's backend catalog; both use minimum low reasoning when disabled. DeepSeek deepseek-flash/deepseek-v4-pro windows 1000000. Reasoning compatibility comes from pi catalog/families/anthropic.ts.

## Configuration and identity

Top-level provider selects service id; NIB_PROVIDER takes precedence. NIB_MODEL, NIB_BASE_URL, NIB_CONTEXT_WINDOW override current-service fields. Built-ins use same-name sections; [codex] retains transport, run_tool, reasoning_summary.

Custom `[providers.mysite]` accepts only protocol, base_url, model, context_window, api_key_env. Nonempty ids use ASCII letters/digits/underscore/hyphen, without built-in/compatibility-id conflicts. All four connection/model fields are required; api_key_env is optional for unauthenticated local services. Store environment names only, never secrets. Extend existing TOML subset without dependencies; unknown/duplicate sections/keys, wrong types, and missing fields report config path/line.

```toml
provider = "mysite"

[providers.mysite]
protocol = "chat_completions"
base_url = "https://models.example.com/v1"
model = "my-code-model"
context_window = 128000
api_key_env = "MYSITE_API_KEY"
```

Legacy `provider = "chat_completions"`, `[chat_completions]`, and NIB_API_KEY precedence over DEEPSEEK_API_KEY remain unchanged as a separate compatibility identity using DeepSeek defaults. Old codex/chat_completions logs stay resumable; never automatically relabel old identities as deepseek. Cross-service-id resume rejects even with matching protocols. Log/compare custom ids too. On resume, encrypted or signed continuation data is replayed only for its original model.

Effective configuration reaches children through existing anonymous stdin pipes: provider id, protocol, nonsecret fields, secret environment names; each process reads environment keys independently. No credentials in argv, config files, or logs. tools.llm/summaries reuse effective configuration.

## Runs, reasoning, and usage

Codex retains custom raw-JS Run/function fallback; OpenAI Responses also uses custom, already supported by pi openai-responses-shared custom/grammar. xAI, Anthropic, Chat Completions use function Run {code}. Preserve historical call types and pair results accordingly, never rewriting history for current definitions.

Responses shares complete output_item.done arguments, completed settlement, encrypted_content, and ordered-output persistence with Codex. Ordinary services use `/responses` and Bearer keys; Codex retains `/codex/responses`, dedicated headers, one login-file reread on 401, Session WS→SSE fallback. Ordinary services never read Codex credentials. Errors include service id/status/safe diagnostics only, without authentication contents.

Anthropic uses `/v1/messages`, x-api-key, anthropic-version:2023-06-01. Place ephemeral cache_control breakpoints on system text and trailing cacheable user/system content; final tool entries may mark fixed prefixes, without breakpoints on every block. Pair tool_use/tool_result by id, merging consecutive results into user blocks. Preserve signed thinking/redacted_thinking completely in provider-tagged reasoning.data; accumulate thinking_delta/signature_delta, never reconstructing signatures from readable text. Resume returns original block order.

Anthropic Usage.prompt_tokens = input_tokens + cache_read_input_tokens + cache_creation_input_tokens; prompt_cache_hit_tokens = cache_read_input_tokens; new zero-default prompt_cache_write_tokens = cache_creation_input_tokens. completion_tokens = output_tokens. Aggregation/logs/children/stats propagate the field; old missing fields read as zero. Merge message_start input usage with message_delta final output, without overwriting with zero.

`/effort` remains unified. Codex none/low/default mappings unchanged; OpenAI Responses sends supported reasoning.effort. xAI omits none/minimal without verified mappings. Chat Completions retains thinking/reasoning_effort. Anthropic uses pi families to distinguish adaptive/budget: adaptive sends thinking.type=adaptive and output_config.effort, minimal→low, xhigh/max only on explicitly supported models; older models use thinking.type=enabled/budget_tokens, leaving max_tokens output room. off maps to minimum supported effort for non-disableable models; default retains service defaults. Budgets follow pi reasoning.ts defaults, without a new scale.

Retries reuse existing 429/5xx/network/timeout classification, cancellation, deadlines. Ordinary-key 401 asks users to check the corresponding environment key; only Codex rereads login once. Ordinary services with visible deltas do not automatically replay; buffered calls can retry safely. Never execute incomplete tools or commit failed Steps.

## Acceptance and non-goals

Unit tests cover configuration, bodies, realistic SSE fixtures; local mocks cover text, Run round trips, signed/encrypted continuation, cache read/write usage, multi-Turn resume, 401, child inheritance, cross-provider rejection. Existing units and all AGENTS.md e2e pass. No real models, paid requests, or nib-bench for acceptance.

No non-Codex OAuth, model discovery endpoint, provider marketplace, per-provider UI, or cross-protocol history conversion. /status and CLI help show service ids; fixed UI text is English.

**Sources:** Local pi `packages/ai/src/providers/{openai-codex,openai,anthropic,deepseek,xai}.ts`, matching models wrappers, `catalog/providers`, `catalog/families`, src/api/{openai-responses,openai-responses-shared,anthropic-messages,openai-completions}.ts. This ADR is approved; code/verification determine delivery status.

**Implementation tradeoffs:** Custom services retain enum log layout, with provider=custom plus custom_provider=`<id>` as full identity compared on resume/fork; preserve old parsing/provider names. Cache-write fields default zero and omit zero on serialization, preserving old usage shape. Custom Responses uses function Run for endpoints lacking custom; custom Chat Completions omits DeepSeek-specific thinking. Shared Responses lives in responses.zig, including Codex auth/WS extensions, without protocol duplication. Anthropic per-message effort uses pi managed-effort markers/block_binding. Verification used local mocks only, no real services.
