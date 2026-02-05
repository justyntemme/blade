const std = @import("std");

pub const Direction = enum {
    row,
    column,
};

pub const Container = struct {
    direction: Direction,
    items: []const Item,
    gap: u16 = 0,

    pub fn row(items: []const Item) Container {
        return .{ .direction = .row, .items = items };
    }
    pub fn column(items: []const Item) Container {
        return .{ .direction = .column, .items = items };
    }
};

pub const Sizing = union(enum) {
    fixed: u16,
    grow: f32,
    percent: f32,
};

pub const Item = struct {
    sizing: Sizing,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

fn calculateGrowSize(weight: f32, total_weight: f32, remaining: u16) u16 {
    if (total_weight == 0) return 0;
    const ratio = weight / total_weight;
    const size = ratio * @as(f32, @floatFromInt(remaining));
    return @intFromFloat(size);
}

/// Zero-allocation layout calculation. Container must be comptime-known.
/// Returns a fixed array of Rect values indexed by item position.
pub fn calculate(comptime container: Container, available: Rect) [container.items.len]Rect {
    comptime {
        for (container.items) |item| {
            switch (item.sizing) {
                .grow => |w| if (w < 0) @compileError("negative grow weight in layout"),
                .percent => |p| if (p < 0.0 or p > 1.0) @compileError("invalid percent in layout (must be 0.0-1.0)"),
                .fixed => {},
            }
        }
    }

    const fixed_total = comptime blk: {
        var total: u16 = 0;
        for (container.items) |item| {
            switch (item.sizing) {
                .fixed => |s| total += s,
                else => {},
            }
        }
        break :blk total;
    };

    const total_weight = comptime blk: {
        var total: f32 = 0;
        for (container.items) |item| {
            switch (item.sizing) {
                .grow => |w| total += w,
                else => {},
            }
        }
        break :blk total;
    };

    const is_row = container.direction == .row;
    const main_size = if (is_row) available.width else available.height;
    const cross_size = if (is_row) available.height else available.width;

    // Percent total depends on runtime main_size
    var percent_total: u16 = 0;
    inline for (container.items) |item| {
        switch (item.sizing) {
            .percent => |p| {
                percent_total += @intFromFloat(p * @as(f32, @floatFromInt(main_size)));
            },
            else => {},
        }
    }

    const remaining = main_size -| fixed_total -| percent_total;

    var result: [container.items.len]Rect = undefined;
    var main_pos: u16 = if (is_row) available.x else available.y;

    inline for (container.items, 0..) |item, i| {
        const item_main_size: u16 = switch (item.sizing) {
            .fixed => |size| size,
            .percent => |p| @intFromFloat(p * @as(f32, @floatFromInt(main_size))),
            .grow => |weight| calculateGrowSize(weight, total_weight, remaining),
        };

        result[i] = .{
            .x = if (is_row) main_pos else available.x,
            .y = if (is_row) available.y else main_pos,
            .width = if (is_row) item_main_size else cross_size,
            .height = if (is_row) available.height else item_main_size,
        };

        main_pos += item_main_size;
    }

    return result;
}

// --- Test containers (file-scope for comptime) ---
const test_row_container = Container.row(&[_]Item{
    .{ .sizing = .{ .fixed = 20 } },
    .{ .sizing = .{ .grow = 1.0 } },
    .{ .sizing = .{ .grow = 2.0 } },
});

const test_col_container = Container.column(&[_]Item{
    .{ .sizing = .{ .fixed = 5 } },
    .{ .sizing = .{ .grow = 1.0 } },
    .{ .sizing = .{ .fixed = 3 } },
});

const test_inner_column = Container.column(&[_]Item{
    .{ .sizing = .{ .grow = 1.0 } },
    .{ .sizing = .{ .grow = 1.0 } },
});

const test_outer_row = Container.row(&[_]Item{
    .{ .sizing = .{ .grow = 2.0 } },
    .{ .sizing = .{ .grow = 1.0 } },
});

// Tests

test "calculate positions row items correctly" {
    const available = Rect{ .x = 0, .y = 0, .width = 100, .height = 30 };
    const rects = calculate(test_row_container, available);

    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 20), rects[0].width);
    try std.testing.expectEqual(@as(u16, 30), rects[0].height);

    try std.testing.expectEqual(@as(u16, 20), rects[1].x);
    try std.testing.expectEqual(@as(u16, 26), rects[1].width);

    try std.testing.expectEqual(@as(u16, 46), rects[2].x);
    try std.testing.expectEqual(@as(u16, 53), rects[2].width);
}

test "calculate positions column items correctly" {
    const available = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const rects = calculate(test_col_container, available);

    try std.testing.expectEqual(@as(u16, 0), rects[0].y);
    try std.testing.expectEqual(@as(u16, 5), rects[0].height);
    try std.testing.expectEqual(@as(u16, 80), rects[0].width);

    try std.testing.expectEqual(@as(u16, 5), rects[1].y);
    try std.testing.expectEqual(@as(u16, 16), rects[1].height);

    try std.testing.expectEqual(@as(u16, 21), rects[2].y);
    try std.testing.expectEqual(@as(u16, 3), rects[2].height);
}

test "calculate handles nested containers via separate calls" {
    const available = Rect{ .x = 0, .y = 0, .width = 90, .height = 30 };
    const outer_rects = calculate(test_outer_row, available);

    try std.testing.expectEqual(@as(u16, 0), outer_rects[0].x);
    try std.testing.expectEqual(@as(u16, 60), outer_rects[0].width);

    try std.testing.expectEqual(@as(u16, 60), outer_rects[1].x);
    try std.testing.expectEqual(@as(u16, 30), outer_rects[1].width);

    const inner_rects = calculate(test_inner_column, outer_rects[0]);

    try std.testing.expectEqual(@as(u16, 0), inner_rects[0].x);
    try std.testing.expectEqual(@as(u16, 0), inner_rects[0].y);
    try std.testing.expectEqual(@as(u16, 60), inner_rects[0].width);
    try std.testing.expectEqual(@as(u16, 15), inner_rects[0].height);

    try std.testing.expectEqual(@as(u16, 0), inner_rects[1].x);
    try std.testing.expectEqual(@as(u16, 15), inner_rects[1].y);
    try std.testing.expectEqual(@as(u16, 60), inner_rects[1].width);
    try std.testing.expectEqual(@as(u16, 15), inner_rects[1].height);
}

test "calculateGrowSize distributes proportionally" {
    const size_a = calculateGrowSize(1.0, 3.0, 90);
    try std.testing.expectEqual(@as(u16, 30), size_a);

    const size_b = calculateGrowSize(2.0, 3.0, 90);
    try std.testing.expectEqual(@as(u16, 60), size_b);
}

test "calculateGrowSize returns zero when total weight is zero" {
    const size = calculateGrowSize(1.0, 0, 100);
    try std.testing.expectEqual(@as(u16, 0), size);
}
