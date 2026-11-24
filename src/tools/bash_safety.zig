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
const tools_common = @import("common.zig");

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
};

/// A shell invocation that has passed the executor's classification gate
/// (#295). `runContained*` requires one so the containment runners receive
/// classified input by construction. Mint points, all documented: the
/// executor's gate after `classify` and the approval flow (via
/// `executor_safety.mintClassified`), the `skill` tool's command mode at the
/// registry boundary (upstream-classified; the fixed `Tool.run` signature
/// cannot carry the token), and the containment test fixtures. Zig has no
/// private fields, so forging the literal remains *possible* — but it is
/// now a greppable, documented act instead of an invisible default, and the
/// executor's contained path refuses a missing mint at runtime.
pub const ClassifiedCommand = struct {
    /// Diagnostic-only: what the mint point vouches for (the gate mints from
    /// the call's arguments; the skill boundary from the classified shell
    /// args). Never compared against what executes.
    command: []const u8,
};

/// The single sanctioned mint point for `ClassifiedCommand`.
pub fn mintClassified(command: []const u8) ClassifiedCommand {
    return .{ .command = command };
}

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
    return if (scopedLocalRule(trimmed) == null) .safe else .unsafe;
}

/// Whether a local destructive rule fires for `command`. Same verdict path
/// as `localClassify`, so the two never disagree on any command.
pub fn isDestructiveRule(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    return scopedLocalRule(trimmed) != null;
}

/// First rule that fires on `command` once the data arguments of a lone
/// search command are blanked (`blankSearchData`). The one verdict path for
/// both callers above: rules evaluate on the command's structure, never on
/// text that is only being searched for.
fn scopedLocalRule(command: []const u8) ?RuleId {
    var blanked_buf: [search_exempt_command_bytes_max]u8 = undefined;
    const blanked = blankSearchData(command, &blanked_buf) orelse command;
    return localClassifyRule(blanked);
}

/// Identifies which local rule fired for `command` — the same disjunction
/// `localClassify` folds into a verdict, exposed for diagnostics and tests.
/// Module-private by design: the remote path has no rule id, and no caller
/// may branch on attribution.
fn localClassifyRule(command: []const u8) ?RuleId {
    for (rules) |rule| {
        if (rule.matches(command)) return rule.id;
    }
    return null;
}

const RuleId = enum {
    fork_bomb_bash,
    fork_bomb_pwsh,
    rm_root,
    dd_block_device,
    mkfs_device,
    pwsh_remove_system,
    clear_recycle_bin,
    redirect_system_bash,
    redirect_system_pwsh,
    privileged_pm_escalator,
    privileged_pm_manager,
    privileged_pm_phrase,
    program_exec_option,
};

const Rule = struct {
    id: RuleId,
    matches: *const fn ([]const u8) bool,
};

/// The local matcher as an ordered rule table — a pure re-expression of the
/// former OR-chain in `localClassify`. ORDER MATTERS ONLY FOR ATTRIBUTION:
/// the first matching entry wins `localClassifyRule`, so rows keep the exact
/// precedence the OR-chain evaluated in (escalators before managers before
/// phrases, bash redirects before pwsh redirects, ...). Verdicts are
/// order-INDEPENDENT — the table is a pure disjunction of `.matches`, so
/// `.unsafe` results are identical under any row permutation. Adding a rule
/// is adding a row.
const rules = [_]Rule{
    // Fork bombs and infinite-recursion shell constructs (bash).
    .{ .id = .fork_bomb_bash, .matches = matchesBashForkBombDefinition },
    .{ .id = .fork_bomb_bash, .matches = matchesBashForkBombCall },
    // PowerShell fork-bomb equivalents.
    .{ .id = .fork_bomb_pwsh, .matches = isPwshForkBomb },
    // Destructive disk operations on system paths.
    .{ .id = .rm_root, .matches = isDangerousRm },
    .{ .id = .dd_block_device, .matches = isDangerousDd },
    .{ .id = .mkfs_device, .matches = isDangerousMkfs },
    .{ .id = .pwsh_remove_system, .matches = isDangerousPwshRemove },
    .{ .id = .clear_recycle_bin, .matches = isDangerousClearRecycleBin },
    // Overwriting critical system files.
    .{ .id = .redirect_system_bash, .matches = isDangerousBashRedirect },
    .{ .id = .redirect_system_pwsh, .matches = isDangerousPwshRedirect },
    // Privileged package management (e.g. `sudo apt install`, `doas pacman -S`).
    // These mutate the system-wide install state and must surface for approval
    // rather than running unattended — a model should never be able to attempt
    // `sudo apt install` without the interactive gate (TD-3). The three
    // sub-families keep the internal priority the single matcher had:
    // escalators, then managers, then multi-word install phrases.
    .{ .id = .privileged_pm_escalator, .matches = isPrivilegedPmEscalator },
    .{ .id = .privileged_pm_manager, .matches = isPrivilegedPmManager },
    .{ .id = .privileged_pm_phrase, .matches = isPrivilegedPmPhrase },
    // Options that execute a program or load additional flags from a file
    // (`rg --pre=rm`, `find -exec`, `tar --use-compress-program=...`).
    .{ .id = .program_exec_option, .matches = isProgramExecOption },
};

