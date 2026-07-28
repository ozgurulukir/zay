//! Persistent model catalogue cache for the TUI model picker.

const std = @import("std");

const codex = @import("../auth/codex.zig");
const config_mod = @import("../config/config.zig");
const model_loader = @import("model_loader.zig");

const assert = std.debug.assert;
const file_bytes_max: u32 = 2 * 1024 * 1024;
/// v2: provider blokları artık `authKeyId` taşıyor (dynamic provider'ları
/// ayırt etmek için). v1 cache `authKeyId` olmadan gelir; parse configured
/// lookup'tan geri çözer.
const version_current: u32 = 2;

pub const AuthMode = enum {
    anonymous,
    keyed,
    local,

    fn label(self: AuthMode) []const u8 {
        return switch (self) {
            .anonymous => "anonymous",
            .keyed => "keyed",
            .local => "local",
        };
    }
};

pub const Configured = struct {
    provider: config_mod.Provider,
    base_url: []const u8,
    auth_mode: AuthMode,
    /// auth.json anahtar kimliği (katalog → label, dynamic → id). dynamic
    /// provider'ları birbirinden ayırt etmek için serialize edilir.
    auth_key_id: ?[]const u8 = null,
};

pub const Record = struct {
    model: codex.Model,
    source: model_loader.ModelSource,
};

pub const Records = struct {
    items: std.ArrayList(Record) = .empty,

    pub fn deinit(self: *Records, gpa: std.mem.Allocator) void {
        for (self.items.items) |*record| {
            record.model.deinit(gpa);
            record.source.deinit(gpa);
        }
        self.items.deinit(gpa);
        self.* = undefined;
    }
};

pub fn load(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, configured: []const Configured) !Records {
    assert(home_dir.len > 0);

    const cache_path = try path(gpa, home_dir);
    defer gpa.free(cache_path);
    const file = std.Io.Dir.openFile(.cwd(), io, cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > file_bytes_max) return error.FileTooBig;
    const bytes = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return parse(gpa, bytes, configured) catch .{};
}

pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    records: []const Record,
    configured: []const Configured,
) !void {
    assert(home_dir.len > 0);

    const cache_path = try path(gpa, home_dir);
    defer gpa.free(cache_path);
    const dirname = std.fs.path.dirname(cache_path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{cache_path});
    defer gpa.free(tmp_path);

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try serialize(&payload.writer, records, configured);

    {
        var file = try std.Io.Dir.createFile(.cwd(), io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(payload.written());
        try writer.interface.flush();
    }

    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), cache_path, io);
}

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, configured: []const Configured) !Records {
    assert(bytes.len > 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCache;
    const version = intField(parsed.value, "version") orelse return error.InvalidCache;
    // v1 (authKeyId yok) geriye dönük uyumlu: parse authKeyId alanı yoksa
    // configured lookup'tan çözer. Daha eski/bilinmeyen sürümler reddedilir.
    if (version != 1 and version != version_current) return .{};

    var out: Records = .{};
    errdefer out.deinit(gpa);
    const providers = parsed.value.object.get("providers") orelse return out;
    if (providers != .array) return error.InvalidCache;
    for (providers.array.items) |provider_value| {
        if (provider_value != .object) continue;
        try parseProvider(gpa, &out, provider_value, configured);
    }
    return out;
}

fn parseProvider(gpa: std.mem.Allocator, out: *Records, value: std.json.Value, configured: []const Configured) !void {
    const provider_label = stringField(value, "provider") orelse return;
    const base_url = stringField(value, "baseUrl") orelse return;
    const auth_mode_label = stringField(value, "authMode") orelse return;
    const auth_key_id = stringField(value, "authKeyId");
    const provider = providerFromLabel(provider_label) orelse return;
    const auth_mode = authModeFromLabel(auth_mode_label) orelse return;
    const matched = containsConfigured(configured, provider, base_url, auth_mode, auth_key_id) orelse return;

    const models = value.object.get("models") orelse return;
    if (models != .array) return;
    for (models.array.items) |model_value| {
        if (model_value != .object) continue;
        const id = stringField(model_value, "id") orelse continue;
        const label = stringField(model_value, "label") orelse id;
        const id_copy = try gpa.dupe(u8, id);
        errdefer gpa.free(id_copy);
        const label_copy = try gpa.dupe(u8, label);
        errdefer gpa.free(label_copy);
        try out.items.append(gpa, .{
            .model = .{ .id = id_copy, .label = label_copy },
            .source = .{
                .openai_compatible = try model_loader.compatibleSource(
                    gpa,
                    provider,
                    base_url,
                    matched.auth_key_id,
                ),
            },
        });
    }
}

fn serialize(writer: *std.Io.Writer, records: []const Record, configured: []const Configured) !void {
    try writer.writeByte('{');
    var wrote_key = false;
    try writeKey(writer, "version", &wrote_key);
    try writer.print("{d}", .{version_current});
    try writeKey(writer, "providers", &wrote_key);
    try writer.writeByte('[');
    var wrote_provider = false;
    for (configured) |configured_provider| {
        if (!hasRecordsForConfigured(records, configured_provider)) continue;
        if (wrote_provider) try writer.writeByte(',');
        try writeProvider(writer, records, configured_provider);
        wrote_provider = true;
    }
    try writer.writeByte(']');
    try writer.writeAll("}\n");
}

fn writeProvider(writer: *std.Io.Writer, records: []const Record, configured: Configured) !void {
    try writer.writeByte('{');
    var wrote_key = false;
    try writeKey(writer, "provider", &wrote_key);
    try std.json.Stringify.value(configured.provider.label(), .{}, writer);
    try writeKey(writer, "baseUrl", &wrote_key);
    try std.json.Stringify.value(configured.base_url, .{}, writer);
    try writeKey(writer, "authMode", &wrote_key);
    try std.json.Stringify.value(configured.auth_mode.label(), .{}, writer);
    // auth_key_id dynamic provider'ları (aynı .openai_compatible enum'ını
    // paylaşan StepFun, Kimi, vb.) birbirinden ayırır. Katalog provider'ları
    // için label'a eşittir; yine de yazılır ki restart'ta birebir eşleşsin.
    if (configured.auth_key_id) |id| {
        try writeKey(writer, "authKeyId", &wrote_key);
        try std.json.Stringify.value(id, .{}, writer);
    }
    try writeKey(writer, "models", &wrote_key);
    try writer.writeByte('[');
    var wrote_model = false;
    for (records) |record| {
        if (!recordMatchesConfigured(record, configured)) continue;
        if (wrote_model) try writer.writeByte(',');
        try writer.writeByte('{');
        var wrote_model_key = false;
        try writeKey(writer, "id", &wrote_model_key);
        try std.json.Stringify.value(record.model.id, .{}, writer);
        try writeKey(writer, "label", &wrote_model_key);
        try std.json.Stringify.value(record.model.label, .{}, writer);
        try writer.writeByte('}');
        wrote_model = true;
    }
    try writer.writeByte(']');
    try writer.writeByte('}');
}

fn hasRecordsForConfigured(records: []const Record, configured: Configured) bool {
    for (records) |record| {
        if (recordMatchesConfigured(record, configured)) return true;
    }
    return false;
}

/// Bir record configured'a provider + base_url + auth_key_id üçlüsüyle
/// eşleşiyorsa true. Dynamic provider'lar `.openai_compatible` enum'ını
/// paylaştığından, yalnızca provider enum karşılaştırmak onları birleştirirdi;
/// base_url + auth_key_id ayırt eder.
fn recordMatchesConfigured(record: Record, configured: Configured) bool {
    return switch (record.source) {
        .openai_compatible => |conn| blk: {
            if (conn.provider != configured.provider) break :blk false;
            if (!std.mem.eql(u8, conn.base_url, configured.base_url)) break :blk false;
            const cfg_id = configured.auth_key_id orelse configured.provider.label();
            break :blk std.mem.eql(u8, conn.auth_key_id, cfg_id);
        },
        .openai_codex => false,
    };
}

/// Eşleşen configured kaydını döndürür (auth_key_id çözümlemek için), yoksa
/// null. `auth_key_id` null (eski v1 cache) ise provider+base_url+auth_mode
/// eşleşmesi yeterli; `auth_key_id` dolu ise (v2 cache) o da eşleşmeli.
fn containsConfigured(configured: []const Configured, provider: config_mod.Provider, base_url: []const u8, auth_mode: AuthMode, auth_key_id: ?[]const u8) ?Configured {
    for (configured) |entry| {
        if (entry.provider != provider) continue;
        if (entry.auth_mode != auth_mode) continue;
        if (!std.mem.eql(u8, entry.base_url, base_url)) continue;
        if (auth_key_id) |id| {
            const entry_id = entry.auth_key_id orelse continue;
            if (!std.mem.eql(u8, entry_id, id)) continue;
        }
        return entry;
    }
    return null;
}

fn providerFromLabel(label: []const u8) ?config_mod.Provider {
    inline for (@typeInfo(config_mod.Provider).@"enum".fields) |field| {
        const provider: config_mod.Provider = @enumFromInt(field.value);
        if (std.mem.eql(u8, label, provider.label())) return provider;
    }
    return null;
}

fn authModeFromLabel(label: []const u8) ?AuthMode {
    inline for (@typeInfo(AuthMode).@"enum".fields) |field| {
        const mode: AuthMode = @enumFromInt(field.value);
        if (std.mem.eql(u8, label, mode.label())) return mode;
    }
    return null;
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn intField(value: std.json.Value, name: []const u8) ?u32 {
    const field = value.object.get(name) orelse return null;
    if (field != .integer) return null;
    if (field.integer < 0) return null;
    return @intCast(@min(field.integer, std.math.maxInt(u32)));
}

fn writeKey(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    wrote_any.* = true;
}

fn path(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    if (home_dir.len == 0) return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "models.json" });
}

