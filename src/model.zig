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
    coalition_id: u64 = 0, // macOS coalition ID - groups app with its XPC services
    start_time_ns: i128 = 0,
    name: []const u8 = "",
    path: []const u8 = "",
    mem_rss: u64 = 0,
    mem_phys: u64 = 0, // phys_footprint from proc_pid_rusage (0 if unavailable)
    total_user: u64 = 0,
    total_system: u64 = 0,
    nice: i32 = 0,
    disk_read_bytes: u64 = 0, // cumulative disk read (from proc_pid_rusage)
    disk_write_bytes: u64 = 0, // cumulative disk write (from proc_pid_rusage)
    idle_wakeups: u64 = 0, // cumulative package idle wakeups
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
    mem: u64, // phys_footprint when available, RSS as fallback
};

pub const ProcHotList = std.MultiArrayList(ProcHot);

pub const ProcCold = struct {
    name: []const u8,
    path: []const u8,
    ppid: std.posix.pid_t,
    pgid: std.posix.pid_t, // Process group ID
    coalition_id: u64, // macOS coalition ID - groups app with its XPC services
    nice: i32,
};

pub const ProcColdList = std.MultiArrayList(ProcCold);

pub const VisibleNode = struct {
    data_idx: u32,
    depth: u16,
    has_children: bool,
    is_last: bool,
    is_expanded: bool,
};

/// Extended task info from Mach task_info() calls (phys_footprint, compressed, faults, etc.)
pub const TaskExtendedInfo = struct {
    // VM info (TASK_VM_INFO)
    phys_footprint: u64 = 0, // Physical memory footprint (what Activity Monitor shows)
    compressed: u64 = 0, // Compressed memory size
    internal: u64 = 0, // Internal (anonymous) memory
    reusable: u64 = 0, // Reusable memory

    // Events info (TASK_EVENTS_INFO)
    faults: u64 = 0, // Page faults
    pageins: u64 = 0, // Page-ins from disk
    cow_faults: u64 = 0, // Copy-on-write faults
    messages_sent: u64 = 0, // Mach messages sent
    messages_received: u64 = 0, // Mach messages received
    syscalls_mach: u64 = 0, // Mach system calls
    syscalls_unix: u64 = 0, // Unix system calls
    csw: u64 = 0, // Context switches

    // Power info (TASK_POWER_INFO_V2 or TASK_POWER_INFO)
    platform_idle_wakeups: u64 = 0, // Platform idle wakeups
    interrupt_wakeups: u64 = 0, // Interrupt wakeups

    available: bool = false, // Whether data was successfully collected
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
    task_extended: TaskExtendedInfo = .{},
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
    thread_id: u64 = 0, // Persistent unique thread ID (from THREAD_IDENTIFIER_INFO)
    dispatch_qaddr: u64 = 0, // GCD dispatch queue address
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

    pub fn fromKernelState(state: i32) TcpState {
        return switch (state) {
            0 => .closed,
            1 => .listen,
            2 => .syn_sent,
            3 => .syn_received,
            4 => .established,
            5 => .close_wait,
            6 => .fin_wait_1,
            7 => .closing,
            8 => .last_ack,
            9 => .fin_wait_2,
            10 => .time_wait,
            else => .unknown,
        };
    }
};

/// System-wide TCP connection (from kernel sysctl, includes PID)
pub const TcpConnection = struct {
    pid: pid_t,
    coalition_id: u64, // For grouping with parent app's XPC services
    local_port: u16,
    remote_port: u16,
    local_addr: [46]u8, // Max IPv6 string length
    local_addr_len: u8,
    remote_addr: [46]u8,
    remote_addr_len: u8,
    state: TcpState,
    is_ipv6: bool,
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
    mem: u64, // phys_footprint when available, RSS as fallback
    name: []const u8,
    path: []const u8,
    nice: i32,
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
    mems: []const u64,
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
    // Per-process network I/O (from nettop, lazy-loaded)
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    bytes_in_rate: f64 = 0, // bytes/sec
    bytes_out_rate: f64 = 0, // bytes/sec
    prev_bytes_in: u64 = 0,
    prev_bytes_out: u64 = 0,
    // Rate history for sparklines (60 samples = ~2 min at 2s intervals)
    in_rate_history: NetRateHistory = .{},
    out_rate_history: NetRateHistory = .{},
};

