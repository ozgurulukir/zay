//! Local shell command safety classifier.
//!
//! Covers BOTH the bash and PowerShell (`pwsh`) shells — the model-facing
//! shell tool on Windows is `pwsh`, and this local matcher backs the
//! destructive-command backstop for whichever shell is host-selected. The
//! bash patterns are kept unchanged (defense-in-depth is not exhaustive), and
//! additive PowerShell patterns are layered on.
//!
//! When the remote classifier is unavailable, a simple local pattern matcher
//! provides defense-in-depth against obviously destructive commands.

const std = @import("std");
const http = @import("../http.zig");
const os = @import("../os.zig");

const assert = std.debug.assert;

const response_bytes_max: u32 = 4096;
const redirect_buffer_bytes = http.redirect_buffer_bytes;
/// Per-call budget for all phases of the remote classifier exchange,
/// including connect/send/body on Windows and HTTPS. Timeout or network
/// failure falls back to the local matcher. The classifier is a localhost sidecar; one that stalls this
/// long is broken, and fail-open beats wedging the turn indefinitely.
const classifier_timeout_seconds: u32 = 5;
/// Fixed receive buffer for the classifier response (head + body). A
/// larger response fails to the local matcher instead of growing.
const classifier_response_buffer_bytes: usize = 16 * 1024;

pub const Verdict = enum {
    safe,
    unsafe,
    unavailable,
};

pub fn commandFromArguments(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const JsonArgs = struct {
        command: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    const command = parsed.value.command orelse return error.InvalidToolArguments;
    if (command.len == 0) return error.InvalidToolArguments;
    return try gpa.dupe(u8, command);
}

/// Classify `command` as safe/unsafe. `url` is the remote classifier endpoint,
/// or null when none is configured. With a URL the remote classifies and the
/// local matcher only runs on fetch failure; with null (no classifier — the
/// local-ONNX server couldn't start, or the user set none) the local matcher
/// runs directly so the destructive-command backstop is always armed, per the
/// module's defense-in-depth contract.
pub fn classify(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: ?[]const u8,
    cwd: []const u8,
    command: []const u8,
) Verdict {
    assert(cwd.len > 0);
    assert(command.len > 0);

    const u = url orelse return localClassify(command);
    if (u.len == 0) return localClassify(command);

    const remote = classifyFallible(gpa, io, u, cwd, command, classifier_timeout_seconds) catch |err| {
        if (err == error.Canceled) io.recancel();
        // Remote classifier unavailable — fall back to local pattern matching.
        return localClassify(command);
    };
    return remote;
}

/// Local pattern-based safety check, used when the remote classifier is
/// unavailable. This is defense-in-depth, not a replacement for the model.
/// Returns `.unsafe` for obviously destructive commands, `.safe` otherwise.
fn localClassify(command: []const u8) Verdict {
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    if (trimmed.len == 0) return .safe;

    // Fork bombs and infinite-recursion shell constructs (bash).
    if (std.mem.indexOf(u8, trimmed, ":(){") != null) return .unsafe;
    if (std.mem.indexOf(u8, trimmed, ":()") != null) return .unsafe;
    // PowerShell fork-bomb equivalents.
    if (isPwshForkBomb(trimmed)) return .unsafe;

    // Destructive disk operations on system paths.
    if (isDangerousRm(trimmed)) return .unsafe;
    if (isDangerousDd(trimmed)) return .unsafe;
    if (isDangerousMkfs(trimmed)) return .unsafe;
    if (isDangerousPwshRemove(trimmed)) return .unsafe;
    if (isDangerousClearRecycleBin(trimmed)) return .unsafe;

    // Overwriting critical system files.
    if (isDangerousRedirect(trimmed)) return .unsafe;

    // Privileged package management (e.g. `sudo apt install`, `doas pacman -S`).
    // These mutate the system-wide install state and must surface for approval
    // rather than running unattended — a model should never be able to attempt
    // `sudo apt install` without the interactive gate (TD-3).
    if (isPrivilegedPackageManagement(trimmed)) return .unsafe;

    return .safe;
}

/// True when `command` escalates privileges (`sudo`/`doas`/`runas`) or invokes a
/// system package manager (`apt`, `dnf`, `brew`, `cargo`, `pip install`, and
/// the Windows installers `winget`/`choco`/`scoop`, ...).
/// These mutate system-wide install state and must surface for approval rather
/// than running unattended. The matcher splits on every shell metacharacter
/// (not just spaces) so syntax tricks like `apt;install`, `/usr/bin/apt`,
/// `./apt`, `apt\ninstall` and `pip  install` (double space) cannot bypass it.
fn isPrivilegedPackageManagement(command: []const u8) bool {
    // Privilege escalation prefixes.
    const escalators = [_][]const u8{ "sudo", "doas", "runas" };
    for (escalators) |esc| {
        if (tokenContains(command, esc)) return true;
    }
    // Single-token package managers (exact token match, case-insensitive).
    // Self-installing managers matched as a bare token (case-insensitive, exact
    // token). The tokenizer splits on shell metacharacters but NOT "-"/"." so
    // "apt-cache" / "aptitude" stay single tokens and do not false-positive on
    // "apt", while "/usr/bin/apt", "./apt" and "apt;install" still split to the
    // bare "apt" token.
    const managers = [_][]const u8{
        "apt",    "apt-get", "dpkg",     "dnf",     "yum",  "pacman", "apk", "brew",
        "zypper", "emerge",  "aptitude", "nix-env", "snap",
    };
    for (managers) |mgr| {
        if (tokenContains(command, mgr)) return true;
    }
    // Multi-word install verbs, matched only at word boundaries so
    // `apt-cache show` does not false-positive on `apt` while `apt;install`
    // (no space) still trips the `apt` single-token rule above.
    // Install verbs that require an explicit subcommand; matched only at word
    // boundaries so "pip show" / "apt-cache show" stay safe reads. The
    // Windows installers (`winget`, `choco`, `scoop`) are phrase-matched so
    // read-only subcommands (`winget list`, `choco list`) stay safe; the
    // Windows shell target is pwsh, where these are the standard managers.
    const phrases = [_][]const u8{
        "pip install",      "pip3 install",    "npm install -g",  "npm i -g",
        "cargo install",    "gem install",     "go install",      "conda install",
        "snap install",     "flatpak install", "apt install",     "apt-get install",
        "dnf install",      "yum install",     "pacman -S",       "apk add",
        "brew install",     "zypper install",  "emerge",          "winget install",
        "winget uninstall", "choco install",   "choco uninstall", "scoop install",
    };
    for (phrases) |phrase| {
        if (phraseAtBoundary(command, phrase)) return true;
    }
    return false;
}

/// Case-insensitive check that `needle` appears as a whole token anywhere in
/// `command`, where tokens are split on whitespace AND shell metacharacters
/// (`; | & ( ) < > / . \'"\\``). This catches `apt;install`, `/usr/bin/apt`,
/// `./apt`, and `apt\ninstall` — all of which a space-only split would miss.
/// Copy `command` into `buf`, mapping shell metacharacters that act as token
/// separators but are not spaces (newline, tab, `; | & ( ) < > / . ' " \``) to a
/// single space, and collapsing runs of whitespace to one space, so a space-only
/// split sees `apt;install` / `/usr/bin/apt` / `apt\ninstall` / `pip  install`
/// (double space) as the same tokens as `apt install`. Returns a slice of `buf`
/// (caller owns buf).
fn normalizeShell(command: []const u8, buf: []u8) []u8 {
    var n: usize = 0;
    var prev_space = false;
    for (command) |ch| {
        const is_sep = ch == '\n' or ch == '\t' or ch == ';' or ch == '|' or ch == '&' or
            ch == '(' or ch == ')' or ch == '<' or ch == '>' or ch == '/' or
            ch == '.' or ch == '\'' or ch == '"' or ch == '`';
        const space = is_sep or ch == ' ';
        // Collapse separators/whitespace runs into a single space.
        if (space and prev_space) continue;
        const out: u8 = if (space) ' ' else ch;
        if (n < buf.len) buf[n] = out;
        n += 1;
        prev_space = space;
    }
    const len = if (n > buf.len) buf.len else n;
    return buf[0..len];
}

fn tokenContains(command: []const u8, needle: []const u8) bool {
    // Normalize shell metacharacters to spaces so `apt\ninstall` and
    // `pip\tinstall` split into the same tokens as `apt install`.
    var buf: [4096]u8 = undefined;
    const normalized = normalizeShell(command, &buf);
    var it = std.mem.tokenizeScalar(u8, normalized, ' ');
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, needle)) return true;
    }
    return false;
}

