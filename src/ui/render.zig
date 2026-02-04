const std = @import("std");
const tui = @import("zigtui");
const state = @import("state");
const layout = @import("ui_layout");
const keymap = @import("event_keymap");
const model = @import("model");

const _Style = tui.style.Style;
const _Modifier = tui.style.Modifier;
const _Color = tui.style.Color;

fn cpuColor(cpu_percent: f32) _Color {
    if (cpu_percent > 50.0) return .red;
    if (cpu_percent > 25.0) return .yellow;
    return .green;
}

fn memColor(mem_rss: u64) _Color {
    const mb = mem_rss / (1024 * 1024);
    if (mb > 1024) return .red;
    if (mb > 256) return .yellow;
    return .green;
}

fn renderColumnHeader(buf: *tui.render.Buffer, x: u16, y: u16, label: []const u8, is_active: bool, dir_suffix: []const u8) void {
    if (is_active) {
        var h_buf: [12]u8 = [_]u8{' '} ** 12;
        @memcpy(h_buf[0..label.len], label);
        @memcpy(h_buf[label.len..][0..dir_suffix.len], dir_suffix);
        buf.setString(x, y, h_buf[0 .. label.len + dir_suffix.len], _Style{ .fg = .light_yellow, .modifier = _Modifier{ .bold = true } });
    } else {
        buf.setString(x, y, label, _Style{ .fg = .cyan, .modifier = _Modifier{ .bold = true } });
    }
}

// --- Horizon dashboard layout ---
// left_stack is a nested column inside bottom_row's left half
const left_stack = layout.Container.column(&[_]layout.Item{
    .{ .id = "disk_io", .sizing = .{ .grow = 1.0 } },
    .{ .id = "network", .sizing = .{ .grow = 1.0 } },
});

// proc_inner is a nested column for process pane content
const proc_inner = layout.Container.column(&[_]layout.Item{
    .{ .id = "proc_header", .sizing = .{ .fixed = 1 } },
    .{ .id = "proc_list", .sizing = .{ .grow = 1.0 } },
    .{ .id = "proc_footer", .sizing = .{ .fixed = 1 } },
});

const top_row = layout.Container.row(&[_]layout.Item{
    .{ .id = "cpu_graph", .sizing = .{ .grow = 3.0 } },
    .{ .id = "cores", .sizing = .{ .grow = 1.0 } },
});

const bottom_row = layout.Container.row(&[_]layout.Item{
    .{ .id = "bottom_left", .sizing = .{ .grow = 1.0 }, .children = &left_stack },
    .{ .id = "bottom_right", .sizing = .{ .grow = 1.0 }, .children = &proc_inner },
});

const horizon_layout = layout.Container.column(&[_]layout.Item{
    .{ .id = "top_row", .sizing = .{ .percent = 0.375 }, .children = &top_row },
    .{ .id = "bottom_row", .sizing = .{ .grow = 1.0 }, .children = &bottom_row },
});

const column_layout = layout.Container.row(&[_]layout.Item{
    .{ .id = "pid", .sizing = .{ .fixed = 8 } },
    .{ .id = "name", .sizing = .{ .grow = 1.0 } },
    .{ .id = "cpu", .sizing = .{ .fixed = 7.0 } },
    .{ .id = "mem", .sizing = .{ .fixed = 10.0 } },
    .{ .id = "path", .sizing = .{ .grow = 2.0 } },
});

const detail_page_layout = layout.Container.column(&[_]layout.Item{
    .{ .id = "detail_header", .sizing = .{ .fixed = 4 } },
    .{ .id = "detail_body", .sizing = .{ .grow = 1.0 } },
    .{ .id = "detail_footer", .sizing = .{ .fixed = 1 } },
});

const detail_body_layout = layout.Container.row(&[_]layout.Item{
    .{ .id = "detail_left", .sizing = .{ .grow = 3.0 } },
    .{ .id = "detail_div", .sizing = .{ .fixed = 1 } },
    .{ .id = "detail_right", .sizing = .{ .grow = 2.0 } },
});

const detail_right_layout = layout.Container.column(&[_]layout.Item{
    .{ .id = "right_stats", .sizing = .{ .fixed = 7 } },
    .{ .id = "right_tree", .sizing = .{ .grow = 1.0 } },
});

/// Shrink a rect by 1 on all sides (for content inside a bordered pane).
fn inset(rect: layout.Rect) layout.Rect {
    return .{
        .x = rect.x + 1,
        .y = rect.y + 1,
        .width = rect.width -| 2,
        .height = rect.height -| 2,
    };
}

fn renderPaneBorder(buf: *tui.render.Buffer, rect: layout.Rect, title: []const u8) void {
    const block = tui.widgets.Block{
        .title = title,
        .borders = tui.widgets.Borders.all(),
        .border_style = _Style{ .fg = .cyan },
    };
    block.render(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, buf);
}

pub fn render(draw_ctx: state.DrawContext, buf: *tui.render.Buffer) !void {
    const app = draw_ctx.state;
    const area = buf.getArea();

    var calculated = try layout.calculate(
        draw_ctx.scratch,
        horizon_layout,
        layout.Rect{
            .x = area.x,
            .y = area.y,
            .width = area.width,
            .height = area.height,
        },
    );
    defer calculated.deinit();

    // Get pane rects from layout
    const cpu_graph_rect = calculated.get("cpu_graph") orelse return;
    const cores_rect = calculated.get("cores") orelse return;
    const disk_io_rect = calculated.get("disk_io") orelse return;
    const network_rect = calculated.get("network") orelse return;
    const proc_header_rect = calculated.get("proc_header") orelse return;
    const proc_list_rect = calculated.get("proc_list") orelse return;
    const proc_footer_rect = calculated.get("proc_footer") orelse return;
    const bottom_right_rect = calculated.get("bottom_right") orelse return;

    // Draw pane borders
    renderPaneBorder(buf, cpu_graph_rect, "CPU");
    renderPaneBorder(buf, cores_rect, "Cores");
    renderPaneBorder(buf, disk_io_rect, "Disk IO");
    renderPaneBorder(buf, network_rect, "Network");
    renderPaneBorder(buf, bottom_right_rect, "Processes");

    // Render pane contents inside borders
    renderCpuGraph(buf, inset(cpu_graph_rect), &app.system);
    renderCoresBars(buf, inset(cores_rect), &app.system);
    renderDiskIO(buf, inset(disk_io_rect), &app.system);
    renderNetwork(buf, inset(network_rect), &app.system);

    // Render process pane (inside the "Processes" border)
    renderProcessPane(buf, draw_ctx.scratch, app, proc_header_rect, proc_list_rect, proc_footer_rect);

    // Overlay modes
    if (app.mode == .help) {
        renderHelpView(buf, area, app);
    }

    if (app.mode == .detail) {
        renderDetailView(buf, area, app, draw_ctx.scratch);
    }

    if (app.active_toast) |*toast| {
        renderToast(buf, toast, area);
    }
}

