//! McpManager — Multi-server MCP supervisor and tool aggregator for Zay Agent.

const std = @import("std");
const log = std.log.scoped(.mcp);
const ai = @import("../ai.zig");
const config_mod = @import("../config/config.zig");
const client_mod = @import("client.zig");
const os = @import("../os.zig");

const assert = std.debug.assert;

pub const McpManager = struct {
    gpa: std.mem.Allocator,
    /// Heap-stable client slots (#385): a background tool-refresh worker holds
    /// a `*McpClient` across ticks, and by-value storage made that pointer
    /// dangle through `removeStaleClients`' `orderedRemove` (slot shifting) and
    /// `installConnectResult`'s slot overwrite. The manager owns every slot;
    /// removal/replacement goes through `retireClient`.
    clients: std.ArrayList(*client_mod.McpClient) = .empty,
    /// In-flight async connect jobs. Touched only from the main thread; each
    /// job's worker mutates only the job's private clone, never the live list.
    pending_connects: std.ArrayList(*ConnectJob) = .empty,
    /// In-flight background tool re-discovery jobs (#385) — same ownership
    /// contract as `pending_connects`, except the worker runs against the LIVE
    /// client (stdio re-discovery must reuse the same server process, so the
    /// clone trick does not apply) and the main thread installs the fresh
    /// records via `drainToolRefreshes`.
    pending_refreshes: std.ArrayList(*RefreshJob) = .empty,

    pub fn init(gpa: std.mem.Allocator) McpManager {
        return .{
            .gpa = gpa,
            .clients = .empty,
        };
    }

    pub fn deinit(self: *McpManager, io: std.Io) void {
        // Join + tear down any in-flight jobs so their spawned subprocesses
        // (stdio) are reaped before the io runtime shuts down. Jobs run
        // against live clients, so they must be joined BEFORE any client
        // deinit — a refresh worker mid-`listToolsFresh` would otherwise touch
        // a destroyed client.
        self.cancelAllConnects(io);
        self.cancelAllRefreshes(io);
        self.pending_connects.deinit(self.gpa);
        self.pending_refreshes.deinit(self.gpa);
        for (self.clients.items) |client| {
            client.deinit(io);
            self.gpa.destroy(client);
        }
        self.clients.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append a client to the list, taking ownership. Heap slot per the
    /// `clients` field doc (#385).
    pub fn addClient(self: *McpManager, client: client_mod.McpClient) !void {
        const slot = try self.gpa.create(client_mod.McpClient);
        errdefer self.gpa.destroy(slot);
        slot.* = client;
        try self.clients.append(self.gpa, slot);
    }

    /// Reconcile client list against config: remove stale, add new, update status.
    /// No I/O connections — pure list management. Safe to call repeatedly.
    /// Misconfigured servers (no command/url) are registered as .failed with
    /// an error message. Duplicate names are skipped with a warning.
    pub fn syncFromConfig(self: *McpManager, io: std.Io, config: *const config_mod.Config) !void {
        // Phase 1: Remove clients no longer in config (zombie cleanup)
        self.removeStaleClients(io, config);

        // Phase 2: Add new or update status of existing
        for (config.mcp_servers, 0..) |server_cfg, cfg_idx| {
            // Skip duplicate names within the same config
            var is_dup = false;
            for (config.mcp_servers[0..cfg_idx]) |prev| {
                if (std.mem.eql(u8, server_cfg.name, prev.name)) {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) {
                log.warn("MCP server '{s}': duplicate name in config, skipping", .{server_cfg.name});
                continue;
            }

            // Expand {env:VAR} placeholders for actual use (spawning / HTTP).
            // The config keeps the raw placeholders so serialize() never writes
            // resolved secrets to disk; only this expanded copy — owned by the
            // client — carries them.
            var expanded = config_mod.expandMcpServer(self.gpa, server_cfg) catch |err| {
                // Causal-neutral label: expandEnvVars handles unset variables
                // itself (empty substitute + warn), so the realistic failure
                // here is allocation, not a bad env var.
                log.warn("MCP server '{s}': expansion failed err={s}; skipping", .{ server_cfg.name, @errorName(err) });
                continue;
            };
            defer expanded.deinit(self.gpa);

            const cmd: ?[]const u8 = switch (expanded.transport) {
                .stdio => |t| t.command,
                .sse => null,
            };
            const args: []const []const u8 = switch (expanded.transport) {
                .stdio => |t| t.args,
                .sse => &.{},
            };
            const url: ?[]const u8 = switch (expanded.transport) {
                .stdio => null,
                .sse => |t| t.url,
            };

            if (self.findClient(server_cfg.name)) |c| {
                if (server_cfg.enabled) {
                    if (c.status() != .connected) c.markConnecting(io);
                } else {
                    // Mirrors `disconnectClient` (#384 bug 4): the raw
                    // `.disabled` write this replaced dropped the lifecycle
                    // union on a possibly-connected client — orphaning the
                    // stdio child and leaving the discovery cache populated,
                    // which then wedged the next re-enable in CONNECTING.
                    // `stop` sets the `.disabled` lifecycle itself.
                    c.stop(io);
                    c.clearTools();
                    c.latency_ms = 0;
                }
            } else {
                var c = try client_mod.McpClient.init(
                    self.gpa,
                    server_cfg.name,
                    cmd,
                    args,
                    url,
                );
                errdefer c.deinit(io);
                if (server_cfg.request_timeout_ms) |ms| c.read_timeout_ms = @max(ms, 1);
                if (c.transport == .sse) {
                    c.transport.sse.headers = try config_mod.cloneHeaders(self.gpa, expanded.transport.sse.headers);
                }
                if (server_cfg.enabled) c.markConnecting(io);
                try self.addClient(c);
            }
        }
    }

    /// Extended sync: reconcile client list, then connect enabled servers.
    ///
    /// Connects run asynchronously (`io.concurrent` + `drainConnects`) so a
    /// slow or unreachable server — the Streamable HTTP handshake has no
    /// timeout — can never block the UI thread. Each TUI tick drains completed
    /// handshakes.
    pub fn syncFromConfigEx(
        self: *McpManager,
        io: std.Io,
        config: *const config_mod.Config,
    ) void {
        // Keep going when the reconcile fails (never OOM in practice): the
        // connect sweep below must still run so existing clients converge.
        // The warn keeps the failure from being invisible.
        self.syncFromConfig(io, config) catch |err| {
            log.warn("mcp.syncFromConfigEx.reconcile_failed err={s}", .{@errorName(err)});
        };
        for (self.clients.items) |c| {
            if (c.status() != .connecting) continue;
            if (c.discovery.tools.items.len > 0) continue;
            if (self.hasPendingConnect(c.name)) continue;
            self.launchConnect(io, c.name);
        }
    }

    /// Count total active tools across all connected MCP servers.
    pub fn totalActiveTools(self: *const McpManager) usize {
        var count: usize = 0;
        for (self.clients.items) |c| {
            if (c.status() == .connected) {
                count += c.discovery.tools.items.len;
            }
        }
        return count;
    }

    /// Count total connected servers.
    pub fn activeServerCount(self: *const McpManager) usize {
        var count: usize = 0;
        for (self.clients.items) |c| {
            if (c.status() == .connected) count += 1;
        }
        return count;
    }

    /// Build an `ai.McpToolSchema` slice from all connected clients' tools.
    /// Caller owns the returned slice and must free with `gpa.free()`.
    /// Each schema's name/description strings borrow from the McpTool — the
    /// caller must keep the McpManager alive while using the result.
    /// Duplicate full_names (same server+tool from two sources) are skipped
    /// with a warning — first writer wins.
    pub fn buildMcpToolSchemas(self: *const McpManager, gpa: std.mem.Allocator) ![]ai.McpToolSchema {
        var total: usize = 0;
        for (self.clients.items) |c| {
            if (c.status() == .connected) total += c.discovery.tools.items.len;
        }
        var schemas = try gpa.alloc(ai.McpToolSchema, total);
        var idx: usize = 0;
        next_tool: for (self.clients.items) |c| {
            if (c.status() != .connected) continue;
            for (c.discovery.tools.items) |tool| {
                // Defensive only: server names are deduped at config parse time,
                // so a `full_name` collision means one server advertised two
                // tools with the same name — skip the malformed duplicate (first
                // writer wins). Linear scan is intentional: this is a cold path
                // (user action / rare `tools/list_changed` notification, not
                // per-tick) and the slice stays cache-hot over ~10-200 tools.
                for (schemas[0..idx]) |existing| {
                    if (std.mem.eql(u8, existing.name, tool.full_name)) {
                        log.warn("MCP tool name collision: '{s}' — skipping duplicate", .{tool.full_name});
                        continue :next_tool;
                    }
                }
                schemas[idx] = .{
                    .name = tool.full_name,
                    .description = tool.description,
                    .schema = tool.schema,
                    .raw_input_schema = tool.raw_input_schema,
                };
                idx += 1;
            }
        }
        // Trim unused tail if duplicates were skipped
        return gpa.realloc(schemas, idx);
    }

    /// Brief one-line summary of connected servers and tool counts.
    /// Caller owns the returned slice.
    pub fn serverSummary(self: *const McpManager, gpa: std.mem.Allocator) ![]u8 {
        if (self.activeServerCount() == 0) return gpa.dupe(u8, "");

        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll("Connected MCP servers: ");
        var first = true;
        for (self.clients.items) |c| {
            if (c.status() != .connected) continue;
            if (!first) try out.writer.writeAll(", ");
            first = false;
            try out.writer.print("{s} ({d} tools)", .{ c.name, c.discovery.tools.items.len });
        }
        return out.toOwnedSlice();
    }

    /// Reconnect a specific client by index: stop, clear tools, and re-discover
    /// asynchronously. `markConnecting` is required so the transport lifecycle
    /// is `.connecting` — `stop` leaves it `.disabled`, and `initialize` only
    /// flips `.stdio`/`.sse` variants to `.ready`, not the `.disabled` arm.
    /// Without this, a reconnecting SSE server stays "connecting" in the TUI
    /// despite actually being live.
    pub fn reconnectClient(self: *McpManager, io: std.Io, index: usize) void {
        if (index >= self.clients.items.len) return;
        const client = self.clients.items[index];
        client.stop(io);
        client.clearTools();
        client.latency_ms = 0;
        client.markConnecting(io);
        self.launchConnect(io, client.name);
    }

    /// Disconnect a specific client: stop process, clear tools, set disabled.
    /// The client stays in the list and can be reconnected later via
    /// `reconnectClient` or by toggling in the TUI. `stop` already sets
    /// lifecycle to `.disabled`, so no explicit lifecycle mutation here.
    pub fn disconnectClient(self: *McpManager, io: std.Io, index: usize) void {
        if (index >= self.clients.items.len) return;
        const client = self.clients.items[index];
        client.stop(io);
        client.clearTools();
        client.latency_ms = 0;
        // An in-flight connect is NOT canceled here — cancel blocks the main
        // thread on a hung handshake. `drainConnects` observes the target is
        // no longer `.connecting` and tears the job down instead.
    }

    /// Poll in-flight connect jobs and install the completed ones. Called from
    /// the TUI tick; the worker flips `done` before returning, so `await` never
    /// blocks on a live handshake. Returns true when any job completed (caller
    /// should re-inject tool schemas and redraw).
    pub fn drainConnects(self: *McpManager, io: std.Io) bool {
        var completed = false;
        var i: usize = 0;
        while (i < self.pending_connects.items.len) {
            const job = self.pending_connects.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            const result = job.future.await(io);
            _ = self.pending_connects.orderedRemove(i);
            self.installConnectResult(job, result, io);
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
            completed = true;
        }
        return completed;
    }

    /// True while any connect job is still in flight. The TUI keeps ticking
    /// (so `drainConnects` keeps running) while this is true.
    pub fn hasPendingConnects(self: *const McpManager) bool {
        return self.pending_connects.items.len > 0;
    }

    fn hasPendingConnect(self: *const McpManager, name: []const u8) bool {
        for (self.pending_connects.items) |job| {
            if (std.mem.eql(u8, job.client_name, name)) return true;
        }
        return false;
    }

    /// Spawn an async connect for the named client. No-op when a job for that
    /// client is already pending, the client isn't `.connecting`, or it already
    /// discovered tools. The worker owns `job.clone`; the main thread installs
    /// it via `drainConnects`.
    fn launchConnect(self: *McpManager, io: std.Io, name: []const u8) void {
        if (self.hasPendingConnect(name)) return;
        const client = self.findClient(name) orelse return;
        if (client.status() != .connecting) return;
        if (client.discovery.tools.items.len > 0) return;

        const job = self.gpa.create(ConnectJob) catch return;
        // Full-struct init: `create` hands back undefined memory, and the
        // fields without explicit assignments below (`failed_message`, `done`)
        // must come from the struct defaults. An uninitialized `failed_message`
        // reads as a non-null garbage slice, so teardown (`cancelAllConnects`,
        // `installConnectResult`) frees a wild pointer and crashes; an
        // uninitialized `done` reads as true, so `drainConnects` awaits a
        // future whose worker never ran.
        job.* = .{
            .gpa = self.gpa,
            .io = io,
            .client_name = undefined,
            .clone = undefined,
            .future = undefined,
        };
        job.client_name = self.gpa.dupe(u8, name) catch {
            self.gpa.destroy(job);
            return;
        };
        job.clone = client.cloneForConnect(io) catch {
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
            return;
        };
        job.future = io.concurrent(runConnect, .{job}) catch {
            job.clone.deinit(io);
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
            return;
        };
        self.pending_connects.append(self.gpa, job) catch {
            _ = job.future.cancel(io);
            job.clone.deinit(io);
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
        };
    }

    /// Move a completed connect's outcome into the live client list. Runs on
    /// the main thread only. If the target was disconnected/removed while the
    /// connect was in flight, the outcome (clone + message) is torn down.
    fn installConnectResult(self: *McpManager, job: *ConnectJob, result: ConnectResult, io: std.Io) void {
        const idx = self.findClientIdx(job.client_name) orelse {
            // Client removed while the connect was in flight.
            job.clone.deinit(io);
            if (job.failed_message) |msg| self.gpa.free(msg);
            return;
        };
        const target = self.clients.items[idx];
        switch (result) {
            .ok => {
                // Install only if the target is still connecting — the user may
                // have disconnected it while we were connecting.
                if (target.status() != .connecting) {
                    job.clone.deinit(io);
                    return;
                }
                // Heap slot swap (#385): the clone moves into a fresh slot
                // entry; the retired original goes through `retireClient` in
                // case a background refresh still runs against it. The clone
                // is heap-boxed FIRST so an OOM here leaves the connecting
                // target untouched (the reconcile relaunches the connect).
                const moved = self.gpa.create(client_mod.McpClient) catch {
                    log.warn("MCP '{s}': OOM boxing the connected client; keeping the connecting slot for the next reconcile", .{job.client_name});
                    job.clone.deinit(io);
                    return;
                };
                moved.* = job.clone;
                self.retireClient(io, target);
                self.clients.items[idx] = moved;
            },
            .failed => {
                const msg = job.failed_message orelse (self.gpa.dupe(u8, "connect failed") catch return);
                if (target.status() != .connecting) {
                    self.gpa.free(msg);
                    // Don't leave a dangling pointer behind — `msg` may alias
                    // `job.failed_message` when the worker allocated one.
                    job.failed_message = null;
                    job.clone.deinit(io);
                    return;
                }
                target.stop(io);
                // Defense-in-depth for the #384 invariant — a non-connected
                // lifecycle never carries tools — so no future path that
                // leaves tools on a connecting client can re-create the
                // stale-cache CONNECTING wedge through this arm.
                target.clearTools();
                // adoptFailure serializes the variant swap against a worker's
                // capture bracket (#385) — a background refresh may still be
                // inside this client after a mid-flight reconnect.
                target.adoptFailure(io, msg);
                job.clone.deinit(io);
            },
        }
    }

    /// Join and tear down every in-flight connect job. Used by `deinit` only —
    /// on the hot path `drainConnects` cleans up lazily instead (cancellation
    /// joins each worker before its owned client can be torn down).
    fn cancelAllConnects(self: *McpManager, io: std.Io) void {
        for (self.pending_connects.items) |job| {
            _ = job.future.cancel(io);
            job.clone.deinit(io);
            if (job.failed_message) |msg| self.gpa.free(msg);
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
        }
        self.pending_connects.clearRetainingCapacity();
    }

    fn findClient(self: *McpManager, name: []const u8) ?*client_mod.McpClient {
        const idx = self.findClientIdx(name) orelse return null;
        return self.clients.items[idx];
    }

    fn findClientIdx(self: *McpManager, name: []const u8) ?usize {
        for (self.clients.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) return i;
        }
        return null;
    }

    /// Remove clients that are no longer in config. Iterates backwards so
    /// orderedRemove indices stay valid. Deinits the client (kills subprocess).
    fn removeStaleClients(self: *McpManager, io: std.Io, config: *const config_mod.Config) void {
        var i: usize = self.clients.items.len;
        while (i > 0) {
            i -= 1;
            const client = self.clients.items[i];
            var found = false;
            for (config.mcp_servers) |server_cfg| {
                if (std.mem.eql(u8, client.name, server_cfg.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.retireClient(io, client);
                _ = self.clients.orderedRemove(i);
            }
        }
    }

    /// Retire a client being replaced or removed while a background tool
    /// refresh may still run against it (#385). If a pending refresh job holds
    /// this pointer, the job takes over the client's deinit at drain time —
    /// after `future.await` has proven the worker exited — and the refresh
    /// outcome itself is discarded (the replacement's own connect handshake
    /// installed a newer discovery). Otherwise the client is destroyed
    /// immediately: no worker can be inside it. Main thread only, like every
    /// other job-list mutation.
    fn retireClient(self: *McpManager, io: std.Io, old: *client_mod.McpClient) void {
        for (self.pending_refreshes.items) |job| {
            if (job.client == old) {
                job.owns_client = true;
                return;
            }
        }
        old.deinit(io);
        self.gpa.destroy(old);
    }

    // ── Background tool re-discovery (#385) ──

    /// Launch an async tools/list re-discovery for the named client. No-op
    /// when a job for that client is already pending, the client is missing,
    /// or it isn't `.connected` — `pollToolsRefresh` only fires on connected
    /// clients, so callers can pass the flag through unchecked. The worker
    /// runs `listToolsFresh` on the LIVE client (stdio re-discovery must reuse
    /// the same server process); the main thread installs the outcome via
    /// `drainToolRefreshes`. Never blocks the caller — the request (which can
    /// wait on `request_mutex` behind an in-flight tool call for up to
    /// `read_timeout_ms`) happens on the worker, off the UI thread.
    pub fn launchToolRefresh(self: *McpManager, io: std.Io, name: []const u8) void {
        if (self.hasPendingRefresh(name)) return;
        const client = self.findClient(name) orelse return;
        if (client.status() != .connected) return;

        // Every failure exit below re-arms the refresh flag: the UI tick
        // already consumed it (atomic swap) before calling this, so a silent
        // return would drop the re-discovery request with NO retry and no
        // signal — the stale list would persist indefinitely (#385 review).
        // The re-armed flag makes the next tick retry; the warn keeps the
        // failure visible in the log.
        const fail_launch = struct {
            fn warn(c: *client_mod.McpClient, err: anyerror) void {
                log.warn("MCP '{s}': tool refresh launch failed err={s}; retrying next tick", .{ c.name, @errorName(err) });
                c.discovery.storeRefreshPending();
            }
        }.warn;

        const job = self.gpa.create(RefreshJob) catch |err| {
            fail_launch(client, err);
            return;
        };
        // Full-struct init: `create` hands back undefined memory, and the
        // fields without explicit assignments below (`owns_client`, `fresh`,
        // `err`, `done`) must come from the struct defaults. An uninitialized
        // `done` reads as true, so `drainToolRefreshes` awaits a future whose
        // worker never ran; uninitialized `fresh`/`err` free or read garbage.
        job.* = .{
            .gpa = self.gpa,
            .io = io,
            .client_name = undefined,
            .client = client,
            .future = undefined,
        };
        job.client_name = self.gpa.dupe(u8, name) catch |err| {
            self.gpa.destroy(job);
            fail_launch(client, err);
            return;
        };
        job.future = io.concurrent(runRefresh, .{job}) catch |err| {
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
            fail_launch(client, err);
            return;
        };
        self.pending_refreshes.append(self.gpa, job) catch |err| {
            _ = job.future.cancel(io);
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
            fail_launch(client, err);
        };
    }

    /// Poll in-flight refresh jobs and install the completed ones. Called from
    /// the TUI tick. Returns true when any job completed (caller should
    /// re-inject tool schemas and redraw). Install semantics preserve the
    /// #384 invariants: replace-not-append via `Discovery.replaceAll`, and a
    /// failed re-discovery surfaces through `setError` on the main thread
    /// (never from the worker — `setError` stops the transport, which is a
    /// lifecycle write) while the old cache goes down with the transport per
    /// the clear-on-stop choke points.
    pub fn drainToolRefreshes(self: *McpManager, io: std.Io) bool {
        var completed = false;
        var i: usize = 0;
        while (i < self.pending_refreshes.items.len) {
            const job = self.pending_refreshes.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            const result = job.future.await(io);
            _ = self.pending_refreshes.orderedRemove(i);
            self.installRefreshResult(job, result, io);
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
            completed = true;
        }
        return completed;
    }

    /// True while any refresh job is still in flight. The TUI keeps ticking
    /// (so `drainToolRefreshes` keeps running) while this is true.
    pub fn hasPendingRefreshes(self: *const McpManager) bool {
        return self.pending_refreshes.items.len > 0;
    }

    fn hasPendingRefresh(self: *const McpManager, name: []const u8) bool {
        for (self.pending_refreshes.items) |job| {
            if (std.mem.eql(u8, job.client_name, name)) return true;
        }
        return false;
    }

    /// Move a completed refresh's outcome into the live client. Runs on the
    /// main thread only. Every discard path frees the worker-built records;
    /// the `owns_client` handoff destroys the retired client here, after
    /// `future.await` proved the worker exited.
    fn installRefreshResult(self: *McpManager, job: *RefreshJob, result: RefreshResult, io: std.Io) void {
        defer {
            for (job.fresh.items) |*tool| tool.deinit(self.gpa);
            job.fresh.deinit(self.gpa);
            if (job.owns_client) {
                job.client.deinit(io);
                self.gpa.destroy(job.client);
            }
        }
        // Client removed mid-flight (retired through a refresh-job handoff).
        const idx = self.findClientIdx(job.client_name) orelse return;
        const target = self.clients.items[idx];
        // Client replaced mid-flight: `target` is the replacement, the job's
        // client is the retired original — discard the stale snapshot (the
        // replacement's own connect handshake installed a newer discovery).
        if (target != job.client) {
            log.debug("MCP '{s}': refresh outcome discarded (client replaced mid-flight)", .{job.client_name});
            return;
        }
        // Client disabled/failed mid-flight: the transport is gone, its cache
        // went down with it, and `setError` on a dead transport is meaningless.
        if (target.status() != .connected) return;
        switch (result) {
            .ok => {
                // Full success: swap the replacement in (replace-not-append).
                target.discovery.replaceAll(job.fresh);
                job.fresh = .empty;
            },
            .failed => {
                // The log trail the old synchronous path kept (#385 review) —
                // the lifecycle failure itself is UI-visible, the warn is for
                // the log archaeologist.
                const err = job.err orelse error.McpInvalidToolsResponse;
                log.warn("MCP '{s}': list_changed re-discovery failed err={s}", .{ target.name, @errorName(err) });
                target.setError(io, "list_changed re-discovery failed: {s}", .{@errorName(err)});
            },
        }
    }

    /// Join and tear down every in-flight refresh job. Used by `deinit` only —
    /// on the hot path `drainToolRefreshes` cleans up lazily instead.
    fn cancelAllRefreshes(self: *McpManager, io: std.Io) void {
        for (self.pending_refreshes.items) |job| {
            _ = job.future.cancel(io);
            for (job.fresh.items) |*tool| tool.deinit(self.gpa);
            job.fresh.deinit(self.gpa);
            if (job.owns_client) {
                job.client.deinit(io);
                self.gpa.destroy(job.client);
            }
            self.gpa.free(job.client_name);
            self.gpa.destroy(job);
        }
        self.pending_refreshes.clearRetainingCapacity();
    }
};

/// Result of an async tool-refresh worker. The worker only fills the job's
/// private fields; the main thread installs the outcome.
const RefreshResult = enum { ok, failed };

/// One in-flight background tools/list re-discovery (#385). Owned by the
/// manager; the worker runs `listToolsFresh` on the LIVE client (stdio
/// re-discovery must reuse the same server process — the connect-job clone
/// trick does not apply) and only mutates the job's own fields plus the
/// request-serialized client state; the main thread installs the fresh
/// records via `drainToolRefreshes`.
const RefreshJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Name of the live client this refresh belongs to — stable across list
    /// churn, so the install looks the client up by name, not index.
    client_name: []u8,
    /// The live client the worker runs against. Heap-stable for the job's
    /// lifetime; when the launched-at client is replaced or removed mid-flight
    /// (`retireClient`), the job takes over its deinit via `owns_client` —
    /// never destroyed while the worker can still be inside it.
    client: *client_mod.McpClient,
    /// Set by the main thread (`retireClient`) when the launched-at client is
    /// replaced or removed while this job is pending.
    owns_client: bool = false,
    /// Worker-built fresh tool records, empty on failure. gpa-owned; the main
    /// thread installs them via `Discovery.replaceAll` or frees them.
    fresh: std.ArrayList(client_mod.McpTool) = .empty,
    /// Worker failure, valid only when the result is `.failed`. Written before
    /// `done.store(true, .release)` and read only after the main thread
    /// observes the flag (same handoff contract as `ConnectJob.failed_message`).
    err: ?anyerror = null,
    future: std.Io.Future(RefreshResult),
    done: std.atomic.Value(bool) = .init(false),
};

/// Run tools/list against the live client on a concurrent worker thread (#385).
/// Only `job.*` is written; the client's shared state touched here is exactly
/// what `listToolsFresh` documents as worker-safe (request-serialized fields,
/// atomic refresh flag) — never the discovery cache.
fn runRefresh(job: *RefreshJob) RefreshResult {
    defer job.done.store(true, .release);
    if (job.client.listToolsFresh(job.io)) |fresh| {
        job.fresh = fresh;
        return .ok;
    } else |err| {
        job.err = err;
        return .failed;
    }
}

/// Result of an async connect worker. The worker never touches the live
/// McpClient list; it builds `job.clone` and the main thread installs it.
const ConnectResult = enum { ok, failed };

/// One in-flight async MCP connect. Owned by the manager; the worker owns the
/// clone until it flips `done`. The main thread polls `done`, awaits, and moves
/// the clone into the client list.
const ConnectJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Name of the live client this connect belongs to — stable across list
    /// churn, so the install looks the client up by name, not index.
    client_name: []u8,
    /// Private transport copy the worker spawns/handshakes on.
    clone: client_mod.McpClient,
    future: std.Io.Future(ConnectResult),
    /// gpa-owned failure message; written before `done.store(true, .release)`
    /// and read only after the main thread observes the flag.
    failed_message: ?[]u8 = null,
    done: std.atomic.Value(bool) = .init(false),
};

/// Spawn the MCP server subprocess (stdio) and perform the handshake + tool
/// discovery over whichever transport the job's clone is configured for. The
/// Streamable HTTP transport is connectionless — each JSON-RPC call is a fresh
/// POST — so there is nothing to spawn for it. Runs on a concurrent worker
/// thread; only `job.*` is touched, never the live client list.
fn runConnect(job: *ConnectJob) ConnectResult {
    defer job.done.store(true, .release);
    const io = job.io;
    const client = &job.clone;
    if (client.transport == .stdio) {
        client.startStdio(io) catch |err| {
            job.failed_message = std.fmt.allocPrint(job.gpa, "Failed to spawn: {s}", .{@errorName(err)}) catch null;
            return .failed;
        };
    }
    client.initialize(io) catch |err| {
        client.stop(io);
        job.failed_message = std.fmt.allocPrint(job.gpa, "Handshake failed: {s}", .{@errorName(err)}) catch null;
        return .failed;
    };
    client.listTools(io) catch |err| {
        client.stop(io);
        job.failed_message = std.fmt.allocPrint(job.gpa, "Tool discovery failed: {s}", .{@errorName(err)}) catch null;
        return .failed;
    };
    return .ok;
}

/// Build a stdio MCP server config for the deterministic Zig mock server.
/// The returned config lives in `arena` (the test's config fixture arena) —
/// released with the arena, never freed per-field.
fn mockStdioConfig(arena: std.mem.Allocator, name: []const u8, mode: []const u8) !config_mod.McpServerConfig {
    var args = try arena.alloc([]u8, 1);
    args[0] = try arena.dupe(u8, mode);
    return .{
        .name = try arena.dupe(u8, name),
        .enabled = true,
        .transport = .{ .stdio = .{
            .command = try arena.dupe(u8, @import("mcp_mock_server").path),
            .args = args,
        } },
    };
}

/// Poll `drainConnects` until every pending connect job has completed and
/// been installed (or torn down). Mirrors the TUI tick loop's role.
fn drainUntilConnected(manager: *McpManager, io: std.Io) !void {
    var deadline: usize = 0;
    while (manager.hasPendingConnects()) : (deadline += 1) {
        if (deadline > 2000) return error.ConnectTimedOut;
        _ = manager.drainConnects(io);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

test "McpManager syncs servers from config and counts tools" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = .{
        .name = try arena.dupe(u8, "memory"),
        .enabled = true,
        .transport = .{ .stdio = .{
            .command = try arena.dupe(u8, "npx"),
        } },
    };
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    // syncFromConfig only registers the client — actual connection happens in syncFromConfigEx
    try std.testing.expectEqual(client_mod.ServerStatus.connecting, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 0), manager.activeServerCount());
}

test "McpManager removes stale clients not in config" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // First sync: add two servers
    var servers1 = try arena.alloc(config_mod.McpServerConfig, 2);
    servers1[0] = .{
        .name = try arena.dupe(u8, "alpha"),
        .enabled = true,
        .transport = .{ .stdio = .{ .command = try arena.dupe(u8, "echo") } },
    };
    servers1[1] = .{
        .name = try arena.dupe(u8, "beta"),
        .enabled = true,
        .transport = .{ .stdio = .{ .command = try arena.dupe(u8, "cat") } },
    };
    var cfg1: config_mod.Config = .{ .mcp_servers = servers1 };

    try manager.syncFromConfig(std.testing.io, &cfg1);
    try std.testing.expectEqual(@as(usize, 2), manager.clients.items.len);

    // Second sync: only "alpha" remains — "beta" should be removed
    var servers2 = try arena.alloc(config_mod.McpServerConfig, 1);
    servers2[0] = .{
        .name = try arena.dupe(u8, "alpha"),
        .enabled = true,
        .transport = .{ .stdio = .{ .command = try arena.dupe(u8, "echo") } },
    };
    var cfg2: config_mod.Config = .{ .mcp_servers = servers2 };

    try manager.syncFromConfig(std.testing.io, &cfg2);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    try std.testing.expectEqualStrings("alpha", manager.clients.items[0].name);
}

