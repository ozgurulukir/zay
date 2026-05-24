const std = @import("std");
const logger = @import("logger");

const auth_port: u16 = 1455;
const auth_host = "127.0.0.1";
const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const authorize_url = "https://auth.openai.com/oauth/authorize";
const token_url = "https://auth.openai.com/oauth/token";
const redirect_uri = "http://localhost:1455/auth/callback";
const scope = "openid profile email offline_access";
const jwt_claim_path = "https://api.openai.com/auth";

pub const Model = struct {
    id: []u8,
    label: []u8,

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.label);
        self.* = undefined;
    }
};

const StaticModel = struct { id: []const u8, label: []const u8 };

const static_models = [_]StaticModel{
    .{ .id = "gpt-5.2", .label = "OpenAI Codex · GPT-5.2" },
    .{ .id = "gpt-5.3-codex", .label = "OpenAI Codex · GPT-5.3 Codex" },
    .{ .id = "gpt-5.3-codex-spark", .label = "OpenAI Codex · GPT-5.3 Codex Spark" },
    .{ .id = "gpt-5.4", .label = "OpenAI Codex · GPT-5.4" },
    .{ .id = "gpt-5.4-mini", .label = "OpenAI Codex · GPT-5.4 mini" },
    .{ .id = "gpt-5.5", .label = "OpenAI Codex · GPT-5.5" },
};

pub fn loadStaticModels(gpa: std.mem.Allocator) ![]Model {
    const out = try gpa.alloc(Model, static_models.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*model| model.deinit(gpa);
        gpa.free(out);
    }
    for (static_models) |model| {
        out[initialized] = .{
            .id = try gpa.dupe(u8, model.id),
            .label = try gpa.dupe(u8, model.label),
        };
        initialized += 1;
    }
    return out;
}

pub const Credentials = struct {
    access: []u8,
    refresh: []u8,
    account_id: []u8,
    expires: i64,

    pub fn deinit(self: *Credentials, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
        gpa.free(self.account_id);
        self.* = undefined;
    }
};

const AuthorizationFlow = struct {
    verifier: []u8,
    state: []u8,
    url: []u8,

    fn deinit(self: *AuthorizationFlow, gpa: std.mem.Allocator) void {
        gpa.free(self.verifier);
        gpa.free(self.state);
        gpa.free(self.url);
        self.* = undefined;
    }
};

