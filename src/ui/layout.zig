const std = @import("std");

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

pub fn row(allocator: std.mem.Allocator, items: []const Item, available: Rect) std.StringHashMap(Rect) {
    var result = std.StringHashMap(Rect).init(allocator);
    //calc result
    return result;
}
