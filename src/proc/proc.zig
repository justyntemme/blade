const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});
pub const pid_t = c.pid_t;
pub const Proc = struct { PID: pid_t, Sname: [256:0]u8, Path: [4096]u8 };
const ProcError = error{
    FailedToGetProcessCount,
    FailedToGetProcessList,
};
pub fn getProcList() !std.AutoHashMap(pid_t, Proc) {
    std.debug.print("Entrypoint -> getProcList\n", .{});
    const allocator = std.heap.page_allocator;

    var procMap: std.AutoHashMap(pid_t, Proc) = .init(allocator);

    const pid_count = c.proc_listpids(c.PROC_ALL_PIDS, 0, null, 0);
    if (pid_count <= 0) {
        std.debug.print("Failed to get process count\n", .{});
        return error.FailedToGetProcessCount;
    }

    std.debug.print("PID Count {d}\n", .{pid_count});

    const buffer_size: usize = @intCast(pid_count);
    const pids = try allocator.alloc(pid_t, buffer_size);
    defer allocator.free(pids);

    // Get the actual PIDs
    const bytes_returned = c.proc_listpids(
        c.PROC_ALL_PIDS,
        0,
        pids.ptr,
        @intCast(buffer_size * @sizeOf(pid_t)),
    );

    if (bytes_returned <= 0) {
        std.debug.print("Failed to get process list\n", .{});
        return error.FailedToGetProcessList;
    }
    const actual_count = @as(usize, @intCast(bytes_returned)) / @sizeOf(pid_t);

    std.debug.print("Found {d} processes:\n\n", .{actual_count});

    // Get info for each process
    for (pids[0..actual_count]) |pid| {
        if (pid == 0) continue;

        var proc_info: c.proc_bsdinfo = undefined;
        const info_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTBSDINFO,
            0,
            &proc_info,
            @sizeOf(c.proc_bsdinfo),
        );
        var path_buf: [4096]u8 = undefined;
        const path_len = c.proc_pidpath(pid, &path_buf, path_buf.len);

        if (info_size > 0) {
            const Cname = std.mem.sliceTo(&proc_info.pbi_name, 0);
            var proc = Proc{
                .PID = pid,
                .Sname = undefined,
                .Path = undefined,
            };
            @memcpy(proc.Sname[0..Cname.len], Cname);
            proc.Sname[Cname.len] = 0;
            if (path_len != -1) {
                @memcpy(proc.Path[0..@intCast(path_len)], path_buf[0..@intCast(path_len)]);
                proc.Path[@intCast(path_len)] = 0;
            } else {
                return error.FailedToGetProcessCount;
            }
            try procMap.put(pid, proc);
        }
    } // for each PID

    return procMap;
}
