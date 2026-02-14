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

fn memPercentColor(pct: f32) _Color {
    if (pct > 50.0) return .red;
    if (pct > 25.0) return .yellow;
    return .green;
}

fn cpuTempColor(temp: f32) _Color {
    if (temp > 85.0) return .red;
    if (temp > 70.0) return .yellow;
    return .green;
}

/// Height-based gradient: green at bottom → yellow → red at top.
fn graphGradientColor(row: usize, height: usize) _Color {
    if (height <= 1) return .green;
    const pct = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(height - 1)) * 100.0;
    if (pct >= 67.0) return .red;
    if (pct >= 33.0) return .yellow;
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

// proc_inner_layout: [0]=header, [1]=list, [2]=footer
const proc_inner_layout = layout.Container.column(&[_]layout.Item{
    .{ .sizing = .{ .fixed = 1 } },
    .{ .sizing = .{ .grow = 1.0 } },
    .{ .sizing = .{ .fixed = 1 } },
});

// --- Box-drawing codepoints (light set, matches zigtui Block default) ---
const BD_HOR: u21 = 0x2500; // ─
const BD_VER: u21 = 0x2502; // │
const BD_TL: u21 = 0x250C; // ┌
const BD_TR: u21 = 0x2510; // ┐
const BD_BL: u21 = 0x2514; // └
const BD_BR: u21 = 0x2518; // ┘
const BD_LT: u21 = 0x251C; // ├
const BD_RT: u21 = 0x2524; // ┤
const BD_TT: u21 = 0x252C; // ┬
const BD_BT: u21 = 0x2534; // ┴
const BD_RTL: u21 = 0x256D; // ╭
const BD_RTR: u21 = 0x256E; // ╮
const BD_RBL: u21 = 0x2570; // ╰
const BD_RBR: u21 = 0x256F; // ╯

const border_style = _Style{ .fg = .cyan };
const pane_title_style = _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } };

// column_layout: [0]=pid, [1]=name, [2]=cpu, [3]=mem, [4]=nice, [5]=path
const column_layout = layout.Container.row(&[_]layout.Item{
    .{ .sizing = .{ .fixed = 8 } },
    .{ .sizing = .{ .grow = 1.0 } },
    .{ .sizing = .{ .fixed = 7 } },
    .{ .sizing = .{ .fixed = 10 } },
    .{ .sizing = .{ .fixed = 4 } },
    .{ .sizing = .{ .grow = 2.0 } },
});

// detail_page_layout: [0]=header, [1]=body, [2]=footer
const detail_page_layout = layout.Container.column(&[_]layout.Item{
    .{ .sizing = .{ .fixed = 4 } },
    .{ .sizing = .{ .grow = 1.0 } },
    .{ .sizing = .{ .fixed = 1 } },
});

// detail_body_layout: [0]=left, [1]=divider, [2]=right
const detail_body_layout = layout.Container.row(&[_]layout.Item{
    .{ .sizing = .{ .grow = 3.0 } },
    .{ .sizing = .{ .fixed = 1 } },
    .{ .sizing = .{ .grow = 2.0 } },
});

// detail_right_layout: [0]=stats, [1]=tree
const detail_right_layout = layout.Container.column(&[_]layout.Item{
    .{ .sizing = .{ .fixed = 7 } },
    .{ .sizing = .{ .grow = 1.0 } },
});

pub fn render(draw_ctx: state.DrawContext, buf: *tui.render.Buffer) !void {
    const app = draw_ctx.state;
    const area = buf.getArea();
    const w = area.width;
    const h = area.height;

    if (w < 20 or h < 10) return;

    // ── Manual unified layout ─────────────────────────────────────
    // One outer border for the entire dashboard. Internal dividers
    // separate panes with shared edges — no double borders anywhere.
    //
    // New layout (bpytop style):
    //   Top row: CPU (full width, cores via overlay)
    //   Left panel (3 rows): Memory+Disks | DiskIO | Network
    //   Right panel: Processes (full height)
    //
    // Divider budget: 3 horizontal dividers (hd1, hd2, hd3) in left panel
    // Y: top_content | hd1 | memory+disks | hd2 | diskio | hd3 | network

    const avail_h = h -| 4; // minus outer borders(2) + hd1(1) + hd2(1) - removed hd3
    const top_h: u16 = @max(avail_h / 3, 2);
    const bot_avail: u16 = avail_h -| top_h;

    // Left panel 2 rows: DiskIO (with Memory+Disks overlay), Network
    // Memory is now part of the Disk IO overlay
    const diskio_h: u16 = @max(bot_avail * 60 / 100, 5);
    const network_h: u16 = bot_avail -| diskio_h;

    const y_hd1 = area.y + 1 + top_h;
    const y_hd2 = y_hd1 + 1 + diskio_h;

    // X: top row: CPU spans full width (no Cores pane)
    const cpu_w: u16 = w -| 2; // minus outer borders only

    // X: bottom row: left_panel | vdB | processes
    const bot_iw = w -| 3;
    const left_w: u16 = bot_iw / 2;
    const proc_w: u16 = bot_iw -| left_w;
    const x_vdB = area.x + 1 + left_w;

    // ── Draw outer border ─────────────────────────────────────────
    const x0 = area.x;
    const x1 = area.x + w - 1;
    const y0 = area.y;
    const y1 = area.y + h - 1;

    buf.setChar(x0, y0, BD_RTL, border_style);
    buf.setChar(x1, y0, BD_RTR, border_style);
    buf.setChar(x0, y1, BD_RBL, border_style);
    buf.setChar(x1, y1, BD_RBR, border_style);

    {
        var x: u16 = x0 + 1;
        while (x < x1) : (x += 1) {
            buf.setChar(x, y0, BD_HOR, border_style);
            buf.setChar(x, y1, BD_HOR, border_style);
        }
    }
    {
        var y: u16 = y0 + 1;
        while (y < y1) : (y += 1) {
            buf.setChar(x0, y, BD_VER, border_style);
            buf.setChar(x1, y, BD_VER, border_style);
        }
    }

    // ── Horizontal divider 1 (full width, between top row and bottom) ──
    {
        buf.setChar(x0, y_hd1, BD_LT, border_style);
        buf.setChar(x1, y_hd1, BD_RT, border_style);
        var x: u16 = x0 + 1;
        while (x < x1) : (x += 1) buf.setChar(x, y_hd1, BD_HOR, border_style);
    }

    // ── Horizontal divider 2 (left panel only, between DiskIO and Network) ──
    {
        buf.setChar(x0, y_hd2, BD_LT, border_style);
        var x: u16 = x0 + 1;
        while (x < x_vdB) : (x += 1) buf.setChar(x, y_hd2, BD_HOR, border_style);
    }

    // ── Vertical dividers ─────────────────────────────────────────
    // vdB: between left panel and Processes (full bottom)
    {
        buf.setChar(x_vdB, y_hd1, BD_TT, border_style);
        var y: u16 = y_hd1 + 1;
        while (y < y1) : (y += 1) buf.setChar(x_vdB, y, BD_VER, border_style);
        buf.setChar(x_vdB, y1, BD_BT, border_style);
        // Junction where hd2 meets vdB
        buf.setChar(x_vdB, y_hd2, BD_RT, border_style);
    }

    // ── Titles on borders / dividers ──────────────────────────────
    // CPU/Mem selector title: "╮[1] CPU╭╮[2] Mem╭" with active highlighted
    {
        const title_x = x0 + 2;
        const active_style = _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } };
        const inactive_style = _Style{ .fg = .gray };
        const cpu_style = if (app.dashboard_graph_mode == .cpu) active_style else inactive_style;
        const mem_style = if (app.dashboard_graph_mode == .memory) active_style else inactive_style;

        // First island: [1] CPU
        buf.setChar(title_x, y0, BD_TR, border_style);
        buf.setString(title_x + 1, y0, "[1] CPU", cpu_style);
        buf.setChar(title_x + 8, y0, BD_TL, border_style);
        // Separator
        buf.setChar(title_x + 9, y0, BD_HOR, border_style);
        // Second island: [2] Mem
        buf.setChar(title_x + 10, y0, BD_TR, border_style);
        buf.setString(title_x + 11, y0, "[2] Mem", mem_style);
        buf.setChar(title_x + 18, y0, BD_TL, border_style);
    }
    // Disk IO title
    drawTitle(buf, x0 + 2, y_hd1, "Disk IO");
    drawTitle(buf, x_vdB + 2, y_hd1, "Processes");
    // Network title with keybinding indicators "[n]etwork" "[p]rotocol" and mode/IP
    {
        const title_x = x0 + 2;
        // First island: [n]etwork
        buf.setChar(title_x, y_hd2, BD_TR, border_style);
        buf.setString(title_x + 1, y_hd2, "[", _Style{ .fg = .gray });
        buf.setString(title_x + 2, y_hd2, "n", _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
        buf.setString(title_x + 3, y_hd2, "]etwork", _Style{ .fg = .gray });
        buf.setChar(title_x + 10, y_hd2, BD_TL, border_style);

        // Separator
        buf.setChar(title_x + 11, y_hd2, BD_HOR, border_style);

        // Second island: mode label
        const mode_str = app.network_display_mode.label();
        buf.setChar(title_x + 12, y_hd2, BD_TR, border_style);
        buf.setString(title_x + 13, y_hd2, mode_str, _Style{ .fg = .light_magenta });
        const mode_end = title_x + 13 + @as(u16, @intCast(mode_str.len));
        buf.setChar(mode_end, y_hd2, BD_TL, border_style);
        var cursor = mode_end;

        // Third island: [p]rotocol filter (shown in by_process and by_process_detail modes)
        if (app.network_display_mode != .by_interface) {
            // Separator
            buf.setChar(cursor + 1, y_hd2, BD_HOR, border_style);
            buf.setChar(cursor + 2, y_hd2, BD_TR, border_style);
            buf.setString(cursor + 3, y_hd2, "[", _Style{ .fg = .gray });
            buf.setString(cursor + 4, y_hd2, "p", _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
            buf.setString(cursor + 5, y_hd2, "]", _Style{ .fg = .gray });
            const proto_label = app.network_protocol_filter.label();
            buf.setString(cursor + 6, y_hd2, proto_label, _Style{ .fg = .light_green });
            cursor = cursor + 6 + @as(u16, @intCast(proto_label.len));
            buf.setChar(cursor, y_hd2, BD_TL, border_style);
        }

        // Fourth island: IP address
        if (app.system.ipv4_addr_len > 0) {
            // Separator
            buf.setChar(cursor + 1, y_hd2, BD_HOR, border_style);
            const ip_str = app.system.ipv4_addr[0..app.system.ipv4_addr_len];
            buf.setChar(cursor + 2, y_hd2, BD_TR, border_style);
            buf.setString(cursor + 3, y_hd2, ip_str, _Style{ .fg = .gray });
            buf.setChar(cursor + 3 + @as(u16, @intCast(app.system.ipv4_addr_len)), y_hd2, BD_TL, border_style);
        }
    }

    // ── Content rects (the usable interior of each pane) ──────────
    // CPU pane: split into graph area (left) and overlay area (right)
    // Overlay is 50% width, positioned bottom-right
    const cpu_full_rect = layout.Rect{ .x = x0 + 1, .y = y0 + 1, .width = cpu_w, .height = top_h };
    const overlay_w: u16 = cpu_w / 2;
    const cpu_graph_rect = layout.Rect{
        .x = x0 + 1,
        .y = y0 + 1,
        .width = cpu_w -| overlay_w, // Graph stops at overlay left edge
        .height = top_h,
    };

    // Disk IO pane: split into chart area (left) and overlay area (right)
    const disk_io_full_rect = layout.Rect{ .x = x0 + 1, .y = y_hd1 + 1, .width = left_w, .height = diskio_h };
    const disk_overlay_w: u16 = left_w / 2;
    const disk_io_chart_rect = layout.Rect{
        .x = x0 + 1,
        .y = y_hd1 + 1,
        .width = left_w -| disk_overlay_w, // Chart stops at overlay left edge
        .height = diskio_h,
    };

    const network_rect = layout.Rect{ .x = x0 + 1, .y = y_hd2 + 1, .width = left_w, .height = network_h };
    const proc_rect = layout.Rect{ .x = x_vdB + 1, .y = y_hd1 + 1, .width = proc_w, .height = y1 - y_hd1 - 1 };

    // ── Render content into each pane ─────────────────────────────
    renderDashboardGraph(buf, cpu_graph_rect, &app.system, app.dashboard_graph_mode);
    renderCpuOverlay(buf, cpu_full_rect, &app.system, app.cpu_overlay_mode, app.temp_unit);
    renderDiskIO(buf, disk_io_chart_rect, &app.system);
    renderStorageOverlay(buf, disk_io_full_rect, &app.system, app.storage_detail_mode, app.mount_filter); // Combined Memory + Mounts overlay
    renderNetworkCombined(buf, network_rect, app, app.network_display_mode, app.network_protocol_filter);

    // Processes pane: calculate sub-layout within the content rect
    const proc_rects = layout.calculate(proc_inner_layout, proc_rect);
    renderProcessPane(buf, app, proc_rects[0], proc_rects[1], proc_rects[2]);

    // ── Overlay modes ─────────────────────────────────────────────
    if (app.mode == .help) {
        renderHelpView(buf, area, app);
    }
    if (app.mode == .detail) {
        renderDetailView(buf, area, app);
    }
    if (app.active_toast) |*toast| {
        renderToast(buf, toast, area);
    }
    if (app.confirm_dialog) |*dialog| {
        renderConfirmDialog(buf, dialog, area);
    }
}

fn drawTitle(buf: *tui.render.Buffer, x: u16, y: u16, title: []const u8) void {
    buf.setChar(x, y, BD_TR, border_style);
    buf.setString(x + 1, y, title, pane_title_style);
    const title_len: u16 = @intCast(title.len);
    buf.setChar(x + 1 + title_len, y, BD_TL, border_style);
}

fn renderProcessPane(
    buf: *tui.render.Buffer,
    app: *state.AppState,
    header_rect: layout.Rect,
    list_rect: layout.Rect,
    footer_rect: layout.Rect,
) void {
    const col_rects = layout.calculate(column_layout, .{
        .x = list_rect.x,
        .y = list_rect.y,
        .width = list_rect.width,
        .height = 1,
    });

    const pid_col = col_rects[0];
    const name_col = col_rects[1];
    const cpu_col = col_rects[2];
    const mem_col = col_rects[3];
    const nice_col = col_rects[4];
    const path_col = col_rects[5];

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
    renderColumnHeader(buf, nice_col.x, header_rect.y, "NI", false, dir_suffix);
    renderColumnHeader(buf, path_col.x, header_rect.y, "Path", app.procs.sort_column == .path, dir_suffix);

    const alt_row_bg = _Color{ .rgb = .{ .r = 35, .g = 35, .b = 40 } };

    var y: u16 = list_rect.y;
    var idx: usize = app.scroll_offset;
    var guides: [32]bool = [_]bool{false} ** 32;
    const rows = app.procs.render_rows.items;
    while (idx < rows.len) : (idx += 1) {
        if (y >= list_rect.y + list_rect.height) break;

        const row = rows[idx];
        const is_highlighted = idx == app.selected_item;
        const is_alt = (idx % 2) == 1;

        // Check if this row is pinned/selected
        const hot = app.procs.hot.slice();
        const start_time = if (row.data_idx < hot.items(.start_time_ns).len)
            hot.items(.start_time_ns)[row.data_idx]
        else
            0;
        const is_pinned = app.isSelected(row.pid, start_time);

        const row_bg: _Color = if (is_highlighted) .blue else if (is_pinned) .{ .rgb = .{ .r = 50, .g = 40, .b = 60 } } else if (is_alt) alt_row_bg else .reset;

        const name_style: _Style = if (is_highlighted) .{ .bg = .blue, .fg = .white, .modifier = _Modifier{ .bold = true } } else if (is_pinned) .{ .bg = row_bg, .fg = .light_magenta, .modifier = _Modifier{ .bold = true } } else .{ .bg = if (is_alt) alt_row_bg else .reset, .fg = .light_cyan };
        const secondary_style: _Style = if (is_highlighted) .{ .bg = .blue, .fg = .light_cyan } else .{ .bg = row_bg, .fg = .gray, .modifier = _Modifier{ .dim = true } };
        const prefix_style: _Style = if (is_highlighted) .{ .bg = .blue, .fg = .light_cyan } else .{ .bg = row_bg, .fg = .gray };

        const cpu_fg = cpuColor(row.cpu_percent);
        const cpu_fg_sel: _Color = switch (cpu_fg) {
            .green => .light_green,
            .yellow => .light_yellow,
            .red => .light_red,
            else => .white,
        };
        const cpu_style: _Style = if (is_highlighted) .{ .bg = .blue, .fg = cpu_fg_sel, .modifier = _Modifier{ .bold = true } } else .{ .bg = row_bg, .fg = cpu_fg };

        const mem_fg = memColor(row.mem_rss);
        const mem_fg_sel: _Color = switch (mem_fg) {
            .green => .light_green,
            .yellow => .light_yellow,
            .red => .light_red,
            else => .white,
        };
        const mem_style: _Style = if (is_highlighted) .{ .bg = .blue, .fg = mem_fg_sel, .modifier = _Modifier{ .bold = true } } else .{ .bg = row_bg, .fg = mem_fg };

        // Fill entire row with background color
        if (is_highlighted or is_pinned or is_alt) {
            var fill_x: u16 = list_rect.x;
            while (fill_x < list_rect.x + list_rect.width) : (fill_x += 1) {
                buf.setChar(fill_x, y, ' ', _Style{ .bg = row_bg });
            }
        }

        // Show pin indicator for selected/pinned rows
        if (is_pinned) {
            const pin_style = _Style{ .fg = .light_magenta, .bg = row_bg, .modifier = _Modifier{ .bold = true } };
            buf.setChar(pid_col.x, y, 0x25CF, pin_style); // ● filled circle
        }

        var pid_buf: [8]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d:<7}", .{row.pid}) catch "err";
        const pid_x: u16 = if (is_pinned) pid_col.x + 2 else pid_col.x;
        var cpu_buf: [7]u8 = undefined;
        const cpu_str = std.fmt.bufPrint(&cpu_buf, "{d:>5.1}%", .{row.cpu_percent}) catch "err";

        var mem_buf: [10]u8 = undefined;
        const mem_mb = @as(f64, @floatFromInt(row.mem_rss)) / (1024.0 * 1024.0);
        const mem_str = std.fmt.bufPrint(&mem_buf, "{d:>6.1} MB", .{mem_mb}) catch "err";

        const prefix_width = renderTreePrefix(buf, name_col.x, y, row, prefix_style, name_col.width, guides[0..@min(row.depth, 32)]);
        const name_x = name_col.x + prefix_width;
        const name_width: u16 = name_col.width -| prefix_width;

        const name_display = row.name[0..@min(row.name.len, @as(usize, @intCast(name_width)))];
        const path_display = row.path[0..@min(row.path.len, path_col.width)];

        buf.setString(pid_x, y, pid_str, secondary_style);
        if (name_width > 0) {
            buf.setString(name_x, y, name_display, name_style);
        }

        buf.setString(cpu_col.x, y, cpu_str, cpu_style);
        buf.setString(mem_col.x, y, mem_str, mem_style);

        // Nice value - color based on priority (negative = higher priority)
        var nice_buf: [4]u8 = undefined;
        const nice_str = std.fmt.bufPrint(&nice_buf, "{d:>3}", .{row.nice}) catch "err";
        const nice_fg: _Color = if (row.nice < 0) .light_red else if (row.nice > 0) .light_green else .gray;
        const nice_style: _Style = if (is_highlighted) .{ .bg = .blue, .fg = nice_fg } else .{ .bg = row_bg, .fg = nice_fg };
        buf.setString(nice_col.x, y, nice_str, nice_style);

        buf.setString(path_col.x, y, path_display, secondary_style);

        // Update guide state for subsequent rows
        if (row.depth > 0 and row.depth - 1 < 32) {
            guides[row.depth - 1] = !row.is_last;
        }

        y += 1;
    }

    // Track visible processes for preloading XPC/TCP data
    const first_visible = app.scroll_offset;
    const last_visible = if (rows.len > 0) @min(app.scroll_offset + visible_rows, rows.len) - 1 else 0;
    app.updateVisiblePids(rows, first_visible, last_visible);

    if (app.mode == .search_edit) {
        renderSearchInput(buf, footer_rect, app);
    } else {
        renderStatusBar(buf, footer_rect, app);
    }
}

// Braille paired-column lookup table (5x5: left_level * 5 + right_level).
// Each entry is the braille codepoint offset from U+2800 for area-fill
// with the given left (0-4) and right (0-4) dot levels.
const braille_up = blk: {
    // Left column dot bits per level (bottom-up fill):
    const left_bits = [5]u21{ 0x00, 0x40, 0x44, 0x46, 0x47 };
    // Right column dot bits per level (bottom-up fill):
    const right_bits = [5]u21{ 0x00, 0x80, 0xA0, 0xB0, 0xB8 };
    var table: [25]u21 = undefined;
    for (0..5) |l| {
        for (0..5) |r| {
            table[l * 5 + r] = 0x2800 + left_bits[l] | right_bits[r];
        }
    }
    break :blk table;
};

// Braille top-down fill table for inverted/mirrored charts (upload half).
// Dots fill from top to bottom: level 1 = top dot, level 4 = all 4.
const braille_down = blk: {
    // Left column dot bits per level (top-down fill):
    // dot positions top-to-bottom: bit0=0x01, bit1=0x02, bit2=0x04, bit6=0x40
    const left_bits = [5]u21{ 0x00, 0x01, 0x03, 0x07, 0x47 };
    // Right column dot bits per level (top-down fill):
    // dot positions top-to-bottom: bit3=0x08, bit4=0x10, bit5=0x20, bit7=0x80
    const right_bits = [5]u21{ 0x00, 0x08, 0x18, 0x38, 0xB8 };
    var table: [25]u21 = undefined;
    for (0..5) |l| {
        for (0..5) |r| {
            table[l * 5 + r] = 0x2800 + left_bits[l] | right_bits[r];
        }
    }
    break :blk table;
};

/// Quantize a value into 0-4 levels within a band [low, high].
fn quantize(value: f32, low: f32, high: f32) u3 {
    if (value <= low) return 0;
    if (value >= high) return 4;
    const range = high - low;
    if (range <= 0) return 0;
    const ratio = (value - low) / range;
    // 5 levels: 0,1,2,3,4 mapped from [0..1]
    const level: u3 = @intFromFloat(@min(ratio * 4.0, 4.0));
    return level;
}

/// Round up max(raw_max * 1.2, floor) to the next power of 2.
fn autoScaleCeiling(raw_max: f64, floor: f64) f64 {
    const padded = @max(raw_max * 1.2, floor);
    if (padded <= 0) return floor;
    // Next power of 2: 2^ceil(log2(padded))
    const log2_val = std.math.log2(padded);
    const ceil_log2 = @ceil(log2_val);
    return std.math.pow(f64, 2.0, ceil_log2);
}

