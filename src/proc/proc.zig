const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});

pub const ProcError = error{
    FailedToGetProcessCount,
    FailedToGetProcessList,
    FailedToGetProcPath,
    OutOfMemory,
    PermissionDenied,
    ProcessNotFound,
    Unexpected,
};

pub const pid_t = c.pid_t;
pub const Proc = struct {
    pid: pid_t,
    start_time_ns: i128 = 0,
    s_name: [256:0]u8,
    path: [4096]u8,
    mem_rss: u64 = 0,
    total_user: u64 = 0,
    total_system: u64 = 0,

    pub fn identity(self: *const Proc) ProcIdentity {
        return .{ .pid = self.pid, .start_time_ns = self.start_time_ns };
    }
};
pub const ProcIdentity = struct {
    pid: pid_t,
    start_time_ns: i128,

    pub fn eql(self: ProcIdentity, other: ProcIdentity) bool {
        return self.pid == other.pid and self.start_time_ns == other.start_time_ns;
    }
};

pub fn getProcList(allocator: std.mem.Allocator) ProcError!std.AutoHashMap(pid_t, Proc) {
    var proc_map: std.AutoHashMap(pid_t, Proc) = .init(allocator);
    const bytes = c.proc_listpids(c.PROC_ALL_PIDS, 0, null, 0);
    const count = @divExact(@as(usize, @intCast(bytes)), @sizeOf(pid_t));
    const pids = try allocator.alloc(pid_t, count);
    if (count <= 0) {
        std.debug.print("Failed to get process count\n", .{});
        return error.FailedToGetProcPath;
    }

    // Get the actual PIDs
    const bytes_returned = c.proc_listpids(
        c.PROC_ALL_PIDS,
        0,
        pids.ptr,
        @intCast(count * @sizeOf(pid_t)),
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

        // SAFETY: proc_pidinfo() fully initializes this struct; we only read fields if info_size > 0
        var task_info: c.proc_taskinfo = undefined;

        const info_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTBSDINFO,
            0,
            &proc_info,
            @sizeOf(c.proc_bsdinfo),
        );

        const task_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTASKINFO,
            9,
            &task_info,
            @sizeOf(c.proc_taskinfo),
        );
        // SAFETY: proc_pidpath() writes to this buffer; we only read path_len bytes
        var path_buf: [4096]u8 = undefined;
        const path_len = c.proc_pidpath(pid, &path_buf, path_buf.len);

        if (info_size > 0) {
            const c_name = std.mem.sliceTo(&proc_info.pbi_name, 0);
            const start_sec: i128 = @intCast(proc_info.pbi_start_tvsec);
            const start_usec: i128 = @intCast(proc_info.pbi_start_tvusec);
            const start_time_ns = start_sec * std.time.ns_per_s + start_usec * std.time.ns_per_us;
            // SAFETY: s_name and path are fully written via @memcpy before struct is used
            var proc = Proc{
                .pid = pid,
                .start_time_ns = start_time_ns,
                .s_name = undefined,
                .path = undefined,
                .mem_rss = if (task_size > 0) task_info.pti_resident_size else 0,
                .total_user = if (task_size > 0) task_info.pti_total_user else 0,
                .total_system = if (task_size > 0) task_info.pti_total_system else 0,
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
    const signal: i32 = if (force) std.posix.SIG.KILL else std.posix.SIG.TERM;
    const result = std.c.kill(pid, signal);
    const e = std.posix.errno(result); // Retrive err enum from C result code
    if (e != .SUCCESS) {
        return switch (e) {
            .PERM => ProcError.PermissionDenied,
            .SRCH => ProcError.ProcessNotFound,
            else => ProcError.Unexpected,
        };
    }
}
