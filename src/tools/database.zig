//! The `database` builtin tool — enables the agent to query and inspect an
//! external database server or database service.
//!
//! Reaches the active server endpoint through `ToolContext.database_server_url`.

const std = @import("std");

const common = @import("common.zig");
const db = @import("../db.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.db_tool);

pub const tool: common.Tool = .{
    .name = "database",
    .description = @embedFile("../prompts/tools/database.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "action",
                .kind = .string,
                .description = "The database action to perform: 'query', 'exec', 'schema', or 'health'.",
                .required = true,
            },
            .{
                .name = "sql",
                .kind = .string,
                .description = "SQL query or statement to execute (required for 'query' and 'exec').",
                .required = false,
            },
            .{
                .name = "table",
                .kind = .string,
                .description = "Optional table name filter for the 'schema' action.",
                .required = false,
            },
        },
    },
    .run = runTool,
    .display = display,
};

pub const Action = enum {
    query,
    exec,
    schema,
    health,

    pub fn fromString(str: []const u8) ?Action {
        if (std.ascii.eqlIgnoreCase(str, "query")) return .query;
        if (std.ascii.eqlIgnoreCase(str, "exec")) return .exec;
        if (std.ascii.eqlIgnoreCase(str, "schema")) return .schema;
        if (std.ascii.eqlIgnoreCase(str, "health")) return .health;
        return null;
    }
};

pub const Args = struct {
    action: Action,
    sql: ?[]u8 = null,
    table: ?[]u8 = null,

    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        if (self.sql) |s| gpa.free(s);
        if (self.table) |t| gpa.free(t);
        self.* = undefined;
    }
};

const JsonArgs = struct {
    action: ?[]const u8 = null,
    sql: ?[]const u8 = null,
    table: ?[]const u8 = null,
};

pub const ParseError = error{ InvalidArguments, OutOfMemory };

pub fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    defer parsed.deinit();

    const raw_action = parsed.value.action orelse return error.InvalidArguments;
    const action = Action.fromString(raw_action) orelse return error.InvalidArguments;

    var sql: ?[]u8 = null;
    if (parsed.value.sql) |s| {
        const trimmed = std.mem.trim(u8, s, " \t\r\n");
        if (trimmed.len > 0) sql = try gpa.dupe(u8, trimmed);
    }
    errdefer if (sql) |s| gpa.free(s);

    var table: ?[]u8 = null;
    if (parsed.value.table) |t| {
        const trimmed = std.mem.trim(u8, t, " \t\r\n");
        if (trimmed.len > 0) table = try gpa.dupe(u8, trimmed);
    }

    return Args{
        .action = action,
        .sql = sql,
        .table = table,
    };
}

fn writeFmt(out: *std.Io.Writer.Allocating, comptime fmt: []const u8, values: anytype) common.Error!void {
    out.writer.print(fmt, values) catch return error.OutOfMemory;
}