/// Multi-row braille area chart from a CpuHistory (values 0-100, f32).
/// Per-column coloring via cpuColor + noise floor. Used for per-core charts.
/// A baseline dotted line (⡀) is drawn across the entire width first,
/// then actual data is drawn on top so idle cores show a visible track.
fn renderCoreBrailleBlock(buf: *tui.render.Buffer, rect: layout.Rect, history: *const model.CpuHistory) void {
    if (rect.width == 0 or rect.height == 0) return;
    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const sample_count = history.count;
    const capacity = width * 2;
    const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
    const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

    // Pass 1: Draw baseline across the ENTIRE chart width (bottom row).
    // This creates the visible "track" even where there's no data or zero load.
    const BASELINE_CP: u21 = 0x2840; // ⡀ bottom-left dot
    const bottom_screen_y = rect.y + @as(u16, @intCast(height - 1));
    {
        var base_utf8: [4]u8 = undefined;
        const base_len = std.unicode.utf8Encode(BASELINE_CP, &base_utf8) catch 0;
        if (base_len > 0) {
            var bx: usize = 0;
            while (bx < width) : (bx += 1) {
                buf.setString(
                    rect.x + @as(u16, @intCast(bx)),
                    bottom_screen_y,
                    base_utf8[0..base_len],
                    _Style{ .fg = .gray },
                );
            }
        }
    }

    // Pass 2: Draw actual data on top of baseline. Data columns overwrite
    // the baseline where there's CPU activity.
    var col: usize = 0;
    while (col < width) : (col += 1) {
        if (col < width - filled_cols) continue;
        const data_col = col - (width - filled_cols);
        const pair_base = start_sample + data_col * 2;

        const left_val = if (pair_base < sample_count) history.get(pair_base) else 0;
        const right_val = if (pair_base + 1 < sample_count) history.get(pair_base + 1) else left_val;

        // Noise floor: clamp near-idle values to 0
        const left_clamped: f32 = if (left_val < 3.0) 0 else @min(left_val, 100.0);
        const right_clamped: f32 = if (right_val < 3.0) 0 else @min(right_val, 100.0);

        // Skip columns where both values are zero — baseline already covers them
        if (left_clamped == 0 and right_clamped == 0) continue;

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row; // row 0 = bottom
            const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
            const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

            const left_level = quantize(left_clamped, band_low, band_high);
            const right_level = quantize(right_clamped, band_low, band_high);
            const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];
            if (braille_cp == 0x2800) continue;

            // Per-row gradient: green at bottom, yellow in middle, red at top
            // Use band_high with thresholds that ensure all 3 colors appear with 2+ rows
            const row_color: _Color = if (band_high > 75.0) .red else if (band_high > 37.5) .yellow else .green;

            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(braille_cp, &utf8_buf) catch continue;
            buf.setString(
                rect.x + @as(u16, @intCast(col)),
                rect.y + @as(u16, @intCast(screen_row)),
                utf8_buf[0..utf8_len],
                _Style{ .fg = row_color },
            );
        }
    }
}

/// Braille area chart from a CpuHistory (values 0-100) with a fixed scale.
/// Each braille dot level = 10%, so each character row = 40%.
/// The chart height determines the max displayable value (height * 40%).
fn renderMemBrailleChart(buf: *tui.render.Buffer, rect: layout.Rect, history: *const model.CpuHistory, color: _Color) void {
    if (rect.width == 0 or rect.height == 0) return;
    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const sample_count = history.count;
    const capacity = width * 2;
    const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
    const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

    // Fixed scale: 10% per dot level, 40% per row
    const pct_per_row: f32 = 40.0;

    var col: usize = 0;
    while (col < width) : (col += 1) {
        if (col < width - filled_cols) continue;
        const data_col = col - (width - filled_cols);
        const pair_base = start_sample + data_col * 2;

        const left_val: f32 = if (pair_base < sample_count) @min(history.get(pair_base), 100.0) else 0;
        const right_val: f32 = if (pair_base + 1 < sample_count) @min(history.get(pair_base + 1), 100.0) else left_val;

        if (left_val == 0 and right_val == 0) continue;

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row;
            const band_low: f32 = @as(f32, @floatFromInt(row)) * pct_per_row;
            const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * pct_per_row;

            var left_level = quantize(left_val, band_low, band_high);
            var right_level = quantize(right_val, band_low, band_high);
            // Ensure non-zero values always produce at least 1 dot in bottom band
            if (row == 0) {
                if (left_val > 0 and left_level == 0) left_level = 1;
                if (right_val > 0 and right_level == 0) right_level = 1;
            }

            const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];
            if (braille_cp == 0x2800) continue;

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
}

/// Braille sparkline chart - single row, 2 samples per character, consistent with other braille charts.
/// Uses braille dot patterns to show vertical bars (4 levels per column).
/// Each character is colored based on the max value of its two samples.
fn renderSparkline(buf: *tui.render.Buffer, x: u16, y: u16, width: u16, history: *const model.CpuHistory) void {
    if (width == 0) return;

    // Build braille character from dot bits
    // Braille dots are numbered 1-8:
    //   1 4
    //   2 5
    //   3 6
    //   7 8
    // For vertical bars from bottom up:
    // Left column (bottom to top): 7, 3, 2, 1
    // Right column (bottom to top): 8, 6, 5, 4

    const w: usize = @intCast(width);
    const sample_count = history.count;

    // 2 samples per braille character
    const capacity = w * 2;
    const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;
    const filled_chars: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, w) else if (sample_count == 1) 1 else 0;

    var col: usize = 0;
    while (col < w) : (col += 1) {
        const screen_x = x + @as(u16, @intCast(col));

        // Before data starts, draw baseline (single bottom dot)
        if (col < w - filled_chars) {
            buf.setString(screen_x, y, "⡀", _Style{ .fg = .gray });
            continue;
        }

        const data_col = col - (w - filled_chars);
        const pair_base = start_sample + data_col * 2;

        const left_val: f32 = if (pair_base < sample_count) @min(history.get(pair_base), 100.0) else 0;
        const right_val: f32 = if (pair_base + 1 < sample_count) @min(history.get(pair_base + 1), 100.0) else left_val;

        // Convert 0-100% to 0-4 level (4 dots per column)
        var left_level: u8 = @intFromFloat(@min(left_val / 25.0, 4.0));
        var right_level: u8 = @intFromFloat(@min(right_val / 25.0, 4.0));

        // Ensure non-zero values show at least 1 dot
        if (left_val > 0 and left_level == 0) left_level = 1;
        if (right_val > 0 and right_level == 0) right_level = 1;

        // Build braille codepoint from dots
        // Left column bits: dot7=0x40, dot3=0x04, dot2=0x02, dot1=0x01
        // Right column bits: dot8=0x80, dot6=0x20, dot5=0x10, dot4=0x08
        var cp: u21 = 0x2800; // braille base

        // Left column (bottom to top: 7, 3, 2, 1)
        if (left_level >= 1) cp |= 0x40; // dot 7
        if (left_level >= 2) cp |= 0x04; // dot 3
        if (left_level >= 3) cp |= 0x02; // dot 2
        if (left_level >= 4) cp |= 0x01; // dot 1

        // Right column (bottom to top: 8, 6, 5, 4)
        if (right_level >= 1) cp |= 0x80; // dot 8
        if (right_level >= 2) cp |= 0x20; // dot 6
        if (right_level >= 3) cp |= 0x10; // dot 5
        if (right_level >= 4) cp |= 0x08; // dot 4

        // Color based on max value
        const max_val = @max(left_val, right_val);
        const color = cpuColor(max_val);

        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
        buf.setString(screen_x, y, utf8_buf[0..utf8_len], _Style{ .fg = color });
    }
}

/// Multi-row braille area chart from a RateHistory with auto-scaling.
/// Uses height-based gradient coloring (green→yellow→red from bottom to top).
fn renderRateBrailleChart(buf: *tui.render.Buffer, rect: layout.Rect, history: *const model.RateHistory, color: _Color) void {
    _ = color; // gradient replaces flat color
    if (rect.width == 0 or rect.height == 0) return;
    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const sample_count = history.count;
    const capacity = width * 2;

    // Extract samples into a normalized [0..100] buffer
    const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
    const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

    // Find max in visible window for auto-scaling
    const visible_samples = @min(sample_count, capacity);
    const raw_max = if (visible_samples > 0) history.maxInWindow(visible_samples) else 0;
    const ceiling = autoScaleCeiling(raw_max, 1024.0); // floor = 1 KB/s

    var col: usize = 0;
    while (col < width) : (col += 1) {
        if (col < width - filled_cols) continue;
        const data_col = col - (width - filled_cols);
        const pair_base = start_sample + data_col * 2;

        const left_raw: f64 = if (pair_base < sample_count) history.get(pair_base) else 0;
        const right_raw: f64 = if (pair_base + 1 < sample_count) history.get(pair_base + 1) else left_raw;

        // Normalize to 0-100 range
        const left_val: f32 = if (ceiling > 0) @floatCast(@min(left_raw / ceiling * 100.0, 100.0)) else 0;
        const right_val: f32 = if (ceiling > 0) @floatCast(@min(right_raw / ceiling * 100.0, 100.0)) else 0;

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row;
            const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
            const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

            const left_level = quantize(left_val, band_low, band_high);
            const right_level = quantize(right_val, band_low, band_high);
            const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];
            if (braille_cp == 0x2800) continue;

            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(braille_cp, &utf8_buf) catch continue;
            buf.setString(
                rect.x + @as(u16, @intCast(col)),
                rect.y + @as(u16, @intCast(screen_row)),
                utf8_buf[0..utf8_len],
                _Style{ .fg = graphGradientColor(row, height) },
            );
        }
    }

}

/// Single-row braille chart from a SocketHistory (u32 counts) with fixed color.
/// Auto-scales based on max value in the history.
fn renderSocketBrailleChart(buf: *tui.render.Buffer, rect: layout.Rect, history: *const model.SocketHistory, color: _Color) void {
    if (rect.width == 0 or rect.height == 0) return;
    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const sample_count = history.count;
    const capacity = width * 2;

    const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
    const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

    // Auto-scale based on max in history (minimum 10 for visibility)
    const raw_max = history.max();
    const ceiling: f32 = @floatFromInt(@max(raw_max, 10));

    var col: usize = 0;
    while (col < width) : (col += 1) {
        if (col < width - filled_cols) continue;
        const data_col = col - (width - filled_cols);
        const pair_base = start_sample + data_col * 2;

        const left_raw: u32 = if (pair_base < sample_count) history.get(pair_base) else 0;
        const right_raw: u32 = if (pair_base + 1 < sample_count) history.get(pair_base + 1) else left_raw;

        // Normalize to 0-100 range
        const left_val: f32 = @as(f32, @floatFromInt(left_raw)) / ceiling * 100.0;
        const right_val: f32 = @as(f32, @floatFromInt(right_raw)) / ceiling * 100.0;

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row;
            const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
            const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

            const left_level = quantize(left_val, band_low, band_high);
            const right_level = quantize(right_val, band_low, band_high);
            const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];
            if (braille_cp == 0x2800) continue;

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
}

fn renderDashboardGraph(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState, mode: state.DashboardGraphMode) void {
    if (!sys.has_data or rect.width == 0 or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    // Render the chart using full rect (label is in the border title)
    const history = if (mode == .cpu) &sys.cpu_history else &sys.mem_history;
    const color: _Color = if (mode == .cpu) .green else .cyan;
    renderBrailleAreaChart(buf, rect, history, color);
}

fn renderBrailleAreaChart(buf: *tui.render.Buffer, rect: layout.Rect, history: *const model.CpuHistory, base_color: _Color) void {
    if (rect.width == 0 or rect.height == 0) return;

    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const sample_count = history.count;

    const capacity = width * 2;
    const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
    const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

    _ = base_color; // Use gradient coloring instead

    var col: usize = 0;
    while (col < width) : (col += 1) {
        if (col < width - filled_cols) continue;

        const data_col = col - (width - filled_cols);
        const pair_base = start_sample + data_col * 2;

        const left_val = if (pair_base < sample_count) history.get(pair_base) else 0;
        const right_val = if (pair_base + 1 < sample_count) history.get(pair_base + 1) else left_val;

        const left_clamped = @min(left_val, 100.0);
        const right_clamped = @min(right_val, 100.0);

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row;
            const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
            const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

            const left_level = quantize(left_clamped, band_low, band_high);
            const right_level = quantize(right_clamped, band_low, band_high);

            const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];

            if (braille_cp == 0x2800) continue;

            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(braille_cp, &utf8_buf) catch continue;

            const color = graphGradientColor(row, height);
            buf.setString(
                rect.x + @as(u16, @intCast(col)),
                rect.y + @as(u16, @intCast(screen_row)),
                utf8_buf[0..utf8_len],
                _Style{ .fg = color },
            );
        }
    }
}

fn renderCpuGraphBraille(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.width == 0 or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height); // Full height (uptime moved to overlay)
    const history = &sys.cpu_history;
    const sample_count = history.count;

    // Each character column encodes 2 consecutive samples (left=prev, right=current).
    // Effective capacity: width * 2 samples across the graph.
    const capacity = width * 2;

    // How many character columns we actually fill
    const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;

    // Starting sample index (right-aligned: newest samples at right edge)
    const start_sample: usize = if (sample_count > capacity)
        sample_count - capacity
    else
        0;

    var col: usize = 0;
    while (col < width) : (col += 1) {
        // Right-align: empty columns on the left when insufficient data
        if (col < width - filled_cols) continue;

        // Which pair of samples does this column represent?
        const data_col = col - (width - filled_cols);
        const pair_base = start_sample + data_col * 2;

        // Get the two samples for this column (left = earlier, right = later)
        const left_val = if (pair_base < sample_count) history.get(pair_base) else 0;
        const right_val = if (pair_base + 1 < sample_count) history.get(pair_base + 1) else left_val;

        const left_clamped = @min(left_val, 100.0);
        const right_clamped = @min(right_val, 100.0);

        // For each character row, compute the band and quantize both samples
        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row; // row 0 = bottom
            const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
            const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

            const left_level = quantize(left_clamped, band_low, band_high);
            const right_level = quantize(right_clamped, band_low, band_high);

            const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];

            // Skip empty characters (no dots lit)
            if (braille_cp == 0x2800) continue;

            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(braille_cp, &utf8_buf) catch continue;
            buf.setString(
                rect.x + @as(u16, @intCast(col)),
                rect.y + @as(u16, @intCast(screen_row)),
                utf8_buf[0..utf8_len],
                _Style{ .fg = graphGradientColor(row, height) },
            );
        }
    }

    // Total CPU percentage overlay in bottom-left (moved from top-right to avoid overlay collision)
    {
        var pct_buf: [7]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>5.1}%", .{sys.total_cpu_percent}) catch "???%";
        buf.setString(rect.x, rect.y + rect.height -| 1, pct_str, _Style{ .fg = cpuColor(sys.total_cpu_percent), .modifier = _Modifier{ .bold = true } });
    }
}

/// Floating overlay box showing CPU cores and stats (bpytop style)
/// Positioned bottom-right of CPU pane, 50% width, full height
/// Cores fill the space with multi-row braille graphs, stats anchored to bottom
fn renderCpuOverlay(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState, mode: state.CpuOverlayMode, temp_unit: state.TempUnit) void {
    _ = mode; // We now show everything at once, no toggle needed

    if (!sys.has_data) return;

    // Adaptive: skip overlay if pane too small
    if (rect.width < 50 or rect.height < 6) return;

    const core_count: u16 = @intCast(@min(sys.core_count, model.MAX_CORES));

    // Box dimensions: 50% width, full height (floats to bottom)
    const box_w: u16 = rect.width / 2;
    const box_h: u16 = rect.height; // Use full height

    // Position: BOTTOM-right corner of CPU pane
    const box_x = rect.x + rect.width -| box_w;
    const box_y = rect.y + rect.height -| box_h; // Anchored to bottom

    // Draw box border (dim style, like network overlay)
    const dim_border = _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } };

    // Corners
    buf.setChar(box_x, box_y, BD_RTL, dim_border); // ╭
    buf.setChar(box_x + box_w - 1, box_y, BD_RTR, dim_border); // ╮
    buf.setChar(box_x, box_y + box_h - 1, BD_RBL, dim_border); // ╰
    buf.setChar(box_x + box_w - 1, box_y + box_h - 1, BD_RBR, dim_border); // ╯

    // Top edge with CPU brand (left) and freq (right, gray like IP)
    buf.setChar(box_x + 1, box_y, BD_HOR, dim_border);

    // Build right-side info: frequency only (temp moved to stats)
    var right_buf: [16]u8 = undefined;
    var right_len: u16 = 0;
    const has_freq = sys.cpu_freq_mhz > 0;

    if (has_freq) {
        const freq_ghz = @as(f32, @floatFromInt(sys.cpu_freq_mhz)) / 1000.0;
        const slice = std.fmt.bufPrint(&right_buf, "{d:.1} GHz", .{freq_ghz}) catch "";
        right_len = @intCast(slice.len);
    }

    // CPU brand name (truncated to fit, leaving room for freq)
    const brand_slice = sys.cpu_brand[0..sys.cpu_brand_len];
    const reserved_right: u16 = if (right_len > 0) right_len + 4 else 2;
    const max_brand_w = box_w -| reserved_right;
    const brand_display = brand_slice[0..@min(brand_slice.len, max_brand_w)];
    buf.setString(box_x + 2, box_y, brand_display, _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
    const brand_end: u16 = box_x + 2 + @as(u16, @intCast(brand_display.len));

    // Frequency on right (gray, like IP address label)
    if (right_len > 0) {
        const right_x = box_x + box_w - 2 - right_len;
        buf.setString(right_x, box_y, right_buf[0..right_len], _Style{ .fg = .gray });
    }

    // Fill horizontal line between brand and freq
    {
        const fill_end = if (right_len > 0) box_x + box_w - 3 - right_len else box_x + box_w - 1;
        var x: u16 = brand_end;
        while (x < fill_end) : (x += 1) {
            buf.setChar(x, box_y, BD_HOR, dim_border);
        }
    }

    // Helper to format temperature with unit
    const formatTemp = struct {
        fn f(temp: f32, unit: state.TempUnit, out_buf: []u8) []const u8 {
            if (unit == .fahrenheit) {
                const temp_f = temp * 9.0 / 5.0 + 32.0;
                return std.fmt.bufPrint(out_buf, "{d:.0}F", .{temp_f}) catch "";
            } else {
                return std.fmt.bufPrint(out_buf, "{d:.0}C", .{temp}) catch "";
            }
        }
    }.f;

    // Bottom edge
    {
        var x: u16 = box_x + 1;
        while (x < box_x + box_w - 1) : (x += 1) {
            buf.setChar(x, box_y + box_h - 1, BD_HOR, dim_border);
        }
    }

    // Side edges
    {
        var y: u16 = box_y + 1;
        while (y < box_y + box_h - 1) : (y += 1) {
            buf.setChar(box_x, y, BD_VER, dim_border);
            buf.setChar(box_x + box_w - 1, y, BD_VER, dim_border);
        }
    }

    // Clear interior
    {
        var y: u16 = box_y + 1;
        while (y < box_y + box_h - 1) : (y += 1) {
            var x: u16 = box_x + 1;
            while (x < box_x + box_w - 1) : (x += 1) {
                buf.setChar(x, y, ' ', _Style{});
            }
        }
    }

    // Content area dimensions
    const content_x = box_x + 2;
    const content_y = box_y + 1;
    const inner_w = box_w -| 4; // 2 padding on each side
    const inner_h = box_h -| 2; // borders

    // Reserve bottom rows for stats (anchored to bottom)
    // Row 1: CPU/User/Sys + [t]emp header
    // Row 2: Load/Uptime + temp values
    // Row 3 (if needed): temp overflow
    const stats_rows: u16 = 3;
    const cores_area_h = if (inner_h > stats_rows + 1) inner_h -| stats_rows -| 1 else inner_h / 2;

    // Dynamic column layout based on available space
    // Minimum width per column: label(3) + chart(6 min) + pct(5) + gap(1) = 15
    const min_col_w: u16 = 15;
    const col_gap: u16 = 1;

    // Determine number of columns needed to fit all cores
    // Prefer fewer columns (bigger charts) when possible
    const num_cols: u16 = blk: {
        // Can all cores fit in 1 column?
        if (core_count <= cores_area_h) break :blk 1;
        // Can all cores fit in 2 columns?
        if (core_count <= cores_area_h * 2 and inner_w >= min_col_w * 2 + col_gap) break :blk 2;
        // Use 3 columns for many cores on small screens
        if (inner_w >= min_col_w * 3 + col_gap * 2) break :blk 3;
        // Fall back to 2 columns if width allows
        if (inner_w >= min_col_w * 2 + col_gap) break :blk 2;
        // Default to 1 column
        break :blk 1;
    };

    // Calculate column width (distribute evenly)
    const total_gap_w = if (num_cols > 1) (num_cols - 1) * col_gap else 0;
    const col_w: u16 = (inner_w -| total_gap_w) / num_cols;

    // Core layout within each column: label(3) + sparkline(expanding) + pct(5)
    // Sparklines use 1 row per core for maximum horizontal detail
    const label_w: u16 = 3; // "XX "
    const pct_w: u16 = 5; // " NNN%"
    const chart_w: u16 = if (col_w > label_w + pct_w) col_w -| label_w -| pct_w else 0;

    // With sparklines, each core gets exactly 1 row
    const cores_per_col: u16 = (core_count + num_cols - 1) / num_cols;

    // Render cores in columns using sparklines
    var col: u16 = 0;
    while (col < num_cols) : (col += 1) {
        const col_x = content_x + col * (col_w + col_gap);

        var row: u16 = 0;
        while (row < cores_per_col) : (row += 1) {
            const core_idx = col * cores_per_col + row;
            if (core_idx >= core_count) break;

            const y_row = content_y + row;
            if (y_row >= content_y + cores_area_h) break;

            const pct = sys.core_percents[core_idx];

            // Core number label
            var label_buf: [4]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d:>2} ", .{core_idx}) catch "?? ";
            buf.setString(col_x, y_row, label, _Style{ .fg = .gray });

            // Sparkline chart (single row, full width, colored per-value)
            if (chart_w > 0) {
                renderSparkline(buf, col_x + label_w, y_row, chart_w, &sys.core_histories[core_idx]);
            }

            // Percentage (after sparkline)
            var pct_buf: [6]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch "???%";
            buf.setString(col_x + label_w + chart_w, y_row, pct_str, _Style{ .fg = cpuColor(pct) });
        }
    }

    // Stats section - ANCHORED TO BOTTOM of popout
    const stats_y = content_y + inner_h -| stats_rows;

    // Temp labels: first 4 have names, rest are numbered
    const named_labels = [_][]const u8{ "Pkg:", "C0:", "C1:", "E:" };
    const total_temps = sys.cpu_cluster_temp_count;

    // Left column content widths (CPU stats ~36 chars, Load/Up ~34 chars)
    const left_col_w: u16 = 38;
    const temp_col_x: u16 = content_x + left_col_w;
    const temp_col_w: u16 = if (inner_w > left_col_w) inner_w - left_col_w else 0;

    // Calculate if temps fit on one row (~7 chars per temp)
    const chars_per_temp: u16 = 7;
    const total_temp_chars = @as(u16, @intCast(total_temps)) * chars_per_temp;
    const use_two_temp_rows = total_temp_chars > temp_col_w and total_temps > 1;
    const temps_row1_count = if (use_two_temp_rows) (total_temps + 1) / 2 else total_temps;

    const dim_line_style = _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } };
    const DASH: u21 = 0x2500; // ─

    // Line 1: Separator with "Load" label (left) + [t]emp header (right)
    {
        // Left side: "Load" label with dashes
        buf.setString(content_x, stats_y, "Load", _Style{ .fg = .gray });
        var dx: u16 = content_x + 5;
        while (dx < temp_col_x -| 1) : (dx += 1) {
            buf.setChar(dx, stats_y, DASH, dim_line_style);
        }

        // Right side: [t]emp header label with dashes
        if (total_temps > 0 and temp_col_w > 0) {
            buf.setString(temp_col_x, stats_y, "[", _Style{ .fg = .gray });
            buf.setString(temp_col_x + 1, stats_y, "t", _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
            buf.setString(temp_col_x + 2, stats_y, "]emp", _Style{ .fg = .gray });

            dx = temp_col_x + 6;
            while (dx < content_x + inner_w) : (dx += 1) {
                buf.setChar(dx, stats_y, DASH, dim_line_style);
            }
        }
    }

    // Line 2: CPU/User/Sys values (left) + temp values row 1 (right)
    if (stats_y + 1 < content_y + inner_h) {
        // Draw each value with its own color
        var x_pos: u16 = content_x;
        const label_style = _Style{ .fg = .gray };

        // CPU label and value
        buf.setString(x_pos, stats_y + 1, "CPU ", label_style);
        x_pos += 4;
        var cpu_val_buf: [8]u8 = undefined;
        const cpu_val = std.fmt.bufPrint(&cpu_val_buf, "{d:>5.1}%", .{sys.total_cpu_percent}) catch "???%";
        buf.setString(x_pos, stats_y + 1, cpu_val, _Style{ .fg = cpuColor(sys.total_cpu_percent) });
        x_pos += @intCast(cpu_val.len);

        // User label and value
        buf.setString(x_pos, stats_y + 1, "  User ", label_style);
        x_pos += 7;
        var user_val_buf: [8]u8 = undefined;
        const user_val = std.fmt.bufPrint(&user_val_buf, "{d:>5.1}%", .{sys.total_user_percent}) catch "???%";
        buf.setString(x_pos, stats_y + 1, user_val, _Style{ .fg = cpuColor(sys.total_user_percent) });
        x_pos += @intCast(user_val.len);

        // Sys label and value
        buf.setString(x_pos, stats_y + 1, "  Sys ", label_style);
        var sys_val_buf: [8]u8 = undefined;
        const sys_val = std.fmt.bufPrint(&sys_val_buf, "{d:>5.1}%", .{sys.total_system_percent}) catch "???%";
        buf.setString(x_pos + 6, stats_y + 1, sys_val, _Style{ .fg = cpuColor(sys.total_system_percent) });

        // Right side: temp values (first row or all if single row)
        if (total_temps > 0 and temp_col_w > 0) {
            var temp_x: u16 = temp_col_x;

            for (0..temps_row1_count) |i| {
                const cluster_temp = sys.cpu_cluster_temps[i];
                if (cluster_temp > 0 and temp_x < content_x + inner_w - 5) {
                    var label_buf: [4]u8 = undefined;
                    const label = if (i < named_labels.len)
                        named_labels[i]
                    else
                        std.fmt.bufPrint(&label_buf, "T{d}:", .{i}) catch "T?:";

                    buf.setString(temp_x, stats_y + 1, label, _Style{ .fg = .gray });
                    temp_x += @as(u16, @intCast(label.len));

                    var single_temp: [8]u8 = undefined;
                    const t_str = formatTemp(cluster_temp, temp_unit, &single_temp);
                    buf.setString(temp_x, stats_y + 1, t_str, _Style{ .fg = cpuTempColor(cluster_temp) });
                    temp_x += @as(u16, @intCast(t_str.len)) + 1;
                }
            }
        }
    }

    // Line 3: Load/Uptime (left) + temp values row 2 if needed (right)
    if (stats_y + 2 < content_y + inner_h) {
        // Left side: Load averages + Uptime (no "Load:" prefix since header says "Load")
        var load_buf: [24]u8 = undefined;
        const load_str = std.fmt.bufPrint(&load_buf, "{d:.2}  {d:.2}  {d:.2}", .{
            sys.load_avg[0], sys.load_avg[1], sys.load_avg[2],
        }) catch "???";
        buf.setString(content_x, stats_y + 2, load_str, _Style{ .fg = .gray });

        const up_s = sys.uptime_seconds;
        const days = up_s / 86400;
        const hours = (up_s % 86400) / 3600;
        const minutes = (up_s % 3600) / 60;

        var up_buf: [16]u8 = undefined;
        const up_str = if (days > 0)
            std.fmt.bufPrint(&up_buf, "  Up: {d}d {d}h", .{ days, hours }) catch "  Up: ???"
        else
            std.fmt.bufPrint(&up_buf, "  Up: {d}h {d}m", .{ hours, minutes }) catch "  Up: ???";

        const load_len: u16 = @intCast(load_str.len);
        buf.setString(content_x + load_len, stats_y + 2, up_str, _Style{ .fg = .gray });

        // Right side: temp values row 2 (if needed)
        if (use_two_temp_rows and total_temps > temps_row1_count and temp_col_w > 0) {
            var temp_x: u16 = temp_col_x;

            for (temps_row1_count..total_temps) |i| {
                const cluster_temp = sys.cpu_cluster_temps[i];
                if (cluster_temp > 0 and temp_x < content_x + inner_w - 5) {
                    var label_buf: [4]u8 = undefined;
                    const label = if (i < named_labels.len)
                        named_labels[i]
                    else
                        std.fmt.bufPrint(&label_buf, "T{d}:", .{i}) catch "T?:";

                    buf.setString(temp_x, stats_y + 2, label, _Style{ .fg = .gray });
                    temp_x += @as(u16, @intCast(label.len));

                    var single_temp: [8]u8 = undefined;
                    const t_str = formatTemp(cluster_temp, temp_unit, &single_temp);
                    buf.setString(temp_x, stats_y + 2, t_str, _Style{ .fg = cpuTempColor(cluster_temp) });
                    temp_x += @as(u16, @intCast(t_str.len)) + 1;
                }
            }
        }
    }
}

