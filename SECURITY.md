# Security

## Reporting a vulnerability

Please report vulnerabilities through the [GitHub Security Advisory
reporting page](https://github.com/ozgurulukir/zay/security/advisories/new).
Do not report them in a public issue. Include the affected version, impact,
and reproduction steps when possible.

## Execution and safety boundaries

Zay can run shell commands (`bash` on Linux and macOS, `pwsh` on Windows)
with the permissions of the user running Zay. Ordinary commands run without
a per-command confirmation prompt.

Before a shell command or a `skill` command-mode call runs, Zay classifies
it. It uses the built-in pattern matcher unless an external classifier URL
is configured. If the external request fails, Zay falls back to the built-in
matcher. A command classified as unsafe prompts for interactive approval.
The built-in rules recognize selected patterns and do not detect every
dangerous command. See the [Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md)
for the classifier flow and limits.

The shell tool checks its requested working directory against the project
root. Symlink resolution is best-effort, and this check does not constrain a
process's filesystem access after it runs. Parallel lanes use separate Git
worktrees to isolate branch and working-file changes; they do not limit
operating-system permissions. Neither mechanism is an operating-system
sandbox.

Lua plugins run in a restricted runtime. See [Plugin permissions and runtime](docs/plugins/permissions-and-runtime.md) for its boundaries.

## Operating guidance

- Prefer Git-tracked repositories so changes can be reviewed and recovered.
- Run Zay without elevated privileges.
- Use an operating-system container or virtual machine when untrusted code
  needs a stronger isolation boundary.
- Review changes and consequential operations, especially around databases,
  remote infrastructure, or sensitive configuration.
