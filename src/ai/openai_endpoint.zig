const std = @import("std");

pub fn v1Root(gpa: std.mem.Allocator, base_url: []const u8) ![]u8 {
    if (base_url.len == 0) return error.EmptyBaseUrl;
    const root = std.mem.trimEnd(u8, base_url, "/");
    if (hasVersionSegment(root)) return try gpa.dupe(u8, root);
    return try std.fmt.allocPrint(gpa, "{s}/v1", .{root});
}

/// True when the URL's path already carries a version segment (`v1`,
/// `v1beta`, `v2`, …). Such bases are complete OpenAI-compat roots:
/// appending `/v1` would fabricate e.g. Google's
/// `…/v1beta/openai/v1/models`, which the models-list route 404s
/// (chat tolerates the doubled path, the probe does not).
fn hasVersionSegment(url: []const u8) bool {
    const authority_start = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse return false;
    var it = std.mem.splitScalar(u8, url[path_start..], '/');
    while (it.next()) |seg| {
        if (seg.len >= 2 and seg[0] == 'v' and std.ascii.isDigit(seg[1])) return true;
    }
    return false;
}

test "v1 root accepts already-versioned base urls" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "http://localhost:11434/v1");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", root);
}

test "v1 root appends version to provider roots" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "http://localhost:11434");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", root);
}

test "v1 root rejects an empty base url with EmptyBaseUrl" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.EmptyBaseUrl, v1Root(gpa, ""));
}

test "v1 root trims trailing slashes before checking for /v1" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "http://localhost:11434/v1/");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", root);
}

test "v1 root keeps a versioned compat root verbatim (google v1beta/openai)" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "https://generativelanguage.googleapis.com/v1beta/openai");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/openai", root);
}

test "v1 root keeps a bare v1beta root verbatim" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "https://example.com/v1beta");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("https://example.com/v1beta", root);
}

test "v1 root does not mistake non-version segments for versions" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "https://example.com/vendor/openai");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("https://example.com/vendor/openai/v1", root);
}