test "McpManager syncFromConfig surfaces injected allocation failure cleanly" {
    // #303: the UI-layer config-apply sites wrap syncFromConfig in
    // `catch |err| log.warn(...)` (startup must boot with a broken config).
    // This pins the contract those catches rely on: an injected allocation
    // failure surfaces as an error (never a panic or a silent success),
    // leaves no partial client behind, and tears down without leaks — the
    // warn is the only visible trace. The config side is built with the real
    // allocator; only the code-under-test sees the failing one. The expand
    // step swallows OOM into skip-with-warn, so a fixed fail_index cannot
    // target the unguarded McpClient.init allocation — sweep until it does.
    const underlying = std.testing.allocator;
    var hit_failure = false;
    var hit_client = false;
    var fail_index: usize = 1;
    // 2048: loadEnvMap allocates per process environment variable, so the
    // indices consumed before the unguarded McpClient.init allocation vary
    // by machine — the bound must clear the whole expand path with headroom
    // even on dev boxes with very large environments. A bound inside the
    // env-var count would observe zero failures and fail the sweep's final
    // assertions (review of #307).
    while (fail_index <= 2048) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(underlying, .{ .fail_index = fail_index });
        var manager = McpManager.init(failing.allocator());
        defer manager.deinit(std.testing.io);

        var servers = try underlying.alloc(config_mod.McpServerConfig, 1);
        const arg_storage = try underlying.alloc([]u8, 1);
        arg_storage[0] = try underlying.dupe(u8, "--hello");
        servers[0] = .{
            .name = try underlying.dupe(u8, "alpha"),
            .enabled = true,
            .transport = .{ .stdio = .{
                .command = try underlying.dupe(u8, "echo"),
                .args = arg_storage,
            } },
        };
        var cfg: config_mod.Config = .{ .mcp_servers = servers };
        defer cfg.deinit(underlying);

        if (manager.syncFromConfig(std.testing.io, &cfg)) |_| {
            // Success means either the client registered or an early index
            // was consumed by the expand path, which skips with its own warn.
            if (manager.clients.items.len == 1) hit_client = true;
        } else |err| {
            hit_failure = true;
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), manager.clients.items.len);
        }
    }
    try std.testing.expect(hit_failure);
    try std.testing.expect(hit_client);
}

