const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");
const os = @import("../os.zig");
const http = @import("../http.zig");
const model_catalog = @import("openai_compatible_models.zig");
const openai_endpoint = @import("openai_endpoint.zig");
const provider_headers = @import("provider_headers.zig");
const stream_parser = @import("stream_parser.zig");
const stream_part = @import("stream_part.zig");
const transport_mod = @import("transport.zig");
const tool_schema = @import("tool_schema.zig");
const tools_common = @import("../tools/common.zig");
const tools_mod = @import("../tools.zig");

const redirect_buffer_bytes = http.redirect_buffer_bytes;
const transfer_buffer_bytes = http.transfer_buffer_bytes;
const body_buffer_bytes = http.body_buffer_bytes;
/// Upper bound on an error body we will decompress + log (matches the models
/// client's cap). Prevents a hostile/garbage body from allocating unboundedly.
const response_bytes_max: u32 = 1 * 1024 * 1024;

pub const ModelEntry = model_catalog.ModelEntry;
pub const listModels = model_catalog.listModels;
pub const openaiV1Root = openai_endpoint.v1Root;
pub const sanitizeToolArguments = stream_parser.sanitizeToolArguments;

// Model- and dialect-compat quirks (two-layer effort clipping, Qwen
// system-message normalization) live in the sibling leaf `model_compat.zig`,
// re-exported so existing `openai_compatible.*` callers resolve unchanged.
pub const model_compat = @import("model_compat.zig");
pub const wireEffortLabel = model_compat.wireEffortLabel;
pub const isQwenModel = model_compat.isQwenModel;
pub const clipEffortForModel = model_compat.clipEffortForModel;

// Chat-completions request-body serialization lives in the sibling module
// `openai_request.zig` (INV-RESP-1 symmetry with the Responses client); the
// alias keeps the `Client.prompt` call sites and the payload-band tests that
// exercise `tools_json` end-to-end compiling unchanged.
pub const openai_request = @import("openai_request.zig");
const writeRequestPayload = openai_request.writeRequestPayload;

/// OpenAI-compatible AI client using the Completions API.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: ?[]u8,
    tools_json: []u8,
    /// Whether tool definitions carry OpenAI strict structured-outputs mode.
    /// Captured at `init` so `updateMcpTools` can rebuild `tools_json`
    /// consistently without the caller re-passing it. Default `false` —
    /// strict mode is OpenAI-only and silently breaks function-calling on
    /// gateways (OpenRouter/Ollama/vLLM).
    strict: bool = false,
    /// The shared send pipeline: request construction, retry budget, C2
    /// downgrade, head/error classification, error-detail recording.
    transport: transport_mod.Transport = undefined,
    /// Owned copy of `ai.Config.headers` (auto provider headers — OpenCode
    /// Zen routing, OpenRouter attribution — merged with the user's
    /// `providers.<name>.headers`, precedence already resolved at attach
    /// time by `provider_headers.build`). Materialized per request by the
    /// transport. Freed in `deinit`.
    provider_headers_owned: []provider_headers.Header = &.{},
    /// Monotonic counter for synthesised tool_call ids when the inference
    /// server omits them. OpenAI's protocol requires stable ids linking
    /// assistant tool_calls to their `tool` result messages, so we mint
    /// one here rather than letting the agent see an empty id.
    tool_call_seq: u64 = 0,

    pub fn init(
        target: *Client,
        gpa: std.mem.Allocator,
        io: std.Io,
        config: ai.Config,
    ) !void {
        if (config.base_url.len == 0) return error.EmptyBaseUrl;
        if (config.model.len == 0) return error.EmptyModelId;

        const v1_root = try openaiV1Root(gpa, config.base_url);
        defer gpa.free(v1_root);
        const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{v1_root});
        errdefer gpa.free(url);

        // Empty key => anonymous request. Keep `authorization` null so `prompt`
        // omits the header entirely.
        const authorization: ?[]u8 = if (config.api_key.len > 0)
            try std.fmt.allocPrint(gpa, "{s}{s}", .{ http.bearer_prefix, config.api_key })
        else
            null;
        errdefer if (authorization) |a| gpa.free(a);

        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
        // Borrowed at init; the deep copy lives in provider_headers_owned.
        // Blank it like base_url/api_key so no future read dangles after the
        // attach frame (which owns the specs) returns.
        owned_config.headers = &.{};
        owned_config.model = try gpa.dupe(u8, config.model);
        errdefer gpa.free(owned_config.model);
        owned_config.session_id = try gpa.dupe(u8, config.session_id);
        errdefer gpa.free(owned_config.session_id);

        const tools_json = try tool_schema.buildAllToolsJson(gpa, config.tools, config.mcp_tools, null, config.strict, .completions);
        errdefer gpa.free(tools_json);
        const provider_headers_owned = try provider_headers.cloneHeaders(gpa, config.headers);
        errdefer provider_headers.freeHeaders(gpa, provider_headers_owned);

        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = owned_config,
            .url = url,
            .authorization = authorization,
            .tools_json = tools_json,
            .strict = config.strict,
            .provider_headers_owned = provider_headers_owned,
        };
        target.transport = undefined;
        target.transport.init(gpa, io);
        // Borrowed identity: every slice here is owned by this Client, so it
        // outlives the transport and every request it sends.
        target.transport.url = target.url;
        target.transport.authorization = target.authorization;
        target.transport.provider_headers = target.provider_headers_owned;
        target.transport.header_context = .{ .session_id = target.config.session_id };
        target.transport.log_tag = "openai_compatible";
        target.transport.log_context = target.config.model;
        target.transport.request_timeout_seconds = config.request_timeout_seconds;
        target.transport.retry_base_delay_ms = config.retry_base_delay_ms;
        target.transport.max_retries = config.max_retries;
        target.transport.disable_cache_seed = config.disable_prompt_cache;
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.session_id);
        self.gpa.free(self.tools_json);
        if (self.authorization) |a| self.gpa.free(a);
        self.gpa.free(self.url);
        provider_headers.freeHeaders(self.gpa, self.provider_headers_owned);
        self.* = undefined;
    }

    /// Rebuild the serialized tool definitions after the MCP tool set changes.
    /// `mcp_tools` is borrowed only for the duration of the call; the result is
    /// the owned `tools_json`. Call between turns, never mid-turn.
    /// `registry`, when non-null, contributes its builtin + plugin tools so
    /// the model sees them as first-class definitions. `builtin_override`
    /// lets the caller pick what `config.tools` contributes at call time —
    /// typically `&.{}` because the registry's builtin already covers
    /// bash, and emitting both creates a duplicate name that most APIs
    /// reject outright.
    // Rebuild the serialized tool definitions from the final, already-deduped
    // spec list assembled by the runtime layer (builtin + registry plugin +
    // registry MCP). Call between turns, never mid-turn.
    pub fn updateTools(self: *Client, specs: []const tool_schema.ToolSpec) !void {
        const new_json = try tool_schema.buildToolsJson(self.gpa, specs, self.strict, .completions);
        self.gpa.free(self.tools_json);
        self.tools_json = new_json;
    }

    pub fn errorDetail(self: *const Client) ?[]const u8 {
        return self.transport.errorDetail();
    }

    /// Run one prompt through the shared transport. The payload writer is a
    /// stack struct over the owned config so the C2 downgrade is "flip one
    /// field, re-serialize"; the stream adapter is `stream_parser`.
    pub fn prompt(
        self: *Client,
        messages: []const ai.MessageView,
        observer: anytype,
    ) !ai.Turn {
        var payload = ChatPayload{
            .gpa = self.gpa,
            .opts = .{
                .model = self.config.model,
                .session_id = self.config.session_id,
                .reasoning = self.config.reasoning,
                .max_output_tokens = self.config.max_output_tokens,
                .dialect = self.config.wire_dialect,
                .disable_prompt_cache = self.config.disable_prompt_cache,
                .is_reasoning_model = self.config.is_reasoning_model,
            },
            .messages = messages,
            .tools_json = self.tools_json,
        };
        const env: stream_part.StreamEnv = .{
            .limits = .{ .max_parallel_calls = self.config.max_parallel_tool_calls, .model_label = self.config.model },
            .id_seq = &self.tool_call_seq,
        };
        return self.transport.prompt(transport_mod.payloadSource(ChatPayload, &payload), observer, stream_parser, env);
    }

    const ChatPayload = struct {
        gpa: std.mem.Allocator,
        opts: openai_request.PayloadOptions,
        messages: []const ai.MessageView,
        tools_json: []const u8,

        pub fn writePayload(self: *ChatPayload, out: *std.Io.Writer, disable_prompt_cache: bool) !void {
            self.opts.disable_prompt_cache = disable_prompt_cache;
            return openai_request.writeRequestPayload(self.gpa, out, self.opts.model, self.opts.session_id, self.messages, self.tools_json, self.opts.reasoning, self.opts.max_output_tokens, self.opts.dialect, self.opts.disable_prompt_cache, self.opts.is_reasoning_model);
        }

        pub fn isToolLess(self: *ChatPayload) bool {
            return std.mem.eql(u8, self.tools_json, "[]");
        }
    };
};

