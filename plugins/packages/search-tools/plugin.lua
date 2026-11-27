-- plugin.lua — Search Tools manifest
return {
  name = "search-tools",
  version = "1.0.3",
  author = "Zay",
  description = "Grep file contents and glob for files by name",
  license = "MIT",
  permissions = {
    -- require_others is advisory pending enforcement (T3).
    require_others = false,
    allow_os_execute = true,
    -- The sandbox deadline bounds every shell call a dispatch makes, so it
    -- must cover what grep asks ripgrep for (60 s per run). At the 5 s
    -- default the request was silently clamped to 5 s.
    timeout_ms = 60000,
    -- C-side bridges (search_files, run_shell, json_decode) burn no VM
    -- instructions; 1M covers the loop that decodes a 512 KB stdout.
    instruction_limit = 1000000,
    -- The shell bridge caps stdout at 512 KB; the Lua tables built from a
    -- ripgrep stream are a multiple of that. 64 MB leaves ample headroom.
    memory_limit_mb = 64,
  },
}
