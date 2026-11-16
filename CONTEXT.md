# nibcode

A coding agent written in Zig: the model acts by writing code, which runs in a sandbox embedded in the host.

## Sessions and Turns

**Session**:
A complete conversation between the user and agent, resumable through the Session log after the process exits. A process holds one Session at a time.
_Avoid_: conversation, thread, chat

**Session log**:
An append-only record of a Session's model context and its sole source of truth. Resume reconstructs system, completed Steps, and compacted context from it. It does not record all UI events and cannot undo or replay external side effects on files or commands.
_Avoid_: history, transcript (transcript refers only to displayed UI content)

**Turn**:
The entire process from a user message until the agent returns control to the user. A Turn contains one or more Steps.
_Avoid_: round. Note: pi's `turn_start` means one model call, equivalent to a Step here.

**Step**:
One model request and response within a Turn, plus all Runs it initiates, if any. Runs may automatically move to the background when tool waits exceed the threshold; the Step finishes with a notification first, and final results arrive as later messages. The log is committed only after a complete Step; the first Step also commits the Turn's user message.
_Avoid_: iteration, turn

**Subagent**:
An independent Session created when a parent Session delegates a task, returning its final answer and usage to the parent after one Turn. By default the task prompt supplies context; fork inherits the parent's current context, and resume continues the same child Session.
_Avoid_: worker (reserved for tool worker threads), persistent agent

## Execution

**Run**:
One execution of model-written code in a fresh Sandbox. Also the only invocation entry point at the model API level.
_Avoid_: eval, cell, code-mode call, PTC call

**Background Run**:
A long Run waiting for tools continues its original script after automatically moving to the background, delivering its result later. The background notification confirms registration only. It remains the same Run, not a new script or child Session.
_Avoid_: background agent (a subagent), detached Run

**Superseded execution**:
After this Session modifies files, a newly started identical bash command supersedes an active execution from an earlier Run. Supersession means only that the old execution stopped, not that validation passed or failed; it does not terminate subsequent code in the original Run.
_Avoid_: validation passed, validation failed (when describing supersession itself)

**Image**:
A png, jpeg, gif or webp file attached to a user message in the TUI or to a Run result by `tools.view`. The Session log stores a reference to a copy under the Session, never the pixels; requests encode it on demand.
_Avoid_: screenshot, attachment (too broad)

**Sandbox**:
The isolated environment for one Run, with no host capabilities except Tools; destroyed when the Run ends.
_Avoid_: VM, REPL, kernel (these imply persistent state across Runs)

**Tool**:
A host capability exposed to scripts within a Run, such as `tools.read`; the host validates call arguments. The Session log records Run code and the final result returned to the model, not individual Tool calls inside the script. `run` itself is not called a Tool.
_Avoid_: function, programmatic tool, native tool

## Models

**Provider**:
A service with its own identity, credentials, and model catalog, such as Codex, OpenAI, or a user-defined endpoint. Multiple Providers may use the same wire protocol.
_Avoid_: backend, API (too broad)

**Reasoning**:
Model-generated thought summaries and reasoning data needed by subsequent requests. Stored and returned according to the provider; readable content is shown to the user, while encrypted items serve only to continue the session.
_Avoid_: thinking (synonymous here; use Reasoning consistently)

**Profile**:
The model family a Session's behavior is tuned for: codex (gpt-*, codex), deepseek, claude, or default. Resolved from the model name, never the provider, so a custom endpoint serving `deepseek-flash` gets the deepseek Profile. Today it selects which prompt patches apply; context policy and request parameters that differ by family belong here too ([ADR 0025](docs/adr/0025-model-profiles.md)). The resolved name is recorded in the Session log header.
_Avoid_: model config, preset

**Tuning**:
A named model-specific choice with a small set of variants: a prompt slot's text or a runtime value such as how background results and mid-Turn user messages reach the model (`delivery`: `user` or `tool`). A Profile picks a variant for each tuning; `NIB_TUNE` overrides variants for experiments only. Variants are fixed when a Session starts and recorded in its log header ([ADR 0026](docs/adr/0026-tuning.md)). Prompt patches are one kind of tuning.
_Avoid_: knob, setting, patch (for the general concept)

**Context compaction**:
Replacing older model context with a summary, preserving system and recent complete Turns or Steps. The Session log appends a replacement record; original records remain in the file, and resume uses the latest replacement.
_Avoid_: clearing the session, deleting the log