/// Case-insensitive match of `phrase` (may contain spaces, expected lowercase)
/// only when bounded by word boundaries (string edges or any shell
/// metacharacter/whitespace), so `pip install` inside `pip install --user x`
/// matches but `equip installation` does not. Case-folds the normalized text
/// so `PIP INSTALL` classifies the same as the token matcher's
/// case-insensitive compare. Advances past the match to avoid infinite loops
/// on overlap.
fn phraseAtBoundary(command: []const u8, phrase: []const u8) bool {
    // Normalize so `apt\ninstall` still trips the `apt install` phrase.
    var buf: [4096]u8 = undefined;
    const normalized = normalizeShell(command, &buf);
    for (normalized) |*c| c.* = std.ascii.toLower(c.*);
    var idx: usize = 0;
    while (idx < normalized.len) {
        const at = std.mem.indexOf(u8, normalized[idx..], phrase) orelse return false;
        const abs = idx + at;
        const before_ok = abs == 0 or isBoundary(normalized[abs - 1]);
        const after_pos = abs + phrase.len;
        const after_ok = after_pos >= normalized.len or isBoundary(normalized[after_pos]);
        if (before_ok and after_ok) return true;
        idx = after_pos + 1;
    }
    return false;
}

/// True for whitespace or any shell metacharacter that separates tokens.
fn isBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '|' or c == '&' or c == '(' or c == ')' or c == '<' or c == '>' or c == '/' or c == '.' or c == '"' or c == '\'' or c == '`';
}

/// PowerShell fork-bomb equivalents: recursive `while($true){Start-Job ...}`
/// loops and `ForEach-Object -Parallel`/`Start-ThreadJob` constructs that fan
/// out unbounded worker processes.
fn isPwshForkBomb(command: []const u8) bool {
    if (containsIgnoreCase(command, "while($true)") or containsIgnoreCase(command, "while ($true)")) {
        if (containsIgnoreCase(command, "Start-Job")) return true;
    }
    if (containsIgnoreCase(command, "-Parallel") and containsIgnoreCase(command, "Start-ThreadJob")) {
        return true;
    }
    return false;
}

/// `Remove-Item -Recurse -Force` (or an alias spelling) on system/drive
/// roots — mirrors `isDangerousRm` for the PowerShell spellings. This is a
/// conservative matcher; the remote classifier covers the full surface.
/// Targets are flagged only when they are a drive ROOT (`C:\` / `C:/` bare),
/// `$env:SystemRoot`, or a well-known system dir — never a project path that
/// merely sits on the C: drive. Both path separators are accepted (pwsh
/// treats `C:/Windows` and `C:\Windows` identically). Abbreviated flags
/// (`-r`, `-fo`) are out of scope.
fn isDangerousPwshRemove(command: []const u8) bool {
    if (!hasRemoveItemSpelling(command)) return false;
    if (!containsIgnoreCase(command, "-Recurse") and !containsIgnoreCase(command, "-Force")) return false;
    return hasPwshSystemTarget(command);
}

/// True when `command` spells Remove-Item or one of its PowerShell command
/// aliases (`ri`, `rm`, `rmdir`, `del`, `erase`, `rd`) as a whole token —
/// `rm` inside `alarm` is not a spelling of Remove-Item.
fn hasRemoveItemSpelling(command: []const u8) bool {
    if (containsIgnoreCase(command, "Remove-Item")) return true;
    const aliases = [_][]const u8{ "ri", "rm", "rmdir", "del", "erase", "rd" };
    for (aliases) |alias| {
        if (tokenContains(command, alias)) return true;
    }
    return false;
}

/// True when `command` names a Windows system target: `$env:SystemRoot` /
/// `$env:WINDIR`, a well-known system dir, or a bare drive root. Project
/// paths that merely sit on the C: drive are not targets. A project-relative
/// directory literally named `windows` (e.g. `platforms\windows\`) does trip
/// the substring — that fails closed into an approval prompt, which is the
/// conservative posture this matcher documents; it never silently blocks.
fn hasPwshSystemTarget(command: []const u8) bool {
    // $env:SystemRoot / $env:WINDIR resolves to a system root.
    if (containsIgnoreCase(command, "$env:systemroot") or containsIgnoreCase(command, "$env:windir")) return true;
    // A well-known system dir (either separator spelling).
    if (containsIgnoreCase(command, "windows\\system32") or
        containsIgnoreCase(command, "windows/system32") or
        containsIgnoreCase(command, "program files") or
        containsIgnoreCase(command, "\\windows\\") or
        containsIgnoreCase(command, "/windows/")) return true;
    if (hasDriveRootTarget(command)) return true;
    return hasPwshSeparatorRootTarget(command);
}

