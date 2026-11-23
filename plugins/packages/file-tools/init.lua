-- init.lua — File Tools
-- Registers read/write/edit/list_directory tools. Output formats mirror the
-- conventions models already know (numbered lines, continuation hints,
-- grouped directory listings) so the model needs no re-training.

-- ── helpers ─────────────────────────────────────────────────────────

local function fail(message)
  return nil, "Error: " .. message
end

-- Binary file extensions we refuse to read as text.
local BINARY_EXTS = {
  zip = true, gz = true, tar = true, tgz = true, bz2 = true, ["7z"] = true,
  png = true, jpg = true, jpeg = true, gif = true, bmp = true, tiff = true,
  webp = true, ico = true, pdf = true,
  exe = true, dll = true, so = true, dylib = true, class = true, jar = true,
  wasm = true, pyc = true, pyo = true, o = true, a = true,
  mp3 = true, mp4 = true, avi = true, mov = true, mkv = true, flac = true,
  ogg = true, wav = true,
  docx = true, xlsx = true, pptx = true, odt = true, ods = true,
}

-- Extract the file extension (without the dot), lowercased. Basename first so
-- a dot in a directory name (e.g. "src.d/file") does not defeat the match; a
-- dotfile (".gitignore") has no extension: `.+` requires at least one char
-- before the final dot, while ".hidden.txt" still yields "txt".
local function extension(path)
  local name = path:match("[^/\\]+$") or path
  local _, ext = name:match("^(.+)%.(%w+)$")
  if not ext then return "" end
  return ext:lower()
end