pub const NET_RATE_HISTORY_LEN = 60;

// --- Mach Port types for privileged port inspection ---

pub const MachPortType = enum(u8) {
    send = 1,
    receive = 2,
    send_once = 3,
    port_set = 4,
    dead_name = 5,
};

pub const MachPort = struct {
    name: u32,
    port_type: MachPortType,
    service_name: [64]u8 = [_]u8{0} ** 64,
    service_name_len: u8 = 0,
    // Receive status (only valid for receive rights)
    msg_count: u32 = 0, // Messages currently in queue
    queue_limit: u32 = 0, // Maximum queue depth
    make_send_count: u32 = 0, // Number of send rights created

    pub fn getServiceName(self: *const MachPort) []const u8 {
        return self.service_name[0..self.service_name_len];
    }
};

pub const MachPortInfo = struct {
    pid: pid_t,
    send_rights: []MachPort,
    receive_rights: []MachPort,
    port_sets: []MachPort,
    dead_names: []MachPort,

    pub fn totalCount(self: *const MachPortInfo) usize {
        return self.send_rights.len + self.receive_rights.len +
            self.port_sets.len + self.dead_names.len;
    }
};

// --- Virtual Memory Map types ---

pub const VmRegionType = enum {
    malloc_small,
    malloc_medium,
    malloc_large,
    malloc_tiny,
    stack,
    dylib,
    mapped_file,
    shared_memory,
    iokit,
    guard,
    other,

    pub fn label(self: VmRegionType) []const u8 {
        return switch (self) {
            .malloc_small => "Malloc Small",
            .malloc_medium => "Malloc Medium",
            .malloc_large => "Malloc Large",
            .malloc_tiny => "Malloc Tiny",
            .stack => "Stack",
            .dylib => "Dylib/Framework",
            .mapped_file => "Mapped File",
            .shared_memory => "Shared Memory",
            .iokit => "IOKit",
            .guard => "Guard",
            .other => "Other",
        };
    }
};

pub const VmRegion = struct {
    address: u64,
    size: u64,
    region_type: VmRegionType,
    protection: u8, // rwx bits
    max_protection: u8,
    user_tag: u32,
};

pub const VmMapSummary = struct {
    total_virtual: u64 = 0,
    total_resident: u64 = 0,
    region_count: usize = 0,
    // Per-type size totals
    malloc_size: u64 = 0,
    stack_size: u64 = 0,
    dylib_size: u64 = 0,
    mapped_file_size: u64 = 0,
    shared_memory_size: u64 = 0,
    iokit_size: u64 = 0,
    guard_size: u64 = 0,
    other_size: u64 = 0,
};

pub const VmMapInfo = struct {
    pid: pid_t,
    regions: []VmRegion,
    summary: VmMapSummary,
};

pub const NetRateHistory = struct {
    samples: [NET_RATE_HISTORY_LEN]f32 = [_]f32{0} ** NET_RATE_HISTORY_LEN,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *NetRateHistory, value: f64) void {
        // Store as f32 to save space, clamp to reasonable range
        self.samples[self.head] = @floatCast(@min(value, 1e12));
        self.head = (self.head + 1) % NET_RATE_HISTORY_LEN;
        if (self.count < NET_RATE_HISTORY_LEN) self.count += 1;
    }

    pub fn get(self: *const NetRateHistory, i: usize) f32 {
        if (i >= self.count) return 0;
        const start = if (self.count < NET_RATE_HISTORY_LEN) 0 else self.head;
        return self.samples[(start + i) % NET_RATE_HISTORY_LEN];
    }

    pub fn max(self: *const NetRateHistory) f32 {
        var max_val: f32 = 0;
        for (0..self.count) |i| {
            const v = self.get(i);
            if (v > max_val) max_val = v;
        }
        return max_val;
    }
};