test "McpManager does not reconnect already connected clients" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = .{
        .name = try arena.dupe(u8, "stable"),
        .enabled = true,
        .transport = .{ .stdio = .{
            .command = try arena.dupe(u8, "echo"),
        } },
    };
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    // First sync: registers as .connecting
    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(client_mod.ServerStatus.connecting, manager.clients.items[0].status());

    // Simulate a successful connection
    manager.clients.items[0].lifecycle = .{ .stdio = .{ .process = client_mod.zeroedChild(), .status = .ready } };

    // Second sync: should NOT change status of already-connected client
    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());
}

test "McpManager skips duplicate server names in config" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 2);
    servers[0] = .{
        .name = try arena.dupe(u8, "dup"),
        .enabled = true,
        .transport = .{ .stdio = .{
            .command = try arena.dupe(u8, "echo"),
        } },
    };
    servers[1] = .{
        .name = try arena.dupe(u8, "dup"),
        .enabled = true,
        .transport = .{ .stdio = .{
            .command = try arena.dupe(u8, "cat"),
        } },
    };
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    try manager.syncFromConfig(std.testing.io, &cfg);
    // Only the first "dup" should be registered
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    switch (manager.clients.items[0].transport) {
        .stdio => |t| try std.testing.expectEqualStrings("echo", t.command),
        .sse => return error.Unexpected,
    }
}