/// True when `command` contains a bare separator-only root target: a `/` or
/// `\` introduced by whitespace or an opening quote and closed by
/// end-of-string, a shell separator, a closing quote, or `*`. In pwsh a bare
/// `/` or `\` resolves to the root of the CURRENT drive, so
/// `rm -Recurse -Force /` is a whole-drive wipe like `rm -Recurse -Force C:\`.
/// A separator attached to a word (`dist/`, `.\build\`) is a relative path,
/// not a root.
fn hasPwshSeparatorRootTarget(command: []const u8) bool {
    var idx: usize = 0;
    while (idx < command.len) : (idx += 1) {
        const c = command[idx];
        if (c != '/' and c != '\\') continue;
        if (idx == 0) continue;
        const before = command[idx - 1];
        // Whitespace, an opening quote, or a pwsh backtick escape introduces
        // the root: `` ri -Force `/ `` still names the bare `/` root.
        if (!std.ascii.isWhitespace(before) and before != '"' and before != '\'' and before != '`') continue;
        const after = idx + 1;
        if (after >= command.len) return true; // trailing ` /` / ` \`
        const nxt = command[after];
        if (isRootTargetDelimiter(nxt)) return true; // ` /"` — `ri -Force "/"`
        if (nxt == '*') {
            const after_star = after + 1;
            if (after_star >= command.len or isRootTargetDelimiter(command[after_star])) return true;
        }
    }
    return false;
}

/// True when `command` contains a bare drive root target (`C:\` or `C:/`
/// followed by end-of-string, whitespace, a quote, `*`, or nothing) — the
/// `Remove-Item C:\` / `Remove-Item C:\*` case that nukes the whole drive.
/// A trailing no-op dot component (`C:\.`, `C:\..`, `C:\.\`) still names the
/// root, mirroring the bash matcher's `/.` handling.
fn hasDriveRootTarget(command: []const u8) bool {
    var idx: usize = 0;
    while (idx < command.len) {
        // A drive letter somewhere, then `:\` or `:/` right after is the
        // drive root.
        if (idx + 2 < command.len and
            std.ascii.isAlphabetic(command[idx]) and
            command[idx + 1] == ':' and
            (command[idx + 2] == '\\' or command[idx + 2] == '/'))
        {
            var after = idx + 3;
            // A no-op dot component (`\.`, `\..`, `\.\`) still names the
            // root; anything else after it (`.git`, `Users`) is a real path.
            while (after < command.len and
                (command[after] == '.' or command[after] == '\\' or command[after] == '/'))
            {
                after += 1;
            }
            if (after >= command.len) return true; // trailing `C:\` / `C:\.`
            const c = command[after];
            if (std.ascii.isWhitespace(c) or c == '\'' or c == '"' or c == '*') return true;
        }
        idx += 1;
    }
    return false;
}

/// `Clear-RecycleBin -Force` empties the recycle bin without confirmation —
/// destructive, irreversible recovery.
fn isDangerousClearRecycleBin(command: []const u8) bool {
    return containsIgnoreCase(command, "clear-recyclebin") and containsIgnoreCase(command, "-force");
}

/// Case-insensitive substring search over ASCII (command text is shell code,
/// which never needs Unicode folding). Deliberately a named wrapper at the
/// classifier's call sites; `std.ascii.findIgnoreCase` folds ASCII-only, which
/// is exactly the old hand-rolled loop's semantics (empty needle matches).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

test "containsIgnoreCase: empty needle matches, case folded" {
    try std.testing.expect(containsIgnoreCase("Remove-Item", ""));
    try std.testing.expect(containsIgnoreCase("rm -RF /", "-rf"));
    try std.testing.expect(!containsIgnoreCase("rm", "-rf"));
}

/// Characters that may sit directly before an `rm`/`dd` command word while it
/// still reads as command position: shell separators (`;`, `|`, `&` —
/// including unspaced `&&rm`), substitution openings (`(`, backtick), quotes
/// (`sh -c "rm -rf /"`), and the backslash escape (`\rm` bypasses a rm alias
/// but still runs rm). Anything else (a letter in `alarm`, a digit, `=`)
/// means the match is inside a larger word, not a command.
fn isCommandWordBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == ';' or c == '|' or c == '&' or
        c == '(' or c == '`' or c == '"' or c == '\'' or c == '\\';
}

/// True when `rest` (the text after an `rm` command word) names the
/// filesystem root as a target: a `/` introduced by whitespace, an opening
/// quote (`"/`), or a backslash escape (`\/`), optionally followed by `*` or
/// a no-op `.` component, and closed by end-of-string, whitespace, a shell
/// separator, or the closing quote/substitution characters — i.e. the whole
/// root, never a longer path like `/tmp/x`.
fn hasRootTarget(rest: []const u8) bool {
    var idx: usize = 0;
    while (idx < rest.len) : (idx += 1) {
        if (rest[idx] != '/') continue;
        if (idx == 0) continue;
        const before = rest[idx - 1];
        // Any whitespace (space, tab, newline), an opening quote, or a
        // backslash escape may introduce the root argument: `rm -rf\t/` is
        // the same command as `rm -rf /`, and bash `\/` is just `/`.
        if (!std.ascii.isWhitespace(before) and before != '"' and before != '\'' and before != '\\') continue;
        const after = idx + 1;
        if (after >= rest.len) return true; // trailing ` /` / `"/`
        const c = rest[after];
        if (isRootTargetDelimiter(c)) return true; // ` /)` — `$(rm -rf /)`
        if (c == '*') {
            const after_star = after + 1;
            if (after_star >= rest.len or isRootTargetDelimiter(rest[after_star])) return true;
        }
    }
    return false;
}

/// Delimiters that may follow the root `/` (or `/*`, `\`, `\.`) target:
/// whitespace, shell separators, the closers of the substitution/quote
/// contexts the root can be embedded in (`)`, backtick, `"`, `'`), and `.`
/// — a dot is a no-op path component (`/.` and `/./` still name the root).
fn isRootTargetDelimiter(c: u8) bool {
    return c == ' ' or c == '\t' or c == ';' or c == '&' or c == '|' or c == '\r' or c == '\n' or
        c == ')' or c == '`' or c == '"' or c == '\'' or c == '.';
}

/// Check for `rm -rf /`, `rm -rf /*`, `rm -rf --no-preserve-root /`, and the
/// same inside command substitution (`$(rm -rf /)`), backticks, quotes, or
/// after an unspaced separator (`&&rm`). Every occurrence of an `rm` command
/// word is examined — a word merely embedding `rm` (`alarm`) does not stop a
/// later standalone `rm` from being checked.
fn isDangerousRm(command: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, command, search_from, "rm")) |rm_idx| {
        search_from = rm_idx + 1;
        // Word boundary before rm: command position, not inside `alarm`.
        if (rm_idx > 0 and !isCommandWordBoundary(command[rm_idx - 1])) continue;

        const rest = command[rm_idx + 2 ..];
        // Look for `-rf` or `-fr` flags.
        const has_recursive = std.mem.indexOf(u8, rest, "-rf") != null or
            std.mem.indexOf(u8, rest, "-fr") != null or
            std.mem.indexOf(u8, rest, "-r -f") != null or
            std.mem.indexOf(u8, rest, "-f -r") != null;
        if (!has_recursive) continue;

        // Target being root (`/`, `/*`, `"/"`) — not just any absolute path.
        if (hasRootTarget(rest)) return true;
        if (std.mem.indexOf(u8, rest, "--no-preserve-root") != null) return true;
    }
    return false;
}

