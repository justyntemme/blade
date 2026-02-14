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
            } else if (app.dashboard_focus == .network_pane) {
                app.networkUp();
            } else app.up();
        },
        .move_down => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) app.detailScrollDown() else app.detail_right_scroll += 1;
            } else if (app.mode == .help) {
                app.help_scroll += 1;
            } else if (app.dashboard_focus == .network_pane) {
                app.networkDown();
            } else app.down();
        },
        .move_left => {
            // Only works when network pane is focused
            if (app.dashboard_focus == .network_pane) {
                app.networkLeft();
            }
        },
        .move_right => {
            // Only works when network pane is focused
            if (app.dashboard_focus == .network_pane) {
                app.networkRight();
            }
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
            } else if (app.dashboard_focus == .network_pane) {
                for (0..5) |_| app.networkUp();
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
            } else if (app.dashboard_focus == .network_pane) {
                for (0..5) |_| app.networkDown();
            } else {
                for (0..5) |_| app.down();
            }
        },
        .jump_top => {
            if (app.mode == .detail) {
                if (app.detail_focus == .left) app.detail_scroll = 0 else app.detail_right_scroll = 0;
            } else if (app.mode == .help) {
                app.help_scroll = 0;
            } else if (app.dashboard_focus == .network_pane) {
                app.network_selected = 0;
                app.network_scroll = 0;
            } else app.jumpTop();
        },
        .jump_bottom => {
            if (app.mode == .detail) {
                // Use a large but safe value that won't overflow in render calculations
                const safe_max: usize = std.math.maxInt(usize) / 2;
                if (app.detail_focus == .left) app.detail_scroll = safe_max else app.detail_right_scroll = safe_max;
            } else if (app.mode == .help) {
                app.help_scroll = ~@as(usize, 0);
            } else if (app.dashboard_focus == .network_pane) {
                if (app.network_entry_count > 0) {
                    app.network_selected = app.network_entry_count - 1;
                }
            } else app.jumpBottom();
        },
        .quit => {
            // If selections exist in normal mode, Esc clears them first
            if (app.mode == .normal and app.getSelectedCount() > 0) {
                app.clearSelections();
            } else {
                app.running = false;
            }
        },
        .start_search => app.mode = .search_edit,
        .clear_search => {
            app.search_len = 0;
            app.refreshFilter();
            if (app.mode == .search_view) app.mode = .normal;
        },
        .kill_term => showKillConfirm(app, false),
        .kill_force => showKillConfirm(app, true),
        .pause_process => {
            if (app.mode == .detail) {
                if (app.detail_pid) |pid| {
                    platform.suspendProcess(pid) catch |err| {
                        app.showToastFmt("Suspend failed: {}", .{err}, .err);
                        return;
                    };
                    // Refresh detail to show updated state
                    app.refreshDetail();
                }
            }
        },
        .resume_process => {
            if (app.mode == .detail) {
                if (app.detail_pid) |pid| {
                    platform.resumeProcess(pid) catch |err| {
                        app.showToastFmt("Resume failed: {}", .{err}, .err);
                        return;
                    };
                    // Refresh detail to show updated state
                    app.refreshDetail();
                }
            }
        },
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
            if (app.dashboard_focus == .network_pane) {
                // Open detail for selected network entry
                if (app.getNetworkSelectedPid()) |pid| {
                    app.openDetail(pid);
                }
            } else {
                const rows = app.procs.render_rows.items;
                if (rows.len == 0) return;
                const idx = @min(app.selected_item, rows.len - 1);
                const pid = rows[idx].pid;
                app.openDetail(pid);
            }
        },
        .close_detail => app.closeDetail(),
        .focus_left => {
            if (app.mode == .detail) {
                app.detail_focus = .left;
            } else {
                // Only allow focus on network pane when by_process mode is active
                if (app.network_display_mode == .by_process) {
                    app.dashboard_focus = .network_pane;
                }
            }
        },
        .focus_right => {
            if (app.mode == .detail) {
                app.detail_focus = .right;
            } else {
                app.dashboard_focus = .process_list;
            }
        },
        .toggle_detail_view => {
            app.detail_view_mode = if (app.detail_view_mode == .info) .network else .info;
            app.detail_scroll = 0; // Reset scroll when switching views
        },
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
        .toggle_network_mode => {
            app.network_display_mode = app.network_display_mode.next();
            // Reset focus to process list if leaving by_process mode
            if (app.network_display_mode != .by_process) {
                app.dashboard_focus = .process_list;
            }
        },
        .toggle_protocol_filter => {
            app.network_protocol_filter = app.network_protocol_filter.next();
        },
        .toggle_preserve_log => {
            app.togglePreserveLog();
        },
        .confirm_dialog_yes => {
            if (app.confirm_dialog) |dialog| {
                const force = dialog.action == .kill_force;
                // Kill all selected processes or just the target
                if (app.getSelectedCount() > 0) {
                    var it = app.pinned_pids.keyIterator();
                    while (it.next()) |id| {
                        executeKill(app, id.pid, force);
                    }
                    app.clearSelections();
                } else {
                    executeKill(app, dialog.target_pid, force);
                }
            }
            app.closeConfirmDialog();
        },
        .confirm_dialog_no => {
            app.closeConfirmDialog();
        },
        .toggle_select => {
            const rows = app.procs.render_rows.items;
            if (rows.len == 0) return;
            const idx = @min(app.selected_item, rows.len - 1);
            const row = rows[idx];
            // Get start_time from the hot data
            const hot = app.procs.hot.slice();
            if (row.data_idx < hot.items(.start_time_ns).len) {
                const start_time = hot.items(.start_time_ns)[row.data_idx];
                const was_pinned = app.isSelected(row.pid, start_time);
                // Pass row position for pinning
                app.toggleSelection(row.pid, start_time, idx);

                // If unpinning in search view, refresh immediately to remove non-matching items
                if (was_pinned and app.mode == .search_view) {
                    app.refreshFilter();
                } else {
                    app.reorderPinnedRows();
                }
            }
        },
        .clear_selections => {
            app.clearSelections();
            // Refresh to remove unpinned items that don't match search
            if (app.mode == .search_view) {
                app.refreshFilter();
            }
        },
        .nice_up => executeRenice(app, -1),
        .nice_down => executeRenice(app, 1),
        .dashboard_cpu => app.dashboard_graph_mode = .cpu,
        .dashboard_mem => app.dashboard_graph_mode = .memory,
    }
}

