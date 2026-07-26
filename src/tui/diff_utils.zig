//! Pure diff-counting helpers — extracted from `tui.zig` (R7.4 of tui-split).
//!
//! Allocation-free stat/numstat parsers and a label loader for the git branch
//! display in the input border. No `App` dependency — pure functions over
//! `[]const u8` / `DiffCounts`.

const std = @import("std");
const DiffCounts = @import("../tui.zig").DiffCounts;
const bash_mod = @import("../tools/bash_exec.zig");

/// Parse `git diff --stat` output into additions/deletions.
/// `+N` / `-M` lines are summed; binary stanzas are skipped.
pub fn parseDiffCounts(output: []const u8) DiffCounts {
    var counts: DiffCounts = .{};
    var line_start: usize = 0;
    while (line_start <= output.len) {
        const line_end = std.mem.findScalarPos(u8, output, line_start, '\n') orelse output.len;
        parseDiffCountLine(&counts, output[line_start..line_end]);
        if (line_end == output.len) break;
        line_start = line_end + 1;
    }
    return counts;
}

/// Count additions/deletions straight from a unified diff by tallying `+`/`-`
/// body lines (excluding the `+++`/`---` file headers). A cheap, allocation-free
/// scan used on the cached full diff.
pub fn countDiff(raw: []const u8) DiffCounts {
    var counts: DiffCounts = .{};
    var line_start: usize = 0;
    while (line_start <= raw.len) {
        const line_end = std.mem.findScalarPos(u8, raw, line_start, '\n') orelse raw.len;
        const line = raw[line_start..line_end];
        if (line.len > 0) {
            if (line[0] == '+' and !std.mem.startsWith(u8, line, "+++")) {
                counts.additions = saturatingAdd(counts.additions, 1);
            } else if (line[0] == '-' and !std.mem.startsWith(u8, line, "---")) {
                counts.deletions = saturatingAdd(counts.deletions, 1);
            }
        }
        if (line_end == raw.len) break;
        line_start = line_end + 1;
    }
    return counts;
}

fn parseDiffCountLine(counts: *DiffCounts, line: []const u8) void {
    if (line.len == 0) return;
    const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return;
    const rest = line[first_tab + 1 ..];
    const second_tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return;
    counts.additions = saturatingAdd(counts.additions, parseNumstatField(line[0..first_tab]));
    counts.deletions = saturatingAdd(counts.deletions, parseNumstatField(rest[0..second_tab]));
}

fn parseNumstatField(field: []const u8) u32 {
    if (field.len == 0) return 0;
    if (std.mem.eql(u8, field, "-")) return 0;
    const value = std.fmt.parseUnsigned(u64, field, 10) catch return 0;
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn saturatingAdd(a: u32, b: u32) u32 {
    const sum: u64 = @as(u64, a) + @as(u64, b);
    return @intCast(@min(sum, std.math.maxInt(u32)));
}

/// Load the git branch label from the repo at `cwd`. Shells out to
/// a bash script that fetches repo name + branch/commit hash.
pub fn loadGitLabel(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]const u8 {
    const command =
        \\root=$(git rev-parse --show-toplevel 2>/dev/null)
        \\if [ -n "$root" ]; then repo=$(basename "$root"); else repo=$(basename "$PWD"); fi
        \\branch=$(git branch --show-current 2>/dev/null)
        \\if [ -z "$branch" ]; then branch=$(git rev-parse --short HEAD 2>/dev/null); fi
        \\if [ -n "$branch" ]; then printf '%s\t%s' "$repo" "$branch"; else printf '%s' "$repo"; fi
    ;
    var result = try bash_mod.runWithOptions(gpa, io, .{
        .cwd = cwd,
        .command = command,
        .timeout = bash_mod.timeoutFromSeconds(2),
    });
    defer result.deinit(gpa);
    if (result.code != 0) return "";
    const out = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (out.len == 0) return "";
    if (std.mem.indexOfScalar(u8, out, '\t')) |tab| {
        return std.fmt.allocPrint(gpa, "{s} ⌥ {s}", .{ out[0..tab], out[tab + 1 ..] });
    }
    return gpa.dupe(u8, out);
}
