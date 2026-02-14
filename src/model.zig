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

pub const pid_t = std.posix.pid_t;

pub const Proc = struct {
    pid: pid_t = 0,
    ppid: pid_t = 0,
    pgid: pid_t = 0, // Process group ID - for session-based grouping
    start_time_ns: i128 = 0,
    name: []const u8 = "",
    path: []const u8 = "",
    mem_rss: u64 = 0,
    total_user: u64 = 0,
    total_system: u64 = 0,
};

pub const ProcessSnapshot = struct {
    pid: std.posix.pid_t,
    start_time_ns: i128,
    cpu_total_ns: u64,
    mem_rss_bytes: u64,
    state: ProcState,

    name: []const u8,
    path: []const u8,
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

pub const ProcHot = struct {
    pid: std.posix.pid_t,
    start_time_ns: i128,
    cpu_percent: f32,
    mem_rss: u64,
};

pub const ProcHotList = std.MultiArrayList(ProcHot);

pub const ProcCold = struct {
    name: []const u8,
    path: []const u8,
    ppid: std.posix.pid_t,
    pgid: std.posix.pid_t, // Process group ID
};

pub const ProcColdList = std.MultiArrayList(ProcCold);

pub const VisibleNode = struct {
    data_idx: u32,
    depth: u16,
    has_children: bool,
    is_last: bool,
    is_expanded: bool,
};

pub const ProcessDetail = struct {
    pid: pid_t,
    ppid: pid_t,
    name: []const u8,
    path: []const u8,
    cmdline: []const u8,
    cwd: []const u8,
    user_name: []const u8,
    uid: u32,
    state: ProcState,
    thread_count: u32,
    nice: i32,
    virtual_mem: u64,
    fd_count: u32,
    start_time_ns: i128,
    environ: []const []const u8,
};

pub const ThreadState = enum {
    running,
    waiting,
    stopped,
    halted,
    unknown,
};

pub const ThreadInfo = struct {
    tid: u64,
    cpu_percent: f32,
    user_time_us: u64,
    system_time_us: u64,
    state: ThreadState,
    name: []const u8,
};

pub const FdType = enum {
    file,
    socket_tcp,
    socket_udp,
    socket_unix,
    pipe,
    kqueue,
    other,
};

pub const TcpState = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    close_wait,
    fin_wait_1,
    closing,
    last_ack,
    fin_wait_2,
    time_wait,
    unknown,

    pub fn label(self: TcpState) []const u8 {
        return switch (self) {
            .closed => "CLOSED",
            .listen => "LISTEN",
            .syn_sent => "SYN_SENT",
            .syn_received => "SYN_RECV",
            .established => "ESTABLISHED",
            .close_wait => "CLOSE_WAIT",
            .fin_wait_1 => "FIN_WAIT_1",
            .closing => "CLOSING",
            .last_ack => "LAST_ACK",
            .fin_wait_2 => "FIN_WAIT_2",
            .time_wait => "TIME_WAIT",
            .unknown => "UNKNOWN",
        };
    }
};

pub const OpenFile = struct {
    fd: i32,
    fd_type: FdType,
    path: []const u8,
    // For sockets
    local_addr: []const u8,
    remote_addr: []const u8,
    tcp_state: TcpState,
};

pub const RenderRow = struct {
    pid: pid_t,
    cpu_percent: f32,
    mem_rss: u64,
    name: []const u8,
    path: []const u8,
    depth: u16,
    has_children: bool,
    is_last: bool,
    is_expanded: bool,
    data_idx: u32,
};

pub const SortColumn = enum { pid, name, cpu, mem, path };
pub const SortDirection = enum { asc, desc };

pub const SortContext = struct {
    pids: []const pid_t,
    cpu_percents: []const f32,
    mem_rsss: []const u64,
    cold_names: []const []const u8,
    cold_paths: []const []const u8,
    sort_column: SortColumn,
    sort_direction: SortDirection,
};

// --- System metrics types for Horizon dashboard ---

pub const MAX_CORES = 128;

pub const CoreTicks = struct {
    user: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    nice: u64 = 0,
};

pub const MAX_INTERFACES = 8;
pub const IFACE_NAME_LEN = 16;

pub const InterfaceIO = struct {
    name: [IFACE_NAME_LEN]u8 = [_]u8{0} ** IFACE_NAME_LEN,
    name_len: u8 = 0,
    bytes_recv: u64 = 0,
    bytes_sent: u64 = 0,
};

pub const IP_ADDR_LEN = 16; // "255.255.255.255\0"

pub const NetworkIO = struct {
    bytes_recv: u64 = 0,
    bytes_sent: u64 = 0,
    interfaces: [MAX_INTERFACES]InterfaceIO = [_]InterfaceIO{.{}} ** MAX_INTERFACES,
    iface_count: u8 = 0,
    ipv4_addr: [IP_ADDR_LEN]u8 = [_]u8{0} ** IP_ADDR_LEN,
    ipv4_addr_len: u8 = 0,
};

pub const DiskIO = struct {
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
};

pub const MemoryDetail = struct {
    total: u64 = 0,
    used: u64 = 0,
    available: u64 = 0,
    cached: u64 = 0,
    free: u64 = 0,
};

