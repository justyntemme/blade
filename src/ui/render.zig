const std = @import("std");
const tui = @import("zigtui");
const state = @import("../state.zig");
const proc = @import("../proc/proc.zig");

const _Rect = tui.render.Rect;
const _Style = tui.style.Style;
const _Modifier = tui.style.Modifier;

pub fn render(draw_ctx: state.DrawContext, buf: *tui.render.Buffer) !void {
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
    buf.setString(inner.x, inner.y, "PID    NAME \t\t\t\t\t\tPATH", _Style{
        .fg = .cyan,
        .modifier = _Modifier{ .bold = true },
    });
    var y: u16 = inner.y + 1;
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
        const name = std.mem.sliceTo(&p.s_name, 0);
        const path = std.mem.sliceTo(&p.Path, 0);
        buf.setString(inner.x, y, pid_str, style);
        buf.setString(inner.x + 8, y, name, style);
        buf.setString(inner.x + area.width / 2, y, path, style);
        y += 1;
    }
    block.render(area, buf);
}
