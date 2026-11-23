//! Frame-boundary builder for `OverlayWidget` (INV-WIDGET-1).
//!
//! Computes the overlay size, border label, and pure leaf widget view model
//! from `App` state so `src/tui/widgets/overlay.zig` remains 100% `*App`-free.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const ai = @import("../ai.zig");
const codex = @import("../auth/codex.zig");
const tui = @import("../tui.zig");
const model_loader = @import("model_loader.zig");
const plugin_store_job = @import("plugin_store_job.zig");
const tui_status = @import("status.zig");

const command_panel = @import("widgets/command_panel.zig");
const help_picker = @import("widgets/help_picker.zig");
const lanes_picker = @import("widgets/lanes_picker.zig");
const links_picker = @import("widgets/links_picker.zig");
const mcp_status = @import("widgets/mcp_status.zig");
const model_picker = @import("widgets/model_picker.zig");
const overlay = @import("widgets/overlay.zig");
const plugins_status = @import("widgets/plugins_status.zig");
const provider_picker = @import("widgets/provider_picker.zig");
const resume_picker = @import("widgets/resume_picker.zig");
const search_widget = @import("widgets/search.zig");
const settings_widget = @import("widgets/settings.zig");
const theme_picker = @import("widgets/theme_picker.zig");
const tree_selector = @import("widgets/tree_selector.zig");

const App = tui.App;

pub fn overlayLabel(app: *const App) []const u8 {
    return switch (app.mode) {
        .normal => "",
        .command => "Command",
        .session_picker => switch (app.nav.session_action) {
            .browsing => "Search for Sessions",
            .renaming => "Rename Session",
            .deleting => "Delete Session",
            .blocked => "Cannot Delete Active Session",
            .locating_project => "Set Local Project Root",
        },
        .provider_picker => "Connect to Provider",
        .model_picker => "Select Model",
        .tree_picker => "Session Timeline",
        .save_message => "Commit Message",
        .help => "Help & Keyboard Shortcuts",
        .settings => "Settings",
        .mcp => "Model Context Protocol (MCP)",
        .plugins => "Lua Plugins",
        .search => "Search Transcript",
        .theme_picker => "Select Theme",
        .link_picker => "Links in Message",
        .lanes => switch (app.nav.lanes_purpose) {
            .manage => "Parallel Lanes",
            .merge_dest => "Merge Into",
        },
        .diff_viewer => "",
    };
}

pub fn buildOverlayWidget(
    app: *App,
    arena: std.mem.Allocator,
    max_w: u16,
    max_h: u16,
) std.mem.Allocator.Error!overlay.OverlayWidget {
    const size = if (app.mode == .provider_picker and app.pickers.provider.stage == .form)
        overlay.OverlaySize{ .width = @min(max_w, @max(@min(@as(u16, 40), max_w), (max_w * 9) / 10)), .height = @min(max_h, 12) }
    else
        overlay.overlaySize(app.mode, max_w, max_h);
    const total_w: u16 = @min(size.width, max_w);
    const total_h: u16 = @min(size.height, max_h);
    app.drawn_overlay_width = total_w;
    app.drawn_overlay_height = total_h;

    const full_panel = (app.mode == .provider_picker and app.pickers.provider.stage == .form) or
        app.mode == .settings or app.mode == .help or app.mode == .mcp or
        app.mode == .plugins;

    return .{
        .label = overlayLabel(app),
        .width = total_w,
        .height = total_h,
        .full_panel = full_panel,
        .palette_input = if (full_panel) null else &app.inputs.palette,
        .palette = &app.palette,
        .content = try buildOverlayContent(app, arena),
    };
}

