---
status: accepted
date: 2026-11-06
---

# Provider sign-in: `/provider`, a credential store, nib-owned Codex OAuth

**Decision:** Choosing a service and signing in move to `/provider`; `/model` lists configured or signed-in services' models with their service names, and selecting a row switches both service and model. nib keeps its own credentials in `$NIB_HOME/auth.json` and signs in to ChatGPT itself, instead of borrowing the Codex CLI's login. Claude subscriptions are not supported; Anthropic uses API keys only.

## Why

Users do not edit config files, and a fresh install showed a Codex model it could not use. Interaction has to cover everything: pick a service, give a key or sign in, add an endpoint, pick a model. `/provider` handles service setup and credentials; `/model` provides quick model selection across services already configured or signed in, without requiring a separate service switch.

## Provider and model split

- `/provider` lists the five built-in services and custom `[providers.<id>]` services with a status column (`signed in · ChatGPT`, the environment variable name a key comes from, `key stored`, `—`, or a host). Selecting a service without credentials asks for a key (masked) or starts the ChatGPT sign-in; selecting a credentialed one switches to it. `Add endpoint…` is a four-step form (name, base URL, key, protocol) followed by a model pick from `GET <base>/models`, or typed text when listing fails. Sign-out is `/provider logout <service>`; typing `/provider lo` lists the services nib can sign out of.
- `/model <model>` selects a model of the current service. `service/model` and `service model` keep working.
- Switching keeps the existing rule: a new Session when Steps already exist; the choice is saved to `config.toml` and `NIB_PROVIDER`/`NIB_MODEL` still override at startup.

## Credential store and precedence

`$NIB_HOME/auth.json`, always mode 0600, replaced atomically. It holds API keys by service id and nib's Codex OAuth tokens (same `tokens` shape as the Codex CLI file, so one reader and one refresher serve both). Precedence: environment variable key, then the store, then (Codex only) `CODEX_HOME/auth.json`, which is used in place and never copied. Keys are never printed in the TUI, logs, errors, or `/status` (which names only the source). The store joins the credential files that read/edit/write and bash refuse to touch. Sign-out removes only nib's own credential and reports environment keys and an imported Codex login. `config.toml` still accepts no secrets; custom endpoints keep their key in the store.

## Codex OAuth owned by nib

nib runs the same flow as the official Codex CLI (`openai/codex`, `codex-rs/login`, read 2026-11-06): authorization code with PKCE against `https://auth.openai.com` using the CLI's public client id, a callback server on `127.0.0.1:1455`, token exchange, `id_token` claims for the plan and account id, refresh with the refresh token, and device-code login for machines without a browser. Refreshed tokens are written back to the file they came from. A refresh happens when the access token is a JWT that is expired or about to expire, or after a 401.

**Risk:** this relies on a public client id and endpoints that OpenAI can change without notice. If the flow breaks, `codex login` keeps working because the CLI's file is read as a fallback. Tests run against a mock issuer only; the real flow is unverified in CI. Cross-process refresh has no lock, so two nib processes refreshing at once may race on a rotating refresh token.

## First launch

Startup uses the configured service when it has credentials; otherwise it silently picks the first credentialed one (Codex login, then anthropic, openai, deepseek, xai keys, then custom services) without saving it. With nothing credentialed the bottom bar says `Not signed in`, the welcome area says `No provider · /provider to sign in`, and sending a message opens the `/provider` menu with the draft kept. `nib ask` exits with `No provider · run nib login`. `nib login [service]` and `nib logout <service>` cover the same ground in a terminal.

## Consequences

- No Claude subscription login: out of scope; Anthropic uses API keys only.
- Model discovery stays minimal: one list request, only while adding an endpoint. Built-in catalogs are unchanged.
- Test hooks `NIB_AUTH_ISSUER`, `NIB_AUTH_PORT`, `NIB_AUTH_NO_BROWSER` exist for mock issuers; they are not user settings.

**Reconsider when:** the OAuth flow changes, a service offers subscription login that nib may use, or users need several accounts per service.
