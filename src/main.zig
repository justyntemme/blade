const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});

const proc = @import("proc/proc.zig");

pub fn main() !void {
    std.debug.print("Entrypoint -> main\n", .{});
    var procMap = try proc.getProcList();
    defer procMap.deinit();

    var PIDIter = procMap.iterator();
    while (PIDIter.next()) |elem| {
        std.debug.print("PID: {d:>5}  Path: {s:<}  Sname: {s:<5} \n", .{ elem.value_ptr.PID, std.mem.sliceTo(&elem.value_ptr.Path, 0), std.mem.sliceTo(&elem.value_ptr.Sname, 0) });
    }
}
