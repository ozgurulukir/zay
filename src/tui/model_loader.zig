const std = @import("std");

const codex = @import("../codex.zig");
const config_mod = @import("../config.zig");
const openai_compatible_mod = @import("../ai/openai_compatible.zig");
const symbols = @import("../symbols.zig");

pub const ModelSource = union(enum) { openai_codex, openai_compatible: config_mod.Provider };

pub const Catalog = enum {
    connected_provider,
    openai_codex,
    single_provider,
};

pub const Result = struct {
    models: std.ArrayList(codex.Model) = .empty,
    sources: std.ArrayList(ModelSource) = .empty,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        for (self.models.items) |*model| model.deinit(gpa);
        self.models.deinit(gpa);
        self.sources.deinit(gpa);
        self.* = undefined;
    }
};

/// Outcome of a load task. `failed.message` is gpa-owned. `Outcome.deinit`
/// frees whichever branch is set, so the consumer only needs to call deinit
/// regardless of which way the task went.
pub const Outcome = union(enum) {
    ready: Result,
    failed: []u8,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*r| r.deinit(gpa),
            .failed => |msg| gpa.free(msg),
        }
        self.* = undefined;
    }
};

pub const Configured = struct {
    provider: config_mod.Provider,
    base_url: []u8, // gpa-owned
    api_key: []u8, // gpa-owned
};

/// Snapshot of everything the worker needs. Owned by the job and freed when
/// the task exits, so the App layer can mutate `cached_config` etc. without
/// racing the worker.
pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    catalog: Catalog,
    configured: []Configured,
    include_locals: bool,
    codex_signed_in: bool,
    /// Set to `true` immediately before the worker returns, so the main
    /// thread can non-blockingly poll for completion without awaiting.
    done: *std.atomic.Value(bool),

    fn deinit(self: *Job) void {
        for (self.configured) |c| {
            self.gpa.free(c.base_url);
            self.gpa.free(c.api_key);
        }
        if (self.configured.len > 0) self.gpa.free(self.configured);
        self.* = undefined;
    }
};

/// Worker entry point for `io.concurrent`. Owns `job` — frees it (and the
/// strings it carries) on exit. Flips `job.done` to `true` immediately
/// before returning so the main loop knows it can `await` without blocking.
pub fn run(job: *Job) Outcome {
    const gpa = job.gpa;
    const done = job.done;
    defer {
        job.deinit();
        gpa.destroy(job);
        done.store(true, .release);
    }

    var result: Result = .{};
    buildCatalog(job, &result) catch |err| {
        result.deinit(gpa);
        const message = std.fmt.allocPrint(gpa, "Could not load models: {s}", .{@errorName(err)}) catch return .{ .failed = &.{} };
        return .{ .failed = message };
    };
    return .{ .ready = result };
}

fn buildCatalog(job: *Job, result: *Result) !void {
    switch (job.catalog) {
        .connected_provider => {
            for (job.configured) |configured| loadConfigured(job, configured, result) catch {};
            if (job.include_locals) {
                loadLocal(job, .ollama, result) catch {};
                loadLocal(job, .llama_cpp, result) catch {};
            }
            if (job.codex_signed_in) try loadStatic(job, result);
        },
        .single_provider => {
            for (job.configured) |configured| try loadConfigured(job, configured, result);
        },
        .openai_codex => try loadStatic(job, result),
    }
}

fn loadConfigured(job: *Job, configured: Configured, result: *Result) !void {
    const fetched = try openai_compatible_mod.listModels(job.gpa, job.io, configured.base_url, configured.api_key);
    defer {
        for (fetched) |*entry| entry.deinit(job.gpa);
        job.gpa.free(fetched);
    }
    for (fetched) |entry| {
        if (!includeLocalModel(configured.provider, entry.id)) continue;
        if (!includeAnonymousModel(configured.provider, configured.api_key, entry.id)) continue;
        const id = try job.gpa.dupe(u8, entry.id);
        errdefer job.gpa.free(id);
        const label = try std.fmt.allocPrint(job.gpa, "{s}{s}{s}", .{ providerModelLabel(configured.provider), symbols.separator_dot_padded, entry.id });
        errdefer job.gpa.free(label);
        try result.models.append(job.gpa, .{ .id = id, .label = label });
        try result.sources.append(job.gpa, .{ .openai_compatible = configured.provider });
    }
}

