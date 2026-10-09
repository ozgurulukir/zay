//! The `database` builtin tool — enables the agent to query and inspect an
//! external database server or database service.
//!
//! Reaches the active server endpoint through `ToolContext.database_server_url`.

const std = @import("std");

const common = @import("common.zig");
const output_policy = @import("output_policy.zig");
const db = @import("../db.zig");
const tool_results = @import("../session/tool_results.zig");
const SessionBackend = @import("../session/backend.zig").SessionBackend;

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
                .description = "The database action: 'query', 'exec', 'schema', 'health', 'search_tool_result' to find literal text in a saved result, or 'read_tool_result' to inspect it by chunk and character offset.",
                .required = true,
            },
            .{
                .name = "sql",
                .kind = .string,
                .description = "SQL query or statement (required for 'query' and 'exec'). For large datasets, select needed columns and use LIMIT or keyset pagination.",
                .required = false,
            },
            .{
                .name = "table",
                .kind = .string,
                .description = "Optional table name filter for the 'schema' action.",
                .required = false,
            },
            .{
                .name = "result_id",
                .kind = .string,
                .description = "Result id from the large tool result's retrieval instructions; use with action='search_tool_result' or 'read_tool_result'.",
                .required = false,
            },
            .{
                .name = "needle",
                .kind = .string,
                .description = "Non-empty, case-sensitive literal to find in a saved result; required for 'search_tool_result'.",
                .required = false,
            },
            .{
                .name = "match_offset",
                .kind = .integer,
                .description = "Zero-based match to start from when continuing a search (default 0).",
                .required = false,
            },
            .{
                .name = "match_limit",
                .kind = .integer,
                .description = "Maximum match locations to return (default 5, hard maximum 8).",
                .required = false,
            },
            .{
                .name = "chunk",
                .kind = .integer,
                .description = "Zero-based chunk in the saved text (default 0); follow the returned continuation instruction.",
                .required = false,
            },
            .{
                .name = "offset",
                .kind = .integer,
                .description = "Character offset, not byte offset, within the selected chunk (default 0).",
                .required = false,
            },
            .{
                .name = "limit",
                .kind = .integer,
                .description = "Maximum characters to return (default 2048; hard maximum 4096). The active tool-output byte budget may lower this so the retrieval instructions remain visible.",
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
    search_tool_result,
    read_tool_result,

    pub fn fromString(str: []const u8) ?Action {
        if (std.ascii.eqlIgnoreCase(str, "query")) return .query;
        if (std.ascii.eqlIgnoreCase(str, "exec")) return .exec;
        if (std.ascii.eqlIgnoreCase(str, "schema")) return .schema;
        if (std.ascii.eqlIgnoreCase(str, "health")) return .health;
        if (std.ascii.eqlIgnoreCase(str, "search_tool_result")) return .search_tool_result;
        if (std.ascii.eqlIgnoreCase(str, "read_tool_result")) return .read_tool_result;
        return null;
    }
};

pub const Args = struct {
    action: Action,
    sql: ?[]u8 = null,
    table: ?[]u8 = null,
    result_id: ?[]u8 = null,
    needle: ?[]u8 = null,
    chunk: ?u64 = null,
    offset: ?u64 = null,
    limit: ?u64 = null,
    match_offset: ?u64 = null,
    match_limit: ?u64 = null,

    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        if (self.sql) |s| gpa.free(s);
        if (self.table) |t| gpa.free(t);
        if (self.result_id) |id| gpa.free(id);
        if (self.needle) |needle| gpa.free(needle);
        self.* = undefined;
    }
};

const JsonArgs = struct {
    action: ?[]const u8 = null,
    sql: ?[]const u8 = null,
    table: ?[]const u8 = null,
    result_id: ?[]const u8 = null,
    needle: ?[]const u8 = null,
    chunk: ?u64 = null,
    offset: ?u64 = null,
    limit: ?u64 = null,
    match_offset: ?u64 = null,
    match_limit: ?u64 = null,
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
    errdefer if (table) |t| gpa.free(t);

    var result_id: ?[]u8 = null;
    if (parsed.value.result_id) |id| {
        const trimmed = std.mem.trim(u8, id, " \t\r\n");
        if (trimmed.len > 0) result_id = try gpa.dupe(u8, trimmed);
    }
    errdefer if (result_id) |id| gpa.free(id);
    if ((action == .read_tool_result or action == .search_tool_result) and result_id == null) return error.InvalidArguments;

    var needle: ?[]u8 = null;
    if (parsed.value.needle) |value| {
        if (value.len > 0) needle = try gpa.dupe(u8, value);
    }
    errdefer if (needle) |value| gpa.free(value);
    if (action == .search_tool_result and needle == null) return error.InvalidArguments;

    return Args{
        .action = action,
        .sql = sql,
        .table = table,
        .result_id = result_id,
        .needle = needle,
        .chunk = parsed.value.chunk,
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
        .match_offset = parsed.value.match_offset,
        .match_limit = parsed.value.match_limit,
    };
}

