Execute bash commands, scripts, and CLI tools.
<instructions>

- Use `cwd` to set working directory, not `cd dir && …`
- Prefer `env: { NAME: "…" }` for multiline, quote-heavy, or untrusted values; reference as `$NAME`
- Quote variable expansions like `"$NAME"` to preserve exact content
- If your command times out, you can try again by passing the `timeout` parameter longer than 10 seconds

</instructions>

<anti-patterns>
Use the read tool instead of shell commands such as cat, head, tail, less, more, ls, sed -n, or awk NR when inspecting files or directories.
Use the search_codebase tool instead of shell commands such as find, fd, rg, grep.
</anti-patterns>