test "McpManager async connect spawns, handshakes, discovers, and installs" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "mock", "default");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try std.testing.expect(manager.hasPendingConnects());

    try drainUntilConnected(&manager, std.testing.io);

    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);
    try std.testing.expectEqualStrings("mcp__mock__greet", manager.clients.items[0].discovery.tools.items[0].full_name);
    try std.testing.expectEqual(@as(usize, 1), manager.activeServerCount());
    try std.testing.expect(!manager.hasPendingConnects());
}

test "McpManager buildMcpToolSchemas carries the raw inputSchema" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "rich", "rich_schema");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try drainUntilConnected(&manager, std.testing.io);

    const schemas = try manager.buildMcpToolSchemas(gpa);
    defer gpa.free(schemas);
    try std.testing.expectEqual(@as(usize, 1), schemas.len);
    const raw = schemas[0].raw_input_schema orelse return error.RawSchemaMissing;
    try std.testing.expectEqualStrings("mcp__rich__query", schemas[0].name);
    // The borrowed raw form is the client's verbatim capture — the
    // serialization path can pass it through without another copy.
    try std.testing.expectEqualStrings(manager.clients.items[0].discovery.tools.items[0].raw_input_schema.?, raw);
}

test "McpManager reconnect frees and re-captures raw inputSchemas" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "rich", "rich_schema");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try drainUntilConnected(&manager, std.testing.io);

    const client = manager.clients.items[0];
    try std.testing.expectEqual(client_mod.ServerStatus.connected, client.status());
    const raw_before = try gpa.dupe(u8, client.discovery.tools.items[0].raw_input_schema.?);
    defer gpa.free(raw_before);
    try std.testing.expect(std.mem.indexOf(u8, raw_before, "$defs") != null);

    // Reconnect: the old tool records (raw schemas included) are freed and
    // re-discovered. The testing allocator's leak check at process end pins
    // that the pre-reconnect raw schema was actually released.
    manager.reconnectClient(std.testing.io, 0);
    try drainUntilConnected(&manager, std.testing.io);

    const refreshed = manager.clients.items[0];
    try std.testing.expectEqual(client_mod.ServerStatus.connected, refreshed.status());
    try std.testing.expectEqual(@as(usize, 1), refreshed.discovery.tools.items.len);
    const raw_after = refreshed.discovery.tools.items[0].raw_input_schema orelse return error.RawSchemaMissing;
    try std.testing.expectEqualStrings(raw_before, raw_after);
}

