const state = @import("state.zig");

pub fn handleEvent(app: *state.AppState, event: anytype) void {
    switch (event) {
        .key => |key| {
            switch (key.code) {
                .char => |c| {
                    if (c == 'q') app.running = false;
                },
                .esc => app.running = false,
                .up => {
                    if (app.selected_item > 0) {
                        app.selected_item -= 1;
                    }
                },
                .down => {
                    if (app.selected_item < app.view.items.len -| 1) {
                        app.selected_item += 1;
                    }
                },

                else => {},
            }
        },
        else => {},
    }
}