test "Client.init rejects an empty base_url with EmptyBaseUrl" {
    // A missing base_url is a config error, not a programming precondition —
    // the guard must be a real early return (it survives into ReleaseFast,
    // where `std.debug.assert` would be UB).
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try std.testing.expectError(error.EmptyBaseUrl, client.init(gpa, std.testing.io, .{
        .base_url = "",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
    }));
}

test "Client.init rejects an empty model id with EmptyModelId" {
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try std.testing.expectError(error.EmptyModelId, client.init(gpa, std.testing.io, .{
        .base_url = "http://localhost:8080/v1",
        .api_key = "test-key",
        .model = "",
        .tools = &.{},
        .mcp_tools = &.{},
    }));
}

test "buildToolsJson produces a valid JSON array for the registry" {
    const tools = @import("../tools.zig");
    const gpa = std.testing.allocator;
    const json = try tool_schema.buildAllToolsJson(gpa, tools.builtinRegistry(), &.{}, null, true, .completions);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    // The builtin shell tool is `pwsh` on Windows and `bash` elsewhere; build the
    // expected "name" dynamically from the canonical `shellToolName` so the
    // assertion holds on both hosts.
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools.shellToolName});
    defer gpa.free(shell_name);
    try std.testing.expect(std.mem.indexOf(u8, json, shell_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Shell command to run.") != null);
}

test "buildToolsJson substitutes {{hsep}} placeholders with ~" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "uses {{hsep}} marker",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .completions);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "uses ~ marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{{hsep}}") == null);
}

test "buildAllToolsJson includes MCP tools alongside builtin tools" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const mcp_tools = [_]ai.McpToolSchema{
        .{
            .name = "mcp__server__greet",
            .description = "Say hello",
            .schema = .{ .properties = &.{} },
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &mcp_tools, null, false, .completions);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"mcp__server__greet\"") != null);
}

test "buildAllToolsJson via updateMcpTools: registry builtin suppresses duplicate shell" {
    // Regression: the tick-driven `injectAllTools` path used to call
    // `updateMcpTools(mcp_tools, registry)` without an override, so
    // `buildAllToolsJson` would emit the shell tool twice — once from
    // `self.config.tools` and again from `r.all.builtin`. Most
    // OpenAI-compatible APIs reject duplicate tool names with HTTP 400,
    // dropping the entire tool list including the plugin tools.
    const gpa = std.testing.allocator;

    // The builtin shell name is `pwsh` on Windows and `bash` elsewhere — build
    // the occurrence scan off the canonical `shellToolName` so the "exactly one,
    // no duplicate" invariant holds on both hosts.
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_name);

    // Build a minimal Client with just a shell builtin in `config.tools`.
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer client.deinit();

    // Build a registry with a plugin tool; its builtin is the shell tool too.
    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());
    // Ownership of `plugin_name` and `plugin_desc` transfers to the
    // registry via addPluginTool; registry.deinit frees them.
    const plugin_name = try gpa.dupe(u8, "lua__p__t");
    const plugin_desc = try gpa.dupe(u8, "plugin tool");
    try reg.addPluginTool(gpa, .{
        .name = plugin_name,
        .description = plugin_desc,
        .schema = .{ .properties = &.{} },
        .run = undefined,
        .display = undefined,
    });

    // Mirror the runtime's assembleToolSpecs: registry records only (the
    // registry's builtin slice already covers the shell tool).
    var specs: std.ArrayList(tool_schema.ToolSpec) = .empty;
    defer specs.deinit(gpa);
    const reg_slice = try reg.all(gpa);
    for (reg_slice) |t| try specs.append(gpa, tool_schema.specFromTool(t));
    try client.updateTools(specs.items);

    const json = client.tools_json;
    var first: ?usize = null;
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, idx, shell_name)) |pos| {
        if (first == null) first = pos;
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__p__t\"") != null);
}

