const std = @import("std");
const builtin = @import("builtin");
const model = @import("model");

//preprocessor directives (compile time platform selection)
pub const backend = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("Unsupported platform"),
};
pub const Proc = model.Proc;
pub const pid_t = model.pid_t;

pub const PlatformError = backend.PlatformError;

pub fn collectSnapshot(arena: std.mem.Allocator) PlatformError!std.AutoHashMap(pid_t, Proc) {
    return backend.collectSnapshot(arena);
}

pub fn signal(pid: std.posix.pid_t, force: bool) PlatformError!void {
    return backend.signal(pid, force);
}

pub fn renice(pid: std.posix.pid_t, delta: i32) PlatformError!i32 {
    return backend.renice(pid, delta);
}
pub const Capabilities = packed struct {
    can_signal: bool = false,
    has_cpu_time: bool = false,
    has_memory_info: bool = false,
    has_io_stats: bool = false,
    has_start_time: bool = false,
};

pub fn capabilities() Capabilities {
    return backend.capabilities();
}

pub fn collectProcessDetail(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError!model.ProcessDetail {
    return backend.collectProcessDetail(pid, arena);
}

pub fn collectSystemMetrics() model.SystemMetrics {
    return backend.collectSystemMetrics();
}

pub fn collectMountInfo() model.MountSnapshot {
    return backend.collectMountInfo();
}

pub fn collectThreads(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError![]model.ThreadInfo {
    return backend.collectThreads(pid, arena);
}

pub fn collectOpenFiles(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError![]model.OpenFile {
    return backend.collectOpenFiles(pid, arena);
}

/// Socket counts by type
pub const SocketCounts = backend.SocketCounts;

/// Fast socket count for a process (no allocation)
pub fn countSockets(pid: std.posix.pid_t) u32 {
    return backend.countSockets(pid);
}

/// Count sockets by type (TCP, UDP, Unix)
pub fn countSocketsByType(pid: std.posix.pid_t) SocketCounts {
    return backend.countSocketsByType(pid);
}

/// Collect all TCP connections system-wide (includes PID for each connection)
pub fn collectTcpConnections(arena: std.mem.Allocator) PlatformError![]model.TcpConnection {
    return backend.collectTcpConnections(arena);
}
