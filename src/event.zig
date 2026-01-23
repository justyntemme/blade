const std = @import("std");
const state = @import("state.zig");
const proc = @import("proc/proc.zig");

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
                term.resize(.{ .width = size.width, .height = size.height });
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
    switch (key.code) {
        .char => |c| {
            switch (c) {
                '/' => {
                    app.mode = .search;
                },
                'c' => {
                    app.search_len = 0;
                    app.rebuildView() catch |err| {
                        std.log.err("rebuildView failed on clear search {}", .{err});
                    };
                },
                'q' => app.running = false,
                'j' => app.down(),
                'k' => app.up(),
                'u' => for (0..5) |_| app.up(),
                'd' => for (0..5) |_| app.down(),
                'x' => {
                    //SIGTERM
                    if (app.selected_item < app.view.items.len) {
                        const pv = app.view.items[app.selected_item];
                        const pid = pv.proc.pid;

                        proc.killProcById(pid, false) catch |err| {
                            app.showToastFmt("Error on killProcById {}", .{err}, .err);
                        };
                    } else {
                        app.showToast("Error: No pid found for object", .err);
                    }
                    app.rebuildView() catch |err| {
                        std.log.err("rebuildView failed on enter {}", .{err});
                    };
                },
                'X' => {
                    //SIGKILL
                    if (app.selected_item < app.view.items.len) {
                        const pv = app.view.items[app.selected_item];
                        proc.killProcById(pv.proc.pid, true) catch |err| {
                            std.log.err("Failed to kill process {}: {}", .{ pv.proc.pid, err });
                        };
                        app.rebuildView() catch |err| {
                            std.log.err("rebuildView failed on enter {}", .{err});
                        };
                    }
                },
                'P' => app.setSort(.pid) catch |err| {
                    app.showToastFmt("Error sorting by process: {}", .{err}, .err);
                },
                'N' => app.setSort(.name) catch |err| {
                    app.showToastFmt("Error sorting by name: {}", .{err}, .err);
                },
                'C' => app.setSort(.cpu) catch |err| {
                    app.showToastFmt("Error sorting by CPU: {}", .{err}, .err);
                },
                'M' => app.setSort(.mem) catch |err| {
                    app.showToastFmt("Error sorting by Mem: {}", .{err}, .err);
                },

                else => {},
            }
        },
        .esc => app.running = false,
        .up => app.up(),
        .down => app.down(),
        else => {},
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
            app.rebuildView() catch |err| {
                std.log.err("rebuildView failed on enter {}", .{err});
            };
            app.mode = .normal;
        },
        .esc => {
            app.searchClear();
            app.rebuildView() catch |err| {
                std.log.err("rebuildView failed on escape {}", .{err});
            };
            app.mode = .normal;
        },
        // allow navigation while in search mode
        .up => app.up(),
        .down => app.down(),
        else => {},
    }
}
