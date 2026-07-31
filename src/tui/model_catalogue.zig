//! ModelCatalogue — the model/provider/selection state the TUI builds when the
//! user opens the model picker.
//!
//! Each displayed model is one `Entry` bundling its `codex.Model`, its
//! provenance (`source`), and its chosen reasoning-effort index. Bundling them
//! removes the old hazard of three index-aligned parallel arrays that had to be
//! appended, dropped, and snapshotted in lockstep (and silently drifted when a
//! caller forgot one — see `dropProvider`). One entry == one row, by
//! construction.
//!
//! The catalogue owns the *data*; orchestration that needs the App's
//! `io`/`gpa`/config/runtime (kicking off the load, persisting a selection)
//! stays on the App and reaches in through here.

const std = @import("std");

const codex = @import("../auth/codex.zig");
const config_mod = @import("../config/config.zig");
const model_loader = @import("model_loader.zig");
const model_picker = @import("widgets/model_picker.zig");

/// Where a model-selection write should land.
pub const ModelScope = enum { global, project, session };

/// One picker row: a model, where it came from, and its reasoning-effort index.
pub const Entry = struct {
    model: codex.Model,
    source: model_loader.ModelSource,
    reasoning_index: u32 = 0,
};

pub const ModelCatalogue = struct {
    /// Every displayed model, in display order. Model + source + reasoning
    /// travel together, so an index is always valid across all three.
    entries: std.ArrayList(Entry) = .empty,
    /// Cache of OpenAI-compatible models fetched from connected providers,
    /// before they are folded into `entries`.
    compatible_models: std.ArrayList(codex.Model) = .empty,
    compatible_models_fetched: bool = false,
    model_selection: u32 = 0,
    model_column: model_picker.Column = .model,
    model_scope: ModelScope = .global,
    /// Reasoning indexes captured when the picker opened, restored on cancel.
    reasoning_snapshot: std.ArrayList(u32) = .empty,
    model_selection_snapshot: u32 = 0,

    /// Background catalogue-load state machine. The previous flat fields
    /// (model_load_future/done/error/merge + models_cached) allowed illegal
    /// combinations like future=null with error set, or done=true with
    /// future=null. The union makes those unrepresentable.
    load: LoadState = .idle,
    /// True once a successful fetch has populated `entries`; subsequent picker
    /// opens skip the network round-trip.
    models_cached: bool = false,

    pub const LoadState = union(enum) {
        idle,
        loading: struct {
            future: std.Io.Future(model_loader.Outcome),
            done: std.atomic.Value(bool) = .init(false),
            merge: bool = false,
        },
        failed: struct {
            message: []u8,
        },
    };

    /// Backward-compatible view: `model_load_future != null`.
    pub fn model_load_future(self: *const ModelCatalogue) ?std.Io.Future(model_loader.Outcome) {
        return switch (self.load) {
            .loading => |l| l.future,
            else => null,
        };
    }
    /// Backward-compatible view: `model_load_done`.
    pub fn model_load_done(self: *const ModelCatalogue) std.atomic.Value(bool) {
        return switch (self.load) {
            .loading => |l| l.done,
            else => .init(false),
        };
    }
    /// Backward-compatible view: `model_load_error`.
    pub fn model_load_error(self: *const ModelCatalogue) ?[]u8 {
        return switch (self.load) {
            .failed => |f| f.message,
            else => null,
        };
    }
    /// Backward-compatible view: `model_load_merge`.
    pub fn model_load_merge(self: *const ModelCatalogue) bool {
        return switch (self.load) {
            .loading => |l| l.merge,
            else => false,
        };
    }

    /// Free every owned model + snapshot. The in-flight future must be
    /// cancelled first by the caller (it needs `io`); see `App.cancelModelLoad`.
    pub fn deinit(self: *ModelCatalogue, gpa: std.mem.Allocator) void {
        switch (self.load) {
            .failed => |*f| gpa.free(f.message),
            else => {},
        }
        for (self.entries.items) |*entry| {
            entry.model.deinit(gpa);
            entry.source.deinit(gpa);
        }
        self.entries.deinit(gpa);
        for (self.compatible_models.items) |*model| model.deinit(gpa);
        self.compatible_models.deinit(gpa);
        self.reasoning_snapshot.deinit(gpa);
        self.* = undefined;
    }

    pub fn len(self: *const ModelCatalogue) u32 {
        return @intCast(self.entries.items.len);
    }

    /// Append a model with its provenance; reasoning starts at the default (0).
    /// Takes ownership of `model`'s id/label.
    pub fn append(self: *ModelCatalogue, gpa: std.mem.Allocator, model: codex.Model, source: model_loader.ModelSource) !void {
        try self.entries.append(gpa, .{ .model = model, .source = source });
    }

    /// Free every entry's model and drop all rows.
    pub fn clearEntries(self: *ModelCatalogue, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            entry.model.deinit(gpa);
            entry.source.deinit(gpa);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Remove every entry sourced from `provider`. Model, source, and reasoning
    /// leave together — nothing can drift out of alignment.
    ///
    /// Enum-bazlıdır ve her builtin katalog provider'ı ayrı bir enum değerine
    /// sahip olduğu için onlar için doğru çalışır. Çoklu `.openai_compatible`
    /// provider'lar aynı enum değerini paylaştığından onları birleştirir —
    /// dynamic/config provider'lar için `dropConn` kullanın.
    pub fn dropProvider(self: *ModelCatalogue, gpa: std.mem.Allocator, provider: config_mod.Provider) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const matches = switch (self.entries.items[i].source) {
                .openai_compatible => |conn| conn.provider == provider,
                .openai_codex => false,
            };
            if (matches) {
                self.entries.items[i].model.deinit(gpa);
                self.entries.items[i].source.deinit(gpa);
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Remove every entry sourced from `conn`. Conn-bazlıdır: provider enum'u
    /// + `base_url` + `auth_key_id` üçlüsü eşleşmelidir. Çoklu
    /// `.openai_compatible` provider'lar aynı enum değerini paylaştığından,
    /// enum-bazlı `dropProvider` onları ayıramazdı — bu versiyon yalnızca
    /// verilen bağlantıya ait entry'leri düşürür, böylece "bir dynamic
    /// provider refresh edildiğinde diğerlerinin modelleri kaybolmaz"
    /// (illegal state temsil edilemez: `Compatible` üç bilgiyi birlikte taşır,
    /// karşılaştırma da üçünü birlikte yapar).
    pub fn dropConn(self: *ModelCatalogue, gpa: std.mem.Allocator, conn: model_loader.Compatible) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const matches = switch (self.entries.items[i].source) {
                .openai_compatible => |c| c.provider == conn.provider and
                    std.mem.eql(u8, c.base_url, conn.base_url) and
                    std.mem.eql(u8, c.auth_key_id, conn.auth_key_id),
                .openai_codex => false,
            };
            if (matches) {
                self.entries.items[i].model.deinit(gpa);
                self.entries.items[i].source.deinit(gpa);
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Reset every reasoning index to the default and clamp the selection. Used
    /// when (re)opening the picker, including the warm path where entries
    /// persist from a prior session.
    pub fn resetReasoning(self: *ModelCatalogue) void {
        for (self.entries.items) |*entry| entry.reasoning_index = 0;
        if (self.model_selection >= self.len()) self.model_selection = 0;
    }

    /// Storage index of the entry whose model matches `active_id`, if any.
    pub fn activeStorageIdx(self: *const ModelCatalogue, active_id: ?[]const u8) ?u32 {
        const id = active_id orelse return null;
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.model.id, id)) return @intCast(i);
        }
        return null;
    }

    /// Capture the current reasoning indexes + selection so the picker can be
    /// cancelled back to this state.
    pub fn snapshot(self: *ModelCatalogue, gpa: std.mem.Allocator) !void {
        self.reasoning_snapshot.clearRetainingCapacity();
        for (self.entries.items) |entry| try self.reasoning_snapshot.append(gpa, entry.reasoning_index);
        self.model_selection_snapshot = self.model_selection;
    }

    /// Restore the reasoning indexes + selection captured by `snapshot`.
    pub fn restore(self: *ModelCatalogue) void {
        for (self.entries.items, 0..) |*entry, i| {
            entry.reasoning_index = if (i < self.reasoning_snapshot.items.len) self.reasoning_snapshot.items[i] else 0;
        }
        self.model_selection = self.model_selection_snapshot;
    }
};