fn renderProcessPane(
    buf: *tui.render.Buffer,
    scratch: std.mem.Allocator,
    app: *state.AppState,
    header_rect: layout.Rect,
    list_rect: layout.Rect,
    footer_rect: layout.Rect,
) void {
    var columns = layout.calculate(
        scratch,
        column_layout,
        layout.Rect{
            .x = list_rect.x,
            .y = list_rect.y,
            .width = list_rect.width,
            .height = 1,
        },
    ) catch return;
    defer columns.deinit();

    const pid_col = columns.get("pid") orelse return;
    const name_col = columns.get("name") orelse return;
    const cpu_col = columns.get("cpu") orelse return;
    const mem_col = columns.get("mem") orelse return;
    const path_col = columns.get("path") orelse return;

    const visible_rows = list_rect.height;
    if (visible_rows > 0) {
        if (app.selected_item >= app.scroll_offset + visible_rows) {
            app.scroll_offset = app.selected_item - visible_rows + 1;
        }
        if (app.selected_item < app.scroll_offset) {
            app.scroll_offset = app.selected_item;
        }
    }
    const dir_suffix: []const u8 = if (app.procs.sort_direction == .desc) "v" else "^";
    renderColumnHeader(buf, pid_col.x, header_rect.y, "PID", app.procs.sort_column == .pid, dir_suffix);
    renderColumnHeader(buf, name_col.x, header_rect.y, "Name", app.procs.sort_column == .name, dir_suffix);
    renderColumnHeader(buf, cpu_col.x, header_rect.y, "CPU%", app.procs.sort_column == .cpu, dir_suffix);
    renderColumnHeader(buf, mem_col.x, header_rect.y, "MEM", app.procs.sort_column == .mem, dir_suffix);
    renderColumnHeader(buf, path_col.x, header_rect.y, "Path", app.procs.sort_column == .path, dir_suffix);

    var y: u16 = list_rect.y;
    var idx: usize = app.scroll_offset;
    const rows = app.procs.render_rows.items;
    while (idx < rows.len) : (idx += 1) {
        if (y >= list_rect.y + list_rect.height) break;

        const row = rows[idx];
        const is_selected = idx == app.selected_item;

        const name_style: _Style = if (is_selected) .{ .bg = .blue, .fg = .white } else .{ .fg = .white };
        const secondary_style: _Style = if (is_selected) .{ .bg = .blue, .fg = .gray } else .{ .fg = .gray };
        const prefix_style: _Style = if (is_selected) .{ .bg = .blue, .fg = .gray } else .{ .fg = .gray };

        const cpu_fg = cpuColor(row.cpu_percent);
        const cpu_style: _Style = if (is_selected) .{ .bg = .blue, .fg = cpu_fg } else .{ .fg = cpu_fg };

        const mem_fg = memColor(row.mem_rss);
        const mem_style: _Style = if (is_selected) .{ .bg = .blue, .fg = mem_fg } else .{ .fg = mem_fg };

        var pid_buf: [8]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d:<7}", .{row.pid}) catch "err";
        var cpu_buf: [7]u8 = undefined;
        const cpu_str = std.fmt.bufPrint(&cpu_buf, "{d:>5.1}%", .{row.cpu_percent}) catch "err";

        var mem_buf: [10]u8 = undefined;
        const mem_mb = @as(f64, @floatFromInt(row.mem_rss)) / (1024.0 * 1024.0);
        const mem_str = std.fmt.bufPrint(&mem_buf, "{d:>6.1} MB", .{mem_mb}) catch "err";

        const prefix_width = renderTreePrefix(buf, name_col.x, y, row, prefix_style, name_col.width);
        const name_x = name_col.x + prefix_width;
        const name_width: u16 = name_col.width -| prefix_width;

        const name_display = row.name[0..@min(row.name.len, @as(usize, @intCast(name_width)))];
        const path_display = row.path[0..@min(row.path.len, path_col.width)];

        buf.setString(pid_col.x, y, pid_str, secondary_style);
        if (name_width > 0) {
            buf.setString(name_x, y, name_display, name_style);
        }

        buf.setString(cpu_col.x, y, cpu_str, cpu_style);
        buf.setString(mem_col.x, y, mem_str, mem_style);
        buf.setString(path_col.x, y, path_display, secondary_style);
        y += 1;
    }
    if (app.mode == .search_edit) {
        renderSearchInput(buf, footer_rect, app);
    } else {
        renderStatusBar(buf, footer_rect, app);
    }
}

fn renderCpuGraph(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.width == 0 or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);

    // Draw braille area chart from CpuHistory ring buffer
    // Each column maps to one sample, newest at right edge
    const history = &sys.cpu_history;
    const sample_count = history.count;

    var col: usize = 0;
    while (col < width) : (col += 1) {
        // Map column to sample index (right-aligned)
        const sample_idx = if (sample_count > width)
            sample_count - width + col
        else if (col >= width - sample_count)
            col - (width - sample_count)
        else {
            continue; // no data for this column yet
        };

        const value = history.get(sample_idx);
        const clamped = @min(value, 100.0);
        // Height in braille dots (4 dots per character row)
        const total_dots: usize = height * 4;
        const fill_dots: usize = @intFromFloat(clamped / 100.0 * @as(f32, @floatFromInt(total_dots)));
        const color = cpuColor(clamped);

        // Render bottom-up: each character cell is 2 wide x 4 tall in braille
        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row;
            const dot_base = row * 4;
            var pattern: u8 = 0;
            // Braille left column dots (we use single-column: left dots only)
            // dot 0 = bit 0, dot 1 = bit 1, dot 2 = bit 2, dot 6 = bit 6
            const dot_bits = [4]u8{ 0x01, 0x02, 0x04, 0x40 };
            for (dot_bits, 0..) |bit, di| {
                if (dot_base + di < fill_dots) {
                    pattern |= bit;
                }
            }
            const braille_cp: u21 = 0x2800 + @as(u21, pattern);
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(braille_cp, &utf8_buf) catch continue;
            buf.setString(
                rect.x + @as(u16, @intCast(col)),
                rect.y + @as(u16, @intCast(screen_row)),
                utf8_buf[0..utf8_len],
                _Style{ .fg = color },
            );
        }
    }

    // Total CPU% label at bottom-right
    var label_buf: [12]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{d:>5.1}%", .{sys.total_cpu_percent}) catch "???";
    const label_x = rect.x + rect.width -| @as(u16, @intCast(label.len));
    buf.setString(label_x, rect.y + rect.height -| 1, label, _Style{ .fg = cpuColor(sys.total_cpu_percent), .modifier = _Modifier{ .bold = true } });
}

