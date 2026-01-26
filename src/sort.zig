const std = @import("std");

pub fn compareByIndex(ctx: anytype, a: usize, b: usize) bool {
    const pids = ctx.hot.items(.pid);
    const cpus = ctx.hot.items(.cpu_percent);
    const mems = ctx.hot.items(.mem_rss);

    const order = switch (ctx.sort_column) {
        .pid => std.math.order(pids[a], pids[b]),
        .cpu => blk: {
            const cmp = std.math.order(cpus[a], cpus[b]);
            break :blk if (cmp != .eq) cmp else std.math.order(pids[a], pids[b]);
        },
        .mem => blk: {
            const cmp = std.math.order(mems[a], mems[b]);
            break :blk if (cmp != .eq) cmp else std.math.order(pids[a], pids[b]);
        },
        .name => blk: {
            const cmp = std.mem.order(u8, ctx.cold.items[a].name, ctx.cold.items[b].name);
            break :blk if (cmp != .eq) cmp else std.math.order(pids[a], pids[b]);
        },
        .path => blk: {
            const cmp = std.mem.order(u8, ctx.cold.items[a].path, ctx.cold.items[b].path);
            break :blk if (cmp != .eq) cmp else std.math.order(pids[a], pids[b]);
        },
    };

    return if (ctx.sort_direction == .asc)
        order == .lt
    else
        order == .gt;
}
