const std = @import("std");
const tui = @import("zigtui");
const AppState = struct {
    running: bool = true,
    selected_item: usize = 0,
    items: []const []const u8,
};
const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // // Initialize backend (platform-specific)
    // try tui.backend.AnsiBackend.init(allocator);
    // try tui.backend.NativeBackend.init(allocator);
    var backend = try tui.backend.AnsiBackend.init(allocator);
    defer backend.deinit();
    // // Initialize terminal
    var terminal = try tui.terminal.Terminal.init(allocator, backend.interface());
    defer terminal.deinit();

    // Hide cursor
    try terminal.hideCursor();
    var state = AppState{
        .items = &[_][]const u8{ "Item 1", "Item 2", "Item 3" },
    };
    while (state.running) {
        // Process event triggers

        // Poll for events (100ms timeout)
        const event = try backend.interface().pollEvent(100);

        // Handle input
        switch (event) {
            .key => |key| {
                switch (key.code) {
                    .char => |c| {
                        if (c == 'q') state.running = false;
                    },
                    .esc => state.running = false,
                    .up => {
                        if (state.selected_item > 0) {
                            state.selected_item -= 1;
                        }
                    },
                    .down => {
                        if (state.selected_item < state.items.len - 1) {
                            state.selected_item += 1;
                        }
                    },

                    else => {},
                }
            },
            else => {},
        }

        const ctx = DrawContext{ .state = &state, .allocator = allocator };

        // Draw UI
        try terminal.draw(ctx, struct {
            fn render(draw_ctx: DrawContext, buf: *tui.render.Buffer) !void {
                const app = draw_ctx.state;

                const area = buf.getArea();
                const block = tui.widgets.Block{
                    .title = "Processes",
                    .borders = tui.widgets.Borders.all(),
                    .border_style = tui.style.Style{ .fg = .cyan },
                };
                // const Pblock = tui.widgets.Block{
                //     .title = "Processes",
                //     .borders = tui.widgets.Borders.all(), // or .none(), .TOP, .BOTTOM, etc.
                //     .style = tui.style.Style{ .fg = .white, .bg = .black },
                //     .border_style = tui.style.Style{ .fg = .cyan },
                //     .title_style = tui.style.Style{ .fg = .yellow },
                // };

                const items = [_]tui.widgets.ListItem{
                    .{ .content = "Item 1" },
                    .{ .content = "Item 2" },
                    .{ .content = "Item 3" },
                };
                const list = tui.widgets.List{
                    .items = &items,
                    .selected = app.selected_item,
                    .highlight_style = tui.style.Style{ .bg = .blue },
                };
                const inner = tui.render.Rect{
                    .x = area.x + 1,
                    .y = area.y + 1,
                    .width = area.width -| 2,
                    .height = area.height -| 2,
                };
                list.render(inner, buf);
                // Pblock.render(area, buf);
                block.render(area, buf);
            }
        }.render);
    }

    try terminal.showCursor();
}
