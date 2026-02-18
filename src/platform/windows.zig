const std = @import("std");
const model = @import("model");
const platform = @import("platform.zig");

pub const Proc = model.Proc;

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

pub fn suspendProcess(pid: std.posix.pid_t) PlatformError!void {
    _ = pid;
    return error.Unsupported;
}

pub fn resumeProcess(pid: std.posix.pid_t) PlatformError!void {
    _ = pid;
    return error.Unsupported;
}

pub fn capabilities() platform.Capabilities {
    return .{}; // All false - nothing supported yet
}

pub fn collectProcessDetail(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError!model.ProcessDetail {
    _ = pid;
    _ = arena;
    return error.Unsupported;
}

pub fn collectSystemMetrics() model.SystemMetrics {
    return .{};
}

pub fn collectMountInfo() model.MountSnapshot {
    return .{};
}

pub fn collectThreads(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError![]model.ThreadInfo {
    _ = pid;
    _ = arena;
    return error.Unsupported;
}

pub fn collectOpenFiles(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError![]model.OpenFile {
    _ = pid;
    _ = arena;
    return error.Unsupported;
}

pub const SocketCounts = struct {
    tcp: u32 = 0,
    udp: u32 = 0,
    unix: u32 = 0,
    pub fn total(self: SocketCounts) u32 {
        return self.tcp + self.udp + self.unix;
    }
};

pub fn countSockets(pid: std.posix.pid_t) u32 {
    _ = pid;
    return 0;
}

pub fn countSocketsByType(pid: std.posix.pid_t) SocketCounts {
    _ = pid;
    return .{};
}

pub fn collectTcpConnections(arena: std.mem.Allocator) PlatformError![]model.TcpConnection {
    _ = arena;
    return error.Unsupported;
}

pub fn collectVmMap(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError!model.VmMapInfo {
    _ = pid;
    _ = arena;
    return error.Unsupported;
}
