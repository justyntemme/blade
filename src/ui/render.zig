const std = @import("std");
const tui = @import("zigtui");
const state = @import("state");
// const proc = @import("proc");
const layout = @import("ui_layout");
const keymap = @import("event_keymap");

const _Style = tui.style.Style;
const _Modifier = tui.style.Modifier;

const app_layout = layout.Container.column(&[_]layout.Item{
    .{ .id = "header", .sizing = .{ .fixed = 1 } },
    .{ .id = "process_list", .sizing = .{ .grow = 1.0 } },
    .{ .id = "footer_bar", .sizing = .{ .fixed = 1 } },
});

const column_layout = layout.Container.row(&[_]layout.Item{
    .{ .id = "pid", .sizing = .{ .fixed = 8 } },
    .{ .id = "name", .sizing = .{ .grow = 1.0 } },
    .{ .id = "cpu", .sizing = .{ .fixed = 7.0 } },
    .{ .id = "mem", .sizing = .{ .fixed = 10.0 } },
    .{ .id = "path", .sizing = .{ .grow = 2.0 } },
});

pub fn render(draw_ctx: state.DrawContext, buf: *tui.render.Buffer) !void {
    const app = draw_ctx.state;
    const area = buf.getArea();

    var calculated = try layout.calculate(
        draw_ctx.allocator,
        app_layout,
        layout.Rect{
            .x = area.x + 1,
            .y = area.y + 1,
            .width = area.width -| 2,
            .height = area.height -| 2,
        },
    ); // ) catch return;
    defer calculated.deinit();

    const header_rect = calculated.get("header") orelse {
        buf.setString(0, 0, "Missing layout ID: header", _Style{ .fg = .red });
        return;
    };
    const list_rect = calculated.get("process_list") orelse {
        buf.setString(0, 0, "Missing layout ID: process_list", _Style{ .fg = .red });
        return;
    };
    var columns = layout.calculate(
        draw_ctx.allocator,
        column_layout,
        layout.Rect{
            .x = list_rect.x,
            .y = list_rect.y,
            .width = list_rect.width,
            .height = 1,
        },
    ) catch return;

    defer columns.deinit();

    const pid_col = columns.get("pid") orelse return {
        buf.setString(0, 0, "Missing PID", _Style{ .fg = .red });
        return;
    };
    const name_col = columns.get("name") orelse {
        buf.setString(0, 0, "Missing Name", _Style{ .fg = .red });
        return;
    };
    const cpu_col = columns.get("cpu") orelse {
        buf.setString(0, 0, "Missing cpu", _Style{ .fg = .red });
        return;
    };
    const mem_col = columns.get("mem") orelse {
        buf.setString(0, 0, "Missing mem", _Style{ .fg = .red });
        return;
    };
    const path_col = columns.get("path") orelse {
        buf.setString(0, 0, "Missing path", _Style{ .fg = .red });
        return;
    };

    const footer_rect = calculated.get("footer_bar") orelse {
        buf.setString(0, 0, "footer_bar", _Style{ .fg = .red });
        return;
    };

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
    const header_style = _Style{ .fg = .cyan, .modifier = _Modifier{ .bold = true } };
    buf.setString(pid_col.x, header_rect.y, "PID", header_style);
    buf.setString(name_col.x, header_rect.y, "Name", header_style);
    buf.setString(cpu_col.x, header_rect.y, "CPU%", header_style);
    buf.setString(mem_col.x, header_rect.y, "MEM", header_style);
    buf.setString(path_col.x, header_rect.y, "Path", header_style);

    var y: u16 = list_rect.y + 1;
    var idx: usize = app.scroll_offset;
    while (idx < app.view.items.len) : (idx += 1) {
        if (y >= list_rect.y + list_rect.height) break;
        const pv = app.view.items[idx];
        const p = pv.proc;
        const style = if (idx == app.selected_item)
            _Style{ .bg = .blue, .fg = .white }
        else
            _Style{ .fg = .white };
        var pid_buf: [8]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d:<7}", .{p.pid}) catch "err";
        var cpu_buf: [7]u8 = undefined;
        const cpu_str = std.fmt.bufPrint(&cpu_buf, "{d:>5.1}%", .{pv.cpu_percent}) catch "err";

        var mem_buf: [10]u8 = undefined;
        const mem_mb = @as(f64, @floatFromInt(p.mem_rss)) / (1024.0 * 1024.0);
        const mem_str = std.fmt.bufPrint(&mem_buf, "{d:>6.1} MB", .{mem_mb}) catch "err";

        const name = std.mem.sliceTo(&p.s_name, 0);
        const name_display = name[0..@min(name.len, name_col.width)];
        const path = std.mem.sliceTo(&p.path, 0);
        const path_display = path[0..@min(path.len, path_col.width)];

        buf.setString(pid_col.x, y, pid_str, style);
        buf.setString(name_col.x, y, name_display, style);
        buf.setString(cpu_col.x, y, cpu_str, style);
        buf.setString(mem_col.x, y, mem_str, style);
        buf.setString(path_col.x, y, path_display, style);
        y += 1;
    }
    if (app.mode == .search) {
        renderSearchInput(buf, footer_rect, app);
    } else {
        // });
        renderHelpBar(buf, footer_rect);
    }
    block.render(area, buf);

    // Render toast notifications as overlay
    if (app.active_toast) |*toast| {
        renderToast(buf, toast, area);
    }
}