fn testModel(gpa: std.mem.Allocator, id: []const u8) !codex.Model {
    return .{ .id = try gpa.dupe(u8, id), .label = try gpa.dupe(u8, id) };
}

/// Test helper: gpa-owned `Compatible` source. `catalogue.deinit`/`dropProvider`
/// string'leri serbest bırakır.
fn testCompatibleSource(gpa: std.mem.Allocator, provider: config_mod.Provider, base_url: []const u8, auth_key_id: []const u8) !model_loader.Compatible {
    return .{
        .provider = provider,
        .base_url = try gpa.dupe(u8, base_url),
        .auth_key_id = try gpa.dupe(u8, auth_key_id),
    };
}

test "dropProvider removes model, source, and reasoning together" {
    const gpa = std.testing.allocator;
    var catalogue: ModelCatalogue = .{};
    defer catalogue.deinit(gpa);

    try catalogue.append(gpa, try testModel(gpa, "gpt"), .openai_codex);
    try catalogue.append(gpa, try testModel(gpa, "llama"), .{ .openai_compatible = try testCompatibleSource(gpa, .ollama, "http://localhost:11434/v1", "ollama") });
    try catalogue.append(gpa, try testModel(gpa, "qwen"), .{ .openai_compatible = try testCompatibleSource(gpa, .ollama, "http://localhost:11434/v1", "ollama") });
    // Give the middle entry a non-default reasoning index — it must leave with
    // its row, never stranding a stale index behind.
    catalogue.entries.items[1].reasoning_index = 2;

    catalogue.dropProvider(gpa, .ollama);

    try std.testing.expectEqual(@as(u32, 1), catalogue.len());
    try std.testing.expectEqualStrings("gpt", catalogue.entries.items[0].model.id);
    try std.testing.expectEqual(model_loader.ModelSource.openai_codex, catalogue.entries.items[0].source);
    try std.testing.expectEqual(@as(u32, 0), catalogue.entries.items[0].reasoning_index);
}

