# 0027: Opt-in plugin packages

Status: accepted

Installable packages reduce the manual work of copying skills and configuring related MCP servers. Reuse the Claude-style manifest and directory layout without promising full Claude Code runtime compatibility or building a marketplace.

Packages contribute namespaced skills, manual Markdown commands and supported MCP definitions through existing execution paths. Installation copies files and defaults off; explicit package enablement gates every component, including manual invocation. Switches apply only to new Sessions. Unsupported components and MCP fields are reported, never executed or silently translated into different semantics. There is no plugin SDK or general lifecycle API.

Each install has a unique immutable-by-convention storage directory. Session logs snapshot the invocation catalog alongside MCP definitions; child Sessions inherit the same configuration. Uninstall unregisters a package but keeps its files for existing Sessions, avoiding a reinstall changing the meaning of an old file reference. Garbage collection and updates can be added if retained storage becomes a practical problem.

Reconsider component support when concrete packages require it. Hook event names alone are insufficient evidence of equivalent execution, cancellation and return-value semantics.
