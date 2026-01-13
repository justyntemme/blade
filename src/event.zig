const state = @import("state.zig");

pub fn handleEvent(app: *state.AppState, event: anytype) void {
    switch (event) {
        .key => |key| {
            switch (key.code) {
                .char => |c| {
                    switch (c) {
                        '/' => app.mode = .search,
                        'q' => if (app.mode != .search) {
                            app.running = false;
                        } else {},
                        'k' => if (app.mode != .search) {
                            app.up();
                        } else {},
                        'j' => if (app.mode != .search) {
                            app.down();
                        } else {},
                        'u' => if (app.mode != .search) {
                            for (0..5) |_| app.up();
                        } else {},
                        'd' => if (app.mode != .search) {
                            for (0..5) |_| app.down();
                        } else {},
                        else => {},
                    }
                },
                //If in search then reset to normal mode, if in normal mode exit program
                .esc => if (app.mode != .search) {
                    app.running = false;
                } else {
                    app.mode = .normal;
                },
                .up => {
                    app.up();
                },
                .down => {
                    app.down();
                },

                else => {},
            }
        },
        else => {},
    }
}