fn renderDiskIO(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    const recv_glyph = "\xe2\x96\xbc"; // U+25BC ▼
    const sent_glyph = "\xe2\x96\xb2"; // U+25B2 ▲

    // Fallback: just show labels if too small
    if (rect.height < 3) {
        buf.setString(rect.x, rect.y, recv_glyph, _Style{ .fg = .green });
        var r_buf: [12]u8 = undefined;
        const r_str = formatRate(&r_buf, sys.disk_read_rate);
        buf.setString(rect.x + 2, rect.y, r_str, _Style{ .fg = .green });
        if (rect.height > 1) {
            buf.setString(rect.x, rect.y + 1, sent_glyph, _Style{ .fg = .red });
            var w_buf: [12]u8 = undefined;
            const w_str = formatRate(&w_buf, sys.disk_write_rate);
            buf.setString(rect.x + 2, rect.y + 1, w_str, _Style{ .fg = .red });
        }
        return;
    }

    // Mirrored chart layout (like network):
    // Read grows UP from center (green), Write grows DOWN from center (red)
    const chart_inner = rect.height - 1; // minus axis row
    const dl_h = chart_inner / 2; // read half (above axis)
    const ul_h = chart_inner - dl_h; // write half (below axis)
    const axis_y = rect.y + dl_h;

    // Shared auto-scale ceiling between read and write
    const scale_window: usize = 30;
    var global_max: f64 = 0;
    {
        const rw = @min(sys.disk_read_history.count, scale_window);
        if (rw > 0) {
            const m = sys.disk_read_history.maxInWindow(rw);
            if (m > global_max) global_max = m;
        }
        const sw = @min(sys.disk_write_history.count, scale_window);
        if (sw > 0) {
            const m = sys.disk_write_history.maxInWindow(sw);
            if (m > global_max) global_max = m;
        }
    }
    const ceiling = autoScaleCeiling(global_max, 1024.0);

    // Read half: braille grows upward (green)
    if (dl_h > 0) {
        const read_ptrs = [1]*const model.RateHistory{&sys.disk_read_history};
        const read_colors = [1]_Color{.green};
        renderMultiRateUp(buf, .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = dl_h,
        }, &read_ptrs, &read_colors, ceiling);
    }

    // Center axis row: "▼5.1M ▲1.2M ──────"
    {
        const DASH: u21 = 0x2500;

        var dl_short_buf: [8]u8 = undefined;
        const dl_short = formatRateShort(&dl_short_buf, sys.disk_read_rate);
        var ul_short_buf: [8]u8 = undefined;
        const ul_short = formatRateShort(&ul_short_buf, sys.disk_write_rate);

        // Fill entire axis with dashes first
        {
            var dx: u16 = rect.x;
            while (dx < rect.x + rect.width) : (dx += 1) {
                buf.setChar(dx, axis_y, DASH, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            }
        }

        // Overlay indicators on left
        var cursor: u16 = rect.x;
        buf.setString(cursor, axis_y, recv_glyph, _Style{ .fg = .green });
        cursor += 1;
        buf.setString(cursor, axis_y, dl_short, _Style{ .fg = .green });
        cursor += @intCast(dl_short.len);
        cursor += 1; // gap
        buf.setString(cursor, axis_y, sent_glyph, _Style{ .fg = .red });
        cursor += 1;
        buf.setString(cursor, axis_y, ul_short, _Style{ .fg = .red });
    }

    // Write half: braille grows downward (red)
    if (ul_h > 0) {
        const write_ptrs = [1]*const model.RateHistory{&sys.disk_write_history};
        const write_colors = [1]_Color{.red};
        renderMultiRateDown(buf, .{
            .x = rect.x,
            .y = axis_y + 1,
            .width = rect.width,
            .height = ul_h,
        }, &write_ptrs, &write_colors, ceiling);
    }
}

/// Combined Storage overlay showing Memory and Mounts with visual separation
/// Positioned bottom-right of Disk IO pane
fn renderStorageOverlay(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState, detail_mode: state.StorageDetailMode, mount_filter: state.MountFilter) void {
    if (!sys.has_data) return;

    // Skip if pane too small
    if (rect.width < 30 or rect.height < 6) return;

    // Box dimensions: 50% width, full height
    const box_w: u16 = rect.width / 2;
    const box_h: u16 = rect.height;

    // Position: bottom-right corner
    const box_x = rect.x + rect.width -| box_w;
    const box_y = rect.y + rect.height -| box_h;

    const dim_border = _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } };

    // Corners
    buf.setChar(box_x, box_y, BD_RTL, dim_border);
    buf.setChar(box_x + box_w - 1, box_y, BD_RTR, dim_border);
    buf.setChar(box_x, box_y + box_h - 1, BD_RBL, dim_border);
    buf.setChar(box_x + box_w - 1, box_y + box_h - 1, BD_RBR, dim_border);

    // Top edge with title: "[s]torage" with highlighted key
    buf.setChar(box_x + 1, box_y, BD_HOR, dim_border);
    buf.setString(box_x + 2, box_y, "[", _Style{ .fg = .gray });
    buf.setString(box_x + 3, box_y, "s", _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
    buf.setString(box_x + 4, box_y, "]torage", _Style{ .fg = .gray });

    // Show current mode indicator
    const mode_str: []const u8 = switch (detail_mode) {
        .compact => "(2)",
        .full => "(4)",
        .with_swap => "(+S)",
    };
    buf.setString(box_x + 11, box_y, mode_str, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });

    {
        var x: u16 = box_x + 11 + @as(u16, @intCast(mode_str.len));
        while (x < box_x + box_w - 1) : (x += 1) {
            buf.setChar(x, box_y, BD_HOR, dim_border);
        }
    }

    // Bottom edge
    {
        var x: u16 = box_x + 1;
        while (x < box_x + box_w - 1) : (x += 1) {
            buf.setChar(x, box_y + box_h - 1, BD_HOR, dim_border);
        }
    }

    // Side edges
    {
        var y: u16 = box_y + 1;
        while (y < box_y + box_h - 1) : (y += 1) {
            buf.setChar(box_x, y, BD_VER, dim_border);
            buf.setChar(box_x + box_w - 1, y, BD_VER, dim_border);
        }
    }

    // Clear interior
    {
        var y: u16 = box_y + 1;
        while (y < box_y + box_h - 1) : (y += 1) {
            var x: u16 = box_x + 1;
            while (x < box_x + box_w - 1) : (x += 1) {
                buf.setChar(x, y, ' ', _Style{});
            }
        }
    }

    // Content area
    const content_x = box_x + 2;
    var content_y = box_y + 1;
    const inner_w = box_w -| 4;
    const inner_h = box_h -| 2;

    // ═══ MEMORY SECTION ═══
    // Layout depends on detail_mode: compact (2), full (4), with_swap (5)
    const mem_total_f: f32 = @floatFromInt(sys.mem_total);
    if (mem_total_f > 0) {
        const MemEntry = struct { label: []const u8, value: u64, color: _Color };

        // Build entries based on detail mode
        const all_entries = [5]MemEntry{
            .{ .label = "Used", .value = sys.mem_used, .color = memPercentColor(@as(f32, @floatFromInt(sys.mem_used)) / mem_total_f * 100.0) },
            .{ .label = "Avail", .value = sys.mem_available, .color = .cyan },
            .{ .label = "Cache", .value = sys.mem_cached, .color = .blue },
            .{ .label = "Free", .value = sys.mem_free, .color = .cyan },
            .{ .label = "Swap", .value = 0, .color = .magenta }, // TODO: Add swap tracking
        };

        const entry_count: usize = switch (detail_mode) {
            .compact => 2,
            .full => 4,
            .with_swap => 5,
        };

        const col_gap: u16 = 2;
        const mem_col_w: u16 = (inner_w -| col_gap) / 2;

        // Render memory entries in 2-column grid
        const rows_needed: u16 = @intCast((entry_count + 1) / 2);
        var mem_row: u16 = 0;
        while (mem_row < rows_needed and content_y < box_y + inner_h) : (mem_row += 1) {
            var mem_col: u16 = 0;
            while (mem_col < 2) : (mem_col += 1) {
                const idx = mem_row * 2 + mem_col;
                if (idx >= entry_count) break;

                const entry = all_entries[idx];
                const col_x = content_x + mem_col * (mem_col_w + col_gap);
                const pct: f32 = @as(f32, @floatFromInt(entry.value)) / mem_total_f * 100.0;

                // Label
                buf.setString(col_x, content_y, entry.label, _Style{ .fg = entry.color, .modifier = _Modifier{ .bold = true } });

                // Value + percentage on right
                var val_buf: [8]u8 = undefined;
                const val_str = formatBytesShort(&val_buf, entry.value);
                var pct_buf: [5]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, " {d:>2.0}%", .{pct}) catch " ??%";

                const val_x = col_x + mem_col_w -| @as(u16, @intCast(val_str.len + pct_str.len));
                buf.setString(val_x, content_y, val_str, _Style{ .fg = entry.color });
                buf.setString(val_x + @as(u16, @intCast(val_str.len)), content_y, pct_str, _Style{ .fg = .gray });
            }
            content_y += 1;
        }

        // ─── Separator line with "[m]ounts" label ───
        if (content_y < box_y + inner_h and sys.mount_count > 0) {
            const DASH: u21 = 0x2500;
            // Draw "[m]ounts" with highlighted key
            buf.setString(content_x, content_y, "[", _Style{ .fg = .gray });
            buf.setString(content_x + 1, content_y, "m", _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
            buf.setString(content_x + 2, content_y, "]ounts", _Style{ .fg = .gray });

            // Show filter indicator
            const filter_indicator: []const u8 = if (mount_filter == .all) "*" else "";
            buf.setString(content_x + 8, content_y, filter_indicator, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });

            // Fill rest with dashes
            var dx: u16 = content_x + 9;
            while (dx < content_x + inner_w) : (dx += 1) {
                buf.setChar(dx, content_y, DASH, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            }
            content_y += 1;
        }
    }

    // ═══ MOUNTS SECTION ═══
    if (sys.mount_count > 0) {
        // Filter mounts based on mount_filter setting
        // System mounts: devfs, autofs, map, synthfs, or those with 0 total bytes
        var filtered_indices: [model.MAX_MOUNTS]u8 = undefined;
        var filtered_count: u16 = 0;

        for (0..sys.mount_count) |i| {
            const mount = sys.mounts[i];
            const name = mount.name[0..mount.name_len];

            // Skip empty mounts
            if (mount.total_bytes == 0) continue;

            // If filtering, skip system mounts
            if (mount_filter == .user_only) {
                // Skip if name starts with system prefixes
                if (std.mem.startsWith(u8, name, "devfs")) continue;
                if (std.mem.startsWith(u8, name, "autofs")) continue;
                if (std.mem.startsWith(u8, name, "map ")) continue;
                if (std.mem.startsWith(u8, name, "synthfs")) continue;
                // Skip if it doesn't look like a real disk (no /)
                if (name.len > 0 and name[0] != '/') continue;
            }

            filtered_indices[filtered_count] = @intCast(i);
            filtered_count += 1;
        }

        if (filtered_count == 0) return;

        const disks_area_h = (box_y + box_h - 1) -| content_y;
        const lines_per_disk: u16 = 2;
        const total_lines_needed = filtered_count * lines_per_disk;

        // Use 2 columns if mounts won't fit
        const use_two_cols = total_lines_needed > disks_area_h and inner_w >= 28;
        const num_cols: u16 = if (use_two_cols) 2 else 1;
        const col_gap: u16 = if (use_two_cols) 2 else 0;
        const col_w: u16 = if (use_two_cols) (inner_w -| col_gap) / 2 else inner_w;
        const disks_per_col: u16 = if (use_two_cols) (filtered_count + 1) / 2 else filtered_count;

        var col: u16 = 0;
        while (col < num_cols) : (col += 1) {
            const col_x = content_x + col * (col_w + col_gap);

            var disk_in_col: u16 = 0;
            while (disk_in_col < disks_per_col) : (disk_in_col += 1) {
                const filtered_idx = col * disks_per_col + disk_in_col;
                if (filtered_idx >= filtered_count) break;

                const y_start = content_y + disk_in_col * lines_per_disk;
                if (y_start + 1 >= box_y + box_h - 1) break;

                const mount = sys.mounts[filtered_indices[filtered_idx]];
                const name = mount.name[0..mount.name_len];

                // Line 1: Mount name and total size
                const max_name_len = col_w -| 6;
                const name_display_len = @min(name.len, max_name_len);
                buf.setString(col_x, y_start, name[0..name_display_len], _Style{ .fg = .light_white, .modifier = _Modifier{ .bold = true } });

                var total_buf: [8]u8 = undefined;
                const total_str = formatBytesShort(&total_buf, mount.total_bytes);
                const total_len: u16 = @intCast(total_str.len);
                buf.setString(col_x + col_w -| total_len, y_start, total_str, _Style{ .fg = .gray });

                // Line 2: Usage bar and percentage
                if (mount.total_bytes > 0 and y_start + 1 < box_y + box_h - 1) {
                    const pct: f32 = @as(f32, @floatFromInt(mount.used_bytes)) / @as(f32, @floatFromInt(mount.total_bytes)) * 100.0;
                    const color = diskPercentColor(pct);

                    const pct_reserve: u16 = 5;
                    const bar_w = col_w -| pct_reserve;

                    if (bar_w > 0) {
                        renderBoxBar(buf, col_x, y_start + 1, bar_w, pct, 100.0, color);
                    }

                    var pct_buf: [5]u8 = undefined;
                    const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>3.0}%", .{pct}) catch "??%";
                    buf.setString(col_x + bar_w + 1, y_start + 1, pct_str, _Style{ .fg = color });
                }
            }
        }
    }
}

/// Format bytes to short form (e.g., "1.5T", "256G", "4.2M")
fn formatBytesShort(buf: *[8]u8, bytes: u64) []const u8 {
    const tib: u64 = 1024 * 1024 * 1024 * 1024;
    const gib: u64 = 1024 * 1024 * 1024;
    const mib: u64 = 1024 * 1024;

    if (bytes >= tib) {
        const val: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(tib));
        return std.fmt.bufPrint(buf, "{d:.1}T", .{val}) catch "???";
    } else if (bytes >= gib) {
        const val: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(gib));
        return std.fmt.bufPrint(buf, "{d:.0}G", .{val}) catch "???";
    } else if (bytes >= mib) {
        const val: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(mib));
        return std.fmt.bufPrint(buf, "{d:.0}M", .{val}) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "???";
    }
}

/// Color palette for network interfaces.
const iface_colors = [_]_Color{ .green, .cyan, .blue, .magenta, .yellow, .light_green, .light_cyan, .light_blue };

fn ifaceColor(idx: usize) _Color {
    return iface_colors[idx % iface_colors.len];
}