test "updateMcpTools propagates plugin tools into tools_json end-to-end" {
    // End-to-end regression for the user-reported "plugin tools not
    // visible to AI" bug. We simulate the exact call site:
    //   attachOpenAiCompatibleClient → injectPluginTools → injectAllTools →
    //   runtime.client.updateMcpTools(mcp_schemas, registry, &.{}).
    // After the call, `client.tools_json` must contain every plugin
    // tool's name so the next prompt includes them.
    const gpa = std.testing.allocator;

    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer client.deinit();

    // Build a registry carrying two plugin tools, exactly the way
    // registerPluginTools would after initRuntime runs.
    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());

    for ([_][]const u8{ "lua__hello-world__greet", "lua__hello-world__current_time" }) |tool_name| {
        const owned_name = try gpa.dupe(u8, tool_name);
        const owned_desc = try gpa.dupe(u8, "test");
        try reg.addPluginTool(gpa, .{
            .name = owned_name,
            .description = owned_desc,
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        });
    }

    // The exact call shape from injectAllTools (specs = registry records).
    var specs: std.ArrayList(tool_schema.ToolSpec) = .empty;
    defer specs.deinit(gpa);
    const reg_slice = try reg.all(gpa);
    for (reg_slice) |t| try specs.append(gpa, tool_schema.specFromTool(t));
    try client.updateTools(specs.items);

    const json = client.tools_json;
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_name);
    try std.testing.expect(std.mem.indexOf(u8, json, shell_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lane\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"background\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__hello-world__greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__hello-world__current_time\"") != null);

    // And the count of name occurrences must be exactly 6 (4 builtins + 2 plugin tools).
    var name_count: usize = 0;
    var scan_idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, scan_idx, "\"name\":\"")) |pos| {
        name_count += 1;
        scan_idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 6), name_count);
}

test "buildToolsJson emits strict schema with nullable union types for optional fields" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "Demo tool with mixed required/optional fields",
            .schema = .{
                .properties = &.{
                    .{ .name = "required_str", .kind = .string, .description = "Required string", .required = true, .nullable = false },
                    .{ .name = "optional_str", .kind = .string, .description = "Optional string", .required = false, .nullable = true },
                    .{ .name = "optional_int", .kind = .integer, .description = "Optional int", .required = false, .nullable = true },
                    .{ .name = "optional_bool", .kind = .boolean, .description = "Optional bool", .required = false, .nullable = true },
                    .{ .name = "optional_obj", .kind = .object, .description = "Optional object", .required = false, .nullable = true },
                    .{ .name = "optional_arr", .kind = .array, .description = "Optional array", .required = false, .nullable = true },
                    .{ .name = "non_nullable_str", .kind = .string, .description = "Non-nullable string", .required = true, .nullable = false },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .completions);
    defer gpa.free(json);

    // Top-level strict marker and top-level additionalProperties:false
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);

    // Non-nullable required field stays as a single type string
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required_str\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_nullable_str\":{\"type\":\"string\"") != null);

    // Nullable optional fields become union type arrays
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\":{\"type\":[\"string\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\":{\"type\":[\"integer\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_bool\":{\"type\":[\"boolean\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_obj\":{\"type\":[\"object\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_arr\":{\"type\":[\"array\",\"null\"]") != null);

    // Nested object keeps additionalProperties:true for free-form keys
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":true") != null);

    // Required array includes ALL properties for strict mode compliance.
    // Optional fields are marked nullable so the model knows they can be absent.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"required_str\",\"optional_str\",\"optional_int\",\"optional_bool\",\"optional_obj\",\"optional_arr\",\"non_nullable_str\"]") != null);
    // Optional fields appear in properties.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_bool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_obj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_arr\"") != null);
}

test "buildToolsJson omits strict mode and filters required when strict is false (gateway compatibility)" {
    // Regression for the "model emits tool calls as plain text" bug:
    // gateways (OpenRouter/Ollama/vLLM) reject or silently break OpenAI
    // strict structured-outputs mode, which disables function-calling.
    // With strict=false the schema must (a) NOT carry "strict":true and
    // (b) list only genuinely-required properties in `required`.
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "Demo",
            .schema = .{
                .properties = &.{
                    .{ .name = "required_str", .kind = .string, .description = "Required", .required = true, .nullable = false },
                    .{ .name = "optional_str", .kind = .string, .description = "Optional", .required = false, .nullable = true },
                    .{ .name = "optional_int", .kind = .integer, .description = "Optional", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .completions);
    defer gpa.free(json);

    // No strict marker.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\"") == null);
    // Only the required property is required — optionals stay optional.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"required_str\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "optional_str") != null);
    // Optionals still listed in properties (nullable unions preserved).
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\":{\"type\":[\"string\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\":{\"type\":[\"integer\",\"null\"]") != null);
    // Empty `required` (no required props) is still valid JSON.
    const no_required_tools = [_]tools_common.Tool{
        .{
            .name = "noargs",
            .description = "No args",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const json2 = try tool_schema.buildAllToolsJson(gpa, &no_required_tools, &.{}, null, false, .completions);
    defer gpa.free(json2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"required\":[]") != null);
}

test "buildToolsJson preserves nested object additionalProperties for free-form env" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{
                .properties = &.{
                    .{ .name = "command", .kind = .string, .description = "Shell command", .required = true, .nullable = false },
                    .{ .name = "env", .kind = .object, .description = "Env vars", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .completions);
    defer gpa.free(json);

    // Top-level parameters object is strict
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parameters\":{\"type\":\"object\",\"additionalProperties\":false") != null);
    // Nested env object remains free-form
    try std.testing.expect(std.mem.indexOf(u8, json, "\"env\":{\"type\":[\"object\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":true") != null);
}

test "updateMcpTools rebuilds the serialized tool list in place" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://localhost:8080/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &tools,
        .mcp_tools = &.{},
    });
    defer client.deinit();

    // No MCP tools yet — only the builtin "bash" is serialized.
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "mcp__tavily__search") == null);

    // Injecting an MCP tool set must add it alongside the builtin tool.
    const mcp_tools = [_]tool_schema.ToolSpec{
        .{ .name = "mcp__tavily__search", .description = "Search the web", .schema = .{ .properties = &.{} } },
    };
    var with_mcp: std.ArrayList(tool_schema.ToolSpec) = .empty;
    defer with_mcp.deinit(gpa);
    for (tools_mod.builtinRegistry()) |t| try with_mcp.append(gpa, tool_schema.specFromTool(t));
    try with_mcp.appendSlice(gpa, &mcp_tools);
    try client.updateTools(with_mcp.items);
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_name);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, shell_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "\"name\":\"mcp__tavily__search\"") != null);

    // Replacing with an empty set removes the MCP tool but keeps the builtin.
    var builtin_only: std.ArrayList(tool_schema.ToolSpec) = .empty;
    defer builtin_only.deinit(gpa);
    for (tools_mod.builtinRegistry()) |t| try builtin_only.append(gpa, tool_schema.specFromTool(t));
    try client.updateTools(builtin_only.items);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "mcp__tavily__search") == null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, shell_name) != null);
}

