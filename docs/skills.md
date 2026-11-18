# Skills

[Plugin packages](plugins.md) can also supply skills and manual commands. They use `<plugin>:<name>` namespaces and are available only when their package is enabled; package switches are separate from the native skill switches below.

New Sessions scan in this order, looking only one level deep for `<name>/SKILL.md` in each directory; later skills override earlier skills with the same name:

1. `~/.agents/skills`
2. `$NIB_HOME/skills` (default `~/.nib/skills`)
3. `<project>/.agents/skills`
4. `<project>/.nib/skills`

project uses the same root as the project AGENTS.md. Symlink directories are supported; hidden directories and loose Markdown files are ignored.

SKILL.md uses the [Agent Skills](https://agentskills.io/specification) format:

```markdown
---
name: example
description: Describe when to use this skill.
---
Put specific instructions in the body.
```

name defaults to the directory name; description must be nonempty and supports plain, single-quoted, double-quoted, `|`, and `>` block text, retaining at most 1024 characters. Only files up to 64 KiB are read; other YAML fields are ignored. `disable-model-invocation: true` excludes the skill from the model index.

All skills are disabled by default. Enable each in `$NIB_HOME/config.toml`:

```toml
[skills]
example = true
```

Only `true` enables a skill; `false` or absence disables it. Enabled entries without corresponding files are excluded from the index; `/status` shows the missing count. `/skills` lists all discovered skills, sources, switches, and short descriptions; `/skills on <name>` and `/skills off <name>` atomically update global configuration, preserving other content. Skills with model invocation disabled cannot be enabled.

Switches affect new Sessions only; the current Session's system is unchanged. `/status`'s `Skills: N on · M found` shows counts from Session creation.

After AGENTS.md, system appends a name-sorted index only of user-enabled skills. For matching tasks, the model loads full instructions with `tools.read`, resolving relative paths against the skill directory. With no enabled skills (even if skills exist on disk), no prompt text or model calls are added. Each enabled skill's description enters every new Session's system prompt, so it costs index tokens even when unused.

Resumed Sessions retain their original system without rediscovering skills; file changes affect new Sessions only. `/status` shows enabled, discovered, and skipped counts; reasons are recorded in the Session log's `skills.skipped`, not the conversation.

## Mentioning a skill

`$name` anywhere in a message uses that skill for the message only, without enabling it: `$release prepare 0.11.0`, `review this PR with $review`. A token is `$` at the start or after whitespace, followed by letters, digits, `_` or `-`; it counts only when it exactly matches a discovered skill name (so `$HOME`, `$1` and misspellings stay plain text). Skills with `disable-model-invocation: true` can be mentioned. Typing `$` in the TUI opens a completion menu with all discovered skills. Type a name prefix to filter, or use the arrow keys to scroll through the list.

On send, each distinct mentioned skill's SKILL.md (same 64 KiB limit) is appended after the message as `<skill name="…" location="…">body without frontmatter</skill>`, with one line saying relative paths resolve against its directory. The expanded text is what the Session log stores and what resume sends, so files are not read again; the TUI transcript shows only what was typed. The system prompt, config and `/skills` are unaffected. `nib ask` expands the same way.