/// Multi-history overlay braille chart (bottom-up fill) for download/recv.
fn renderMultiRateUp(
    buf: *tui.render.Buffer,
    rect: layout.Rect,
    histories: []const *const model.RateHistory,
    colors: []const _Color,
    ceiling: f64,
) void {
    if (rect.width == 0 or rect.height == 0 or histories.len == 0) return;
    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const capacity = width * 2;

    for (histories, 0..) |history, h_idx| {
        const color = if (h_idx < colors.len) colors[h_idx] else .white;
        const sample_count = history.count;
        const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
        const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

        var col: usize = 0;
        while (col < width) : (col += 1) {
            if (col < width - filled_cols) continue;
            const data_col = col - (width - filled_cols);
            const pair_base = start_sample + data_col * 2;

            const left_raw: f64 = if (pair_base < sample_count) history.get(pair_base) else 0;
            const right_raw: f64 = if (pair_base + 1 < sample_count) history.get(pair_base + 1) else left_raw;

            const left_val: f32 = if (ceiling > 0) @floatCast(@min(left_raw / ceiling * 100.0, 100.0)) else 0;
            const right_val: f32 = if (ceiling > 0) @floatCast(@min(right_raw / ceiling * 100.0, 100.0)) else 0;

            var row: usize = 0;
            while (row < height) : (row += 1) {
                const screen_row = height - 1 - row;
                const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
                const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

                const left_level = quantize(left_val, band_low, band_high);
                const right_level = quantize(right_val, band_low, band_high);
                const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];
                if (braille_cp == 0x2800) continue;

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
    }
}

/// Multi-history overlay braille chart (top-down fill) for upload/sent.
/// Dots grow downward from the top of the rect (mirrored).
fn renderMultiRateDown(
    buf: *tui.render.Buffer,
    rect: layout.Rect,
    histories: []const *const model.RateHistory,
    colors: []const _Color,
    ceiling: f64,
) void {
    if (rect.width == 0 or rect.height == 0 or histories.len == 0) return;
    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const capacity = width * 2;

    for (histories, 0..) |history, h_idx| {
        const color = if (h_idx < colors.len) colors[h_idx] else .white;
        const sample_count = history.count;
        const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
        const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

        var col: usize = 0;
        while (col < width) : (col += 1) {
            if (col < width - filled_cols) continue;
            const data_col = col - (width - filled_cols);
            const pair_base = start_sample + data_col * 2;

            const left_raw: f64 = if (pair_base < sample_count) history.get(pair_base) else 0;
            const right_raw: f64 = if (pair_base + 1 < sample_count) history.get(pair_base + 1) else left_raw;

            const left_val: f32 = if (ceiling > 0) @floatCast(@min(left_raw / ceiling * 100.0, 100.0)) else 0;
            const right_val: f32 = if (ceiling > 0) @floatCast(@min(right_raw / ceiling * 100.0, 100.0)) else 0;

            // For top-down: row 0 = top of rect, fills downward
            var row: usize = 0;
            while (row < height) : (row += 1) {
                const screen_row = row; // row 0 = top
                const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
                const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

                const left_level = quantize(left_val, band_low, band_high);
                const right_level = quantize(right_val, band_low, band_high);
                const braille_cp = braille_down[@as(usize, left_level) * 5 + @as(usize, right_level)];
                if (braille_cp == 0x2800) continue;

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
    }
}

fn renderNetworkCombined(buf: *tui.render.Buffer, rect: layout.Rect, app: *state.AppState, display_mode: state.NetworkDisplayMode, protocol_filter: state.NetworkProtocolFilter) void {
    const sys = &app.system;
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    // By-process mode: show socket count graphs per process
    if (display_mode == .by_process) {
        renderNetworkByProcess(buf, rect, app, protocol_filter);
        return;
    }

    // By-process detail mode: show detailed I/O rates per process
    if (display_mode == .by_process_detail) {
        renderNetworkByProcessDetail(buf, rect, sys, protocol_filter);
        return;
    }

    const recv_glyph = "\xe2\x96\xbc"; // U+25BC ▼
    const sent_glyph = "\xe2\x96\xb2"; // U+25B2 ▲

    // Calculate chart width that stops before the overlay (16w + 2 padding)
    const overlay_w: u16 = 18;
    const chart_width: u16 = if (rect.width > overlay_w + 10) rect.width -| overlay_w else rect.width;

    const iface_count: usize = @intCast(sys.iface_count);

    // Fallback: if no per-interface data yet, show aggregate totals
    if (iface_count == 0) {
        if (rect.height < 3) {
            buf.setString(rect.x, rect.y, recv_glyph, _Style{ .fg = .green });
            var r_buf: [12]u8 = undefined;
            buf.setString(rect.x + 2, rect.y, formatRate(&r_buf, sys.net_recv_rate), _Style{ .fg = .green });
            if (rect.height > 1) {
                buf.setString(rect.x, rect.y + 1, sent_glyph, _Style{ .fg = .red });
                var s_buf: [12]u8 = undefined;
                buf.setString(rect.x + 2, rect.y + 1, formatRate(&s_buf, sys.net_sent_rate), _Style{ .fg = .red });
            }
            return;
        }
        // Single aggregate chart: download up, upload down
        const dl_h = (rect.height - 1) / 2;
        const ul_h = rect.height - 1 - dl_h;
        renderRateBrailleChart(buf, .{ .x = rect.x, .y = rect.y, .width = chart_width, .height = dl_h }, &sys.net_recv_history, .green);
        renderRateBrailleChart(buf, .{ .x = rect.x, .y = rect.y + dl_h + 1, .width = chart_width, .height = ul_h }, &sys.net_sent_history, .red);
        return;
    }

    // ── Interface label grid ──────────────────────────────────────
    // Each interface takes 2 rows: recv rate on line 1, upload rate on line 2.
    //   ● en0   ▼  5.1 MB/s
    //           ▲  1.2 MB/s
    // Dynamically calculate columns based on available width
    const col_pad: u16 = 2;
    const min_col_w: u16 = 22; // minimum width needed for "● name  ▼ 123.4 MB/s"

    // Calculate how many columns can fit (at least 1, dynamically expand for wider screens)
    const max_cols: u16 = @max(1, (rect.width + col_pad) / (min_col_w + col_pad));
    // Don't use more columns than interfaces
    const cols: u16 = @min(max_cols, @as(u16, @intCast(iface_count)));
    // Calculate actual column width to fill the space evenly
    const total_pad: u16 = if (cols > 1) (cols - 1) * col_pad else 0;
    const col_w: u16 = if (cols > 0) (rect.width -| total_pad) / cols else rect.width;

    // Each interface uses 2 rows; calculate how many row-pairs we need
    const iface_row_pairs: u16 = @intCast((@as(usize, iface_count) + @as(usize, cols) - 1) / @as(usize, cols));
    const label_row_count: u16 = iface_row_pairs * 2;
    const max_label_rows: u16 = @min(label_row_count, rect.height / 2); // reserve at least half for chart

    // Find max interface name length (across all visible interfaces) to align ▼ glyphs
    var max_name_len: u16 = 0;
    for (0..iface_count) |i| {
        const nlen: u16 = @intCast(sys.iface_name_lens[i]);
        if (nlen > max_name_len) max_name_len = nlen;
    }

    for (0..iface_count) |i| {
        const grid_row: u16 = @intCast(i / cols);
        const grid_col: u16 = @intCast(i % cols);
        const cell_x = rect.x + grid_col * (col_w + col_pad);
        const cell_y = rect.y + grid_row * 2; // 2 rows per interface
        // Guard: need 2 rows for this interface
        if (cell_y + 1 >= rect.y + max_label_rows) break;
        const color = ifaceColor(i);
        const name = sys.iface_names[i][0..sys.iface_name_lens[i]];
        const cell_end = cell_x + col_w;

        // Colored dot legend + interface name
        buf.setChar(cell_x, cell_y, 0x25CF, _Style{ .fg = color }); // ●
        buf.setString(cell_x + 2, cell_y, name, _Style{ .fg = color, .modifier = _Modifier{ .bold = true } });

        // ▼ recv rate — aligned at consistent column across all interfaces
        const rate_x = cell_x + 2 + max_name_len + 1;
        if (rate_x + 2 < cell_end) {
            buf.setString(rate_x, cell_y, recv_glyph, _Style{ .fg = color });
            var r_buf: [12]u8 = undefined;
            const r_str = formatRate(&r_buf, sys.iface_recv_rates[i]);
            const r_len: u16 = @intCast(r_str.len);
            const r_avail = cell_end -| (rate_x + 2);
            const r_show: u16 = @min(r_len, r_avail);
            if (r_show > 0) buf.setString(rate_x + 2, cell_y, r_str[0..r_show], _Style{ .fg = color });
        }

        // ▲ upload rate on second row, aligned under recv rate
        if (rate_x + 2 < cell_end) {
            buf.setString(rate_x, cell_y + 1, sent_glyph, _Style{ .fg = color });
            var s_buf: [12]u8 = undefined;
            const s_str = formatRate(&s_buf, sys.iface_sent_rates[i]);
            const s_len: u16 = @intCast(s_str.len);
            const s_avail = cell_end -| (rate_x + 2);
            const s_show: u16 = @min(s_len, s_avail);
            if (s_show > 0) buf.setString(rate_x + 2, cell_y + 1, s_str[0..s_show], _Style{ .fg = color });
        }
    }

    // ── Mirrored chart below labels ─────────────────────────────
    // Download (recv) grows UP from center, Upload (sent) grows DOWN from center.
    // A center axis row separates the two halves with direction indicators.
    const chart_y = rect.y + max_label_rows;
    const chart_h = rect.height -| max_label_rows;
    if (chart_h < 3) return; // need at least 1 + 1 + 1 (dl, axis, ul)

    // Reserve 1 row for the center axis
    const chart_inner = chart_h - 1;
    const dl_h = chart_inner / 2; // download half (above axis)
    const ul_h = chart_inner - dl_h; // upload half (below axis)
    const axis_y = chart_y + dl_h;

    // Build pointer/color arrays
    var recv_ptrs: [model.MAX_INTERFACES]*const model.RateHistory = undefined;
    var sent_ptrs: [model.MAX_INTERFACES]*const model.RateHistory = undefined;
    var colors: [model.MAX_INTERFACES]_Color = undefined;
    for (0..iface_count) |i| {
        recv_ptrs[i] = &sys.iface_recv_histories[i];
        sent_ptrs[i] = &sys.iface_sent_histories[i];
        colors[i] = ifaceColor(i);
    }

    // Shared scale across both halves — use a short recent window so the
    // chart adapts quickly to current traffic instead of being pinned by
    // old spikes, which causes low traffic to appear as floating dots.
    const scale_window: usize = 30; // ~30 seconds of recent data
    var global_max: f64 = 0;
    for (0..iface_count) |i| {
        const rw = @min(sys.iface_recv_histories[i].count, scale_window);
        if (rw > 0) {
            const m = sys.iface_recv_histories[i].maxInWindow(rw);
            if (m > global_max) global_max = m;
        }
        const sw = @min(sys.iface_sent_histories[i].count, scale_window);
        if (sw > 0) {
            const m = sys.iface_sent_histories[i].maxInWindow(sw);
            if (m > global_max) global_max = m;
        }
    }
    const ceiling = autoScaleCeiling(global_max, 1024.0);

    // Download half: braille grows upward
    if (dl_h > 0) {
        renderMultiRateUp(buf, .{
            .x = rect.x, .y = chart_y, .width = chart_width, .height = dl_h,
        }, recv_ptrs[0..iface_count], colors[0..iface_count], ceiling);
    }

    // Center axis row: "▼5.1M ▲1.2M ──────────"
    {
        const DASH: u21 = 0x2500;

        var dl_short_buf: [8]u8 = undefined;
        const dl_short = formatRateShort(&dl_short_buf, sys.net_recv_rate);
        var ul_short_buf: [8]u8 = undefined;
        const ul_short = formatRateShort(&ul_short_buf, sys.net_sent_rate);

        // Fill axis with dashes (only up to chart width)
        {
            var dx: u16 = rect.x;
            while (dx < rect.x + chart_width) : (dx += 1) {
                buf.setChar(dx, axis_y, DASH, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            }
        }

        // Overlay indicators on left
        var cursor: u16 = rect.x;
        buf.setString(cursor, axis_y, recv_glyph, _Style{ .fg = .green });
        cursor += 1; // glyph is 1 cell wide
        buf.setString(cursor, axis_y, dl_short, _Style{ .fg = .green });
        cursor += @intCast(dl_short.len);
        cursor += 1; // gap
        buf.setString(cursor, axis_y, sent_glyph, _Style{ .fg = .red });
        cursor += 1;
        buf.setString(cursor, axis_y, ul_short, _Style{ .fg = .red });
    }

    // Upload half: braille grows downward
    if (ul_h > 0) {
        renderMultiRateDown(buf, .{
            .x = rect.x, .y = axis_y + 1, .width = chart_width, .height = ul_h,
        }, sent_ptrs[0..iface_count], colors[0..iface_count], ceiling);
    }

    // Floating stats overlay in bottom-right corner
    renderNetworkOverlay(buf, rect, sys);
}

/// Floating overlay box showing cumulative network totals (bpytop style)
fn renderNetworkOverlay(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    // Box dimensions: 16w × 4h
    const box_w: u16 = 16;
    const box_h: u16 = 4;

    // Adaptive: skip overlay if pane too small for the box
    if (rect.width < box_w + 2 or rect.height < box_h + 1) return;

    // Position: bottom-right corner of pane area
    const box_x = rect.x + rect.width -| box_w -| 1;
    const box_y = rect.y + rect.height -| box_h -| 1;

    // Draw box border (dim style)
    const dim_border = _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } };

    // Corners
    buf.setChar(box_x, box_y, BD_RTL, dim_border); // ╭
    buf.setChar(box_x + box_w - 1, box_y, BD_RTR, dim_border); // ╮
    buf.setChar(box_x, box_y + box_h - 1, BD_RBL, dim_border); // ╰
    buf.setChar(box_x + box_w - 1, box_y + box_h - 1, BD_RBR, dim_border); // ╯

    // Top edge with title
    buf.setChar(box_x + 1, box_y, BD_HOR, dim_border);
    buf.setString(box_x + 2, box_y, "Totals", _Style{ .fg = .gray });
    {
        var x: u16 = box_x + 8;
        while (x < box_x + box_w - 1) : (x += 1) {
            buf.setChar(x, box_y, BD_HOR, dim_border);
        }
    }

    // Bottom edge
    {
        var x: u16 = box_x + 1;
        while (x < box_x + box_w - 1) : (x += 1) {
            buf.setChar(x, box_y + box_h - 1, BD_HOR, dim_border);
        }
    }

    // Side edges
    buf.setChar(box_x, box_y + 1, BD_VER, dim_border);
    buf.setChar(box_x, box_y + 2, BD_VER, dim_border);
    buf.setChar(box_x + box_w - 1, box_y + 1, BD_VER, dim_border);
    buf.setChar(box_x + box_w - 1, box_y + 2, BD_VER, dim_border);

    // Content: download total
    const recv_glyph = "\xe2\x96\xbc"; // U+25BC ▼
    const sent_glyph = "\xe2\x96\xb2"; // U+25B2 ▲

    buf.setString(box_x + 2, box_y + 1, recv_glyph, _Style{ .fg = .green });
    var recv_buf: [12]u8 = undefined;
    const recv_str = formatBytes(&recv_buf, sys.net_total_recv);
    buf.setString(box_x + 4, box_y + 1, recv_str, _Style{ .fg = .green });

    // Content: upload total
    buf.setString(box_x + 2, box_y + 2, sent_glyph, _Style{ .fg = .red });
    var sent_buf: [12]u8 = undefined;
    const sent_str = formatBytes(&sent_buf, sys.net_total_sent);
    buf.setString(box_x + 4, box_y + 2, sent_str, _Style{ .fg = .red });
}

/// Render network view by process - shows socket count graphs per process
/// Groups processes by coalition_id to show XPC children indented under parent apps
fn renderNetworkByProcess(buf: *tui.render.Buffer, rect: layout.Rect, app: *state.AppState, filter: state.NetworkProtocolFilter) void {
    const dim_style = _Style{ .fg = .gray };
    const sys = &app.system;

    // Process colors (same palette as network interfaces)
    const proc_colors = [_]_Color{ .light_cyan, .light_magenta, .light_green, .light_yellow, .light_blue, .light_red, .cyan, .magenta };

    // Get TCP connections
    const all_tcp = sys.tcp_connections[0..sys.tcp_connection_count];
    if (all_tcp.len == 0 and sys.tracked_proc_count == 0) {
        buf.setString(rect.x, rect.y, "No socket activity", dim_style);
        buf.setString(rect.x, rect.y + 1, "(waiting for processes with open sockets)", dim_style);
        return;
    }

    // Entry can be either a coalition leader (parent app) or a process with connections
    const DisplayEntry = struct {
        pid: model.pid_t,
        coalition_id: u64,
        is_leader: bool, // Coalition leader (main app like Safari)
        is_child: bool, // XPC child within coalition
        conn_count: u32, // Number of TCP connections
        name: [16]u8,
        name_len: u8,
    };

    var entries: [model.MAX_TRACKED_PROCS * 2]DisplayEntry = undefined;
    var entry_count: usize = 0;

    // Collect unique coalition IDs from TCP connections
    var seen_coalitions: [64]u64 = [_]u64{0} ** 64;
    var seen_coalition_count: usize = 0;

    // First: gather all unique PIDs with their connection counts and coalition IDs
    const PidInfo = struct {
        pid: model.pid_t,
        coalition_id: u64,
        conn_count: u32,
    };
    var pid_infos: [128]PidInfo = undefined;
    var pid_info_count: usize = 0;

    for (all_tcp) |conn| {
        // Find or create entry for this PID
        var found_idx: ?usize = null;
        for (0..pid_info_count) |pi| {
            if (pid_infos[pi].pid == conn.pid) {
                found_idx = pi;
                break;
            }
        }
        if (found_idx) |idx| {
            pid_infos[idx].conn_count += 1;
        } else if (pid_info_count < pid_infos.len) {
            pid_infos[pid_info_count] = .{
                .pid = conn.pid,
                .coalition_id = conn.coalition_id,
                .conn_count = 1,
            };
            pid_info_count += 1;
        }

        // Track unique coalition IDs (non-zero)
        if (conn.coalition_id != 0) {
            var coalition_seen = false;
            for (seen_coalitions[0..seen_coalition_count]) |c| {
                if (c == conn.coalition_id) {
                    coalition_seen = true;
                    break;
                }
            }
            if (!coalition_seen and seen_coalition_count < seen_coalitions.len) {
                seen_coalitions[seen_coalition_count] = conn.coalition_id;
                seen_coalition_count += 1;
            }
        }
    }

    // For each coalition, find the leader process (main app) from app.procs
    const cold_slice = app.procs.cold.slice();
    const hot_slice = app.procs.hot.slice();
    const coalition_ids = cold_slice.items(.coalition_id);
    const names = cold_slice.items(.name);
    const pids = hot_slice.items(.pid);

    for (seen_coalitions[0..seen_coalition_count]) |coalition_id| {
        if (coalition_id == 0) continue;

        // Find the coalition leader: process in this coalition with shortest name
        // (XPC services typically have long names like "com.apple.WebKit.Networking")
        var leader_idx: ?usize = null;
        var leader_name_len: usize = 999;

        for (0..cold_slice.len) |idx| {
            if (coalition_ids[idx] == coalition_id) {
                const name_len = names[idx].len;
                // Prefer shorter names (main apps) over XPC service names
                // Also prefer names not containing "com." or "XPC"
                var score = name_len;
                if (std.mem.indexOf(u8, names[idx], "com.") != null) score += 50;
                if (std.mem.indexOf(u8, names[idx], "XPC") != null) score += 50;
                if (std.mem.indexOf(u8, names[idx], "Helper") != null) score += 30;

                if (score < leader_name_len) {
                    leader_name_len = score;
                    leader_idx = idx;
                }
            }
        }

        // Add the coalition leader as a display entry (even if no direct connections)
        if (leader_idx) |idx| {
            const leader_pid = pids[idx];
            // Check if leader already has connections (would be in pid_infos)
            var leader_has_connections = false;
            for (0..pid_info_count) |pi| {
                if (pid_infos[pi].pid == leader_pid) {
                    leader_has_connections = true;
                    break;
                }
            }

            // Only add leader if it doesn't already have connections (will be added below)
            if (!leader_has_connections and entry_count < entries.len) {
                var name_buf: [16]u8 = [_]u8{0} ** 16;
                const copy_len = @min(names[idx].len, 16);
                @memcpy(name_buf[0..copy_len], names[idx][0..copy_len]);

                entries[entry_count] = .{
                    .pid = leader_pid,
                    .coalition_id = coalition_id,
                    .is_leader = true,
                    .is_child = false,
                    .conn_count = 0,
                    .name = name_buf,
                    .name_len = @intCast(copy_len),
                };
                entry_count += 1;
            }
        }
    }

    // Add all PIDs with connections
    for (0..pid_info_count) |pi| {
        if (entry_count >= entries.len) break;

        const info = pid_infos[pi];

        // Get name from procs store or tracked_procs
        var name_buf: [16]u8 = [_]u8{0} ** 16;
        var name_len: u8 = 0;

        if (app.procs.pid_to_index.get(info.pid)) |idx| {
            const name = names[idx];
            const copy_len = @min(name.len, 16);
            @memcpy(name_buf[0..copy_len], name[0..copy_len]);
            name_len = @intCast(copy_len);
        } else {
            // Fallback: check tracked_procs
            for (0..model.MAX_TRACKED_PROCS) |ti| {
                if (sys.tracked_procs[ti].active and sys.tracked_procs[ti].pid == info.pid) {
                    const tp = &sys.tracked_procs[ti];
                    const copy_len: usize = @intCast(tp.name_len);
                    @memcpy(name_buf[0..copy_len], tp.name[0..copy_len]);
                    name_len = tp.name_len;
                    break;
                }
            }
        }

        if (name_len == 0) {
            // Unknown process, use PID as name
            const pid_str = std.fmt.bufPrint(&name_buf, "pid:{d}", .{info.pid}) catch "???";
            name_len = @intCast(pid_str.len);
        }

        entries[entry_count] = .{
            .pid = info.pid,
            .coalition_id = info.coalition_id,
            .is_leader = false,
            .is_child = false,
            .conn_count = info.conn_count,
            .name = name_buf,
            .name_len = name_len,
        };
        entry_count += 1;
    }

    if (entry_count == 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = if (filter == .all)
            "No active network connections"
        else
            std.fmt.bufPrint(&msg_buf, "No active {s} connections", .{filter.label()}) catch "No active connections";
        buf.setString(rect.x, rect.y, msg, dim_style);
        return;
    }

    // Sort entries by coalition_id, then by is_leader (leaders first), then by conn_count
    std.mem.sort(DisplayEntry, entries[0..entry_count], {}, struct {
        fn lessThan(_: void, a: DisplayEntry, b: DisplayEntry) bool {
            // Coalition 0 means unknown - sort these last
            const a_has_coalition = a.coalition_id != 0;
            const b_has_coalition = b.coalition_id != 0;
            if (a_has_coalition != b_has_coalition) return a_has_coalition;
            if (a.coalition_id != b.coalition_id) return a.coalition_id < b.coalition_id;
            // Leaders first within coalition
            if (a.is_leader != b.is_leader) return a.is_leader;
            // Then by connection count
            return a.conn_count > b.conn_count;
        }
    }.lessThan);

    // Mark XPC children (same coalition as previous, coalition must be non-zero)
    var prev_coalition: u64 = 0;
    for (0..entry_count) |idx| {
        const coalition = entries[idx].coalition_id;
        if (coalition != 0 and idx > 0 and coalition == prev_coalition and !entries[idx].is_leader) {
            entries[idx].is_child = true;
        }
        prev_coalition = coalition;
    }

    // Store entry PIDs and count for navigation
    app.network_entry_count = entry_count;
    const pid_copy_len = @min(entry_count, app.network_entry_pids.len);
    for (0..pid_copy_len) |idx| {
        app.network_entry_pids[idx] = entries[idx].pid;
    }
    // Clamp selection to valid range
    if (app.network_selected >= entry_count and entry_count > 0) {
        app.network_selected = entry_count - 1;
    }

    // Check if network pane is focused for selection highlight
    const show_selection = (app.dashboard_focus == .network_pane);

    // Count coalition groups for two-column layout
    // Each coalition group (parent + children) stays together in one column
    const CoalitionGroup = struct {
        start_idx: usize,
        count: usize,
    };
    var groups: [model.MAX_TRACKED_PROCS * 2]CoalitionGroup = undefined;
    var group_count: usize = 0;
    var i: usize = 0;
    while (i < entry_count) {
        const start = i;
        const coalition = entries[i].coalition_id;
        i += 1;
        // Include all children in same group
        while (i < entry_count and entries[i].coalition_id == coalition and coalition != 0) : (i += 1) {}
        groups[group_count] = .{ .start_idx = start, .count = i - start };
        group_count += 1;
    }

    // Two-column layout - distribute groups (not individual entries) evenly
    const col_gap: u16 = 2;
    const col_width: u16 = (rect.width -| col_gap) / 2;
    const col2_x = rect.x + col_width + col_gap;
    const max_rows: usize = @intCast(rect.height);

    // Assign groups to columns, keeping each group together
    var left_rows: usize = 0;
    var right_rows: usize = 0;
    var group_columns: [model.MAX_TRACKED_PROCS * 2]u16 = undefined; // 0=left, 1=right
    var group_start_rows: [model.MAX_TRACKED_PROCS * 2]usize = undefined;

    for (0..group_count) |gi| {
        const group_size = groups[gi].count;
        // Assign to column with fewer rows (balance columns)
        if (left_rows <= right_rows) {
            group_columns[gi] = 0;
            group_start_rows[gi] = left_rows;
            left_rows += group_size;
        } else {
            group_columns[gi] = 1;
            group_start_rows[gi] = right_rows;
            right_rows += group_size;
        }
    }

    var color_idx: usize = 0;
    for (0..group_count) |gi| {
        const group = groups[gi];
        const col = group_columns[gi];
        const base_x: u16 = if (col == 0) rect.x else col2_x;
        const max_x = if (col == 0) col2_x -| 1 else rect.x + rect.width;

        for (0..group.count) |offset| {
            const row_in_col = group_start_rows[gi] + offset;
            if (row_in_col >= max_rows) break;

            const idx = group.start_idx + offset;
            const y: u16 = rect.y + @as(u16, @intCast(row_in_col));

            // Store column and row info for navigation
            if (idx < app.network_entry_cols.len) {
                app.network_entry_cols[idx] = @intCast(col);
                app.network_entry_rows[idx] = @intCast(row_in_col);
            }

            const entry = entries[idx];
            const is_selected = show_selection and idx == app.network_selected;

            // XPC children use same color as parent but get indent
            if (!entry.is_child) {
                color_idx = gi; // Use group index for color
            }
            const color = proc_colors[color_idx % proc_colors.len];

            const name_slice = entry.name[0..entry.name_len];

            // Selection highlight - draw background for selected row
            if (is_selected) {
                // Fill row with highlight background
                for (base_x..max_x) |x| {
                    buf.setString(@intCast(x), y, " ", _Style{ .bg = .dark_gray });
                }
            }

            if (entry.is_child) {
                // XPC child - show with └ prefix and indent
                const child_style: _Style = if (is_selected)
                    .{ .fg = .white, .bg = .dark_gray }
                else
                    .{ .fg = .gray };
                buf.setString(base_x, y, "  \xe2\x94\x94", child_style); // └
                const name_max: usize = 7;
                const name_display_len = @min(entry.name_len, name_max);
                buf.setString(base_x + 4, y, name_slice[0..name_display_len], child_style);
            } else {
                // Parent process - colored dot
                const dot_style: _Style = if (is_selected)
                    .{ .fg = color, .bg = .dark_gray }
                else
                    .{ .fg = color };
                const name_style: _Style = if (is_selected)
                    .{ .fg = .white, .bg = .dark_gray, .modifier = _Modifier{ .bold = true } }
                else
                    .{ .fg = .white };
                buf.setString(base_x, y, "\xe2\x97\x8f", dot_style); // ● dot
                const name_max: usize = 8;
                const name_display_len = @min(entry.name_len, name_max);
                buf.setString(base_x + 2, y, name_slice[0..name_display_len], name_style);
            }

            // Connection count
            const name_style_color: _Color = if (entry.is_child) .gray else color;
            const count_style: _Style = if (is_selected)
                .{ .fg = name_style_color, .bg = .dark_gray }
            else
                .{ .fg = name_style_color };
            var count_buf: [8]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d:>3}", .{entry.conn_count}) catch "???";
            buf.setString(base_x + 11, y, count_str, count_style);

            // Port styles with selection background
            const listen_style: _Style = if (is_selected) .{ .fg = .cyan, .bg = .dark_gray } else .{ .fg = .cyan };
            const remote_prefix_style: _Style = if (is_selected) .{ .fg = .yellow, .bg = .dark_gray } else .{ .fg = .yellow };
            const remote_port_style: _Style = if (is_selected) .{ .fg = .light_yellow, .bg = .dark_gray } else .{ .fg = .light_yellow };
            const space_style: _Style = if (is_selected) .{ .bg = .dark_gray } else .{};

            // Collect unique ports for this process from TCP connections
            // Separate listen ports (local) from remote ports (outbound)
            var listen_ports: [4]u16 = [_]u16{0} ** 4;
            var listen_count: usize = 0;
            var remote_ports: [4]u16 = [_]u16{0} ** 4;
            var remote_count: usize = 0;

            for (all_tcp) |conn| {
                if (conn.pid != entry.pid) continue;

                if (conn.state == .listen) {
                    // Listening port - use local port
                    const port = conn.local_port;
                    if (port == 0) continue;
                    var found = false;
                    for (listen_ports[0..listen_count]) |p| {
                        if (p == port) {
                            found = true;
                            break;
                        }
                    }
                    if (!found and listen_count < 4) {
                        listen_ports[listen_count] = port;
                        listen_count += 1;
                    }
                } else {
                    // Outbound connection - use remote port
                    const port = conn.remote_port;
                    if (port == 0) continue;
                    var found = false;
                    for (remote_ports[0..remote_count]) |p| {
                        if (p == port) {
                            found = true;
                            break;
                        }
                    }
                    if (!found and remote_count < 4) {
                        remote_ports[remote_count] = port;
                        remote_count += 1;
                    }
                }
            }

            // Display ports after count: ":port" for listen, "→port" for remote
            var x_offset: u16 = 15;

            // Listen ports first (cyan, with : prefix)
            if (listen_count > 0) {
                for (0..listen_count) |pi| {
                    if (base_x + x_offset >= max_x -| 2) break;
                    buf.setString(base_x + x_offset, y, ":", listen_style);
                    x_offset += 1;
                    var port_buf: [6]u8 = undefined;
                    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{listen_ports[pi]}) catch "";
                    buf.setString(base_x + x_offset, y, port_str, listen_style);
                    x_offset += @as(u16, @intCast(port_str.len));
                    if (pi < listen_count - 1 or remote_count > 0) {
                        if (base_x + x_offset < max_x -| 2) {
                            buf.setString(base_x + x_offset, y, " ", space_style);
                            x_offset += 1;
                        }
                    }
                }
            }

            // Remote ports (yellow, with → prefix)
            if (remote_count > 0) {
                for (0..remote_count) |pi| {
                    if (base_x + x_offset >= max_x -| 2) break;
                    buf.setString(base_x + x_offset, y, "\xe2\x86\x92", remote_prefix_style); // →
                    x_offset += 1;
                    var port_buf: [6]u8 = undefined;
                    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{remote_ports[pi]}) catch "";
                    buf.setString(base_x + x_offset, y, port_str, remote_port_style);
                    x_offset += @as(u16, @intCast(port_str.len));
                    if (pi < remote_count - 1 and base_x + x_offset < max_x -| 2) {
                        buf.setString(base_x + x_offset, y, " ", space_style);
                        x_offset += 1;
                    }
                }
            }
        }
    }
}

