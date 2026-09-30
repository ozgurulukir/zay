//! Core types for the session layer.
//!
//! Pure type definitions with no references to Session, SessionManager,
//! SessionWriter, or the database — the leaves of the dependency graph.

const std = @import("std");
const bounded_queue = @import("bounded_queue");
const db = @import("../db.zig");

const assert = std.debug.assert;

/// Length of an entry id in bytes.
pub const entry_id_len: u32 = 8;
/// Length of a session id in bytes.
pub const session_id_len: u32 = 32;
/// Upper bound on entries in a single branch path. Far above any real
/// session; exists so projection loops are bounded (tigerstyle).
pub const path_entries_max: u32 = 1 << 20;

pub const EntryId = struct {
    bytes: [entry_id_len]u8,

    pub fn fromSlice(value: []const u8) Error!EntryId {
        if (value.len != entry_id_len) return error.BadEntryId;
        var bytes: [entry_id_len]u8 = undefined;
        @memcpy(bytes[0..], value);
        const result = EntryId{ .bytes = bytes };
        // Two-way assertion: round-trip preserves the value.
        assert(std.mem.eql(u8, value, result.slice()));
        return result;
    }

    pub fn slice(self: *const EntryId) []const u8 {
        return self.bytes[0..];
    }
};

pub const SessionId = struct {
    bytes: [session_id_len]u8,

    pub fn fromSlice(value: []const u8) Error!SessionId {
        if (value.len != session_id_len) return error.BadSessionId;
        var bytes: [session_id_len]u8 = undefined;
        @memcpy(bytes[0..], value);
        const result = SessionId{ .bytes = bytes };
        // Two-way assertion: round-trip preserves the value.
        assert(std.mem.eql(u8, value, result.slice()));
        return result;
    }

    pub fn slice(self: *const SessionId) []const u8 {
        return self.bytes[0..];
    }
};

pub const Error = anyerror;

/// A single entry queued for the background writer thread.
pub const QueuedEntry = struct {
    kind: []const u8,
    role: ?[]u8,
    payload_json: []u8,
    title_candidate: ?[]u8 = null,

    pub fn deinit(self: *QueuedEntry, gpa: std.mem.Allocator) void {
        if (self.role) |role| gpa.free(role);
        gpa.free(self.payload_json);
        if (self.title_candidate) |title| gpa.free(title);
        self.* = undefined;
    }
};

/// Fixed-capacity queue of entries pending write.
pub const EntryQueue = bounded_queue.BoundedQueue(QueuedEntry);

pub const CreateOptions = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    host_id: ?[]const u8 = null,
    /// Explicit logical-project association for the new session. When null,
    /// creation reuses the most recent current-host binding for the cwd, or
    /// mints a fresh key when none exists.
    project_key: ?[]const u8 = null,
};

/// Opaque logical-project identity (INV-PROJECT-ID). A project key names a
/// project across hosts; it is NEVER interpreted as a filesystem path (the
/// lane manifest's `repo_key` keeps its local-path semantics). Values are
/// minted by the session layer (`pk-` + hex) and validated at the API
/// boundary so a stray path or free-form string cannot masquerade as a key.
pub const project_key_prefix = "pk-";
pub const project_key_len = project_key_prefix.len + 32;

pub const ProjectKey = struct {
    value: []const u8,

    /// Validate a borrowed key. Accepts exactly the minted shape; anything
    /// else (paths, whitespace, uppercase, wrong length) is rejected.
    pub fn validate(value: []const u8) Error!ProjectKey {
        if (value.len != project_key_len) return error.BadProjectKey;
        if (!std.mem.startsWith(u8, value, project_key_prefix)) return error.BadProjectKey;
        for (value[project_key_prefix.len..]) |c| {
            const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
            if (!ok) return error.BadProjectKey;
        }
        return .{ .value = value };
    }
};

/// One host-local mapping of a logical project onto a real directory. Rows
/// live in `project_locations` and are scoped by `host_id` — a foreign host's
/// cwd is never executed as a runtime root (INV-RESUME-CWD).
pub const ProjectLocation = struct {
    project_key: []u8,
    host_id: []u8,
    /// Native/display path as stored on this host.
    cwd: []u8,
    /// Normalized lookup spelling (paths.cwdKey semantics).
    cwd_key: []u8,
    updated_at_ms: i64,

    pub fn deinit(self: *ProjectLocation, gpa: std.mem.Allocator) void {
        gpa.free(self.project_key);
        gpa.free(self.host_id);
        gpa.free(self.cwd);
        gpa.free(self.cwd_key);
        self.* = undefined;
    }
};

/// A verified current-host project root — the only shape `switchToSession`
/// may be called with (INV-RESUME-CWD).
pub const ProjectRoot = struct {
    cwd: []u8,
};

/// The payload of a `.needs_project_root` resolution: the selected session
/// could not be bound to a local directory on this host. All strings are
/// owned; `project_key` is null for legacy (unbound) rows and is minted on
/// the user's successful bind.
pub const PendingProjectBinding = struct {
    session_id: []u8,
    project_key: ?[]u8,
    origin_cwd: []u8,
    origin_host_id: ?[]u8,

    pub fn deinit(self: *PendingProjectBinding, gpa: std.mem.Allocator) void {
        gpa.free(self.session_id);
        if (self.project_key) |key| gpa.free(key);
        gpa.free(self.origin_cwd);
        if (self.origin_host_id) |host| gpa.free(host);
        self.* = undefined;
    }
};

