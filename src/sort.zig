const std = @import("std");

pub fn compareByIndex(ctx: anytype, a: usize, b: usize) bool {
    const order = switch (ctx.sort_column) {
        .pid => std.math.order(ctx.hot.items(.pid)[a], ctx.hot.items(.pid)[b]),
        .cpu => std.math.order(ctx.hot.items(.cpu_percent)[a], ctx.hot.items(.cpu_percent)[b]),
        .mem => std.math.order(ctx.hot.items(.mem_rss)[a], ctx.hot.items(.mem_rss)[b]),
        .name => std.mem.order(u8, ctx.cold.items[a].name, ctx.cold.items[b].name),
        .path => std.mem.order(u8, ctx.cold.items[a].path, ctx.cold.items[b].path),
    };

    return if (ctx.sort_direction == .asc)
        order == .lt
    else
        order == .gt;
}