fn buildOverlayContent(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!overlay.OverlayContent {
    return switch (app.mode) {
        .command => .{ .command = try buildCommandContent(app, arena) },
        .session_picker => .{ .session = try buildSessionContent(app, arena) },
        .provider_picker => .{ .provider = try buildProviderContent(app, arena) },
        .model_picker => .{ .model = try buildModelContent(app, arena) },
        .tree_picker => .{ .tree = .{
            .state = &app.pickers.tree,
            .list = &app.list_widgets.tree_list,
            .palette = &app.palette,
        } },
        .save_message => .{ .save_message = .{ .text = "" } },
        .lanes => .{ .lanes = .{
            .list = &app.list_widgets.lanes_list,
            .entries = try app.buildLaneEntries(arena),
            .selection = app.nav.lanes_selection,
            .empty_message = switch (app.nav.lanes_purpose) {
                .manage => "  No parked lanes.",
                .merge_dest => "  No lanes to merge into.",
            },
            .palette = &app.palette,
        } },
        .help => .{ .help = .{ .state = &app.pickers.help, .palette = &app.palette } },
        .settings => blk: {
            const runtime = app.liveRuntime();
            break :blk .{ .settings = .{
                .state = &app.pickers.settings,
                .config = &app.cached_config,
                .home_dir = if (runtime) |r| r.home_dir else "",
                .cwd = if (runtime) |r| r.cwd else ".",
                .system_prompt_input = app.input_buffers.settings_text.items,
                .bash_classifier_input = app.input_buffers.settings_text.items,
                .max_content_width_input = app.input_buffers.settings_text.items,
                .palette = &app.palette,
            } };
        },
        .mcp => .{ .mcp = .{
            .state = &app.pickers.mcp,
            .manager = &app.mcp_manager,
            .url_input = app.input_buffers.mcp_url.items,
            .palette = &app.palette,
        } },
        .plugins => .{ .plugins = try buildPluginsContent(app, arena) },
        .search => .{ .search = .{ .state = &app.pickers.search, .palette = &app.palette } },
        .theme_picker => .{ .theme = try buildThemeContent(app, arena) },
        .link_picker => .{ .links = .{ .state = &app.pickers.links, .palette = &app.palette } },
        .normal, .diff_viewer => unreachable,
    };
}

fn buildThemeContent(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!theme_picker.Content {
    const filter = try app.peekPaletteInputArena(arena);
    const active_name = app.theme_registry.resolveWithScheme(
        app.cached_config.theme,
        app.terminal_color_scheme,
        app.cached_config.tui.effectiveLightTheme(),
        app.cached_config.tui.effectiveDarkTheme(),
    ).name;
    return .{
        .themes = app.theme_registry.slice(),
        .selection = app.pickers.theme.selection,
        .active_name = active_name,
        .filter = filter,
        .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
        .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        .palette = &app.palette,
    };
}

fn buildPluginsContent(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!plugins_status.Content {
    const installed_plugins = try plugin_store_job.installedPlugins(app.gpa, app);
    defer app.gpa.free(installed_plugins);
    var entries: std.ArrayList(plugins_status.PluginEntry) = .empty;
    for (installed_plugins) |plugin| try entries.append(arena, .{
        .name = plugin.name,
        .active = plugin.active,
        .enabled = plugin.enabled,
        .missing = plugin.path.len == 0,
        .failed = plugin.diagnostic != null and plugin.path.len > 0,
        .shadowed = plugin.shadowed,
    });

    var available: std.ArrayList(plugins_status.StoreEntry) = .empty;
    if (app.plugin_store.catalogs) |*catalogs| {
        var i: usize = 0;
        while (i < catalogs.entryCount()) : (i += 1) {
            const entry = catalogs.entryAt(i) orelse continue;
            try available.append(arena, .{
                .name = entry.plugin.name,
                .version = entry.plugin.version,
                .store = entry.store_name,
                .installed = plugin_store_job.isInstalled(app, entry.catalog_source, entry.plugin.id),
                .stale = catalogs.catalogs[entry.catalog_index].stale,
            });
        }
    }

    var sources: std.ArrayList(plugins_status.StoreSourceEntry) = .empty;
    if (app.plugin_store.catalogs) |*catalogs| {
        for (catalogs.stores) |source| try sources.append(arena, .{
            .url = source.url,
            .enabled = source.enabled,
            .catalog_name = source.catalog_name,
            .stale = source.stale,
            .failure = source.failure,
        });
    }

    const selected = app.pickers.plugins.selection;
    const details = if (app.pickers.plugins.view == .installed and selected < installed_plugins.len) blk: {
        const row = installed_plugins[selected];
        var requested: std.ArrayList([]const u8) = .empty;
        if (row.permissions.file_access) try requested.append(arena, "file");
        if (row.permissions.network_access) try requested.append(arena, "network");
        if (row.permissions.allow_os_execute) try requested.append(arena, "os.execute");
        if (row.permissions.allow_os_remove) try requested.append(arena, "os.remove/rename");
        if (row.permissions.allow_env) try requested.append(arena, "env");
        if (row.permissions.full_access) try requested.append(arena, "full Lua access");
        const permission_summary = if (requested.items.len == 0) "no extra permissions requested" else try std.mem.join(arena, ", ", requested.items);
        break :blk try std.fmt.allocPrint(arena, "v{s} · {s} · {s} · manifest requests: {s} · {s}", .{ row.version, row.origin, if (row.managed) "Store-managed" else "manual", permission_summary, row.diagnostic orelse row.path });
    } else if (app.pickers.plugins.view == .store and app.plugin_store.catalogs != null) blk: {
        const entry = app.plugin_store.catalogs.?.entryAt(selected) orelse break :blk "";
        break :blk try std.fmt.allocPrint(arena, "{s} · {s} · {s}", .{ entry.plugin.description, entry.catalog_source, if (plugin_store_job.verified(entry.plugin)) "verified files" else "unverified files" });
    } else if (app.pickers.plugins.view == .sources and selected < sources.items.len) blk: {
        const source = sources.items[selected];
        break :blk source.failure orelse source.catalog_name orelse source.url;
    } else "";

    return .{
        .state = &app.pickers.plugins,
        .plugins = entries.items,
        .available = available.items,
        .sources = sources.items,
        .store_url_input = app.input_buffers.plugin_store_url.items,
        .notice = app.plugin_store.notice,
        .installing = app.plugin_store.operation == .installing,
        .uninstalling = app.plugin_store.operation == .uninstalling,
        .refreshing = app.plugin_store.operation == .refreshing or app.plugin_store.operation == .scanning,
        .details = details,
        .palette = &app.palette,
    };
}

fn buildCommandContent(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!command_panel.Content {
    const filter = try app.peekPaletteInputArena(arena);
    var buf: [tui.commands.len]command_panel.Entry = undefined;
    var n: usize = 0;
    for (tui.commands) |entry| {
        if (!tui.commandVisible(app, entry)) continue;
        buf[n] = .{ .name = entry.name, .description = entry.description };
        n += 1;
    }
    return .{
        .entries = try arena.dupe(command_panel.Entry, buf[0..n]),
        .filter = filter,
        .selection = app.nav.command_selection,
        .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
        .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        .palette = &app.palette,
    };
}

fn buildSessionContent(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!resume_picker.Content {
    const filter = try app.peekPaletteInputArena(arena);
    return .{
        .io = app.io,
        .list = &app.list_widgets.resume_list,
        .summaries = app.resume_summaries.items,
        .selection = app.nav.resume_selection,
        .folded_projects = app.resume_folded_projects.items,
        .filter = filter,
        .group_by = app.nav.resume_group_by,
        .action = app.nav.session_action,
        .rename_text = app.input_buffers.session_rename_text.items,
        .project_root_text = app.input_buffers.project_root_text.items,
        .project_root_error = app.project_root_error,
        .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
        .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        .palette = &app.palette,
    };
}

fn buildProviderContent(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!provider_picker.Content {
    const filter = try app.peekPaletteInputArena(arena);
    return .{
        .state = app.pickers.provider,
        .codex_signed_in = app.isCodexSignedIn(),
        .statuses = &app.provider_state.conn_status,
        .key_input = app.input_buffers.provider_key.items,
        .api_keys = &app.provider_state.api_keys,
        .filter = filter,
        .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
        .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        .palette = &app.palette,
    };
}

fn buildModelContent(app: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!model_picker.Content {
    const filter = try app.peekPaletteInputArena(arena);
    const status = tui_status.modelStatus(app.liveRuntime(), app.cached_config);
    const entries = app.pickers.models.entries.items;
    const picker_models = try arena.alloc(codex.Model, entries.len);
    const picker_sources = try arena.alloc(model_loader.ModelSource, entries.len);
    const picker_reasoning = try arena.alloc(u32, entries.len);
    for (entries, 0..) |entry, i| {
        picker_models[i] = entry.model;
        picker_sources[i] = entry.source;
        picker_reasoning[i] = entry.reasoning_index;
    }
    return .{
        .models = picker_models,
        .sources = picker_sources,
        .list = &app.list_widgets.model_list,
        .selection = app.pickers.models.model_selection,
        .column = app.pickers.models.model_column,
        .active_model = if (status) |value| value.model else null,
        .reasoning_options = tui.activeReasoningOptions(app),
        .reasoning_indexes = picker_reasoning,
        .footer = try buildModelPickerFooter(app, arena, status),
        .filter = filter,
        .loading = app.pickers.models.load == .loading,
        .error_message = if (app.pickers.models.load == .failed) app.pickers.models.load.failed.message else null,
        .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
        .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        .palette = &app.palette,
    };
}

fn buildModelPickerFooter(app: *App, arena: std.mem.Allocator, status: ?tui_status.ModelStatus) std.mem.Allocator.Error![]const u8 {
    const scope_text = switch (app.pickers.models.model_scope) {
        .global => "Global",
        .project => "Project",
        .session => "Session",
    };
    const opts = tui.activeReasoningOptions(app);
    const r_index: u32 = if (app.pickers.models.model_selection < app.pickers.models.entries.items.len)
        app.pickers.models.entries.items[app.pickers.models.model_selection].reasoning_index
    else
        0;
    const effort_label = if (r_index < opts.len) opts[r_index].label else "medium";
    const dialect = if (app.liveRuntime()) |rt| rt.wire_dialect else ai.WireDialect.minimal;
    const wire_param: []const u8 = if (dialect.usesEnableThinking()) "enable_thinking" else "reasoning_effort";
    const provider = if (status) |s| s.provider else "unknown provider";
    const refresh = if (app.pickers.models.load == .loading) "  ⟳ refreshing…" else "";
    return std.fmt.allocPrint(arena, "  Scope: {s}  │  Ctrl+S to change      →  {s}:\"{s}\" ({s}){s}", .{ scope_text, wire_param, effort_label, provider, refresh });
}
