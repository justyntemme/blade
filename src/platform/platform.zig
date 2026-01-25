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

pub const PlatformError = backend.PlatformError;

pub fn collectSnapshot(allocator: std.mem.Allocator) PlatformError!std.AutoHashMap(backend.pid_t, backend.Proc) {
    return backend.collectSnapshot(allocator);
}

pub fn signal(pid: std.posix.pid_t, force: bool) PlatformError!void {
    return backend.signal(pid, force);
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
