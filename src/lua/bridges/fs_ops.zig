//! Filesystem pure operations and utilities for Lua filesystem bridge.
//! Extracted from `fs.zig` to keep file sizes below the 500-line ceiling.

const std = @import("std");

/// Maximum size for read_file operations (1MB).
pub const max_read_size: usize = 1024 * 1024;

/// Language map for file extension → language name.
pub const lang_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lua", "lua" },
    .{ "py", "python" },
    .{ "js", "javascript" },
    .{ "ts", "typescript" },
    .{ "zig", "zig" },
    .{ "c", "c" },
    .{ "cpp", "cpp" },
    .{ "h", "c" },
    .{ "rs", "rust" },
    .{ "go", "go" },
    .{ "java", "java" },
    .{ "rb", "ruby" },
    .{ "php", "php" },
    .{ "sh", "bash" },
    .{ "bash", "bash" },
    .{ "zsh", "bash" },
    .{ "json", "json" },
    .{ "xml", "xml" },
    .{ "yaml", "yaml" },
    .{ "yml", "yaml" },
    .{ "toml", "toml" },
    .{ "md", "markdown" },
    .{ "txt", "text" },
    .{ "log", "log" },
    .{ "conf", "config" },
    .{ "cfg", "config" },
    .{ "ini", "ini" },
});

/// MIME type map.
pub const mime_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lua", "text/x-lua" },
    .{ "py", "text/x-python" },
    .{ "js", "application/javascript" },
    .{ "json", "application/json" },
    .{ "html", "text/html" },
    .{ "css", "text/css" },
    .{ "xml", "application/xml" },
    .{ "md", "text/markdown" },
    .{ "txt", "text/plain" },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "svg", "image/svg+xml" },
});

/// Core of `zay.edit_file`: stat the file, refuse anything over the read cap,
/// then splice the replacement and write atomically.
pub const EditFileError = error{ FileTooLarge, OldStringNotFound, OutOfMemory, WriteFailed };

pub fn editFileSplice(io: std.Io, clean_path: []const u8, old_string: []const u8, new_string: []const u8) EditFileError!void {
    const full_size = statFileSize(io, clean_path) catch return error.WriteFailed;
    if (full_size > max_read_size) return error.FileTooLarge;

    const content = readFileBytes(io, clean_path, max_read_size) catch return error.WriteFailed;
    defer std.heap.page_allocator.free(content);

    const index = std.mem.indexOf(u8, content, old_string) orelse return error.OldStringNotFound;

    const new_content = std.mem.concat(std.heap.page_allocator, u8, &.{
        content[0..index],
        new_string,
        content[index + old_string.len ..],
    }) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(new_content);

    writeFileAtomic(io, clean_path, new_content) catch return error.WriteFailed;
}

/// Read file bytes with size limit.
pub fn readFileBytes(io: std.Io, path: []const u8, max_size: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const read_size = @min(@as(usize, @intCast(stat.size)), max_size);
    const bytes = try std.heap.page_allocator.alloc(u8, read_size);
    errdefer std.heap.page_allocator.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

/// Stat a file and return its on-disk size in bytes.
pub fn statFileSize(io: std.Io, path: []const u8) !u64 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return stat.size;
}

/// Atomic file write: write to temp, then rename.
pub fn writeFileAtomic(io: std.Io, path: []const u8, content: []const u8) !void {
    var random: [4]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{s}.tmp", .{ path, hex[0..] });
    defer std.heap.page_allocator.free(tmp_path);

    var file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch |err| {
        return err;
    };

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(content) catch |err| {
        file.close(io);
        deleteFileBestEffort(io, tmp_path);
        return err;
    };
    writer.interface.flush() catch |err| {
        file.close(io);
        deleteFileBestEffort(io, tmp_path);
        return err;
    };
    file.close(io);

    std.Io.Dir.renameAbsolute(tmp_path, path, io) catch |err| {
        deleteFileBestEffort(io, tmp_path);
        return err;
    };
}

pub fn deleteFileBestEffort(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

/// Apply line range to content.
pub fn applyLineRange(content: []const u8, start_line: ?u32, end_line: ?u32) []const u8 {
    const start = start_line orelse 1;
    if (start <= 1 and end_line == null) return content;

    var line_start: usize = 0;
    var current_line: u32 = 1;

    while (current_line < start) {
        if (std.mem.indexOfScalarPos(u8, content, line_start, '\n')) |pos| {
            line_start = pos + 1;
            current_line += 1;
        } else {
            return content[0..0];
        }
    }

    if (end_line == null) return content[line_start..];

    const end = end_line.?;
    var line_end = line_start;
    while (current_line <= end) {
        if (std.mem.indexOfScalarPos(u8, content, line_end, '\n')) |pos| {
            line_end = pos + 1;
            current_line += 1;
        } else {
            line_end = content.len;
            break;
        }
    }

    if (line_end > line_start and content[line_end - 1] == '\n') {
        return content[line_start .. line_end - 1];
    }
    return content[line_start..line_end];
}

/// Count lines in text.
pub fn countLines(text: []const u8) u32 {
    var count: u32 = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

/// Detect programming language from file extension.
pub fn detectLanguage(path: []const u8, content: []const u8) []const u8 {
    const ext = getExtension(path);
    if (lang_map.get(ext)) |lang| return lang;
    if (content.len > 0 and content[0] == '#' and content.len > 1 and content[1] == '!') return "script";
    return "text";
}

/// Get MIME type from file extension.
pub fn getMimeType(path: []const u8) []const u8 {
    const ext = getExtension(path);
    return mime_map.get(ext) orelse "application/octet-stream";
}

/// Get file extension (lowercase).
pub fn getExtension(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    return path[dot + 1 ..];
}