test "writeRequestPayload ships the full tools array for OpenRouter byte-for-byte" {
    // Tersine mühendislik yerine servis katmanını uçtan uca çalıştırıp, gerçek
    // wire payload'ı üretir ve OpenRouter'a giden `tools` array'inin log
    // truncation'ına takılmadan tam doğruluğunu (hiçbir tool düşmeden, tam
    // byte-for-byte) kanıtlar. Payload `writeRequestPayload` tarafından tek
    // parça üretilir — `logBytes` yalnızca loglama için kırpar, test ham byte'ı
    // olduğu gibi alır.
    const gpa = std.testing.allocator;

    // Registry: builtin (bash, lane) + plugin tools, aynen üretimdeki gibi.
    var registry = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());
    defer registry.deinit(gpa);
    const plugin_names = [_][]const u8{
        "lua__file-tools__read",        "lua__file-tools__write",        "lua__file-tools__edit",
        "lua__search-tools__grep",      "lua__search-tools__glob",       "lua__path-tools__create_directory",
        "lua__path-tools__delete_path", "lua__git-tools__git_status",    "lua__git-tools__git_diff",
        "lua__git-tools__git_commit",   "lua__todo__todo_list",          "lua__todo__todo_add",
        "lua__todo__todo_done",         "lua__file-watcher__file_stats", "lua__hello-world__greet",
    };
    for (plugin_names) |name| {
        try registry.addPluginTool(gpa, .{
            .name = try gpa.dupe(u8, name),
            .description = try std.fmt.allocPrint(gpa, "Plugin tool {{hsep}} for {s}", .{name}),
            .schema = .{
                .properties = &.{
                    .{ .name = "path", .kind = .string, .description = "A path", .required = true, .nullable = false },
                    .{ .name = "recursive", .kind = .boolean, .description = "Recurse", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        });
    }
    const mcp_tools = [_]ai.McpToolSchema{
        .{ .name = "mcp__tavily__search", .description = "Web search", .schema = .{ .properties = &.{} } },
        .{ .name = "mcp__chrome-devtools__click", .description = "Click element", .schema = .{ .properties = &.{} } },
    };

    // Tools array'i servis katmanıyla, OpenRouter'ın gerçekte aldığı biçimde üret.
    const tools_json = try tool_schema.buildAllToolsJson(gpa, &.{}, &mcp_tools, &registry, false, .completions);
    defer gpa.free(tools_json);

    // Full wire payload — writeRequestPayload applies no truncation. Include a
    // system message so OpenRouter's top-level cache_control is emitted.
    const system_blocks = try gpa.alloc(ai.ContentBlock, 1);
    system_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "You are a helpful agent.") } };
    var system_msg: ai.ChatMessage = .{ .system = .{ .content = system_blocks } };
    defer system_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &system_msg }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "inclusionai/ling-3.0-flash:free", "session-abc", &views, tools_json, null, null, .openrouter, false, false);
    const body = payload.written();

    // Payload gerçekten JSON parse edilebilir olmalı (kırpılmamış, geçerli).
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    // 1. OpenRouter dialect'i: top-level cache_control + native session_id.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"session_id\":\"session-abc\"") != null);

    // 2. tools array'i tam ve kırpılmamış — üretilen byte'larla birebir aynı.
    const tools_str = try std.fmt.allocPrint(gpa, "\"tools\":{s}", .{tools_json});
    defer gpa.free(tools_str);
    try std.testing.expect(std.mem.indexOf(u8, body, tools_str) != null);
    try std.testing.expectEqual(@as(usize, tools_mod.builtinRegistry().len + plugin_names.len + mcp_tools.len), countWireTools(tools_json));

    // 3. tool_choice auto (tools varken) + stream true.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

fn countWireTools(tools_json: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, tools_json, idx, "\"type\":\"function\"")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    return count;
}

