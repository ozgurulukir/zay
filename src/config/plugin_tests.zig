const std = @import("std");
const PluginConfig = @import("plugin.zig").PluginConfig;

test "deinit_freesNameAndSettings_whenSettingsIsNonEmpty" {
    const gpa = std.testing.allocator;

    var config: PluginConfig = .{
        .name = try gpa.dupe(u8, "syntax_highlighter"),
        .enabled = true,
        .settings = try gpa.dupe(u8, "{\"theme\":\"dark\"}"),
    };

    config.deinit(gpa);
}

test "deinit_freesOnlyName_whenSettingsIsEmpty" {
    const gpa = std.testing.allocator;

    var config: PluginConfig = .{
        .name = try gpa.dupe(u8, "formatter"),
        .enabled = true,
        .settings = "",
    };

    config.deinit(gpa);
}

test "clone_duplicatesFieldsCorrectly_whenPopulated" {
    const gpa = std.testing.allocator;

    var original: PluginConfig = .{
        .name = try gpa.dupe(u8, "linter"),
        .enabled = false,
        .settings = try gpa.dupe(u8, "{\"level\":\"warn\"}"),
    };
    defer original.deinit(gpa);

    var cloned = try original.clone(gpa);
    defer cloned.deinit(gpa);

    try std.testing.expectEqualStrings(original.name, cloned.name);
    try std.testing.expectEqual(original.enabled, cloned.enabled);
    try std.testing.expectEqualStrings(original.settings, cloned.settings);
    try std.testing.expect(original.name.ptr != cloned.name.ptr);
    try std.testing.expect(original.settings.ptr != cloned.settings.ptr);
}

test "clone_handlesEmptySettings_withoutAllocation" {
    const gpa = std.testing.allocator;

    var original: PluginConfig = .{
        .name = try gpa.dupe(u8, "git_status"),
        .enabled = true,
        .settings = "",
    };
    defer original.deinit(gpa);

    var cloned = try original.clone(gpa);
    defer cloned.deinit(gpa);

    try std.testing.expectEqualStrings("git_status", cloned.name);
    try std.testing.expect(cloned.enabled);
    try std.testing.expectEqualStrings("", cloned.settings);
    try std.testing.expect(original.name.ptr != cloned.name.ptr);
}

test "clone_freesName_whenSettingsAllocationFails" {
    const gpa = std.testing.allocator;

    var original: PluginConfig = .{
        .name = try gpa.dupe(u8, "debugger"),
        .enabled = true,
        .settings = try gpa.dupe(u8, "{\"port\":9222}"),
    };
    defer original.deinit(gpa);

    // fail_index = 1 allows the first allocation (for out.name) to succeed,
    // but forces the second allocation (for out.settings) to return OutOfMemory.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });

    const result = original.clone(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
}
