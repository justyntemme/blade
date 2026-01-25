const std = @import("std");
const model = @import("model");
const platform = @import("platform.zig");

pub const PlatformError = error{
    Unsupported,
};

pub const Proc = struct {
    pid: std.posix.pid_t,
    start_time_ns: i128 = 0,
    s_name: [256:0]u8,
    path: [4096]u8,
    mem_rss: u64 = 0,
    total_user: u64 = 0,
    total_system: u64 = 0,

    pub fn identity(self: *const Proc) model.ProcIdentity {
        return .{ .pid = self.pid, .start_time_ns = @intCast(self.start_time_ns) };
    }
};

pub fn collectSnapshot(allocator: std.mem.Allocator) PlatformError!std.AutoHashMap(std.posix.pid_t, *Proc) {
    _ = allocator;
    return error.Unsupported;
}

pub fn signal(pid: std.posix.pid_t, sig: std.posix.SIG, force: bool) PlatformError!void {
    _ = pid;
    _ = sig;
    _ = force;
    return error.Unsupported;
}

pub fn capabilities() platform.Capabilities {
    return .{}; // All false - nothing supported yet
}
