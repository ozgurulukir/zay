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

fn isSelectQuery(sql: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, sql, " \t\r\n");
    const first = words.next() orelse return false;
    return std.ascii.eqlIgnoreCase(first, "select") or std.ascii.eqlIgnoreCase(first, "with");
}

fn writeFmt(out: *std.Io.Writer.Allocating, comptime fmt: []const u8, values: anytype) common.Error!void {
    out.writer.print(fmt, values) catch return error.OutOfMemory;
}

fn writeStr(out: *std.Io.Writer.Allocating, bytes: []const u8) common.Error!void {
    out.writer.writeAll(bytes) catch return error.OutOfMemory;
}

fn renderQueryResult(gpa: std.mem.Allocator, res: *const db.service.QueryResult) common.Error![]u8 {
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

    return out.toOwnedSlice() catch return error.OutOfMemory;
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
    if (args.action == .query) {
        if (args.sql) |sql| {
            if (!isSelectQuery(sql)) {
                return common.failFmt(gpa, 2, "Database query must be a SELECT statement.\n", .{});
            }
        }
    }

    if (env.ctx.session_backend == null and env.ctx.database_server_url != null) {
        const endpoint = env.ctx.database_server_url.?;
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

                const stdout = try renderQueryResult(gpa, &res);
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
    } else if (env.ctx.session_backend) |backend| {
        var tool_backend = backend.*;
        var tool_connection: ?db.Connection = null;
        defer if (tool_connection) |*conn| conn.close();
        if (backend.local_path) |path| {
            if (!std.mem.eql(u8, path, ":memory:")) {
                var conn = db.Connection.open(path, .{ .create = false, .full_mutex = true }) catch |err| {
                    return common.failFmt(gpa, 1, "Database connection failed: {s}\n", .{@errorName(err)});
                };
                conn.exec("pragma busy_timeout = 5000") catch |err| {
                    conn.close();
                    return common.failFmt(gpa, 1, "Database connection setup failed: {s}\n", .{@errorName(err)});
                };
                conn.exec("pragma foreign_keys = on") catch |err| {
                    conn.close();
                    return common.failFmt(gpa, 1, "Database connection setup failed: {s}\n", .{@errorName(err)});
                };
                tool_connection = conn;
                tool_backend.local = conn;
            }
        }
        switch (args.action) {
            .health => {
                var out: std.Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                switch (backend.kind) {
                    .local_sqlite => try writeStr(&out, "[Database Health]\nBackend: sqlite (local embedded session database)\nStatus: ok\nVersion: embedded\nAuth required: false\n"),
                    .remote_service => {
                        const client = backend.remote orelse return common.failFmt(gpa, 1, "Database service is unavailable.\n", .{});
                        var health = client.health(io) catch |err| {
                            return common.failFmt(gpa, 1, "Database health check failed: {s}\n", .{@errorName(err)});
                        };
                        defer health.deinit();
                        try writeFmt(&out, "[Database Health]\nBackend: {s}\nStatus: {s}\nVersion: {s}\nAuth required: {}\n", .{ health.backend, health.status, health.version, health.auth_required });
                    },
                    .turso_http => {
                        const client = backend.turso orelse return common.failFmt(gpa, 1, "Turso database client is unavailable.\n", .{});
                        var health = client.health(io) catch |err| {
                            return common.failFmt(gpa, 1, "Database health check failed: {s}\n", .{@errorName(err)});
                        };
                        defer health.deinit();
                        try writeFmt(&out, "[Database Health]\nBackend: {s}\nStatus: {s}\nVersion: {s}\nAuth required: {}\n", .{ health.backend, health.status, health.version, health.auth_required });
                    },
                    .postgres_native => try writeStr(&out, "[Database Health]\nBackend: postgres_native (native wire protocol)\nStatus: not implemented\n"),
                }
                const stdout = out.toOwnedSlice() catch return error.OutOfMemory;
                return common.ok(gpa, stdout);
            },
            .query => {
                const sql = args.sql orelse {
                    return common.failFmt(gpa, 2, "Invalid arguments: 'sql' query is required for 'query' action.\n", .{});
                };

                var res = tool_backend.query(io, sql, &.{}) catch |err| {
                    return common.failFmt(gpa, 1, "Database query failed: {s}\n", .{@errorName(err)});
                };
                defer res.deinit();

                const stdout = try renderQueryResult(gpa, &res);
                return common.ok(gpa, stdout);
            },
            .exec => {
                const sql = args.sql orelse {
                    return common.failFmt(gpa, 2, "Invalid arguments: 'sql' statement is required for 'exec' action.\n", .{});
                };

                tool_backend.exec(io, sql, &.{}) catch |err| {
                    return common.failFmt(gpa, 1, "Database execution failed: {s}\n", .{@errorName(err)});
                };
                const msg = try gpa.dupe(u8, "Statement executed successfully.\n");
                return common.ok(gpa, msg);
            },
            .schema => {
                var out: std.Io.Writer.Allocating = .init(gpa);
                defer out.deinit();

                switch (backend.kind) {
                    .local_sqlite => {
                        var res = if (args.table) |tbl| blk: {
                            break :blk tool_backend.query(io, "SELECT name, sql FROM sqlite_master WHERE type='table' AND name = ? ORDER BY name", &.{.{ .text = tbl }}) catch |err| {
                                return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
                            };
                        } else blk: {
                            break :blk tool_backend.query(io, "SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", &.{}) catch |err| {
                                return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
                            };
                        };
                        defer res.deinit();

                        try writeStr(&out, "[Database Schema]\n\n");
                        if (res.rows.len == 0) {
                            try writeStr(&out, "No tables found.\n");
                        } else {
                            for (res.rows) |row| {
                                if (row.len >= 2) {
                                    const name = switch (row[0]) {
                                        .text => |t| t,
                                        else => "unknown",
                                    };
                                    const table_sql = switch (row[1]) {
                                        .text => |t| t,
                                        else => "",
                                    };
                                    try writeFmt(&out, "Table: `{s}`\n```sql\n{s}\n```\n\n", .{ name, table_sql });
                                }
                            }
                        }
                    },
                    .remote_service => {
                        if (backend.remote) |*client| {
                            var s = client.schema(io, args.table) catch |err| {
                                return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
                            };
                            defer s.deinit();

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
                        }
                    },
                    .turso_http => {
                        if (backend.turso) |*client| {
                            var s = client.schema(io, args.table) catch |err| {
                                return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
                            };
                            defer s.deinit();

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
                        }
                    },
                    .postgres_native => {
                        return common.failFmt(gpa, 1, "Database schema inspection is not yet implemented for this backend.\n", .{});
                    },
                }

                const stdout = out.toOwnedSlice() catch return error.OutOfMemory;
                return common.ok(gpa, stdout);
            },
        }
    } else {
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

test "database tool operates on session_backend fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try db.Connection.open(":memory:", .{});
    defer conn.close();

    try conn.exec("create table sessions (id text, title text, cwd text, created_at_ms bigint, host_id text)");
    try conn.exec("insert into sessions values ('s1', 'first session', '/proj', 1000, 'host-a')");

    var backend: @import("../session/backend.zig").SessionBackend = .{
        .gpa = gpa,
        .kind = .local_sqlite,
        .local = conn,
        .host_id = "test-host",
    };

    var ctx: common.ToolContext = .{
        .session_backend = &backend,
    };
    const env: common.Env = .{ .ctx = &ctx, .userdata = undefined };

    // 1. health
    var health_out = try runTool(gpa, io, ".", "{\"action\":\"health\"}", env);
    defer health_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), health_out.code);
    try std.testing.expect(std.mem.indexOf(u8, health_out.stdout, "sqlite (local embedded session database)") != null);

    // 2. query
    var query_out = try runTool(gpa, io, ".", "{\"action\":\"query\",\"sql\":\"SELECT id, title, host_id FROM sessions\"}", env);
    defer query_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), query_out.code);
    try std.testing.expect(std.mem.indexOf(u8, query_out.stdout, "first session") != null);
    try std.testing.expect(std.mem.indexOf(u8, query_out.stdout, "host-a") != null);

    // 3. schema
    var schema_out = try runTool(gpa, io, ".", "{\"action\":\"schema\"}", env);
    defer schema_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), schema_out.code);
    try std.testing.expect(std.mem.indexOf(u8, schema_out.stdout, "Table: `sessions`") != null);

    // 4. exec
    var exec_out = try runTool(gpa, io, ".", "{\"action\":\"exec\",\"sql\":\"insert into sessions values ('s2', 'second session', '/proj', 2000, 'host-b')\"}", env);
    defer exec_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), exec_out.code);

    // Verify row inserted
    var verify_out = try runTool(gpa, io, ".", "{\"action\":\"query\",\"sql\":\"SELECT count(*) FROM sessions\"}", env);
    defer verify_out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, verify_out.stdout, "2") != null);
}