fn renderCoresBars(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting...", _Style{ .fg = .gray });
        return;
    }

    const count = @min(sys.core_count, @as(u32, @intCast(rect.height -| 1)));
    for (0..count) |i| {
        const y = rect.y + @as(u16, @intCast(i));
        const pct = sys.core_percents[i];
        var line_buf: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&line_buf, "{d:>2} ", .{i}) catch "?? ";
        buf.setString(rect.x, y, label, _Style{ .fg = .gray });
        const bar_x = rect.x + @as(u16, @intCast(label.len));
        const bar_w = rect.width -| @as(u16, @intCast(label.len)) -| 5;
        renderBar(buf, bar_x, y, bar_w, pct, 100.0, cpuColor(pct));
        var pct_buf: [6]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch "???";
        buf.setString(bar_x + bar_w + 1, y, pct_str, _Style{ .fg = cpuColor(pct) });
    }

    // Total line at bottom
    const total_y = rect.y + rect.height -| 1;
    var total_buf: [24]u8 = undefined;
    const total_str = std.fmt.bufPrint(&total_buf, "total {d:>5.1}%", .{sys.total_cpu_percent}) catch "total ???";
    const total_x = rect.x + rect.width -| @as(u16, @intCast(total_str.len));
    buf.setString(total_x, total_y, total_str, _Style{ .fg = cpuColor(sys.total_cpu_percent), .modifier = _Modifier{ .bold = true } });
}

fn renderDiskIO(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    // Read rate
    buf.setString(rect.x, rect.y, "R ", _Style{ .fg = .green, .modifier = _Modifier{ .bold = true } });
    const bar_w = rect.width -| 14;
    renderRateBar(buf, rect.x + 2, rect.y, bar_w, sys.disk_read_rate, .green);
    var r_buf: [12]u8 = undefined;
    const r_str = formatRate(&r_buf, sys.disk_read_rate);
    buf.setString(rect.x + 2 + bar_w + 1, rect.y, r_str, _Style{ .fg = .green });

    // Write rate
    if (rect.height > 1) {
        buf.setString(rect.x, rect.y + 1, "W ", _Style{ .fg = .red, .modifier = _Modifier{ .bold = true } });
        renderRateBar(buf, rect.x + 2, rect.y + 1, bar_w, sys.disk_write_rate, .red);
        var w_buf: [12]u8 = undefined;
        const w_str = formatRate(&w_buf, sys.disk_write_rate);
        buf.setString(rect.x + 2 + bar_w + 1, rect.y + 1, w_str, _Style{ .fg = .red });
    }
}

fn renderNetwork(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    // Recv rate
    const recv_glyph = "\xe2\x96\xbc"; // U+25BC black down-pointing triangle
    buf.setString(rect.x, rect.y, recv_glyph, _Style{ .fg = .green, .modifier = _Modifier{ .bold = true } });
    const bar_w = rect.width -| 14;
    renderRateBar(buf, rect.x + 2, rect.y, bar_w, sys.net_recv_rate, .green);
    var r_buf: [12]u8 = undefined;
    const r_str = formatRate(&r_buf, sys.net_recv_rate);
    buf.setString(rect.x + 2 + bar_w + 1, rect.y, r_str, _Style{ .fg = .green });

    // Sent rate
    if (rect.height > 1) {
        const sent_glyph = "\xe2\x96\xb2"; // U+25B2 black up-pointing triangle
        buf.setString(rect.x, rect.y + 1, sent_glyph, _Style{ .fg = .red, .modifier = _Modifier{ .bold = true } });
        renderRateBar(buf, rect.x + 2, rect.y + 1, bar_w, sys.net_sent_rate, .red);
        var s_buf: [12]u8 = undefined;
        const s_str = formatRate(&s_buf, sys.net_sent_rate);
        buf.setString(rect.x + 2 + bar_w + 1, rect.y + 1, s_str, _Style{ .fg = .red });
    }
}

fn renderBar(buf: *tui.render.Buffer, x: u16, y: u16, width: u16, value: f32, max_val: f32, color: _Color) void {
    if (width == 0) return;
    const ratio = @min(value / max_val, 1.0);
    const filled: u16 = @intFromFloat(ratio * @as(f32, @floatFromInt(width)));

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            buf.setString(x + i, y, "\xe2\x96\x88", _Style{ .fg = color }); // U+2588 full block
        } else {
            buf.setString(x + i, y, "\xe2\x96\x91", _Style{ .fg = .gray }); // U+2591 light shade
        }
    }
}

fn renderRateBar(buf: *tui.render.Buffer, x: u16, y: u16, width: u16, rate: f64, color: _Color) void {
    if (width == 0) return;
    // Auto-scale: bar is relative to a reasonable max (100 MB/s)
    const max_rate: f64 = 100.0 * 1024.0 * 1024.0;
    const ratio: f32 = @floatCast(@min(rate / max_rate, 1.0));
    const filled: u16 = @intFromFloat(ratio * @as(f32, @floatFromInt(width)));

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            buf.setString(x + i, y, "\xe2\x96\x88", _Style{ .fg = color });
        } else {
            buf.setString(x + i, y, "\xe2\x96\x91", _Style{ .fg = .gray });
        }
    }
}

