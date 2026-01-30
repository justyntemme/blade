// const std = @import("std");
const state = @import("state");
const keymap = @import("event_keymap");
const platform = @import("platform");

pub fn handleEvent(app: *state.AppState, event: anytype) !void {
    switch (event) {
        .key => |key| {

            //check app mode for search
            switch (app.mode) {
                .normal => handleNormalMode(app, key),
                .search => handleSearchMode(app, key),
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

fn handleNormalMode(app: *state.AppState, key: anytype) void {
    if (app.active_toast != null) {
        app.active_toast = null;
        return; //consume keypress to not process further during toast notification
    }
    const mapped_key = mapKey(key) orelse return;
    const action = keymap.getAction(mapped_key, .normal) orelse return;

    executeAction(app, action);
}

fn mapKey(key: anytype) ?keymap.Key {
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
        .move_up => app.up(),
        .move_down => app.down(),
        .page_up => for (0..5) |_| app.up(),
        .page_down => for (0..5) |_| app.down(),
        .jump_top => app.jumpTop(),
        .jump_bottom => app.jumpBottom(),
        .quit => app.running = false,
        .start_search => app.mode = .search,
        .clear_search => {
            app.search_len = 0;
            app.refreshFilter();
        },
        .kill_term => killSelected(app, false),
        .kill_force => killSelected(app, true),
        .sort_by_pid => app.setSort(.pid),
        .sort_by_name => app.setSort(.name),
        .sort_by_cpu => app.setSort(.cpu),
        .sort_by_mem => app.setSort(.mem),
        .toggle_expand => app.toggleSelectedExpansion(),
        .toggle_expand_all => app.toggleExpandAll(),
    }
}

fn killSelected(app: *state.AppState, force: bool) void {
    if (app.visible_nodes.items.len == 0) {
        app.showToast("No Process Selected", .err);
        return;
    }
    const idx = @min(app.selected_item, app.visible_nodes.items.len - 1);
    const data_idx: usize = @intCast(app.visible_nodes.items[idx].data_idx);
    const pid = app.hot.items(.pid)[data_idx];
    platform.signal(pid, force) catch |err| {
        app.showToastFmt("Kill failed: {}", .{err}, .err);
        return;
    };
    app.buildView() catch |err| {
        app.showToastFmt("BuidlView Failed: {}", .{err}, .err);
    };
}

fn handleSearchMode(app: *state.AppState, key: anytype) void {
    switch (key.code) {
        .char => |c| {
            if (c < 128) {
                app.searchAppend(@intCast(c));
            }
        },
        .backspace => {
            app.searchBackspace();
        },
        .enter => {
            app.refreshFilter();
            app.mode = .normal;
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