/// Resume resolution: either a verified local root, or an explicit request
/// for the user to bind one inside the TUI (never a silent fallback to a
/// foreign path).
pub const ResumeResolution = union(enum) {
    ready: ProjectRoot,
    needs_project_root: PendingProjectBinding,

    pub fn deinit(self: *ResumeResolution, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |root| gpa.free(root.cwd),
            .needs_project_root => |*pending| pending.deinit(gpa),
        }
        self.* = undefined;
    }
};

pub const SessionSummary = struct {
    id: []u8,
    title: ?[]u8,
    cwd: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    /// Last entry id in the branch's leaf chain. Branded as EntryId
    /// (fixed-size [entry_id_len]u8) instead of a loose []u8 so the
    /// type system enforces the length invariant the DB layer relies
    /// on. null when the branch has no entries yet.
    leaf_entry_id: ?EntryId,
    /// Model provider and ID used in this session. null for sessions
    /// created before schema v4 or when model info is not available.
    model_provider: ?[]u8,
    model_id: ?[]u8,
    /// Session-scoped reasoning effort label ("default", "high", …).
    /// null for sessions created before schema v5 or when the user never
    /// overrode the effort — resume then falls back to config/default.
    reasoning_effort: ?[]u8,
    /// Machine or host identifier where the session originated.
    host_id: ?[]u8 = null,
    /// Logical project this session belongs to (schema v9). null for legacy
    /// rows — an unbound row stays representable until a verified lazy bind.
    project_key: ?[]u8 = null,
    /// The current host's mapped directory for this session's project, when
    /// one exists (filled by `list`). null for unbound or foreign-only
    /// sessions — the resume picker shows "project root required" for those.
    local_cwd: ?[]u8 = null,

    pub fn deinit(self: *SessionSummary, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        if (self.title) |title| gpa.free(title);
        gpa.free(self.cwd);
        if (self.model_provider) |mp| gpa.free(mp);
        if (self.model_id) |mid| gpa.free(mid);
        if (self.reasoning_effort) |effort| gpa.free(effort);
        if (self.host_id) |hid| gpa.free(hid);
        if (self.project_key) |key| gpa.free(key);
        if (self.local_cwd) |cwd| gpa.free(cwd);
        self.* = undefined;
    }
};

/// A single entry in the session tree, loaded from the database.
pub const EntryRecord = struct {
    id: [entry_id_len]u8,
    parent_id: ?[entry_id_len]u8,
    kind: []u8,
    role: ?[]u8,
    payload_json: []u8,
    created_at_ms: i64,
    /// The git snapshot commit bound to this entry (null if none). Drives the
    /// timeline ✦ marker and code-state restore.
    snapshot: ?[]u8 = null,

    pub fn deinit(self: *EntryRecord, gpa: std.mem.Allocator) void {
        // Assert pre-free invariant: self-owned fields are non-null.
        assert(self.kind.len > 0);
        gpa.free(self.kind);
        if (self.role) |role| gpa.free(role);
        assert(self.payload_json.len > 0);
        gpa.free(self.payload_json);
        if (self.snapshot) |s| gpa.free(s);
        // Poison after free to catch use-after-free.
        self.* = undefined;
    }
};

/// Fixed-size reference to a user message entry on the active path — the
/// `/undo` walk's result. Carries only the two ids the caller needs, so the
/// lookup stays allocation-free (no payload ownership).
pub const UserEntryRef = struct {
    id: EntryId,
    parent_id: ?EntryId,
};

/// A compaction boundary found while walking a branch.
pub const CompactionBoundary = struct {
    /// Index in the path array of the compaction entry itself.
    summary_index: u32,
    /// Index of the first entry that should be emitted (the "first kept" id).
    first_kept_index: u32,
};

/// Result of computing where to cut the branch for compaction.
pub const CompactionCut = struct {
    first_kept_id: EntryId,
    prefix_text: []u8,
};

pub const EntryKind = enum {
    user,
    assistant,
    assistant_empty,
    tool,
    branch_summary,
    session_info,
    checkpoint,
    other,
};

pub const EntrySummary = union(enum) {
    user: struct { text: []u8 },
    assistant: struct { text: []u8 },
    assistant_empty: struct { text: []u8 },
    tool: struct { text: []u8, failed: bool },
    branch_summary: struct { text: []u8 },
    session_info: struct { text: []u8 },
    checkpoint: struct { text: []u8 },
    other: struct { text: []u8 },

    pub fn deinit(self: *EntrySummary, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |info| gpa.free(info.text),
        }
        self.* = undefined;
    }

    pub fn text(self: EntrySummary) []u8 {
        return switch (self) {
            inline else => |info| info.text,
        };
    }

    pub fn kind(self: EntrySummary) EntryKind {
        return switch (self) {
            .user => .user,
            .assistant => .assistant,
            .assistant_empty => .assistant_empty,
            .tool => .tool,
            .branch_summary => .branch_summary,
            .session_info => .session_info,
            .checkpoint => .checkpoint,
            .other => .other,
        };
    }

    pub fn toolFailed(self: EntrySummary) bool {
        return switch (self) {
            .tool => |t| t.failed,
            else => false,
        };
    }
};