fn formatRate(out_buf: *[12]u8, rate: f64) []const u8 {
    if (rate >= 1024.0 * 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>5.1} GB/s", .{rate / (1024.0 * 1024.0 * 1024.0)}) catch "??? GB/s";
    } else if (rate >= 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>5.1} MB/s", .{rate / (1024.0 * 1024.0)}) catch "??? MB/s";
    } else if (rate >= 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>5.1} KB/s", .{rate / 1024.0}) catch "??? KB/s";
    } else {
        return std.fmt.bufPrint(out_buf, "{d:>5.0}  B/s", .{rate}) catch "???  B/s";
    }
}

fn renderTreePrefix(
    buf: *tui.render.Buffer,
    x: u16,
    y: u16,
    row: model.RenderRow,
    style: _Style,
    max_width: u16,
) u16 {
    var prefix_buf: [64]u8 = undefined;
    var pos: usize = 0;

    var d: u16 = 0;
    while (d < row.depth and pos + 2 < prefix_buf.len) : (d += 1) {
        prefix_buf[pos] = ' ';
        prefix_buf[pos + 1] = ' ';
        pos += 2;
    }

    const glyph: u8 = if (row.has_children) (if (row.is_expanded) 'v' else '>') else ' ';
    if (pos + 2 <= prefix_buf.len) {
        prefix_buf[pos] = glyph;
        prefix_buf[pos + 1] = ' ';
        pos += 2;
    }

    const width: u16 = @min(max_width, @as(u16, @intCast(pos)));
    if (width > 0) {
        buf.setString(x, y, prefix_buf[0..width], style);
    }
    return width;
}

fn renderHelpView(buf: *tui.render.Buffer, area: tui.render.Rect, app: *state.AppState) void {
    // Two-column layout: left and right category groups
    const left_cats = [_][]const u8{ "Navigation", "Search", "Tree" };
    const right_cats = [_][]const u8{ "Sorting", "Process", "General" };

    const cat_style = _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } };
    const key_style = _Style{ .fg = .light_yellow, .modifier = _Modifier{ .bold = true } };
    const desc_style = _Style{ .fg = .light_white };
    const key_w: u16 = 10;

    // Measure max description width
    var max_desc: u16 = 0;
    for (keymap.keymap) |binding| {
        if (binding.description.len == 0) continue;
        max_desc = @max(max_desc, @as(u16, @intCast(binding.description.len)));
    }
    const col_w: u16 = key_w + max_desc;
    const col_gap: u16 = 4;

    // Measure height for each column
    const left_h = measureCategoryHeight(&left_cats);
    const right_h = measureCategoryHeight(&right_cats);
    const content_h: u16 = @max(left_h, right_h);

    // Box dimensions — clamp height to terminal
    const content_total_w: u16 = col_w + col_gap + col_w;
    const box_width: u16 = @min(content_total_w + 6, area.width -| 4);
    // inner = border(2) + top blank(1) + dismiss(1) + bottom blank(1) = 5 overhead
    const ideal_height: u16 = content_h + 5;
    const box_height: u16 = @min(ideal_height, area.height -| 2);
    const box_x: u16 = area.x + (area.width -| box_width) / 2;
    const box_y: u16 = area.y + (area.height -| box_height) / 2;

    // Available lines for content (inside border, minus top blank + dismiss row)
    const avail_h: u16 = box_height -| 5;
    const needs_scroll = content_h > avail_h;

    // Clamp scroll offset
    if (needs_scroll) {
        const max_scroll: usize = @as(usize, content_h -| avail_h);
        app.help_scroll = @min(app.help_scroll, max_scroll);
    } else {
        app.help_scroll = 0;
    }

    // Clear box area
    const bg_style = _Style{ .bg = .reset };
    var cy: u16 = box_y;
    while (cy < box_y + box_height) : (cy += 1) {
        var blank_buf: [160]u8 = [_]u8{' '} ** 160;
        const w: usize = @min(box_width, blank_buf.len);
        buf.setString(box_x, cy, blank_buf[0..w], bg_style);
    }

    // Border
    const help_block = tui.widgets.Block{
        .title = "Help / Keybindings",
        .borders = tui.widgets.Borders.all(),
        .border_style = _Style{ .fg = .cyan },
    };
    help_block.render(tui.render.Rect{ .x = box_x, .y = box_y, .width = box_width, .height = box_height }, buf);

    // Center the two-column block within the box
    const left_x: u16 = box_x + (box_width -| content_total_w) / 2;
    const right_x: u16 = left_x + col_w + col_gap;
    const start_y: u16 = box_y + 2; // skip border + blank
    const scroll: u16 = @intCast(app.help_scroll);

    // Render left column with scroll
    renderHelpColumn(buf, &left_cats, left_x, start_y, avail_h, scroll, key_w, col_w, cat_style, key_style, desc_style);
    // Render right column with scroll
    renderHelpColumn(buf, &right_cats, right_x, start_y, avail_h, scroll, key_w, col_w, cat_style, key_style, desc_style);

    // Scroll indicators (only when scrollable)
    if (needs_scroll) {
        const arrow_x = box_x + box_width -| 2;
        if (app.help_scroll > 0) {
            buf.setString(arrow_x, start_y, "^", _Style{ .fg = .cyan });
        }
        if (app.help_scroll + avail_h < content_h) {
            buf.setString(arrow_x, start_y + avail_h -| 1, "v", _Style{ .fg = .cyan });
        }
    }

    // Dismiss hint — include scroll hint only when needed
    const dismiss = if (needs_scroll) "j/k:scroll  ?/esc:close" else "?/esc:close";
    const dismiss_x = box_x + (box_width -| @as(u16, @intCast(dismiss.len))) / 2;
    buf.setString(dismiss_x, box_y + box_height - 2, dismiss, _Style{ .fg = .white });
}

fn measureCategoryHeight(cats: []const []const u8) u16 {
    var lines: u16 = 0;
    for (cats) |cat| {
        var has_entries = false;
        for (keymap.keymap) |binding| {
            if (binding.description.len == 0) continue;
            if (!std.mem.eql(u8, binding.category, cat)) continue;
            has_entries = true;
            lines += 1;
        }
        if (has_entries) lines += 2; // header + trailing blank
    }
    return lines;
}

