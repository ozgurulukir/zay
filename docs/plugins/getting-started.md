# Zay Plugin Development Guide

Zay supports extending its capabilities through Lua plugins. Plugins can register
custom tools, subscribe to tool-call events, access the filesystem, run shell commands,
interact with git, and store persistent state.

## Quick Start

For a user-wide plugin, create a plugin directory with two files:

```
~/.config/zay/plugins/my-plugin/
  plugin.lua    -- manifest (required)
  init.lua      -- entry point (required)
```

Project-local plugins remain available under `.zay/plugins/`; the checked-in
repository `plugins/` directory contains the distribution catalog and is not
the TUI install destination.

### plugin.lua (manifest)

```lua
return {
  name = "my-plugin",
  version = "1.0.0",
  author = "Your Name",
  description = "Does something useful",
  license = "MIT",
  permissions = {
    file_access = false,
    network_access = false,
    require_others = false,
  },
}
```

### init.lua (entry point)

```lua
zay.register_tool({
  name = "hello",
  description = "A friendly greeting",
  parameters = {
    name = { type = "string", description = "Who to greet" },
  },
  handler = function(params)
    -- params is a Lua table (JSON parsed automatically)
    return "Hello, " .. (params.name or "World") .. "!"
  end,
})
```

**Tool naming:** Tools are exposed to the AI model as `lua__<plugin>__<tool>`
(e.g. `lua__my-plugin__hello`). The prefix is added automatically.

**Parameters:** JSON arguments from the AI model are automatically parsed into
a Lua table before the handler is called. Access `params.param_name` directly.

### prompt.md (optional model instructions)

A plugin MAY include a `prompt.md` next to `plugin.lua`. Its body is injected
into the AI model's system prompt, so the model learns how to call the
plugin's tools correctly before it ever invokes one.

```
my-plugin/
├── plugin.lua
├── init.lua
└── prompt.md      ← optional, plain markdown (frontmatter optional)
```

`prompt.md` is plain markdown. An optional YAML frontmatter block is stripped
before injection (same format as `SKILL.md`):

```markdown
---
description: Short summary of what these tools do.
---

Always confirm with the user before overwriting an existing file.
Prefer the `edit` tool for small changes over `write`.

When the user asks to create a new file, use `write` with the full path.
```

**How it works:** Zay scans `<home>/.config/zay/plugins/*/prompt.md` and
`plugins/*/prompt.md` at session start (a pure text scan — no Lua state is
created). The former `.zay/plugins/*/prompt.md` root is scanned as a legacy
fallback, before the visible project root. Each non-empty body is wrapped in a
`<plugin_prompts>` block in the system prompt:

```
<plugin_prompts>
  <plugin name="my-plugin">
    Always confirm with the user before overwriting an existing file.
    ...
  </plugin>
</plugin_prompts>
```

Notes:
- A plugin with no `prompt.md` contributes nothing — only tools registered via
  `zay.register_tool` are visible to the model.
- A plugin with `prompt.md` but no `plugin.lua` still contributes prompt text.
- A project plugin overrides a global plugin with the same manifest `name`
  field. (The `prompt.md` scan is a pure text pass keyed by directory name, so
  its override follows the directory name.)
- Each plugin's `prompt.md` contributes at most 32 KB, with a 64 KB aggregate
  cap across all plugins; oversized bodies are skipped.
- Changes to `prompt.md` take effect on the next session or lane.
