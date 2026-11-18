# 0015 Agent fork: reuse parent context in an independent child Session

## Decision and model choice

`tools.agent` adds optional `fork?: boolean`, default false. Ordinary creation still starts with independent system and task prompt; `fork:true` copies the parent's complete current history after compaction, preserving system/tool schema byte for byte without recovering compacted-away history. Each fork allocates a new `aN`, resumable by that id; passing both fork and resume is an argument error. Results, background execution, cancellation, limits, and continuation reuse existing agent mechanisms; see [delegation interface](../tool-delegation.md).

model/effort inherit the parent's current effective configuration, with per-call overrides allowed. Matching parent model and effort preserves the opportunity to reuse its cache prefix; changing either loses this advantage. Default creation still supports cold-start children on other models; switching models is not fork's purpose. Codex fork checks model consistency to avoid passing encrypted reasoning to another model; overrides do not bypass this check.

The delegating main model chooses fork or ordinary creation by task, without automatic rules. Fork may reduce repeated investigation but carries longer input and may inherit assumptions/biases; ordinary creation pays rereading costs for a more independent perspective. This tradeoff varies by task; no measured threshold reliably maps context length, expected Steps, or task category to a choice. Tool descriptions state inheritance, model/cache conditions, cost observations, and execution boundaries without turning observations into selection rules.

## Capture point and execution boundaries

The capture includes the current assistant message initiating fork, not just the previous completed tool result, preserving its reasoning (including Codex encrypted items) and tool calls. Synthetic tool results close the current assistant's calls, followed by the child task user prompt. These results close the message sequence, represent no real parent Run result, and do not rerun the parent Run in the child. This retains fresh context without waiting for the executing parent Run.

Fork's first work request does not automatically compact inherited history, preventing token estimates/window thresholds from rewriting the prefix before first transmission; later requests use existing automatic thresholds.

Fork is an independent child Session, not a parent rollback point. Depth matches ordinary agents: inherited system/schema still describe agent, but runtime agent calls remain unavailable; recursion is not opened. Parent/child share cwd without worktree isolation. Existing locks, atomic replacement, and stale checks still apply; bash/editors do not participate in locks. Fork also copies existing file-version observations at capture, preventing writes based on inherited stale content from bypassing stale detection; observations are not refreshed from disk. History/version arrays last only through Step end; background fork serializes task-owned input before queuing, without accumulating per-Step snapshots indefinitely.

## Evidence and confidence

- **Observed motivation:** Among 105 locally created child Sessions, roughly 6 initial read-only Steps consumed about 22% of time; full subtasks took about 12 Steps, 3 minutes, and around 290,000 cumulative prompt tokens. Total tokens include repeated context/cache input, not fees. This shows rereading cost, not fork savings. See [cost reference](../tool-delegation.md) for samples/distributions.
- **High-confidence semantics:** Copying current history, preserving system/schema bytes, including current assistant and synthetic closing results, independent ids, and runtime depth boundaries are locally verifiable and cache-service-independent.
- **Medium-confidence expected benefit:** Parent context may reduce reinvestigation, but longer input may add cost or irrelevant context. No real fork comparison confirms net benefit yet.
- **Routing hypothesis awaiting measurement:** Codex fork keeps the parent's `prompt_cache_key` to route matching prefixes to the same cache; confidence in actual server reuse is low, without protocol guarantees. Matching model/effort and byte prefixes are prerequisites, not hit promises; adjacent-Step effort cache statistics do not prove fork hits. See [Codex cache notes](../codex.md#fork-and-parent-cache-routing).

## When to reconsider

With identical parent prefix/model/effort, compare parent versus independent keys for first-request hit rate, uncached input, and time. If shared keys do not help, adjust routing without changing inheritance semantics. If complete-context costs/interference outweigh reduced reading, consider smaller explicit slices. Evaluate depth and worktrees separately when real nested-delegation or workspace-isolation needs arise, without implying them in fork.
