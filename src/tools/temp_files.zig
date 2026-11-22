//! Temp-file name prefixes shared by the writers (bash_exec, pwsh_exec,
//! background) and the startup pruner (bash_exec.pruneTempDir). The pruner
//! matches on these prefixes, so every writer file name MUST start with one of
//! `prunable_prefixes` — otherwise a crash-stranded file is never reaped by the
//! 24h startup cleanup. The values are load-bearing history: files written by
//! older binaries carry these exact prefixes, so changing one silently stops
//! pruning every pre-existing temp file.

const std = @import("std");

/// Spill files from the bash tool's disk-backed capture: `zay-bash-<hex>.log`.
pub const bash_spill_prefix = "zay-bash-";

/// PowerShell temp files: spill logs (`zay-pwsh-<hex>.log`), exit-checked
/// scripts (`zay-pwsh-script-<hex>.ps1`), and background scripts
/// (`zay-pwsh-bg-<hex>.ps1`).
pub const pwsh_prefix = "zay-pwsh-";

/// Background job logs, composed from the job id: `zay-bg_<id>.log`.
pub const bg_log_prefix = "zay-bg_";

/// Everything the startup pruner may delete. Bare `zay-` is deliberately
/// absent so unrelated temp files that merely start with `zay-` are never
/// touched.
pub const prunable_prefixes = [_][]const u8{ bash_spill_prefix, pwsh_prefix, bg_log_prefix };

/// True when `name` matches one of Zay's generated temp-file shapes:
/// - `zay-bash-<hex>.log`
/// - `zay-pwsh-<hex>.log`
/// - `zay-pwsh-script-<hex>.ps1`
/// - `zay-pwsh-bg-<hex>.ps1`
/// - `zay-bg_<digits>.log`
pub fn isPrunable(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, bash_spill_prefix)) {
        return hasStemAndExt(name[bash_spill_prefix.len..], ".log", isLowerHex);
    }
    if (std.mem.startsWith(u8, name, pwsh_prefix)) {
        const rest = name[pwsh_prefix.len..];
        if (std.mem.startsWith(u8, rest, "script-")) {
            return hasStemAndExt(rest["script-".len..], ".ps1", isLowerHex);
        }
        if (std.mem.startsWith(u8, rest, "bg-")) {
            return hasStemAndExt(rest["bg-".len..], ".ps1", isLowerHex);
        }
        return hasStemAndExt(rest, ".log", isLowerHex);
    }
    if (std.mem.startsWith(u8, name, bg_log_prefix)) {
        return hasStemAndExt(name[bg_log_prefix.len..], ".log", std.ascii.isDigit);
    }
    return false;
}

fn hasStemAndExt(rest: []const u8, ext: []const u8, comptime pred: fn (u8) bool) bool {
    if (rest.len <= ext.len) return false;
    if (!std.mem.endsWith(u8, rest, ext)) return false;
    const stem = rest[0 .. rest.len - ext.len];
    for (stem) |c| {
        if (!pred(c)) return false;
    }
    return true;
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

test "prunablePrefixes_matchExpectedValues" {
    // Pin the exact prefix values: files from older binaries carry them, so an
    // accidental value change would strand every pre-existing temp file past
    // the startup prune.
    try std.testing.expectEqualStrings("zay-bash-", bash_spill_prefix);
    try std.testing.expectEqualStrings("zay-pwsh-", pwsh_prefix);
    try std.testing.expectEqualStrings("zay-bg_", bg_log_prefix);
}

test "isPrunable rejects unrelated filenames sharing reserved prefixes" {
    try std.testing.expect(!isPrunable("zay-bg_notes.log"));
    try std.testing.expect(!isPrunable("zay-bash-readme.txt"));
    try std.testing.expect(!isPrunable("zay-pwsh-notes.log"));
    try std.testing.expect(!isPrunable("zay-bash-.log"));
    try std.testing.expect(!isPrunable("zay-bg_.log"));
    try std.testing.expect(isPrunable("zay-bg_42.log"));
    try std.testing.expect(isPrunable("zay-pwsh-script-0123abcd.ps1"));
    try std.testing.expect(isPrunable("zay-pwsh-bg-0123abcd.ps1"));
}

test "isPrunable_returnsTrue_whenNameHasValidPrefix" {
    // Every name shape produced by writers
    try std.testing.expect(isPrunable(bash_spill_prefix ++ "a1b2c3.log"));
    try std.testing.expect(isPrunable(pwsh_prefix ++ "a1b2c3.log"));
    try std.testing.expect(isPrunable(pwsh_prefix ++ "script-a1b2c3.ps1"));
    try std.testing.expect(isPrunable(pwsh_prefix ++ "bg-a1b2c3.ps1"));
    try std.testing.expect(isPrunable(bg_log_prefix ++ "7.log"));

    // Bare exact prefixes without trailing filenames/suffixes must NOT be pruned.
    try std.testing.expect(!isPrunable(bash_spill_prefix));
    try std.testing.expect(!isPrunable(pwsh_prefix));
    try std.testing.expect(!isPrunable(bg_log_prefix));
}

test "isPrunable_returnsFalse_whenNameLacksValidPrefix" {
    // Bare `zay-` must stay unprunable
    try std.testing.expect(!isPrunable("zay-other.txt"));
    try std.testing.expect(!isPrunable("zay-"));

    // Partial or misspelled prefixes
    try std.testing.expect(!isPrunable("zay-bas"));
    try std.testing.expect(!isPrunable("zay-pws"));
    try std.testing.expect(!isPrunable("zay-b"));

    // Uppercase / case variants (prefixes are strictly lower-case)
    try std.testing.expect(!isPrunable("ZAY-BASH-123.log"));
    try std.testing.expect(!isPrunable("ZAY-PWSH-123.log"));

    // Prefixes in middle or end of string (must start with prefix)
    try std.testing.expect(!isPrunable("tmp/zay-bash-123.log"));
    try std.testing.expect(!isPrunable("prefix_zay-bg_1.log"));

    // Unrelated files & empty string
    try std.testing.expect(!isPrunable("keep.txt"));
    try std.testing.expect(!isPrunable(""));
}