test "ollama_cloud(minimal) vs openrouter dialect: identical tools array, only cache fields differ" {
    // Kullanıcının gözlemi: ollama_cloud üzerindeki temel bir model (gemma4:31b)
    // tool çağırabiliyor ama openrouter'daki ling-3.0-flash çağıramıyor. Dialect
    // farkının tools array'ini ETKİLEMEDİĞİNİ kanıtlar — ikisi de aynı `tools`
    // array'ini üretir; tek fark OpenRouter'ın eklediği cache_control /
    // prompt_cache_key alanlarıdır. Yani tool çağıramama sorunu dialect'ten
    // değil, modelin kendisinden gelir.
    const gpa = std.testing.allocator;

    // Aynı tool seti, her iki dialect için.
    var registry = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());
    defer registry.deinit(gpa);
    try registry.addPluginTool(gpa, .{
        .name = try gpa.dupe(u8, "lua__file-tools__read"),
        .description = try gpa.dupe(u8, "Read a file"),
        .schema = .{ .properties = &.{.{ .name = "path", .kind = .string, .description = "A path", .required = true, .nullable = false }} },
        .run = undefined,
        .display = undefined,
    });
    const mcp_tools = [_]ai.McpToolSchema{
        .{ .name = "mcp__tavily__search", .description = "Web search", .schema = .{ .properties = &.{} } },
    };
    const tools_json = try tool_schema.buildAllToolsJson(gpa, &.{}, &mcp_tools, &registry, false, .completions);
    defer gpa.free(tools_json);

    const system_blocks = try gpa.alloc(ai.ContentBlock, 1);
    system_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "You are a helpful agent.") } };
    var system_msg: ai.ChatMessage = .{ .system = .{ .content = system_blocks } };
    defer system_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &system_msg }};

    // .minimal = ollama_cloud'ın çözümü; .openrouter = openrouter'ın çözümü.
    var payload_min: std.Io.Writer.Allocating = .init(gpa);
    defer payload_min.deinit();
    try writeRequestPayload(gpa, &payload_min.writer, "gemma4:31b", "", &views, tools_json, null, null, .minimal, false, false);
    const body_min = payload_min.written();

    var payload_or: std.Io.Writer.Allocating = .init(gpa);
    defer payload_or.deinit();
    try writeRequestPayload(gpa, &payload_or.writer, "inclusionai/ling-3.0-flash:free", "sess", &views, tools_json, null, null, .openrouter, false, false);
    const body_or = payload_or.written();

    // 1. tools array'i İKİSİNDE DE aynıdır — byte-for-byte.
    const tools_needle = try std.fmt.allocPrint(gpa, "\"tools\":{s}", .{tools_json});
    defer gpa.free(tools_needle);
    try std.testing.expect(std.mem.indexOf(u8, body_min, tools_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, tools_needle) != null);
    try std.testing.expectEqual(countWireTools(tools_json), tools_mod.builtinRegistry().len + 1 + mcp_tools.len);

    // 2. tool_choice auto her ikisinde de var (tools varken).
    try std.testing.expect(std.mem.indexOf(u8, body_min, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, "\"tool_choice\":\"auto\"") != null);

    // 3. TEK fark: openrouter, top-level cache_control + native session_id
    //    ekler; minimal bunları hiç üretmez.
    try std.testing.expect(std.mem.indexOf(u8, body_min, "cache_control") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_min, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_min, "prompt_cache_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, "\"session_id\":\"sess\"") != null);
}

// Ollama (or any generic gateway) can serve Qwen models; the provider resolves to
// `.minimal`, not `.dashscope`. The Qwen gate must still normalize the history so
// Qwen does not reject multiple/late system messages. This mirrors running a
// `qwen2.5:7b` model through a local ollama instance.
test "writeRequestPayload normalizes system messages for qwen model on minimal dialect" {
    const gpa = std.testing.allocator;

    const sys1 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_A") } }}) } };
    const user = ai.ChatMessage{ .user = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "hi") } }}) } };
    const sys2 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_B") } }}) } };
    var chat_messages = [_]ai.ChatMessage{ sys1, user, sys2 };
    var views: [chat_messages.len]ai.MessageView = undefined;
    for (&chat_messages, 0..) |*m, i| views[i] = ai.MessageView{ .borrowed = @ptrCast(@constCast(m)) };
    const messages = views[0..];
    defer {
        for (&chat_messages) |*m| m.deinit(gpa);
    }

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    // minimal dialect + a qwen* model id → normalization must fire.
    try writeRequestPayload(gpa, &payload.writer, "qwen2.5:7b", "", messages, "[]", null, null, .minimal, false, false);
    const body = payload.written();

    // Exactly one system message, and it is the merged leading block.
    const sys_count = countSubstring(body, "\"role\":\"system\"");
    try std.testing.expectEqual(@as(usize, 1), sys_count);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SYS_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SYS_B") != null);
    // system must precede the user message.
    const sys_idx = std.mem.indexOf(u8, body, "\"role\":\"system\"").?;
    const user_idx = std.mem.indexOf(u8, body, "\"role\":\"user\"").?;
    try std.testing.expect(sys_idx < user_idx);
}

// The exact scenario from vllm-project/vllm#41114: a vLLM server hosting a
// HuggingFace-style `Qwen/Qwen3-32B` id. The provider is a generic
// OpenAI-compatible URL (resolves to `.minimal`), and the model id starts with
// a capitalized `Qwen/` — so both the history normalization AND the effort clip
// must key off the case-insensitive model-id gate, not the dialect alone.
test "writeRequestPayload normalizes system messages and clips effort for vLLM-style Qwen id" {
    const gpa = std.testing.allocator;

    const sys1 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_A") } }}) } };
    const user = ai.ChatMessage{ .user = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "hi") } }}) } };
    const sys2 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_B") } }}) } };
    var chat_messages = [_]ai.ChatMessage{ sys1, user, sys2 };
    var views: [chat_messages.len]ai.MessageView = undefined;
    for (&chat_messages, 0..) |*m, i| views[i] = ai.MessageView{ .borrowed = @ptrCast(@constCast(m)) };
    const messages = views[0..];
    defer {
        for (&chat_messages) |*m| m.deinit(gpa);
    }

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "Qwen/Qwen3-32B", "", messages, "[]", ai.Reasoning{ .effort = .high }, null, .minimal, false, false);
    const body = payload.written();

    // Single leading merged system block. The join newline is JSON-escaped in
    // the payload, so assert the escaped two-character `\n` sequence.
    try std.testing.expectEqual(@as(usize, 1), countSubstring(body, "\"role\":\"system\""));
    try std.testing.expect(std.mem.indexOf(u8, body, "SYS_A\\nSYS_B") != null);
    // `high` is invalid for Qwen — clipped to `medium` even on the `.minimal`
    // dialect (dialect passes it through, the model layer clips it).
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
}

fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (std.mem.indexOf(u8, haystack[i..], needle)) |idx| {
            count += 1;
            i += idx;
        } else break;
    }
    return count;
}

test "readStream accepts an SSE line larger than the transfer buffer" {
    const gpa = std.testing.allocator;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);

    try stream.appendSlice(gpa, "data: {\"choices\":[{\"delta\":{\"content\":\"");
    var index: u32 = 0;
    while (index < transfer_buffer_bytes + 512) : (index += 1) try stream.append(gpa, 'a');
    try stream.appendSlice(gpa, "\"}}]}\n");
    try stream.appendSlice(gpa, "data: [DONE]\n");

    var reader: std.Io.Reader = .fixed(stream.items);
    var tool_call_seq: u64 = 0;
    var response = try stream_parser.readStream(gpa, &reader, ai.streamNoop(), .{ .limits = .{ .max_parallel_calls = 16, .model_label = "test-model" }, .id_seq = &tool_call_seq });
    defer response.deinit(gpa);
    try std.testing.expectEqual(@as(usize, transfer_buffer_bytes + 512), response.assistant.assistant.content[0].text.text.len);
}

test "readStream skips empty data lines without crashing" {
    const gpa = std.testing.allocator;
    // An empty `data:` keep-alive used to hit `parseStreamChunk`'s non-empty
    // assertion and panic the TUI mid-turn.
    const stream =
        "data:\n" ++
        "data: \n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
        "data: [DONE]\n";
    var reader: std.Io.Reader = .fixed(stream);
    var tool_call_seq: u64 = 0;
    var response = try stream_parser.readStream(gpa, &reader, ai.streamNoop(), .{ .limits = .{ .max_parallel_calls = 16, .model_label = "test-model" }, .id_seq = &tool_call_seq });
    defer response.deinit(gpa);
    try std.testing.expectEqualStrings("hi", response.assistant.assistant.content[0].text.text);
}

test "parse streaming content tolerates null prelude" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}]}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.empty());
    try std.testing.expectEqual(@as(usize, 0), content.items.len);
    try std.testing.expectEqual(@as(usize, 0), reasoning.items.len);
}

test "parse streaming tool deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
        index: u32 = 0,

        fn onToolDelta(ctx: *@This(), delta: ai.ToolDelta) anyerror!void {
            ctx.index = delta.index;
            ctx.name = delta.name;
            ctx.arguments = delta.arguments;
        }
    };
    var seen: Seen = .{};
    var observer = ai.noopObserver(Seen, &seen);
    observer.on_tool_delta = Seen.onToolDelta;

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"zig"}}]}}]}
    , &content, &reasoning, &stream, observer);
    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" build\"}"}}]}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("bash", seen.name);
    try std.testing.expectEqualStrings("{\"command\":\"zig build\"}", seen.arguments);
    try std.testing.expectEqual(@as(u32, 0), seen.index);
}

test "parse streaming tool deltas tolerate key reorder" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"function":{"name":"bash","arguments":"{}"},"id":"call_1","index":0}]}}]}
    , &content, &reasoning, &stream, ai.streamNoop());

    try std.testing.expectEqual(@as(usize, 1), stream.builders.items.len);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("{}", stream.builders.items[0].arguments.items);
}

test "parse streaming tool deltas batches render notification per event" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        tool_delta_count: u32 = 0,
        render_count: u32 = 0,

        fn onToolDelta(ctx: *@This(), _: ai.ToolDelta) anyerror!void {
            ctx.tool_delta_count += 1;
        }

        fn onDeltaEnd(ctx: *@This()) anyerror!void {
            ctx.render_count += 1;
        }
    };
    var seen: Seen = .{};
    var observer = ai.noopObserver(Seen, &seen);
    observer.on_tool_delta = Seen.onToolDelta;
    observer.on_delta_end = Seen.onDeltaEnd;

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}},{"index":1,"id":"call_2","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqual(@as(u32, 2), seen.tool_delta_count);
    try std.testing.expectEqual(@as(u32, 1), seen.render_count);
}

test "parse streaming reasoning deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        gpa: std.mem.Allocator,
        reasoning: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.reasoning.deinit(self.gpa);
        }

        fn onReasoning(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.reasoning.appendSlice(ctx.gpa, delta);
        }
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    var observer = ai.noopObserver(Seen, &seen);
    observer.on_reasoning = Seen.onReasoning;

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"reasoning_content":"checking output"}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("checking output", seen.reasoning.items);
    try std.testing.expectEqualStrings("checking output", reasoning.items);
}

test "parse streaming content deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        gpa: std.mem.Allocator,
        content: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.content.deinit(self.gpa);
        }

        fn onContent(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.content.appendSlice(ctx.gpa, delta);
        }
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    var observer = ai.noopObserver(Seen, &seen);
    observer.on_content = Seen.onContent;

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hel"}}]}
    , &content, &reasoning, &stream, observer);
    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"lo"}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("hello", seen.content.items);
    try std.testing.expectEqualStrings("hello", content.items);
}

test "parse streaming usage chunk" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":340,"total_tokens":1540}}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage != null);
    try std.testing.expectEqual(@as(u32, 1200), change.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 340), change.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 1540), change.usage.?.total_tokens);
}

test "parse streaming usage chunk captures cached and reasoning token details" {
    // The chat-completions parser must populate the same cached/reasoning
    // breakdown the Responses API parser does, so both wire dialects report
    // `ai.Usage` consistently (mirrors the openai-compatible provider's
    // `prompt_tokens_details.cached_tokens` / `completion_tokens_details.reasoning_tokens`).
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[],"usage":{"prompt_tokens":2000,"prompt_tokens_details":{"cached_tokens":1500},"completion_tokens":420,"completion_tokens_details":{"reasoning_tokens":256},"total_tokens":2420}}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage != null);
    try std.testing.expectEqual(@as(u32, 2000), change.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 1500), change.usage.?.cached_input_tokens);
    try std.testing.expectEqual(@as(u32, 420), change.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 256), change.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 2420), change.usage.?.total_tokens);
}

test "content chunk carries null usage" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hi"}}],"usage":null}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage == null);
}