fn renderHelpColumn(
    buf: *tui.render.Buffer,
    cats: []const []const u8,
    col_x: u16,
    screen_y: u16,
    visible_h: u16,
    scroll: u16,
    key_w: u16,
    col_w: u16,
    cat_style: _Style,
    key_style: _Style,
    desc_style: _Style,
) void {
    const vis_start: usize = scroll;
    const vis_end: usize = scroll + @as(usize, visible_h);
    var ln: usize = 0;

    for (cats) |cat| {
        var has_entries = false;
        for (keymap.keymap) |binding| {
            if (binding.description.len == 0) continue;
            if (!std.mem.eql(u8, binding.category, cat)) continue;
            has_entries = true;
        }
        if (!has_entries) continue;

        // Category header
        if (ln >= vis_start and ln < vis_end) {
            const y = screen_y + @as(u16, @intCast(ln - vis_start));
            buf.setString(col_x, y, cat, cat_style);
        }
        ln += 1;

        // Entries
        for (keymap.keymap) |binding| {
            if (ln >= vis_end) break;
            if (binding.description.len == 0) continue;
            if (!std.mem.eql(u8, binding.category, cat)) continue;

            if (ln >= vis_start) {
                const y = screen_y + @as(u16, @intCast(ln - vis_start));
                const key_str = switch (binding.key) {
                    .char => |ch| &[_]u8{ch},
                    .special => |s| switch (s) {
                        .up => "up",
                        .down => "dn",
                        .esc => "esc",
                        .enter => "enter",
                        .backspace => "bksp",
                        .tab => "tab/S-Ent",
                    },
                };
                var line_buf: [60]u8 = [_]u8{' '} ** 60;
                for (key_str, 0..) |ch, i| {
                    if (i < line_buf.len) line_buf[i] = ch;
                }
                for (binding.description, 0..) |ch, i| {
                    if (key_w + i < line_buf.len) line_buf[key_w + i] = ch;
                }
                const line_w: usize = @min(col_w, line_buf.len);
                buf.setString(col_x, y, line_buf[0..line_w], desc_style);
                buf.setString(col_x, y, key_str, key_style);
            }
            ln += 1;
        }
        ln += 1; // blank between categories
    }
}

fn renderStatusBar(buf: *tui.render.Buffer, rect: layout.Rect, app: *const state.AppState) void {
    var x: u16 = rect.x;

    // Segment 1: process count
    const visible = app.procs.render_rows.items.len;
    const total = app.procs.hot.len;
    var count_buf: [32]u8 = undefined;
    if (std.fmt.bufPrint(&count_buf, "{d}/{d} shown", .{ visible, total })) |slice| {
        buf.setString(x, rect.y, slice, _Style{ .fg = .light_white });
        x += @intCast(slice.len);
    } else |_| {}

    // Separator
    buf.setString(x, rect.y, " | ", _Style{ .fg = .gray });
    x += 3;

    // Segment 2: last update (green if fresh, yellow if stale, gray if old)
    if (app.last_update_ns > 0) {
        const now = std.time.nanoTimestamp();
        const delta_ns = now - app.last_update_ns;
        const delta_s: u64 = @intCast(@max(0, @divTrunc(delta_ns, std.time.ns_per_s)));
        const update_style: _Style = if (delta_s < 5) .{ .fg = .green } else if (delta_s < 15) .{ .fg = .yellow } else .{ .fg = .gray };
        var update_buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&update_buf, "updated {d}s ago", .{delta_s})) |slice| {
            buf.setString(x, rect.y, slice, update_style);
            x += @intCast(slice.len);
        } else |_| {}
    } else {
        buf.setString(x, rect.y, "no data", _Style{ .fg = .gray });
        x += 7;
    }

    // Separator
    buf.setString(x, rect.y, " | ", _Style{ .fg = .gray });
    x += 3;

    // Segment 3: sort indicator
    const col_name: []const u8 = switch (app.procs.sort_column) {
        .pid => "PID",
        .name => "Name",
        .cpu => "CPU",
        .mem => "MEM",
        .path => "Path",
    };
    const dir_glyph: []const u8 = if (app.procs.sort_direction == .desc) "v" else "^";
    var sort_buf: [24]u8 = undefined;
    if (std.fmt.bufPrint(&sort_buf, "sort: {s}{s}", .{ col_name, dir_glyph })) |slice| {
        buf.setString(x, rect.y, slice, _Style{ .fg = .cyan });
        x += @intCast(slice.len);
    } else |_| {}

    // Segment 4 (search_view only): search query
    if (app.mode == .search_view) {
        const query = app.searchSlice();
        if (query.len > 0) {
            buf.setString(x, rect.y, " | ", _Style{ .fg = .gray });
            x += 3;
            var search_buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&search_buf, "search: \"{s}\"", .{query})) |slice| {
                buf.setString(x, rect.y, slice, _Style{ .fg = .light_yellow });
                x += @intCast(slice.len);
            } else |_| {}
        }
    }

    // Right-aligned ?:help hint
    const hint = "?:help";
    const hint_x: u16 = rect.x + rect.width -| @as(u16, @intCast(hint.len));
    buf.setString(hint_x, rect.y, hint, _Style{ .fg = .gray });
}

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

