# tui-domain-extract-2 — Backlog

## Refactor targets

Continue Strangler Fig extraction from `tui.zig` (4141 lines → target ~3000).

### Phase 1: Queue management → `tui/queue.zig` *(committed `08a7485`)*

8 functions: enqueueSubmit, selectPrevQueued, selectNextQueued, steerSelectedQueued,
appendMessageQueueFullNotice, appendSkillInvocationsToTranscript,
flushQueuedUserMessagesToTranscript, clearQueuedUserMessages.

### Spotted but deferred

- Background modal (~50 lines) — toggleBackgroundModal, handleBackgroundModalKey, cancelSelectedBackgroundJob
- Checkpoint (~60 lines) — sealCheckpoint, noteCheckpointFailure/Succeeded, checkpointBoundary/FinishedTurn, ensureCheckpointReady
- Turn lifecycle (~200 lines) — beginSubmit, startTurn, restartTurnForQueuedMessages, startDeliveryTurnOnCurrentThread, laneForAgent, setLaneTitleIfUnset, formatNoProviderMessage, resetTurnState
- Agent event (~60 lines) — applyAgentEvent, awaitTurn
- Save (~30 lines) — beginSave, saveActiveLane
- Command palette (~80 lines) — Command enum, resolveCommand, commandMatchesCount, startsWithIgnoreCase
- RootWidget → tui/root_widget.zig (~100 lines)
- Init/deinit (~110 lines)
- submitMode/cancelMode (~125 lines) — stays per R6.0 audit
