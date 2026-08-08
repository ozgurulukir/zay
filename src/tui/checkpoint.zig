//! Git checkpoint and save command logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const tui = @import("../tui.zig");
const vcs = @import("../vcs.zig");

const App = tui.App;

/// What a `sealCheckpoint` attempt did — so callers can tell a genuine
/// failure apart from the benign "nothing to bind" and "git unavailable"
/// cases and surface only the former.
pub const SealOutcome = enum { sealed, nothing, unavailable, failed };

/// Snapshot the working tree (git-shadow) and bind the resulting commit id to
/// the active conversation leaf, so navigating back here restores this code
/// state. HEAD stays attached to the branch; the snapshot is an off-branch
/// commit kept alive by a `refs/nova/*` ref. A git or persistence error
/// returns `.failed` — never swallowed silently, since a missing binding is
/// exactly what broke timeline navigation before.
pub fn sealCheckpoint(app: *App) SealOutcome {
    const rt = app.liveRuntime() orelse return .unavailable;
    if (!ensureCheckpointReady(app)) return .unavailable;
    const index = vcs.indexPath(app.gpa, app.getIo(), rt.cwd) catch return .failed;
    defer app.gpa.free(index);
    const sha = vcs.snapshot(app.gpa, app.getIo(), rt.cwd, index) catch return .failed;
    rt.session_writer.setLeafSnapshot(sha.slice()) catch return .failed;
    // Bind only makes sense if there is a leaf entry to bind to; otherwise the
    // snapshot is an orphan (gc'd later) — report nothing happened.
    const leaf_id = rt.session_writer.leaf() orelse return .nothing;
    // Keep the snapshot reachable against `git gc`, named by the entry it
    // binds so it can be pruned with that entry.
    vcs.keepRef(app.gpa, app.getIo(), rt.cwd, leaf_id, sha) catch {};
    return .sealed;
}

/// Tell the user a snapshot couldn't be taken — once. A persistently broken
/// git would otherwise append this every turn; the flag clears the next time
/// a snapshot succeeds (see `noteCheckpointSucceeded`).
pub fn noteCheckpointFailure(app: *App) void {
    if (app.checkpoint_warned) return;
    app.checkpoint_warned = true;
    _ = app.thread.transcript.append(app.gpa, .notice, "notice", "Couldn't snapshot the working tree — timeline navigation may not restore this point's files. Check that `git` works in this repo.") catch {};
}

pub fn noteCheckpointSucceeded(app: *App) void {
    app.checkpoint_warned = false;
}

/// Snapshot at a turn boundary and surface a genuine failure to the user
/// (deduped). Every place that must bind the current code state to the
/// conversation goes through here, so a broken snapshot is never silent.
pub fn checkpointBoundary(app: *App) void {
    switch (sealCheckpoint(app)) {
        .sealed => noteCheckpointSucceeded(app),
        .failed => noteCheckpointFailure(app),
        .nothing, .unavailable => {},
    }
}

/// Seal at the end of a turn (clean or interrupted, so a turn that wrote
/// files before being cut still binds them to a snapshot).
pub fn checkpointFinishedTurn(app: *App) void {
    checkpointBoundary(app);
}

/// `/save` entry point: reject when the working tree has nothing to commit,
/// otherwise open the commit-message prompt. `saveActiveLane` commits on
/// confirm.
pub fn beginSave(app: *App) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const rt = app.liveRuntime() orelse return error.NoActiveRuntime;

    if (!(vcs.workingTreeDirty(app.gpa, app.getIo(), rt.cwd) catch true)) {
        _ = try app.thread.transcript.append(app.gpa, .notice, "notice", "Nothing to save — the working tree matches the last commit.");
        return;
    }

    // Prompt for a commit message; `submitMode` calls `saveActiveLane` on
    // confirm. Prefill the lane title as an editable suggestion.
    app.mode = .save_message;
    app.clearInput();
    app.clearPaletteInput();
    if (app.thread.title) |title| app.inputs.palette.insertSliceAtCursor(title) catch {};
}

/// `/save`: commit the current working tree onto the lane's branch with the
/// user's message. In the git-shadow model HEAD stays attached, so this is
/// just `git add -A && git commit` — the working tree *is* the state to keep;
/// the off-branch snapshot chain never reaches the branch. `message` is the
/// user-supplied commit message (see `beginSave`).
pub fn saveActiveLane(app: *App, message: []const u8) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const rt = app.liveRuntime() orelse return error.NoActiveRuntime;
    try vcs.commitAll(app.gpa, app.getIo(), rt.cwd, message);
    _ = try app.thread.transcript.append(app.gpa, .success, "notice", "Saved — committed the working tree to the current branch.");
}

/// Resolve once whether the git-shadow snapshot feature can run: git
/// installed and the working copy inside a git repo. Cached per session.
pub fn ensureCheckpointReady(app: *App) bool {
    switch (app.checkpoint_state) {
        .ready => return true,
        .unavailable => return false,
        .unknown => {},
    }
    const repo = app.repoRoot() orelse {
        app.checkpoint_state = .unavailable;
        return false;
    };
    const ok = vcs.isAvailable(app.gpa, app.getIo()) and vcs.isRepo(app.gpa, app.getIo(), repo);
    app.checkpoint_state = if (ok) .ready else .unavailable;
    return ok;
}