/// Check for `dd if=/dev/zero of=/dev/sda` or similar destructive dd, in any
/// command position (standalone, after a separator, in substitution).
fn isDangerousDd(command: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, command, search_from, "dd")) |dd_idx| {
        search_from = dd_idx + 1;
        if (dd_idx > 0 and !isCommandWordBoundary(command[dd_idx - 1])) continue;

        const rest = command[dd_idx + 2 ..];
        // dd writing to a block device.
        const of_dev = std.mem.indexOf(u8, rest, "of=/dev/");
        if (of_dev) |idx| {
            // Skip /dev/null, /dev/zero, /dev/random, /dev/urandom.
            const target = rest[idx + 8 ..];
            if (std.mem.startsWith(u8, target, "null") or
                std.mem.startsWith(u8, target, "zero") or
                std.mem.startsWith(u8, target, "random") or
                std.mem.startsWith(u8, target, "urandom") or
                std.mem.startsWith(u8, target, "stdout")) continue;
            return true;
        }
        // dd writing to other dangerous system paths.
        const dangerous_of = [_][]const u8{
            "of=/boot/",
            "of=/etc/",
            "of=/sys/",
            "of=/proc/",
        };
        for (dangerous_of) |prefix| {
            if (std.mem.indexOf(u8, rest, prefix) != null) return true;
        }
    }
    return false;
}

/// Check for `mkfs` or `mkfs.*` targeting a block device.
fn isDangerousMkfs(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, "mkfs") == null) return false;
    // mkfs without arguments is just help output.
    if (std.mem.indexOf(u8, command, "/dev/") != null) return true;
    return false;
}

/// Check for redirecting into critical system files.
fn isDangerousRedirect(command: []const u8) bool {
    // Structural scan: every `>` (including `>>` and `2>`) with any run of
    // whitespace and one optional quote before the target, so `>/etc/x`,
    // `>> /etc/x`, and `> "/etc/x"` classify the same as `> /etc/x`. Targets
    // are path prefixes, so a `>` used as a comparison (`3 > 2`) has no
    // target and stays safe.
    const dangerous_targets = [_][]const u8{
        "/etc/",
        "/boot/",
        "/dev/sd",
        "/dev/nvme",
        "/dev/mmcblk",
        "/dev/vda",
        "/dev/hd",
        "/dev/mapper/",
        "/dev/loop",
        "/sys/",
        "/proc/",
    };
    var idx: usize = 0;
    while (indexOfScalarPos(command, idx, '>')) |gt| {
        var after = gt + 1;
        while (after < command.len and std.ascii.isWhitespace(command[after])) after += 1;
        if (after < command.len and (command[after] == '\'' or command[after] == '"')) after += 1;
        for (dangerous_targets) |target| {
            if (std.mem.startsWith(u8, command[after..], target)) return true;
        }
        idx = gt + 1;
    }
    // PowerShell redirects into system roots: `> C:\Windows\`,
    // `> 'C:\Program Files\'`, etc. Drive-letter roots and the well-known
    // system dirs are the only Windows targets worth flagging from the local
    // matcher (defense-in-depth; the remote classifier covers the full surface).
    if (isDangerousPwshRedirect(command)) return true;
    return false;
}

/// PowerShell redirect (`>`) into a Windows system root. Case-insensitive on the
/// ASCII text. Flags well-known system dirs and a bare drive root; a project path
/// on the C: drive (`> C:\repo\out.txt`) is NOT flagged. Both separators are
/// accepted (pwsh treats `C:/Windows` and `C:\Windows` identically).
fn isDangerousPwshRedirect(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, ">") == null) return false;
    if (containsIgnoreCase(command, "windows\\system32") or
        containsIgnoreCase(command, "windows/system32") or
        containsIgnoreCase(command, "program files") or
        containsIgnoreCase(command, "windows\\") or
        containsIgnoreCase(command, "windows/") or
        containsIgnoreCase(command, "$env:systemroot"))
    {
        return true;
    }
    // A bare drive root redirect (`> C:\`, `> 'D:\'`): the target is the drive
    // root with nothing after it but whitespace / quote / end-of-string / `*`.
    if (hasBareDriveRootRedirect(command)) return true;
    return false;
}

/// True when `command` contains a `>` redirect to a drive root with nothing but
/// whitespace/quote/`*`/end after the `C:\` (or `C:/`) — i.e. writing to the
/// root of a drive itself, not into a subdirectory.
fn hasBareDriveRootRedirect(command: []const u8) bool {
    var idx: usize = 0;
    while (indexOfScalarPos(command, idx, '>')) |gt| {
        var after = gt + 1;
        while (after < command.len and std.ascii.isWhitespace(command[after])) after += 1;
        if (after < command.len and (command[after] == '\'' or command[after] == '"')) after += 1;
        // Strict bound: a trailing `X:` (no root separator after the colon)
        // is not a redirect target, and indexing one past it would panic.
        if (after + 2 < command.len and
            std.ascii.isAlphabetic(command[after]) and
            command[after + 1] == ':' and
            (command[after + 2] == '\\' or command[after + 2] == '/'))
        {
            var tail = after + 3;
            // A no-op dot component (`\.`, `\..`) still names the root.
            while (tail < command.len and
                (command[tail] == '.' or command[tail] == '\\' or command[tail] == '/'))
            {
                tail += 1;
            }
            if (tail >= command.len) return true;
            const c = command[tail];
            if (std.ascii.isWhitespace(c) or c == '\'' or c == '"' or c == '*' or c == ';') return true;
        }
        idx = gt + 1;
    }
    return false;
}

fn indexOfScalarPos(haystack: []const u8, from: usize, needle: u8) ?usize {
    if (from >= haystack.len) return null;
    return std.mem.indexOfScalarPos(u8, haystack, from, needle);
}

fn classifyFallible(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    cwd: []const u8,
    command: []const u8,
    timeout_seconds: u32,
) !Verdict {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequest(&payload.writer, cwd, command);

    const uri = try std.Uri.parse(url);
    const transport: ClassifierExchange.Transport = if (os.is_windows or std.mem.eql(u8, uri.scheme, "https")) .http_client else .socket;
    return classifyExchange(gpa, io, url, payload.written(), timeout_seconds, transport);
}

fn classifyExchange(gpa: std.mem.Allocator, io: std.Io, url: []const u8, payload: []const u8, timeout_seconds: u32, transport: ClassifierExchange.Transport) !Verdict {
    var exchange: ClassifierExchange = .{ .gpa = gpa, .io = io, .url = url, .payload = payload, .timeout_seconds = timeout_seconds, .transport = transport };
    var task = try io.concurrent(ClassifierExchange.run, .{&exchange});
    // Join before releasing payload/context on success, timeout, cancellation
    // or a network error. The child owns its client/socket until it unwinds.
    defer task.cancel(io);
    exchange.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(timeout_seconds), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return error.ClassifierTimeout,
        else => return err,
    };
    task.await(io);
    return exchange.result;
}

