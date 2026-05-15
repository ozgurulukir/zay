Write a complete file in one tool call.

Use this tool only for new files or full rewrites. For targeted edits to existing files, prefer `edit_file` with hashline anchors from `read`.

<parameters>
- `path` — required. File path to create or overwrite, relative to the current working directory unless absolute.
- `content` — required. The complete file content to write.
</parameters>

<rules>
- Always include BOTH `path` and `content`.
- Never put the path inside `content`.
- Never call this tool with only `content`.
- `content` is the full file body, not a patch, diff, or explanation.
- Parent directories are created automatically.
</rules>

<example>
{
  "path": "src/main.zig",
  "content": "const std = @import(\"std\");\n\npub fn main() !void {\n    std.debug.print(\"hello\\n\", .{});\n}\n"
}
</example>
