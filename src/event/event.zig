const std = @import("std");
const state = @import("state");
const proc = @import("proc");
const keymap = @import("event_keymap");

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

    // switch (key.code) {
    //     .char => |c| {
    //         switch (c) {
    //             '/' => {
    //                 app.mode = .search;
    //             },
    //             'c' => {
    //                 app.search_len = 0;
    //                 app.buildView() catch |err| {
    //                     std.log.err("buildView failed on clear search {}", .{err});
    //                 };
    //             },
    //             'q' => app.running = false,
    //             'j' => app.down(),
    //             'k' => app.up(),
    //             'u' => for (0..5) |_| app.up(),
    //             'd' => for (0..5) |_| app.down(),
    //             'x' => {
    //                 //SIGTERM
    //                 if (app.selected_item < app.view.items.len) {
    //                     const pv = app.view.items[app.selected_item];
    //                     const pid = pv.proc.pid;
    //
    //                     proc.killProcById(pid, false) catch |err| {
    //                         app.showToastFmt("Error on killProcById {}", .{err}, .err);
    //                     };
    //                 } else {
    //                     app.showToast("Error: No pid found for object", .err);
    //                 }
    //                 app.buildView() catch |err| {
    //                     std.log.err("buildView failed on enter {}", .{err});
    //                 };
    //             },
    //             'X' => {
    //                 //SIGKILL
    //                 if (app.selected_item < app.view.items.len) {
    //                     const pv = app.view.items[app.selected_item];
    //                     proc.killProcById(pv.proc.pid, true) catch |err| {
    //                         std.log.err("Failed to kill process {}: {}", .{ pv.proc.pid, err });
    //                     };
    //                     app.buildView() catch |err| {
    //                         std.log.err("buildView failed on enter {}", .{err});
    //                     };
    //                 }
    //             },
    //             'P' => app.setSort(.pid),
    //             // 'P' => app.setSort(.pid) catch |err| {
    //             // app.showToastFmt("Error sorting by process: {}", .{err}, .err);
    //             // },
    //             'N' => app.setSort(.name),
    //             //     app.showToastFmt("Error sorting by name: {}", .{err}, .err);
    //             // },
    //             'C' => app.setSort(.cpu),
    //             // app.showToastFmt("Error sorting by CPU: {}", .{err}, .err);
    //             // },
    //             'M' => app.setSort(.mem),
    //             // app.showToastFmt("Error sorting by Mem: {}", .{err}, .err);
    //             // },
    //
    //             else => {},
    //         }
    //     },
    //     .esc => app.running = false,
    //     .up => app.up(),
    //     .down => app.down(),
    //     else => {},
    // }
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
        .quit => app.running = false,
        .start_search => app.mode = .search,
        .clear_search => {
            app.search_len = 0;
            app.buildView() catch |err| {
                std.log.err("buildView failed: {}", .{err});
            };
        },
        .kill_term => killSelected(app, false),
        .kill_force => killSelected(app, true),
        .sort_by_pid => app.setSort(.pid),
        .sort_by_name => app.setSort(.name),
        .sort_by_cpu => app.setSort(.cpu),
        .sort_by_mem => app.setSort(.mem),
    }
}

fn killSelected(app: *state.AppState, force: bool) void {
    if (app.selected_item < app.view.items.len) {
        const pv = app.view.items[app.selected_item];
        proc.killProcById(pv.proc.pid, force) catch |err| {
            app.showToastFmt("Kill failed: {}", .{err}, .err);
            return;
        };
        app.buildView() catch {};
    } else {
        app.showToast("No process selected", .err);
    }
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
            app.buildView() catch |err| {
                std.log.err("buildView failed on enter {}", .{err});
            };
            app.mode = .normal;
        },
        .esc => {
            app.searchClear();
            app.buildView() catch |err| {
                std.log.err("buildView failed on escape {}", .{err});
            };
            app.mode = .normal;
        },
        // allow navigation while in search mode
        .up => app.up(),
        .down => app.down(),
        else => {},
    }
}
