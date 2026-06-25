//! Background connectivity probe for catalogue providers. A stored API key in
//! `auth.json` only proves a key was *entered*, not that it still works — keys
//! expire and endpoints go down. This module re-uses the provider's `/models`
//! call (the same probe that decides whether a provider's models load) to tell
//! whether the credentials are live, so the picker badge reflects reality
//! instead of mere key presence.

const std = @import("std");

const openai_compatible_mod = @import("../ai/openai_compatible.zig");

/// Per-provider connectivity, mirrored into the picker badge.
///   unknown   — no credentials to check (no key and no anonymous tier).
///   checking  — a probe is in flight.
///   connected — the last probe succeeded.
///   failed    — credentials exist but the probe failed (expired key, 4xx,
///               unreachable host, …).
pub const Status = enum { unknown, checking, connected, failed };

pub const Outcome = enum { connected, failed };

/// Snapshot the worker needs to probe one provider. Owns its strings and frees
/// them (plus itself) on exit, so the App layer can mutate its key map without
/// racing the worker.
pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    api_key: []u8,
    done: *std.atomic.Value(bool),

    fn deinit(self: *Job) void {
        self.gpa.free(self.base_url);
        self.gpa.free(self.api_key);
        self.* = undefined;
    }
};

/// Worker entry point for `io.concurrent`. Owns `job` — frees it on exit and
/// flips `job.done` so the main loop knows it can `await` without blocking.
pub fn run(job: *Job) Outcome {
    const gpa = job.gpa;
    const done = job.done;
    defer {
        job.deinit();
        gpa.destroy(job);
        done.store(true, .release);
    }

    // A `/models` 2xx means the credentials are live; any error (4xx for an
    // expired/invalid key, 5xx, a network failure) means they are not.
    const fetched = openai_compatible_mod.listModels(gpa, job.io, job.base_url, job.api_key) catch
        return .failed;
    for (fetched) |*entry| entry.deinit(gpa);
    gpa.free(fetched);
    return .connected;
}