test "McpManager async connect failure marks the client failed with a reason" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "dead", "fail");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try std.testing.expect(manager.hasPendingConnects());
    try drainUntilConnected(&manager, std.testing.io);

    try std.testing.expectEqual(client_mod.ServerStatus.failed, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 0), manager.activeServerCount());
    switch (manager.clients.items[0].lifecycle) {
        .failed => |f| {
            try std.testing.expect(f.reason.len > 0);
            try std.testing.expect(std.mem.indexOf(u8, f.reason, "Handshake failed") != null);
        },
        else => return error.UnexpectedLifecycle,
    }
}

test "McpManager async connect fails on a malformed tool discovery response" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "bad-tools", "malformed_tools");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try drainUntilConnected(&manager, std.testing.io);

    try std.testing.expectEqual(client_mod.ServerStatus.failed, manager.clients.items[0].status());
    switch (manager.clients.items[0].lifecycle) {
        .failed => |f| try std.testing.expect(std.mem.indexOf(u8, f.reason, "Tool discovery failed") != null),
        else => return error.UnexpectedLifecycle,
    }
}

test "McpManager discards a connect outcome when the client is disconnected mid-flight" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "flaky", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try std.testing.expect(manager.hasPendingConnects());

    // Disconnect while the connect is in flight — the completed outcome must
    // be discarded, never resurrecting the server.
    manager.disconnectClient(std.testing.io, 0);
    try drainUntilConnected(&manager, std.testing.io);

    try std.testing.expectEqual(client_mod.ServerStatus.disabled, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 0), manager.clients.items[0].discovery.tools.items.len);
    try std.testing.expect(!manager.hasPendingConnects());
}