pub fn login(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !Credentials {
    var flow = try createAuthorizationFlow(gpa, io);
    defer flow.deinit(gpa);
    try openBrowser(gpa, io, flow.url);
    const code = try waitForAuthorizationCode(gpa, io, flow.state);
    defer gpa.free(code);
    var credentials = try exchangeAuthorizationCode(gpa, io, code, flow.verifier);
    errdefer credentials.deinit(gpa);
    try save(gpa, io, home_dir, credentials);
    return credentials;
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !?Credentials {
    const path = try authPath(gpa, home_dir);
    defer gpa.free(path);
    const bytes = std.Io.Dir.readFileAllocOptions(.cwd(), io, path, gpa, .limited(32 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    return try parseAuthFile(gpa, bytes);
}

pub fn refresh(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, refresh_token: []const u8) !Credentials {
    var credentials = try refreshAccessToken(gpa, io, refresh_token);
    errdefer credentials.deinit(gpa);
    try save(gpa, io, home_dir, credentials);
    return credentials;
}

pub fn signOut(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !void {
    const path = try authPath(gpa, home_dir);
    defer gpa.free(path);
    std.Io.Dir.deleteFile(.cwd(), io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn createAuthorizationFlow(gpa: std.mem.Allocator, io: std.Io) !AuthorizationFlow {
    var random: [32]u8 = undefined;
    io.random(&random);
    const verifier = try base64Url(gpa, &random);
    errdefer gpa.free(verifier);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = try base64Url(gpa, &digest);
    defer gpa.free(challenge);

    var state_bytes: [16]u8 = undefined;
    io.random(&state_bytes);
    const state = try hexLower(gpa, &state_bytes);
    errdefer gpa.free(state);

    var url: std.Io.Writer.Allocating = .init(gpa);
    errdefer url.deinit();
    try url.writer.writeAll(authorize_url ++ "?response_type=code&client_id=");
    try writeUrlEncoded(&url.writer, client_id);
    try url.writer.writeAll("&redirect_uri=");
    try writeUrlEncoded(&url.writer, redirect_uri);
    try url.writer.writeAll("&scope=");
    try writeUrlEncoded(&url.writer, scope);
    try url.writer.writeAll("&code_challenge=");
    try writeUrlEncoded(&url.writer, challenge);
    try url.writer.writeAll("&code_challenge_method=S256&state=");
    try writeUrlEncoded(&url.writer, state);
    try url.writer.writeAll("&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=nova");

    return .{ .verifier = verifier, .state = state, .url = try url.toOwnedSlice() };
}

fn openBrowser(gpa: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const argv = switch (@import("builtin").target.os.tag) {
        .macos => &[_][]const u8{ "open", url },
        .windows => &[_][]const u8{ "cmd", "/c", "start", "", url },
        else => &[_][]const u8{ "xdg-open", url },
    };
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
}

fn waitForAuthorizationCode(gpa: std.mem.Allocator, io: std.Io, state: []const u8) ![]u8 {
    var address = try std.Io.net.IpAddress.parseIp4(auth_host, auth_port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var stream = try server.accept(io);
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try http_server.receiveHead();
    const code = parseCallbackTarget(gpa, request.head.target, state) catch |err| {
        try request.respond("OpenAI authentication failed.", .{ .status = .bad_request });
        return err;
    };
    errdefer gpa.free(code);
    try request.respond("OpenAI authentication completed. You can close this window.", .{});
    return code;
}

fn parseCallbackTarget(gpa: std.mem.Allocator, target: []const u8, expected_state: []const u8) ![]u8 {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse return error.InvalidCallback;
    if (!std.mem.eql(u8, target[0..question], "/auth/callback")) return error.InvalidCallback;
    const query = target[question + 1 ..];
    const code = queryValue(query, "code") orelse return error.InvalidCallback;
    const state = queryValue(query, "state") orelse return error.InvalidCallback;
    if (!std.mem.eql(u8, state, expected_state)) return error.StateMismatch;
    return try percentDecode(gpa, code);
}

fn exchangeAuthorizationCode(gpa: std.mem.Allocator, io: std.Io, code: []const u8, verifier: []const u8) !Credentials {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("grant_type=authorization_code&client_id=");
    try writeUrlEncoded(&body.writer, client_id);
    try body.writer.writeAll("&code=");
    try writeUrlEncoded(&body.writer, code);
    try body.writer.writeAll("&code_verifier=");
    try writeUrlEncoded(&body.writer, verifier);
    try body.writer.writeAll("&redirect_uri=");
    try writeUrlEncoded(&body.writer, redirect_uri);
    return try tokenRequest(gpa, io, body.written());
}

fn refreshAccessToken(gpa: std.mem.Allocator, io: std.Io, refresh_token: []const u8) !Credentials {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("grant_type=refresh_token&refresh_token=");
    try writeUrlEncoded(&body.writer, refresh_token);
    try body.writer.writeAll("&client_id=");
    try writeUrlEncoded(&body.writer, client_id);
    return try tokenRequest(gpa, io, body.written());
}

fn tokenRequest(gpa: std.mem.Allocator, io: std.Io, body: []const u8) !Credentials {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    logger.log("codex.token.request POST {s} body={s}", .{ token_url, body });
    var req = try client.request(.POST, try std.Uri.parse(token_url), .{ .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } } });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var buffer: [4096]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&buffer);
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    const bytes = try readResponseBody(gpa, &response);
    defer gpa.free(bytes);
    logger.log("codex.token.response status={d} body={s}", .{ status, logBytes(bytes) });
    if (status < 200 or status >= 300) return error.TokenRequestFailed;
    return try parseTokenResponse(gpa, io, bytes);
}

fn readResponseBody(gpa: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var empty_decompress_buffer: [0]u8 = .{};
    var decompress_buffer: []u8 = &empty_decompress_buffer;
    var decompress_buffer_owned = false;
    switch (response.head.content_encoding) {
        .identity => {},
        .zstd => {
            decompress_buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len);
            decompress_buffer_owned = true;
        },
        .deflate, .gzip => {
            decompress_buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            decompress_buffer_owned = true;
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
    defer if (decompress_buffer_owned) gpa.free(decompress_buffer);
    var transfer_buffer: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try reader.streamRemaining(&out.writer);
    return try out.toOwnedSlice();
}

fn parseTokenResponse(gpa: std.mem.Allocator, io: std.Io, bytes: []const u8) !Credentials {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidCredentials;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCredentials;
    const access = stringField(parsed.value, "access_token") orelse return error.InvalidCredentials;
    const refresh_token = stringField(parsed.value, "refresh_token") orelse return error.InvalidCredentials;
    const expires_in = numberField(parsed.value, "expires_in") orelse return error.InvalidCredentials;
    const account_id = try accountIdFromAccessToken(gpa, access);
    errdefer gpa.free(account_id);
    return .{
        .access = try gpa.dupe(u8, access),
        .refresh = try gpa.dupe(u8, refresh_token),
        .account_id = account_id,
        .expires = nowMs(io) + expires_in * 1000,
    };
}

fn accountIdFromAccessToken(gpa: std.mem.Allocator, access: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, access, '.');
    _ = parts.next() orelse return error.InvalidCredentials;
    const payload = parts.next() orelse return error.InvalidCredentials;
    _ = parts.next() orelse return error.InvalidCredentials;
    const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    const decoded = try gpa.alloc(u8, size);
    defer gpa.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, decoded, .{}) catch return error.InvalidCredentials;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCredentials;
    const claim = parsed.value.object.get(jwt_claim_path) orelse return error.InvalidCredentials;
    if (claim != .object) return error.InvalidCredentials;
    const account_id = stringField(claim, "chatgpt_account_id") orelse return error.InvalidCredentials;
    return try gpa.dupe(u8, account_id);
}

fn save(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, credentials: Credentials) !void {
    try writeAuth(gpa, io, home_dir, credentials);
}

fn writeAuth(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    credentials: ?Credentials,
) !void {
    const path = try authPath(gpa, home_dir);
    defer gpa.free(path);
    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try payload.writer.writeByte('{');
    var wrote_any = false;
    if (credentials) |value| {
        try writeAuthKey(&payload.writer, "openaiCodex", &wrote_any);
        try writeCredentials(&payload.writer, &value);
    }
    try payload.writer.writeAll("}\n");
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(payload.written());
    try writer.interface.flush();
}

fn writeAuthKey(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    wrote_any.* = true;
}

fn writeCredentials(writer: *std.Io.Writer, credentials: *const Credentials) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"access\":");
    try std.json.Stringify.value(credentials.access, .{}, writer);
    try writer.writeAll(",\"refresh\":");
    try std.json.Stringify.value(credentials.refresh, .{}, writer);
    try writer.writeAll(",\"expires\":");
    try std.json.Stringify.value(credentials.expires, .{}, writer);
    try writer.writeAll(",\"accountId\":");
    try std.json.Stringify.value(credentials.account_id, .{}, writer);
    try writer.writeByte('}');
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

fn authPath(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    if (home_dir.len == 0) return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home_dir, ".nova", "auth.json" });
}

fn parseAuthFile(gpa: std.mem.Allocator, bytes: []const u8) !?Credentials {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const provider = parsed.value.object.get("openaiCodex") orelse return null;
    if (provider != .object) return null;
    return try credentialsFromValue(gpa, provider);
}

fn credentialsFromValue(gpa: std.mem.Allocator, value: std.json.Value) !Credentials {
    const access = stringField(value, "access") orelse return error.InvalidCredentials;
    const refresh_token = stringField(value, "refresh") orelse return error.InvalidCredentials;
    const account_id = stringField(value, "accountId") orelse return error.InvalidCredentials;
    const expires = numberField(value, "expires") orelse return error.InvalidCredentials;
    return .{
        .access = try gpa.dupe(u8, access),
        .refresh = try gpa.dupe(u8, refresh_token),
        .account_id = try gpa.dupe(u8, account_id),
        .expires = expires,
    };
}

fn queryValue(query: []const u8, name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..equals], name)) return part[equals + 1 ..];
    }
    return null;
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn numberField(value: std.json.Value, name: []const u8) ?i64 {
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .integer => |integer| @intCast(integer),
        .float => |float| @intFromFloat(float),
        else => null,
    };
}

