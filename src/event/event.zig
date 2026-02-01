const state = @import("state");
const keymap = @import("event_keymap");
const platform = @import("platform");
const tui = @import("zigtui");

pub fn handleEvent(app: *state.AppState, event: tui.Event) !void {
    switch (event) {
        .key => |key| {
            //check app mode for search
            switch (app.mode) {
                .normal, .search_view, .help => handleNormalMode(app, key),
                .search_edit => handleSearchEditMode(app, key),
            }
        },
        .resize => |size| {
            if (app.terminal) |term| {
                try term.resize(.{ .width = size.width, .height = size.height });
            }
        },
        else => {},
    }
}

fn handleNormalMode(app: *state.AppState, key: tui.KeyEvent) void {
    if (app.active_toast != null) {
        app.active_toast = null;
        return; //consume keypress to not process further during toast notification
    }
    const mapped_key = mapKey(key) orelse return;
    const action = keymap.getAction(mapped_key, app.mode) orelse return;

    executeAction(app, action);
}

fn mapKey(key: tui.KeyEvent) ?keymap.Key {
    return switch (key.code) {
        .char => |c| .{ .char = @intCast(c) },
        .up => .{ .special = .up },
        .down => .{ .special = .down },
        .esc => .{ .special = .esc },
        .enter => .{ .special = .enter },
        .backspace => .{ .special = .backspace },
        else => null,
    };
}

fn executeAction(app: *state.AppState, action: keymap.Action) void {
    switch (action) {
        .show_help => {
            if (app.mode == .help) {
                app.mode = app.previous_mode;
            } else {
                app.previous_mode = app.mode;
                app.mode = .help;
            }
        },
        .move_up => app.up(),
        .move_down => app.down(),
        .page_up => for (0..5) |_| app.up(),
        .page_down => for (0..5) |_| app.down(),
        .jump_top => app.jumpTop(),
        .jump_bottom => app.jumpBottom(),
        .quit => app.running = false,
        .start_search => app.mode = .search_edit,
        .clear_search => {
            app.search_len = 0;
            app.refreshFilter();
            if (app.mode == .search_view) app.mode = .normal;
        },
        .kill_term => killSelected(app, false),
        .kill_force => killSelected(app, true),
        .sort_by_pid => app.setSort(.pid),
        .sort_by_name => app.setSort(.name),
        .sort_by_cpu => app.setSort(.cpu),
        .sort_by_mem => app.setSort(.mem),
        .toggle_expand => app.toggleSelectedExpansion(),
        .toggle_expand_all => app.toggleExpandAll(),
        .exit_search_view => {
            app.search_len = 0;
            app.refreshFilter();
            app.mode = .normal;
        },
    }
}

fn killSelected(app: *state.AppState, force: bool) void {
    const rows = app.procs.render_rows.items;
    if (rows.len == 0) {
        app.showToast("No Process Selected", .err);
        return;
    }
    const idx = @min(app.selected_item, rows.len - 1);
    const pid = rows[idx].pid;
    platform.signal(pid, force) catch |err| {
        app.showToastFmt("Kill failed: {}", .{err}, .err);
        return;
    };
    app.buildView();
}

// This is special as we may have arbitruary keys that can not map
// Thus creating a need for a special function that modifies state rather
// than executes actions
fn handleSearchEditMode(app: *state.AppState, key: tui.KeyEvent) void {
    switch (key.code) {
        .char => |c| {
            if (c < 128) {
                app.searchAppend(@intCast(c));
                app.refreshFilter(); // live search
            }
        },
        .backspace => {
            app.searchBackspace();
            app.refreshFilter(); // live search
        },
        .enter => {
            app.mode = .search_view; // cement search
        },
        .esc => {
            app.searchClear();
            app.refreshFilter();
            app.mode = .normal;
        },
        // allow navigation while in search mode
        .up => app.up(),
        .down => app.down(),
        else => {},
    }
}
