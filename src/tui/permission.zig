//! Permission overlay: approval/rejection of tool calls. Free functions taking
//! `*App`.

const std = @import("std");
const vaxis = @import("vaxis");

const tui = @import("../tui.zig");
const agent_worker = @import("agent_worker.zig");

const App = tui.App;

pub fn permissionPending(app: *App) bool {
    const worker = if (app.thread.worker_context) |*context| context else return false;
    return worker.approval.pending(worker.io);
}

pub fn handlePermissionKey(app: *App, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.left, .{})) {
        app.thread.permission_selection = .approve;
        return true;
    }
    if (key.matches(vaxis.Key.right, .{})) {
        app.thread.permission_selection = .reject;
        return true;
    }
    if (key.matches(vaxis.Key.up, .{})) {
        if (app.thread.permission_scroll > 0) app.thread.permission_scroll -= 1;
        return true;
    }
    if (key.matches(vaxis.Key.down, .{})) {
        app.thread.permission_scroll += 1;
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        try resolvePermission(app, app.thread.permission_selection);
        return true;
    }
    if (key.matches('y', .{}) or key.matches('a', .{})) {
        try resolvePermission(app, .approve);
        return true;
    }
    if (key.matches('n', .{}) or key.matches('r', .{})) {
        try resolvePermission(app, .reject);
        return true;
    }
    return false;
}

pub fn resolvePermission(app: *App, decision: agent_worker.ApprovalDecision) !void {
    const worker = if (app.thread.worker_context) |*context| context else return;
    try worker.approval.resolve(worker.io, decision);
    app.thread.permission_scroll = 0;
    app.thread.permission_selection = .approve;
}