fn isSelectQuery(sql: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, sql, " \t\r\n");
    const first = words.next() orelse return false;
    return std.ascii.eqlIgnoreCase(first, "select") or std.ascii.eqlIgnoreCase(first, "with");
}

const SqlToken = struct {
    const Kind = enum { word, quoted_identifier, symbol };

    kind: Kind,
    text: []const u8 = "",
    symbol: u8 = 0,
    depth: usize,
    start: usize,
    end: usize,

    fn isIdentifier(self: SqlToken) bool {
        return self.kind == .word or self.kind == .quoted_identifier;
    }

    fn isWord(self: SqlToken, expected: []const u8) bool {
        return self.kind == .word and std.ascii.eqlIgnoreCase(self.text, expected);
    }

    fn isSymbol(self: SqlToken, expected: u8) bool {
        return self.kind == .symbol and self.symbol == expected;
    }
};

const SqlScanner = struct {
    sql: []const u8,
    offset: usize = 0,
    depth: usize = 0,

    fn next(self: *SqlScanner) ?SqlToken {
        while (self.offset < self.sql.len) {
            const start = self.offset;
            const byte = self.sql[start];
            if (std.ascii.isWhitespace(byte)) {
                self.offset += 1;
                continue;
            }
            if (byte == '-' and start + 1 < self.sql.len and self.sql[start + 1] == '-') {
                self.offset += 2;
                while (self.offset < self.sql.len and self.sql[self.offset] != '\n' and self.sql[self.offset] != '\r') self.offset += 1;
                continue;
            }
            if (byte == '/' and start + 1 < self.sql.len and self.sql[start + 1] == '*') {
                self.offset += 2;
                var closed = false;
                while (self.offset + 1 < self.sql.len) : (self.offset += 1) {
                    if (self.sql[self.offset] == '*' and self.sql[self.offset + 1] == '/') {
                        self.offset += 2;
                        closed = true;
                        break;
                    }
                }
                if (!closed) self.offset = self.sql.len;
                continue;
            }
            if (byte == '\'') {
                self.skipQuoted('\'', self.hasPostgresEscapePrefix(start));
                continue;
            }
            if (byte == '"' or byte == '`' or byte == '[') {
                const closing = if (byte == '[') ']' else byte;
                self.offset += 1;
                const text_start = self.offset;
                while (self.offset < self.sql.len) {
                    if (self.sql[self.offset] == closing) {
                        const text_end = self.offset;
                        if (self.offset + 1 < self.sql.len and self.sql[self.offset + 1] == closing) {
                            self.offset += 2;
                            continue;
                        }
                        self.offset += 1;
                        return .{
                            .kind = .quoted_identifier,
                            .text = self.sql[text_start..text_end],
                            .depth = self.depth,
                            .start = start,
                            .end = self.offset,
                        };
                    }
                    self.offset += 1;
                }
                return .{
                    .kind = .quoted_identifier,
                    .text = self.sql[text_start..],
                    .depth = self.depth,
                    .start = start,
                    .end = self.offset,
                };
            }
            if (isSqlIdentifierStart(byte)) {
                self.offset += 1;
                while (self.offset < self.sql.len and isSqlIdentifierContinue(self.sql[self.offset])) self.offset += 1;
                return .{
                    .kind = .word,
                    .text = self.sql[start..self.offset],
                    .depth = self.depth,
                    .start = start,
                    .end = self.offset,
                };
            }
            if (byte == '(') {
                self.offset += 1;
                const depth = self.depth;
                self.depth += 1;
                return .{ .kind = .symbol, .symbol = byte, .depth = depth, .start = start, .end = self.offset };
            }
            if (byte == ')') {
                self.offset += 1;
                if (self.depth > 0) self.depth -= 1;
                return .{ .kind = .symbol, .symbol = byte, .depth = self.depth, .start = start, .end = self.offset };
            }
            self.offset += 1;
            return .{ .kind = .symbol, .symbol = byte, .depth = self.depth, .start = start, .end = self.offset };
        }
        return null;
    }

    fn hasPostgresEscapePrefix(self: *const SqlScanner, quote_start: usize) bool {
        if (quote_start > 0 and (self.sql[quote_start - 1] == 'e' or self.sql[quote_start - 1] == 'E')) {
            if (quote_start == 1 or !isSqlIdentifierContinue(self.sql[quote_start - 2])) return true;
        }
        return false;
    }

    fn skipQuoted(self: *SqlScanner, delimiter: u8, backslash_escapes: bool) void {
        self.offset += 1;
        while (self.offset < self.sql.len) {
            if (backslash_escapes and self.sql[self.offset] == '\\' and self.offset + 1 < self.sql.len) {
                self.offset += 2;
                continue;
            }
            if (self.sql[self.offset] == delimiter) {
                if (self.offset + 1 < self.sql.len and self.sql[self.offset + 1] == delimiter) {
                    self.offset += 2;
                    continue;
                }
                self.offset += 1;
                return;
            }
            self.offset += 1;
        }
    }
};