test "McpManager does not launch a second connect while one is pending" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A silent server keeps the job pending long enough to double-sync.
    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "slow", "hang");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    manager.syncFromConfigEx(std.testing.io, &cfg);
    try std.testing.expectEqual(@as(usize, 1), manager.pending_connects.items.len);
}

test "launchConnect initializes every ConnectJob field" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "lazy", "hang");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    try manager.syncFromConfig(io, &cfg);
    manager.launchConnect(io, "lazy");
    try std.testing.expect(manager.hasPendingConnects());

    // Read the job before its worker has had any chance to run: an
    // uninitialized `failed_message` reads as a non-null garbage slice
    // (0xAA fill in Debug) and teardown frees a wild pointer — the
    // shutdown crash when quitting with connects still in flight.
    const job = manager.pending_connects.items[0];
    try std.testing.expect(job.failed_message == null);
    try std.testing.expect(!job.done.load(.acquire));
}

test "McpManager deinit while a connect is in flight joins and tears down" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    // `deinit` is the code under test — no defer.

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A server that never speaks JSON-RPC keeps the handshake in flight until
    // teardown terminates the child process.
    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "hang", "hang");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    try manager.syncFromConfig(io, &cfg);
    manager.clients.items[0].read_timeout_ms = 60_000;
    manager.launchConnect(io, "hang");
    try std.testing.expect(manager.hasPendingConnects());
    try io.sleep(.fromMilliseconds(100), .awake);

    // Quit while the connect is in flight: `deinit` must cancel the pending
    // response wait instead of waiting out its 60-second timeout.
    const started = std.Io.Timestamp.now(io, .awake);
    manager.deinit(io);
    const elapsed_ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

