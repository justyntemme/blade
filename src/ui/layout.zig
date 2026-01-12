const std = @import("std");
// errors
const LayoutError = error{
    InvalidPercent,
    NegativeGrow,
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
    pub fn definit(self: *CalculatedLayout) void {
        self.rects.definit();
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
