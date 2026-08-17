//! Pure diff-counting helpers — extracted from `tui.zig` (R7.4 of tui-split).
//!
//! Allocation-free stat/numstat parsers and a label loader for the git branch
//! display in the input border. No `App` dependency — pure functions over
//! `[]const u8` / `DiffCounts`.

const std = @import("std");
const DiffCounts = @import("../tui.zig").DiffCounts;
const vcs = @import("../vcs.zig");

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

/// Load the git branch label from the repo at `cwd`. Uses native `git` CLI
/// execution (cross-platform, zero bash dependency) to fetch repo name + branch/commit hash.
pub fn loadGitLabel(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]const u8 {
    if (!vcs.isRepo(gpa, io, cwd)) return "";

    // 1. Get repo top-level directory name
    const repo_root = vcs.runOut(gpa, io, cwd, &.{ "rev-parse", "--show-toplevel" }, null) catch null;
    defer if (repo_root) |r| gpa.free(r);

    const repo_name = if (repo_root) |r| blk: {
        const trimmed = std.mem.trim(u8, r, " \t\r\n");
        break :blk std.fs.path.basename(trimmed);
    } else std.fs.path.basename(cwd);

    // 2. Get current branch or short commit hash
    var branch_buf: ?[]u8 = null;
    defer if (branch_buf) |b| gpa.free(b);

    const branch = if (vcs.currentBranch(gpa, io, cwd)) |b| blk: {
        branch_buf = b;
        break :blk b;
    } else blk: {
        const short_sha = vcs.runOut(gpa, io, cwd, &.{ "rev-parse", "--short", "HEAD" }, null) catch null;
        if (short_sha) |s| {
            branch_buf = s;
            break :blk std.mem.trim(u8, s, " \t\r\n");
        }
        break :blk null;
    };

    if (branch) |b| {
        if (b.len > 0) {
            return std.fmt.allocPrint(gpa, "{s} ⌥ {s}", .{ repo_name, b });
        }
    }
    return gpa.dupe(u8, repo_name);
}

test "loadGitLabel returns repo and branch for git repository" {
    const label = try loadGitLabel(std.testing.allocator, std.testing.io, ".");
    defer std.testing.allocator.free(label);
    try std.testing.expect(label.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "⌥") != null);
}