test "McpManager deinit cancels a partial stdio response" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "partial", "partial");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    try manager.syncFromConfig(io, &cfg);
    manager.clients.items[0].read_timeout_ms = 60_000;
    manager.launchConnect(io, "partial");
    try std.testing.expect(manager.hasPendingConnects());
    try io.sleep(.fromMilliseconds(100), .awake);

    // A partial line must remain cancelable. Entering the blocking delimiter
    // reader after PeekNamedPipe observes bytes would wedge this join.
    const started = std.Io.Timestamp.now(io, .awake);
    manager.deinit(io);
    const elapsed_ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

// ---------------------------------------------------------------------------
// Discovery-cache/lifecycle invariants (#384): a non-connected lifecycle
// never carries tools, and a live transport is stopped before it is dropped.
// ---------------------------------------------------------------------------

test "McpManager toggle-off clears the cache so a re-enabled server reconnects" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "toggle", "default");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try drainUntilConnected(&manager, std.testing.io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);

    // Toggle-off (command_router's connected arm goes through
    // `disconnectClient`): the transport goes down and the discovery cache
    // goes down WITH it — a disabled lifecycle never carries tools.
    manager.disconnectClient(std.testing.io, 0);
    try std.testing.expectEqual(client_mod.ServerStatus.disabled, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 0), manager.clients.items[0].discovery.tools.items.len);

    // The server is still enabled in config: the reconcile marks it
    // connecting again and — because the cache is cleared — launches a
    // fresh connect. With stale tools this used to be skipped and the
    // server wedged in CONNECTING forever (#384 bug 1).
    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(client_mod.ServerStatus.connecting, manager.clients.items[0].status());

    manager.syncFromConfigEx(std.testing.io, &cfg);
    try std.testing.expect(manager.hasPendingConnects());
    try drainUntilConnected(&manager, std.testing.io);

    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);
    try std.testing.expect(!manager.hasPendingConnects());
}

test "McpManager config-disable stops the child and clears the cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // After discovery the mock sits blocked in its stdin read loop and only
    // `stop()` ends it (closing stdin / terminating), so the process-death
    // probe below can only pass if the disable actually tore the child down
    // — the raw `.disabled` write this replaced orphaned it, keeping the
    // child alive forever with its stdin still open (#384 bug 4).
    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "orphan", "default");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);

    // Watch the child while the client still owns it — the watch survives
    // the client closing its own process handle.
    var watch: ?os.ChildExitWatch = os.ChildExitWatch.init(&manager.clients.items[0].lifecycle.stdio.process);
    defer if (watch) |*w| w.deinit();
    if (os.ChildExitWatch.supported) try std.testing.expect(watch != null);

    // The server flips to disabled in config on the next reconcile.
    servers[0].enabled = false;
    try manager.syncFromConfig(io, &cfg);

    try std.testing.expectEqual(client_mod.ServerStatus.disabled, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 0), manager.clients.items[0].discovery.tools.items.len);
    // No orphan: bounded wait on the process itself.
    if (watch) |*w| try std.testing.expect(w.awaitExit(io, 2_000));
}

test "McpManager relaunches a connect for a failed server with a cleared cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    // Arena-backed config fixture (PR-2b): mirrors the App hand-off —
    // the config tree lives in this arena and is released in one shot;
    // no per-field Config.deinit, no gpa frees for fixture slices.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "recover", "default");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());

    // A re-discovery failure on a connected client lands via `setError`
    // (the list_changed path in provider_model): the transport stops, the
    // lifecycle fails — and the discovery cache must go down with it, or
    // the reconcile wedges the server in CONNECTING with stale tools (bug
    // 1's shape through the failed arm).
    const client = manager.clients.items[0];
    try client.addTool("stale", "Cached before the failure", .{ .properties = &.{} }, null);
    client.setError(io, "list_changed re-discovery failed", .{});
    try std.testing.expectEqual(client_mod.ServerStatus.failed, client.status());
    try std.testing.expectEqual(@as(usize, 0), client.discovery.tools.items.len);

    // Still enabled in config: the reconcile marks it connecting (freeing
    // the failure reason) and launches a fresh connect.
    try manager.syncFromConfig(io, &cfg);
    try std.testing.expectEqual(client_mod.ServerStatus.connecting, client.status());

    manager.syncFromConfigEx(io, &cfg);
    try std.testing.expect(manager.hasPendingConnects());
    try drainUntilConnected(&manager, io);

    // The completed connect replaced the heap slot (#385) — the retired
    // original the assertions above held is gone; read the live slot.
    const reconnected = manager.clients.items[0];
    try std.testing.expect(reconnected != client);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, reconnected.status());
    try std.testing.expectEqual(@as(usize, 1), reconnected.discovery.tools.items.len);
}

// ---------------------------------------------------------------------------
// Background tool re-discovery (#385): the UI tick never blocks on a
// re-discovery request; outcomes install on the main thread via drain.
// ---------------------------------------------------------------------------

