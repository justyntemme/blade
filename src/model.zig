const std = @import("std");

pub const ProcState = enum {
    running,
    sleeping,
    disk_wait,
    stopped,
    zombie,
    unkown,
};

pub const ProcIdentity = struct {
    pid: std.posix.pid_t,
    start_time_ns: i128,

    pub fn eql(self: ProcIdentity, other: ProcIdentity) bool {
        return self.pid == other.pid and self.start_time_ns == other.start_time_ns;
    }
};

pub const ProcessSnapshot = struct {
    pid: std.posix.pid_t,
    start_time_ns: i128,
    cpu_total_ns: u64,
    mem_rss_bytes: u64,
    state: ProcState,

    name: []const u8,
    path: []const u8,

    pub fn identity(self: *const ProcessSnapshot) ProcIdentity {
        return .{ .pid = self.pid, .start_time_ns = self.start_time_ns };
    }
};

pub const SystemSnapshot = struct {
    timestamp_ns: u64,
    cpu_count: u16,
    total_mem_bytes: u64,
    available_mem_bytes: u64,
    load_avg_1m: f32,
    load_avg_5m: f32,
    load_avg_15m: f32,
};
