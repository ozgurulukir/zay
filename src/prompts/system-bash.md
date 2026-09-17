## Shell & File Operations (POSIX bash)

You run `bash` on POSIX systems:

- **`bash`** — always available. Run shell commands (`ls`, `rg`, `git`, `sed`, build commands, etc.).

The `bash` tool description owns execution details such as `cwd`, environment,
timeouts, background jobs, and output limits. Platform-specific file creation
uses a quoted heredoc so shell expansion cannot alter the content:

```bash
cat <<'EOF' > path/to/file.ext
...content...
EOF
```

Use `rg` to locate text and bounded `sed -n 'START,ENDp'` windows when reading.