/// Render detailed per-process network I/O view with table layout and sparklines
fn renderNetworkByProcessDetail(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState, filter: state.NetworkProtocolFilter) void {
    const dim_style = _Style{ .fg = .gray };
    const header_style = _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } };

    const tracked_count = sys.tracked_proc_count;
    if (tracked_count == 0) {
        buf.setString(rect.x, rect.y, "No network activity", dim_style);
        buf.setString(rect.x, rect.y + 1, "(waiting for nettop data)", dim_style);
        return;
    }

    // Collect active processes with I/O data
    var active_procs: [model.MAX_TRACKED_PROCS]usize = undefined;
    var active_count: usize = 0;
    for (0..model.MAX_TRACKED_PROCS) |i| {
        if (sys.tracked_procs[i].active) {
            const tp = &sys.tracked_procs[i];
            // Filter by protocol if applicable
            const has_matching_sockets: bool = switch (filter) {
                .all => tp.socket_count > 0,
                .tcp => tp.tcp_count > 0,
                .udp => tp.udp_count > 0,
                .unix => tp.unix_count > 0,
            };
            // Show if has matching sockets OR has network I/O data
            if (has_matching_sockets or tp.bytes_in_rate > 0 or tp.bytes_out_rate > 0) {
                active_procs[active_count] = i;
                active_count += 1;
            }
        }
    }

    // Sort by network usage (bytes_in_rate + bytes_out_rate) descending
    if (active_count > 1) {
        for (1..active_count) |i| {
            const key = active_procs[i];
            const key_rate = sys.tracked_procs[key].bytes_in_rate + sys.tracked_procs[key].bytes_out_rate;
            var j = i;
            while (j > 0) {
                const prev_rate = sys.tracked_procs[active_procs[j - 1]].bytes_in_rate + sys.tracked_procs[active_procs[j - 1]].bytes_out_rate;
                if (prev_rate >= key_rate) break;
                active_procs[j] = active_procs[j - 1];
                j -= 1;
            }
            active_procs[j] = key;
        }
    }

    if (active_count == 0) {
        buf.setString(rect.x, rect.y, "No processes with network activity", dim_style);
        return;
    }

    // Calculate sparkline width based on available space
    // Layout: name(10) + pid(8) + sock(6) + in_rate(12) + out_rate(12) + sparklines(rest)
    const fixed_cols: u16 = 48;
    const sparkline_area: u16 = if (rect.width > fixed_cols + 4) rect.width - fixed_cols else 4;
    const sparkline_w: u16 = sparkline_area / 2; // Split between in/out

    // Header row
    var y = rect.y;
    buf.setString(rect.x, y, "Process", header_style);
    buf.setString(rect.x + 10, y, "PID", header_style);
    buf.setString(rect.x + 18, y, "Sock", header_style);
    buf.setString(rect.x + 23, y, "\xe2\x96\xbc In/s", header_style); // ▼ In/s
    buf.setString(rect.x + 35, y, "\xe2\x96\xb2 Out/s", header_style); // ▲ Out/s
    buf.setString(rect.x + fixed_cols, y, "In History", header_style);
    buf.setString(rect.x + fixed_cols + sparkline_w, y, "Out History", header_style);
    y += 1;

    // Separator
    if (y < rect.y + rect.height) {
        var sep_buf: [128]u8 = undefined;
        const sep_w: usize = @min(rect.width, 128);
        @memset(sep_buf[0..sep_w], '-');
        buf.setString(rect.x, y, sep_buf[0..sep_w], dim_style);
        y += 1;
    }

    // Process rows
    const proc_colors = [_]_Color{ .light_cyan, .light_magenta, .light_green, .light_yellow, .light_blue, .light_red, .cyan, .magenta };

    for (0..active_count) |idx| {
        if (y >= rect.y + rect.height) break;

        const proc_idx = active_procs[idx];
        const tp = &sys.tracked_procs[proc_idx];
        const color = proc_colors[idx % proc_colors.len];

        // Process name (truncated to 9 chars)
        const name_len: usize = @intCast(tp.name_len);
        const name_max: usize = 9;
        const name_display_len = @min(name_len, name_max);
        buf.setString(rect.x, y, tp.name[0..name_display_len], _Style{ .fg = color });

        // PID
        var pid_buf: [8]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d:<7}", .{tp.pid}) catch "?";
        buf.setString(rect.x + 10, y, pid_str, _Style{ .fg = .white });

        // Socket count (filtered)
        const sock_count: u32 = switch (filter) {
            .all => tp.socket_count,
            .tcp => tp.tcp_count,
            .udp => tp.udp_count,
            .unix => tp.unix_count,
        };
        var sock_buf: [6]u8 = undefined;
        const sock_str = std.fmt.bufPrint(&sock_buf, "{d:<4}", .{sock_count}) catch "?";
        buf.setString(rect.x + 18, y, sock_str, _Style{ .fg = .cyan });

        // In rate
        var in_rate_buf: [12]u8 = undefined;
        const in_rate_str = formatRateWithBuf(&in_rate_buf, tp.bytes_in_rate);
        buf.setString(rect.x + 23, y, in_rate_str, _Style{ .fg = .green });

        // Out rate
        var out_rate_buf: [12]u8 = undefined;
        const out_rate_str = formatRateWithBuf(&out_rate_buf, tp.bytes_out_rate);
        buf.setString(rect.x + 35, y, out_rate_str, _Style{ .fg = .yellow });

        // In history sparkline
        if (sparkline_w > 0) {
            renderNetRateSparkline(buf, rect.x + fixed_cols, y, sparkline_w -| 1, &tp.in_rate_history, .green);
        }

        // Out history sparkline
        if (sparkline_w > 0) {
            renderNetRateSparkline(buf, rect.x + fixed_cols + sparkline_w, y, sparkline_w -| 1, &tp.out_rate_history, .yellow);
        }

        y += 1;
    }
}

/// Render a single-row sparkline for network rate history using braille
fn renderNetRateSparkline(buf: *tui.render.Buffer, x: u16, y: u16, width: u16, history: *const model.NetRateHistory, color: _Color) void {
    if (width == 0 or history.count == 0) return;

    const w: usize = @intCast(width);

    // Auto-scale based on max value in history
    const max_val = @max(history.max(), 1.0); // At least 1 to avoid div by zero

    // 2 samples per braille character
    const capacity = w * 2;
    const start_sample: usize = if (history.count > capacity) history.count - capacity else 0;
    const filled_chars: usize = if (history.count >= 2) @min((history.count + 1) / 2, w) else if (history.count == 1) 1 else 0;

    var col: usize = 0;
    while (col < w) : (col += 1) {
        const screen_x = x + @as(u16, @intCast(col));

        // Before data starts, draw baseline
        if (col < w - filled_chars) {
            buf.setString(screen_x, y, "⡀", _Style{ .fg = .gray });
            continue;
        }

        const data_col = col - (w - filled_chars);
        const pair_base = start_sample + data_col * 2;

        const left_val: f32 = if (pair_base < history.count) history.get(pair_base) else 0;
        const right_val: f32 = if (pair_base + 1 < history.count) history.get(pair_base + 1) else left_val;

        // Normalize to 0-4 range based on max
        var left_level: u8 = @intFromFloat(@min(left_val / max_val * 4.0, 4.0));
        var right_level: u8 = @intFromFloat(@min(right_val / max_val * 4.0, 4.0));

        // Ensure non-zero values show at least 1 dot
        if (left_val > 0 and left_level == 0) left_level = 1;
        if (right_val > 0 and right_level == 0) right_level = 1;

        // Build braille codepoint
        var cp: u21 = 0x2800;
        if (left_level >= 1) cp |= 0x40;
        if (left_level >= 2) cp |= 0x04;
        if (left_level >= 3) cp |= 0x02;
        if (left_level >= 4) cp |= 0x01;
        if (right_level >= 1) cp |= 0x80;
        if (right_level >= 2) cp |= 0x20;
        if (right_level >= 3) cp |= 0x10;
        if (right_level >= 4) cp |= 0x08;

        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
        buf.setString(screen_x, y, utf8_buf[0..utf8_len], _Style{ .fg = color });
    }
}

/// Format rate with buffer for non-static usage
fn formatRateWithBuf(out_buf: *[12]u8, rate: f64) []const u8 {
    if (rate >= 1024.0 * 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>6.1} G/s", .{rate / (1024.0 * 1024.0 * 1024.0)}) catch "? G/s";
    } else if (rate >= 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>6.1} M/s", .{rate / (1024.0 * 1024.0)}) catch "? M/s";
    } else if (rate >= 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>6.1} K/s", .{rate / 1024.0}) catch "? K/s";
    } else if (rate > 0) {
        return std.fmt.bufPrint(out_buf, "{d:>6.0} B/s", .{rate}) catch "? B/s";
    } else {
        return "     0 B/s";
    }
}

/// Format a rate (bytes/sec) in compact form: "1.2M", "300K", "5G", etc.
/// Returns a static buffer - not reentrant, use immediately.
fn formatRateCompact(rate: f64) []const u8 {
    const Static = struct {
        var buf: [8]u8 = undefined;
    };
    if (rate >= 1024.0 * 1024.0 * 1024.0) {
        return std.fmt.bufPrint(&Static.buf, "{d:.0}G", .{rate / (1024.0 * 1024.0 * 1024.0)}) catch "?G";
    } else if (rate >= 1024.0 * 1024.0) {
        return std.fmt.bufPrint(&Static.buf, "{d:.0}M", .{rate / (1024.0 * 1024.0)}) catch "?M";
    } else if (rate >= 1024.0) {
        return std.fmt.bufPrint(&Static.buf, "{d:.0}K", .{rate / 1024.0}) catch "?K";
    } else if (rate > 0) {
        return std.fmt.bufPrint(&Static.buf, "{d:.0}B", .{rate}) catch "?B";
    } else {
        return "0";
    }
}

fn formatBytes(out_buf: *[12]u8, bytes: u64) []const u8 {
    const fb: f64 = @floatFromInt(bytes);
    if (fb >= 1024.0 * 1024.0 * 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>5.1} TiB", .{fb / (1024.0 * 1024.0 * 1024.0 * 1024.0)}) catch "??? TiB";
    } else if (fb >= 1024.0 * 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>5.1} GiB", .{fb / (1024.0 * 1024.0 * 1024.0)}) catch "??? GiB";
    } else if (fb >= 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>5.1} MiB", .{fb / (1024.0 * 1024.0)}) catch "??? MiB";
    } else if (fb >= 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:>5.1} KiB", .{fb / 1024.0}) catch "??? KiB";
    } else {
        return std.fmt.bufPrint(out_buf, "{d:>5.0}   B", .{fb}) catch "???   B";
    }
}

fn renderMemoryPane(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting...", _Style{ .fg = .gray });
        return;
    }

    const mem_total_f: f32 = @floatFromInt(sys.mem_total);
    if (mem_total_f == 0) return;

    const MemLine = struct {
        label: []const u8,
        value: u64,
        color: _Color,
    };

    const lines = [4]MemLine{
        .{ .label = "Used", .value = sys.mem_used, .color = memPercentColor(@as(f32, @floatFromInt(sys.mem_used)) / mem_total_f * 100.0) },
        .{ .label = "Available", .value = sys.mem_available, .color = .cyan },
        .{ .label = "Cached", .value = sys.mem_cached, .color = .blue },
        .{ .label = "Free", .value = sys.mem_free, .color = .cyan },
    };

    var y: u16 = rect.y;
    const max_y = rect.y + rect.height;

    // Adaptive: if height < 4, show only Used + Available
    const max_lines: usize = if (rect.height < 4) 2 else 4;

    // Layout constants
    const label_w: u16 = 10; // "Available " = 9 + 1 padding
    const value_w: u16 = 10; // " 8.1 GiB"
    const pct_w: u16 = 5; // " 50%"

    for (lines[0..max_lines]) |line| {
        if (y >= max_y) break;

        const pct: f32 = @as(f32, @floatFromInt(line.value)) / mem_total_f * 100.0;

        // bpytop-style single row: Label  ■■■■□□□□  8.1 GiB   50%
        buf.setString(rect.x, y, line.label, _Style{ .fg = line.color, .modifier = _Modifier{ .bold = true } });

        // Calculate bar width: total width minus label, value, and percentage
        const bar_w = rect.width -| (label_w + value_w + pct_w);

        // Adaptive: if width < 30, show label + percent only (skip bar and value)
        if (rect.width < 30) {
            var pct_buf: [5]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch " ??%";
            buf.setString(rect.x + rect.width -| pct_w, y, pct_str, _Style{ .fg = line.color });
        } else if (bar_w > 0) {
            // Draw box-bar meter after label
            renderBoxBar(buf, rect.x + label_w, y, bar_w, pct, 100.0, line.color);

            // Value after bar
            var val_buf: [12]u8 = undefined;
            const val_str = formatBytes(&val_buf, line.value);
            buf.setString(rect.x + label_w + bar_w + 1, y, val_str, _Style{ .fg = line.color });

            // Percentage at right edge
            var pct_buf: [5]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch " ??%";
            buf.setString(rect.x + rect.width -| pct_w, y, pct_str, _Style{ .fg = line.color });
        }

        y += 1;
    }
}

fn diskPercentColor(pct: f32) _Color {
    if (pct >= 90.0) return .red;
    if (pct >= 70.0) return .yellow;
    return .green;
}

fn renderDisksPane(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (sys.mount_count == 0 or rect.height == 0) {
        buf.setString(rect.x, rect.y, "No disks", _Style{ .fg = .gray });
        return;
    }

    const DASH: u21 = 0x2500; // ─ horizontal dash
    var y: u16 = rect.y;
    const max_y = rect.y + rect.height;
    const pct_reserve: u16 = 5; // " NN%" = space + 3-digit + %

    var mount_idx: u32 = 0;
    while (mount_idx < sys.mount_count) : (mount_idx += 1) {
        const mount = sys.mounts[mount_idx];
        // Each disk needs 2 lines minimum
        if (y >= max_y) break;
        if (y + 1 >= max_y and mount.total_bytes > 0) break;

        const name = mount.name[0..mount.name_len];
        const name_len: u16 = @intCast(name.len);

        // Line 1: name (bold) ─── total_size (gray)
        const name_display_len = @min(name_len, rect.width -| 1);
        buf.setString(rect.x, y, name[0..name_display_len], _Style{ .fg = .light_white, .modifier = _Modifier{ .bold = true } });

        var total_buf: [12]u8 = undefined;
        const total_str = formatBytes(&total_buf, mount.total_bytes);
        const total_len: u16 = @intCast(total_str.len);
        const total_x = rect.x + rect.width -| total_len;
        buf.setString(total_x, y, total_str, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });

        // Fill dashes between name and total size (with 1-char gap each side)
        const dash_start = rect.x + name_display_len + 1;
        const dash_end = if (total_x > 0) total_x -| 1 else total_x;
        if (dash_end > dash_start) {
            var dx: u16 = dash_start;
            while (dx <= dash_end) : (dx += 1) {
                buf.setChar(dx, y, DASH, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            }
        }
        y += 1;

        if (y >= max_y) break;

        // Line 2: full-width bar with used bytes and percentage
        if (mount.total_bytes > 0) {
            const pct: f32 = @as(f32, @floatFromInt(mount.used_bytes)) / @as(f32, @floatFromInt(mount.total_bytes)) * 100.0;
            const color = diskPercentColor(pct);

            // Format used bytes
            var used_buf: [12]u8 = undefined;
            const used_str = formatBytes(&used_buf, mount.used_bytes);

            // Adaptive: if width < 35, show only bar + percent (skip used label)
            if (rect.width < 35) {
                // Discrete box grid bar, percentage at right
                const bar_w = rect.width -| pct_reserve;
                if (bar_w > 0) {
                    renderBoxBar(buf, rect.x, y, bar_w, pct, 100.0, color);
                }

                // " NN%" right-aligned
                var pct_buf: [5]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, " {d:>3.0}%", .{pct}) catch " ??%";
                buf.setString(rect.x + rect.width -| pct_reserve, y, pct_str, _Style{ .fg = color });
            } else {
                // Format: bar + "  X.X GiB used" + percentage
                const used_label_w: u16 = @intCast(used_str.len + 6); // " used " = 6 chars
                const bar_w = rect.width -| (used_label_w + pct_reserve);

                if (bar_w > 0) {
                    renderBoxBar(buf, rect.x, y, bar_w, pct, 100.0, color);
                }

                // Used bytes label after bar
                const used_x = rect.x + bar_w + 1;
                buf.setString(used_x, y, used_str, _Style{ .fg = color });
                buf.setString(used_x + @as(u16, @intCast(used_str.len)), y, " used", _Style{ .fg = .gray });

                // " NN%" right-aligned
                var pct_buf: [5]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, " {d:>3.0}%", .{pct}) catch " ??%";
                buf.setString(rect.x + rect.width -| pct_reserve, y, pct_str, _Style{ .fg = color });
            }
        }
        y += 1;

        // Add blank line between disks if space allows and more disks follow
        if (mount_idx + 1 < sys.mount_count and y + 2 < max_y) {
            y += 1;
        }
    }
}

/// Combined Memory + Disks pane (bpytop MemBox style)
fn renderMemoryAndDisksPane(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting...", _Style{ .fg = .gray });
        return;
    }

    // Memory-only pane with 2-column layout (disks are now shown in Disk IO overlay)
    renderMemorySection2Col(buf, rect, sys);
}

/// Render memory section for combined pane
fn renderMemorySection(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState, max_lines: u16) void {
    const mem_total_f: f32 = @floatFromInt(sys.mem_total);
    if (mem_total_f == 0) return;

    const MemLine = struct {
        label: []const u8,
        value: u64,
        color: _Color,
    };

    const lines = [4]MemLine{
        .{ .label = "Used", .value = sys.mem_used, .color = memPercentColor(@as(f32, @floatFromInt(sys.mem_used)) / mem_total_f * 100.0) },
        .{ .label = "Available", .value = sys.mem_available, .color = .cyan },
        .{ .label = "Cached", .value = sys.mem_cached, .color = .blue },
        .{ .label = "Free", .value = sys.mem_free, .color = .cyan },
    };

    var y: u16 = rect.y;
    const max_y = rect.y + rect.height;
    const show_lines: usize = @min(@as(usize, max_lines), 4);

    const label_w: u16 = 10;
    const value_w: u16 = 10;
    const pct_w: u16 = 5;

    for (lines[0..show_lines]) |line| {
        if (y >= max_y) break;

        const pct: f32 = @as(f32, @floatFromInt(line.value)) / mem_total_f * 100.0;

        buf.setString(rect.x, y, line.label, _Style{ .fg = line.color, .modifier = _Modifier{ .bold = true } });

        const bar_w = rect.width -| (label_w + value_w + pct_w);

        if (rect.width < 30) {
            var pct_buf: [5]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch " ??%";
            buf.setString(rect.x + rect.width -| pct_w, y, pct_str, _Style{ .fg = line.color });
        } else if (bar_w > 0) {
            renderBoxBar(buf, rect.x + label_w, y, bar_w, pct, 100.0, line.color);

            var val_buf: [12]u8 = undefined;
            const val_str = formatBytes(&val_buf, line.value);
            buf.setString(rect.x + label_w + bar_w + 1, y, val_str, _Style{ .fg = line.color });

            var pct_buf: [5]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch " ??%";
            buf.setString(rect.x + rect.width -| pct_w, y, pct_str, _Style{ .fg = line.color });
        }

        y += 1;
    }
}