test "dropConn drops only the matching dynamic provider, not sibling openai_compatible ones" {
    // İki dynamic provider (StepFun + Kimi) aynı `.openai_compatible` enum
    // değerini paylaşır. `dropConn` yalnızca (provider + base_url + auth_key_id)
    // üçlüsü eşleşen entry'leri düşürmelidir — kardeşi korumalıdır. Enum-bazlı
    // `dropProvider` bunu yapamazdı (her ikisini de düşürürdü).
    const gpa = std.testing.allocator;
    var catalogue: ModelCatalogue = .{};
    defer catalogue.deinit(gpa);

    try catalogue.append(gpa, try testModel(gpa, "step-1"), .{ .openai_compatible = try testCompatibleSource(gpa, .openai_compatible, "https://api.stepfun.com/v1", "stepfun-ai") });
    try catalogue.append(gpa, try testModel(gpa, "step-2"), .{ .openai_compatible = try testCompatibleSource(gpa, .openai_compatible, "https://api.stepfun.com/v1", "stepfun-ai") });
    try catalogue.append(gpa, try testModel(gpa, "kimi"), .{ .openai_compatible = try testCompatibleSource(gpa, .openai_compatible, "https://api.moonshot.cn/v1", "moonshot") });
    try catalogue.append(gpa, try testModel(gpa, "gpt"), .openai_codex);

    // Refresh StepFun: sadece onun entry'leri düşürülmeli, Kimi ve Codex kalır.
    catalogue.dropConn(gpa, .{
        .provider = .openai_compatible,
        .base_url = "https://api.stepfun.com/v1",
        .auth_key_id = "stepfun-ai",
    });

    try std.testing.expectEqual(@as(u32, 2), catalogue.len());
    try std.testing.expectEqualStrings("kimi", catalogue.entries.items[0].model.id);
    try std.testing.expectEqualStrings("moonshot", catalogue.entries.items[0].source.openai_compatible.auth_key_id);
    try std.testing.expectEqualStrings("gpt", catalogue.entries.items[1].model.id);
    try std.testing.expectEqual(model_loader.ModelSource.openai_codex, catalogue.entries.items[1].source);

    // Kimi'yi de drop et — geriye yalnızca Codex kalmalı.
    catalogue.dropConn(gpa, .{
        .provider = .openai_compatible,
        .base_url = "https://api.moonshot.cn/v1",
        .auth_key_id = "moonshot",
    });
    try std.testing.expectEqual(@as(u32, 1), catalogue.len());
    try std.testing.expectEqual(model_loader.ModelSource.openai_codex, catalogue.entries.items[0].source);
}

test "snapshot then restore round-trips reasoning and selection" {
    const gpa = std.testing.allocator;
    var catalogue: ModelCatalogue = .{};
    defer catalogue.deinit(gpa);

    try catalogue.append(gpa, try testModel(gpa, "a"), .openai_codex);
    try catalogue.append(gpa, try testModel(gpa, "b"), .openai_codex);
    catalogue.entries.items[0].reasoning_index = 1;
    catalogue.model_selection = 1;
    try catalogue.snapshot(gpa);

    // Mutate after the snapshot…
    catalogue.entries.items[0].reasoning_index = 3;
    catalogue.entries.items[1].reasoning_index = 2;
    catalogue.model_selection = 0;

    // …then cancel back to the captured state.
    catalogue.restore();
    try std.testing.expectEqual(@as(u32, 1), catalogue.entries.items[0].reasoning_index);
    try std.testing.expectEqual(@as(u32, 0), catalogue.entries.items[1].reasoning_index);
    try std.testing.expectEqual(@as(u32, 1), catalogue.model_selection);
}

test "resetReasoning zeroes indexes and clamps selection" {
    const gpa = std.testing.allocator;
    var catalogue: ModelCatalogue = .{};
    defer catalogue.deinit(gpa);

    try catalogue.append(gpa, try testModel(gpa, "a"), .openai_codex);
    catalogue.entries.items[0].reasoning_index = 2;
    catalogue.model_selection = 9;

    catalogue.resetReasoning();
    try std.testing.expectEqual(@as(u32, 0), catalogue.entries.items[0].reasoning_index);
    try std.testing.expectEqual(@as(u32, 0), catalogue.model_selection);
}

test "activeStorageIdx finds the matching model" {
    const gpa = std.testing.allocator;
    var catalogue: ModelCatalogue = .{};
    defer catalogue.deinit(gpa);

    try catalogue.append(gpa, try testModel(gpa, "a"), .openai_codex);
    try catalogue.append(gpa, try testModel(gpa, "b"), .openai_codex);

    try std.testing.expectEqual(@as(?u32, 1), catalogue.activeStorageIdx("b"));
    try std.testing.expectEqual(@as(?u32, null), catalogue.activeStorageIdx("missing"));
    try std.testing.expectEqual(@as(?u32, null), catalogue.activeStorageIdx(null));
}