// ── Lone search commands: arguments are data, never code ─────────────
//
// `rg -e 'sudo'` searches for a word; it cannot run it. The rules above are
// quote-insensitive on purpose (`sh -c "rm -rf /"`), which made every search
// for a flagged token an `unsafe` verdict — a hard block for plugin shells.
// A lone search command is the one shape where its arguments are provably
// inert, so they are blanked before the rules run. The proof is narrow and
// fails closed: anything the lexer cannot vouch for leaves the command
// classified exactly as before.
//
//   - One simple command, spelled `rg`/`grep`/`egrep`/`fgrep` in lowercase:
//     no separator, redirect, substitution, env prefix or path qualifier.
//   - Outside single quotes only inert ASCII. Excluded: separators and
//     redirects, `$`/backtick/double-quote expansions, braces, backslashes
//     (an escape in bash, a path separator in PowerShell), `@` (splat and
//     here-string sigil) and every non-ASCII byte — PowerShell reads several
//     Unicode code points as quotes, dashes and newlines.
//   - Every option before `--` comes from `search_data_options_*`. An
//     unknown option denies the exemption for the whole command: ripgrep's
//     `--pre`, `--hostname-bin`, `--hyperlink-format` and `--config-path`
//     run programs or load further flags, and grep variants carry their own
//     (`--filter`, `--config`, `-Q` on ugrep). An option counts with or
//     without quotes, so `rg '--pre=apt'` is an option, never data.

const search_commands = [_][]const u8{ "rg", "grep", "egrep", "fgrep" };

/// Long options that only select what to read or how to print it, in
/// ripgrep and the grep family. Exact names; abbreviations are not options.
const search_data_options_long = [_][]const u8{
    "after-context",    "before-context", "binary-files",       "case-sensitive",
    "color",            "column",         "context",            "count",
    "encoding",         "engine",         "exclude",            "exclude-dir",
    "file",             "files",          "files-with-matches", "files-without-match",
    "fixed-strings",    "follow",         "glob",               "heading",
    "hidden",           "ignore-case",    "iglob",              "include",
    "include-dir",      "invert-match",   "json",               "line-buffered",
    "line-number",      "line-regexp",    "max-columns",        "max-columns-preview",
    "max-count",        "max-depth",      "max-filesize",       "multiline",
    "multiline-dotall", "no-column",      "no-config",          "no-filename",
    "no-heading",       "no-ignore",      "no-ignore-dot",      "no-ignore-parent",
    "no-ignore-vcs",    "no-line-number", "no-messages",        "no-require-git",
    "only-matching",    "pcre2",          "pretty",             "quiet",
    "recursive",        "regexp",         "replace",            "silent",
    "smart-case",       "sort",           "stats",              "text",
    "threads",          "trim",           "unrestricted",       "with-filename",
    "word-regexp",
};

/// Short option letters with the same property. They may cluster (`-in`)
/// and take a trailing count (`-A3`); each letter is harmless on its own,
/// so any split of a cluster is harmless too.
const search_data_options_short = "aAbBcCeFfgHhIilmnopPqrRsSUuvwx";

/// A command past this length is classified raw. The exemption works on a
/// bounded copy, and failing closed only forfeits the exemption.
const search_exempt_command_bytes_max: usize = 4096;

const SearchToken = struct {
    start: usize,
    end: usize,
    /// The whole token is one single-quoted string.
    quoted: bool,
};

const SearchLexError = error{NotSearchData};

