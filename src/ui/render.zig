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

// proc_inner_layout is calculated manually for process list content
const proc_inner_layout = layout.Container.column(&[_]layout.Item{
    .{ .id = "proc_header", .sizing = .{ .fixed = 1 } },
    .{ .id = "proc_list", .sizing = .{ .grow = 1.0 } },
    .{ .id = "proc_footer", .sizing = .{ .fixed = 1 } },
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

const border_style = _Style{ .fg = .cyan };
const pane_title_style = _Style{ .fg = .white, .modifier = _Modifier{ .bold = true } };

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
    // Divider budget (subtracted from content space):
    //   2 horizontal dividers (hd1 between top/bottom, hd2 within left panel)
    //   varies by row for vertical dividers
    //
    // Y: top_content | hd1 | left_top_content | hd2 | left_bot_content
    //    (Processes spans from hd1 to bottom border without hd2)

    const avail_h = h -| 4; // minus outer borders(2) + hd1(1) + hd2(1)
    const top_h: u16 = @max(avail_h * 2 / 5, 2);
    const bot_avail: u16 = avail_h -| top_h;
    const left_top_h: u16 = @max(bot_avail / 2, 2);
    const left_bot_h: u16 = bot_avail -| left_top_h;

    const y_hd1 = area.y + 1 + top_h;
    const y_hd2 = y_hd1 + 1 + left_top_h;

    // X: top row: cpu | vdA | cores
    const top_iw = w -| 3; // minus outer(2) + vdA(1)
    const cpu_w: u16 = top_iw * 3 / 4;
    const cores_w: u16 = top_iw -| cpu_w;
    const x_vdA = area.x + 1 + cpu_w;

    // X: bottom row: left_panel | vdB | processes
    const bot_iw = w -| 3;
    const left_w: u16 = bot_iw / 2;
    const proc_w: u16 = bot_iw -| left_w;
    const x_vdB = area.x + 1 + left_w;

    // X: left panel top: net_graph | vdC | net_sync
    const lt_iw = left_w -| 1;
    const ng_w: u16 = lt_iw / 2;
    const ns_w: u16 = lt_iw -| ng_w;
    const x_vdC = area.x + 1 + ng_w;

    // X: left panel bottom: disk_io | vdD | disks (2 columns)
    const lb_iw = left_w -| 1;
    const io_w: u16 = lb_iw / 2;
    const dk_w: u16 = lb_iw -| io_w;
    const x_vdD = area.x + 1 + io_w;

    // ── Draw outer border ─────────────────────────────────────────
    const x0 = area.x;
    const x1 = area.x + w - 1;
    const y0 = area.y;
    const y1 = area.y + h - 1;

    buf.setChar(x0, y0, BD_TL, border_style);
    buf.setChar(x1, y0, BD_TR, border_style);
    buf.setChar(x0, y1, BD_BL, border_style);
    buf.setChar(x1, y1, BD_BR, border_style);

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

    // ── Horizontal divider 2 (left panel only, from left border to vdB) ──
    {
        buf.setChar(x0, y_hd2, BD_LT, border_style);
        var x: u16 = x0 + 1;
        while (x < x_vdB) : (x += 1) buf.setChar(x, y_hd2, BD_HOR, border_style);
    }

    // ── Vertical dividers ─────────────────────────────────────────
    // vdA: between CPU and Cores (top row only)
    {
        buf.setChar(x_vdA, y0, BD_TT, border_style);
        var y: u16 = y0 + 1;
        while (y < y_hd1) : (y += 1) buf.setChar(x_vdA, y, BD_VER, border_style);
        buf.setChar(x_vdA, y_hd1, BD_BT, border_style);
    }

    // vdB: between left panel and Processes (full bottom)
    {
        buf.setChar(x_vdB, y_hd1, BD_TT, border_style);
        var y: u16 = y_hd1 + 1;
        while (y < y1) : (y += 1) buf.setChar(x_vdB, y, BD_VER, border_style);
        buf.setChar(x_vdB, y1, BD_BT, border_style);
        // Junction where hd2 meets vdB
        buf.setChar(x_vdB, y_hd2, BD_RT, border_style);
    }

    // vdC: between Network and Sync (left panel top sub-row)
    {
        buf.setChar(x_vdC, y_hd1, BD_TT, border_style);
        var y: u16 = y_hd1 + 1;
        while (y < y_hd2) : (y += 1) buf.setChar(x_vdC, y, BD_VER, border_style);
        buf.setChar(x_vdC, y_hd2, BD_BT, border_style);
    }

    // vdD: between Disk IO and Disks (left panel bottom sub-row)
    {
        buf.setChar(x_vdD, y_hd2, BD_TT, border_style);
        var y: u16 = y_hd2 + 1;
        while (y < y1) : (y += 1) buf.setChar(x_vdD, y, BD_VER, border_style);
        buf.setChar(x_vdD, y1, BD_BT, border_style);
    }

    // ── Titles on borders / dividers ──────────────────────────────
    drawTitle(buf, x0 + 2, y0, "CPU");
    drawTitle(buf, x_vdA + 2, y0, "Cores");
    drawTitle(buf, x0 + 2, y_hd1, "Network");
    drawTitle(buf, x_vdC + 2, y_hd1, "Memory");
    drawTitle(buf, x_vdB + 2, y_hd1, "Processes");
    drawTitle(buf, x0 + 2, y_hd2, "Disk IO");
    drawTitle(buf, x_vdD + 2, y_hd2, "Disks");

    // ── Content rects (the usable interior of each pane) ──────────
    const cpu_rect = layout.Rect{ .x = x0 + 1, .y = y0 + 1, .width = cpu_w, .height = top_h };
    const cores_rect = layout.Rect{ .x = x_vdA + 1, .y = y0 + 1, .width = cores_w, .height = top_h };
    const network_rect = layout.Rect{ .x = x0 + 1, .y = y_hd1 + 1, .width = ng_w, .height = left_top_h };
    const memory_rect = layout.Rect{ .x = x_vdC + 1, .y = y_hd1 + 1, .width = ns_w, .height = left_top_h };
    const disk_io_rect = layout.Rect{ .x = x0 + 1, .y = y_hd2 + 1, .width = io_w, .height = left_bot_h };
    const disks_rect = layout.Rect{ .x = x_vdD + 1, .y = y_hd2 + 1, .width = dk_w, .height = left_bot_h };
    const proc_rect = layout.Rect{ .x = x_vdB + 1, .y = y_hd1 + 1, .width = proc_w, .height = y1 - y_hd1 - 1 };

    // ── Render content into each pane ─────────────────────────────
    renderCpuGraphBraille(buf, cpu_rect, &app.system);
    renderCoresBars(buf, cores_rect, &app.system);
    renderNetworkCombined(buf, network_rect, &app.system);
    renderMemoryPane(buf, memory_rect, &app.system);
    renderDiskIO(buf, disk_io_rect, &app.system);
    renderDisksPane(buf, disks_rect, &app.system);

    // Processes pane: calculate sub-layout within the content rect
    var proc_layout_calc = layout.calculate(draw_ctx.scratch, proc_inner_layout, proc_rect) catch return;
    defer proc_layout_calc.deinit();
    const proc_header_rect = proc_layout_calc.get("proc_header") orelse return;
    const proc_list_rect = proc_layout_calc.get("proc_list") orelse return;
    const proc_footer_rect = proc_layout_calc.get("proc_footer") orelse return;
    renderProcessPane(buf, draw_ctx.scratch, app, proc_header_rect, proc_list_rect, proc_footer_rect);

    // ── Overlay modes ─────────────────────────────────────────────
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

fn drawTitle(buf: *tui.render.Buffer, x: u16, y: u16, title: []const u8) void {
    buf.setString(x, y, title, pane_title_style);
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

        const name_style: _Style = if (is_selected) .{ .bg = .blue, .fg = .white, .modifier = _Modifier{ .bold = true } } else .{ .fg = .light_cyan };
        const secondary_style: _Style = if (is_selected) .{ .bg = .blue, .fg = .light_cyan } else .{ .fg = .gray };
        const prefix_style: _Style = if (is_selected) .{ .bg = .blue, .fg = .light_cyan } else .{ .fg = .gray };

        const cpu_fg = cpuColor(row.cpu_percent);
        const cpu_fg_sel: _Color = switch (cpu_fg) {
            .green => .light_green,
            .yellow => .light_yellow,
            .red => .light_red,
            else => .white,
        };
        const cpu_style: _Style = if (is_selected) .{ .bg = .blue, .fg = cpu_fg_sel, .modifier = _Modifier{ .bold = true } } else .{ .fg = cpu_fg };

        const mem_fg = memColor(row.mem_rss);
        const mem_fg_sel: _Color = switch (mem_fg) {
            .green => .light_green,
            .yellow => .light_yellow,
            .red => .light_red,
            else => .white,
        };
        const mem_style: _Style = if (is_selected) .{ .bg = .blue, .fg = mem_fg_sel, .modifier = _Modifier{ .bold = true } } else .{ .fg = mem_fg };

        // Fill entire row with blue background for selected process
        if (is_selected) {
            var fill_x: u16 = list_rect.x;
            while (fill_x < list_rect.x + list_rect.width) : (fill_x += 1) {
                buf.setChar(fill_x, y, ' ', _Style{ .bg = .blue });
            }
        }

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

        // Per-column color based on the max of both original samples
        const col_color = cpuColor(@max(left_val, right_val));

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const screen_row = height - 1 - row; // row 0 = bottom
            const band_low: f32 = @as(f32, @floatFromInt(row)) * 100.0 / @as(f32, @floatFromInt(height));
            const band_high: f32 = @as(f32, @floatFromInt(row + 1)) * 100.0 / @as(f32, @floatFromInt(height));

            const left_level = quantize(left_clamped, band_low, band_high);
            const right_level = quantize(right_clamped, band_low, band_high);
            const braille_cp = braille_up[@as(usize, left_level) * 5 + @as(usize, right_level)];
            if (braille_cp == 0x2800) continue;

            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(braille_cp, &utf8_buf) catch continue;
            buf.setString(
                rect.x + @as(u16, @intCast(col)),
                rect.y + @as(u16, @intCast(screen_row)),
                utf8_buf[0..utf8_len],
                _Style{ .fg = col_color },
            );
        }
    }
}

