# Principles

nib is a small, focused, quiet coding agent: a place to write code together with AI.

It is for engineers who work in a terminal, read diffs, and care about speed and control. It is not an IDE suite, a general assistant, or an agent that runs unattended for a day.

## Focused

nib does coding: reading, changing, and verifying code. Larger agents grow heavier as they serve wider audiences; nib does not follow.

Ask of every feature: **does it make reading, changing, or verifying code faster or more reliable?** If not, it does not belong here, however popular it is.

## Small and refined

Focus is the cause; small and refined is the result. Fewer features leave room to get each detail right.

- Defaults over options. A new setting needs a reason; removing one does not.
- One static binary, no runtime dependencies.
- Few concepts, each with one job (see [README](README.md#what-we-mean-by-minimalism)).
- Subtract regularly. Session logs show what is actually used; what is not used goes.

Ask: **does this make nib bigger, and is what it adds worth it?**

## Quiet

Success is silent; only deviations stand out.

- No tips, what's-new screens, upsells, emoji, sounds, or decorative animation.
- No background update checks and no telemetry. `nib update` updates only when you run it.
- State only known facts. A green check confirms the object named next to it.
- Answers end with the result, not a long summary.
- Release at our own pace, not the trend's.

## Together

The person stays in the loop. Each Run shows what it read, changed, and ran; you can interject at any time and `/undo` edits. Long unattended work and autonomous multi-agent orchestration are not the direction.

## Nothing enters the model's context unchosen

Skills are off until you enable them. Interface text never asks the model to write extra words; labels come from tool results, diffs, and exit codes. Every output token costs time.

## Measured, not guessed

Speed is judged against other agents under the same model, effort, and service tier — never by tuning for benchmark tasks. Changes that trade speed for quality are fine when the data says the trade is worth it. Prefer observed state over guessed thresholds, and mechanisms over prompt rules: rules tend to make models think and write more.

Extension is through skills, command-line tools, MCP servers, and hooks, all off until the user enables them. Opt-in [plugin packages](plugins.md) install related skills, commands and MCP definitions together; they reuse existing execution paths, not a plugin runtime API.

## Not planned

Browser or desktop automation, document and slide generation, plugin marketplaces, theme systems, automatic/background updating, telemetry, Windows support, and unattended autonomous orchestration.
