const std = @import("std");

pub fn compareProcView(ctx: anytype, a: anytype, b: anytype) bool {
    const order = switch (ctx.sort_column) {
        .pid => std.math.order(a.proc.pid, b.proc.pid),
        .cpu => std.math.order(a.cpu_percent, b.cpu_percent),
        .mem => std.math.order(a.proc.mem_rss, b.proc.mem_rss),
        .name => std.mem.order(u8, std.mem.sliceTo(&a.proc.s_name, 0), std.mem.sliceTo(&b.proc.s_name, 0)),
        .path => std.mem.order(u8, std.mem.sliceTo(&a.proc.path, 0), std.mem.sliceTo(&b.proc.path, 0)),
    };

    return if (ctx.sort_direction == .asc)
        order == .lt
    else
        order == .gt;
}