const ClassifierExchange = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    payload: []const u8,
    timeout_seconds: u32,
    transport: Transport,
    done: std.Io.Event = .unset,
    result: anyerror!Verdict = error.Unexpected,

    const Transport = enum { socket, http_client };

    fn run(self: *ClassifierExchange) void {
        self.result = self.fetch();
        self.done.set(self.io);
    }

    fn fetch(self: *ClassifierExchange) !Verdict {
        if (os.is_windows) return classifyOverClient(self.gpa, self.io, self.url, self.payload, self.timeout_seconds);
        if (self.transport == .http_client) return classifyOverClient(self.gpa, self.io, self.url, self.payload, self.timeout_seconds);
        const uri = try std.Uri.parse(self.url);

        if (!std.mem.eql(u8, uri.scheme, "http")) return error.UnsupportedScheme;
        return classifyOverSocket(self.gpa, self.io, uri, self.payload, self.timeout_seconds);
    }
};

/// Explicit `std.http.Client` exchange for HTTPS and Windows, executed
/// under ClassifierExchange's cancelable watchdog.
///
/// The read path is bounded two ways, and BOTH are needed:
///
/// 1. `http.setSocketTimeout` puts `SO_RCVTIMEO` on the connection, so a
///    stalled server makes the read fail with `EAGAIN`/`ETIMEDOUT` instead
///    of blocking forever.
/// 2. `http.timeoutAwareIo` swaps the `Io.Threaded` read callback for one
///    that translates that `EAGAIN` into `error.Timeout` rather than
///    letting Zig 0.16.0's `errnoBug` treat it as a programmer bug (a
///    panic in Debug, `error.Unexpected` in ReleaseFast).
///
/// Wrapping the Io WITHOUT the socket timeout is a no-op: the wrapper
/// reads `SO_RCVTIMEO`, sees no timeout, and falls through to the
/// unmodified read path — so the `EAGAIN` bug it exists to prevent would
/// still fire. The socket timeout is applied after the response head
/// arrives, so the (fast) head exchange is not affected.
fn classifyOverClient(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    payload: []const u8,
    timeout_seconds: u32,
) !Verdict {
    var body_buffer: [response_bytes_max]u8 = undefined;
    var response_body: std.Io.Writer = .fixed(&body_buffer);
    var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;

    var client: std.http.Client = .{ .allocator = gpa, .io = http.timeoutAwareIo(io) };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try client.request(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = http.content_type_json } },
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = payload.len };
    var body = try request.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try request.connection.?.flush();
    var response = try request.receiveHead(&redirect_buffer);
    if (!http.isSuccess(@intFromEnum(response.head.status))) return error.HttpUnexpectedStatus;
    // Socket-level read timeout: bounds the BODY read, which is the phase
    // that can stall (a server that answers the head and then goes quiet).
    // Applied after the head so the fast head exchange is unaffected.
    // `timeoutAwareIo` above turns the resulting EAGAIN into `error.Timeout`.
    if (request.connection) |conn| http.setSocketTimeout(conn, timeout_seconds);
    const decompress_size: usize = switch (response.head.content_encoding) {
        .identity => 0,
        .zstd => std.compress.zstd.default_window_len,
        .deflate, .gzip => std.compress.flate.max_window_len,
        .compress => return error.UnsupportedCompressionMethod,
    };
    const decompress_buffer = try gpa.alloc(u8, decompress_size);
    defer gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&response_body) catch |err| switch (err) {
        // Zig 0.16 fetch unwraps bodyErr unconditionally, but cancellation
        // of a content-length read can leave it null. Preserve that failure
        // without panicking, and let the outer watchdog join the task.
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };
    return parseResponse(gpa, response_body.buffered());
}

/// Deadline-bounded HTTP/1.1 exchange over a raw socket, POSIX http only.
///
/// The response receive phase polls the socket with the remaining budget
/// instead of blocking in recv: `Io.Threaded`'s read path treats the EAGAIN
/// a socket read timeout produces as a programmer bug (panic in Debug), so
/// the deadline lives in explicit poll rounds. Framing is EOF-delimited —
/// the request advertises `Connection: close`, which the uvicorn sidecar
/// honours, so the response ends when the server closes. A server that
/// keeps the connection open simply runs into the deadline. The send phase
/// goes through the blocking stream writer and the connect is
/// kernel-default (instant for the localhost sidecar); both match the
/// pre-deadline behavior and are bounded in practice by the sidecar being
/// a local process that reads what we send.
fn classifyOverSocket(
    gpa: std.mem.Allocator,
    io: std.Io,
    uri: std.Uri,
    payload: []const u8,
    timeout_seconds: u32,
) !Verdict {
    const host_component = uri.host orelse return error.UriMissingHost;
    const host = componentText(host_component);
    const port: u16 = uri.port orelse 80;
    // Forward the query string: the previous `fetch` path sent the full
    // URL, so `…/classify?x=1` must keep reaching the same handler.
    var request_target: std.Io.Writer.Allocating = .init(gpa);
    defer request_target.deinit();
    const raw_path = componentText(uri.path);
    try request_target.writer.writeAll(if (raw_path.len > 0) raw_path else "/");
    if (uri.query) |q| try request_target.writer.print("?{s}", .{componentText(q)});

    const deadline_ns = std.Io.Timestamp.now(io, .awake).nanoseconds +
        @as(i96, timeout_seconds) * std.time.ns_per_s;

    const address = try std.Io.net.IpAddress.resolve(io, host, port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var request: std.Io.Writer.Allocating = .init(gpa);
    defer request.deinit();
    try request.writer.print("POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ request_target.written(), host, port, payload.len });
    try request.writer.writeAll(payload);

    // Small fixed-shape request through the blocking stream writer; the
    // deadline is enforced on the receive phase below.
    var write_buffer: [http.body_buffer_bytes]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request.written());
    try writer.interface.flush();

    var response_buffer: [classifier_response_buffer_bytes]u8 = undefined;
    const response = try receiveResponseBounded(io, stream.socket.handle, &response_buffer, deadline_ns);
    return parseSocketResponse(gpa, response);
}

/// Nanoseconds left until `deadline_ns`; negative once the budget is spent.
fn classifierRemainingNs(io: std.Io, deadline_ns: i96) i96 {
    return deadline_ns - std.Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Poll-round timeout in milliseconds, clamped to what `poll` accepts.
fn pollTimeoutMs(remaining_ns: i96) i32 {
    const ms = @divTrunc(remaining_ns, std.time.ns_per_ms);
    return @intCast(@min(ms, @as(i96, std.math.maxInt(i32))));
}

/// Read the full response into `buffer`, one deadline-bounded poll round at
/// a time, until the server closes the connection. Returns a slice of
/// `buffer`.
fn receiveResponseBounded(
    io: std.Io,
    fd: std.posix.socket_t,
    buffer: []u8,
    deadline_ns: i96,
) ![]const u8 {
    var received: usize = 0;
    while (true) {
        try io.checkCancel();
        const remaining_ns = classifierRemainingNs(io, deadline_ns);
        if (remaining_ns <= 0) return error.ClassifierTimeout;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, @min(pollTimeoutMs(remaining_ns), 20)) == 0) continue;
        const n = try std.posix.read(fd, buffer[received..]);
        if (n == 0) return buffer[0..received]; // Server closed: response complete.
        received += n;
        if (received == buffer.len) return error.ResponseTooLarge;
    }
}