test "parse streaming usage tolerates null token details sub-objects" {
    // Some providers send `prompt_tokens_details: null` / `completion_tokens_details: null`
    // (the openai-compatible schema marks them nullish). The parser must not
    // fail the whole stream on a null nested object.
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[],"usage":{"prompt_tokens":100,"prompt_tokens_details":null,"completion_tokens":50,"completion_tokens_details":null,"total_tokens":150}}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage != null);
    try std.testing.expectEqual(@as(u32, 100), change.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 0), change.usage.?.cached_input_tokens);
    try std.testing.expectEqual(@as(u32, 0), change.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 150), change.usage.?.total_tokens);
}

test "parse streaming tool calls deduplicates repeated tool names (bashbash fix)" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":"}}]}}]}
    , &content, &reasoning, &stream);

    // Second chunk repeats function.name: "bash" while sending argument continuation
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream);

    try std.testing.expectEqual(@as(usize, 1), stream.builders.items.len);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream.builders.items[0].arguments.items);
}

test "sanitizeToolArguments strips markdown backticks and falls back to empty object" {
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments(""));
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments("   "));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream_parser.sanitizeToolArguments("{\"command\":\"ls\"}"));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream_parser.sanitizeToolArguments("```json\n{\"command\":\"ls\"}\n```"));
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments("not a json string"));
}

test "parse streaming parallel tool calls with reused index does not concatenate names" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    // Provider emits two parallel tool calls in separate SSE events, both
    // with index 0 (a known misbehaviour from some OpenAI-compatible providers).
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"mcp__server__get_architecture","arguments":"{}"}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","function":{"name":"mcp__server__search_graph","arguments":"{}"}}]}}]}
    , &content, &reasoning, &stream);

    // Queue mechanism forks the second tool call into a new physical slot.
    // Both tool calls are preserved — names must NOT be concatenated.
    try std.testing.expectEqual(@as(usize, 2), stream.builders.items.len);
    try std.testing.expectEqualStrings("mcp__server__get_architecture", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("mcp__server__search_graph", stream.builders.items[1].name.items);
    try std.testing.expectEqualStrings("call_2", stream.builders.items[1].id.items);
}

test "parse streaming duplicate ID across indices merges into one builder" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    // Qwen/DashScope echoes the same tool-call ID across multiple indices.
    // The first chunk carries the name at index 0; a duplicate arrives at
    // index 1 with the same ID. Arguments follow on index 0.
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":""}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_1","function":{"name":"bash","arguments":""}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream);

    // Index 1 is remapped to the same physical slot as index 0.
    // Only one builder should carry the name + arguments.
    var with_args: usize = 0;
    for (stream.builders.items) |b| {
        if (b.name.items.len > 0 and b.arguments.items.len > 0) with_args += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), with_args);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream.builders.items[0].arguments.items);
}

// ── Retry / backoff ───────────────────────────────────────────────────────

test "retryDelayMs honors Retry-After over backoff and caps exponential growth" {
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://127.0.0.1:1/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
    });
    defer client.deinit();

    // Retry-After wins regardless of the attempt count.
    try std.testing.expectEqual(@as(u64, 3000), http.retryDelayMs(500, 0, 3));
    try std.testing.expectEqual(@as(u64, 3000), http.retryDelayMs(500, 5, 3));
    // Without the header: base * 2^attempt, capped at 8000ms.
    try std.testing.expectEqual(@as(u64, 500), http.retryDelayMs(500, 0, null));
    try std.testing.expectEqual(@as(u64, 1000), http.retryDelayMs(500, 1, null));
    try std.testing.expectEqual(@as(u64, 2000), http.retryDelayMs(500, 2, null));
    try std.testing.expectEqual(@as(u64, 4000), http.retryDelayMs(500, 3, null));
    try std.testing.expectEqual(@as(u64, 8000), http.retryDelayMs(500, 4, null)); // capped
    try std.testing.expectEqual(@as(u64, 8000), http.retryDelayMs(500, 10, null)); // stays capped
}

/// Minimal blocking HTTP server for retry tests. Serves exactly one canned
/// response per accepted connection (each `Connection: close`), on a
/// dedicated thread. The ephemeral port comes from `server.socket.address`.
const MockRetryServer = struct {
    const Response = struct {
        status: std.http.Status,
        retry_after: ?[]const u8 = null,
        body: []const u8 = "",
        // When true, `body` is gzip-compressed and served with
        // `Content-Encoding: gzip` — exercises the decompressing reader.
        gzip: bool = false,
    };

    io: std.Io,
    server: std.Io.net.Server,
    responses: []const Response,
    connection_count: std.atomic.Value(u32) = .init(0),

    fn init(io: std.Io, responses: []const Response) !MockRetryServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .server = server, .responses = responses };
    }

    fn deinit(self: *MockRetryServer) void {
        self.server.deinit(self.io);
    }

    fn port(self: *const MockRetryServer) u16 {
        return self.server.socket.address.ip4.port;
    }

    fn serve(self: *MockRetryServer) void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        for (self.responses) |resp| {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            _ = self.connection_count.fetchAdd(1, .monotonic);
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch return;
            var extra: [2]std.http.Header = undefined;
            var extra_count: usize = 0;
            if (resp.retry_after) |ra| {
                extra[extra_count] = .{ .name = "Retry-After", .value = ra };
                extra_count += 1;
            }
            if (resp.gzip) {
                extra[extra_count] = .{ .name = "Content-Encoding", .value = "gzip" };
                extra_count += 1;
            }
            const headers = extra[0..extra_count];
            request.respond(resp.body, .{
                .status = resp.status,
                .keep_alive = false,
                .extra_headers = headers,
            }) catch return;
        }
    }
};

const ok_sse_body =
    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
    "data: [DONE]\n";

fn retryTestClient(gpa: std.mem.Allocator, io: std.Io, port: u16) !Client {
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{port});
    errdefer gpa.free(base_url);
    var client: Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        // No sleeping between retries in tests.
        .retry_base_delay_ms = 0,
    });
    // `init` deep-copies the config (including the request URL) — the
    // temporary base_url is not retained, so free it.
    gpa.free(base_url);
    return client;
}