/// Poll `drainToolRefreshes` until every pending refresh job has completed
/// and been installed (or discarded). Mirrors the TUI tick loop's role.
fn drainUntilRefreshed(manager: *McpManager, io: std.Io) !void {
    var deadline: usize = 0;
    while (manager.hasPendingRefreshes()) : (deadline += 1) {
        if (deadline > 2000) return error.RefreshTimedOut;
        _ = manager.drainToolRefreshes(io);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

test "McpManager tool refresh launches off the tick thread and installs on drain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // slow mode: a synchronous re-discovery (the pre-#385 UI-tick path)
    // would block the caller for the request's full 500ms; the launched
    // job must hand the wait to a background worker instead.
    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "slow-refresh", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());

    // A stale record the fresh discovery must fully replace.
    try manager.clients.items[0].addTool("stale", "Cached before the refresh", .{ .properties = &.{} }, null);
    manager.clients.items[0].discovery.storeRefreshPending();

    const started = std.Io.Timestamp.now(io, .awake);
    manager.launchToolRefresh(io, "slow-refresh");
    const launch_elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;

    // A/B signal: launching is non-blocking (the old synchronous path spent
    // >= 500ms inside the request; launch itself must stay far below that).
    try std.testing.expect(launch_elapsed < 100 * std.time.ns_per_ms);
    try std.testing.expect(manager.hasPendingRefreshes());

    try drainUntilRefreshed(&manager, io);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);
    try std.testing.expectEqualStrings("greet", manager.clients.items[0].discovery.tools.items[0].name);
    try std.testing.expect(!manager.hasPendingRefreshes());
}

test "McpManager dedupes concurrent tool refresh launches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "dedupe", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    manager.clients.items[0].discovery.storeRefreshPending();

    manager.launchToolRefresh(io, "dedupe");
    manager.launchToolRefresh(io, "dedupe");
    try std.testing.expectEqual(@as(usize, 1), manager.pending_refreshes.items.len);
    try drainUntilRefreshed(&manager, io);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);
}

test "launchToolRefresh initializes every RefreshJob field" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "lazy-refresh", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    manager.clients.items[0].discovery.storeRefreshPending();
    manager.launchToolRefresh(io, "lazy-refresh");
    try std.testing.expect(manager.hasPendingRefreshes());

    // Read the job before its worker has had any chance to run: an
    // uninitialized `done` reads as true, so `drainToolRefreshes` would
    // await a future whose worker never ran; uninitialized `fresh`/`err`
    // free or read garbage (0xAA fill in Debug).
    const job = manager.pending_refreshes.items[0];
    try std.testing.expect(job.fresh.items.len == 0);
    try std.testing.expect(job.err == null);
    try std.testing.expect(!job.owns_client);
    try std.testing.expect(!job.done.load(.acquire));
}

test "McpManager tool refresh failure marks the client failed at drain and recovers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "die-refresh", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    const client = manager.clients.items[0];

    // Kill the child process directly (the client's own lifecycle stays
    // `.connected`) while the refresh worker is inside its request: the
    // worker fails loudly, and the DRAIN (main thread) — never the worker —
    // routes the failure through setError, failing the lifecycle. (Calling
    // `stop` here would disable the client, and the drain would discard the
    // outcome instead of exercising the failure arm.)
    client.discovery.storeRefreshPending();
    manager.launchToolRefresh(io, "die-refresh");
    try io.sleep(.fromMilliseconds(50), .awake);
    client.lifecycle.stdio.process.kill(io);

    try drainUntilRefreshed(&manager, io);
    try std.testing.expectEqual(client_mod.ServerStatus.failed, client.status());
    switch (client.lifecycle) {
        .failed => |f| try std.testing.expect(std.mem.indexOf(u8, f.reason, "list_changed re-discovery failed") != null),
        else => return error.UnexpectedLifecycle,
    }

    // The #384 recovery contract extends to the async path: still enabled
    // in config, the reconcile relaunches a connect for the failed server.
    manager.syncFromConfigEx(io, &cfg);
    try std.testing.expect(manager.hasPendingConnects());
    try drainUntilConnected(&manager, io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);
}

test "McpManager discards a refresh outcome when the client is disconnected mid-flight" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "disc-refresh", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);

    manager.clients.items[0].discovery.storeRefreshPending();
    manager.launchToolRefresh(io, "disc-refresh");
    manager.disconnectClient(io, 0);

    try drainUntilRefreshed(&manager, io);
    try std.testing.expectEqual(client_mod.ServerStatus.disabled, manager.clients.items[0].status());
    try std.testing.expectEqual(@as(usize, 0), manager.clients.items[0].discovery.tools.items.len);
}

test "McpManager discards a refresh outcome and retires the client when it is replaced mid-flight" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "repl-refresh", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    const old_client = manager.clients.items[0];

    // Launch a refresh against the live client, then reconnect: stop-first
    // teardown parks the pipes under the in-flight refresh worker (the
    // transport-lifetime bracket), and the completed connect replaces the
    // slot — the retired original is handed to the job and destroyed at
    // drain, after future.await proved the worker exited.
    old_client.discovery.storeRefreshPending();
    manager.launchToolRefresh(io, "repl-refresh");
    manager.reconnectClient(io, 0);

    try drainUntilConnected(&manager, io);
    try drainUntilRefreshed(&manager, io);

    const replaced = manager.clients.items[0];
    try std.testing.expect(replaced != old_client);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, replaced.status());
    try std.testing.expectEqual(@as(usize, 1), replaced.discovery.tools.items.len);
    try std.testing.expect(!manager.hasPendingRefreshes());
}

test "McpManager deinit while a tool refresh is in flight joins and tears down" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    // `deinit` is the code under test — no defer.

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "hang-refresh", "slow");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    manager.clients.items[0].discovery.storeRefreshPending();
    manager.launchToolRefresh(io, "hang-refresh");
    try std.testing.expect(manager.hasPendingRefreshes());
    try io.sleep(.fromMilliseconds(100), .awake);

    // Quit while the refresh is in flight: `deinit` must cancel the pending
    // response wait instead of waiting out the request.
    const started = std.Io.Timestamp.now(io, .awake);
    manager.deinit(io);
    const elapsed_ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

test "interleaved list_changed re-arms the refresh flag through the async path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = McpManager.init(gpa);
    defer manager.deinit(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // interleaved mode: the server pushes tools/list_changed before
    // answering the first tools/list — the notification captured during
    // discovery must leave the flag set for the next tick.
    var servers = try arena.alloc(config_mod.McpServerConfig, 1);
    servers[0] = try mockStdioConfig(arena, "interleaved", "interleaved");
    var cfg: config_mod.Config = .{ .mcp_servers = servers };

    manager.syncFromConfigEx(io, &cfg);
    try drainUntilConnected(&manager, io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status());
    try std.testing.expect(manager.clients.items[0].pollToolsRefresh());

    // The full pipeline then still works: launch, drain, install. The mock
    // echoes the CONFIG name (not the default "mock") into the namespace.
    manager.launchToolRefresh(io, "interleaved");
    try drainUntilRefreshed(&manager, io);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items[0].discovery.tools.items.len);
    try std.testing.expectEqualStrings("mcp__interleaved__greet", manager.clients.items[0].discovery.tools.items[0].full_name);
}
