//! context_assembly.zig — re-export umbrella for the split context modules.
//!
//! The original single-file assembly engine grew past 2000 lines with no
//! locality between its halves, so it split (strangler-fig) into:
//!   - `rules.zig` — system-prompt assembly: dynamic environment injection and
//!     rule ingestion (user AGENTS.md first, then project conventions, one
//!     shared aggregate byte budget), plus refresh snapshots.
//!   - `prune.zig` — historical tool-result pruning (recent turns kept in full,
//!     ancient tool outputs capped), history image eviction with re-mention
//!     stubs, and pruned-request token estimates.
//!   - Attachment budgeting (per-file and aggregate byte limits for @-mention
//!     file inlining) remains in `at_mention.zig`, the module that owns
//!     expansion.
//!
//! Every externally referenced declaration is re-exported here unchanged, so
//! `agent.zig`, `runtime.zig`, `config/config.zig`, and `root.zig` need no
//! import-path changes.

const rules = @import("rules.zig");
const prune = @import("prune.zig");

// ─── rules.zig ───────────────────────────────────────────────────────────

pub const RefreshSnapshot = rules.RefreshSnapshot;
pub const captureRefreshSnapshot = rules.captureRefreshSnapshot;
pub const max_project_rule_file_bytes = rules.max_project_rule_file_bytes;
pub const max_aggregate_project_rule_bytes = rules.max_aggregate_project_rule_bytes;
pub const assembleSystemPrompt = rules.assembleSystemPrompt;
pub const assembleSystemPromptForRefresh = rules.assembleSystemPromptForRefresh;
pub const substituteBaseTemplate = rules.substituteBaseTemplate;

// ─── prune.zig ───────────────────────────────────────────────────────────

pub const default_historical_tool_cap_bytes = prune.default_historical_tool_cap_bytes;
pub const default_keep_recent_tool_turns = prune.default_keep_recent_tool_turns;
pub const PrunedToolCache = prune.PrunedToolCache;
pub const pruneHistoricalToolResultsViews = prune.pruneHistoricalToolResultsViews;
pub const pruneHistoricalToolResultsViewsCached = prune.pruneHistoricalToolResultsViewsCached;
pub const pruneHistoricalToolResultsViewsWithSkills = prune.pruneHistoricalToolResultsViewsWithSkills;
pub const freePrunedViews = prune.freePrunedViews;
pub const evictHistoryImagesViews = prune.evictHistoryImagesViews;
pub const evicted_image_stub_tokens = prune.evicted_image_stub_tokens;
pub const estimatePrunedTokensRange = prune.estimatePrunedTokensRange;
pub const estimatePrunedTokensRangeWithSkills = prune.estimatePrunedTokensRangeWithSkills;

// ─── Tests ───────────────────────────────────────────────────────────────

test {
    _ = rules;
    _ = prune;
}