fn showKillConfirm(app: *state.AppState, force: bool) void {
    const action: state.ConfirmAction = if (force) .kill_force else .kill_term;
    var msg_buf: [128]u8 = undefined;
    var title_buf: [64]u8 = undefined;

    // In detail mode, kill the process being viewed
    if (app.mode == .detail) {
        if (app.detail_pid) |pid| {
            const title = if (force) "Force Kill Process?" else "Kill Process?";
            // Try to get the process name from the detail data
            const name = if (app.detail_data) |data| data.name else "Unknown";
            const message = std.fmt.bufPrint(&msg_buf, "PID {d}: {s}", .{ pid, name }) catch "Unknown process";
            app.showConfirmDialog(title, message, action, pid, name);
        }
        return;
    }

    const rows = app.procs.render_rows.items;
    if (rows.len == 0) {
        app.showToast("No Process Selected", .err);
        return;
    }

    const selected_count = app.getSelectedCount();

    if (selected_count > 0) {
        // Multiple selected - batch kill
        const title = if (force)
            std.fmt.bufPrint(&title_buf, "Force Kill {d} Processes?", .{selected_count}) catch "Force Kill Processes?"
        else
            std.fmt.bufPrint(&title_buf, "Kill {d} Processes?", .{selected_count}) catch "Kill Processes?";

        const message = std.fmt.bufPrint(&msg_buf, "{d} selected processes will be terminated", .{selected_count}) catch "Multiple processes";

        app.showConfirmDialog(title, message, action, 0, "multiple");
    } else {
        // Single process - current highlighted row
        const idx = @min(app.selected_item, rows.len - 1);
        const row = rows[idx];
        const pid = row.pid;
        const name = row.name;

        const title = if (force) "Force Kill Process?" else "Kill Process?";
        const message = std.fmt.bufPrint(&msg_buf, "PID {d}: {s}", .{ pid, name }) catch "Unknown process";

        app.showConfirmDialog(title, message, action, pid, name);
    }
}

fn executeKill(app: *state.AppState, pid: std.posix.pid_t, force: bool) void {
    platform.signal(pid, force) catch |err| {
        app.showToastFmt("Kill failed: {}", .{err}, .err);
        return;
    };
    app.buildView();
}

fn executeRenice(app: *state.AppState, delta: i32) void {
    const rows = app.procs.render_rows.items;
    if (rows.len == 0) return;

    const idx = @min(app.selected_item, rows.len - 1);
    const row = rows[idx];
    const pid = row.pid;

    _ = platform.renice(pid, delta) catch |err| {
        app.showToastFmt("Renice failed: {}", .{err}, .err);
        return;
    };
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