fn loadLocal(job: *Job, provider: config_mod.Provider, result: *Result) !void {
    const base_url = provider.defaultBaseUrl() orelse return;
    const api_key = providerLocalApiKey(provider);
    const fetched = try openai_compatible_mod.listModels(job.gpa, job.io, base_url, api_key);
    defer {
        for (fetched) |*entry| entry.deinit(job.gpa);
        job.gpa.free(fetched);
    }
    for (fetched) |entry| {
        if (!includeLocalModel(provider, entry.id)) continue;
        const id = try job.gpa.dupe(u8, entry.id);
        errdefer job.gpa.free(id);
        const label = try std.fmt.allocPrint(job.gpa, "{s}{s}{s}", .{ providerModelLabel(provider), symbols.separator_dot_padded, entry.id });
        errdefer job.gpa.free(label);
        try result.models.append(job.gpa, .{ .id = id, .label = label });
        try result.sources.append(job.gpa, .{ .openai_compatible = provider });
    }
}

fn loadStatic(job: *Job, result: *Result) !void {
    const models = try codex.loadStaticModels(job.gpa);
    defer job.gpa.free(models);
    for (models) |model| {
        const id = try job.gpa.dupe(u8, model.id);
        errdefer job.gpa.free(id);
        const label = try job.gpa.dupe(u8, model.label);
        errdefer job.gpa.free(label);
        try result.models.append(job.gpa, .{ .id = id, .label = label });
        try result.sources.append(job.gpa, .openai_codex);
    }
}

pub fn includeAnonymousModel(provider: config_mod.Provider, api_key: []const u8, id: []const u8) bool {
    const anon = provider.anonymousApiKey() orelse return true;
    if (!std.mem.eql(u8, api_key, anon)) return true;
    return std.mem.endsWith(u8, id, "-free");
}

pub fn includeLocalModel(provider: config_mod.Provider, id: []const u8) bool {
    if (provider == .ollama) {
        if (std.mem.endsWith(u8, id, "-cloud")) return false;
        if (std.mem.endsWith(u8, id, ":cloud")) return false;
    }
    return true;
}

fn providerLocalApiKey(provider: config_mod.Provider) []const u8 {
    return switch (provider) {
        .ollama => "ollama",
        .llama_cpp => "llama.cpp",
        else => "",
    };
}

fn providerModelLabel(provider: config_mod.Provider) []const u8 {
    return provider.displayName();
}

test "includeAnonymousModel keeps only -free models when anonymous on opencode zen" {
    // Anonymous (the "public" sentinel): only `-free` models pass.
    try std.testing.expect(includeAnonymousModel(.opencode_zen, "public", "deepseek-v4-flash-free"));
    try std.testing.expect(!includeAnonymousModel(.opencode_zen, "public", "claude-opus-4-8"));
    try std.testing.expect(!includeAnonymousModel(.opencode_zen, "public", "deepseek-v4-flash"));
    // A real key (not the sentinel) shows everything.
    try std.testing.expect(includeAnonymousModel(.opencode_zen, "sk-real", "claude-opus-4-8"));
    // Providers without an anonymous tier are never filtered.
    try std.testing.expect(includeAnonymousModel(.cerebras, "public", "anything"));
}

test "includeLocalModel drops cloud-suffixed models for local ollama only" {
    try std.testing.expect(!includeLocalModel(.ollama, "gpt-oss:120b-cloud"));
    try std.testing.expect(!includeLocalModel(.ollama, "qwen3-coder:480b-cloud"));
    try std.testing.expect(!includeLocalModel(.ollama, "deepseek-v3.1:671b:cloud"));
    try std.testing.expect(includeLocalModel(.ollama, "llama3.1:8b"));
    // Ollama Cloud and other providers keep every model the endpoint returns.
    try std.testing.expect(includeLocalModel(.ollama_cloud, "gpt-oss:120b-cloud"));
    try std.testing.expect(includeLocalModel(.cerebras, "anything:cloud"));
}
