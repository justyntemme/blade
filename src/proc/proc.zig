const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});
const model = @import("model");
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

    pub fn identity(self: *const Proc) model.ProcIdentity {
        return .{ .pid = self.pid, .start_time_ns = @intCast(self.start_time_ns) };
    }

    pub fn toSnapshot(self: *const Proc, arena: std.mem.Allocator) !model.ProcessSnapshot {
        const name_slice = std.mem.sliceTo(&self.s_name, 0);
        const path_slice = std.mem.sliceTo(&self.path, 0);
        return .{
            .pid = self.pid,
            .start_time_ns = @intCast(self.start_time_ns),
            .cpu_total_ns = self.total_user + self.total_system,
            .mem_rss_bytes = self.mem_rss,
            .state = .unkown, //TODO map from bsd status in future
            .name = try arena.dupe(u8, name_slice),
            .path = try arena.dupe(u8, path_slice),
        };
    }
};
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