test "parse keeps only currently configured provider models" {
    const gpa = std.testing.allocator;
    const configured = [_]Configured{.{ .provider = .openrouter, .base_url = "https://openrouter.ai/api", .auth_mode = .keyed, .auth_key_id = "openrouter" }};
    var records = try parse(gpa,
        \\{"version":2,"providers":[{"provider":"openrouter","baseUrl":"https://openrouter.ai/api","authMode":"keyed","authKeyId":"openrouter","models":[{"id":"m","label":"OpenRouter · m"}]},{"provider":"cerebras","baseUrl":"https://api.cerebras.ai/v1","authMode":"keyed","authKeyId":"cerebras","models":[{"id":"c"}]}]}
    , &configured);
    defer records.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), records.items.items.len);
    try std.testing.expectEqualStrings("m", records.items.items[0].model.id);
    const conn = records.items.items[0].source.openai_compatible;
    try std.testing.expectEqual(config_mod.Provider.openrouter, conn.provider);
    try std.testing.expectEqualStrings("https://openrouter.ai/api", conn.base_url);
    try std.testing.expectEqualStrings("openrouter", conn.auth_key_id);
}

test "parse distinguishes dynamic providers sharing the openai_compatible enum" {
    // İki dynamic provider (StepFun + Kimi) aynı .openai_compatible enum'ını
    // paylaşır. authKeyId olmadan birleştirilirlerdi; v2 şema auth_key_id ile
    // ayırt eder. Bu, multi-provider kataloğundaki eşleşme hatasının cache
    // tarafındaki tezahürüdür.
    const gpa = std.testing.allocator;
    const configured = [_]Configured{
        .{ .provider = .openai_compatible, .base_url = "https://api.stepfun.com/v1", .auth_mode = .keyed, .auth_key_id = "stepfun-ai" },
        .{ .provider = .openai_compatible, .base_url = "https://api.moonshot.cn/v1", .auth_mode = .keyed, .auth_key_id = "moonshot" },
    };
    var records = try parse(gpa,
        \\{"version":2,"providers":[
        \\  {"provider":"openai_compatible","baseUrl":"https://api.stepfun.com/v1","authMode":"keyed","authKeyId":"stepfun-ai","models":[{"id":"step-1"}]},
        \\  {"provider":"openai_compatible","baseUrl":"https://api.moonshot.cn/v1","authMode":"keyed","authKeyId":"moonshot","models":[{"id":"kimi"}]}
        \\]}
    , &configured);
    defer records.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), records.items.items.len);
    // Her iki record da kendi base_url + auth_key_id'sini taşır — cache
    // restore edildikten sonra applySelectedModel yanlış provider'a gitmez.
    const ids = [_][]const u8{ records.items.items[0].source.openai_compatible.auth_key_id, records.items.items[1].source.openai_compatible.auth_key_id };
    try std.testing.expect(
        std.mem.eql(u8, ids[0], "stepfun-ai") or std.mem.eql(u8, ids[0], "moonshot"),
    );
    try std.testing.expect(ids[0].len != ids[1].len or !std.mem.eql(u8, ids[0], ids[1]));
}

test "parse v1 cache (no authKeyId) resolves auth_key_id from configured label" {
    // Eski v1 cache geriye dönük uyumlu: authKeyId yok, configured.label'a düşer.
    const gpa = std.testing.allocator;
    const configured = [_]Configured{.{ .provider = .openrouter, .base_url = "https://openrouter.ai/api", .auth_mode = .keyed }};
    var records = try parse(gpa,
        \\{"version":1,"providers":[{"provider":"openrouter","baseUrl":"https://openrouter.ai/api","authMode":"keyed","models":[{"id":"m","label":"OpenRouter · m"}]}]}
    , &configured);
    defer records.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), records.items.items.len);
    try std.testing.expectEqualStrings("openrouter", records.items.items[0].source.openai_compatible.auth_key_id);
}