fn renderDetailView(buf: *tui.render.Buffer, area: tui.render.Rect, app: *state.AppState, scratch: std.mem.Allocator) void {
    // Modal dimensions: 3/4 of screen, centered
    const box_w: u16 = area.width * 3 / 4;
    const box_h: u16 = area.height * 3 / 4;
    const box_x: u16 = area.x + (area.width -| box_w) / 2;
    const box_y: u16 = area.y + (area.height -| box_h) / 2;

    // Clear modal area
    const bg_style = _Style{ .bg = .reset };
    var cy: u16 = box_y;
    while (cy < box_y + box_h) : (cy += 1) {
        var blank_buf: [256]u8 = [_]u8{' '} ** 256;
        const w: usize = @min(box_w, blank_buf.len);
        buf.setString(box_x, cy, blank_buf[0..w], bg_style);
    }

    const modal = tui.render.Rect{
        .x = box_x,
        .y = box_y,
        .width = box_w,
        .height = box_h,
    };

    // Border
    const block = tui.widgets.Block{
        .title = "Process Detail",
        .borders = tui.widgets.Borders.all(),
        .border_style = _Style{ .fg = .cyan },
    };
    block.render(modal, buf);

    // Page layout inside border (2-char horizontal padding, 1-char vertical)
    const pad_x: u16 = 3;
    const pad_y: u16 = 1;
    var page = layout.calculate(scratch, detail_page_layout, layout.Rect{
        .x = modal.x + pad_x,
        .y = modal.y + pad_y,
        .width = modal.width -| (pad_x * 2),
        .height = modal.height -| (pad_y * 2),
    }) catch return;
    defer page.deinit();

    const header_rect = page.get("detail_header") orelse return;
    const body_rect = page.get("detail_body") orelse return;
    const footer_rect = page.get("detail_footer") orelse return;

    // Loading state — centered text when SPSC result hasn't arrived yet
    if (app.detail_data == null) {
        const loading = "Loading...";
        const lx = modal.x + (modal.width -| @as(u16, @intCast(loading.len))) / 2;
        const ly = modal.y + modal.height / 2;
        buf.setString(lx, ly, loading, _Style{ .fg = .yellow });
        return;
    }

    const detail = app.detail_data.?;

    // Find live CPU/MEM from render_rows by PID match
    var live_cpu: f32 = 0;
    var live_mem: u64 = 0;
    for (app.procs.render_rows.items) |row| {
        if (row.pid == detail.pid) {
            live_cpu = row.cpu_percent;
            live_mem = row.mem_rss;
            break;
        }
    }

    // --- Header (4 lines) ---
    const lbl_style = _Style{ .fg = .gray };
    const val_style = _Style{ .fg = .light_white };
    const title_style = _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } };

    // Line 1: name + PID
    var name_buf: [80]u8 = undefined;
    const name_line = std.fmt.bufPrint(&name_buf, "{s} (PID: {d})", .{ detail.name, detail.pid }) catch "???";
    buf.setString(header_rect.x, header_rect.y, name_line, title_style);

    // Line 2: path
    const path_max: usize = @intCast(header_rect.width -| 6);
    const path_display = detail.path[0..@min(detail.path.len, path_max)];
    buf.setString(header_rect.x, header_rect.y + 1, "Path: ", lbl_style);
    buf.setString(header_rect.x + 6, header_rect.y + 1, path_display, val_style);

    // Line 3: State | User | Uptime | PPID
    const state_str: []const u8 = switch (detail.state) {
        .running => "running",
        .sleeping => "sleeping",
        .disk_wait => "disk_wait",
        .stopped => "stopped",
        .zombie => "zombie",
        .unkown => "unknown",
    };
    const state_color: _Color = switch (detail.state) {
        .running => .green,
        .sleeping => .gray,
        .stopped => .yellow,
        .zombie => .red,
        .disk_wait => .yellow,
        .unkown => .gray,
    };
    const now_ns = std.time.nanoTimestamp();
    const uptime_ns = now_ns - detail.start_time_ns;
    const uptime_s: u64 = @intCast(@max(0, @divTrunc(uptime_ns, std.time.ns_per_s)));
    const hours = uptime_s / 3600;
    const minutes = (uptime_s % 3600) / 60;
    // Render "State: " label + colored value, then the rest as a single formatted string
    buf.setString(header_rect.x, header_rect.y + 2, "State: ", lbl_style);
    buf.setString(header_rect.x + 7, header_rect.y + 2, state_str, _Style{ .fg = state_color });
    const info_x = header_rect.x + 7 + @as(u16, @intCast(state_str.len));
    var info_buf: [80]u8 = undefined;
    const info_line = std.fmt.bufPrint(&info_buf, " | User: {s} | Uptime: {d}h {d}m | PPID: {d}", .{
        detail.user_name,
        hours,
        minutes,
        detail.ppid,
    }) catch "???";
    buf.setString(info_x, header_rect.y + 2, info_line, lbl_style);

    // --- Header separator (line 4 — thin rule) ---
    {
        var sep_buf: [256]u8 = undefined;
        const sep_w: usize = @min(header_rect.width, sep_buf.len);
        @memset(sep_buf[0..sep_w], '-');
        buf.setString(header_rect.x, header_rect.y + 3, sep_buf[0..sep_w], _Style{ .fg = .gray });
    }

    // --- Body: two-pane split (3:divider:2 left:right) ---
    var body = layout.calculate(scratch, detail_body_layout, layout.Rect{
        .x = body_rect.x,
        .y = body_rect.y,
        .width = body_rect.width,
        .height = body_rect.height,
    }) catch return;
    defer body.deinit();

    const left_rect = body.get("detail_left") orelse return;
    const div_rect = body.get("detail_div") orelse return;
    const right_rect = body.get("detail_right") orelse return;

    // Render vertical divider between panes
    {
        var dy: u16 = div_rect.y;
        while (dy < div_rect.y + div_rect.height) : (dy += 1) {
            buf.setString(div_rect.x, dy, "|", _Style{ .fg = .gray });
        }
    }

    // Clamp left scroll
    const left_content_lines: usize = 11 + detail.environ.len;
    const left_visible: usize = @intCast(left_rect.height);
    if (left_content_lines > left_visible) {
        app.detail_scroll = @min(app.detail_scroll, left_content_lines - left_visible);
    } else {
        app.detail_scroll = 0;
    }

    // Split right pane: static stats on top, scrollable tree below
    var right_sub = layout.calculate(scratch, detail_right_layout, layout.Rect{
        .x = right_rect.x,
        .y = right_rect.y,
        .width = right_rect.width,
        .height = right_rect.height,
    }) catch return;
    defer right_sub.deinit();

    const stats_rect = right_sub.get("right_stats") orelse return;
    const tree_rect = right_sub.get("right_tree") orelse return;

    const left_focused = app.detail_focus == .left;

    // Render static live stats (always visible, never scrolls)
    renderDetailStats(buf, stats_rect, detail, live_cpu, live_mem, !left_focused);

    // Measure tree content, auto-scroll to show selected process, then render
    const tree_info = renderDetailTree(buf, tree_rect, detail, app, true, false);
    const tree_content_lines = tree_info.total_lines;
    const tree_visible: usize = @intCast(tree_rect.height);
    // Auto-center on first open (scroll still at 0 and selected proc not visible)
    if (app.detail_right_scroll == 0 and tree_info.self_line >= tree_visible and tree_content_lines > tree_visible) {
        // Center the selected process in the visible area
        const half = tree_visible / 2;
        app.detail_right_scroll = if (tree_info.self_line > half) tree_info.self_line - half else 0;
    }
    if (tree_content_lines > tree_visible) {
        app.detail_right_scroll = @min(app.detail_right_scroll, tree_content_lines - tree_visible);
    } else {
        app.detail_right_scroll = 0;
    }
    _ = renderDetailTree(buf, tree_rect, detail, app, false, !left_focused);

    // Render left pane
    renderDetailLeftPane(buf, left_rect, detail, app.detail_scroll, left_focused);

    // --- Scroll arrows for focused pane ---
    if (left_focused) {
        if (app.detail_scroll > 0) {
            const arrow_x = left_rect.x + left_rect.width -| 1;
            buf.setString(arrow_x, left_rect.y, "^", _Style{ .fg = .cyan });
        }
        if (left_content_lines > left_visible and app.detail_scroll + left_visible < left_content_lines) {
            const arrow_x = left_rect.x + left_rect.width -| 1;
            const arrow_y = left_rect.y + left_rect.height -| 1;
            buf.setString(arrow_x, arrow_y, "v", _Style{ .fg = .cyan });
        }
    } else {
        if (app.detail_right_scroll > 0) {
            const arrow_x = tree_rect.x + tree_rect.width -| 1;
            buf.setString(arrow_x, tree_rect.y, "^", _Style{ .fg = .cyan });
        }
        if (tree_content_lines > tree_visible and app.detail_right_scroll + tree_visible < tree_content_lines) {
            const arrow_x = tree_rect.x + tree_rect.width -| 1;
            const arrow_y = tree_rect.y + tree_rect.height -| 1;
            buf.setString(arrow_x, arrow_y, "v", _Style{ .fg = .cyan });
        }
    }

    // --- Footer keybinds ---
    const footer_hint = "esc:close  h/l:pane  j/k:scroll  u/d:page  g/G:top/bottom";
    buf.setString(footer_rect.x, footer_rect.y, footer_hint, _Style{ .fg = .gray });
}