pub const MAX_MOUNTS = 16;
pub const MOUNT_NAME_LEN = 32;

pub const MountInfo = struct {
    name: [MOUNT_NAME_LEN]u8 = [_]u8{0} ** MOUNT_NAME_LEN,
    name_len: u8 = 0,
    total_bytes: u64 = 0,
    used_bytes: u64 = 0,
    available_bytes: u64 = 0,
};

pub const MountSnapshot = struct {
    mounts: [MAX_MOUNTS]MountInfo = [_]MountInfo{.{}} ** MAX_MOUNTS,
    mount_count: u8 = 0,
};

pub const SystemMetrics = struct {
    timestamp_ns: i128 = 0,
    core_count: u32 = 0,
    core_ticks: [MAX_CORES]CoreTicks = [_]CoreTicks{.{}} ** MAX_CORES,
    mem_total: u64 = 0,
    mem_used: u64 = 0,
    load_avg: [3]f64 = .{ 0, 0, 0 },
    uptime_seconds: u64 = 0,
    net: NetworkIO = .{},
    disk: DiskIO = .{},
    mem_detail: MemoryDetail = .{},
    // CPU identification and thermal
    cpu_brand: [64]u8 = [_]u8{0} ** 64,
    cpu_brand_len: u8 = 0,
    cpu_freq_mhz: u32 = 0, // 0 = unavailable/dynamic
    cpu_temp_celsius: f32 = 0, // 0 = unavailable (average/package)
    // Per-cluster temps (Apple Silicon: Tp0C=package, Tp09/Tp01/Tp05=clusters)
    cpu_cluster_temps: [12]f32 = [_]f32{0} ** 12,
    cpu_cluster_temp_count: u8 = 0,
};

pub const CPU_HISTORY_LEN = 300;

pub const CpuHistory = struct {
    samples: [CPU_HISTORY_LEN]f32 = [_]f32{0} ** CPU_HISTORY_LEN,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *CpuHistory, value: f32) void {
        self.samples[self.head] = value;
        self.head = (self.head + 1) % CPU_HISTORY_LEN;
        if (self.count < CPU_HISTORY_LEN) self.count += 1;
    }

    /// Returns sample at logical index i (0 = oldest).
    pub fn get(self: *const CpuHistory, i: usize) f32 {
        if (i >= self.count) return 0;
        const start = if (self.count < CPU_HISTORY_LEN) 0 else self.head;
        return self.samples[(start + i) % CPU_HISTORY_LEN];
    }
};

pub const RATE_HISTORY_LEN = 300;

pub const RateHistory = struct {
    samples: [RATE_HISTORY_LEN]f64 = [_]f64{0} ** RATE_HISTORY_LEN,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *RateHistory, value: f64) void {
        self.samples[self.head] = value;
        self.head = (self.head + 1) % RATE_HISTORY_LEN;
        if (self.count < RATE_HISTORY_LEN) self.count += 1;
    }

    /// Returns sample at logical index i (0 = oldest).
    pub fn get(self: *const RateHistory, i: usize) f64 {
        if (i >= self.count) return 0;
        const start = if (self.count < RATE_HISTORY_LEN) 0 else self.head;
        return self.samples[(start + i) % RATE_HISTORY_LEN];
    }

    /// Returns the maximum value in the last `window` samples.
    pub fn maxInWindow(self: *const RateHistory, window: usize) f64 {
        if (self.count == 0) return 0;
        var max_val: f64 = 0;
        const n = @min(window, self.count);
        const start_idx = self.count - n;
        for (start_idx..self.count) |i| {
            const v = self.get(i);
            if (v > max_val) max_val = v;
        }
        return max_val;
    }
};

// --- Per-process socket tracking for network graphs ---

pub const SOCKET_HISTORY_LEN = 60; // 1 minute at 1 sample/sec
pub const MAX_TRACKED_PROCS = 8; // Top N processes to track

pub const SocketHistory = struct {
    samples: [SOCKET_HISTORY_LEN]u32 = [_]u32{0} ** SOCKET_HISTORY_LEN,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *SocketHistory, value: u32) void {
        self.samples[self.head] = value;
        self.head = (self.head + 1) % SOCKET_HISTORY_LEN;
        if (self.count < SOCKET_HISTORY_LEN) self.count += 1;
    }

    /// Returns sample at logical index i (0 = oldest).
    pub fn get(self: *const SocketHistory, i: usize) u32 {
        if (i >= self.count) return 0;
        const start = if (self.count < SOCKET_HISTORY_LEN) 0 else self.head;
        return self.samples[(start + i) % SOCKET_HISTORY_LEN];
    }

    /// Returns the maximum value in the buffer.
    pub fn max(self: *const SocketHistory) u32 {
        var max_val: u32 = 0;
        for (0..self.count) |i| {
            const v = self.get(i);
            if (v > max_val) max_val = v;
        }
        return max_val;
    }
};

pub const TrackedProcess = struct {
    pid: pid_t = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    socket_count: u32 = 0,
    tcp_count: u32 = 0,
    udp_count: u32 = 0,
    unix_count: u32 = 0,
    history: SocketHistory = .{},
    active: bool = false,
};
