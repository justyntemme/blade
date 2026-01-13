const std = @import("std");
const tui = @import("zigtui");
const state = @import("../state.zig");
// const proc = @import("../proc/proc.zig");
const layout = @import("layout.zig");
const _Rect = tui.render.Rect;
const _Style = tui.style.Style;
const _Modifier = tui.style.Modifier;

const app_layout = layout.Container.column(&[_]layout.Item{
    .{ .id = "header", .sizing = .{ .fixed = 1 } },
    .{ .id = "process_list", .sizing = .{ .grow = 1.0 } },
});

pub fn render(draw_ctx: state.DrawContext, buf: *tui.render.Buffer) !void {
    const app = draw_ctx.state;
    const area = buf.getArea();

    var calculated = layout.calculate(
        draw_ctx.allocator,
        app_layout,
        layout.Rect{
            .x = area.x + 1,
            .y = area.y + 1,
            .width = area.width -| 2,
            .height = area.height -| 2,
        },
    ) catch return;
    defer calculated.deinit();

    const header_rect = calculated.get("header") orelse return;
    const list_rect = calculated.get("process_list") orelse return;

    const block = tui.widgets.Block{
        .title = "Processes",
        .borders = tui.widgets.Borders.all(),
        .border_style = tui.style.Style{ .fg = .cyan },
    };
    const visible_rows = list_rect.height -| 1;
    if (visible_rows > 0) {
        if (app.selected_item >= app.scroll_offset + visible_rows) {
            app.scroll_offset = app.selected_item - visible_rows + 1;
        }
        if (app.selected_item < app.scroll_offset) {
            app.scroll_offset = app.selected_item;
        }
    }
    buf.setString(header_rect.x, header_rect.y, "PID    NAME \t\t\t\t\t\tPATH", _Style{
        .fg = .cyan,
        .modifier = _Modifier{ .bold = true },
    });
    var y: u16 = list_rect.y + 1;
    var idx: usize = app.scroll_offset;
    while (idx < app.view.items.len) : (idx += 1) {
        if (y >= list_rect.y + list_rect.height) break;
        const p = app.view.items[idx];
        const style = if (idx == app.selected_item)
            _Style{ .bg = .blue, .fg = .white }
        else
            _Style{ .fg = .white };
        var pid_buf: [8]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d:<7}", .{p.pid}) catch "???";
        const name = std.mem.sliceTo(&p.s_name, 0);
        const path = std.mem.sliceTo(&p.path, 0);
        buf.setString(list_rect.x, y, pid_str, style);
        buf.setString(list_rect.x + 8, y, name, style);
        buf.setString(list_rect.x + list_rect.width / 2, y, path, style);
        y += 1;
    }
    block.render(area, buf);
}