const CteName = struct {
    name: []const u8,
    visible_from: usize,
    scope_end: usize,
    scope_depth: usize,
};

const SqlScope = struct {
    const DdlTarget = enum { none, pending, index, trigger };

    in_from_clause: bool = false,
    expects_table: bool = false,
    ddl_target: DdlTarget = .none,
};

const TableReference = struct {
    name: []const u8,
    qualified: bool,
};

fn isSqlIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

fn isSqlIdentifierContinue(byte: u8) bool {
    return isSqlIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn matchingSqlParen(tokens: []const SqlToken, open_index: usize) ?usize {
    const depth = tokens[open_index].depth;
    var index = open_index + 1;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].isSymbol(')') and tokens[index].depth == depth) return index;
    }
    return null;
}

fn cteScopeEnd(tokens: []const SqlToken, with_index: usize, depth: usize, sql_len: usize) usize {
    var index = with_index + 1;
    while (index < tokens.len) : (index += 1) {
        const token = tokens[index];
        if (token.isSymbol(')') and token.depth < depth) return token.end;
        if (token.isSymbol(';') and token.depth == depth) return token.start;
    }
    return sql_len;
}

fn collectCteNames(
    gpa: std.mem.Allocator,
    tokens: []const SqlToken,
    with_index: usize,
    cte_names: *std.ArrayList(CteName),
    sql_len: usize,
) std.mem.Allocator.Error!void {
    const scope_depth = tokens[with_index].depth;
    const scope_end = cteScopeEnd(tokens, with_index, scope_depth, sql_len);
    var index = with_index + 1;
    const recursive = index < tokens.len and tokens[index].isWord("recursive");
    if (recursive) index += 1;

    while (index < tokens.len) {
        const name = tokens[index];
        if (!name.isIdentifier() or name.depth != scope_depth) return;
        index += 1;

        if (index < tokens.len and tokens[index].isSymbol('(') and tokens[index].depth == scope_depth) {
            index = (matchingSqlParen(tokens, index) orelse return) + 1;
        }
        if (index >= tokens.len or !tokens[index].isWord("as")) return;
        index += 1;

        if (index < tokens.len and tokens[index].isWord("not")) {
            index += 1;
            if (index >= tokens.len or !tokens[index].isWord("materialized")) return;
            index += 1;
        } else if (index < tokens.len and tokens[index].isWord("materialized")) {
            index += 1;
        }
        if (index >= tokens.len or !tokens[index].isSymbol('(') or tokens[index].depth != scope_depth) return;

        const body_open = index;
        const body_close = matchingSqlParen(tokens, body_open) orelse return;
        try cte_names.append(gpa, .{
            .name = name.text,
            .visible_from = if (recursive) tokens[body_open].start else tokens[body_close].end,
            .scope_end = scope_end,
            .scope_depth = scope_depth,
        });
        index = body_close + 1;
        if (index >= tokens.len or !tokens[index].isSymbol(',') or tokens[index].depth != scope_depth) return;
        index += 1;
    }
}

fn readTableReference(tokens: []const SqlToken, index: *usize) TableReference {
    var reference: TableReference = .{ .name = tokens[index.*].text, .qualified = false };
    while (index.* + 2 < tokens.len and
        tokens[index.* + 1].isSymbol('.') and
        tokens[index.* + 2].isIdentifier())
    {
        reference.name = tokens[index.* + 2].text;
        reference.qualified = true;
        index.* += 2;
    }
    return reference;
}

fn isCteReference(cte_names: []const CteName, reference: TableReference, token: SqlToken) bool {
    if (reference.qualified) return false;
    for (cte_names) |cte| {
        if (token.depth >= cte.scope_depth and token.start >= cte.visible_from and token.start < cte.scope_end and
            std.ascii.eqlIgnoreCase(reference.name, cte.name)) return true;
    }
    return false;
}

fn isTableModifier(token: SqlToken) bool {
    const modifiers = [_][]const u8{ "only", "lateral", "if", "not", "exists", "or", "rollback", "abort", "fail", "ignore", "replace" };
    for (modifiers) |modifier| {
        if (token.isWord(modifier)) return true;
    }
    return false;
}

