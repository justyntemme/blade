const std = @import("std");
const state = @import("state");
const keymap = @import("event_keymap");
const platform = @import("platform");
const tui = @import("zigtui");

pub fn handleEvent(app: *state.AppState, event: tui.Event) !void {
    switch (event) {
        .key => |key| {
            //check app mode for search
            switch (app.mode) {
                .normal, .search_view, .help, .detail, .confirm_dialog => handleNormalMode(app, key),
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
    // Shift+Enter → toggle expand (mapped to tab)
    if (key.code == .enter and key.modifiers.shift) return .{ .special = .tab };

    return switch (key.code) {
        .char => |c| .{ .char = @intCast(c) },
        .up => .{ .special = .up },
        .down => .{ .special = .down },
        .esc => .{ .special = .esc },
        .enter => .{ .special = .enter },
        .backspace => .{ .special = .backspace },
        .tab => .{ .special = .tab },
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
                app.help_scroll = 0;
                app.mode = .help;
            }
        },
        .move_up => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) app.detailScrollUp() else {
                    if (app.detail_right_scroll > 0) app.detail_right_scroll -= 1;
                }
            } else if (app.mode == .help) {
                if (app.help_scroll > 0) app.help_scroll -= 1;
            } else app.up();
        },
        .move_down => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) app.detailScrollDown() else app.detail_right_scroll += 1;
            } else if (app.mode == .help) {
                app.help_scroll += 1;
            } else app.down();
        },
        .page_up => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) {
                    for (0..10) |_| app.detailScrollUp();
                } else {
                    app.detail_right_scroll -|= 10;
                }
            } else if (app.mode == .help) {
                app.help_scroll -|= 10;
            } else {
                for (0..5) |_| app.up();
            }
        },
        .page_down => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) {
                    for (0..10) |_| app.detailScrollDown();
                } else {
                    app.detail_right_scroll += 10;
                }
            } else if (app.mode == .help) {
                app.help_scroll += 10;
            } else {
                for (0..5) |_| app.down();
            }
        },
        .jump_top => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) app.detail_scroll = 0 else app.detail_right_scroll = 0;
            } else if (app.mode == .help) {
                app.help_scroll = 0;
            } else app.jumpTop();
        },
        .jump_bottom => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) app.detailScrollToBottom() else app.detail_right_scroll = ~@as(usize, 0);
            } else if (app.mode == .help) {
                app.help_scroll = ~@as(usize, 0);
            } else app.jumpBottom();
        },
        .quit => app.running = false,
        .start_search => app.mode = .search_edit,
        .clear_search => {
            app.search_len = 0;
            app.refreshFilter();
            if (app.mode == .search_view) app.mode = .normal;
        },
        .kill_term => showKillConfirm(app, false),
        .kill_force => showKillConfirm(app, true),
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
        .open_detail => {
            const rows = app.procs.render_rows.items;
            if (rows.len == 0) return;
            const idx = @min(app.selected_item, rows.len - 1);
            const pid = rows[idx].pid;
            app.openDetail(pid);
        },
        .close_detail => app.closeDetail(),
        .focus_left => app.detail_focus = .left,
        .focus_right => app.detail_focus = .right,
        .toggle_cpu_overlay => {
            app.cpu_overlay_mode = if (app.cpu_overlay_mode == .cores) .aggregate else .cores;
        },
        .toggle_temp_unit => {
            app.temp_unit = if (app.temp_unit == .celsius) .fahrenheit else .celsius;
        },
        .cycle_storage_detail => {
            app.storage_detail_mode = switch (app.storage_detail_mode) {
                .compact => .full,
                .full => .with_swap,
                .with_swap => .compact,
            };
        },
        .toggle_mount_filter => {
            app.mount_filter = if (app.mount_filter == .user_only) .all else .user_only;
        },
        .confirm_dialog_yes => {
            if (app.confirm_dialog) |dialog| {
                const force = dialog.action == .kill_force;
                executeKill(app, dialog.target_pid, force);
            }
            app.closeConfirmDialog();
        },
        .confirm_dialog_no => {
            app.closeConfirmDialog();
        },
    }
}

fn showKillConfirm(app: *state.AppState, force: bool) void {
    const rows = app.procs.render_rows.items;
    if (rows.len == 0) {
        app.showToast("No Process Selected", .err);
        return;
    }
    const idx = @min(app.selected_item, rows.len - 1);
    const row = rows[idx];
    const pid = row.pid;
    const name = row.name;

    const action: state.ConfirmAction = if (force) .kill_force else .kill_term;
    const title = if (force) "Force Kill Process?" else "Kill Process?";

    var msg_buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, "PID {d}: {s}", .{ pid, name }) catch "Unknown process";

    app.showConfirmDialog(title, message, action, pid, name);
}

fn executeKill(app: *state.AppState, pid: std.posix.pid_t, force: bool) void {
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
