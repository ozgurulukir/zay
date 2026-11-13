//! Per-turn continuation policy: the hard cap on tool calls per turn and the
//! two knobs that decide how a bounded turn ends (graceful soft stop on
//! budget exhaustion, one-shot auto-continue after a provider length cut).
//!
//! Ownership: this module holds the policy state, the pure budget math the
//! turn loop gates on, and the machine-authored continuation hints those
//! paths inject. The orchestration that consumes them — the `runTurn` loop,
//! `softStopOnBudget` (queue drain + history append + listener events),
//! `handleLengthCut` — stays on `Agent` because it drives the message queue,
//! history, and event stream; `turn_budget` is deliberately a plain value
//! struct with no back-reference (the #367 slice-2 seam, extraction over
//! facade). Set by the runtime from `config.context`; defaults match the
//! pre-extraction constants so agents created without a config keep the
//! historical contract.

const std = @import("std");
const config_mod = @import("../config/config.zig");

/// Trailing machine-authored continuation hint left in history after a soft
/// budget stop. Role `.user` (not `.system`) because `SessionWriter.append`
/// skips system messages — `.user` survives `/resume`, branch switches, and
/// compaction reprojection, and Qwen's single-leading-system normalization
/// never touches it. Static text: the event carries the limit for the human;
/// the model does not need the number.
pub const tool_budget_continuation_hint =
    "[zay] This turn stopped early because the per-turn tool-call budget was reached. " ++
    "Work done so far is intact. When the user asks to continue, briefly summarize " ++
    "completed steps, then pick up exactly where the work left off.";
/// Trailing machine-authored continuation hint appended when a response was
/// severed by the provider's output token cap (`finish_reason=length`) with
/// no tool calls: the prose landed, the tool_call section did not. Same
/// `.user`-role reasoning as `tool_budget_continuation_hint` (survives
/// resume/compaction; Qwen normalization never touches it).
pub const length_cut_continuation_hint =
    "[zay] Your previous response was cut off by the output token limit before it finished. " ++
    "Continue from exactly where it stopped; if you were about to call a tool, emit that tool call now.";

pub const TurnBudget = struct {
    /// Per-turn hard cap on individual tool calls. Model-response iterations
    /// are also capped by this value so queued continuations remain bounded.
    /// Set by the runtime from `config.context.tool_call_limit_per_turn`;
    /// the default matches `config_mod.default_tool_call_limit_per_turn`.
    tool_call_limit_per_turn: u32 = config_mod.default_tool_call_limit_per_turn,
    /// When true, exhausting `tool_call_limit_per_turn` ends the turn
    /// gracefully (drain + hint + typed event) instead of failing with
    /// `error.ToolCallLimit`. Default true; `false` restores the historical
    /// hard-failure contract byte-for-byte.
    soft_stop_on_tool_call_limit: bool = true,
    /// When true (default), a response severed by the provider's output
    /// token cap (`finish_reason=length`, no tool calls) gets ONE automatic
    /// continuation inside the same turn: a hint is appended and the model
    /// re-requested. Guards against providers whose default completion
    /// budget cuts the tool_call section off after the prose — the turn
    /// otherwise ends as a text-only message that looks complete. Set from
    /// `config.context.auto_continue_on_length_cut`.
    auto_continue_on_length_cut: bool = true,

    /// Whether the turn loop may run another model iteration: both the
    /// iteration counter and the executed-call counter must sit strictly
    /// below the cap. This is `runTurn`'s loop condition, extracted verbatim.
    pub fn hasCapacity(self: TurnBudget, iterations: u32, tool_calls_executed: u32) bool {
        return iterations < self.tool_call_limit_per_turn and tool_calls_executed < self.tool_call_limit_per_turn;
    }

    /// Tool calls still dispatchable this turn. The caller must guarantee
    /// `tool_calls_executed < self.tool_call_limit_per_turn` — `runTurn`
    /// computes this only inside the capacity-gated loop.
    pub fn callsRemaining(self: TurnBudget, tool_calls_executed: u32) usize {
        return @intCast(self.tool_call_limit_per_turn - tool_calls_executed);
    }
};

test "turn budget capacity is exclusive on both axes" {
    var budget: TurnBudget = .{};
    budget.tool_call_limit_per_turn = 2;

    // Strictly below the cap on both counters: the loop keeps running.
    try std.testing.expect(budget.hasCapacity(0, 0));
    try std.testing.expect(budget.hasCapacity(1, 1));
    // Either counter reaching the cap ends the loop — iterations so queued
    // continuations stay bounded, executed calls so the budget is hard.
    try std.testing.expect(!budget.hasCapacity(2, 1));
    try std.testing.expect(!budget.hasCapacity(1, 2));

    // A batch larger than the remaining budget dispatches only the remainder.
    try std.testing.expectEqual(@as(usize, 2), budget.callsRemaining(0));
    try std.testing.expectEqual(@as(usize, 1), budget.callsRemaining(1));
    try std.testing.expectEqual(@as(usize, 0), budget.callsRemaining(2));
}

test "turn budget defaults match the config SSOT and the historical contract" {
    const budget: TurnBudget = .{};

    // The limit defaults to the config module's SSOT, not a copy of it.
    try std.testing.expectEqual(config_mod.default_tool_call_limit_per_turn, budget.tool_call_limit_per_turn);
    // Both continuation knobs default on: budget exhaustion soft-stops
    // (drain + hint + event), a length cut auto-continues exactly once.
    try std.testing.expect(budget.soft_stop_on_tool_call_limit);
    try std.testing.expect(budget.auto_continue_on_length_cut);
}