fn renderHelpBar(buf: *tui.render.Buffer, rect: layout.Rect) void {
    var help_buf: [512]u8 = [_]u8{' '} ** 512;
    const help_text = keymap.getHelpText(.normal, &help_buf);

    const width: usize = @min(rect.width, help_text.len);
    buf.setString(rect.x, rect.y, help_text[0..width], _Style{ .fg = .gray });
}
// fn renderHelpBar(buf: *tui.render.Buffer, rect: layout.Rect) void {
//     const help_text = "/ to search search, q to quit, x to kill process, c to clear search, arrow keys to navigate";
//     // std.debug.print("", .{});
//     var line_buf: [512]u8 = [_]u8{' '} ** 512;
//     @memcpy(line_buf[0..help_text.len], help_text);
//
//     const width: usize = @min(rect.width, line_buf.len);
//     buf.setString(rect.x, rect.y, line_buf[0..width], _Style{ .fg = .gray });
// }
//
fn renderSearchInput(
    buf: *tui.render.Buffer,
    rect: layout.Rect,
    app: *const state.AppState,
) void {
    var line_buf: [512]u8 = [_]u8{' '} ** 512;

    const prompt_style = _Style{ .fg = .yellow };
    const text_style = _Style{ .fg = .white };
    const cursor_style = _Style{
        .fg = .yellow,
        .modifier = _Modifier{ .slow_blink = true },
    };
    //TODO move line output down one when text is beyond terminal length so that it shows the last text typed
    // examples. search string = helloworld but terminal cal only fit 5 char
    // [oworld]
    // Build the line
    line_buf[0] = '/';

    const query = app.searchSlice();
    if (query.len > 0) {
        // buf.setString(rect.x + 1, rect.y, query, text_style);
        @memcpy(line_buf[1 .. 1 + query.len], query);
    }
    line_buf[1 + query.len] = '_';

    //render full width in one call
    const width: usize = @min(rect.width, line_buf.len);

    buf.setString(rect.x, rect.y, line_buf[0..width], text_style);

    buf.setString(rect.x, rect.y, "/", prompt_style);

    const cursor_x: u16 = rect.x + 1 + @as(u16, @intCast(query.len));
    buf.setString(cursor_x, rect.y, "_", cursor_style);
}

fn renderToast(buf: *tui.render.Buffer, toast: *const state.Toast, area: tui.render.Rect) void {
    const message = toast.getMessage();
    if (message.len == 0) return;

    const style: _Style = switch (toast.level) {
        .info => .{ .fg = .white, .bg = .gray },
        .success => .{ .fg = .white, .bg = .green },
        .warning => .{ .fg = .black, .bg = .yellow },
        .err => .{ .fg = .white, .bg = .red },
    };

    const dismiss_text = "Press any key to dismiss";

    //width calcul
    const msg_len: u16 = @intCast(message.len);
    const dismiss_len: u16 = @intCast(dismiss_text.len);
    const box_width: u16 = @max(msg_len, dismiss_len) + 4;

    //center horizontally
    const toast_x = area.x + (area.width -| box_width) / 2;

    //center vert
    const toast_y = area.y + area.height / 2;

    var msg_buf: [136]u8 = [_]u8{' '} ** 136;
    const msg_start = (box_width - msg_len) / 2;
    @memcpy(msg_buf[msg_start..][0..message.len], message);

    // Build padded dismiss line
    var dismiss_buf: [136]u8 = [_]u8{' '} ** 136;
    const dismiss_start = (box_width - dismiss_len) / 2;
    @memcpy(dismiss_buf[dismiss_start..][0..dismiss_text.len], dismiss_text);

    buf.setString(toast_x, toast_y - 1, msg_buf[0..box_width], style);
    // buf.setString(toast_x, toast_y, msg_buf[0..box_width], style);
    buf.setString(toast_x, toast_y, dismiss_buf[0..box_width], style);
}