fn base64Url(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, bytes);
    return out;
}

fn hexLower(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try gpa.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 15];
    }
    return out;
}

fn writeUrlEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else if (byte == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 15]);
        }
    }
}

fn percentDecode(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '+') {
            try out.writer.writeByte(' ');
            index += 1;
        } else if (value[index] == '%') {
            if (index + 2 >= value.len) return error.InvalidPercentEncoding;
            const hi = try std.fmt.charToDigit(value[index + 1], 16);
            const lo = try std.fmt.charToDigit(value[index + 2], 16);
            try out.writer.writeByte((hi << 4) | lo);
            index += 3;
        } else {
            try out.writer.writeByte(value[index]);
            index += 1;
        }
    }
    return try out.toOwnedSlice();
}

fn logBytes(bytes: []const u8) []const u8 {
    const limit = 12 * 1024;
    if (bytes.len <= limit) return bytes;
    return bytes[0..limit];
}

test "pkce helpers use base64url without padding" {
    const gpa = std.testing.allocator;
    const encoded = try base64Url(gpa, "abc");
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings("YWJj", encoded);
}

test "callback parser validates state and decodes code" {
    const gpa = std.testing.allocator;
    const code = try parseCallbackTarget(gpa, "/auth/callback?code=a%2Fb%3D&state=ok", "ok");
    defer gpa.free(code);
    try std.testing.expectEqualStrings("a/b=", code);
    try std.testing.expectError(error.StateMismatch, parseCallbackTarget(gpa, "/auth/callback?code=a&state=bad", "ok"));
}

