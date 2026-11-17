# Plugins

Plugins install a group of skills, Markdown commands, scripts and MCP server definitions. They use a subset of the Claude Code package layout, not a new runtime API. There is no marketplace, automatic update, dependency installer or install-time script execution.

## Install and enable

```sh
nib plugin install ./my-plugin
nib plugin install https://github.com/owner/repository.git
nib plugin install https://github.com/owner/repository.git --path plugins/my-plugin
nib plugin list
nib plugin on my-plugin
nib plugin off my-plugin
nib plugin uninstall my-plugin
```

In the TUI, `/plugins` lists installed packages and their compatibility limitations; `/plugins on <name>` and `/plugins off <name>` change the same switches. Installation requires no provider credentials. Git sources require Git; local directory installation does not.

Every installation is disabled, including a reinstall. Installing copies files without running package commands or discovering MCP tools. Only explicitly enabled packages contribute to new Sessions. Enabled packages activate their supported components together; package skills do not need separate `/skills` switches. An off package is also unavailable to explicit mentions and commands.

Switches are stored in `$NIB_HOME/config.toml`:

```toml
[plugins]
my-plugin = true
```

Changes apply to new Sessions, not the current one. Enabling a package trusts its instructions and allows its declared MCP processes/network connections to run using nib's existing MCP sandbox and credential rules. Unsupported components remain inactive and are listed on installation, enablement and `/plugins`.

## Supported layout

```text
my-plugin/
├── .claude-plugin/plugin.json
├── skills/
│   └── review/SKILL.md
├── commands/
│   └── check.md
├── .mcp.json
└── scripts/
```

The manifest is required and contains at least `{"name":"my-plugin"}`. Names use ASCII letters, digits, `_` and `-`, start with a letter or digit, and are at most 100 bytes. Metadata such as version, author and description is accepted without adding model context. `defaultEnabled` does not enable installation.

`skills` and `commands` in the manifest accept a relative path or array of paths, in addition to their standard directories. Skill paths can name a collection directory, one skill directory, or its `SKILL.md`; command paths can name a flat directory or a Markdown file. Paths stay inside the package. Repeated paths are deduplicated; duplicate component names are rejected. A skill's frontmatter name cannot escape its package namespace.

### Skills and commands

Skills use nib's [existing skill parser](skills.md). A package named `my-plugin` supplies `my-plugin:review`, invoked with `$my-plugin:review` or `/my-plugin:review`. Model-invocable skills are indexed when the package is enabled, except those with `disable-model-invocation: true`, which remain available explicitly.

Legacy `commands/*.md` files become manual-only prompt entries: `/my-plugin:check arguments`, or `$my-plugin:check`. Frontmatter and descriptions are optional for commands. They do not enter the model's automatic skill index. `$` completion includes enabled package entries.

Slash invocation substitutes `$ARGUMENTS` with the complete argument string; `${CLAUDE_PLUGIN_ROOT}` expands to the installed package root in explicitly loaded bodies. Ordinary skill reads retain their source bytes; the skill index includes the package root for resolving that variable. Relative resource paths resolve against the entry file's directory. Expanded bodies enter the Session log just like explicit native skill mentions.

This is not full Claude Code runtime compatibility. Per-entry tool restrictions, model selection, fork context, agent selection and hook frontmatter are not enforced; detected declarations are reported. Shell interpolation such as `` !`command` `` is never executed by the plugin loader. Positional argument substitution is not supported.

### MCP

Servers may be declared in `.mcp.json`, inline under manifest `mcpServers`, or in relative JSON files named by that field (a path or array of paths). JSON files can wrap definitions in `mcpServers`. Server IDs use `<plugin>__<server>`; a collision with another configured server fails explicitly.

Supported server fields are `command`, `args`, `env`, `url`, and `type` (`stdio` or `http`). `${CLAUDE_PLUGIN_ROOT}` expands in command, arguments, URL and environment values. Environment values can reference `${VARIABLE}`; resolution happens at process launch, so resolved credential values are not copied into configuration snapshots. Missing referenced variables fail explicitly. Do not put literal credentials in package files: package declarations, including literal values, are recorded in Session logs. Other environment variables remain filtered by the existing MCP transport.

Unsupported server fields or transports are reported and that server is not loaded. They are not silently removed from an otherwise active server. HTTP headers and OAuth configuration are not supported by the plugin adapter in this version; standalone MCP configuration remains available.

### Not supported

Agents, Claude lifecycle hooks, LSP servers, output styles, workflows, themes, monitors, executable `bin/` registration, dependencies and interactive `userConfig` are not implemented. Their declarations/default locations are reported when detected. Bundled scripts can still be called explicitly through existing tools; installation never runs them.

## Storage and Sessions

Packages are copied into unique directories under `$NIB_HOME/plugins/store`; `$NIB_HOME/plugins/installed` tracks the active installation of each name. A name cannot be installed twice without uninstalling it first. Each install is a snapshot, not a symlink to a working directory. Symlinks and special files are rejected; `.git` is excluded. Copying is bounded to 10,000 entries, 64 MiB and 64 directory levels. Git cloning has a two-minute timeout and does not fetch submodules.

New Sessions snapshot the enabled invocation catalog and MCP definitions. Resume and child Sessions retain that catalog rather than rediscovering installed plugins. Uninstall removes the registration and disables future Sessions, but retains stored package files so existing Sessions keep working. Reinstalling the same name uses a new storage directory and never substitutes new files into an old Session. There is no store garbage collection in this version. Manually modifying/removing stored files can break existing Sessions.
