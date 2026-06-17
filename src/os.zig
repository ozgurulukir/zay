//! The host operating system, resolved once at comptime. A single place for the
//! rest of the program to branch on (`is_windows`, `tag`) or label (`label`) the
//! OS, instead of reaching for `builtin.os.tag` — and re-deriving the human name —
//! in scattered spots.

const std = @import("std");
const builtin = @import("builtin");

/// Host OS tag. Prefer this over `builtin.os.tag` so every OS check shares one source.
pub const tag = builtin.os.tag;

/// Whether the host is Windows — Nova's most common OS branch.
pub const is_windows = tag == .windows;

/// Human-facing OS name, e.g. for the system prompt's `${OS}` placeholder.
pub const label: []const u8 = switch (tag) {
    .windows => "Windows",
    .linux => "Linux",
    .macos => "macOS",
    .freebsd => "FreeBSD",
    .netbsd => "NetBSD",
    .openbsd => "OpenBSD",
    else => @tagName(tag),
};
