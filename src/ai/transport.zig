//! Unified wire transport: the send pipeline shared by both LLM wire
//! clients (chat-completions and Responses). Owns request construction,
//! the retry budget, the one-shot C2 cache downgrade, head/error
//! classification, `Retry-After` capture, decompressed error-body reads,
//! and `last_error_detail` recording.
//!
//! Each wire client reduces to what genuinely differs:
//!   * a payload writer (`PayloadSource.writePayload`) — the wire protocol,
//!   * a stream adapter namespace (`comptime StreamAdapter` with `run`) —
//!     the SSE/event parser,
//!   * endpoint identity + header spec tables on the `Transport` itself.
//!
//! Behaviours that had drifted between the two former copies are unified
//! here deliberately: the C2 downgrade, `HttpRequestTruncated` head-phase
//! capture, the gzip error-body reader, and the tools-tail request log apply
//! to BOTH clients. Log lines are `log.info`/`log.warn` and are not pinned
//! by tests; the two user-facing detail formats ARE pinned:
//! `HTTP {d}: {s}` and `Connection to the model provider was lost: {s}`.

const std = @import("std");
const log = std.log.scoped(.wire_transport);

const ai = @import("../ai.zig");
const http = @import("../http.zig");
const provider_headers = @import("provider_headers.zig");
const stream_part = @import("stream_part.zig");

/// Upper bound on a decompressed error body read into memory for the UI
/// detail. Shared by both clients (was duplicated at 1 MiB each).
pub const response_bytes_max: u32 = 1 * 1024 * 1024;

const redirect_buffer_bytes = http.redirect_buffer_bytes;
const transfer_buffer_bytes = http.transfer_buffer_bytes;
const body_buffer_bytes = http.body_buffer_bytes;

/// Anything a wire client must supply per prompt call. `S` is the payload
/// writer (the wire protocol); `StreamAdapter` the parser namespace with
/// `pub fn run(gpa, reader, observer, env) !ai.Turn`.
///
/// Implemented by a small stack struct inside each client, so the C2
/// downgrade is "mutate one field, re-serialize once":
///
///     const ChatPayload = struct {
///         opts: openai_request.PayloadOptions,
///         messages: []const ai.MessageView,
///         tools_json: []const u8,
///         fn writePayload(self: *ChatPayload, out: *std.Io.Writer, disable_prompt_cache: bool) !void {
///             self.opts.disable_prompt_cache = disable_prompt_cache;
///             return openai_request.writePayload(self.gpa, out, self.opts, self.messages, self.tools_json);
///         }
///     };
pub const PayloadSource = struct {
    /// Serialize the full request body. `disable_prompt_cache` is the
    /// per-call value (C1 seed, possibly flipped by the C2 downgrade) — the
    /// writer must suppress every cache field when it is `true`.
    writePayload: *const fn (self: *anyopaque, out: *std.Io.Writer, disable_prompt_cache: bool) anyerror!void,
    context: *anyopaque,
    /// True when the client carries no tools; drives the `no_tools` info
    /// line next to the request log (main agent vs summarizer/naming).
    isToolLess: *const fn (self: *anyopaque) bool,
};

/// Type-erased `PayloadSource` constructor — wraps `S` by pointer.
pub fn payloadSource(comptime S: type, instance: *S) PayloadSource {
    const W = struct {
        fn write(ctx: *anyopaque, out: *std.Io.Writer, disable_prompt_cache: bool) anyerror!void {
            const s: *S = @ptrCast(@alignCast(ctx));
            return s.writePayload(out, disable_prompt_cache);
        }
        fn toolLess(ctx: *anyopaque) bool {
            const s: *S = @ptrCast(@alignCast(ctx));
            return s.isToolLess();
        }
    };
    return .{
        .writePayload = W.write,
        .context = @ptrCast(instance),
        .isToolLess = W.toolLess,
    };
}