/// Braille area chart from a CpuHistory (values 0-100) with a fixed color.
/// No noise floor, no per-column coloring — suited for memory category charts.
fn renderMemBrailleChart(buf: *tui.render.Buffer, rect: layout.Rect, history: *const model.CpuHistory, color: _Color) void {
    if (rect.width == 0 or rect.height == 0) return;
    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
    const sample_count = history.count;
    const capacity = width * 2;
    const filled_cols: usize = if (sample_count >= 2) @min((sample_count + 1) / 2, width) else if (sample_count == 1) 1 else 0;
    const start_sample: usize = if (sample_count > capacity) sample_count - capacity else 0;

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

    // Y-axis scale label: ceiling value at top-right (when height >= 3)
    if (height >= 3) {
        var scale_buf: [12]u8 = undefined;
        const scale_str = formatRate(&scale_buf, ceiling);
        const scale_len: u16 = @intCast(scale_str.len);
        if (scale_len < rect.width) {
            const scale_x = rect.x + rect.width -| scale_len;
            buf.setString(scale_x, rect.y, scale_str, _Style{ .fg = .gray });
        }
    }
}

fn renderCpuGraphBraille(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.width == 0 or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    const width: usize = @intCast(rect.width);
    const height: usize = @intCast(rect.height);
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

    // "100%" scale label at top-right (dimmed)
    if (height >= 3) {
        const scale_label = "100%";
        const scale_x = rect.x + rect.width -| @as(u16, @intCast(scale_label.len));
        buf.setString(scale_x, rect.y, scale_label, _Style{ .fg = .gray });
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

    // Reserve 1 row for total CPU bar at bottom
    const reserved_bottom: u16 = 1;
    const core_area_h = rect.height -| reserved_bottom;
    if (core_area_h == 0) return;

    const core_count: u16 = @intCast(@min(sys.core_count, model.MAX_CORES));
    if (core_count == 0) return;

    // Calculate rows per core: use available height evenly across all cores.
    const rows_per_core: u16 = @max(core_area_h / core_count, 1);
    const visible_cores: u16 = @min(core_count, core_area_h / rows_per_core);
    if (visible_cores == 0) return;

    const label_w: u16 = 3; // "XX "
    const pct_w: u16 = 5; // " NNN%"
    const chart_w = rect.width -| label_w -| pct_w;

    for (0..visible_cores) |i| {
        const block_y = rect.y + @as(u16, @intCast(i)) * rows_per_core;
        const pct = sys.core_percents[i];

        // Core number label overlaid on top-left of chart
        var line_buf: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&line_buf, "{d:>2} ", .{i}) catch "?? ";
        buf.setString(rect.x, block_y, label, _Style{ .fg = .gray });

        // Percent label overlaid on top-right of chart
        var pct_buf: [6]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch "???";
        buf.setString(rect.x + label_w + chart_w, block_y, pct_str, _Style{ .fg = cpuColor(pct) });

        // Multi-row braille chart filling the full block
        if (chart_w > 0) {
            renderCoreBrailleBlock(buf, .{
                .x = rect.x + label_w,
                .y = block_y,
                .width = chart_w,
                .height = rows_per_core,
            }, &sys.core_histories[i]);
        }
    }

    // Total CPU bar at bottom: "tot [bar] NN.N%"
    const total_y = rect.y + rect.height -| 1;
    const cpu_color = cpuColor(sys.total_cpu_percent);
    const cpu_bold = _Style{ .fg = cpu_color, .modifier = _Modifier{ .bold = true } };

    const tot_label_w: u16 = 4; // "tot "
    const tot_pct_w: u16 = 6; // " NN.N%"
    const tot_overhead: u16 = tot_label_w + tot_pct_w; // 10
    const tot_bar_w = rect.width -| tot_overhead;

    buf.setString(rect.x, total_y, "CPU ", cpu_bold);

    if (tot_bar_w > 0) {
        renderBar(buf, rect.x + tot_label_w, total_y, tot_bar_w, sys.total_cpu_percent, 100.0, cpu_color);
    }

    var tot_pct_buf: [6]u8 = undefined;
    const tot_pct_str = std.fmt.bufPrint(&tot_pct_buf, "{d:>5.1}%", .{sys.total_cpu_percent}) catch " ???%";
    buf.setString(rect.x + rect.width -| tot_pct_w, total_y, tot_pct_str, cpu_bold);
}

