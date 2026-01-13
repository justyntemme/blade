const std = @import("std");
// errors
const LayoutError = error{
    InvalidPercent,
    NegativeGrow,
    OutOfMemory,
};
pub const Direction = enum {
    row,
    column,
};
pub const Container = struct {
    direction: Direction,
    items: []const Item,
    gap: u16 = 0,
    //helper functions for syntax sugar const layour = Container.row(..)
    //vs const layout = container{.direction = .row, .items....
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
    id: []const u8,
    sizing: Sizing,
    children: ?*const Container = null,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};
pub const CalculatedLayout = struct {
    rects: std.StringHashMap(Rect),
    allocator: std.mem.Allocator,

    pub fn get(self: *const CalculatedLayout, id: []const u8) ?Rect {
        return self.rects.get(id);
    }
    pub fn deinit(self: *CalculatedLayout) void {
        self.rects.deinit();
    }
};

fn sumGrowWeights(items: []const Item) LayoutError!f32 {
    var total: f32 = 0;
    for (items) |item| {
        switch (item.sizing) {
            .grow => |weight| {
                if (weight < 0) {
                    return error.NegativeGrow;
                }
                total += weight;
            },
            else => {},
        }
    }
    return total;
}
fn sumFixedSizes(items: []const Item) u16 {
    var total: u16 = 0;
    for (items) |item| {
        switch (item.sizing) {
            .fixed => |size| total += size,
            else => {},
        }
    }
    return total;
}

fn sumPercentSizes(items: []const Item, available: u16) LayoutError!u16 {
    var total: u16 = 0;
    for (items) |item| {
        switch (item.sizing) {
            .percent => |p| {
                if (p < 0.0 or p > 1.0) {
                    return error.InvalidPercent;
                }
                const size: u16 = @intFromFloat(p * @as(f32, @floatFromInt(available)));
                total += size;
            },
            else => {},
        }
    }
    return total;
}

fn calculateGrowSize(weight: f32, total_weight: f32, remaining: u16) u16 {
    if (total_weight == 0) return 0;

    const ratio = weight / total_weight;
    const size = ratio * @as(f32, @floatFromInt(remaining));
    return @intFromFloat(size);
}

pub fn calculate(
    allocator: std.mem.Allocator,
    container: Container,
    available: Rect,
) LayoutError!CalculatedLayout {
    var result = CalculatedLayout{
        .rects = std.StringHashMap(Rect).init(allocator),
        .allocator = allocator,
    };
    const is_row = container.direction == .row;
    // determine sizes based on direction
    const main_size = if (is_row) available.width else available.height;
    const cross_size = if (is_row) available.height else available.width;
    // pass 1 measure
    const fixed_total = sumFixedSizes(container.items);
    const percent_total = try sumPercentSizes(container.items, main_size);
    const total_weight = try sumGrowWeights(container.items);

    const remaining = main_size -| fixed_total -| percent_total;

    //pass 2 position
    var main_pos: u16 = if (is_row) available.x else available.y;
    for (container.items) |item| {
        const item_main_size: u16 = switch (item.sizing) {
            .fixed => |size| size,
            .percent => |p| @intFromFloat(p * @as(f32, @floatFromInt(main_size))),
            .grow => |weight| calculateGrowSize(weight, total_weight, remaining),
        };

        //create Rect for item
        const item_rect = Rect{
            .x = if (is_row) main_pos else available.x,
            .y = if (is_row) available.y else main_pos,
            .width = if (is_row) item_main_size else cross_size,
            .height = if (is_row) available.height else item_main_size,
        };

        //store result
        try result.rects.put(item.id, item_rect);

        //move to next item
        main_pos += item_main_size;
    }

    return result;
}

// Tests
test "sumGrowWeights returns error for negative weight" {
    const items = [_]Item{
        .{ .id = "a", .sizing = .{ .grow = -1.0 } },
    };

    const result = sumGrowWeights(&items);
    try std.testing.expectError(error.NegativeGrow, result);
}
test "sumGrowWeights totals only grow items" {
    const items = [_]Item{
        .{ .id = "a", .sizing = .{ .grow = 1.0 } },
        .{ .id = "b", .sizing = .{ .fixed = 10 } },
        .{ .id = "c", .sizing = .{ .grow = 2.5 } },
        .{ .id = "d", .sizing = .{ .percent = 0.5 } },
    };

    const total = try sumGrowWeights(&items);
    try std.testing.expectEqual(@as(f32, 3.5), total);
}