pub const Transport = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    http_client: std.http.Client = undefined,

    // ── Endpoint identity (borrowed; the owning Client outlives every
    //    request). ──
    url: []const u8,
    /// null omits the Authorization header entirely (anonymous chat mode).
    authorization: ?[]const u8 = null,
    /// null = std default User-Agent.
    user_agent: ?[]const u8 = null,
    /// Transport-protocol profile header specs (e.g. the codex handshake
    /// table); appended FIRST so profile headers win collisions —
    /// `HeaderSet.append` is first-writer-wins. The provider (user + auto)
    /// table is appended after it.
    profile_headers: []const provider_headers.Header = &.{},
    provider_headers: []const provider_headers.Header = &.{},
    header_context: provider_headers.ValueContext = .{},

    // ── Logging identity (borrowed). ──
    /// e.g. "openai_compatible" | "responses" — prefixes every log line.
    log_tag: []const u8,
    /// Extra per-line context, e.g. the model id or the profile name.
    log_context: []const u8 = "",

    // ── Policy (from the client's ai.Config). ──
    request_timeout_seconds: u32 = 0,
    retry_base_delay_ms: u64 = 500,
    max_retries: u32 = 2,
    /// C1 seed: the user's `disable_prompt_cache` flag. The C2 downgrade may
    /// flip the per-request value on top; the seed itself never changes.
    disable_cache_seed: bool = false,

    /// Owned; freed in `deinit`. The de-facto error interface surfaced via
    /// the client's `errorDetail()`.
    last_error_detail: ?[]u8 = null,

    pub fn init(self: *Transport, gpa: std.mem.Allocator, io: std.Io) void {
        // Reset everything to safe defaults — the caller sets the borrowed
        // identity fields (url, headers, log tags, policy) AFTER this, but
        // owned state like `last_error_detail` must never stay undefined or
        // the first `clearErrorDetail` would free garbage.
        self.* = .{
            .gpa = gpa,
            .io = io,
            .http_client = .{ .allocator = gpa, .io = io },
            .url = "",
            .log_tag = "transport",
        };
    }

    pub fn deinit(self: *Transport) void {
        self.http_client.deinit();
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.* = undefined;
    }

    pub fn errorDetail(self: *const Transport) ?[]const u8 {
        return self.last_error_detail;
    }

    fn clearErrorDetail(self: *Transport) void {
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.last_error_detail = null;
    }

    fn recordReadFailure(self: *Transport, read_err: anyerror) void {
        const detail = std.fmt.allocPrint(
            self.gpa,
            "Connection to the model provider was lost: {s}",
            .{@errorName(read_err)},
        ) catch return;
        self.clearErrorDetail();
        self.last_error_detail = detail;
    }

    /// Record `HTTP <status>: <message>` from a failed response body for the
    /// UI. Best-effort: a failure to build the string just leaves the detail
    /// unset.
    fn recordErrorDetail(self: *Transport, status_code: u16, body: []const u8) void {
        const message = http.extractErrorMessage(self.gpa, body) catch return;
        defer self.gpa.free(message);
        log.warn("{s}.recordErrorDetail status={d} body={s}", .{ self.log_tag, status_code, message });
        const detail = std.fmt.allocPrint(self.gpa, "HTTP {d}: {s}", .{ status_code, message }) catch return;
        self.clearErrorDetail();
        self.last_error_detail = detail;
    }

    /// C2 gate: did the failed response body mention caching at all?
    /// Conservative substring match, case-insensitive.
    fn errorDetailMentionsCache(self: *const Transport) bool {
        const detail = self.last_error_detail orelse return false;
        return std.ascii.indexOfIgnoreCase(detail, "cache") != null;
    }

    fn sleepMs(self: *const Transport, ms: u64) void {
        if (ms == 0) return;
        const clamped: i64 = @intCast(@min(ms, std.math.maxInt(i64)));
        self.io.sleep(std.Io.Duration.fromMilliseconds(clamped), .awake) catch {};
    }

    fn materializeHeaders(self: *const Transport, buffer: []std.http.Header) []const std.http.Header {
        var set = provider_headers.HeaderSet.init(buffer);
        // Profile (transport-protocol) headers first — first-writer-wins, so
        // they beat provider headers on name collision: `accept` and
        // `OpenAI-Beta` are functional for the SSE transport, not styling.
        set.append(self.profile_headers, self.header_context);
        set.append(self.provider_headers, self.header_context);
        return set.slice();
    }

    /// Run one prompt: serialize once, retry 429/5xx/connection failures
    /// within the budget, and give a cache-mentioning final 400 exactly one
    /// cache-stripped re-send (C2). See the module doc for the division of
    /// labour with the payload writer and stream adapter.
    pub fn prompt(
        self: *Transport,
        source: PayloadSource,
        observer: anytype,
        comptime stream_adapter: type,
        env: stream_part.StreamEnv,
    ) !ai.Turn {
        std.debug.assert(self.url.len > 0);
        self.clearErrorDetail();

        // The payload is serialized ONCE per cache mode; every retry attempt
        // re-sends the same bytes. Retries only happen on head-phase
        // 429/5xx — the model has not produced anything and no tool has run,
        // so the request is idempotent. Stream-mid errors are never retried
        // (partial deltas may already be visible to the observer).
        var payload: std.Io.Writer.Allocating = .init(self.gpa);
        defer payload.deinit();
        var disable_cache = self.disable_cache_seed;
        try source.writePayload(source.context, &payload.writer, disable_cache);
        const req_body_log = try http.logBytesToolsTail(self.gpa, payload.written());
        defer if (req_body_log.ptr != payload.written().ptr) self.gpa.free(req_body_log);
        log.info("{s}.request POST {s} {s} body={s}", .{ self.log_tag, self.url, self.log_context, req_body_log });
        // L2: when this client carries no tools, say so next to the request
        // log — it tells the main agent apart from the summarizer/naming
        // clients (which are correctly tool-less) when several are alive.
        if (source.isToolLess(source.context)) {
            log.info("{s}.no_tools client {s} url={s}", .{ self.log_tag, self.log_context, self.url });
        }

        // C2: a cache-related 400 earns exactly ONE cache-stripped re-send,
        // independent of the 429/5xx retry budget (different failure mode).
        // `downgrade_done` gates it to a single rebuild; the outer loop runs
        // at most twice (original payload, then stripped). Note Zig's
        // `while … : (step) { continue }` runs the step expr, so a downgrade
        // cannot ride the `attempt` counter — it is a separate state bit,
        // hence the labeled continue instead of the old break-and-flag dance.
        var downgrade_done = false;
        outer: while (true) {
            var attempt: u32 = 0;
            while (attempt <= self.max_retries) : (attempt += 1) {
                var retry_after_secs: ?u64 = null;
                const turn = self.sendOnce(payload.written(), observer, stream_adapter, env, &retry_after_secs) catch |err| {
                    // Only head-phase transient failures are retried; every
                    // other 4xx is permanent and stream-mid errors never
                    // surface as retryable statuses.
                    if (attempt >= self.max_retries) {
                        // C2: before giving up on a 400, try the
                        // cache-stripped variant once. Conservative: only
                        // when the error body mentions "cache" AND we
                        // haven't downgraded yet AND the user didn't already
                        // disable caching (no fields to strip).
                        if (err == error.HttpClientError and !downgrade_done and !disable_cache and self.errorDetailMentionsCache()) {
                            downgrade_done = true;
                            disable_cache = true;
                            payload.deinit();
                            payload = .init(self.gpa);
                            try source.writePayload(source.context, &payload.writer, disable_cache);
                            log.warn("{s}.cache_downgrade retrying without cache fields after HTTP 400", .{self.log_tag});
                            continue :outer; // full retry budget on the stripped payload
                        }
                        return err;
                    }
                    switch (err) {
                        error.HttpServerError, error.HttpRateLimited, error.ConnectionFailed => {},
                        else => return err,
                    }
                    const delay_ms = http.retryDelayMs(self.retry_base_delay_ms, attempt, retry_after_secs);
                    log.warn("{s}.retry attempt={d} err={s} delay_ms={d}", .{ self.log_tag, attempt + 1, @errorName(err), delay_ms });
                    self.sleepMs(delay_ms);
                    continue;
                };
                return turn;
            }
            // Inner loop exhausted its retry budget without returning a turn.
            // This only happens after a downgrade (the labeled continue
            // restarts the outer loop) — the original-payload path always
            // returns err or a turn. Surface the persistent 400 rather than
            // looping forever.
            if (downgrade_done) return error.HttpClientError;
            unreachable; // guarded by the return paths above
        }
    }

    /// Perform one HTTP round-trip with the already-serialized payload.
    /// Transient head-phase statuses (429, 5xx) and pre-response connection
    /// drops surface as `error.HttpRateLimited` / `error.HttpServerError` /
    /// `error.ConnectionFailed` so `prompt` can decide whether to retry;
    /// every other failure propagates unchanged. When a retryable status is
    /// hit, `retry_after_secs` receives the server's `Retry-After` value
    /// (integer seconds) if one was sent.
    fn sendOnce(
        self: *Transport,
        payload: []const u8,
        observer: anytype,
        comptime stream_adapter: type,
        env: stream_part.StreamEnv,
        retry_after_secs: *?u64,
    ) !ai.Turn {
        var extra_headers_buffer: [provider_headers.max_outbound_headers]std.http.Header = undefined;
        const extra_headers = self.materializeHeaders(&extra_headers_buffer);
        var req = self.http_client.request(.POST, try std.Uri.parse(self.url), .{
            .headers = .{
                .authorization = if (self.authorization) |a| .{ .override = a } else .omit,
                .content_type = .{ .override = http.content_type_json },
                .user_agent = if (self.user_agent) |value| .{ .override = value } else .default,
            },
            .extra_headers = extra_headers,
        }) catch |err| return http.headPhaseFailure(err);
        defer req.deinit();

        req.transfer_encoding = .chunked;
        var body_buffer: [body_buffer_bytes]u8 = undefined;
        var body_writer = req.sendBodyUnflushed(&body_buffer) catch |err| return http.headPhaseFailure(err);
        body_writer.writer.writeAll(payload) catch |err| return http.headPhaseFailure(err);
        body_writer.end() catch |err| return http.headPhaseFailure(err);
        req.connection.?.flush() catch |err| return http.headPhaseFailure(err);

        var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
        var http_response = req.receiveHead(&redirect_buffer) catch |err| {
            // `receiveHead` fails with `error.ReadFailed`/`error.WriteFailed`
            // when the connection drops; capture the underlying socket error
            // so the UI shows what actually went wrong instead of the opaque
            // error name. Read the stream error fields directly —
            // `Connection.getReadError` unwraps `.?` internally and panics
            // when std synthesized the ReadFailed without a socket error.
            if (err == error.ReadFailed or err == error.WriteFailed or err == error.HttpRequestTruncated) {
                if (req.connection) |conn| {
                    const reason: anyerror = if (conn.stream_reader.err) |e| e else if (conn.stream_writer.err) |e| e else err;
                    self.recordReadFailure(reason);
                }
            }
            return http.headPhaseFailure(err);
        };
        const status_code: u16 = @intFromEnum(http_response.head.status);
        log.info("{s}.response.head status={d} {s}", .{ self.log_tag, status_code, self.log_context });
        if (status_code >= 400) {
            // Read `Retry-After` before initializing the body reader — the
            // head pointers are invalidated once the body stream starts.
            if (http.isRetryableHeadStatus(status_code)) {
                retry_after_secs.* = http.parseRetryAfterSeconds(http_response.head.bytes);
            }
            // The error body (e.g. a 403 from a Cloudflare-fronted host) may
            // be gzip/deflate-compressed (the only encodings this client
            // advertises) — use the decompressing reader so the logs show
            // real text instead of raw compressed bytes.
            var error_buffer: [transfer_buffer_bytes]u8 = undefined;
            var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const error_reader = http_response.readerDecompressing(&error_buffer, &decompress, &decompress_buffer);
            const error_body = error_reader.allocRemaining(self.gpa, .limited(response_bytes_max)) catch |err| switch (err) {
                error.StreamTooLong => return error.ResponseTooLarge,
                else => |e| return e,
            };
            defer self.gpa.free(error_body);
            log.warn("{s}.response.error status={d} body={s}", .{ self.log_tag, status_code, http.logBytesHead(error_body) });
            self.recordErrorDetail(status_code, error_body);
            if (status_code == 429) return error.HttpRateLimited;
            if (status_code >= 500) return error.HttpServerError;
            return error.HttpClientError;
        }
        if (!http.isSuccess(status_code)) return error.HttpUnexpectedStatus;

        // Socket-level read timeout: prevents indefinite hangs when the
        // server stops mid-stream. Applied after the head is received so the
        // (fast) head exchange is not affected. Windows: `Io.Threaded` opens
        // sockets through the AFD driver, so socket handles are not ws2_32
        // SOCKETs and setsockopt always fails (WSAENOTSOCK) — setSocketTimeout
        // skips it rather than warn on every request.
        if (req.connection) |conn| http.setSocketTimeout(conn, self.request_timeout_seconds);

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = http_response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
        return stream_adapter.run(self.gpa, reader, observer, env) catch |err| {
            if (err == error.ReadFailed) {
                if (req.connection) |conn| {
                    // Prefer the socket error; std also synthesizes
                    // `error.ReadFailed` for a truncated or invalid chunked
                    // body (recorded as `body_err`), and
                    // `Connection.getReadError` would panic on `.?` there —
                    // see the head-phase note above.
                    const reason: anyerror = if (conn.stream_reader.err) |e| e else if (http_response.bodyErr()) |e| e else err;
                    self.recordReadFailure(reason);
                }
            }
            return err;
        };
    }
};

test "errorDetailMentionsCache is case-insensitive and handles null" {
    // C2: the downgrade decision is driven by this predicate. Verify the
    // conservative "cache" substring match in both cases and the null path.
    var t: Transport = undefined;
    t.init(std.testing.allocator, std.testing.io);
    defer t.deinit();

    try std.testing.expect(!t.errorDetailMentionsCache());

    t.last_error_detail = try t.gpa.dupe(u8, "HTTP 400: unknown field cache_control");
    try std.testing.expect(t.errorDetailMentionsCache());
    t.clearErrorDetail();

    t.last_error_detail = try t.gpa.dupe(u8, "Cache-Control header rejected");
    try std.testing.expect(t.errorDetailMentionsCache());
    t.clearErrorDetail();

    t.last_error_detail = try t.gpa.dupe(u8, "HTTP 400: invalid model id");
    try std.testing.expect(!t.errorDetailMentionsCache());
    t.clearErrorDetail();
}
