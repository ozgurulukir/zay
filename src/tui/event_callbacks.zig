//! Event callbacks for vxfw text input change notifications. Free functions
//! that receive `?*anyopaque` (the `App` pointer) from the framework.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const provider_model = @import("provider_model.zig");
const resume_picker = @import("widgets/resume_picker.zig");

const App = tui.App;

pub fn inputChanged(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.nav.block_nav = false;
    const was_command = app.mode == .command;
    try app.syncModeWithInput(value);
    if (!was_command and app.mode == .command) {
        app.clearInput();
        app.clearPaletteInput();
        try ctx.requestFocus(app.inputs.palette.widget());
    }
    if (app.mode == .normal) {
        try app.updateAtSearch();
    } else {
        app.closeAtSearch();
    }
    ctx.consumeAndRedraw();
}

pub fn paletteInputChanged(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    switch (app.mode) {
        .command => {
            const count = tui.commandMatchesCountForFilter(app, value);
            if (app.nav.command_selection >= count) app.nav.command_selection = 0;
        },
        .session_picker => {
            // Sub-states (rename/delete) don't use the palette input for
            // filtering — skip the visible-count recompute.
            if (app.nav.session_action == .browsing) {
                const count = resume_picker.visibleCount(app.io, app.resume_summaries.items, value, app.resume_folded_projects.items, app.nav.resume_group_by);
                if (app.nav.resume_selection >= count) app.nav.resume_selection = 0;
                app.syncResumeListCursor();
            }
        },
        .tree_picker => {
            try app.pickers.tree.reflattenKeepingSelection(value);
        },
        .model_picker => {
            if (!provider_model.modelDisplayMatches(app, app.pickers.models.model_selection, value)) {
                app.pickers.models.model_selection = provider_model.firstMatchingModelDisplay(app, value) orelse 0;
            }
        },
        .diff_viewer => {
            if (app.diff.sub == .file_search) try app.diff.filterFiles(app.gpa, value);
        },
        .provider_picker, .normal, .save_message, .lanes, .help, .settings, .mcp, .plugins => {},
    }
    ctx.consumeAndRedraw();
}
