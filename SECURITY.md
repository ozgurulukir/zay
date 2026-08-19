# Security Policy & Safeguards

## 1. Supported Versions

Security updates and patches are actively provided for the following releases:

| Version | Supported          |
| ------- | ------------------ |
| 0.4.x   | :white_check_mark: |
| 0.3.x   | :white_check_mark: |
| < 0.3.0 | :x:                |

---

## 2. Reporting a Vulnerability

We take the security of Nova Agent seriously. If you discover a security vulnerability (such as a path-traversal vulnerability, sandbox escape in Lua, prompt injection vector that bypasses safety filters, or remote code execution), please **do not open a public issue**.

Instead, report vulnerabilities responsibly via:
- **GitHub Security Advisory:** [Report a vulnerability](https://github.com/ozgurulukir/nova-agent/security/advisories/new)
- **Direct Contact:** Contact the repository maintainers through GitHub profiles.

Please include:
1. Description of the vulnerability and attack vector.
2. Step-by-step reproduction instructions or a minimal Proof of Concept (PoC).
3. Impact assessment.

We will acknowledge receipt within 48 hours and work with you on a coordinated disclosure timeline.

---

## 3. Nova Agent Security & Safety Model

Nova Agent operates as an autonomous coding assistant with direct shell access (`pwsh` on Windows, `bash` on Linux/macOS). To mitigate risks, Nova incorporates multiple layers of defense:

### A. Deterministic Command Safety Matcher
Nova includes a zero-dependency, hardcoded command safety classifier (`src/tools/bash_safety.zig`) that inspects shell commands before execution with `<1µs` latency. It automatically intercepts:
- Recursive deletions targeting root or home filesystems (`rm -rf /`, `rm -rf ~`, `Remove-Item C:\ -Recurse`).
- Raw disk wipes, partition table overwrites (`dd if=/dev/zero of=/dev/sd*`, `mkfs`).
- Fork bombs and runaway shell loops (`:(){ :|:& };:`).
- Windows drive-root or system directory wipes (`Remove-Item $env:SystemRoot`).

### B. Project Root Containment (`validateCwd`)
Tool executions and filesystem modifications enforce strict lexical and realpath containment checks to prevent directory escaping outside the project root without explicit user configuration.

### C. Sandboxed Lua Plugins
Lua plugin execution is confined to a protected runtime environment with strict per-dispatch instruction budgets (`resetInstructionBudget`) and memory limits.

### D. Optional External AI Safety Classifier
For sensitive or high-risk development environments, users can enable a standalone REST safety classifier service (`tools/classifier/`) powered by Transformer models (ModernBERT) to perform deep semantic risk evaluation on generated shell commands.

---

## 4. User Responsibilities & Operational Best Practices

- **Use Version Control:** Always run Nova inside Git-tracked repositories so changes can be audited and rolled back (`git diff`, `git restore`).
- **Least Privilege:** Avoid running Nova with elevated privileges (`root` / `Administrator`).
- **Isolated Environments:** For untrusted repositories or risky tasks, run Nova inside Docker containers or dedicated VMs, or isolate changes using Nova's `/parallel` Git worktree lanes.
- **Review Critical Operations:** Review model actions when interacting with databases, remote infrastructure, or sensitive configuration files.
