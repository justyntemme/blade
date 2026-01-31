const std = @import("std");
const model = @import("model");

pub fn compareByIndex(ctx: model.SortContext, a: usize, b: usize) bool {
    const order = switch (ctx.sort_column) {
        .pid => std.math.order(ctx.pids[a], ctx.pids[b]),
        .cpu => blk: {
            const cmp = std.math.order(ctx.cpu_percents[a], ctx.cpu_percents[b]);
            break :blk if (cmp != .eq) cmp else std.math.order(ctx.pids[a], ctx.pids[b]);
        },
        .mem => blk: {
            const cmp = std.math.order(ctx.mem_rsss[a], ctx.mem_rsss[b]);
            break :blk if (cmp != .eq) cmp else std.math.order(ctx.pids[a], ctx.pids[b]);
        },
        .name => blk: {
            const cmp = std.mem.order(u8, ctx.cold_items[a].name, ctx.cold_items[b].name);
            break :blk if (cmp != .eq) cmp else std.math.order(ctx.pids[a], ctx.pids[b]);
        },
        .path => blk: {
            const cmp = std.mem.order(u8, ctx.cold_items[a].path, ctx.cold_items[b].path);
            break :blk if (cmp != .eq) cmp else std.math.order(ctx.pids[a], ctx.pids[b]);
        },
    };

    return if (ctx.sort_direction == .asc)
        order == .lt
    else
        order == .gt;
}

pub fn compareByNodeIndex(ctx: model.SortContext, a: u32, b: u32) bool {
    return compareByIndex(ctx, @intCast(a), @intCast(b));
}