/// Render memory section in 2-column layout (Used/Available, Cached/Free)
fn renderMemorySection2Col(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    const mem_total_f: f32 = @floatFromInt(sys.mem_total);
    if (mem_total_f == 0) return;

    const MemLine = struct {
        label: []const u8,
        value: u64,
        color: _Color,
    };

    const lines = [4]MemLine{
        .{ .label = "Used", .value = sys.mem_used, .color = memPercentColor(@as(f32, @floatFromInt(sys.mem_used)) / mem_total_f * 100.0) },
        .{ .label = "Avail", .value = sys.mem_available, .color = .cyan },
        .{ .label = "Cache", .value = sys.mem_cached, .color = .blue },
        .{ .label = "Free", .value = sys.mem_free, .color = .cyan },
    };

    // 2-column layout: each column shows label + bar + value + %
    const col_gap: u16 = 2;
    const col_w: u16 = (rect.width -| col_gap) / 2;
    const label_w: u16 = 6; // "Used  " etc
    const pct_w: u16 = 5; // " NNN%"
    const val_w: u16 = 7; // " X.X GB"
    const bar_w: u16 = if (col_w > label_w + val_w + pct_w) col_w -| label_w -| val_w -| pct_w else 0;

    // Row 0: Used (col 0), Available (col 1)
    // Row 1: Cached (col 0), Free (col 1)
    var row: u16 = 0;
    while (row < 2 and rect.y + row < rect.y + rect.height) : (row += 1) {
        var col: u16 = 0;
        while (col < 2) : (col += 1) {
            const idx = row * 2 + col;
            if (idx >= 4) break;

            const line = lines[idx];
            const col_x = rect.x + col * (col_w + col_gap);
            const y = rect.y + row;
            const pct: f32 = @as(f32, @floatFromInt(line.value)) / mem_total_f * 100.0;

            // Label
            buf.setString(col_x, y, line.label, _Style{ .fg = line.color, .modifier = _Modifier{ .bold = true } });

            // Bar (if space)
            if (bar_w > 0) {
                renderBoxBar(buf, col_x + label_w, y, bar_w, pct, 100.0, line.color);
            }

            // Value
            var val_buf: [8]u8 = undefined;
            const val_str = formatBytesShort(&val_buf, line.value);
            buf.setString(col_x + label_w + bar_w, y, val_str, _Style{ .fg = line.color });

            // Percentage
            var pct_buf: [5]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>3.0}%", .{pct}) catch "??%";
            const pct_x = col_x + col_w -| pct_w;
            buf.setString(pct_x, y, pct_str, _Style{ .fg = line.color });
        }
    }
}

/// Render disks section for combined pane (compact format)
fn renderDisksSection(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (sys.mount_count == 0 or rect.height == 0) return;

    const DASH: u21 = 0x2500;
    var y: u16 = rect.y;
    const max_y = rect.y + rect.height;
    const pct_reserve: u16 = 5;

    var mount_idx: u32 = 0;
    while (mount_idx < sys.mount_count) : (mount_idx += 1) {
        const mount = sys.mounts[mount_idx];
        if (y >= max_y) break;
        if (y + 1 >= max_y and mount.total_bytes > 0) break;

        const name = mount.name[0..mount.name_len];
        const name_len: u16 = @intCast(name.len);

        // Line 1: name ─── total_size
        const name_display_len = @min(name_len, rect.width -| 1);
        buf.setString(rect.x, y, name[0..name_display_len], _Style{ .fg = .light_white, .modifier = _Modifier{ .bold = true } });

        var total_buf: [12]u8 = undefined;
        const total_str = formatBytes(&total_buf, mount.total_bytes);
        const total_len: u16 = @intCast(total_str.len);
        const total_x = rect.x + rect.width -| total_len;
        buf.setString(total_x, y, total_str, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });

        const dash_start = rect.x + name_display_len + 1;
        const dash_end = if (total_x > 0) total_x -| 1 else total_x;
        if (dash_end > dash_start) {
            var dx: u16 = dash_start;
            while (dx <= dash_end) : (dx += 1) {
                buf.setChar(dx, y, DASH, _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            }
        }
        y += 1;

        if (y >= max_y) break;

        // Line 2: bar with usage
        if (mount.total_bytes > 0) {
            const pct: f32 = @as(f32, @floatFromInt(mount.used_bytes)) / @as(f32, @floatFromInt(mount.total_bytes)) * 100.0;
            const color = diskPercentColor(pct);

            var used_buf: [12]u8 = undefined;
            const used_str = formatBytes(&used_buf, mount.used_bytes);

            if (rect.width < 35) {
                const bar_w = rect.width -| pct_reserve;
                if (bar_w > 0) {
                    renderBoxBar(buf, rect.x, y, bar_w, pct, 100.0, color);
                }
                var pct_buf: [5]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, " {d:>3.0}%", .{pct}) catch " ??%";
                buf.setString(rect.x + rect.width -| pct_reserve, y, pct_str, _Style{ .fg = color });
            } else {
                const used_label_w: u16 = @intCast(used_str.len + 6);
                const bar_w = rect.width -| (used_label_w + pct_reserve);

                if (bar_w > 0) {
                    renderBoxBar(buf, rect.x, y, bar_w, pct, 100.0, color);
                }

                const used_x = rect.x + bar_w + 1;
                buf.setString(used_x, y, used_str, _Style{ .fg = color });
                buf.setString(used_x + @as(u16, @intCast(used_str.len)), y, " used", _Style{ .fg = .gray });

                var pct_buf: [5]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, " {d:>3.0}%", .{pct}) catch " ??%";
                buf.setString(rect.x + rect.width -| pct_reserve, y, pct_str, _Style{ .fg = color });
            }
        }
        y += 1;

        // Skip blank lines between disks in compact mode to save space
    }
}

// 1/8th-width block characters for sub-cell precision bars (index 0 = 1/8, index 7 = full)
const partial_blocks = [8]u21{ 0x258F, 0x258E, 0x258D, 0x258C, 0x258B, 0x258A, 0x2589, 0x2588 };
const EMPTY_SHADE: u21 = 0x2591; // ░ light shade for unfilled bar cells
const FULL_BLOCK: u21 = 0x2588; // █ full block

/// Discrete box-grid bar (btop style): N small squares, filled ones colored, empty ones gray.
fn renderBoxBar(buf: *tui.render.Buffer, x: u16, y: u16, width: u16, value: f32, max_val: f32, color: _Color) void {
    const BOX_FILLED: u21 = 0x25A0; // ■ BLACK SMALL SQUARE
    const BOX_EMPTY: u21 = 0x25A1; // □ WHITE SMALL SQUARE
    if (width == 0) return;
    const ratio = @min(value / max_val, 1.0);
    const filled: u16 = @intFromFloat(@round(ratio * @as(f32, @floatFromInt(width))));

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            buf.setChar(x + i, y, BOX_FILLED, _Style{ .fg = color });
        } else {
            buf.setChar(x + i, y, BOX_EMPTY, _Style{ .fg = .gray });
        }
    }
}

fn renderBar(buf: *tui.render.Buffer, x: u16, y: u16, width: u16, value: f32, max_val: f32, color: _Color) void {
    if (width == 0) return;
    const ratio = @min(value / max_val, 1.0);
    const fill_eighths: u32 = @intFromFloat(ratio * @as(f32, @floatFromInt(width)) * 8.0);
    const full_cells: u16 = @intCast(fill_eighths / 8);
    const remainder: u3 = @intCast(fill_eighths % 8);

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        if (i < full_cells) {
            buf.setChar(x + i, y, FULL_BLOCK, _Style{ .fg = color });
        } else if (i == full_cells and remainder > 0) {
            buf.setChar(x + i, y, partial_blocks[remainder - 1], _Style{ .fg = color });
        } else {
            buf.setChar(x + i, y, EMPTY_SHADE, _Style{ .fg = .gray });
        }
    }
}

/// Compact rate format for tight spaces: "5.1M", "120K", "0B"
fn formatRateShort(out_buf: *[8]u8, rate: f64) []const u8 {
    if (rate >= 1024.0 * 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:.1}G", .{rate / (1024.0 * 1024.0 * 1024.0)}) catch "?G";
    } else if (rate >= 1024.0 * 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:.1}M", .{rate / (1024.0 * 1024.0)}) catch "?M";
    } else if (rate >= 1024.0) {
        return std.fmt.bufPrint(out_buf, "{d:.0}K", .{rate / 1024.0}) catch "?K";
    } else {
        return std.fmt.bufPrint(out_buf, "{d:.0}B", .{rate}) catch "0B";
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
    guides: []const bool,
) u16 {
    if (row.depth == 0) {
        // Root nodes: just expand/collapse glyph + space
        if (max_width < 2) return 0;
        const glyph: u21 = if (row.has_children) (if (row.is_expanded) 0x25BC else 0x25B6) else ' ';
        buf.setChar(x, y, glyph, style);
        buf.setChar(x + 1, y, ' ', style);
        return 2;
    }

    // Each depth level takes 2 columns; glyph + space = 2 more
    const total: u16 = row.depth * 2 + 2;
    if (total > max_width) {
        // Fallback: just show glyph if no room for tree lines
        if (max_width >= 2) {
            const glyph: u21 = if (row.has_children) (if (row.is_expanded) 0x25BC else 0x25B6) else ' ';
            buf.setChar(x, y, glyph, style);
            buf.setChar(x + 1, y, ' ', style);
            return 2;
        }
        return 0;
    }

    var cx: u16 = x;

    // Draw ancestor continuation lines
    var d: u16 = 0;
    while (d < row.depth - 1) : (d += 1) {
        if (d < guides.len and guides[d]) {
            buf.setChar(cx, y, 0x2502, style); // │
            buf.setChar(cx + 1, y, ' ', style);
        } else {
            buf.setChar(cx, y, ' ', style);
            buf.setChar(cx + 1, y, ' ', style);
        }
        cx += 2;
    }

    // Draw connector at current depth
    if (row.is_last) {
        buf.setChar(cx, y, 0x2514, style); // └
    } else {
        buf.setChar(cx, y, 0x251C, style); // ├
    }
    buf.setChar(cx + 1, y, 0x2500, style); // ─
    cx += 2;

    // Expand/collapse glyph
    const glyph: u21 = if (row.has_children) (if (row.is_expanded) 0x25BC else 0x25B6) else ' ';
    buf.setChar(cx, y, glyph, style);
    buf.setChar(cx + 1, y, ' ', style);
    cx += 2;

    return cx - x;
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
    if (std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ visible, total })) |slice| {
        buf.setString(x, rect.y, slice, _Style{ .fg = .light_white });
        x += @intCast(slice.len);
    } else |_| {}
    buf.setString(x, rect.y, " shown", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
    x += 6;

    // Separator
    buf.setString(x, rect.y, " | ", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
    x += 3;

    // Segment 2: last update (green if fresh, yellow if stale, gray if old)
    if (app.last_update_ns > 0) {
        const now = std.time.nanoTimestamp();
        const delta_ns = now - app.last_update_ns;
        const delta_s: u64 = @intCast(@max(0, @divTrunc(delta_ns, std.time.ns_per_s)));
        const update_style: _Style = if (delta_s < 5) .{ .fg = .green } else if (delta_s < 15) .{ .fg = .yellow } else .{ .fg = .gray };
        var update_buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&update_buf, "updated {d}s", .{delta_s})) |slice| {
            buf.setString(x, rect.y, slice, update_style);
            x += @intCast(slice.len);
        } else |_| {}
        buf.setString(x, rect.y, " ago", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
        x += 4;
    } else {
        buf.setString(x, rect.y, "no data", _Style{ .fg = .gray });
        x += 7;
    }

    // Separator
    buf.setString(x, rect.y, " | ", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
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

    // Segment 4: selection indicator (when items are pinned/selected)
    const selected_count = app.getSelectedCount();
    if (selected_count > 0) {
        buf.setString(x, rect.y, " | ", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
        x += 3;

        // Count with highlight
        var sel_buf: [16]u8 = undefined;
        if (std.fmt.bufPrint(&sel_buf, "{d}", .{selected_count})) |slice| {
            buf.setString(x, rect.y, slice, _Style{ .fg = .light_magenta, .modifier = _Modifier{ .bold = true } });
            x += @intCast(slice.len);
        } else |_| {}
        buf.setString(x, rect.y, " selected ", _Style{ .fg = .light_magenta });
        x += 10;

        // Clear hint
        buf.setString(x, rect.y, "[", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
        x += 1;
        buf.setString(x, rect.y, "c", _Style{ .fg = .light_cyan });
        x += 1;
        buf.setString(x, rect.y, "/", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
        x += 1;
        buf.setString(x, rect.y, "esc", _Style{ .fg = .light_cyan });
        x += 3;
        buf.setString(x, rect.y, ":clear]", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
        x += 7;
    }

    // Segment 5 (search_view only): search query + esc hint
    if (app.mode == .search_view) {
        const query = app.searchSlice();
        if (query.len > 0) {
            buf.setString(x, rect.y, " | ", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            x += 3;
            var search_buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&search_buf, "search: \"{s}\"", .{query})) |slice| {
                buf.setString(x, rect.y, slice, _Style{ .fg = .light_yellow });
                x += @intCast(slice.len);
            } else |_| {}
            // ESC hint to clear search
            buf.setString(x, rect.y, " ", _Style{});
            x += 1;
            buf.setString(x, rect.y, "esc", _Style{ .fg = .light_cyan });
            x += 3;
            buf.setString(x, rect.y, ":clear", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            x += 6;
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

fn renderDetailView(buf: *tui.render.Buffer, area: tui.render.Rect, app: *state.AppState) void {
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

    // Border with view mode indicator
    const mode_title: []const u8 = if (app.detail_view_mode == .info) "Process Detail - Info" else "Process Detail - Network";
    const block = tui.widgets.Block{
        .title = mode_title,
        .borders = tui.widgets.Borders.all(),
        .border_style = _Style{ .fg = .cyan },
    };
    block.render(modal, buf);

    // Add view mode tabs on title bar: [Info] [Network] with current highlighted
    const tabs_x = modal.x + modal.width -| 22;
    if (app.detail_view_mode == .info) {
        // Info is active
        buf.setString(tabs_x, modal.y, "[", _Style{ .fg = .cyan });
        buf.setString(tabs_x + 1, modal.y, "Info", _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
        buf.setString(tabs_x + 5, modal.y, "]", _Style{ .fg = .cyan });
        buf.setString(tabs_x + 7, modal.y, "[", _Style{ .fg = .gray });
        buf.setString(tabs_x + 8, modal.y, "v", _Style{ .fg = .light_cyan });
        buf.setString(tabs_x + 9, modal.y, ":Net]", _Style{ .fg = .gray });
    } else {
        // Network is active
        buf.setString(tabs_x, modal.y, "[", _Style{ .fg = .gray });
        buf.setString(tabs_x + 1, modal.y, "v", _Style{ .fg = .light_cyan });
        buf.setString(tabs_x + 2, modal.y, ":Info]", _Style{ .fg = .gray });
        buf.setString(tabs_x + 9, modal.y, "[", _Style{ .fg = .cyan });
        buf.setString(tabs_x + 10, modal.y, "Net", _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
        buf.setString(tabs_x + 13, modal.y, "]", _Style{ .fg = .cyan });
    }

    // Page layout inside border (2-char horizontal padding, 1-char vertical)
    const pad_x: u16 = 3;
    const pad_y: u16 = 1;
    const page_rects = layout.calculate(detail_page_layout, .{
        .x = modal.x + pad_x,
        .y = modal.y + pad_y,
        .width = modal.width -| (pad_x * 2),
        .height = modal.height -| (pad_y * 2),
    });

    const header_rect = page_rects[0];
    const body_rect = page_rects[1];
    const footer_rect = page_rects[2];

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

    // --- Body rendering depends on view mode ---
    if (app.detail_view_mode == .network) {
        // Network view: show only connections in full body area
        renderDetailNetworkView(buf, body_rect, app);
    } else {
        // Info view: two-pane split (3:divider:2 left:right)
        const body_rects = layout.calculate(detail_body_layout, body_rect);

        const left_rect = body_rects[0];
        const div_rect = body_rects[1];
        const right_rect = body_rects[2];

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

        // Split right pane: static stats on top, scrollable content below
        const right_rects = layout.calculate(detail_right_layout, right_rect);

        const stats_rect = right_rects[0];
        const content_rect = right_rects[1];

        const left_focused = app.detail_focus == .left;

        // Render static live stats (never focused - it's not selectable)
        renderDetailStats(buf, stats_rect, detail, live_cpu, live_mem, false);

        // Measure right pane content for scroll clamping
        const tree_info = renderDetailTreeAndFiles(buf, content_rect, detail, app, true, false);
        const right_content_lines = tree_info.total_lines;
        const right_visible: usize = @intCast(content_rect.height);

        // Clamp scroll to valid range
        if (right_content_lines > right_visible) {
            app.detail_right_scroll = @min(app.detail_right_scroll, right_content_lines - right_visible);
        } else {
            app.detail_right_scroll = 0;
        }

        // Render accordion content for right pane
        _ = renderDetailTreeAndFiles(buf, content_rect, detail, app, false, !left_focused);

        // Render left pane
        renderDetailLeftPane(buf, left_rect, detail, app.detail_scroll, left_focused);

        // --- Scroll arrows ---
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
            // Right pane scroll arrows
            if (app.detail_right_scroll > 0) {
                const arrow_x = content_rect.x + content_rect.width -| 1;
                buf.setString(arrow_x, content_rect.y, "^", _Style{ .fg = .cyan });
            }
            if (right_content_lines > right_visible and app.detail_right_scroll + right_visible < right_content_lines) {
                const arrow_x = content_rect.x + content_rect.width -| 1;
                const arrow_y = content_rect.y + content_rect.height -| 1;
                buf.setString(arrow_x, arrow_y, "v", _Style{ .fg = .cyan });
            }
        }
    }

    // --- Footer keybinds ---
    const footer_hint = if (app.detail_view_mode == .network)
        "esc:close  v:info  j/k:scroll  u/d:page  s:suspend  r:resume  x:kill"
    else
        "esc:close  v:network  h/l:pane  j/k:nav  tab:fold  s:suspend  x:kill";
    buf.setString(footer_rect.x, footer_rect.y, footer_hint, _Style{ .fg = .gray });
}

/// Format an address:port string from TcpConnection address data
fn formatConnAddr(addr: []const u8, port: u16, out: *[64]u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}:{d}", .{ addr, port }) catch "*:0";
}

/// Helper to render a single TCP connection row
fn renderTcpConnection(
    buf: *tui.render.Buffer,
    rect: layout.Rect,
    conn: model.TcpConnection,
    ln: *usize,
    vis_start: usize,
    vis_end: usize,
    max_w: usize,
    proc_name: ?[]const u8, // If set, show process name (for XPC service connections)
) void {
    if (ln.* >= vis_start and ln.* < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln.* - vis_start));

        // Protocol
        buf.setString(rect.x, y, "tcp", _Style{ .fg = .green });

        // State with color
        const state_label = conn.state.label();
        const state_color: _Color = switch (conn.state) {
            .established => .green,
            .listen => .cyan,
            .time_wait, .fin_wait_1, .fin_wait_2, .closing, .last_ack => .yellow,
            .close_wait => .light_red,
            .syn_sent, .syn_received => .light_blue,
            .closed => .gray,
            .unknown => .gray,
        };
        buf.setString(rect.x + 6, y, state_label, _Style{ .fg = state_color });

        // Local address (format: addr:port)
        var local_buf: [64]u8 = undefined;
        const local_addr_slice = conn.local_addr[0..conn.local_addr_len];
        const local_str = std.fmt.bufPrint(&local_buf, "{s}:{d}", .{ local_addr_slice, conn.local_port }) catch "";
        const local_max: usize = 22;
        const local_len = @min(local_str.len, local_max);
        if (local_len > 0) {
            buf.setString(rect.x + 18, y, local_str[0..local_len], _Style{ .fg = .white });
        }

        // Remote address - always show the actual endpoint
        var remote_buf: [64]u8 = undefined;
        const remote_addr_slice = conn.remote_addr[0..conn.remote_addr_len];
        const remote_str = std.fmt.bufPrint(&remote_buf, "{s}:{d}", .{ remote_addr_slice, conn.remote_port }) catch "";
        const remote_max: usize = 22;
        const remote_len = @min(remote_str.len, remote_max);
        if (remote_len > 0) {
            buf.setString(rect.x + 42, y, remote_str[0..remote_len], _Style{ .fg = .light_white });
        }

        // For XPC service connections, show the owning process name after remote
        if (proc_name) |name| {
            const col_offset: usize = 42 + @as(usize, remote_len) + 1;
            const via_x = rect.x +| @as(u16, @intCast(@min(col_offset, 200)));
            if (via_x + 5 < rect.x + rect.width) {
                buf.setString(via_x, y, "via", _Style{ .fg = .gray });
                const name_x = via_x + 4;
                const remaining = max_w -| (col_offset + 4);
                const name_max: usize = @min(remaining, 20);
                const name_len = @min(name.len, name_max);
                if (name_len > 0 and name_x < rect.x + rect.width) {
                    buf.setString(name_x, y, name[0..name_len], _Style{ .fg = .cyan });
                }
            }
        }
    }
    ln.* += 1;
}

/// Render the network connections view (detail mode, network tab)
fn renderDetailNetworkView(buf: *tui.render.Buffer, rect: layout.Rect, app: *state.AppState) void {
    const header_style = _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } };
    const dim_style = _Style{ .fg = .gray };

    // Show loading indicator only on first load (no data yet)
    // Once we have data, keep showing it during background refreshes (no jitter)
    if (app.tcp_pending and app.last_tcp_collect_ns == 0) {
        buf.setString(rect.x, rect.y, "Loading network connections...", _Style{ .fg = .yellow });
        return;
    }

    // Get the detail process's coalition ID for grouping with XPC services
    // Also update connection history for preserve log feature
    const detail_pid = app.detail_pid orelse 0;
    const detail_coalition_id = blk: {
        if (app.procs.pid_to_index.get(detail_pid)) |idx| {
            break :blk app.procs.cold.items(.coalition_id)[idx];
        }
        break :blk @as(u64, 0);
    };

    // Update connection history (for preserve log feature)
    app.updateConnectionHistory(detail_pid, detail_coalition_id);

    // Count TCP connections from sysctl data
    const all_tcp = app.system.tcp_connections[0..app.system.tcp_connection_count];
    var direct_tcp_count: usize = 0; // This process's connections
    var coalition_tcp_count: usize = 0; // XPC service connections (same coalition)
    for (all_tcp) |conn| {
        if (conn.pid == detail_pid) {
            direct_tcp_count += 1;
        } else if (detail_coalition_id != 0 and conn.coalition_id == detail_coalition_id) {
            coalition_tcp_count += 1;
        }
    }
    const sysctl_tcp_count = direct_tcp_count + coalition_tcp_count;

    const files = app.detail_open_files;
    const has_files = files != null and files.?.len > 0;

    // Count sockets by type from proc_pidinfo
    var proc_tcp_count: usize = 0;
    var udp_count: usize = 0;
    var unix_count: usize = 0;
    if (has_files) {
        for (files.?) |f| {
            if (f.fd_type == .socket_tcp) proc_tcp_count += 1;
            if (f.fd_type == .socket_udp) udp_count += 1;
            if (f.fd_type == .socket_unix) unix_count += 1;
        }
    }

    // Use sysctl TCP if proc_pidinfo didn't find any (sandboxed apps)
    const tcp_count = if (proc_tcp_count > 0) proc_tcp_count else sysctl_tcp_count;
    const use_sysctl_tcp = proc_tcp_count == 0 and sysctl_tcp_count > 0;

    if (!has_files and sysctl_tcp_count == 0) {
        buf.setString(rect.x, rect.y, "No open file descriptors found", dim_style);
        buf.setString(rect.x, rect.y + 1, "(checked process + all descendants)", dim_style);
        if (rect.height > 3) {
            buf.setString(rect.x, rect.y + 3, "Sandboxed apps (Safari, Mail) delegate networking", _Style{ .fg = .yellow });
            buf.setString(rect.x, rect.y + 4, "to XPC services. Search for 'WebKit' or 'Network'", _Style{ .fg = .yellow });
            buf.setString(rect.x, rect.y + 5, "in the process list to find them.", _Style{ .fg = .yellow });
        }
        return;
    }

    const file_list = if (has_files) files.? else &[_]model.OpenFile{};

    // Apply protocol filter to determine what to show
    const filter = app.network_protocol_filter;
    const show_tcp = (filter == .all or filter == .tcp);
    const show_udp = (filter == .all or filter == .udp);
    const show_unix = (filter == .all or filter == .unix);

    const filtered_count = (if (show_tcp) tcp_count else 0) +
        (if (show_udp) udp_count else 0) +
        (if (show_unix) unix_count else 0);

    if (filtered_count == 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = if (filter == .all)
            "No network connections"
        else
            std.fmt.bufPrint(&msg_buf, "No {s} connections", .{filter.label()}) catch "No connections";
        buf.setString(rect.x, rect.y, msg, dim_style);
        buf.setString(rect.x, rect.y + 1, "(process has other file descriptors but no matching sockets)", dim_style);
        if (rect.height > 3) {
            buf.setString(rect.x, rect.y + 3, "Sandboxed apps delegate networking to XPC services.", _Style{ .fg = .yellow });
            buf.setString(rect.x, rect.y + 4, "Try searching for related service processes.", _Style{ .fg = .yellow });
        }
        return;
    }

    var ln: usize = 0;
    // Clamp scroll to prevent overflow - use saturating arithmetic
    const max_scroll: usize = std.math.maxInt(usize) - @as(usize, rect.height) - 1;
    const vis_start = @min(app.detail_scroll, max_scroll);
    const vis_end = vis_start +| @as(usize, @intCast(rect.height)); // saturating add
    const max_w: usize = @intCast(rect.width);

    // Header
    if (ln >= vis_start and ln < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "Network Connections", header_style);
        // Show source: sysctl (kernel tables) or proc_pidinfo (+ descendants)
        const source_label = if (use_sysctl_tcp) "(kernel)" else "(+ descendants)";
        const source_style = if (use_sysctl_tcp) _Style{ .fg = .cyan } else _Style{ .fg = .light_magenta };
        buf.setString(rect.x + 20, y, source_label, source_style);
        // Show counts, filter, and preserve log mode
        var count_buf: [64]u8 = undefined;
        const preserve_label = app.preserve_log.label();
        const count_str = std.fmt.bufPrint(&count_buf, " [{s}] {d} TCP, {d} UDP, {d} Unix  [p]reserve: {s}", .{ filter.label(), tcp_count, udp_count, unix_count, preserve_label }) catch "";
        buf.setString(rect.x + 36, y, count_str, dim_style);
    }
    ln += 1;

    // Column headers
    if (ln >= vis_start and ln < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "Proto", _Style{ .fg = .gray });
        buf.setString(rect.x + 6, y, "State", _Style{ .fg = .gray });
        buf.setString(rect.x + 18, y, "Local Address", _Style{ .fg = .gray });
        buf.setString(rect.x + 42, y, "Remote Address", _Style{ .fg = .gray });
    }
    ln += 1;

    // Separator
    if (ln >= vis_start and ln < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln - vis_start));
        var sep_buf: [128]u8 = undefined;
        const sep_w = @min(max_w, sep_buf.len);
        @memset(sep_buf[0..sep_w], '-');
        buf.setString(rect.x, y, sep_buf[0..sep_w], dim_style);
    }
    ln += 1;

    // Render TCP connections grouped by state (LISTEN first, then ESTABLISHED, then others)
    const state_order = [_]model.TcpState{ .listen, .established, .syn_sent, .syn_received, .close_wait, .fin_wait_1, .fin_wait_2, .time_wait, .closing, .last_ack, .closed, .unknown };

    if (show_tcp) {
        if (use_sysctl_tcp) {
            // Use sysctl data (works for sandboxed processes like WebKit)
            // First: render direct connections (pid == detail_pid)
            for (state_order) |target_state| {
                for (all_tcp) |conn| {
                    if (conn.pid != detail_pid) continue;
                    if (conn.state != target_state) continue;
                    renderTcpConnection(buf, rect, conn, &ln, vis_start, vis_end, max_w, null);
                }
            }

            // Second: render coalition connections (same coalition, different PID)
            if (coalition_tcp_count > 0 and detail_coalition_id != 0) {
                // Add separator label
                if (ln >= vis_start and ln < vis_end) {
                    const y = rect.y + @as(u16, @intCast(ln - vis_start));
                    buf.setString(rect.x, y, "--- via XPC Services ---", _Style{ .fg = .magenta });
                }
                ln += 1;

                for (state_order) |target_state| {
                    for (all_tcp) |conn| {
                        if (conn.pid == detail_pid) continue; // Skip direct
                        if (conn.coalition_id != detail_coalition_id) continue; // Must match coalition
                        if (conn.state != target_state) continue;

                        // Get process name for this PID
                        const proc_name = blk: {
                            if (app.procs.pid_to_index.get(conn.pid)) |idx| {
                                break :blk app.procs.cold.items(.name)[idx];
                            }
                            break :blk @as([]const u8, "");
                        };
                        renderTcpConnection(buf, rect, conn, &ln, vis_start, vis_end, max_w, proc_name);
                    }
                }
            }
        } else {
            // Use proc_pidinfo data (regular processes)
            for (state_order) |target_state| {
                for (file_list) |file| {
                    if (file.fd_type != .socket_tcp) continue;
                    if (file.tcp_state != target_state) continue;

                    if (ln >= vis_start and ln < vis_end) {
                        const y = rect.y + @as(u16, @intCast(ln - vis_start));

                        // Protocol
                        buf.setString(rect.x, y, "tcp", _Style{ .fg = .green });

                        // State with color
                        const state_label = file.tcp_state.label();
                        const state_color: _Color = switch (file.tcp_state) {
                            .established => .green,
                            .listen => .cyan,
                            .time_wait, .fin_wait_1, .fin_wait_2, .closing, .last_ack => .yellow,
                            .close_wait => .light_red,
                            .syn_sent, .syn_received => .light_blue,
                            .closed => .gray,
                            .unknown => .gray,
                        };
                        buf.setString(rect.x + 6, y, state_label, _Style{ .fg = state_color });

                        // Local address
                        const local_max: usize = 22;
                        const local_len = @min(file.local_addr.len, local_max);
                        if (local_len > 0) {
                            buf.setString(rect.x + 18, y, file.local_addr[0..local_len], _Style{ .fg = .white });
                        }

                        // Remote address
                        const remote_max: usize = @min(max_w -| 42, 30);
                        const remote_len = @min(file.remote_addr.len, remote_max);
                        if (remote_len > 0) {
                            buf.setString(rect.x + 42, y, file.remote_addr[0..remote_len], _Style{ .fg = .light_white });
                        }
                    }
                    ln += 1;
                }
            }
        }
    }

    // UDP sockets (no state)
    if (show_udp) {
        for (file_list) |file| {
            if (file.fd_type != .socket_udp) continue;

        if (ln >= vis_start and ln < vis_end) {
            const y = rect.y + @as(u16, @intCast(ln - vis_start));

            // Protocol
            buf.setString(rect.x, y, "udp", _Style{ .fg = .yellow });

            // State placeholder
            buf.setString(rect.x + 6, y, "-", dim_style);

            // Local address
            const local_max: usize = 22;
            const local_len = @min(file.local_addr.len, local_max);
            if (local_len > 0) {
                buf.setString(rect.x + 18, y, file.local_addr[0..local_len], _Style{ .fg = .white });
            }

            // Remote address
            const remote_max: usize = @min(max_w -| 42, 30);
            const remote_len = @min(file.remote_addr.len, remote_max);
            if (remote_len > 0) {
                buf.setString(rect.x + 42, y, file.remote_addr[0..remote_len], _Style{ .fg = .light_white });
            }
            }
            ln += 1;
        }
    }

    // Unix sockets - group by path and show counts
    if (show_unix) {
        // First pass: count unique paths
        const UnixEntry = struct { path: []const u8, count: usize };
        var unique_paths: [64]UnixEntry = undefined;
        var unique_count: usize = 0;

        for (file_list) |file| {
            if (file.fd_type != .socket_unix) continue;

            // Check if path already seen
            var found = false;
            for (unique_paths[0..unique_count]) |*entry| {
                if (std.mem.eql(u8, entry.path, file.path)) {
                    entry.count += 1;
                    found = true;
                    break;
                }
            }
            if (!found and unique_count < 64) {
                unique_paths[unique_count] = .{ .path = file.path, .count = 1 };
                unique_count += 1;
            }
        }

        // Second pass: render unique paths with counts
        for (unique_paths[0..unique_count]) |entry| {
            if (ln >= vis_start and ln < vis_end) {
                const y = rect.y + @as(u16, @intCast(ln - vis_start));

                // Protocol
                buf.setString(rect.x, y, "unix", _Style{ .fg = .magenta });

                // Count (if > 1)
                var count_offset: u16 = 6;
                if (entry.count > 1) {
                    var count_buf: [8]u8 = undefined;
                    const count_str = std.fmt.bufPrint(&count_buf, "({d})", .{entry.count}) catch "(??)";
                    buf.setString(rect.x + 5, y, count_str, _Style{ .fg = .yellow });
                    count_offset = 5 + @as(u16, @intCast(count_str.len)) + 1;
                }

                // Path or (anonymous)
                const path_x = rect.x + count_offset;
                const path_max: usize = @min(max_w -| count_offset, 50);
                if (entry.path.len > 0) {
                    const path_len = @min(entry.path.len, path_max);
                    buf.setString(path_x, y, entry.path[0..path_len], _Style{ .fg = .white });
                } else {
                    buf.setString(path_x, y, "(anonymous)", _Style{ .fg = .gray });
                }
            }
            ln += 1;
        }
    }

    // Historical connections (preserve log feature)
    if (app.preserve_log != .no) {
        const history = app.getDisplayConnections();
        var has_closed = false;

        // Check if there are any closed connections for this pid/coalition
        for (history) |hist| {
            if (!hist.is_active) {
                const dominated_by_pid = hist.conn.pid == detail_pid or
                    (detail_coalition_id != 0 and hist.conn.coalition_id == detail_coalition_id);
                if (dominated_by_pid) {
                    has_closed = true;
                    break;
                }
            }
        }

        if (has_closed) {
            // Section header
            if (ln >= vis_start and ln < vis_end) {
                const y = rect.y + @as(u16, @intCast(ln - vis_start));
                buf.setString(rect.x, y, "--- Closed Connections ---", _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } });
            }
            ln += 1;

            // Render closed connections
            const now_ns = std.time.nanoTimestamp();
            for (history) |hist| {
                if (hist.is_active) continue;
                const dominated_by_pid = hist.conn.pid == detail_pid or
                    (detail_coalition_id != 0 and hist.conn.coalition_id == detail_coalition_id);
                if (!dominated_by_pid) continue;

                if (ln >= vis_start and ln < vis_end) {
                    const y = rect.y + @as(u16, @intCast(ln - vis_start));
                    const closed_style = _Style{ .fg = .gray, .modifier = _Modifier{ .dim = true } };

                    // Show "x" prefix to indicate closed
                    buf.setString(rect.x, y, "x", _Style{ .fg = .red, .modifier = _Modifier{ .dim = true } });

                    // Protocol
                    buf.setString(rect.x + 2, y, "tcp", closed_style);

                    // State (CLOSED)
                    buf.setString(rect.x + 6, y, "CLOSED", closed_style);

                    // Local address
                    var local_buf: [64]u8 = undefined;
                    const local_str = formatConnAddr(hist.conn.local_addr[0..hist.conn.local_addr_len], hist.conn.local_port, &local_buf);
                    const local_max: usize = 22;
                    const local_len = @min(local_str.len, local_max);
                    buf.setString(rect.x + 18, y, local_str[0..local_len], closed_style);

                    // Remote address
                    var remote_buf: [64]u8 = undefined;
                    const remote_str = formatConnAddr(hist.conn.remote_addr[0..hist.conn.remote_addr_len], hist.conn.remote_port, &remote_buf);
                    const remote_max: usize = @min(max_w -| 42, 30);
                    const remote_len = @min(remote_str.len, remote_max);
                    buf.setString(rect.x + 42, y, remote_str[0..remote_len], closed_style);

                    // Show time since closed (if in fade mode)
                    if (app.preserve_log == .fade and hist.closed_at_ns > 0) {
                        const age_ns = now_ns - hist.closed_at_ns;
                        const age_s = @as(u32, @intCast(@divFloor(age_ns, std.time.ns_per_s)));
                        var age_buf: [16]u8 = undefined;
                        const age_str = std.fmt.bufPrint(&age_buf, " ({d}s)", .{age_s}) catch "";
                        const age_x = rect.x + 42 + @as(u16, @intCast(remote_len));
                        if (age_x + age_str.len < rect.x + rect.width) {
                            buf.setString(age_x, y, age_str, _Style{ .fg = .yellow, .modifier = _Modifier{ .dim = true } });
                        }
                    }
                }
                ln += 1;
            }
        }
    }

    // Clamp scroll
    const content_lines = ln;
    const visible: usize = @intCast(rect.height);
    if (content_lines > visible) {
        app.detail_scroll = @min(app.detail_scroll, content_lines - visible);
    } else {
        app.detail_scroll = 0;
    }

    // Scroll indicators
    if (app.detail_scroll > 0) {
        buf.setString(rect.x + rect.width -| 1, rect.y, "^", _Style{ .fg = .cyan });
    }
    if (content_lines > visible and app.detail_scroll + visible < content_lines) {
        buf.setString(rect.x + rect.width -| 1, rect.y + rect.height -| 1, "v", _Style{ .fg = .cyan });
    }
}