fn renderDetailLeftPane(buf: *tui.render.Buffer, rect: layout.Rect, detail: model.ProcessDetail, scroll: usize, focused: bool) void {
    const sec: _Style = if (focused) .{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } } else .{ .fg = .gray };
    const lbl = _Style{ .fg = .gray };
    const val = _Style{ .fg = .light_white };

    const vis_start = scroll;
    const vis_end = scroll + @as(usize, rect.height);
    const max_w: usize = @intCast(rect.width);

    var ln: usize = 0;

    // --- Overview section ---
    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "Overview", sec);
    }
    ln += 1;

    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "  Executable: ", lbl);
        const vmax = max_w -| 14;
        buf.setString(rect.x + 14, y, detail.path[0..@min(detail.path.len, vmax)], val);
    }
    ln += 1;

    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "  Cmdline:    ", lbl);
        const vmax = max_w -| 14;
        buf.setString(rect.x + 14, y, detail.cmdline[0..@min(detail.cmdline.len, vmax)], val);
    }
    ln += 1;

    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "  CWD:        ", lbl);
        const vmax = max_w -| 14;
        buf.setString(rect.x + 14, y, detail.cwd[0..@min(detail.cwd.len, vmax)], val);
    }
    ln += 1;

    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "  User:       ", lbl);
        var user_buf: [48]u8 = undefined;
        const user_str = std.fmt.bufPrint(&user_buf, "{s} (uid: {d})", .{ detail.user_name, detail.uid }) catch "???";
        buf.setString(rect.x + 14, y, user_str, val);
    }
    ln += 1;

    // blank
    ln += 1;

    // --- Resources section ---
    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "Resources", sec);
    }
    ln += 1;

    // Start time (absolute timestamp)
    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "  Started:    ", lbl);
        var time_buf: [32]u8 = undefined;
        const start_s: u64 = @intCast(@max(0, @divTrunc(detail.start_time_ns, std.time.ns_per_s)));
        const epoch = std.time.epoch.EpochSeconds{ .secs = start_s };
        const day_secs = epoch.getDaySeconds();
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        }) catch "???";
        buf.setString(rect.x + 14, y, time_str, val);
    }
    ln += 1;

    // Priority / nice
    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "  Nice:       ", lbl);
        var nice_buf: [8]u8 = undefined;
        const nice_str = std.fmt.bufPrint(&nice_buf, "{d}", .{detail.nice}) catch "???";
        buf.setString(rect.x + 14, y, nice_str, val);
    }
    ln += 1;

    // blank
    ln += 1;

    // --- Environment section ---
    if (ln >= vis_start and ln < vis_end) {
        const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "Environment", sec);
    }
    ln += 1;

    if (detail.environ.len == 0) {
        if (ln >= vis_start and ln < vis_end) {
            const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
            buf.setString(rect.x, y, "  (none)", lbl);
        }
        ln += 1;
    } else {
        for (detail.environ) |env_entry| {
            if (ln >= vis_end) break;
            if (ln >= vis_start) {
                const y: u16 = rect.y + @as(u16, @intCast(ln - vis_start));
                const display_max = max_w -| 2;
                buf.setString(rect.x, y, "  ", lbl);
                buf.setString(rect.x + 2, y, env_entry[0..@min(env_entry.len, display_max)], val);
            }
            ln += 1;
        }
    }
}