test "prompt retries a transient 503 and succeeds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .service_unavailable },
        .{ .status = .ok, .body = ok_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    // Two connections: the failed 503 attempt plus the successful retry.
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
    try std.testing.expectEqualStrings("hi", turn.assistant.assistant.content[0].text.text);
}

test "prompt retries a 429 and honors Retry-After" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .too_many_requests, .retry_after = "0" },
        .{ .status = .ok, .body = ok_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
    try std.testing.expectEqualStrings("hi", turn.assistant.assistant.content[0].text.text);
}

test "prompt does not retry a permanent 4xx" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .bad_request },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    // Exactly one attempt — 4xx is permanent.
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt with max_retries 0 makes a single attempt on a transient 5xx" {
    // Kill-switch regression: max_retries = 0 must reproduce the legacy
    // single-attempt behavior even for otherwise-retryable 5xx errors.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .internal_server_error },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .max_retries = 0,
    });
    defer client.deinit();

    try std.testing.expectError(error.HttpServerError, client.prompt(&.{}, ai.streamNoop()));
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt exhausts retries on a persistent 5xx" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Default max_retries = 2 → three attempts total.
    var server = try MockRetryServer.init(io, &.{
        .{ .status = .internal_server_error },
        .{ .status = .internal_server_error },
        .{ .status = .internal_server_error },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.HttpServerError, client.prompt(&.{}, ai.streamNoop()));
    try std.testing.expectEqual(@as(u32, 3), server.connection_count.load(.monotonic));
}

test "prompt decompresses a Content-Encoding: gzip error body into the UI detail" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // gzip stream of `{"error":{"message":"invalid api key"}}`.
    // Without the decompressing reader the toaster logs the raw compressed
    // bytes (the `body=����...` garbage) instead of the JSON message.
    const gzipped = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x04, 0x4b, 0x8f, 0x6a, 0x02, 0xff, 0xab, 0x56,
        0x4a, 0x2d, 0x2a, 0xca, 0x2f, 0x52, 0xb2, 0xaa, 0x56, 0xca, 0x4d, 0x2d,
        0x2e, 0x4e, 0x4c, 0x4f, 0x55, 0xb2, 0x52, 0xca, 0xcc, 0x2b, 0x4b, 0xcc,
        0xc9, 0x4c, 0x51, 0x48, 0x2c, 0xc8, 0x54, 0xc8, 0x4e, 0xad, 0x54, 0xaa,
        0xad, 0x05, 0x00, 0xaf, 0xdd, 0xf6, 0x03, 0x27, 0x00, 0x00, 0x00,
    };

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .forbidden, .body = &gzipped, .gzip = true },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.errorDetail() orelse @panic("expected a recorded error detail");
    try std.testing.expectEqualStrings("HTTP 403: invalid api key", detail);
}

/// Mock server that sends a valid HTTP 200 head with chunked transfer-encoding,
/// sends partial SSE data, then closes abruptly without [DONE]. Used to test
/// stream-phase ReadFailed capture.
const MockAbortServer = struct {
    srv_io: std.Io,
    server: std.Io.net.Server,

    fn init(srv_io: std.Io) !MockAbortServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const srv = try addr.listen(srv_io, .{ .reuse_address = true });
        return .{ .srv_io = srv_io, .server = srv };
    }

    fn deinit(self: *MockAbortServer) void {
        self.server.deinit(self.srv_io);
    }

    fn port(self: *const MockAbortServer) u16 {
        return self.server.socket.address.ip4.port;
    }

    fn serve(self: *MockAbortServer) void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var stream = self.server.accept(self.srv_io) catch return;
        defer stream.close(self.srv_io);
        var reader = stream.reader(self.srv_io, &read_buf);
        var writer = stream.writer(self.srv_io, &write_buf);
        // Drain the FULL request (headers + chunked body through the terminal
        // `0\r\n\r\n`). `readSliceShort` blocks until its destination is
        // FULL — and this request is smaller than any fixed buffer we could
        // pick — so it must never be handed a larger destination here.
        // `fillMore` performs exactly one blocking read, then an
        // exactly-sized `readSliceShort` copies the buffered bytes out
        // without waiting for more. The client sends nothing after the
        // terminator (it blocks reading the response), so the loop ends
        // there and never hangs.
        var req_buf: [4096]u8 = undefined;
        var req_len: usize = 0;
        while (req_len < req_buf.len) {
            reader.interface.fillMore() catch break;
            const take = @min(reader.interface.bufferedLen(), req_buf.len - req_len);
            req_len += reader.interface.readSliceShort(req_buf[req_len..][0..take]) catch break;
            if (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") != null and
                std.mem.endsWith(u8, req_buf[0..req_len], "0\r\n\r\n")) break;
        }
        // Send a 200 OK response with chunked transfer-encoding.
        writer.interface.writeAll("HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n") catch return;
        // Send one chunk of SSE data.
        const chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n";
        var hex_buf: [16]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{chunk.len}) catch return;
        writer.interface.writeAll(hex) catch return;
        writer.interface.writeAll(chunk) catch return;
        writer.interface.writeAll("\r\n") catch return;
        // A malformed chunk header breaks the client's chunked decoder
        // mid-body — std maps that to a stream-phase `error.ReadFailed` with
        // `body_err` set. An abortive RST would mimic a real-world drop more
        // closely, but `Io.Threaded` hands out AFD handles on Windows, which
        // `setsockopt`(SO_LINGER) rejects — a protocol-level abort is the
        // portable way to exercise the same client capture path.
        writer.interface.writeAll("ZZ\r\n") catch return;
        writer.interface.flush() catch return;
    }
};

test "prompt records last_error_detail on stream-phase ReadFailed" {
    if (os.is_windows) {
        // Windows loopback close semantics: a server close after a partial
        // write does not surface as a client read error here, so the client
        // blocks (tests configure no socket timeout). Deferred with the
        // other host-gated variants (#32); the retry/C2/gzip socket suites
        // still run on Windows — only truncation semantics are gated out.
        return error.SkipZigTest;
    }
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockAbortServer.init(io);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockAbortServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.ReadFailed, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.errorDetail() orelse @panic("expected a recorded error detail on stream ReadFailed");
    try std.testing.expect(std.mem.startsWith(u8, detail, "Connection to the model provider was lost:"));
}
