# tui-domain-extract-2 — Done

- **Phase 1** `tui/queue.zig` — extract queue management *(2026-07-22, commit `08a7485`)*
  - 8 functions moved. `appendSkillInvocationsToTranscript` made `pub`.
  - `tui.zig` 4141 → **4097** (-44). `queue.zig` +83 lines.
  - `zig build` and `zig build test` pass.
