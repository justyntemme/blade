const state = @import("state.zig");

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
                'q' => app.running = false,
                'j' => app.down(),
                'k' => app.up(),
                'u' => for (0..5) |_| app.up(),
                'd' => for (0..5) |_| app.down(),
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
            // submit search and return to normal mode
            app.mode = .normal;
        },
        .esc => {
            app.searchClear();
            app.mode = .normal;
        },
        // allow navigation while in search mode
        .up => app.up(),
        .down => app.down(),
        else => {},
    }
}
