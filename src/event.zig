const state = @import("state.zig");

pub fn handleEvent(app: *state.AppState, event: anytype) void {
    switch (event) {
        .key => |key| {
            switch (key.code) {
                .char => |c| {
                    switch (c) {
                        'q' => app.running = false,
                        'k' => app.up(),
                        'j' => app.down(),
                        else => {},
                    }
                },
                .esc => app.running = false,
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