/// Split the EOF-delimited response into head and body. The status line
/// must carry a 2xx code and the body must fit the cap — anything else
/// fails to the local matcher.
fn parseSocketResponse(gpa: std.mem.Allocator, response: []const u8) !Verdict {
    const separator = "\r\n\r\n";
    const sep = std.mem.indexOf(u8, response, separator) orelse return error.InvalidClassifierResponse;
    const head = response[0..sep];
    const body = response[sep + separator.len ..];
    if (body.len > response_bytes_max) return error.ResponseTooLarge;

    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const status_line = head[0..line_end];
    const code_start = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.InvalidClassifierResponse;
    const rest = status_line[code_start + 1 ..];
    const code_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const status_code = std.fmt.parseInt(u16, rest[0..code_end], 10) catch return error.InvalidClassifierResponse;
    if (!http.isSuccess(status_code)) return error.HttpUnexpectedStatus;
    return parseResponse(gpa, body);
}

/// Bytes of a URI component as-is. Classifier hosts/paths are plain
/// literals (IP or hostname, `/classify`); percent-encoded hosts are used
/// undecoded, which matches how they resolve in practice.
fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |text| text,
        .percent_encoded => |text| text,
    };
}

fn writeRequest(writer: *std.Io.Writer, cwd: []const u8, command: []const u8) !void {
    try writer.writeAll("{\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, writer);
    try writer.writeAll(",\"command\":");
    try std.json.Stringify.value(command, .{}, writer);
    try writer.writeAll("}");
}

const ClassifierResponse = struct {
    label: []const u8,
};

fn parseResponse(gpa: std.mem.Allocator, bytes: []const u8) !Verdict {
    if (bytes.len == 0) return error.InvalidClassifierResponse;
    const parsed = std.json.parseFromSlice(ClassifierResponse, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidClassifierResponse;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.label, "safe")) return .safe;
    if (std.mem.eql(u8, parsed.value.label, "unsafe")) return .unsafe;
    return error.InvalidClassifierResponse;
}

test "bash safety extracts command from tool arguments" {
    const gpa = std.testing.allocator;
    const command = try commandFromArguments(gpa, "{\"command\":\"rm -rf /tmp/x\",\"description\":\"clean\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("rm -rf /tmp/x", command);
}

test "bash safety parses classifier responses" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Verdict.safe, try parseResponse(gpa, "{\"label\":\"safe\"}"));
    try std.testing.expectEqual(Verdict.unsafe, try parseResponse(gpa, "{\"label\":\"unsafe\",\"score\":0.99}"));
    try std.testing.expectError(error.InvalidClassifierResponse, parseResponse(gpa, "{\"label\":\"maybe\"}"));
    // A response with a score but no label is also malformed.
    try std.testing.expectError(error.InvalidClassifierResponse, parseResponse(gpa, "{\"score\":0.99}"));
}

test "classify with no URL falls back to the local matcher" {
    // Regression for H4: with no classifier configured the local destructive-
    // command backstop must still run (it used to be reachable only through the
    // remote-fetch-failure path).
    try std.testing.expectEqual(Verdict.unsafe, classify(std.testing.allocator, std.testing.io, null, "/x", "rm -rf /"));
    try std.testing.expectEqual(Verdict.safe, classify(std.testing.allocator, std.testing.io, null, "/x", "ls"));
}

test "local classifier flags rm -rf /" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf /"));
}