/// Render a label + value pair, wrapping the value to continuation lines if it
/// exceeds the available width. Continuation lines are indented to the value column.
fn renderWrappedField(
    buf: *tui.render.Buffer,
    rect_x: u16,
    rect_y: u16,
    label: []const u8,
    value: []const u8,
    label_w: u16,
    max_w: usize,
    lbl_style: _Style,
    val_style: _Style,
    vis_start: usize,
    vis_end: usize,
    ln: *usize,
) void {
    const vmax = max_w -| @as(usize, label_w);

    if (value.len == 0 or vmax == 0) {
        if (ln.* >= vis_start and ln.* < vis_end) {
            const y: u16 = rect_y + @as(u16, @intCast(ln.* - vis_start));
            buf.setString(rect_x, y, label, lbl_style);
        }
        ln.* += 1;
        return;
    }

    var offset: usize = 0;
    var is_first = true;
    while (offset < value.len) {
        const end = @min(offset + vmax, value.len);
        if (ln.* >= vis_start and ln.* < vis_end) {
            const y: u16 = rect_y + @as(u16, @intCast(ln.* - vis_start));
            if (is_first) {
                buf.setString(rect_x, y, label, lbl_style);
            }
            buf.setString(rect_x + label_w, y, value[offset..end], val_style);
        }
        offset = end;
        is_first = false;
        ln.* += 1;
    }
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

    renderWrappedField(buf, rect.x, rect.y, "  Executable: ", detail.path, 14, max_w, lbl, val, vis_start, vis_end, &ln);
    renderWrappedField(buf, rect.x, rect.y, "  Cmdline:    ", detail.cmdline, 14, max_w, lbl, val, vis_start, vis_end, &ln);
    renderWrappedField(buf, rect.x, rect.y, "  CWD:        ", detail.cwd, 14, max_w, lbl, val, vis_start, vis_end, &ln);

    var user_buf: [48]u8 = undefined;
    const user_str = std.fmt.bufPrint(&user_buf, "{s} (uid: {d})", .{ detail.user_name, detail.uid }) catch "???";
    renderWrappedField(buf, rect.x, rect.y, "  User:       ", user_str, 14, max_w, lbl, val, vis_start, vis_end, &ln);

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
    const cold_names = app.procs.cold.items(.name);
    const cold_ppids = app.procs.cold.items(.ppid);
    const cold_len = app.procs.cold.len;

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
            if (i >= cold_len) break;
            ancestor_pids[ancestor_count] = walk_pid;
            ancestor_names[ancestor_count] = cold_names[i];
            ancestor_count += 1;
            const next_ppid = cold_ppids[i];
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
    for (cold_ppids, cold_names, 0..) |ppid, name, i| {
        if (i >= pids.len) break;
        if (ppid == detail.pid) {
            if (!measure_only and ln >= vis_start and ln < vis_end) {
                const y = rect.y + @as(u16, @intCast(ln - vis_start));
                var child_line: [80]u8 = [_]u8{' '} ** 80;
                var fmt_buf: [64]u8 = undefined;
                const label = std.fmt.bufPrint(&fmt_buf, "{s} ({d})", .{ name, pids[i] }) catch "???";
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

/// Combined render function that shows process tree followed by open files
/// Uses accordion-style collapsible sections when content doesn't fit
fn renderDetailTreeAndFiles(buf: *tui.render.Buffer, rect: layout.Rect, detail: model.ProcessDetail, app: *state.AppState, measure_only: bool, focused: bool) TreeInfo {
    const lbl = _Style{ .fg = .gray };
    const val = _Style{ .fg = .light_white };
    const rx: u16 = rect.x + 1;
    const max_w: usize = @intCast(rect.width -| 1);
    const avail_height: usize = @intCast(rect.height);

    const pids = app.procs.hot.items(.pid);
    const cold_names = app.procs.cold.items(.name);
    const cold_ppids = app.procs.cold.items(.ppid);
    const cold_coalition_ids = app.procs.cold.items(.coalition_id);
    const cold_len = app.procs.cold.len;

    // === MEASURE PHASE: Calculate content heights for each section ===

    // Get current process's coalition_id
    const current_coalition_id: u64 = blk: {
        if (app.procs.pid_to_index.get(detail.pid)) |idx| {
            const i: usize = @intCast(idx);
            if (i < cold_len) {
                break :blk cold_coalition_ids[i];
            }
        }
        break :blk 0;
    };

    // Count coalition members (excluding self)
    var coalition_member_count: usize = 0;
    if (current_coalition_id != 0) {
        for (cold_coalition_ids, 0..) |cid, i| {
            if (i >= pids.len) break;
            if (cid == current_coalition_id and pids[i] != detail.pid) {
                coalition_member_count += 1;
            }
        }
    }

    // Calculate tree height (ancestors + self + children)
    var ancestor_count: usize = 0;
    var walk_pid = detail.ppid;
    while (ancestor_count < 64) {
        if (walk_pid <= 0) break;
        if (app.procs.pid_to_index.get(walk_pid)) |idx| {
            const i: usize = @intCast(idx);
            if (i >= cold_len) break;
            ancestor_count += 1;
            const next_ppid = cold_ppids[i];
            if (next_ppid == walk_pid) break;
            walk_pid = next_ppid;
        } else break;
    }

    var child_count: usize = 0;
    for (cold_ppids, 0..) |ppid, i| {
        if (i >= pids.len) break;
        if (ppid == detail.pid) child_count += 1;
    }

    // Calculate file count (excluding grouped entries)
    var file_lines: usize = 0;
    var pipe_count: usize = 0;
    var kqueue_count: usize = 0;
    var other_count: usize = 0;
    if (app.detail_open_files) |files| {
        for (files) |file| {
            const is_std_fd = file.fd == 0 or file.fd == 1 or file.fd == 2;
            switch (file.fd_type) {
                .pipe => {
                    if (!is_std_fd) {
                        pipe_count += 1;
                    } else {
                        file_lines += 1;
                    }
                },
                .kqueue => kqueue_count += 1,
                .other => other_count += 1,
                else => file_lines += 1,
            }
        }
        if (pipe_count > 0 or kqueue_count > 0 or other_count > 0) {
            file_lines += 1; // Summary line
        }
    }

    // Content heights (not including headers)
    const coalition_content_height: usize = coalition_member_count;
    const tree_content_height: usize = ancestor_count + 1 + @max(child_count, 1); // ancestors + self + children or "(no children)"
    const files_content_height: usize = if (app.detail_open_files != null) file_lines + 1 else 1; // +1 for column headers or error msg

    // Header heights (1 line each, plus 1 blank line between sections)
    const has_coalition = coalition_member_count > 0;
    const coalition_header_height: usize = if (has_coalition) 1 else 0;
    const tree_header_height: usize = 1;
    const files_header_height: usize = 1;

    // Total height if all expanded
    const total_height_expanded = coalition_header_height + coalition_content_height +
        (if (has_coalition) @as(usize, 1) else @as(usize, 0)) + // blank line after coalition
        tree_header_height + tree_content_height +
        1 + // blank line
        files_header_height + files_content_height;

    // Determine effective expanded state for each section (always respect user's state)
    const coalition_expanded = app.detail_sections_expanded.coalition;
    const tree_expanded = app.detail_sections_expanded.tree;
    const files_expanded = app.detail_sections_expanded.files;

    // Show accordion UI if any existing section is collapsed OR content doesn't fit when expanded
    const coalition_collapsed = has_coalition and !coalition_expanded;
    const any_collapsed = coalition_collapsed or !tree_expanded or !files_expanded;
    const needs_accordion = any_collapsed or (total_height_expanded > avail_height);

    // === RENDER PHASE ===
    var ln: usize = 0;
    var self_ln: usize = 0;

    // Scroll support
    const scroll = app.detail_right_scroll;
    const vis_start = scroll;
    const vis_end = scroll +| avail_height;

    // Helper to check if line is visible and get screen Y position
    const isVisible = struct {
        fn f(line: usize, start: usize, end: usize) bool {
            return line >= start and line < end;
        }
    }.f;

    const getScreenY = struct {
        fn f(line: usize, start: usize, base_y: u16) u16 {
            return base_y + @as(u16, @intCast(line - start));
        }
    }.f;

    // Helper for section header style
    // When left pane focused: all headers cyan (dimmed)
    // When right pane focused: selected section = yellow, others = gray
    const getSectionStyle = struct {
        fn f(right_pane_focused: bool, section: state.DetailSection, current_focus: state.DetailSection, show_accordion: bool) _Style {
            _ = show_accordion; // Always show selection, regardless of accordion state
            if (!right_pane_focused) {
                // Left pane has focus - all headers cyan (visible but not selected)
                return _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } };
            }
            // Right pane has focus - highlight selected section in yellow
            if (section == current_focus) {
                return _Style{ .fg = .light_yellow, .modifier = _Modifier{ .bold = true } };
            }
            return _Style{ .fg = .gray };
        }
    }.f;

    // === COALITION MEMBERS SECTION ===
    if (has_coalition) {
        if (!measure_only and isVisible(ln, vis_start, vis_end)) {
            const y = getScreenY(ln, vis_start, rect.y);
            const sec_style = getSectionStyle(focused, .coalition, app.detail_section_focus, needs_accordion);

            // Show fold indicator if accordion mode
            if (needs_accordion) {
                const indicator: []const u8 = if (coalition_expanded) "▼ " else "▶ ";
                buf.setString(rx, y, indicator, sec_style);
                var header_buf: [40]u8 = undefined;
                const header = std.fmt.bufPrint(&header_buf, "Coalition Members ({d})", .{coalition_member_count}) catch "Coalition Members";
                buf.setString(rx + 2, y, header, sec_style);
            } else {
                buf.setString(rx, y, "Coalition Members", sec_style);
            }
        }
        ln += 1;

        // Content (only if expanded)
        if (coalition_expanded) {
            for (cold_coalition_ids, cold_names, 0..) |cid, name, i| {
                if (i >= pids.len) break;
                if (cid == current_coalition_id and pids[i] != detail.pid) {
                    if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                        const y = getScreenY(ln, vis_start, rect.y);
                        var member_buf: [80]u8 = undefined;
                        const member_str = std.fmt.bufPrint(&member_buf, "  {s} ({d})", .{ name, pids[i] }) catch "  ???";
                        buf.setString(rx, y, member_str[0..@min(member_str.len, max_w)], val);
                    }
                    ln += 1;
                }
            }
        }

        // Blank line after coalition members
        ln += 1;
    }

    // === PROCESS TREE SECTION ===
    if (!measure_only and isVisible(ln, vis_start, vis_end)) {
        const y = getScreenY(ln, vis_start, rect.y);
        const sec_style = getSectionStyle(focused, .tree, app.detail_section_focus, needs_accordion);

        if (needs_accordion) {
            const indicator: []const u8 = if (tree_expanded) "▼ " else "▶ ";
            buf.setString(rx, y, indicator, sec_style);
            buf.setString(rx + 2, y, "Process Tree", sec_style);
        } else {
            buf.setString(rx, y, "Process Tree", sec_style);
        }
    }
    ln += 1;

    if (tree_expanded) {
        // Walk full ancestor chain
        const max_ancestors = 64;
        var ancestor_pids: [max_ancestors]model.pid_t = undefined;
        var ancestor_names: [max_ancestors][]const u8 = undefined;
        var actual_ancestor_count: usize = 0;
        walk_pid = detail.ppid;
        while (actual_ancestor_count < max_ancestors) {
            if (walk_pid <= 0) break;
            if (app.procs.pid_to_index.get(walk_pid)) |idx| {
                const i: usize = @intCast(idx);
                if (i >= cold_len) break;
                ancestor_pids[actual_ancestor_count] = walk_pid;
                ancestor_names[actual_ancestor_count] = cold_names[i];
                actual_ancestor_count += 1;
                const next_ppid = cold_ppids[i];
                if (next_ppid == walk_pid) break;
                walk_pid = next_ppid;
            } else break;
        }

        // Ancestors top-down (reverse the stack)
        var ai: usize = actual_ancestor_count;
        while (ai > 0) {
            ai -= 1;
            if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                const y = getScreenY(ln, vis_start, rect.y);
                const indent = actual_ancestor_count - 1 - ai;
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
        self_ln = ln;
        if (!measure_only and isVisible(ln, vis_start, vis_end)) {
            const y = getScreenY(ln, vis_start, rect.y);
            const indent = actual_ancestor_count * 2 + 2;
            var cur_buf: [80]u8 = [_]u8{' '} ** 80;
            var fmt_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&fmt_buf, "{s} ({d})", .{ detail.name, detail.pid }) catch "???";
            const start = @min(indent, cur_buf.len);
            const end = @min(start + label.len, cur_buf.len);
            @memcpy(cur_buf[start..end], label[0 .. end - start]);
            // Use cyan+bold for "current process being viewed" (not yellow - that's for section selection)
            buf.setString(rx, y, cur_buf[0..@min(end, max_w)], _Style{ .fg = .light_cyan, .modifier = _Modifier{ .bold = true } });
        }
        ln += 1;

        // Children
        const child_indent = actual_ancestor_count * 2 + 4;
        var rendered_children: u16 = 0;
        for (cold_ppids, cold_names, 0..) |ppid, name, i| {
            if (i >= pids.len) break;
            if (ppid == detail.pid) {
                if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                    const y = getScreenY(ln, vis_start, rect.y);
                    var child_line: [80]u8 = [_]u8{' '} ** 80;
                    var fmt_buf: [64]u8 = undefined;
                    const label = std.fmt.bufPrint(&fmt_buf, "{s} ({d})", .{ name, pids[i] }) catch "???";
                    const start = @min(child_indent, child_line.len);
                    const end = @min(start + label.len, child_line.len);
                    @memcpy(child_line[start..end], label[0 .. end - start]);
                    buf.setString(rx, y, child_line[0..@min(end, max_w)], val);
                }
                ln += 1;
                rendered_children += 1;
            }
        }
        if (rendered_children == 0) {
            if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                const y = getScreenY(ln, vis_start, rect.y);
                var no_child: [80]u8 = [_]u8{' '} ** 80;
                const msg = "(no children)";
                const start = @min(child_indent, no_child.len);
                const end = @min(start + msg.len, no_child.len);
                @memcpy(no_child[start..end], msg);
                buf.setString(rx, y, no_child[0..@min(end, max_w)], lbl);
            }
            ln += 1;
        }
    }

    // === SEPARATOR ===
    ln += 1; // blank line

    // === OPEN FILES SECTION ===
    if (!measure_only and isVisible(ln, vis_start, vis_end)) {
        const y = getScreenY(ln, vis_start, rect.y);
        const sec_style = getSectionStyle(focused, .files, app.detail_section_focus, needs_accordion);

        var file_count_buf: [32]u8 = undefined;
        const file_count = if (app.detail_open_files) |files| files.len else 0;

        if (needs_accordion) {
            const indicator: []const u8 = if (files_expanded) "▼ " else "▶ ";
            buf.setString(rx, y, indicator, sec_style);
            const header = std.fmt.bufPrint(&file_count_buf, "Open Files ({d})", .{file_count}) catch "Open Files";
            buf.setString(rx + 2, y, header, sec_style);
        } else {
            const header = std.fmt.bufPrint(&file_count_buf, "Open Files ({d})", .{file_count}) catch "Open Files";
            buf.setString(rx, y, header, sec_style);
        }
    }
    ln += 1;

    if (files_expanded) {
        // Column headers
        if (!measure_only and isVisible(ln, vis_start, vis_end)) {
            const y = getScreenY(ln, vis_start, rect.y);
            buf.setString(rx, y, "FD", lbl);
            buf.setString(rx + 5, y, "Type", lbl);
            buf.setString(rx + 14, y, "Path / Address", lbl);
        }
        ln += 1;

        // File rows
        if (app.detail_open_files) |files| {
            const path_x = rx + 14;
            const path_max: usize = if (max_w > 14) max_w - 14 else 1;

            // Re-count grouped entries
            var local_pipe_count: usize = 0;
            var local_kqueue_count: usize = 0;
            var local_other_count: usize = 0;
            for (files) |file| {
                switch (file.fd_type) {
                    .pipe => {
                        if (file.fd != 0 and file.fd != 1 and file.fd != 2) {
                            local_pipe_count += 1;
                        }
                    },
                    .kqueue => local_kqueue_count += 1,
                    .other => local_other_count += 1,
                    else => {},
                }
            }

            for (files) |file| {
                // Skip anonymous pipes (except stdin/stdout/stderr), kqueues, and other
                const is_std_fd = file.fd == 0 or file.fd == 1 or file.fd == 2;
                if (file.fd_type == .kqueue) continue;
                if (file.fd_type == .other) continue;
                if (file.fd_type == .pipe and !is_std_fd) continue;

                // Get the path/address string
                var addr_buf: [256]u8 = undefined;
                const path_str: []const u8 = if (file.fd_type == .socket_tcp or file.fd_type == .socket_udp) blk: {
                    const addr_str = std.fmt.bufPrint(&addr_buf, "{s} -> {s}", .{
                        if (file.local_addr.len > 0) file.local_addr else "?",
                        if (file.remote_addr.len > 0) file.remote_addr else "?",
                    }) catch "???";
                    break :blk addr_str;
                } else if (file.fd_type == .pipe and is_std_fd) blk: {
                    break :blk switch (file.fd) {
                        0 => "stdin",
                        1 => "stdout",
                        2 => "stderr",
                        else => "(pipe)",
                    };
                } else file.path;

                if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                    const y = getScreenY(ln, vis_start, rect.y);

                    // FD number
                    var fd_buf: [5]u8 = undefined;
                    const fd_str = std.fmt.bufPrint(&fd_buf, "{d:>3}", .{file.fd}) catch "???";
                    buf.setString(rx, y, fd_str, val);

                    // Type with color
                    const type_str = switch (file.fd_type) {
                        .file => "file",
                        .socket_tcp => "tcp",
                        .socket_udp => "udp",
                        .socket_unix => "unix",
                        .pipe => "pipe",
                        .kqueue => "kqueue",
                        .other => "other",
                    };
                    const type_color: _Color = switch (file.fd_type) {
                        .file => .white,
                        .socket_tcp => .green,
                        .socket_udp => .yellow,
                        .socket_unix => .cyan,
                        .pipe => .magenta,
                        .kqueue => .blue,
                        .other => .gray,
                    };
                    buf.setString(rx + 5, y, type_str, _Style{ .fg = type_color });

                    // For TCP sockets, show the connection state
                    var state_offset: u16 = 0;
                    if (file.fd_type == .socket_tcp) {
                        const state_label = file.tcp_state.label();
                        const state_color: _Color = switch (file.tcp_state) {
                            .established => .green,
                            .listen => .cyan,
                            .time_wait, .fin_wait_1, .fin_wait_2, .closing, .last_ack => .yellow,
                            .close_wait => .light_red,
                            .syn_sent, .syn_received => .light_blue,
                            .closed => .gray,
                            .unknown => .gray,
                        };
                        buf.setString(rx + 9, y, state_label, _Style{ .fg = state_color });
                        state_offset = @intCast(state_label.len + 1);
                    }

                    // First chunk of path
                    if (path_str.len > 0) {
                        const actual_path_x = path_x + state_offset;
                        const actual_path_max = if (path_max > state_offset) path_max - state_offset else 0;
                        const first_chunk = path_str[0..@min(path_str.len, actual_path_max)];
                        buf.setString(actual_path_x, y, first_chunk, _Style{ .fg = .light_cyan });
                    }
                }
                ln += 1;

                // Continuation lines for long paths
                var offset: usize = path_max;
                while (offset < path_str.len) : (offset += path_max) {
                    if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                        const y = getScreenY(ln, vis_start, rect.y);
                        const chunk_end = @min(offset + path_max, path_str.len);
                        const chunk = path_str[offset..chunk_end];
                        buf.setString(path_x, y, chunk, _Style{ .fg = .light_cyan });
                    }
                    ln += 1;
                }
            }

            // Summary line for grouped anonymous entries
            if (local_pipe_count > 0 or local_kqueue_count > 0 or local_other_count > 0) {
                if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                    const y = getScreenY(ln, vis_start, rect.y);
                    var summary_buf: [64]u8 = undefined;
                    var parts: [3][]const u8 = undefined;
                    var part_count: usize = 0;
                    var pipe_buf_inner: [20]u8 = undefined;
                    var kq_buf: [20]u8 = undefined;
                    var other_buf: [20]u8 = undefined;

                    if (local_pipe_count > 0) {
                        parts[part_count] = std.fmt.bufPrint(&pipe_buf_inner, "{d} pipes", .{local_pipe_count}) catch "? pipes";
                        part_count += 1;
                    }
                    if (local_kqueue_count > 0) {
                        parts[part_count] = std.fmt.bufPrint(&kq_buf, "{d} kqueues", .{local_kqueue_count}) catch "? kqueues";
                        part_count += 1;
                    }
                    if (local_other_count > 0) {
                        parts[part_count] = std.fmt.bufPrint(&other_buf, "{d} other", .{local_other_count}) catch "? other";
                        part_count += 1;
                    }

                    var summary_len: usize = 0;
                    for (parts[0..part_count], 0..) |part, i| {
                        if (i > 0 and summary_len + 2 < summary_buf.len) {
                            @memcpy(summary_buf[summary_len..][0..2], ", ");
                            summary_len += 2;
                        }
                        const copy_len = @min(part.len, summary_buf.len - summary_len);
                        @memcpy(summary_buf[summary_len..][0..copy_len], part[0..copy_len]);
                        summary_len += copy_len;
                    }

                    buf.setString(rx + 2, y, summary_buf[0..summary_len], _Style{ .fg = .gray });
                }
                ln += 1;
            }
        } else {
            if (!measure_only and isVisible(ln, vis_start, vis_end)) {
                const y = getScreenY(ln, vis_start, rect.y);
                buf.setString(rx + 2, y, "(unable to read file descriptors)", lbl);
            }
            ln += 1;
        }
    }

    return .{ .total_lines = ln, .self_line = self_ln };
}