fn containsProtectedResultTable(gpa: std.mem.Allocator, sql: []const u8) std.mem.Allocator.Error!bool {
    var tokens: std.ArrayList(SqlToken) = .empty;
    defer tokens.deinit(gpa);
    var scanner: SqlScanner = .{ .sql = sql };
    while (scanner.next()) |token| try tokens.append(gpa, token);

    var cte_names: std.ArrayList(CteName) = .empty;
    defer cte_names.deinit(gpa);
    for (tokens.items, 0..) |token, index| {
        if (token.isWord("with")) try collectCteNames(gpa, tokens.items, index, &cte_names, sql.len);
    }

    var scopes: std.ArrayList(SqlScope) = .empty;
    defer scopes.deinit(gpa);
    try scopes.append(gpa, .{});

    var index: usize = 0;
    while (index < tokens.items.len) {
        const token = tokens.items[index];
        var scope = &scopes.items[scopes.items.len - 1];
        if (token.isSymbol('(')) {
            if (scope.expects_table) scope.expects_table = false;
            try scopes.append(gpa, .{});
            index += 1;
            continue;
        }
        if (token.isSymbol(')')) {
            if (scopes.items.len > 1) scopes.items.len -= 1;
            index += 1;
            continue;
        }

        if (token.kind == .word) {
            if (token.isWord("where") or token.isWord("group") or token.isWord("order") or
                token.isWord("having") or token.isWord("limit") or token.isWord("window") or
                token.isWord("union") or token.isWord("except") or token.isWord("intersect") or
                token.isWord("returning") or token.isWord("qualify"))
            {
                scope.in_from_clause = false;
                scope.expects_table = false;
                scope.ddl_target = .none;
                index += 1;
                continue;
            }
            if (token.isWord("create")) {
                scope.ddl_target = .pending;
                index += 1;
                continue;
            } else if (scope.ddl_target == .pending and token.isWord("index")) {
                scope.ddl_target = .index;
                index += 1;
                continue;
            } else if (scope.ddl_target == .pending and token.isWord("trigger")) {
                scope.ddl_target = .trigger;
                index += 1;
                continue;
            } else if (token.isWord("from") or token.isWord("join")) {
                scope.in_from_clause = true;
                scope.expects_table = true;
                index += 1;
                continue;
            } else if (token.isWord("into") or token.isWord("update") or token.isWord("references")) {
                scope.expects_table = true;
                index += 1;
                continue;
            } else if (token.isWord("table")) {
                scope.expects_table = true;
                if (scope.ddl_target == .pending) scope.ddl_target = .none;
                index += 1;
                continue;
            } else if (token.isWord("on") and (scope.ddl_target == .index or scope.ddl_target == .trigger)) {
                scope.expects_table = true;
                scope.ddl_target = .none;
                index += 1;
                continue;
            }
        }

        if (token.isSymbol(',') and scope.in_from_clause) {
            scope.expects_table = true;
            index += 1;
            continue;
        }
        if (scope.expects_table) {
            if (isTableModifier(token)) {
                index += 1;
                continue;
            }
            if (token.isIdentifier()) {
                const reference = readTableReference(tokens.items, &index);
                const is_protected = std.ascii.eqlIgnoreCase(reference.name, "tool_results") or
                    std.ascii.eqlIgnoreCase(reference.name, "tool_result_chunks");
                if (is_protected and !isCteReference(cte_names.items, reference, token)) return true;
            }
            scope.expects_table = false;
        }
        index += 1;
    }
    return false;
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

fn renderSchemaResult(gpa: std.mem.Allocator, s: *const db.service.SchemaResult) common.Error![]u8 {
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

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const ServiceTarget = struct {
    client: db.Service,
    endpoint: []const u8,
};

const BackendTarget = union(enum) {
    service: ServiceTarget,
    backend: *SessionBackend,
};

const PreparedBackend = struct {
    backend: SessionBackend,
    conn: ?db.Connection = null,

    pub fn deinit(self: *PreparedBackend) void {
        if (self.conn) |*conn| conn.close();
        self.* = undefined;
    }
};

const PrepareResult = union(enum) {
    ready: PreparedBackend,
    failed: common.Output,
};

fn prepareBackend(gpa: std.mem.Allocator, backend: *const SessionBackend) common.Error!PrepareResult {
    var prepared = PreparedBackend{
        .backend = backend.*,
    };
    errdefer prepared.deinit();

    if (backend.local_path) |path| {
        if (!std.mem.eql(u8, path, ":memory:")) {
            var conn = db.Connection.open(path, .{ .create = false, .full_mutex = true }) catch |err| {
                return .{ .failed = try common.failFmt(gpa, 1, "Database connection failed: {s}\n", .{@errorName(err)}) };
            };
            conn.exec("pragma busy_timeout = 5000") catch |err| {
                conn.close();
                return .{ .failed = try common.failFmt(gpa, 1, "Database connection setup failed: {s}\n", .{@errorName(err)}) };
            };
            conn.exec("pragma foreign_keys = on") catch |err| {
                conn.close();
                return .{ .failed = try common.failFmt(gpa, 1, "Database connection setup failed: {s}\n", .{@errorName(err)}) };
            };
            prepared.conn = conn;
            prepared.backend.local = conn;
        }
    }
    return .{ .ready = prepared };
}

fn runHealth(gpa: std.mem.Allocator, io: std.Io, target: BackendTarget) common.Error!common.Output {
    switch (target) {
        .service => |s| {
            var h = s.client.health(io) catch |err| {
                return common.failFmt(gpa, 1, "Failed to connect to database service at {s}: {s}\n", .{ s.endpoint, @errorName(err) });
            };
            defer h.deinit();

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try writeFmt(&out, "[Database Service Health]\nEndpoint: {s}\nStatus: {s}\nBackend: {s}\nVersion: {s}\nAuth required: {}\n", .{
                s.endpoint,
                h.status,
                h.backend,
                h.version,
                h.auth_required,
            });

            const stdout = out.toOwnedSlice() catch return error.OutOfMemory;
            return common.ok(gpa, stdout);
        },
        .backend => |backend| {
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
                .d1_http => {
                    const client = backend.d1 orelse return common.failFmt(gpa, 1, "Cloudflare D1 client is unavailable.\n", .{});
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
    }
}

fn runQuery(gpa: std.mem.Allocator, io: std.Io, args: Args, target: BackendTarget) common.Error!common.Output {
    const sql = args.sql orelse {
        return common.failFmt(gpa, 2, "Invalid arguments: 'sql' query is required for 'query' action.\n", .{});
    };

    var res = switch (target) {
        .service => |s| s.client.query(io, sql, &.{}) catch |err| {
            return common.failFmt(gpa, 1, "Database query failed: {s}\n", .{@errorName(err)});
        },
        .backend => |backend| backend.query(io, sql, &.{}) catch |err| {
            return common.failFmt(gpa, 1, "Database query failed: {s}\n", .{@errorName(err)});
        },
    };
    defer res.deinit();

    const stdout = try renderQueryResult(gpa, &res);
    return common.ok(gpa, stdout);
}

fn renderToolResultSlice(
    gpa: std.mem.Allocator,
    result: *const tool_results.ResultSlice,
    result_id: []const u8,
    requested_limit: u64,
) common.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try writeFmt(&out, "[Saved tool result: {s}]\n", .{result_id});
    try writeFmt(&out, "Tool: {s}; original exit code: {d}; bytes: {d}; lines: {d}\n", .{ result.tool_name, result.exit_code, result.byte_length, result.line_count });
    try writeFmt(&out, "Chunk {d} of {d} (zero-based); character offset {d}; chunk size {d} characters.\n\n", .{ result.chunk_index, result.chunk_count, result.offset_characters, result.chunk_characters });
    try writeStr(&out, result.text);

    const remaining = if (result.offset_characters < result.chunk_characters)
        result.chunk_characters - result.offset_characters
    else
        0;
    const returned_characters = @min(requested_limit, remaining);
    const next_offset = result.offset_characters + returned_characters;
    if (next_offset < result.chunk_characters) {
        try writeFmt(&out, "\n\nContinue with database action=read_tool_result, result_id=\"{s}\", chunk={d}, offset={d}, limit={d}.", .{ result_id, result.chunk_index, next_offset, requested_limit });
    } else if (result.chunk_index + 1 < result.chunk_count) {
        try writeFmt(&out, "\n\nContinue with database action=read_tool_result, result_id=\"{s}\", chunk={d}, offset=0, limit={d}.", .{ result_id, result.chunk_index + 1, requested_limit });
    } else {
        try writeStr(&out, "\n\nEnd of saved result.");
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn renderToolResultSearch(
    gpa: std.mem.Allocator,
    result: *const tool_results.SearchResult,
    result_id: []const u8,
    requested_offset: u64,
) common.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try writeFmt(&out, "Saved result search: {s}\n", .{result_id});
    try writeFmt(&out, "Tool: {s}; original exit code: {d}; bytes: {d}. Search uses case-sensitive literal text.\n", .{ result.tool_name, result.exit_code, result.byte_length });
    if (result.matches.len == 0) {
        try writeStr(&out, "No further matches.\n");
    } else {
        for (result.matches, 0..) |hit, index| {
            try writeFmt(&out, "Match {d}: chunk={d}, character offset={d}. Read this location with database action=read_tool_result, result_id=\"{s}\", chunk={d}, offset={d}, limit={d}.\n", .{
                requested_offset + @as(u64, @intCast(index)),
                hit.chunk_index,
                hit.offset_characters,
                result_id,
                hit.chunk_index,
                hit.offset_characters,
                tool_results.default_read_chars,
            });
        }
    }
    if (result.has_more) {
        const next_offset = requested_offset + @as(u64, @intCast(result.matches.len));
        try writeFmt(&out, "More matches exist. Continue with database action=search_tool_result using the same needle and result_id=\"{s}\", match_offset={d}.\n", .{ result_id, next_offset });
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn runSearchToolResult(gpa: std.mem.Allocator, io: std.Io, args: Args, ctx: *const common.ToolContext) common.Error!common.Output {
    const backend = ctx.session_backend orelse return common.failFmt(gpa, 2, "Searching saved tool results requires an active session database.\n", .{});
    const session_id = ctx.session_id orelse return common.failFmt(gpa, 2, "Searching saved tool results requires an active session.\n", .{});
    const result_id = args.result_id orelse return common.failFmt(gpa, 2, "Invalid arguments: 'result_id' is required for 'search_tool_result'.\n", .{});
    const needle = args.needle orelse return common.failFmt(gpa, 2, "Invalid arguments: 'needle' is required for 'search_tool_result'.\n", .{});
    const match_offset = args.match_offset orelse 0;
    const match_limit = @min(args.match_limit orelse tool_results.default_search_matches, tool_results.max_search_matches);
    if (match_limit == 0) return common.failFmt(gpa, 2, "Invalid arguments: 'match_limit' must be at least 1.\n", .{});

    var prepared = switch (try prepareBackend(gpa, backend)) {
        .ready => |value| value,
        .failed => |output| return output,
    };
    defer prepared.deinit();

    var result = tool_results.search(gpa, io, &prepared.backend, session_id, result_id, needle, match_offset, match_limit, tool_results.nowMs(io)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSearchQuery => return common.failFmt(gpa, 2, "Search query must be non-empty, valid UTF-8, and at most 1024 bytes.\n", .{}),
        error.InvalidSearchLimit => return common.failFmt(gpa, 2, "Search match limit must be between 1 and {d}.\n", .{tool_results.max_search_matches}),
        else => return common.failFmt(gpa, 1, "Saved tool result could not be searched: {s}. Check the result id; expired results are removed automatically.\n", .{@errorName(err)}),
    };
    defer result.deinit(gpa);

    return common.ok(gpa, try renderToolResultSearch(gpa, &result, result_id, match_offset));
}

fn runReadToolResult(gpa: std.mem.Allocator, io: std.Io, args: Args, ctx: *const common.ToolContext) common.Error!common.Output {
    const backend = ctx.session_backend orelse return common.failFmt(gpa, 2, "Reading saved tool results requires an active session database.\n", .{});
    const session_id = ctx.session_id orelse return common.failFmt(gpa, 2, "Reading saved tool results requires an active session.\n", .{});
    const result_id = args.result_id orelse return common.failFmt(gpa, 2, "Invalid arguments: 'result_id' is required for 'read_tool_result'.\n", .{});
    const chunk = args.chunk orelse 0;
    const offset = args.offset orelse 0;
    const requested_limit = args.limit orelse tool_results.default_read_chars;
    const limit = output_policy.readWindowLimitChars(ctx.tool_output_cap_bytes, requested_limit);

    var prepared = switch (try prepareBackend(gpa, backend)) {
        .ready => |value| value,
        .failed => |output| return output,
    };
    defer prepared.deinit();

    var result = tool_results.read(gpa, io, &prepared.backend, session_id, result_id, chunk, offset, limit, tool_results.nowMs(io)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.failFmt(gpa, 1, "Saved tool result could not be read: {s}. Check the result id and chunk/offset/limit; expired results are removed automatically.\n", .{@errorName(err)}),
    };
    defer result.deinit(gpa);

    return common.ok(gpa, try renderToolResultSlice(gpa, &result, result_id, limit));
}

fn runExec(gpa: std.mem.Allocator, io: std.Io, args: Args, target: BackendTarget) common.Error!common.Output {
    const sql = args.sql orelse {
        return common.failFmt(gpa, 2, "Invalid arguments: 'sql' statement is required for 'exec' action.\n", .{});
    };

    switch (target) {
        .service => |s| {
            const res = s.client.exec(io, sql, &.{}) catch |err| {
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
        .backend => |backend| {
            backend.exec(io, sql, &.{}) catch |err| {
                return common.failFmt(gpa, 1, "Database execution failed: {s}\n", .{@errorName(err)});
            };
            const msg = try gpa.dupe(u8, "Statement executed successfully.\n");
            return common.ok(gpa, msg);
        },
    }
}

fn runSchema(gpa: std.mem.Allocator, io: std.Io, args: Args, target: BackendTarget) common.Error!common.Output {
    switch (target) {
        .service => |s| {
            var schema_res = s.client.schema(io, args.table) catch |err| {
                return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
            };
            defer schema_res.deinit();

            const stdout = try renderSchemaResult(gpa, &schema_res);
            return common.ok(gpa, stdout);
        },
        .backend => |backend| {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();

            switch (backend.kind) {
                .local_sqlite => {
                    var res = if (args.table) |tbl| blk: {
                        break :blk backend.query(io, "SELECT name, sql FROM sqlite_master WHERE type='table' AND name = ? ORDER BY name", &.{.{ .text = tbl }}) catch |err| {
                            return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
                        };
                    } else blk: {
                        break :blk backend.query(io, "SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", &.{}) catch |err| {
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
                        const text = try renderSchemaResult(gpa, &s);
                        defer gpa.free(text);
                        try writeStr(&out, text);
                    }
                },
                .turso_http => {
                    if (backend.turso) |*client| {
                        var s = client.schema(io, args.table) catch |err| {
                            return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
                        };
                        defer s.deinit();
                        const text = try renderSchemaResult(gpa, &s);
                        defer gpa.free(text);
                        try writeStr(&out, text);
                    }
                },
                .d1_http => {
                    if (backend.d1) |*client| {
                        var s = client.schema(io, args.table) catch |err| {
                            return common.failFmt(gpa, 1, "Database schema inspection failed: {s}\n", .{@errorName(err)});
                        };
                        defer s.deinit();
                        const text = try renderSchemaResult(gpa, &s);
                        defer gpa.free(text);
                        try writeStr(&out, text);
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
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    // _cwd is required by the common.Tool.run interface signature but unused
    // because database operations target remote service endpoints or session backends.
    _cwd: []const u8,
    arguments: []const u8,
    env: common.Env,
) common.Error!common.Output {
    _ = _cwd;
    _ = env.userdata;

    var args = parseArgs(gpa, arguments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return common.failFmt(
            gpa,
            2,
            "Invalid arguments: 'action' is required ('query', 'exec', 'schema', 'health', 'search_tool_result', or 'read_tool_result').\n",
            .{},
        ),
    };
    defer args.deinit(gpa);

    if (args.action == .read_tool_result) return runReadToolResult(gpa, io, args, env.ctx);
    if (args.action == .search_tool_result) return runSearchToolResult(gpa, io, args, env.ctx);

    if (args.action == .query) {
        if (args.sql) |sql| {
            if (!isSelectQuery(sql)) {
                return common.failFmt(gpa, 2, "Database query must be a SELECT statement.\n", .{});
            }
            if (try containsProtectedResultTable(gpa, sql)) {
                return common.failFmt(gpa, 2, "Large tool-result tables are private; use action='search_tool_result' or 'read_tool_result' with the result id from the tool output.\n", .{});
            }
        }
    } else if (args.action == .exec) {
        if (args.sql) |sql| {
            if (try containsProtectedResultTable(gpa, sql)) {
                return common.failFmt(gpa, 2, "Large tool-result tables are private and cannot be changed through SQL.\n", .{});
            }
        }
    }

    if (env.ctx.session_backend == null and env.ctx.database_server_url != null) {
        const endpoint = env.ctx.database_server_url.?;
        const client = db.Service.init(gpa, endpoint, env.ctx.database_auth_token);
        const target: BackendTarget = .{ .service = .{ .client = client, .endpoint = endpoint } };
        return switch (args.action) {
            .health => runHealth(gpa, io, target),
            .query => runQuery(gpa, io, args, target),
            .exec => runExec(gpa, io, args, target),
            .schema => runSchema(gpa, io, args, target),
            .search_tool_result => unreachable,
            .read_tool_result => unreachable,
        };
    } else if (env.ctx.session_backend) |backend| {
        var prepared = switch (try prepareBackend(gpa, backend)) {
            .ready => |value| value,
            .failed => |output| return output,
        };
        defer prepared.deinit();
        const target: BackendTarget = .{ .backend = &prepared.backend };
        return switch (args.action) {
            .health => runHealth(gpa, io, target),
            .query => runQuery(gpa, io, args, target),
            .exec => runExec(gpa, io, args, target),
            .schema => runSchema(gpa, io, args, target),
            .search_tool_result => unreachable,
            .read_tool_result => unreachable,
        };
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
        result_id: ?[]const u8 = null,
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
    else if (parsed.value.result_id) |id|
        try std.fmt.allocPrint(gpa, "db {s}: {s}", .{ action, id })
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

    var args3 = try parseArgs(gpa, "{\"action\":\"read_tool_result\",\"result_id\":\"call-1\",\"chunk\":2,\"offset\":12,\"limit\":256}");
    defer args3.deinit(gpa);
    try std.testing.expectEqual(Action.read_tool_result, args3.action);
    try std.testing.expectEqualStrings("call-1", args3.result_id.?);
    try std.testing.expectEqual(@as(u64, 2), args3.chunk.?);
    try std.testing.expectEqual(@as(u64, 12), args3.offset.?);
    try std.testing.expectEqual(@as(u64, 256), args3.limit.?);

    var args4 = try parseArgs(gpa, "{\"action\":\"search_tool_result\",\"result_id\":\"call-1\",\"needle\":\"permission denied\",\"match_offset\":3,\"match_limit\":2}");
    defer args4.deinit(gpa);
    try std.testing.expectEqual(Action.search_tool_result, args4.action);
    try std.testing.expectEqualStrings("permission denied", args4.needle.?);
    try std.testing.expectEqual(@as(u64, 3), args4.match_offset.?);
    try std.testing.expectEqual(@as(u64, 2), args4.match_limit.?);

    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{\"action\":\"unknown\"}"));
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{}"));
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{\"action\":\"read_tool_result\"}"));
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{\"action\":\"search_tool_result\",\"result_id\":\"call-1\"}"));
}

test "private result table guard matches table references" {
    const gpa = std.testing.allocator;
    const allowed = [_][]const u8{
        "SELECT 'tool_results', 'tool_result_chunks'",
        "SELECT 1 /* tool_results */",
        "SELECT 1 -- tool_result_chunks\n",
        "SELECT * FROM my_tool_results_archive",
        "SELECT tool_results FROM sessions",
        "WITH tool_results AS (SELECT 1) SELECT * FROM tool_results",
    };
    for (allowed) |sql| try std.testing.expect(!try containsProtectedResultTable(gpa, sql));

    const blocked = [_][]const u8{
        "SELECT * FROM Tool_Results",
        "SELECT * FROM main.tool_result_chunks",
        "SELECT * FROM sessions, tool_results",
        "SELECT * FROM (SELECT id FROM tool_results) AS saved",
        "WITH selected AS (SELECT * FROM tool_results) SELECT * FROM selected",
        "INSERT INTO tool_results(id) VALUES ('hidden')",
        "UPDATE tool_result_chunks SET content = ''",
        "CREATE INDEX tool_result_idx ON tool_results(id)",
    };
    for (blocked) |sql| try std.testing.expect(try containsProtectedResultTable(gpa, sql));
}

test "database tool reads large results through the current session scope" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const conn = try db.Connection.open(":memory:", .{});
    var backend = try SessionBackend.openLocal(gpa, conn, "test-host", ":memory:");
    defer backend.deinit();
    if (backend.local) |*local| try @import("../session/migration.zig").migrate(local, io);
    try backend.exec(io, "insert into sessions(id, cwd, project_key, created_at_ms, updated_at_ms) values (?, ?, ?, 1, 1)", &.{ .{ .text = "session-a" }, .{ .text = "/project/a" }, .{ .text = "project-a" } });

    const full_text = try gpa.alloc(u8, tool_results.inline_limit_bytes + 32);
    defer gpa.free(full_text);
    @memset(full_text, 'R');
    @memcpy(full_text[full_text.len - 4 ..], "TAIL");
    _ = try tool_results.store(gpa, io, &backend, "session-a", "call-large", "bash", 0, full_text);

    var ctx: common.ToolContext = .{ .session_backend = &backend, .session_id = "session-a" };
    const env: common.Env = .{ .ctx = &ctx, .userdata = undefined };
    var first = try runTool(gpa, io, ".", "{\"action\":\"read_tool_result\",\"result_id\":\"call-large\",\"limit\":8}", env);
    defer first.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), first.code);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "RRRRRRRR") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "offset=8") != null);

    var found = try runTool(gpa, io, ".", "{\"action\":\"search_tool_result\",\"result_id\":\"call-large\",\"needle\":\"TAIL\",\"match_limit\":1}", env);
    defer found.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), found.code);
    try std.testing.expect(std.mem.indexOf(u8, found.stdout, "chunk=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.stdout, "offset=8220") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.stdout, "action=read_tool_result") != null);

    var continued = try runTool(gpa, io, ".", "{\"action\":\"search_tool_result\",\"result_id\":\"call-large\",\"needle\":\"R\",\"match_limit\":1}", env);
    defer continued.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), continued.code);
    try std.testing.expect(std.mem.indexOf(u8, continued.stdout, "same needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, continued.stdout, "match_offset=1") != null);

    var denied = try runTool(gpa, io, ".", "{\"action\":\"query\",\"sql\":\"SELECT * FROM Tool_Results\"}", env);
    defer denied.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), denied.code);
    try std.testing.expect(std.mem.indexOf(u8, denied.stderr, "private") != null);
}

test "database tool operates on session_backend fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try db.Connection.open(":memory:", .{});
    defer conn.close();

    try conn.exec("create table sessions (id text, title text, cwd text, created_at_ms bigint, host_id text)");
    try conn.exec("insert into sessions values ('s1', 'first session', '/proj', 1000, 'host-a')");

    var backend: SessionBackend = .{
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