fn renderDetailStats(buf: *tui.render.Buffer, rect: layout.Rect, detail: model.ProcessDetail, live_cpu: f32, live_mem: u64, focused: bool) void {
    const sec: _Style = if (focused) .{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } } else .{ .fg = .gray };
    const val = _Style{ .fg = .light_white };
    const rx: u16 = rect.x + 1;
    var y: u16 = rect.y;
    const max_y = rect.y + rect.height;

    if (y >= max_y) return;
    buf.setString(rx, y, "Live Stats", sec);
    y += 1;

    if (y >= max_y) return;
    var cpu_buf: [24]u8 = undefined;
    const cpu_str = std.fmt.bufPrint(&cpu_buf, "  CPU:     {d:>5.1}%", .{live_cpu}) catch "  CPU: ???";
    buf.setString(rx, y, cpu_str, _Style{ .fg = cpuColor(live_cpu) });
    y += 1;

    if (y >= max_y) return;
    var mem_buf: [24]u8 = undefined;
    const mem_mb = @as(f64, @floatFromInt(live_mem)) / (1024.0 * 1024.0);
    const mem_str = std.fmt.bufPrint(&mem_buf, "  MEM:     {d:>6.1} MB", .{mem_mb}) catch "  MEM: ???";
    buf.setString(rx, y, mem_str, _Style{ .fg = memColor(live_mem) });
    y += 1;

    if (y >= max_y) return;
    var thr_buf: [24]u8 = undefined;
    const thr_str = std.fmt.bufPrint(&thr_buf, "  Threads: {d}", .{detail.thread_count}) catch "  Threads: ???";
    buf.setString(rx, y, thr_str, val);
    y += 1;

    if (y >= max_y) return;
    var fd_buf: [24]u8 = undefined;
    const fd_str = std.fmt.bufPrint(&fd_buf, "  FDs:     {d}", .{detail.fd_count}) catch "  FDs: ???";
    buf.setString(rx, y, fd_str, val);
    y += 1;

    if (y >= max_y) return;
    var virt_buf: [24]u8 = undefined;
    const virt_gb = @as(f64, @floatFromInt(detail.virtual_mem)) / (1024.0 * 1024.0 * 1024.0);
    const virt_str = std.fmt.bufPrint(&virt_buf, "  Virtual: {d:>5.1} GB", .{virt_gb}) catch "  Virtual: ???";
    buf.setString(rx, y, virt_str, val);
}

const TreeInfo = struct { total_lines: usize, self_line: usize };

fn renderDetailTree(buf: *tui.render.Buffer, rect: layout.Rect, detail: model.ProcessDetail, app: *const state.AppState, measure_only: bool, focused: bool) TreeInfo {
    const sec: _Style = if (focused) .{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } } else .{ .fg = .gray };
    const lbl = _Style{ .fg = .gray };
    const val = _Style{ .fg = .light_white };
    const rx: u16 = rect.x + 1;
    const max_w: usize = @intCast(rect.width -| 1);

    const scroll = app.detail_right_scroll;
    const vis_start = scroll;
    const vis_end = scroll + @as(usize, rect.height);

    var ln: usize = 0;

    // Header
    if (!measure_only and ln >= vis_start and ln < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rx, y, "Process Tree", sec);
    }
    ln += 1;

    const pids = app.procs.hot.items(.pid);
    const cold = app.procs.cold.items;

    // Walk full ancestor chain (no cap) into a stack buffer
    const max_ancestors = 64;
    var ancestor_pids: [max_ancestors]model.pid_t = undefined;
    var ancestor_names: [max_ancestors][]const u8 = undefined;
    var ancestor_count: usize = 0;
    var walk_pid = detail.ppid;
    while (ancestor_count < max_ancestors) {
        if (walk_pid <= 0) break;
        if (app.procs.pid_to_index.get(walk_pid)) |idx| {
            const i: usize = @intCast(idx);
            if (i >= cold.len) break;
            ancestor_pids[ancestor_count] = walk_pid;
            ancestor_names[ancestor_count] = cold[i].name;
            ancestor_count += 1;
            const next_ppid = cold[i].ppid;
            if (next_ppid == walk_pid) break;
            walk_pid = next_ppid;
        } else break;
    }

    // Ancestors top-down (reverse the stack)
    var ai: usize = ancestor_count;
    while (ai > 0) {
        ai -= 1;
        if (!measure_only and ln >= vis_start and ln < vis_end) {
            const y = rect.y + @as(u16, @intCast(ln - vis_start));
            const indent = ancestor_count - 1 - ai;
            var anc_buf: [80]u8 = [_]u8{' '} ** 80;
            const pad: usize = 2 + indent * 2;
            var fmt_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&fmt_buf, "{s} ({d})", .{ ancestor_names[ai], ancestor_pids[ai] }) catch "???";
            const start = @min(pad, anc_buf.len);
            const end = @min(start + label.len, anc_buf.len);
            @memcpy(anc_buf[start..end], label[0 .. end - start]);
            buf.setString(rx, y, anc_buf[0..@min(end, max_w)], lbl);
        }
        ln += 1;
    }

    // Current process (highlighted)
    const self_ln = ln;
    if (!measure_only and ln >= vis_start and ln < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln - vis_start));
        const indent = ancestor_count * 2 + 2;
        var cur_buf: [80]u8 = [_]u8{' '} ** 80;
        var fmt_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&fmt_buf, "{s} ({d})", .{ detail.name, detail.pid }) catch "???";
        const start = @min(indent, cur_buf.len);
        const end = @min(start + label.len, cur_buf.len);
        @memcpy(cur_buf[start..end], label[0 .. end - start]);
        buf.setString(rx, y, cur_buf[0..@min(end, max_w)], _Style{ .fg = .light_yellow, .modifier = _Modifier{ .bold = true } });
    }
    ln += 1;

    // Children
    const child_indent = ancestor_count * 2 + 4;
    var child_count: u16 = 0;
    for (cold, 0..) |cold_entry, i| {
        if (i >= pids.len) break;
        if (cold_entry.ppid == detail.pid) {
            if (!measure_only and ln >= vis_start and ln < vis_end) {
                const y = rect.y + @as(u16, @intCast(ln - vis_start));
                var child_line: [80]u8 = [_]u8{' '} ** 80;
                var fmt_buf: [64]u8 = undefined;
                const label = std.fmt.bufPrint(&fmt_buf, "{s} ({d})", .{ cold_entry.name, pids[i] }) catch "???";
                const start = @min(child_indent, child_line.len);
                const end = @min(start + label.len, child_line.len);
                @memcpy(child_line[start..end], label[0 .. end - start]);
                buf.setString(rx, y, child_line[0..@min(end, max_w)], val);
            }
            ln += 1;
            child_count += 1;
        }
    }
    if (child_count == 0) {
        if (!measure_only and ln >= vis_start and ln < vis_end) {
            const y = rect.y + @as(u16, @intCast(ln - vis_start));
            var no_child: [80]u8 = [_]u8{' '} ** 80;
            const msg = "(no children)";
            const start = @min(child_indent, no_child.len);
            const end = @min(start + msg.len, no_child.len);
            @memcpy(no_child[start..end], msg);
            buf.setString(rx, y, no_child[0..@min(end, max_w)], lbl);
        }
        ln += 1;
    }

    return .{ .total_lines = ln, .self_line = self_ln };
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