-- Heuristic: is this path likely a binary file? Extension blacklist first,
-- then a null-byte / high-non-printable ratio sniff on a sample.
local function is_binary(ext, sample)
  if BINARY_EXTS[ext] then return true end
  if sample:find("\0", 1, true) then return true end
  if #sample == 0 then return false end
  local nonprint = 0
  for i = 1, #sample do
    local b = sample:byte(i)
    if b < 9 or (b > 13 and b < 32) then nonprint = nonprint + 1 end
  end
  return (nonprint / #sample) > 0.30
end

-- Deterministic line splitter. `gmatch("[^\n]*")` cannot count empty lines
-- reliably in Lua 5.4, so walk explicitly. A trailing "\n" TERMINATES the last
-- line (so "a\n" -> 1 line, "a\n\n" -> 2 lines, "" -> 0 lines).
-- Advances one cursor instead of re-slicing the tail: `rest = rest:sub(nl + 1)`
-- copies every remaining byte on every line, which is O(N^2) on a file with
-- thousands of lines and can exhaust the sandbox's memory and time budget.
local function split_lines(text)
  if text == "" then return {} end
  local lines = {}
  local start, pos = 1, 1
  while true do
    local nl = text:find("\n", pos, true)
    if not nl then
      table.insert(lines, text:sub(start)) -- final segment (may be "")
      break
    end
    table.insert(lines, text:sub(start, nl - 1))
    start = nl + 1
    pos = start
  end
  -- A trailing "\n" TERMINATES the last line; drop the artifact it leaves.
  if lines[#lines] == "" and text:sub(-1) == "\n" then table.remove(lines) end
  return lines
end

-- One read's output budget, mirroring OpenCode's central truncation: keep the
-- head of the window and say how much was dropped, so wide lines cannot
-- return megabytes. Bytes count the line text plus its newline.
local READ_DEFAULT_LIMIT = 2000
local READ_LINE_BUDGET = 2000
local READ_BYTE_BUDGET = 50000
-- Largest line number `zay.read_file` accepts for start_line/end_line.
local MAX_LINE = 2147483647

-- ── read ────────────────────────────────────────────────────────────

zay.register_tool({
  name = "read",
  description = "Read a file's contents with line numbers. Returns each line as `N: <content>` (1-indexed). Supports offset/limit for paging large files. Refuses binary files. Use this before editing any file and to answer 'what is in this file?'",
  parameters = {
    path = {
      type = "string",
      description = "File path to read (relative to the current active workspace or absolute)",
    },
    offset = {
      type = "integer",
      description = "Line number to start reading from (1-indexed, optional)",
      optional = true,
    },
    limit = {
      type = "integer",
      description = "Maximum number of lines to read (default 2000)",
      optional = true,
    },
  },
  handler = function(params)
    local limit = math.max(1, math.min(math.floor(params.limit or READ_DEFAULT_LIMIT), MAX_LINE))
    local offset = math.max(1, math.min(math.floor(params.offset or 1), MAX_LINE))

    -- Let the bridge slice the window in Zig instead of splitting the whole
    -- file into Lua strings. One sentinel line beyond the window says whether
    -- more lines follow, so the footer needs no second pass over the file.
    local window_end = math.min(offset + limit, MAX_LINE)
    local result, err = zay.read_file(params.path, { start_line = offset, end_line = window_end })
    if result == nil then
      return fail("could not read " .. params.path .. ": " .. tostring(err or "unknown error"))
    end

    -- Binary guard.
    local ext = extension(result.path)
    if is_binary(ext, result.content:sub(1, 1024)) then
      return fail("cannot read binary file: " .. result.path)
    end

    local lines = split_lines(result.content)
    local total = result.total_lines
    if total ~= nil and #lines <= limit and offset + #lines == total then
      -- A window that reaches the end of the file drops a blank final line:
      -- the bridge strips the newline after its last line, and a blank line
      -- has no other bytes to return. `total_lines` says it exists.
      table.insert(lines, "")
    end
    local has_more = #lines > limit
    if has_more then table.remove(lines) end -- drop the sentinel
    local last = offset + #lines - 1
    -- Bridges without `total_lines` (and test doubles) only know the window.
    total = total or last

    -- Number the window under the output budget in a single pass.
    local out, shown, bytes = {}, 0, 0
    for index, line in ipairs(lines) do
      if shown >= READ_LINE_BUDGET or bytes + #line + 1 > READ_BYTE_BUDGET then break end
      table.insert(out, string.format("%d: %s", offset + index - 1, line))
      shown = shown + 1
      bytes = bytes + #line + 1
    end
    local body = table.concat(out, "\n")
    if shown < #lines then
      body = body .. string.format("\n\n... %d lines truncated ...", #lines - shown)
    end

    -- Context-aware footer so the model knows whether to page further.
    local footer
    if total == 0 then
      footer = "\n(Empty file.)"
    elseif #lines == 0 then
      footer = string.format("\n(No lines at offset %d; the file has %d lines.)", offset, total)
    elseif has_more then
      footer = string.format("\n(Showing lines %d-%d of %d. Use offset=%d to continue.)", offset, last, total, last + 1)
    else
      footer = string.format("\n(Showing lines %d-%d of %d. End of file.)", offset, last, total)
    end

    -- Expose the bridge's 1 MB read cap so the model knows to page via bash.
    if result.truncated then
      footer = footer .. string.format("\n[file truncated: showing first 1 MB of %d bytes; page the rest with bash `sed -n`]", result.full_size or result.size)
    end

    local header = string.format("<path>%s</path>\n", result.path)
    return header .. body .. footer
  end,
})

-- ── write ───────────────────────────────────────────────────────────

zay.register_tool({
  name = "write",
  description = "Write content to a file, creating it if it does not exist or overwriting it entirely if it does. ALWAYS prefer editing existing files; NEVER write new files unless explicitly required. NEVER proactively create documentation (.md/README) files unless asked. Read the file first before overwriting.",
  parameters = {
    path = {
      type = "string",
      description = "File path to write (relative to the current active workspace or absolute)",
    },
    content = {
      type = "string",
      description = "The full content to write",
    },
  },
  handler = function(params)
    local ok, err = zay.write_file(params.path, params.content)
    if ok then
      return string.format("Wrote %d bytes to %s", #params.content, params.path)
    end
    return fail("could not write to " .. params.path .. ": " .. tostring(err or "unknown error"))
  end,
})

-- ── edit ────────────────────────────────────────────────────────────

-- Count non-overlapping occurrences of `old` in `text`.
local function count_occurrences(text, old)
  if old == "" then return 0 end
  local count, pos = 0, 1
  while true do
    local found = text:find(old, pos, true)
    if not found then break end
    count = count + 1
    pos = found + #old
  end
  return count
end

-- Replace first or all occurrences (non-overlapping).
local function replace_all(text, old, new)
  if old == "" then return text, 0 end
  local result, count = {}, 0
  local pos = 1
  while true do
    local found = text:find(old, pos, true)
    if not found then
      table.insert(result, text:sub(pos))
      break
    end
    table.insert(result, text:sub(pos, found - 1))
    table.insert(result, new)
    pos = found + #old
    count = count + 1
  end
  return table.concat(result), count
end

zay.register_tool({
  name = "edit",
  description = "Replace occurrences of a string in an existing file. By default replaces only the first occurrence; set replace_all=true to replace every occurrence. The edit FAILS if old_string is not found, and (unless replace_all) FAILS if old_string appears multiple times — provide more surrounding context to make it unique. Preserve the exact indentation from the file (everything after the `N: ` line-number prefix in read output is the real content).",
  parameters = {
    path = {
      type = "string",
      description = "File path to edit",
    },
    old_string = {
      type = "string",
      description = "The exact text to replace (must match the file byte-for-byte, including indentation)",
    },
    new_string = {
      type = "string",
      description = "The replacement text (must differ from old_string)",
    },
    replace_all = {
      type = "boolean",
      description = "Replace all occurrences of old_string (default false)",
      optional = true,
    },
  },
  handler = function(params)
    local replace_all_flag = params.replace_all == true

    -- The description promises new_string must differ from old_string.
    if params.old_string == params.new_string then
      return fail("new_string must differ from old_string")
    end

    -- Read current content to validate before mutating.
    local result, read_err = zay.read_file(params.path, {})
    if result == nil then
      return fail("could not read " .. params.path .. " (read the file before editing): " .. tostring(read_err or "unknown error"))
    end
    -- A capped read holds only the first 1 MB. Rewriting that prefix would
    -- destroy everything past the cap, so refuse before any write — in either
    -- mode (`zay.edit_file` refuses on its own; the replace_all write below
    -- did not).
    if result.truncated then
      return fail("cannot edit " .. params.path .. ": the file exceeds the 1 MB read limit (FileTooLarge); edit it with a script through bash instead")
    end
    local content = result.content

    local occurrences = count_occurrences(content, params.old_string)
    if occurrences == 0 then
      return fail("old_string not found in " .. params.path)
    end
    if not replace_all_flag and occurrences > 1 then
      return fail(string.format(
        "old_string found %d times in %s. Provide more surrounding lines to make it unique, or set replace_all=true.",
        occurrences, params.path
      ))
    end

    local new_content, n
    if replace_all_flag then
      new_content, n = replace_all(content, params.old_string, params.new_string)
    else
      -- Zay's edit_file replaces the first occurrence only.
      local ok, err = zay.edit_file(params.path, params.old_string, params.new_string)
      if not ok then
        return fail("edit failed on " .. params.path .. ": " .. tostring(err or "unknown error"))
      end
      n = 1
      return string.format("Edited %s (1 replacement)", params.path)
    end

    if n == 0 then
      return fail("old_string not found in " .. params.path)
    end
    local ok, err = zay.write_file(params.path, new_content)
    if not ok then
      return fail("could not write edited content to " .. params.path .. ": " .. tostring(err or "unknown error"))
    end
    return string.format("Edited %s (%d replacements)", params.path, n)
  end,
})

-- ── list_directory ──────────────────────────────────────────────────

zay.register_tool({
  name = "list_directory",
  description = "List the contents of a directory. Returns folders and files in separate, alphabetically sorted sections so the structure is easy to scan. Use this to explore an unfamiliar directory; for recursive filename search use glob instead.",
  parameters = {
    path = {
      type = "string",
      description = "Directory path to list (relative to the current active workspace or absolute, default: active workspace)",
      optional = true,
    },
  },
  handler = function(params)
    local dir = params.path or "."
    local result, err = zay.list_dir(dir)
    if result == nil then
      return fail("could not list " .. dir .. ": " .. tostring(err or "unknown error"))
    end

    -- Collect and sort folders and files separately (Zed format).
    local folders, files = {}, {}
    if result.directories then
      for _, d in ipairs(result.directories) do table.insert(folders, d) end
    end
    if result.files then
      for _, f in ipairs(result.files) do table.insert(files, f) end
    end
    table.sort(folders)
    table.sort(files)

    if #folders == 0 and #files == 0 then
      return dir .. " is empty."
    end

    local out = {}
    if #folders > 0 then
      table.insert(out, "# Folders:")
      for _, f in ipairs(folders) do table.insert(out, f .. "/") end
    end
    if #files > 0 then
      if #out > 0 then table.insert(out, "") end
      table.insert(out, "# Files:")
      for _, f in ipairs(files) do table.insert(out, f) end
    end
    return table.concat(out, "\n")
  end,
})
