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
            try app.view.resize(app.allocator, size.width);
        },
        else => {},
    }
}

fn handleNormalMode(app: *state.AppState, key: anytype) void {
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
                    //graceful kill SIGTERM
                    const selected_proc = app.view.items[app.selected_item];
                    proc.killProcById(selected_proc.pid, false) catch |err| {
                        std.log.err("Failed to kill process {}: {}", .{ selected_proc.pid, err });
                    };
                    app.rebuildView() catch |err| {
                        std.log.err("rebuildView failed on enter {}", .{err});
                    };
                },
                'X' => {
                    //graceful kill SIGTERM
                    const selected_proc = app.view.items[app.selected_item];
                    proc.killProcById(selected_proc.pid, true) catch |err| {
                        std.log.err("Failed to kill process {}: {}", .{ selected_proc.pid, err });
                    };
                    app.rebuildView() catch |err| {
                        std.log.err("rebuildView failed on enter {}", .{err});
                    };
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
