const std = @import("std");
const tui = @import("zigtui");
const proc = @import("proc/proc.zig");

const _Rect = tui.render.Rect;
const _Style = tui.style.Style;
const _Modifier = tui.style.Modifier;

const AppState = struct {
    running: bool = true,
    allocator: std.mem.Allocator,
    selected_item: usize = 0,
    // items: []const []const u8,
    // proc_count: usize = 0, not needed instead for state.procs.count()
    procs: std.AutoHashMap(proc.pid_t, proc.Proc),
    view: std.ArrayList(*proc.Proc) = .{},
    scroll_offset: usize = 0,
    pub fn rebuildView(self: *AppState) void {
        self.view.clearRetainingCapacity();
        var iter = self.procs.iterator();
        while (iter.next()) |entry| {
            self.view.append(self.allocator, entry.value_ptr) catch {};
        }
    }
    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .procs = std.AutoHashMap(proc.pid_t, proc.Proc).init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.view.deinit(self.allocator);
        self.procs.deinit();
    }
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
    var state = AppState.init(allocator);
    defer state.deinit();

    var procMap = try proc.getProcList();
    defer procMap.deinit();

    var iter = procMap.iterator();
    while (iter.next()) |entry| {
        try state.procs.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    // rebuild view state from procs map buffer
    state.rebuildView();

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
                        if (state.selected_item < state.view.items.len -| 1) {
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
                const inner = tui.render.Rect{
                    .x = area.x + 1,
                    .y = area.y + 1,
                    .width = area.width -| 2,
                    .height = area.height -| 2,
                };
                const visible_rows = inner.height -| 1;
                if (visible_rows > 0) {
                    if (app.selected_item >= app.scroll_offset + visible_rows) {
                        app.scroll_offset = app.selected_item - visible_rows + 1;
                    }
                    if (app.selected_item < app.scroll_offset) {
                        app.scroll_offset = app.selected_item;
                    }
                }
                buf.setString(inner.x, inner.y, "PID    NAME", _Style{
                    .fg = .cyan,
                    .modifier = _Modifier{ .bold = true },
                });
                var y: u16 = inner.y + 1;
                // const visible_rows = inner.height -| 1; //subtract header row
                var idx: usize = app.scroll_offset;
                while (idx < app.view.items.len) : (idx += 1) {
                    if (y >= inner.y + inner.height) break;
                    const p = app.view.items[idx];
                    const style = if (idx == app.selected_item)
                        _Style{ .bg = .blue, .fg = .white }
                    else
                        _Style{ .fg = .white };
                    var pid_buf: [8]u8 = undefined;
                    const pid_str = std.fmt.bufPrint(&pid_buf, "{d:<7}", .{p.PID}) catch "???";
                    const name = std.mem.sliceTo(&p.Sname, 0);

                    buf.setString(inner.x, y, pid_str, style);
                    buf.setString(inner.x + 8, y, name, style);
                    y += 1;
                }
                block.render(area, buf);
            }
        }.render);
    }

    try terminal.showCursor();
}