fn writeStr(out: *std.Io.Writer.Allocating, bytes: []const u8) common.Error!void {
    out.writer.writeAll(bytes) catch return error.OutOfMemory;
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    env: common.Env,
) common.Error!common.Output {
    _ = cwd;
    _ = env.userdata;

    const endpoint = env.ctx.database_server_url orelse {
        return common.failFmt(
            gpa,
            1,
            "External database service is not configured.\n" ++
                "To connect Zay to an external database, configure 'databaseServerUrl' in config.json " ++
                "or export ZAY_DATABASE_SERVER_URL='http://127.0.0.1:8766'.\n" ++
                "To start the included local DB server:\n" ++
                "  uv run -m tools.db_server.server --port 8766\n",
            .{},
        );
    };

    var args = parseArgs(gpa, arguments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return common.failFmt(
            gpa,
            2,
            "Invalid arguments: 'action' is required ('query', 'exec', 'schema', or 'health').\n",
            .{},
        ),
    };
    defer args.deinit(gpa);

    const client = db.Service.init(gpa, endpoint, env.ctx.database_auth_token);

    switch (args.action) {
        .health => {
            var h = client.health(io) catch |err| {
                return common.failFmt(gpa, 1, "Failed to connect to database service at {s}: {s}\n", .{ endpoint, @errorName(err) });
            };
            defer h.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try writeFmt(&out, "[Database Service Health]\nEndpoint: {s}\nStatus: {s}\nBackend: {s}\nVersion: {s}\nAuth required: {}\n", .{
                endpoint,
                h.status,
                h.backend,
                h.version,
                h.auth_required,
            });

            const stdout = out.toOwnedSlice() catch return error.OutOfMemory;
            return common.ok(gpa, stdout);
        },
        .query => {
            const sql = args.sql orelse {
                return common.failFmt(gpa, 2, "Invalid arguments: 'sql' query is required for 'query' action.\n", .{});
            };

            var res = client.query(io, sql, &.{}) catch |err| {
                return common.failFmt(gpa, 1, "Database query failed: {s}\n", .{@errorName(err)});
            };
            defer res.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();

            if (res.columns.len == 0) {
                try writeStr(&out, "Query returned empty result set (0 columns, 0 rows).\n");
            } else {
                // Render Markdown Table
                try writeStr(&out, "| ");
                for (res.columns) |col| {
                    try writeFmt(&out, "{s} | ", .{col});
                }
                try writeStr(&out, "\n| ");
                for (res.columns) |_| {
                    try writeStr(&out, "--- | ");
                }
                try writeStr(&out, "\n");

                for (res.rows) |row| {
                    try writeStr(&out, "| ");
                    for (row) |cell| {
                        switch (cell) {
                            .null => try writeStr(&out, "NULL | "),
                            .int => |v| try writeFmt(&out, "{d} | ", .{v}),
                            .float => |v| try writeFmt(&out, "{d:.4} | ", .{v}),
                            .text => |v| try writeFmt(&out, "{s} | ", .{v}),
                            .blob => |v| try writeFmt(&out, "[blob {d}B] | ", .{v.len}),
                        }
                    }
                    try writeStr(&out, "\n");
                }
                try writeFmt(&out, "({d} rows returned)\n", .{res.count});
            }

            const stdout = out.toOwnedSlice() catch return error.OutOfMemory;
            return common.ok(gpa, stdout);
        },
        .exec => {
            const sql = args.sql orelse {
                return common.failFmt(gpa, 2, "Invalid arguments: 'sql' statement is required for 'exec' action.\n", .{});
            };

            const res = client.exec(io, sql, &.{}) catch |err| {
                return common.failFmt(gpa, 1, "Database execute failed: {s}\n", .{@errorName(err)});
            };

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();

            try writeFmt(&out, "Statement executed successfully.\nChanges: {d}\n", .{res.changes});
            if (res.last_insert_rowid) |rowid| {
                try writeFmt(&out, "Last Insert RowID: {d}\n", .{rowid});
            }

            const stdout = out.toOwnedSlice() catch return error.OutOfMemory;
            return common.ok(gpa, stdout);
        },
        .schema => {
            var s = client.schema(io, args.table) catch |err| {
                return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
            };
            defer s.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();

            try writeStr(&out, "[Database Schema]\n");
            if (s.tables.len == 0) {
                try writeStr(&out, "No tables discovered.\n");
            } else {
                for (s.tables) |t| {
                    try writeFmt(&out, "Table: {s}\n", .{t.name});
                    for (t.columns) |c| {
                        try writeFmt(&out, "  - {s} ({s}{s}{s})\n", .{
                            c.name,
                            c.type_name,
                            if (c.primary_key) ", PRIMARY KEY" else "",
                            if (!c.nullable) ", NOT NULL" else "",
                        });
                    }
                    try writeStr(&out, "\n");
                }
            }

            const stdout = out.toOwnedSlice() catch return error.OutOfMemory;
            return common.ok(gpa, stdout);
        },
    }
}

pub fn display(
    gpa: std.mem.Allocator,
    arguments: []const u8,
    env: common.Env,
) std.mem.Allocator.Error!common.ToolDisplay {
    _ = env;
    const JsonArgsDisplay = struct {
        action: ?[]const u8 = null,
        sql: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgsDisplay, gpa, arguments, .{ .ignore_unknown_fields = false }) catch return .{
        .label = try gpa.dupe(u8, "database"),
        .expanded_label = try gpa.dupe(u8, "database"),
    };
    defer parsed.deinit();

    const action = parsed.value.action orelse "query";
    const label = try std.fmt.allocPrint(gpa, "database: {s}", .{action});
    errdefer gpa.free(label);

    const expanded_label = if (parsed.value.sql) |s|
        try std.fmt.allocPrint(gpa, "db {s}: {s}", .{ action, s })
    else
        try std.fmt.allocPrint(gpa, "db: {s}", .{action});

    return .{
        .label = label,
        .expanded_label = expanded_label,
    };
}

test "database tool parseArgs validates actions" {
    const gpa = std.testing.allocator;

    var args1 = try parseArgs(gpa, "{\"action\":\"health\"}");
    defer args1.deinit(gpa);
    try std.testing.expectEqual(Action.health, args1.action);

    var args2 = try parseArgs(gpa, "{\"action\":\"query\",\"sql\":\"SELECT 1\"}");
    defer args2.deinit(gpa);
    try std.testing.expectEqual(Action.query, args2.action);
    try std.testing.expectEqualStrings("SELECT 1", args2.sql.?);

    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{\"action\":\"unknown\"}"));
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{}"));
}