fn renderDetailThreads(buf: *tui.render.Buffer, rect: layout.Rect, threads: ?[]const model.ThreadInfo, scroll: usize, focused: bool) usize {
    const header_style = _Style{ .fg = .cyan, .modifier = _Modifier{ .bold = true } };
    const val_style = _Style{ .fg = if (focused) .white else .gray };
    const dim_style = _Style{ .fg = .gray };

    if (threads == null or threads.?.len == 0) {
        buf.setString(rect.x, rect.y, "No thread data available", dim_style);
        buf.setString(rect.x, rect.y + 1, "(may require elevated privileges)", dim_style);
        return 2;
    }

    const thread_list = threads.?;
    var ln: usize = 0;
    const vis_start = scroll;
    const vis_end = scroll + @as(usize, @intCast(rect.height));

    // Header
    if (ln >= vis_start and ln < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "TID", header_style);
        buf.setString(rect.x + 12, y, "CPU%", header_style);
        buf.setString(rect.x + 20, y, "State", header_style);
        buf.setString(rect.x + 32, y, "User Time", header_style);
        buf.setString(rect.x + 44, y, "Sys Time", header_style);
    }
    ln += 1;

    // Thread rows
    for (thread_list) |thread| {
        if (ln >= vis_start and ln < vis_end) {
            const y = rect.y + @as(u16, @intCast(ln - vis_start));

            // TID
            var tid_buf: [12]u8 = undefined;
            const tid_str = std.fmt.bufPrint(&tid_buf, "0x{x:0>8}", .{thread.tid}) catch "???";
            buf.setString(rect.x, y, tid_str, val_style);

            // CPU%
            var cpu_buf: [8]u8 = undefined;
            const cpu_str = std.fmt.bufPrint(&cpu_buf, "{d:>5.1}%", .{thread.cpu_percent}) catch "???";
            buf.setString(rect.x + 12, y, cpu_str, _Style{ .fg = cpuColor(thread.cpu_percent) });

            // State
            const state_str = switch (thread.state) {
                .running => "Running",
                .waiting => "Waiting",
                .stopped => "Stopped",
                .halted => "Halted",
                .unknown => "Unknown",
            };
            const state_color: _Color = switch (thread.state) {
                .running => .green,
                .waiting => .yellow,
                .stopped => .red,
                .halted => .red,
                .unknown => .gray,
            };
            buf.setString(rect.x + 20, y, state_str, _Style{ .fg = state_color });

            // User time
            var user_buf: [12]u8 = undefined;
            const user_sec = @as(f64, @floatFromInt(thread.user_time_us)) / 1_000_000.0;
            const user_str = std.fmt.bufPrint(&user_buf, "{d:>7.2}s", .{user_sec}) catch "???";
            buf.setString(rect.x + 32, y, user_str, dim_style);

            // System time
            var sys_buf: [12]u8 = undefined;
            const sys_sec = @as(f64, @floatFromInt(thread.system_time_us)) / 1_000_000.0;
            const sys_str = std.fmt.bufPrint(&sys_buf, "{d:>7.2}s", .{sys_sec}) catch "???";
            buf.setString(rect.x + 44, y, sys_str, dim_style);
        }
        ln += 1;
    }

    return ln;
}

fn renderDetailOpenFiles(buf: *tui.render.Buffer, rect: layout.Rect, files: ?[]const model.OpenFile, scroll: usize, focused: bool) usize {
    const header_style = _Style{ .fg = .cyan, .modifier = _Modifier{ .bold = true } };
    const val_style = _Style{ .fg = if (focused) .white else .gray };
    const dim_style = _Style{ .fg = .gray };
    const path_style = _Style{ .fg = .light_cyan };

    if (files == null or files.?.len == 0) {
        buf.setString(rect.x, rect.y, "No open file data available", dim_style);
        buf.setString(rect.x, rect.y + 1, "(may require elevated privileges)", dim_style);
        return 2;
    }

    const file_list = files.?;
    var ln: usize = 0;
    const vis_start = scroll;
    const vis_end = scroll + @as(usize, @intCast(rect.height));
    const max_w: usize = @intCast(rect.width);

    // Header
    if (ln >= vis_start and ln < vis_end) {
        const y = rect.y + @as(u16, @intCast(ln - vis_start));
        buf.setString(rect.x, y, "FD", header_style);
        buf.setString(rect.x + 5, y, "Type", header_style);
        buf.setString(rect.x + 16, y, "Path / Address", header_style);
    }
    ln += 1;

    // File rows
    for (file_list) |file| {
        if (ln >= vis_start and ln < vis_end) {
            const y = rect.y + @as(u16, @intCast(ln - vis_start));

            // FD number
            var fd_buf: [5]u8 = undefined;
            const fd_str = std.fmt.bufPrint(&fd_buf, "{d:>3}", .{file.fd}) catch "???";
            buf.setString(rect.x, y, fd_str, val_style);

            // Type
            const type_str = switch (file.fd_type) {
                .file => "file",
                .socket_tcp => "tcp",
                .socket_udp => "udp",
                .socket_unix => "unix",
                .pipe => "pipe",
                .kqueue => "kqueue",
                .other => "other",
            };
            const type_color: _Color = switch (file.fd_type) {
                .file => .white,
                .socket_tcp => .green,
                .socket_udp => .yellow,
                .socket_unix => .cyan,
                .pipe => .magenta,
                .kqueue => .blue,
                .other => .gray,
            };
            buf.setString(rect.x + 5, y, type_str, _Style{ .fg = type_color });

            // For TCP sockets, show the connection state
            var state_offset: u16 = 0;
            if (file.fd_type == .socket_tcp) {
                const state_label = file.tcp_state.label();
                const state_color: _Color = switch (file.tcp_state) {
                    .established => .green,
                    .listen => .cyan,
                    .time_wait, .fin_wait_1, .fin_wait_2, .closing, .last_ack => .yellow,
                    .close_wait => .light_red,
                    .syn_sent, .syn_received => .light_blue,
                    .closed => .gray,
                    .unknown => .gray,
                };
                buf.setString(rect.x + 9, y, state_label, _Style{ .fg = state_color });
                state_offset = @intCast(state_label.len + 1);
            }

            // Path or address
            const path_x = rect.x + 16 + state_offset;
            const path_max: usize = if (max_w > 16 + state_offset) max_w - 16 - state_offset else 0;

            if (file.fd_type == .socket_tcp or file.fd_type == .socket_udp) {
                // Show local -> remote for sockets
                var addr_buf: [80]u8 = undefined;
                const addr_str = std.fmt.bufPrint(&addr_buf, "{s} -> {s}", .{
                    if (file.local_addr.len > 0) file.local_addr else "?",
                    if (file.remote_addr.len > 0) file.remote_addr else "?",
                }) catch "???";
                const show_len = @min(addr_str.len, path_max);
                buf.setString(path_x, y, addr_str[0..show_len], path_style);
            } else {
                // Show path
                const show_len = @min(file.path.len, path_max);
                if (show_len > 0) {
                    buf.setString(path_x, y, file.path[0..show_len], path_style);
                }
            }
        }
        ln += 1;
    }

    return ln;
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

fn renderConfirmDialog(buf: *tui.render.Buffer, dialog: *const state.ConfirmDialog, area: tui.render.Rect) void {
    const title = dialog.getTitle();
    const message = dialog.getMessage();

    // Dialog dimensions
    const title_len: u16 = @intCast(title.len);
    const msg_len: u16 = @intCast(message.len);
    const min_content_w: u16 = @max(title_len + 4, msg_len + 4);
    const box_width: u16 = @max(min_content_w, 40);
    const box_height: u16 = 9;

    // Center the dialog
    const dialog_x = area.x + (area.width -| box_width) / 2;
    const dialog_y = area.y + (area.height -| box_height) / 2;

    // Colors based on action type
    const is_force = dialog.action == .kill_force;
    const border_color: _Color = if (is_force) .red else .yellow;
    const border_style_dialog = _Style{ .fg = border_color };
    const title_style = _Style{ .fg = border_color, .modifier = _Modifier{ .bold = true } };
    const content_style = _Style{ .fg = .white };
    const dim_style = _Style{ .fg = .gray };

    // Clear interior with spaces
    {
        var y: u16 = dialog_y;
        while (y < dialog_y + box_height) : (y += 1) {
            var x: u16 = dialog_x;
            while (x < dialog_x + box_width) : (x += 1) {
                buf.setChar(x, y, ' ', _Style{});
            }
        }
    }

    // Draw border - corners
    buf.setChar(dialog_x, dialog_y, BD_RTL, border_style_dialog); // ╭
    buf.setChar(dialog_x + box_width - 1, dialog_y, BD_RTR, border_style_dialog); // ╮
    buf.setChar(dialog_x, dialog_y + box_height - 1, BD_RBL, border_style_dialog); // ╰
    buf.setChar(dialog_x + box_width - 1, dialog_y + box_height - 1, BD_RBR, border_style_dialog); // ╯

    // Top edge with title
    buf.setChar(dialog_x + 1, dialog_y, BD_HOR, border_style_dialog);
    buf.setChar(dialog_x + 2, dialog_y, ' ', border_style_dialog);
    buf.setString(dialog_x + 3, dialog_y, title, title_style);
    {
        var x: u16 = dialog_x + 3 + title_len + 1;
        while (x < dialog_x + box_width - 1) : (x += 1) {
            buf.setChar(x, dialog_y, BD_HOR, border_style_dialog);
        }
    }

    // Bottom edge
    {
        var x: u16 = dialog_x + 1;
        while (x < dialog_x + box_width - 1) : (x += 1) {
            buf.setChar(x, dialog_y + box_height - 1, BD_HOR, border_style_dialog);
        }
    }

    // Side edges
    {
        var y: u16 = dialog_y + 1;
        while (y < dialog_y + box_height - 1) : (y += 1) {
            buf.setChar(dialog_x, y, BD_VER, border_style_dialog);
            buf.setChar(dialog_x + box_width - 1, y, BD_VER, border_style_dialog);
        }
    }

    // Content area
    const content_x = dialog_x + 2;
    const content_w = box_width - 4;

    // Process info line (centered)
    const msg_x = content_x + (content_w -| msg_len) / 2;
    buf.setString(msg_x, dialog_y + 2, message, content_style);

    // Warning for force kill
    if (is_force) {
        const warn_text = "SIGKILL - Cannot be caught!";
        const warn_len: u16 = @intCast(warn_text.len);
        const warn_x = content_x + (content_w -| warn_len) / 2;
        buf.setString(warn_x, dialog_y + 3, warn_text, _Style{ .fg = .red, .modifier = _Modifier{ .bold = true } });
    }

    // Separator line before buttons
    {
        const sep_y = dialog_y + 5;
        var x: u16 = content_x;
        while (x < content_x + content_w) : (x += 1) {
            buf.setChar(x, sep_y, 0x2500, dim_style); // ─
        }
    }

    // Buttons with borders
    const button_y = dialog_y + 7;
    const yes_btn_w: u16 = 9; // "│ Yes │"
    const no_btn_w: u16 = 8; // "│ No │"
    const btn_gap: u16 = 4;
    const total_btn_w = yes_btn_w + btn_gap + no_btn_w;
    const btn_start_x = content_x + (content_w -| total_btn_w) / 2;

    // Yes button
    const yes_style = _Style{ .fg = if (is_force) .red else .green, .modifier = _Modifier{ .bold = true } };
    buf.setString(btn_start_x, button_y, "[", dim_style);
    buf.setString(btn_start_x + 1, button_y, "Y", yes_style);
    buf.setString(btn_start_x + 2, button_y, "]", dim_style);
    buf.setString(btn_start_x + 3, button_y, " Yes", content_style);

    // No button
    const no_x = btn_start_x + yes_btn_w + btn_gap;
    buf.setString(no_x, button_y, "[", dim_style);
    buf.setString(no_x + 1, button_y, "N", _Style{ .fg = .cyan, .modifier = _Modifier{ .bold = true } });
    buf.setString(no_x + 2, button_y, "]", dim_style);
    buf.setString(no_x + 3, button_y, " No", content_style);

    // Hint text at bottom
    const hint = "Enter=Yes  Esc=Cancel";
    const hint_len: u16 = @intCast(hint.len);
    const hint_x = content_x + (content_w -| hint_len) / 2;
    buf.setString(hint_x, dialog_y + box_height - 2, hint, dim_style);
}
