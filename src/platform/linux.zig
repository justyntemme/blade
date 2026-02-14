const std = @import("std");
const model = @import("model");
const platform = @import("platform.zig");

pub const Proc = model.Proc;
pub const pid_t = model.pid_t;

pub const PlatformError = error{
    Unsupported,
};

pub fn collectSnapshot(arena: std.mem.Allocator) PlatformError!std.AutoHashMap(std.posix.pid_t, Proc) {
    _ = arena;
    return error.Unsupported;
}

pub fn signal(pid: std.posix.pid_t, force: bool) PlatformError!void {
    _ = pid;
    _ = force;
    return error.Unsupported;
}

pub fn renice(pid: std.posix.pid_t, delta: i32) PlatformError!i32 {
    _ = pid;
    _ = delta;
    return error.Unsupported;
}

pub fn capabilities() platform.Capabilities {
    return .{}; // All false - nothing supported yet
}