fn renderDiskIO(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    // Split vertically: read (top half), write (bottom half)
    // Each half: 1 label row + remaining rows for braille chart
    const half_h = rect.height / 2;
    if (half_h < 2) {
        // Fallback: just show labels if too small
        buf.setString(rect.x, rect.y, "R ", _Style{ .fg = .green, .modifier = _Modifier{ .bold = true } });
        var r_buf: [12]u8 = undefined;
        const r_str = formatRate(&r_buf, sys.disk_read_rate);
        buf.setString(rect.x + 2, rect.y, r_str, _Style{ .fg = .green });
        if (rect.height > 1) {
            buf.setString(rect.x, rect.y + 1, "W ", _Style{ .fg = .red, .modifier = _Modifier{ .bold = true } });
            var w_buf: [12]u8 = undefined;
            const w_str = formatRate(&w_buf, sys.disk_write_rate);
            buf.setString(rect.x + 2, rect.y + 1, w_str, _Style{ .fg = .red });
        }
        return;
    }

    // Read label row
    buf.setString(rect.x, rect.y, "R  ", _Style{ .fg = .green, .modifier = _Modifier{ .bold = true } });
    var r_buf: [12]u8 = undefined;
    const r_str = formatRate(&r_buf, sys.disk_read_rate);
    buf.setString(rect.x + 3, rect.y, r_str, _Style{ .fg = .green });

    // Read braille chart
    const read_chart_h = half_h - 1;
    if (read_chart_h > 0) {
        renderRateBrailleChart(buf, .{
            .x = rect.x,
            .y = rect.y + 1,
            .width = rect.width,
            .height = read_chart_h,
        }, &sys.disk_read_history, .green);
    }

    // Write label row
    const write_y = rect.y + half_h;
    buf.setString(rect.x, write_y, "W  ", _Style{ .fg = .red, .modifier = _Modifier{ .bold = true } });
    var w_buf: [12]u8 = undefined;
    const w_str = formatRate(&w_buf, sys.disk_write_rate);
    buf.setString(rect.x + 3, write_y, w_str, _Style{ .fg = .red });

    // Write braille chart
    const write_chart_h = rect.height - half_h - 1;
    if (write_chart_h > 0) {
        renderRateBrailleChart(buf, .{
            .x = rect.x,
            .y = write_y + 1,
            .width = rect.width,
            .height = write_chart_h,
        }, &sys.disk_write_history, .red);
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

fn renderNetworkCombined(buf: *tui.render.Buffer, rect: layout.Rect, sys: *const state.SystemState) void {
    if (!sys.has_data or rect.height == 0) {
        buf.setString(rect.x, rect.y, "Waiting for data...", _Style{ .fg = .gray });
        return;
    }

    const recv_glyph = "\xe2\x96\xbc"; // U+25BC ▼
    const sent_glyph = "\xe2\x96\xb2"; // U+25B2 ▲

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
        renderRateBrailleChart(buf, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = dl_h }, &sys.net_recv_history, .green);
        renderRateBrailleChart(buf, .{ .x = rect.x, .y = rect.y + dl_h + 1, .width = rect.width, .height = ul_h }, &sys.net_sent_history, .red);
        return;
    }

    // ── Two-column interface label grid ──────────────────────────
    // Layout: labels read left-to-right, wrapping into rows of 2.
    //   en0 ▼5.1 MB/s  |  utun0 ▼  0  B/s
    // 2-char padding between columns for readability.
    const col_pad: u16 = 2;
    const col_w = (rect.width -| col_pad) / 2;
    const label_row_count: u16 = @intCast((@as(usize, iface_count) + 1) / 2);
    const max_label_rows: u16 = @min(label_row_count, rect.height / 2); // reserve at least half for chart

    // Find max interface name length (across all visible interfaces) to align ▼ glyphs
    var max_name_len: u16 = 0;
    for (0..iface_count) |i| {
        const nlen: u16 = @intCast(sys.iface_name_lens[i]);
        if (nlen > max_name_len) max_name_len = nlen;
    }

    for (0..@as(usize, max_label_rows) * 2) |i| {
        if (i >= iface_count) break;
        const grid_row: u16 = @intCast(i / 2);
        if (grid_row >= max_label_rows) break;
        const grid_col: u16 = @intCast(i % 2);
        const cell_x = rect.x + grid_col * (col_w + col_pad);
        const cell_y = rect.y + grid_row;
        const color = ifaceColor(i);
        const name = sys.iface_names[i][0..sys.iface_name_lens[i]];
        const cell_end = cell_x + col_w;

        // Interface name (bold)
        buf.setString(cell_x, cell_y, name, _Style{ .fg = color, .modifier = _Modifier{ .bold = true } });

        // ▼ recv rate — aligned at consistent column across all interfaces
        const rate_x = cell_x + max_name_len + 1;
        if (rate_x + 2 < cell_end) {
            buf.setString(rate_x, cell_y, recv_glyph, _Style{ .fg = color });
            var r_buf: [12]u8 = undefined;
            const r_str = formatRate(&r_buf, sys.iface_recv_rates[i]);
            const r_len: u16 = @intCast(r_str.len);
            const r_avail = cell_end -| (rate_x + 2);
            const r_show: u16 = @min(r_len, r_avail);
            if (r_show > 0) buf.setString(rate_x + 2, cell_y, r_str[0..r_show], _Style{ .fg = color });
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

    // Shared scale across both halves (max of all recv + all sent)
    const capacity = @as(usize, @intCast(rect.width)) * 2;
    var global_max: f64 = 0;
    for (0..iface_count) |i| {
        const rv = @min(sys.iface_recv_histories[i].count, capacity);
        if (rv > 0) {
            const m = sys.iface_recv_histories[i].maxInWindow(rv);
            if (m > global_max) global_max = m;
        }
        const sv = @min(sys.iface_sent_histories[i].count, capacity);
        if (sv > 0) {
            const m = sys.iface_sent_histories[i].maxInWindow(sv);
            if (m > global_max) global_max = m;
        }
    }
    const ceiling = autoScaleCeiling(global_max, 1024.0);

    // Download half: braille grows upward
    if (dl_h > 0) {
        renderMultiRateUp(buf, .{
            .x = rect.x, .y = chart_y, .width = rect.width, .height = dl_h,
        }, recv_ptrs[0..iface_count], colors[0..iface_count], ceiling);

        // Scale label at top-right of download half
        var scale_buf: [12]u8 = undefined;
        const scale_str = formatRate(&scale_buf, ceiling);
        const scale_len: u16 = @intCast(scale_str.len);
        if (scale_len < rect.width) {
            buf.setString(rect.x + rect.width -| scale_len, chart_y, scale_str, _Style{ .fg = .gray });
        }
    }

    // Center axis row: "▼ 5.1 MB/s ▲ 1.2 MB/s ──────"
    {
        const DASH: u21 = 0x2500;

        var dl_rate_buf: [12]u8 = undefined;
        const dl_rate_str = formatRate(&dl_rate_buf, sys.net_recv_rate);
        var ul_rate_buf: [12]u8 = undefined;
        const ul_rate_str = formatRate(&ul_rate_buf, sys.net_sent_rate);

        // ▼ + space + rate
        var cursor: u16 = rect.x;
        buf.setString(cursor, axis_y, recv_glyph, _Style{ .fg = .green });
        cursor += @intCast(recv_glyph.len);
        buf.setString(cursor, axis_y, dl_rate_str, _Style{ .fg = .green });
        cursor += @intCast(dl_rate_str.len);
        cursor += 1; // gap
        // ▲ + space + rate
        buf.setString(cursor, axis_y, sent_glyph, _Style{ .fg = .red });
        cursor += @intCast(sent_glyph.len);
        buf.setString(cursor, axis_y, ul_rate_str, _Style{ .fg = .red });
        cursor += @intCast(ul_rate_str.len);
        // Fill dashes to right edge
        const dash_end = rect.x + rect.width;
        if (dash_end > cursor) {
            var dx: u16 = cursor;
            while (dx < dash_end) : (dx += 1) {
                buf.setChar(dx, axis_y, DASH, _Style{ .fg = .gray });
            }
        }
    }

    // Upload half: braille grows downward
    if (ul_h > 0) {
        renderMultiRateDown(buf, .{
            .x = rect.x, .y = axis_y + 1, .width = rect.width, .height = ul_h,
        }, sent_ptrs[0..iface_count], colors[0..iface_count], ceiling);
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

    const MemLine = struct {
        label: []const u8,
        short_label: []const u8,
        value: u64,
        color: _Color,
        history: *const model.CpuHistory,
    };

    const lines = [4]MemLine{
        .{ .label = "Used", .short_label = "U ", .value = sys.mem_used, .color = if (mem_total_f > 0) memPercentColor(@as(f32, @floatFromInt(sys.mem_used)) / mem_total_f * 100.0) else .green, .history = &sys.mem_used_history },
        .{ .label = "Available", .short_label = "A ", .value = sys.mem_available, .color = .cyan, .history = &sys.mem_available_history },
        .{ .label = "Cached", .short_label = "C ", .value = sys.mem_cached, .color = .blue, .history = &sys.mem_cached_history },
        .{ .label = "Free", .short_label = "F ", .value = sys.mem_free, .color = .cyan, .history = &sys.mem_free_history },
    };

    // Full format: height >= 10 and width >= 20
    if (rect.height >= 10 and rect.width >= 20) {
        var y: u16 = rect.y;
        const max_y = rect.y + rect.height;
        const DASH: u21 = 0x2500; // ─

        // Total header line: "Total ─────── 16.0 GiB"
        if (y < max_y) {
            const total_label = "Total";
            buf.setString(rect.x, y, total_label, _Style{ .fg = .light_white, .modifier = _Modifier{ .bold = true } });
            var b: [12]u8 = undefined;
            const s = formatBytes(&b, sys.mem_total);
            const s_len: u16 = @intCast(s.len);
            const val_x = rect.x + rect.width -| s_len;
            buf.setString(val_x, y, s, _Style{ .fg = .light_white });

            // Fill dashes between label and value
            const dash_start = rect.x + @as(u16, @intCast(total_label.len)) + 1;
            const dash_end = if (val_x > 0) val_x -| 1 else val_x;
            if (dash_end > dash_start) {
                var dx: u16 = dash_start;
                while (dx <= dash_end) : (dx += 1) {
                    buf.setChar(dx, y, DASH, _Style{ .fg = .gray });
                }
            }
            y += 1;
        }

        // Each entry: 1 label row + braille chart rows
        // Distribute remaining rows evenly across 4 categories
        const remaining = max_y -| y;
        const rows_per_entry = remaining / 4;

        for (lines) |line| {
            if (y >= max_y) break;
            if (mem_total_f == 0) break;

            const pct: f32 = @as(f32, @floatFromInt(line.value)) / mem_total_f * 100.0;

            // Label row: "Used   8.1 GiB   50%"
            buf.setString(rect.x, y, line.label, _Style{ .fg = line.color, .modifier = _Modifier{ .bold = true } });

            var val_buf: [12]u8 = undefined;
            const val_str = formatBytes(&val_buf, line.value);
            const label_col_w: u16 = 10;
            buf.setString(rect.x + label_col_w, y, val_str, _Style{ .fg = line.color });

            const pct_w: u16 = 5;
            var pct_buf: [5]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>4.0}%", .{pct}) catch " ??%";
            buf.setString(rect.x + rect.width -| pct_w, y, pct_str, _Style{ .fg = line.color });
            y += 1;

            // Braille chart rows
            const chart_rows: u16 = if (rows_per_entry > 1) rows_per_entry - 1 else 0;
            if (chart_rows > 0 and y + chart_rows <= max_y) {
                renderMemBrailleChart(buf, .{ .x = rect.x, .y = y, .width = rect.width, .height = chart_rows }, line.history, line.color);
                y += chart_rows;
            }
        }
    } else {
        // Compact layout: full names + braille chart per entry, filling available space
        var y: u16 = rect.y;
        const max_y = rect.y + rect.height;

        // Total line
        if (y < max_y) {
            buf.setString(rect.x, y, "Total", _Style{ .fg = .gray });
            var b: [12]u8 = undefined;
            const s = formatBytes(&b, sys.mem_total);
            const val_x = rect.x + rect.width -| @as(u16, @intCast(s.len));
            buf.setString(val_x, y, s, _Style{ .fg = .light_white });
            y += 1;
        }

        // Distribute remaining rows across 4 categories
        const remaining = max_y -| y;
        const rows_per_entry = remaining / 4;

        for (lines) |line| {
            if (y >= max_y) break;
            if (mem_total_f == 0) break;

            const pct: f32 = @as(f32, @floatFromInt(line.value)) / mem_total_f * 100.0;

            // Label row: "Used  8.1 GiB  50%"
            const label_len: u16 = @intCast(line.label.len);
            buf.setString(rect.x, y, line.label, _Style{ .fg = line.color, .modifier = _Modifier{ .bold = true } });

            var val_buf: [12]u8 = undefined;
            const val_str = formatBytes(&val_buf, line.value);
            const val_x = rect.x + label_len + 1;
            buf.setString(val_x, y, val_str, _Style{ .fg = line.color });

            const pct_w: u16 = 4;
            var pct_buf: [4]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:>3.0}%", .{pct}) catch "??%";
            buf.setString(rect.x + rect.width -| pct_w, y, pct_str, _Style{ .fg = line.color });
            y += 1;

            // Braille chart rows (fill remaining allocated space)
            const chart_rows: u16 = if (rows_per_entry > 1) rows_per_entry - 1 else 0;
            if (chart_rows > 0 and y + chart_rows <= max_y) {
                renderMemBrailleChart(buf, .{ .x = rect.x, .y = y, .width = rect.width, .height = chart_rows }, line.history, line.color);
                y += chart_rows;
            }
        }
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
        buf.setString(total_x, y, total_str, _Style{ .fg = .gray });

        // Fill dashes between name and total size (with 1-char gap each side)
        const dash_start = rect.x + name_display_len + 1;
        const dash_end = if (total_x > 0) total_x -| 1 else total_x;
        if (dash_end > dash_start) {
            var dx: u16 = dash_start;
            while (dx <= dash_end) : (dx += 1) {
                buf.setChar(dx, y, DASH, _Style{ .fg = .gray });
            }
        }
        y += 1;

        if (y >= max_y) break;

        // Line 2: full-width bar with percentage
        if (mount.total_bytes > 0) {
            const pct: f32 = @as(f32, @floatFromInt(mount.used_bytes)) / @as(f32, @floatFromInt(mount.total_bytes)) * 100.0;
            const color = diskPercentColor(pct);

            // Discrete box grid bar, percentage at right
            const bar_w = rect.width -| pct_reserve;
            if (bar_w > 0) {
                renderBoxBar(buf, rect.x, y, bar_w, pct, 100.0, color);
            }

            // " NN%" right-aligned
            var pct_buf: [5]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, " {d:>3.0}%", .{pct}) catch " ??%";
            buf.setString(rect.x + rect.width -| pct_reserve, y, pct_str, _Style{ .fg = color });
        }
        y += 1;

        // Add blank line between disks if space allows and more disks follow
        if (mount_idx + 1 < sys.mount_count and y + 2 < max_y) {
            y += 1;
        }
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
