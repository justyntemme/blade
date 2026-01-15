const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});
pub const pid_t = c.pid_t;
pub const Proc = struct { pid: pid_t, s_name: [256:0]u8, path: [4096]u8 };
pub const ProcError = error{
    FailedToGetProcessCount,
    FailedToGetProcessList,
    OutOfMemory,
    PermissionDenied,
    ProcessNotFound,
    Unexpected,
};
pub fn getProcList() ProcError!std.AutoHashMap(pid_t, Proc) {
    // std.debug.print("Entrypoint -> getProcList\n", .{});
    const allocator = std.heap.page_allocator;

    var proc_map: std.AutoHashMap(pid_t, Proc) = .init(allocator);

    const pid_count = c.proc_listpids(c.PROC_ALL_PIDS, 0, null, 0);
    if (pid_count <= 0) {
        std.debug.print("Failed to get process count\n", .{});
        return error.FailedToGetProcessCount;
    }

    // std.debug.print("PID Count {d}\n", .{pid_count});

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

    // std.debug.print("Found {d} processes:\n\n", .{actual_count});

    // Get info for each process
    for (pids[0..actual_count]) |pid| {
        if (pid == 0) continue;
        // SAFETY: proc_pidinfo() fully initializes this struct; we only read fields if info_size > 0
        var proc_info: c.proc_bsdinfo = undefined;
        const info_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTBSDINFO,
            0,
            &proc_info,
            @sizeOf(c.proc_bsdinfo),
        );
        // SAFETY: proc_pidpath() writes to this buffer; we only read path_len bytes
        var path_buf: [4096]u8 = undefined;
        const path_len = c.proc_pidpath(pid, &path_buf, path_buf.len);

        if (info_size > 0) {
            const c_name = std.mem.sliceTo(&proc_info.pbi_name, 0);
            // SAFETY: s_name and path are fully written via @memcpy before struct is used
            var proc = Proc{
                .pid = pid,
                .s_name = undefined,
                .path = undefined,
            };
            @memcpy(proc.s_name[0..c_name.len], c_name);
            proc.s_name[c_name.len] = 0;
            if (path_len != -1) {
                @memcpy(proc.path[0..@intCast(path_len)], path_buf[0..@intCast(path_len)]);
                proc.path[@intCast(path_len)] = 0;
            } else {
                return error.FailedToGetProcessCount;
            }
            try proc_map.put(pid, proc);
        }
    } // for each PID

    return proc_map;
}
pub fn killProcById(pid: pid_t, force: bool) ProcError!void {
    const signal: i32 = if (force) 9 else 15; // KILL if 9 TERM if 15
    const result = std.c.kill(pid, signal);
    if (result == -1) {
        const err = std.c._errno().*;
        return switch (err) {
            1 => ProcError.PermissionDenied,
            3 => ProcError.ProcessNotFound,
            else => ProcError.Unexpected,
        };
    }
}