fn isSearchSeparator(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

/// Bytes that cannot change how either shell splits or runs the command.
fn isSearchArgumentByte(byte: u8) bool {
    return switch (byte) {
        '!', '#', '%', '*', '+', ',', '-', '.', '/', ':', '=', '?', '[', ']', '^', '_', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// Next space- or tab-delimited token. Fails on the first byte that is not
/// inert outside single quotes, on a quote left open, and on a token that
/// mixes quoted and unquoted parts: bash and PowerShell split those
/// differently (`\'` and `-e'x'`), so their meaning cannot be vouched for.
fn nextSearchToken(command: []const u8, pos: *usize) SearchLexError!?SearchToken {
    while (pos.* < command.len and isSearchSeparator(command[pos.*])) pos.* += 1;
    if (pos.* == command.len) return null;

    const start = pos.*;
    var in_quote = false;
    var quote_count: usize = 0;
    while (pos.* < command.len) : (pos.* += 1) {
        const byte = command[pos.*];
        if (byte == '\'') {
            in_quote = !in_quote;
            quote_count += 1;
        } else if (!in_quote) {
            // Between single quotes every other byte is literal in both shells.
            if (isSearchSeparator(byte)) break;
            if (!isSearchArgumentByte(byte)) return error.NotSearchData;
        }
    }
    if (in_quote) return error.NotSearchData;

    const quoted = quote_count == 2 and command[start] == '\'' and command[pos.* - 1] == '\'';
    if (quote_count != 0 and !quoted) return error.NotSearchData;
    return .{ .start = start, .end = pos.*, .quoted = quoted };
}

fn isSearchCommand(word: []const u8) bool {
    for (search_commands) |name| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

/// Whether `option` (without its quotes) only selects what to read or how to
/// print it. `-` and `--` are not options here: `-` is stdin, `--` ends them.
fn isSearchDataOption(option: []const u8) bool {
    if (option.len < 2 or option[0] != '-') return false;

    if (option[1] == '-') {
        const name_end = std.mem.indexOfScalar(u8, option, '=') orelse option.len;
        for (search_data_options_long) |name| {
            if (std.mem.eql(u8, option[2..name_end], name)) return true;
        }
        return false;
    }

    var index: usize = 1;
    while (index < option.len and std.ascii.isAlphabetic(option[index])) : (index += 1) {
        if (std.mem.indexOfScalar(u8, search_data_options_short, option[index]) == null) return false;
    }
    if (index == 1) return false;
    while (index < option.len) : (index += 1) {
        if (!std.ascii.isDigit(option[index])) return false;
    }
    return true;
}

/// Blank the data arguments of a lone search command into `buf` and return
/// the result, or null when `command` is not one. Options stay, so the rules
/// still see them.
fn blankSearchData(command: []const u8, buf: *[search_exempt_command_bytes_max]u8) ?[]const u8 {
    if (command.len > buf.len) return null;

    var pos: usize = 0;
    const head = (nextSearchToken(command, &pos) catch return null) orelse return null;
    const head_word = command[head.start..head.end];
    if (head.quoted or !isSearchCommand(head_word)) return null;

    @memcpy(buf[0..command.len], command);
    const blanked = buf[0..command.len];
    var past_options = false;
    while (true) {
        const next = nextSearchToken(command, &pos) catch return null;
        const token = next orelse break;
        const text = command[token.start..token.end];
        const argument = if (token.quoted) text[1 .. text.len - 1] else text;

        const is_option = !past_options and argument.len > 0 and argument[0] == '-';
        if (!is_option) {
            @memset(blanked[token.start..token.end], ' ');
        } else if (std.mem.eql(u8, argument, "--")) {
            past_options = true;
        } else if (!isSearchDataOption(argument)) {
            return null;
        }
    }
    return blanked;
}

/// Fork-bomb definition construct `:(){` (the classic `:(){ :|:& };:`).
fn matchesBashForkBombDefinition(command: []const u8) bool {
    return std.mem.indexOf(u8, command, ":(){") != null;
}

/// Fork-bomb call construct `:()` (a recursion seeding without the open
/// brace, still an infinite-recursion shape).
fn matchesBashForkBombCall(command: []const u8) bool {
    return std.mem.indexOf(u8, command, ":()") != null;
}

/// True when `command` escalates privileges (`sudo`/`doas`/`runas`).
fn isPrivilegedPmEscalator(command: []const u8) bool {
    const escalators = [_][]const u8{ "sudo", "doas", "runas" };
    for (escalators) |esc| {
        if (tokenContains(command, esc)) return true;
    }
    return false;
}

/// True when `command` invokes a system package manager (`apt`, `dnf`,
/// `brew`, ...). Single-token package managers (exact token match,
/// case-insensitive). Self-installing managers matched as a bare token
/// (case-insensitive, exact token). The tokenizer splits on shell
/// metacharacters but NOT "-"/"." so "apt-cache" / "aptitude" stay single
/// tokens and do not false-positive on "apt", while "/usr/bin/apt", "./apt"
/// and "apt;install" still split to the bare "apt" token.
fn isPrivilegedPmManager(command: []const u8) bool {
    const managers = [_][]const u8{
        "apt",    "apt-get", "dpkg",     "dnf",     "yum",  "pacman", "apk", "brew",
        "zypper", "emerge",  "aptitude", "nix-env", "snap",
    };
    for (managers) |mgr| {
        if (tokenContains(command, mgr)) return true;
    }
    return false;
}

/// True when `command` matches a multi-word install verb (`pip install`,
/// `winget install`, ...), matched only at word boundaries so `pip show` /
/// `apt-cache show` stay safe reads while `apt;install` (no space) still
/// trips the `apt` single-token rule above. The Windows installers
/// (`winget`, `choco`, `scoop`) are phrase-matched so read-only subcommands
/// (`winget list`, `choco list`) stay safe; the Windows shell target is
/// pwsh, where these are the standard managers.
fn isPrivilegedPmPhrase(command: []const u8) bool {
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

/// True when `command` uses a flag that executes an arbitrary program or
/// loads further options (`rg --pre=...`, `find -exec`, `tar
/// --use-compress-program=...`). Matched as a whole normalized token so
/// `--pre` flags `--pre=rm` without false-positiving on `--pre-glob`.
fn isProgramExecOption(command: []const u8) bool {
    const options = [_][]const u8{
        "--pre",
        "--hostname-bin",
        "--config-path",
        "--filter",
        "--use-compress-program",
        "--compress-program",
        "-exec",
        "-execdir",
    };
    for (options) |opt| {
        if (tokenContains(command, opt)) return true;
    }
    return false;
}

/// Case-insensitive check that `needle` appears as a whole token anywhere in
/// `command`, where tokens are split on whitespace, `=`, AND shell
/// metacharacters (`; | & ( ) < > / . \'"\\``). This catches `apt;install`,
/// `/usr/bin/apt`, `./apt`, `apt\ninstall`, and `--opt=sudo` — all of which
/// a space-only split would miss.
fn isNormalizedSep(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\t' or ch == ';' or ch == '|' or ch == '&' or
        ch == '(' or ch == ')' or ch == '<' or ch == '>' or ch == '/' or
        ch == '.' or ch == '\'' or ch == '"' or ch == '`' or ch == '=';
}

/// Stream-scan normalized tokens without a fixed 4096-byte buffer (#419).
fn nextNormalizedToken(command: []const u8, pos: *usize) ?[]const u8 {
    var i = pos.*;
    while (i < command.len and isNormalizedSep(command[i])) i += 1;
    if (i >= command.len) {
        pos.* = i;
        return null;
    }
    const start = i;
    while (i < command.len and !isNormalizedSep(command[i])) i += 1;
    pos.* = i;
    return command[start..i];
}

fn tokenContains(command: []const u8, needle: []const u8) bool {
    var pos: usize = 0;
    while (nextNormalizedToken(command, &pos)) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, needle)) return true;
    }
    return false;
}

/// Case-insensitive match of `phrase` (space-separated lowercase words)
/// against consecutive normalized tokens without a fixed 4096-byte buffer
/// (#419), so `apt\ninstall` and `PIP INSTALL` match at any offset.
fn phraseAtBoundary(command: []const u8, phrase: []const u8) bool {
    var first_it = std.mem.tokenizeScalar(u8, phrase, ' ');
    const first_word = first_it.next() orelse return false;

    var pos: usize = 0;
    while (nextNormalizedToken(command, &pos)) |tok| {
        if (!std.ascii.eqlIgnoreCase(tok, first_word)) continue;
        var look_pos = pos;
        var rest_it = first_it;
        var matched = true;
        while (rest_it.next()) |word| {
            const next_tok = nextNormalizedToken(command, &look_pos) orelse {
                matched = false;
                break;
            };
            if (!std.ascii.eqlIgnoreCase(next_tok, word)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

/// True for whitespace or any shell metacharacter that separates tokens.
fn isBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '|' or c == '&' or c == '(' or c == ')' or c == '<' or c == '>' or c == '/' or c == '.' or c == '"' or c == '\'' or c == '`';
}

/// PowerShell fork-bomb equivalents: recursive `while($true){Start-Job ...}`
/// loops and `ForEach-Object -Parallel`/`Start-ThreadJob` constructs that fan
/// out unbounded worker processes. `Start-Process` in such a loop is the
/// same shape: one unbounded process spawn per iteration.
fn isPwshForkBomb(command: []const u8) bool {
    if (containsIgnoreCase(command, "while($true)") or containsIgnoreCase(command, "while ($true)")) {
        if (containsIgnoreCase(command, "Start-Job") or containsIgnoreCase(command, "Start-Process")) return true;
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
/// which never needs Unicode folding). Deliberately a named alias at the
/// classifier's call sites; the shared primitive in `tools/common.zig`
/// documents the exact semantics (ASCII-only folding, empty needle matches).
const containsIgnoreCase = tools_common.containsIgnoreCase;

test "containsIgnoreCase: empty needle matches, case folded" {
    try std.testing.expect(containsIgnoreCase("Remove-Item", ""));
    try std.testing.expect(containsIgnoreCase("rm -RF /", "-rf"));
    try std.testing.expect(!containsIgnoreCase("rm", "-rf"));
}

/// Characters that may sit directly before an `rm`/`dd` command word while it
/// still reads as command position: shell separators (`;`, `|`, `&` —
/// including unspaced `&&rm`), substitution openings (`(`, backtick), quotes
/// (`sh -c "rm -rf /"`), `=` (`--pre=rm`, `CMD=rm`), and the backslash escape
/// (`\rm` bypasses a rm alias but still runs rm). Anything else (a letter in
/// `alarm`, a digit) means the match is inside a larger word, not a command.
fn isCommandWordBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == ';' or c == '|' or c == '&' or
        c == '(' or c == '`' or c == '"' or c == '\'' or c == '\\' or c == '=';
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
        // Look for `-rf`, `-fr`, `-r -f`, `-f -r` (including uppercase `-R`
        // synonym for recursive, #419).
        const has_recursive = std.ascii.indexOfIgnoreCase(rest, "-rf") != null or
            std.ascii.indexOfIgnoreCase(rest, "-fr") != null or
            std.ascii.indexOfIgnoreCase(rest, "-r -f") != null or
            std.ascii.indexOfIgnoreCase(rest, "-f -r") != null;
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

/// Check for redirecting into critical POSIX system files.
fn isDangerousBashRedirect(command: []const u8) bool {
    // Structural scan: every `>` (including `>>` and `2>`) with any run of
    // whitespace and one optional quote before the target, so `>/etc/x`,
    // `>> /etc/x`, and `> "/etc/x"` classify the same as `> /etc/x`. The
    // adjacent force-clobber spelling `>| /etc/x` is covered too: its `|`
    // belongs to the operator, and a spaced `> |` is a bash syntax error
    // rather than an executable redirect. Targets are path prefixes, so a
    // `>` used as a comparison (`3 > 2`) has no target and stays safe.
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
        if (after < command.len and command[after] == '|') after += 1;
        while (after < command.len and std.ascii.isWhitespace(command[after])) after += 1;
        if (after < command.len and (command[after] == '\'' or command[after] == '"')) after += 1;
        const target_slice = command[after..];
        // Variable (`$x`, `${x}`) and brace (`{/etc,/tmp}/x`) redirect targets
        // can expand to protected paths at runtime — fail closed (#536).
        if (target_slice.len > 0 and (target_slice[0] == '$' or target_slice[0] == '{')) return true;
        if (redirectTargetHasParentTraversal(target_slice)) return true;
        for (dangerous_targets) |target| {
            if (unescapedStartsWith(target_slice, target)) return true;
        }
        idx = gt + 1;
    }
    return false;
}

fn redirectTargetHasParentTraversal(target: []const u8) bool {
    var i: usize = 0;
    var seg_len: usize = 0;
    var seg_dots: usize = 0;
    while (i < target.len) : (i += 1) {
        var c = target[i];
        if (std.ascii.isWhitespace(c) or c == ';' or c == '|' or c == '&' or c == '\'' or c == '"') break;
        if (c == '\\' and i + 1 < target.len) {
            i += 1;
            c = target[i];
        }
        if (c == '/') {
            if (seg_len == 2 and seg_dots == 2) return true;
            seg_len = 0;
            seg_dots = 0;
        } else {
            seg_len += 1;
            if (c == '.') seg_dots += 1;
        }
    }
    return seg_len == 2 and seg_dots == 2;
}

/// Compare `haystack` against `prefix` while unescaping bash backslash escapes
/// (`\X` -> `X`), so `> /etc\/passwd` matches `/etc/` (#419).
fn unescapedStartsWith(haystack: []const u8, prefix: []const u8) bool {
    var hi: usize = 0;
    var pi: usize = 0;
    while (pi < prefix.len) : (pi += 1) {
        if (hi >= haystack.len) return false;
        if (haystack[hi] == '\\') {
            hi += 1;
            if (hi >= haystack.len) return false;
        }
        if (haystack[hi] != prefix[pi]) return false;
        hi += 1;
    }
    return true;
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

test "S4 force-clobber redirects still flag" {
    // `>|` is bash's noclobber override; the `|` is part of the redirect
    // operator, so the target scan must look past it: `echo x >| /etc/passwd`
    // is the same critical-file overwrite as `> /etc/passwd`.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x >| /etc/passwd"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo hacker::0:0::/:/bin/sh >|/etc/passwd"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("make 2>| /dev/sda"));
    // A clobber into a harmless target stays safe.
    try std.testing.expectEqual(Verdict.safe, localClassify("echo x >| build.log"));
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

test "S7 pwsh fork-bomb Start-Process loop still flags" {
    // `while($true){Start-Process x}` fans out unbounded processes exactly
    // like the recognized Start-Job forms; the loop + process-spawn
    // conjunction is the same pathological shape.
    try std.testing.expectEqual(Verdict.unsafe, localClassify("while($true){Start-Process notepad}"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("while ($true) { Start-Process cmd }"));
    // A loop without process fan-out, or a spawn without a loop, is not a
    // fork bomb.
    try std.testing.expectEqual(Verdict.safe, localClassify("while($true){ Write-Output x }"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Start-Process notepad"));
    try std.testing.expectEqual(Verdict.safe, localClassify("while($true){ Start-Sleep -Seconds 1 }"));
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

// ── Lone search commands: data arguments are not code ────────────────

/// Fails with the command in the message: a bare `expectEqual` inside a loop
/// over commands does not say which one was misjudged. Also checks the
/// session-approval gate, which asks the same question another way.
fn expectVerdict(command: []const u8, expected: Verdict) !void {
    const got = localClassify(command);
    if (got != expected) {
        std.debug.print("misjudged command ({s} expected, {s} returned): {s}\n", .{ @tagName(expected), @tagName(got), command });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(expected == .unsafe, isDestructiveRule(command));
}

/// Fails unless the exemption refuses `command`, naming it.
fn expectNoExemption(command: []const u8, buf: *[search_exempt_command_bytes_max]u8) !void {
    if (blankSearchData(command, buf) != null) {
        std.debug.print("exemption granted to a command it must refuse: {s}\n", .{command});
        return error.TestUnexpectedResult;
    }
}

test "lone search commands may search for text the rules would flag" {
    const searched = [_][]const u8{
        // The search-tools plugin's ripgrep line, and its overflow retry.
        "rg --json --color never --glob '*.zig' -m 50 -e 'sudo|doas' -- .",
        "rg --json --color never -m 1 -e 'apt' -- src",
        "rg -e 'sudo' -- .",
        "rg -e ':(){ :|:& };:' docs",
        "rg 'rm -rf /' src",
        "rg -e 'a|b' -e 'pip install' src",
        "rg sudo",
        "grep -rn 'apt install' .",
        "grep -e 'doas' /etc/config",
        "egrep 'brew' .",
        "fgrep 'pacman -S' .",
        "rg --glob '*.zig' --max-columns-preview -n -e 'snap' .",
        "rg -A3 -B2 -C1 -m5 -e 'apk' .",
        "rg -in -e 'zypper' --max-count=20 --color=never .",
        // After `--` everything is a path, whatever it looks like.
        "rg -- '--pre sudo'",
        // Two arguments, both inert however they read.
        "rg -e 'x' 'sudo apt install'",
    };
    for (searched) |command| {
        // Every case really is text the raw rules flag — otherwise the
        // test would pass without the exemption doing anything.
        try std.testing.expect(localClassifyRule(command) != null);
        try expectVerdict(command, .safe);
    }
}

test "lone search exemption fails closed and leaves flagged searches flagged" {
    // Each command names a search tool and reads like a search, yet the raw
    // rules flag it. The exemption must not apply, so the verdict stays
    // `unsafe` exactly as before.
    const still_flagged = [_][]const u8{
        // Not a lone search command.
        "sudo rg -e 'x' .",
        "command rg -e 'sudo' .",
        "/usr/bin/rg -e 'sudo' .",
        "RG -e 'sudo' .",
        "echo 'sudo'",
        "sh -c \"rg -e 'sudo' .\"",
        // A second command, however it is spelled.
        "rg -e 'x'; sudo apt install y",
        "rg -e 'x' && sudo apt install y",
        "rg -e 'x' | sudo tee /etc/hosts",
        "rg -e 'x' & sudo apt install y",
        "rg -e 'x'\n sudo apt install y",
        "rg -e 'x' (cd /tmp && sudo apt install y)",
        "rg -e 'x' { sudo apt install y; }",
        // Redirects and substitutions.
        "rg -e 'x' > /etc/passwd",
        "rg -e 'sudo' >/etc/passwd",
        "rg -e 'x' 2> /etc/passwd",
        "rg -e \"$(sudo apt install y)\"",
        "rg -e 'x' `sudo apt install y`",
        "rg -e 'it'\\''; sudo apt install y'",
        // Options that run programs or load further options, quoted or not.
        "rg --pre 'sudo' .",
        "rg '--pre=sudo' .",
        "rg --pre=sudo -e 'x' .",
        "rg --pre=rm --pre-glob '*' x .",
        "rg --hostname-bin 'sudo' .",
        "rg --config-path 'sudo' .",
        "rg --config-path ./rgrc .",
        "grep --filter 'sudo' .",
        "grep -Q 'sudo'",
        // Any option outside the allowlist, wherever it appears.
        "rg -z -e 'sudo' .",
        "rg --unknown -e 'sudo' .",
        "rg --max-col -e 'sudo' .",
        "rg -e 'sudo' --unknown .",
        // Quote shapes bash and PowerShell split differently.
        "rg -e'sudo' .",
        "rg -e 'sudo'src",
        "rg -e ''sudo'' .",
        "rg -e 'sudo",
        "rg -e 'a\\' ; sudo apt install y",
        // Bytes that are not inert outside single quotes: a PowerShell
        // here-string header, a Unicode line separator, a backslash path.
        "rg -e @'\nsudo apt install y\n'@",
        "rg -e 'x' \u{2028} sudo apt install y",
        "rg -e 'x' src\\tools; sudo apt install y",
    };
    var buf: [search_exempt_command_bytes_max]u8 = undefined;
    for (still_flagged) |command| {
        try expectNoExemption(command, &buf);
        try expectVerdict(command, .unsafe);
    }

    // Denied as well, and raw-safe: the verdict must simply not move.
    const unchanged = [_][]const u8{
        "rg --hyperlink-format '{h}' .",
        "rg -e 'x' | cat",
    };
    for (unchanged) |command| {
        try expectNoExemption(command, &buf);
        try expectVerdict(command, .safe);
    }
}

test "lone search exemption is bounded and yields to the raw verdict past its bound" {
    const gpa = std.testing.allocator;
    // A pattern past the bound, with the flagged word as a token of its own
    // so the raw rules see it: the command is classified raw — still
    // flagged, never waved through.
    const padding = try gpa.alloc(u8, search_exempt_command_bytes_max);
    defer gpa.free(padding);
    @memset(padding, 'x');
    const too_long = try std.fmt.allocPrint(gpa, "rg -e '{s} sudo' .", .{padding});
    defer gpa.free(too_long);

    var buf: [search_exempt_command_bytes_max]u8 = undefined;
    try expectNoExemption(too_long, &buf);
    try expectVerdict(too_long, .unsafe);
}

test "lone search exemption keeps the options and blanks only the data" {
    var buf: [search_exempt_command_bytes_max]u8 = undefined;
    const blanked = blankSearchData("rg -n -e 'sudo' --glob '*.zig' -- --pre=apt", &buf).?;
    // Option tokens stay; every data argument keeps its width and loses its
    // bytes ('sudo' and '*.zig' six and seven wide with their quotes,
    // --pre=apt nine).
    try std.testing.expectEqualStrings("rg -n -e " ++ "      " ++ " --glob " ++ "       " ++ " -- " ++ "         ", blanked);
    // The search word itself has to be bare: a quoted one is a different command.
    try std.testing.expect(blankSearchData("'rg' -e 'sudo' .", &buf) == null);
}

test "isSearchDataOption accepts only allowlisted options in their exact spelling" {
    const allowed = [_][]const u8{
        "--json", "--color=never", "--max-columns-preview", "--no-ignore-vcs",
        "-i",     "-in",           "-A3",                   "-m50",
        "-uuu",   "-e5",           "-P",                    "-rS",
        "-g",
    };
    const denied = [_][]const u8{
        "-",        "--",      "--pre", "--pre=sh", "--pr", "--jsonx",
        "--json-x", "-z",      "-Q",    "-0",       "-i.",  "-i=x",
        "--=x",     "---json", "",      "x",        "-pQ",
    };
    for (allowed) |option| try std.testing.expect(isSearchDataOption(option));
    for (denied) |option| try std.testing.expect(!isSearchDataOption(option));
}

test "rule table: every rule attributes its first-fire input" {
    // One input per table row where that row is the FIRST to fire, so the
    // table's ordering is pinned: attribution must match the row's id. The
    // inputs are chosen so no earlier rule can claim them (e.g. `sudo apt
    // install` attributes to the escalator entry, not the manager or the
    // phrase; the pwsh Remove-Item spellings do not trip the bash rm rule).
    const cases = [_]struct { input: []const u8, expected: RuleId }{
        .{ .input = ":(){ :|:& };:", .expected = .fork_bomb_bash },
        .{ .input = ":() recursion;:", .expected = .fork_bomb_bash },
        .{ .input = "while($true){Start-Job {}}", .expected = .fork_bomb_pwsh },
        .{ .input = "rm -rf /", .expected = .rm_root },
        .{ .input = "dd if=/dev/zero of=/dev/sda", .expected = .dd_block_device },
        .{ .input = "mkfs.ext4 /dev/sda1", .expected = .mkfs_device },
        .{ .input = "Remove-Item -Recurse -Force C:\\", .expected = .pwsh_remove_system },
        .{ .input = "Clear-RecycleBin -Force", .expected = .clear_recycle_bin },
        .{ .input = "echo x > /etc/passwd", .expected = .redirect_system_bash },
        .{ .input = "Write-Output 'x' > C:\\Windows\\x.txt", .expected = .redirect_system_pwsh },
        .{ .input = "sudo apt install nginx", .expected = .privileged_pm_escalator },
        .{ .input = "apt-get update", .expected = .privileged_pm_manager },
        .{ .input = "pip install requests", .expected = .privileged_pm_phrase },
        .{ .input = "rg --pre=rm --pre-glob '*' x .", .expected = .program_exec_option },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, localClassifyRule(case.input).?);
    }
}

test "equals-attached option values and program-exec options (#595)" {
    // Every rule that can be reached through an `=`-attached value or a
    // program-executing option must classify `.unsafe`, while ordinary
    // `KEY=value` arguments stay `.safe`.
    const unsafe_cases = [_][]const u8{
        "rg --pre=sudo .",
        "rg '--pre=sudo' .",
        "rg --pre=rm --pre-glob '*' x .",
        "rg --hostname-bin=sh .",
        "rg --config-path=./rgrc .",
        "grep --filter=sh x .",
        "tar --use-compress-program=sh -xf a.tar",
        "sort --compress-program=sh file.txt",
        "find . -exec rm {} +",
        "find . -execdir sh -c 'echo x' {} +",
        "CMD=rm -rf /",
        "OPT='--flag=apt'",
        "RUN='pip install x'",
    };
    for (unsafe_cases) |cmd| {
        try expectVerdict(cmd, .unsafe);
    }

    const safe_cases = [_][]const u8{
        "git commit -m x",
        "cargo build --features=a,b",
        "echo PATH=/usr/bin",
        "rg --pre-glob '*.zig' x .",
        "git diff --message=hello",
        "curl https://example.com?page=1",
        "dd if=/dev/zero of=/dev/null",
    };
    for (safe_cases) |cmd| {
        try expectVerdict(cmd, .safe);
    }
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

test "bash safety classifier catches backslash redirect, uppercase rm -Rf, and >4096B commands (#419)" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > /etc\\/passwd"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > \"/dev\\/sda\""));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -Rf /"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -R -f /"));

    const long_cmd = "echo " ++ ("a" ** 5000) ++ "; sudo apt install malware";
    try std.testing.expectEqual(Verdict.unsafe, localClassify(long_cmd));

    // Variable, brace, and parent-traversal redirect targets fail closed (#536).
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > $TARGET_FILE"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > ${HOME}/out"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > {/etc,/tmp}/pwn"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > /tmp/../etc/passwd"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo x > /" ++ ("a" ** 300) ++ "/../etc/passwd"));
}