test "sumFixedSizes Totals only fixed items" {
    const items = [_]Item{
        .{ .id = "a", .sizing = .{ .fixed = 10 } },
        .{ .id = "b", .sizing = .{ .grow = 1.0 } },
        .{ .id = "c", .sizing = .{ .fixed = 25 } },
        .{ .id = "d", .sizing = .{ .percent = 0.5 } },
    };

    const total = sumFixedSizes(&items);
    try std.testing.expectEqual(@as(u16, 35), total);
}

test "sumPercentSizes calculates from available space" {
    const items = [_]Item{
        .{ .id = "a", .sizing = .{ .percent = 0.25 } }, // 25% of 200 = 50
        .{ .id = "b", .sizing = .{ .fixed = 10 } }, // ignored
        .{ .id = "c", .sizing = .{ .percent = 0.10 } }, // 10% of 200 = 20
        .{ .id = "d", .sizing = .{ .grow = 1.0 } }, // ignored
    };

    const total = sumPercentSizes(&items, 200);
    try std.testing.expectEqual(@as(u16, 70), total); // 50 + 20
}

test "sumPercentSizes returns error for invalid percent" {
    const items = [_]Item{
        .{ .id = "a", .sizing = .{ .percent = 1.5 } }, // Invalid: 150%
    };

    const result = sumPercentSizes(&items, 200);
    try std.testing.expectError(error.InvalidPercent, result);
}

test "calculateGrowSize distributes proportionally" {
    // 1/3 of 90 = 30
    const size_a = calculateGrowSize(1.0, 3.0, 90);
    try std.testing.expectEqual(@as(u16, 30), size_a);

    // 2/3 of 90 = 60
    const size_b = calculateGrowSize(2.0, 3.0, 90);
    try std.testing.expectEqual(@as(u16, 60), size_b);
}

test "calculateGrowSize returns zero when total weight is zero" {
    const size = calculateGrowSize(1.0, 0, 100);
    try std.testing.expectEqual(@as(u16, 0), size);
}

test "calculate positions row items correctly" {
    const container = Container.row(&[_]Item{
        .{ .id = "fixed", .sizing = .{ .fixed = 20 } },
        .{ .id = "grow1", .sizing = .{ .grow = 1.0 } },
        .{ .id = "grow2", .sizing = .{ .grow = 2.0 } },
    });

    const available = Rect{ .x = 0, .y = 0, .width = 100, .height = 30 };

    var layout = try calculate(std.testing.allocator, container, available);
    defer layout.deinit();

    // Fixed item: starts at 0, width 20
    const fixed_rect = layout.get("fixed").?;
    try std.testing.expectEqual(@as(u16, 0), fixed_rect.x);
    try std.testing.expectEqual(@as(u16, 20), fixed_rect.width);
    try std.testing.expectEqual(@as(u16, 30), fixed_rect.height);

    // Grow items split remaining 80 cells (1:2 ratio = 26:53)
    const grow1_rect = layout.get("grow1").?;
    try std.testing.expectEqual(@as(u16, 20), grow1_rect.x); // starts after fixed
    try std.testing.expectEqual(@as(u16, 26), grow1_rect.width); // 80 * 1/3

    const grow2_rect = layout.get("grow2").?;
    try std.testing.expectEqual(@as(u16, 46), grow2_rect.x); // starts after grow1
    try std.testing.expectEqual(@as(u16, 53), grow2_rect.width); // 80 * 2/3
}

test "calculate positions column items correctly" {
    const container = Container.column(&[_]Item{
        .{ .id = "header", .sizing = .{ .fixed = 5 } },
        .{ .id = "content", .sizing = .{ .grow = 1.0 } },
        .{ .id = "footer", .sizing = .{ .fixed = 3 } },
    });

    const available = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };

    var layout = try calculate(std.testing.allocator, container, available);
    defer layout.deinit();

    // Header: starts at y=0, height=5, full width
    const header = layout.get("header").?;
    try std.testing.expectEqual(@as(u16, 0), header.y);
    try std.testing.expectEqual(@as(u16, 5), header.height);
    try std.testing.expectEqual(@as(u16, 80), header.width);

    // Content: starts at y=5, fills remaining (24-5-3=16)
    const content = layout.get("content").?;
    try std.testing.expectEqual(@as(u16, 5), content.y);
    try std.testing.expectEqual(@as(u16, 16), content.height);

    // Footer: starts at y=21, height=3
    const footer = layout.get("footer").?;
    try std.testing.expectEqual(@as(u16, 21), footer.y);
    try std.testing.expectEqual(@as(u16, 3), footer.height);
}