test "invalid token json maps to domain error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidCredentials, parseTokenResponse(gpa, std.testing.io, "not json"));
}

test "static models match openai codex catalog" {
    const gpa = std.testing.allocator;
    const loaded = try loadStaticModels(gpa);
    defer {
        for (loaded) |*model| model.deinit(gpa);
        gpa.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 6), loaded.len);
    try std.testing.expectEqualStrings("gpt-5.2", loaded[0].id);
    try std.testing.expectEqualStrings("gpt-5.3-codex", loaded[1].id);
    try std.testing.expectEqualStrings("gpt-5.3-codex-spark", loaded[2].id);
    try std.testing.expectEqualStrings("gpt-5.4", loaded[3].id);
    try std.testing.expectEqualStrings("gpt-5.4-mini", loaded[4].id);
    try std.testing.expectEqualStrings("gpt-5.5", loaded[5].id);
}

test "sign out removes missing auth file without error" {
    try signOut(std.testing.allocator, std.testing.io, "/tmp/nova-missing-home-for-signout-test");
}

test "auth file parser loads openai codex credentials" {
    const gpa = std.testing.allocator;
    const loaded = try parseAuthFile(gpa, "{\"openaiCodex\":{\"access\":\"a\",\"refresh\":\"r\",\"expires\":12,\"accountId\":\"acct\"}}");
    var credentials = loaded.?;
    defer credentials.deinit(gpa);
    try std.testing.expectEqualStrings("a", credentials.access);
    try std.testing.expectEqualStrings("r", credentials.refresh);
    try std.testing.expectEqualStrings("acct", credentials.account_id);
    try std.testing.expectEqual(@as(i64, 12), credentials.expires);
}