test "local classifier flags rm -rf /*" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf /*"));
}

test "local classifier flags rm -rf --no-preserve-root /" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf --no-preserve-root /"));
}

test "local classifier allows rm -rf /tmp/x" {
    try std.testing.expectEqual(Verdict.safe, localClassify("rm -rf /tmp/x"));
}

test "local classifier allows rm -rf ./build" {
    try std.testing.expectEqual(Verdict.safe, localClassify("rm -rf ./build"));
}

test "local classifier flags fork bomb" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify(":(){ :|:& };:"));
}

test "local classifier flags dd to block device" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dd if=/dev/zero of=/dev/sda bs=1M"));
}

test "local classifier allows dd to /dev/null" {
    try std.testing.expectEqual(Verdict.safe, localClassify("dd if=/dev/zero of=/dev/null bs=1M"));
}

test "local classifier flags mkfs on /dev" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("mkfs.ext4 /dev/sda1"));
}

test "local classifier allows mkfs without device" {
    try std.testing.expectEqual(Verdict.safe, localClassify("mkfs.ext4"));
}

test "local classifier flags redirect to /etc/passwd" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo 'hacker::0:0::/:/bin/sh' > /etc/passwd"));
}

test "S4 unspaced system-file redirects still flag" {
    // `> /etc/` with no space after the redirect, and the append / fd-prefixed
    // spellings, are the same critical-file overwrite.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo hacker::0:0::/:/bin/sh >/etc/passwd"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x >>/etc/passwd"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("make 2>/dev/sda"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("xargs cat >/sys/kernel/x"));
}

test "S4 quoted system-file redirect targets still flag" {
    // A quote between `>` and the target must not hide it: `> "/etc/passwd"`
    // is the same redirect as `> /etc/passwd`.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > \"/etc/passwd\""));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x >'/etc/passwd'"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > \"/dev/sda\""));
}

test "S4 ordinary redirect targets stay safe" {
    try std.testing.expectEqual(Verdict.safe, localClassify("echo x >/dev/null"));
    try std.testing.expectEqual(Verdict.safe, localClassify("echo x >>/dev/null"));
    try std.testing.expectEqual(Verdict.safe, localClassify("git log > out.log"));
    try std.testing.expectEqual(Verdict.safe, localClassify("zig build test 2>err.txt"));
    // A `>` that is a comparison, not a redirect, has no path target.
    try std.testing.expectEqual(Verdict.safe, localClassify("test 3 > 2 && echo bigger"));
}

test "local classifier flags redirect to /boot" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dd if=/dev/zero of=/boot/initrd.img"));
}

test "local classifier allows safe commands" {
    try std.testing.expectEqual(Verdict.safe, localClassify("ls -la"));
    try std.testing.expectEqual(Verdict.safe, localClassify("git status"));
    try std.testing.expectEqual(Verdict.safe, localClassify("npm run build"));
    try std.testing.expectEqual(Verdict.safe, localClassify("cat src/main.zig"));
}

test "local classifier flags pwsh Remove-Item on a drive root" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\*"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force $env:SystemRoot"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\Windows\\*"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force 'C:\\Program Files\\*'"));
}

test "local classifier allows pwsh Remove-Item on a project path" {
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse -Force .\\build"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse -Force C:\\repo\\dist"));
}

test "local classifier flags Clear-RecycleBin -Force" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Clear-RecycleBin -Force"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Clear-RecycleBin -WhatIf"));
}

test "local classifier flags pwsh fork-bomb equivalents" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("while($true){Start-Job { Start-Job { Start-Job {} } }}"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("1..100 | ForEach-Object -Parallel { Start-ThreadJob { } }"));
}

test "local classifier flags pwsh dangerous redirect" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Write-Output 'x' > C:\\Windows\\x.txt"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Something > 'C:\\Program Files\\x.txt'"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Write-Output 'x' > .\\out.txt"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Write-Output 'x' > C:\\repo\\out.txt"));
}

test "local classifier flags sudo apt install as unsafe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("sudo apt install nginx"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("sudo apt-get install -y curl"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("doas pacman -S htop"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("runas /user:admin winget install foo"));
}

test "local classifier flags direct package managers as unsafe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("apt-get update"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dpkg -i package.deb"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dnf install vim"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("yum remove git"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("pacman -Syu"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("apk add wget"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("pip install --user requests"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("npm install -g typescript"));
}

test "local classifier still allows safe reads" {
    try std.testing.expectEqual(Verdict.safe, localClassify("ls -la"));
    try std.testing.expectEqual(Verdict.safe, localClassify("apt-cache show nginx"));
    try std.testing.expectEqual(Verdict.safe, localClassify("pip show requests"));
    // `apt` substring inside an unrelated word must not false-positive.
    try std.testing.expectEqual(Verdict.safe, localClassify("cat adapter.log"));
}

test "S1 rm inside command substitution still flags root wipe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo $(rm -rf /)"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo $(rm -rf /*)"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("$(dd if=/dev/zero of=/dev/sda)"));
}

test "S1 rm after backtick or unspaced && still flags root wipe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo `rm -rf /`"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("true&&rm -rf /"));
}

test "S1 quoted rm root target still flags" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("sh -c \"rm -rf /\""));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf \"/\""));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf '/'"));
}

test "S1 rm as a later command word after a word embedding rm" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("alarm; rm -rf /"));
}

test "S1 substitution-scoped rm on project paths stays safe" {
    try std.testing.expectEqual(Verdict.safe, localClassify("echo $(rm -rf /tmp/x)"));
    try std.testing.expectEqual(Verdict.safe, localClassify("echo $(rm -rf ./build)"));
    try std.testing.expectEqual(Verdict.safe, localClassify("cat alarm.log; rm -rf ./dist"));
}

test "S2 windows package managers install and uninstall are unsafe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("winget install Microsoft.PowerToys"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("winget uninstall Microsoft.Edge"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("choco install nginx --yes"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("choco uninstall nginx"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("scoop install ripgrep"));
}

test "S2 windows package manager reads stay safe" {
    try std.testing.expectEqual(Verdict.safe, localClassify("winget list"));
    try std.testing.expectEqual(Verdict.safe, localClassify("winget search ripgrep"));
    try std.testing.expectEqual(Verdict.safe, localClassify("choco list --local-only"));
    try std.testing.expectEqual(Verdict.safe, localClassify("scoop info ripgrep"));
}

test "S2 install phrases match case-insensitively" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("PIP INSTALL requests"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Winget Install Microsoft.PowerToys"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("winget;install ripgrep"));
}

test "S3 pwsh Remove-Item aliases on system targets are unsafe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -Recurse -Force C:\\"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("del -Recurse -Force C:\\Windows\\System32\\bad"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rd -Force C:\\"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("ri -Recurse $env:SystemRoot"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("erase -Force 'C:\\Program Files'"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rmdir -Recurse -Force D:\\"));
}

test "S3 forward-slash drive roots and windows dirs are recognized" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:/"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -Recurse -Force D:/"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:/Windows/System32/x"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Write-Output 'x' > C:/Windows/x.txt"));
}

test "S3 pwsh alias removals on project paths stay safe" {
    try std.testing.expectEqual(Verdict.safe, localClassify("rm -Recurse -Force .\\build"));
    try std.testing.expectEqual(Verdict.safe, localClassify("del -Recurse -Force C:\\repo\\dist"));
    try std.testing.expectEqual(Verdict.safe, localClassify("rd -Force D:\\repo\\out"));
    // Abbreviated flags are out of scope for the conservative matcher.
    try std.testing.expectEqual(Verdict.safe, localClassify("rm -r .\\node_modules"));
}

test "S3 trailing drive letter after redirect neither panics nor flags" {
    // Regression: `X:` at end-of-string made hasBareDriveRootRedirect read
    // one byte past the command; a drive letter with no root separator is
    // not a redirect target at all.
    try std.testing.expectEqual(Verdict.safe, localClassify("echo x > C:"));
    try std.testing.expectEqual(Verdict.safe, localClassify("echo x > 'D:"));
}

test "S3 rm root target accepts tab and newline before the slash" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf\t/"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf\n/"));
}

test "S3 pwsh bare separator roots are recognized" {
    // In pwsh a bare `/` or `\` resolves to the root of the current drive,
    // so these are whole-drive wipes in the same class as `C:\`. A trailing
    // `.` is a no-op path component: `/.` is still the root.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -Recurse -Force /"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force \\"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("ri -Force \"/\""));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rd -Recurse -Force /*"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force /."));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -Recurse -Force '/'"));
}

test "S3 separators attached to words are relative paths, not roots" {
    try std.testing.expectEqual(Verdict.safe, localClassify("rm -Recurse -Force .\\build\\"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse dist/"));
    // A UNC share is a remote path, not the current drive's root.
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse -Force \\\\server\\share\\build"));
}

test "S6 pwsh drive-root no-op dot components still flag" {
    // `C:\.`, `C:\..`, and `C:\.\` resolve to the drive root in pwsh, the
    // same way `/.` resolves to the filesystem root for the bash matcher —
    // which already treats the dot as a root-target delimiter. The pwsh
    // drive-root scan must accept the same no-op components.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\."));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\.."));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -Recurse -Force C:\\.\\"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("ri -Force C:/.."));
    // The redirect twin: writing to the drive root via a dot component.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Write-Output x > C:\\."));
}

test "S6 dot-name subdirectories stay safe" {
    // A dot component followed by a name is a real directory, not the root:
    // `C:\.git` and `C:\.gitignore` are ordinary targets.
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse -Force C:\\.git"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Write-Output x > C:\\.gitignore"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse -Force C:\\Users"));
}

test "S1 backslash-escaped rm still flags root wipe" {
    // `\rm` is the bash idiom for bypassing a rm alias; it is still the rm
    // command in command position. `\/` is the same escape applied to the
    // root target itself.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("\\rm -rf /"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("\\dd if=/dev/zero of=/dev/sda"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf \\/"));
}

test "S5 brace-group rm and dd still flag root wipe" {
    // `{ rm ...; }` reaches command position through the space after `{` —
    // bash requires it (`{rm` is a single word), so the existing whitespace
    // boundary already covers brace groups. Documented so a brace group is
    // not mistaken for an uncovered introducer.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("{ rm -rf /; }"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("sh -c '{ rm -rf /; }'"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("{ dd if=/dev/zero of=/dev/sda; }"));
    // A rm later in the group, after the initial command, still flags.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("{ echo start; rm -rf /; }"));
}

test "RT semicolon" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("apt;install nginx"));
}
test "RT fullpath" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("/usr/bin/apt install nginx"));
}
test "RT doublespace" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("pip  install requests"));
}
test "RT newline" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("apt\ninstall nginx"));
}
test "RT relpath" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("./apt install nginx"));
}
test "RT sudo semicolon" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("sudo;apt install nginx"));
}
test "RT env prefix" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("env X=1 sudo apt install"));
}
test "RT exec prefix" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("exec sudo apt install"));
}
test "RT pip module" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("python -m pip install x"));
}

test "privileged pm: additional managers are unsafe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("cargo install foo"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("gem install rails"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("go install x@latest"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("conda install numpy"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("snap install vlc"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("flatpak install org.gimp.GIMP"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("zypper install git"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("emerge vim"));
}

test "privileged pm: no false positives on safe reads" {
    try std.testing.expectEqual(Verdict.safe, localClassify("apt-cache show nginx"));
    try std.testing.expectEqual(Verdict.safe, localClassify("pip show requests"));
    try std.testing.expectEqual(Verdict.safe, localClassify("cat adapter.log"));
    try std.testing.expectEqual(Verdict.safe, localClassify("equip installation kit"));
}

/// Accepts one connection, consumes the request head, then holds the
/// connection open WITHOUT ever responding — the client-side socket timeout
/// is the only way the classify call completes. It uses the same listener
/// setup as `MockHttpServer` but deliberately never responds.
const StallServer = struct {
    io: std.Io,
    server: std.Io.net.Server,

    fn init(io: std.Io) !StallServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .server = server };
    }

    fn deinit(self: *StallServer) void {
        self.server.deinit(self.io);
    }

    fn port(self: *const StallServer) u16 {
        return self.server.socket.address.ip4.port;
    }

    fn stall(self: *StallServer) void {
        // Hoisted: the test returns at ~1 s (client deadline) and its frame
        // — where `self` lives — is popped; the detached worker must touch
        // nothing on it when it wakes up ~30 s later.
        const io = self.io;
        const stream = self.server.accept(io) catch return;
        defer stream.close(io);
        var read_buf: [8192]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var write_buf: [8192]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        // Consume the head so the client's send phase completes, then stall
        // well past any client timeout instead of answering.
        _ = http_server.receiveHead() catch return;
        io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch return;
    }
};

test "classifyFallible times out a stalled classifier and falls back to the local matcher" {
    // The deadline lives in poll rounds (`classifyOverSocket`), POSIX-only;
    // on Windows this test would block for the full server stall.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try StallServer.init(io);
    defer server.deinit();
    const worker = try std.Thread.spawn(.{}, StallServer.stall, .{&server});
    worker.detach(); // never joins: the client timeout ends the test first

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/classify", .{server.port()});
    defer gpa.free(url);

    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    // Destructive on purpose and expecting the timeout error: the stall
    // server never answers, so the deadline (1 s) is the only way out. The
    // catch → localClassify fallback one level up is covered by the
    // dead-port test in plugin_api.zig.
    const outcome = classifyFallible(gpa, io, url, "/tmp", "rm -rf /", 1);
    try std.testing.expectError(error.ClassifierTimeout, outcome);
    // Without the deadline the call only returns when the server's 30 s
    // stall ends — the bound turns that regression into a failure instead
    // of a slow test.
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms < 10_000);
}

const ClassifierStallFixture = struct {
    server: *StallServer,
    send_head: bool,

    fn run(self: *ClassifierStallFixture) void {
        const io = self.server.io;
        const stream = self.server.server.accept(io) catch return;
        defer stream.close(io);
        var read_buf: [8192]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var write_buf: [8192]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        _ = http_server.receiveHead() catch return;
        if (self.send_head) {
            writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n") catch return;
            writer.interface.flush() catch return;
        }
        io.sleep(.fromSeconds(30), .awake) catch {};
    }
};

test "lock architecture: client classifier watchdog cancels stalled response heads and bodies" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |send_head| {
        var server = try StallServer.init(io);
        defer server.deinit();
        var fixture: ClassifierStallFixture = .{ .server = &server, .send_head = send_head };
        var task = try io.concurrent(ClassifierStallFixture.run, .{&fixture});
        defer task.cancel(io);
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/classify", .{server.port()});
        defer gpa.free(url);
        const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
        // Select the same std.http.Client path used by Windows and HTTPS,
        // even on POSIX, so this regression is exercised on every platform.
        try std.testing.expectError(error.ClassifierTimeout, classifyExchange(gpa, io, url, "{}", 1, .http_client));
        try std.testing.expect(std.Io.Timestamp.now(io, .awake).nanoseconds - start < 3 * std.time.ns_per_s);
    }
}

test "client classifier body read is bounded by the socket timeout" {
    // The `std.http.Client` path must not park forever on a server that
    // answers the head and then goes quiet. This needs BOTH halves of the
    // fix: the socket timeout (`SO_RCVTIMEO`) that bounds the read, and the
    // timeout-aware Io that turns the resulting EAGAIN into `error.Timeout`
    // instead of Zig 0.16.0's `errnoBug` panic. Wrapping the Io alone is a
    // no-op — the wrapper reads `SO_RCVTIMEO`, finds no timeout, and falls
    // through to the unmodified read path.
    //
    // `classifyOverClient` is called directly, WITHOUT the
    // `ClassifierExchange` watchdog, so the socket-level bound is what ends
    // the read. Going through the watchdog would mask the difference: the
    // watchdog fires at the same deadline and would make the test pass with
    // the fix reverted.
    if (os.is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var server = try StallServer.init(io);
    defer server.deinit();
    var fixture: ClassifierStallFixture = .{ .server = &server, .send_head = true };
    var task = try io.concurrent(ClassifierStallFixture.run, .{&fixture});
    defer task.cancel(io);
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/classify", .{server.port()});
    defer gpa.free(url);

    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    // The head arrives, then the body never does. The socket timeout must
    // end the body read; without it the read parks until the server's
    // 30 s stall ends.
    const outcome = classifyOverClient(gpa, io, url, "{}", 1);
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - start;
    try std.testing.expect(outcome == error.Timeout or outcome == error.ReadFailed);
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}
