const std = @import("std");
const channel = @import("thread_channel");
const procs = @import("procs");
const zigtui = @import("zigtui");
const model = @import("model");
const keymap = @import("event_keymap");

pub const SortColumn = model.SortColumn;
pub const SortDirection = model.SortDirection;

pub const SystemState = struct {
    core_count: u32 = 0,
    core_percents: [model.MAX_CORES]f32 = [_]f32{0} ** model.MAX_CORES,
    core_user_percents: [model.MAX_CORES]f32 = [_]f32{0} ** model.MAX_CORES,
    core_system_percents: [model.MAX_CORES]f32 = [_]f32{0} ** model.MAX_CORES,
    total_cpu_percent: f32 = 0,
    total_user_percent: f32 = 0,
    total_system_percent: f32 = 0,
    cpu_history: model.CpuHistory = .{},
    cpu_user_history: model.CpuHistory = .{},
    cpu_system_history: model.CpuHistory = .{},
    core_histories: [model.MAX_CORES]model.CpuHistory = [_]model.CpuHistory{.{}} ** model.MAX_CORES,
    core_user_histories: [model.MAX_CORES]model.CpuHistory = [_]model.CpuHistory{.{}} ** model.MAX_CORES,
    core_system_histories: [model.MAX_CORES]model.CpuHistory = [_]model.CpuHistory{.{}} ** model.MAX_CORES,
    mem_total: u64 = 0,
    mem_used: u64 = 0,
    mem_history: model.CpuHistory = .{},
    load_avg: [3]f64 = .{ 0, 0, 0 },
    uptime_seconds: u64 = 0,
    disk_read_rate: f64 = 0,
    disk_write_rate: f64 = 0,
    net_recv_rate: f64 = 0,
    net_sent_rate: f64 = 0,
    disk_read_history: model.RateHistory = .{},
    disk_write_history: model.RateHistory = .{},
    net_recv_history: model.RateHistory = .{},
    net_sent_history: model.RateHistory = .{},
    // Detailed memory fields
    mem_available: u64 = 0,
    mem_cached: u64 = 0,
    mem_free: u64 = 0,
    // Per-category memory histories (percentage 0-100)
    mem_used_history: model.CpuHistory = .{},
    mem_available_history: model.CpuHistory = .{},
    mem_cached_history: model.CpuHistory = .{},
    mem_free_history: model.CpuHistory = .{},

    // Network cumulative totals (for Sync pane)
    net_total_recv: u64 = 0,
    net_total_sent: u64 = 0,
    // IPv4 address
    ipv4_addr: [model.IP_ADDR_LEN]u8 = [_]u8{0} ** model.IP_ADDR_LEN,
    ipv4_addr_len: u8 = 0,

    // Per-interface network state
    iface_count: u8 = 0,
    iface_names: [model.MAX_INTERFACES][model.IFACE_NAME_LEN]u8 = [_][model.IFACE_NAME_LEN]u8{[_]u8{0} ** model.IFACE_NAME_LEN} ** model.MAX_INTERFACES,
    iface_name_lens: [model.MAX_INTERFACES]u8 = [_]u8{0} ** model.MAX_INTERFACES,
    iface_recv_rates: [model.MAX_INTERFACES]f64 = [_]f64{0} ** model.MAX_INTERFACES,
    iface_sent_rates: [model.MAX_INTERFACES]f64 = [_]f64{0} ** model.MAX_INTERFACES,
    iface_recv_histories: [model.MAX_INTERFACES]model.RateHistory = [_]model.RateHistory{.{}} ** model.MAX_INTERFACES,
    iface_sent_histories: [model.MAX_INTERFACES]model.RateHistory = [_]model.RateHistory{.{}} ** model.MAX_INTERFACES,
    iface_total_recv: [model.MAX_INTERFACES]u64 = [_]u64{0} ** model.MAX_INTERFACES,
    iface_total_sent: [model.MAX_INTERFACES]u64 = [_]u64{0} ** model.MAX_INTERFACES,

    // Disk mount info (updated via SPSC queue)
    mounts: [model.MAX_MOUNTS]model.MountInfo = [_]model.MountInfo{.{}} ** model.MAX_MOUNTS,
    mount_count: u8 = 0,

    // CPU identification and thermal
    cpu_brand: [64]u8 = [_]u8{0} ** 64,
    cpu_brand_len: u8 = 0,
    cpu_freq_mhz: u32 = 0, // 0 = unavailable/dynamic
    cpu_temp_celsius: f32 = 0, // 0 = unavailable (average/package)
    cpu_cluster_temps: [12]f32 = [_]f32{0} ** 12,
    cpu_cluster_temp_count: u8 = 0,

    // Per-process socket tracking (for network by-process graphs)
    tracked_procs: [model.MAX_TRACKED_PROCS]model.TrackedProcess = [_]model.TrackedProcess{.{}} ** model.MAX_TRACKED_PROCS,
    tracked_proc_count: u8 = 0,

    // System-wide TCP connections (from sysctl, includes PID)
    tcp_connections: [MAX_TCP_CONNECTIONS]model.TcpConnection = undefined,
    tcp_connection_count: u16 = 0,

    prev_metrics: ?model.SystemMetrics = null,
    has_data: bool = false,

    pub const MAX_TCP_CONNECTIONS = 1024;

    pub fn update(self: *SystemState, metrics: model.SystemMetrics) void {
        self.core_count = metrics.core_count;
        self.mem_total = metrics.mem_total;
        self.mem_used = metrics.mem_used;
        self.load_avg = metrics.load_avg;
        self.uptime_seconds = metrics.uptime_seconds;

        // CPU identification and thermal
        if (metrics.cpu_brand_len > 0) {
            @memcpy(self.cpu_brand[0..metrics.cpu_brand_len], metrics.cpu_brand[0..metrics.cpu_brand_len]);
            self.cpu_brand_len = metrics.cpu_brand_len;
        }
        self.cpu_freq_mhz = metrics.cpu_freq_mhz;
        self.cpu_temp_celsius = metrics.cpu_temp_celsius;
        self.cpu_cluster_temps = metrics.cpu_cluster_temps;
        self.cpu_cluster_temp_count = metrics.cpu_cluster_temp_count;

        // Detailed memory
        self.mem_available = metrics.mem_detail.available;
        self.mem_cached = metrics.mem_detail.cached;
        self.mem_free = metrics.mem_detail.free;

        // Network absolute data (valid from first sample, like core_count/mem_total)
        self.net_total_recv = metrics.net.bytes_recv;
        self.net_total_sent = metrics.net.bytes_sent;
        if (metrics.net.ipv4_addr_len > 0) {
            @memcpy(self.ipv4_addr[0..metrics.net.ipv4_addr_len], metrics.net.ipv4_addr[0..metrics.net.ipv4_addr_len]);
            self.ipv4_addr_len = metrics.net.ipv4_addr_len;
        }

        // Per-interface identity (names, cumulative totals) — available from first sample.
        // Rates are computed below only when prev_metrics exists.
        {
            const cur_count = metrics.net.iface_count;
            self.iface_count = cur_count;
            for (0..cur_count) |i| {
                const cur_iface = metrics.net.interfaces[i];
                @memcpy(self.iface_names[i][0..cur_iface.name_len], cur_iface.name[0..cur_iface.name_len]);
                self.iface_name_lens[i] = cur_iface.name_len;
                self.iface_total_recv[i] = cur_iface.bytes_recv;
                self.iface_total_sent[i] = cur_iface.bytes_sent;
            }
        }

        if (self.prev_metrics) |prev| {
            // Per-core CPU% from tick deltas
            var total_active: u64 = 0;
            var total_all: u64 = 0;
            var total_user_ticks: u64 = 0;
            var total_system_ticks: u64 = 0;
            const count = @min(metrics.core_count, model.MAX_CORES);
            for (0..count) |i| {
                const cur = metrics.core_ticks[i];
                const old = prev.core_ticks[i];
                const d_user = cur.user -| old.user;
                const d_system = cur.system -| old.system;
                const d_idle = cur.idle -| old.idle;
                const d_nice = cur.nice -| old.nice;
                const d_active = d_user + d_system + d_nice;
                const d_total = d_active + d_idle;
                if (d_total > 0) {
                    const ft: f32 = @floatFromInt(d_total);
                    self.core_percents[i] = @as(f32, @floatFromInt(d_active)) / ft * 100.0;
                    self.core_user_percents[i] = @as(f32, @floatFromInt(d_user + d_nice)) / ft * 100.0;
                    self.core_system_percents[i] = @as(f32, @floatFromInt(d_system)) / ft * 100.0;
                } else {
                    self.core_percents[i] = 0;
                    self.core_user_percents[i] = 0;
                    self.core_system_percents[i] = 0;
                }
                self.core_histories[i].push(self.core_percents[i]);
                self.core_user_histories[i].push(self.core_user_percents[i]);
                self.core_system_histories[i].push(self.core_system_percents[i]);
                total_active += d_active;
                total_all += d_total;
                total_user_ticks += d_user + d_nice;
                total_system_ticks += d_system;
            }
            if (total_all > 0) {
                self.total_cpu_percent = @as(f32, @floatFromInt(total_active)) / @as(f32, @floatFromInt(total_all)) * 100.0;
                self.total_user_percent = @as(f32, @floatFromInt(total_user_ticks)) / @as(f32, @floatFromInt(total_all)) * 100.0;
                self.total_system_percent = @as(f32, @floatFromInt(total_system_ticks)) / @as(f32, @floatFromInt(total_all)) * 100.0;
            }

            // Rates from cumulative deltas
            const ts_cur = metrics.timestamp_ns;
            const ts_prev = prev.timestamp_ns;
            const dt_ns = ts_cur - ts_prev;
            if (dt_ns > 0) {
                const dt_s: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(@min(dt_ns, std.math.maxInt(i64)))))) / 1_000_000_000.0;
                self.disk_read_rate = @as(f64, @floatFromInt(metrics.disk.bytes_read -| prev.disk.bytes_read)) / dt_s;
                self.disk_write_rate = @as(f64, @floatFromInt(metrics.disk.bytes_written -| prev.disk.bytes_written)) / dt_s;
                self.net_recv_rate = @as(f64, @floatFromInt(metrics.net.bytes_recv -| prev.net.bytes_recv)) / dt_s;
                self.net_sent_rate = @as(f64, @floatFromInt(metrics.net.bytes_sent -| prev.net.bytes_sent)) / dt_s;

                // Per-interface rates (names/totals already stored above)
                for (0..metrics.net.iface_count) |i| {
                    const cur_iface = metrics.net.interfaces[i];
                    const cur_name = cur_iface.name[0..cur_iface.name_len];

                    // Find matching previous interface by name
                    var prev_recv: u64 = 0;
                    var prev_sent: u64 = 0;
                    for (0..prev.net.iface_count) |j| {
                        const prev_iface = prev.net.interfaces[j];
                        const prev_name = prev_iface.name[0..prev_iface.name_len];
                        if (std.mem.eql(u8, cur_name, prev_name)) {
                            prev_recv = prev_iface.bytes_recv;
                            prev_sent = prev_iface.bytes_sent;
                            break;
                        }
                    }

                    self.iface_recv_rates[i] = @as(f64, @floatFromInt(cur_iface.bytes_recv -| prev_recv)) / dt_s;
                    self.iface_sent_rates[i] = @as(f64, @floatFromInt(cur_iface.bytes_sent -| prev_sent)) / dt_s;
                    self.iface_recv_histories[i].push(self.iface_recv_rates[i]);
                    self.iface_sent_histories[i].push(self.iface_sent_rates[i]);
                }
            }
        }

        self.cpu_history.push(self.total_cpu_percent);
        self.cpu_user_history.push(self.total_user_percent);
        self.cpu_system_history.push(self.total_system_percent);
        if (self.mem_total > 0) {
            const mt: f32 = @floatFromInt(self.mem_total);
            const mem_pct: f32 = @as(f32, @floatFromInt(self.mem_used)) / mt * 100.0;
            self.mem_history.push(mem_pct);
            self.mem_used_history.push(mem_pct);
            self.mem_available_history.push(@as(f32, @floatFromInt(self.mem_available)) / mt * 100.0);
            self.mem_cached_history.push(@as(f32, @floatFromInt(self.mem_cached)) / mt * 100.0);
            self.mem_free_history.push(@as(f32, @floatFromInt(self.mem_free)) / mt * 100.0);
        }
        self.disk_read_history.push(self.disk_read_rate);
        self.disk_write_history.push(self.disk_write_rate);
        self.net_recv_history.push(self.net_recv_rate);
        self.net_sent_history.push(self.net_sent_rate);
        self.prev_metrics = metrics;
        self.has_data = true;
    }

    /// Update per-process socket tracking. Called with current process data.
    pub fn updateSocketTracking(self: *SystemState, pids: []const model.pid_t, names: []const []const u8) void {
        const platform = @import("platform");

        // Temporary storage for this frame's socket counts
        const Entry = struct {
            pid: model.pid_t,
            counts: platform.SocketCounts,
            name_idx: usize,
        };
        var entries: [128]Entry = undefined;
        var entry_count: usize = 0;

        // Collect socket counts by type for all processes
        for (pids, 0..) |pid, i| {
            const counts = platform.countSocketsByType(pid);
            if (counts.total() > 0 and entry_count < 128) {
                entries[entry_count] = .{ .pid = pid, .counts = counts, .name_idx = i };
                entry_count += 1;
            }
        }

        // Sort by total socket count descending (simple insertion sort for small N)
        for (1..entry_count) |i| {
            const key = entries[i];
            var j: usize = i;
            while (j > 0 and entries[j - 1].counts.total() < key.counts.total()) {
                entries[j] = entries[j - 1];
                j -= 1;
            }
            entries[j] = key;
        }

        // Update tracked processes - keep top N
        const to_track = @min(entry_count, model.MAX_TRACKED_PROCS);

        // Mark all as inactive first
        for (&self.tracked_procs) |*tp| {
            tp.active = false;
        }

        for (0..to_track) |i| {
            const entry = entries[i];
            const name = names[entry.name_idx];

            // Find existing slot for this PID or use new slot
            var slot: ?usize = null;
            for (0..model.MAX_TRACKED_PROCS) |j| {
                if (self.tracked_procs[j].pid == entry.pid) {
                    slot = j;
                    break;
                }
            }
            if (slot == null) {
                // Find an inactive slot
                for (0..model.MAX_TRACKED_PROCS) |j| {
                    if (!self.tracked_procs[j].active and self.tracked_procs[j].pid == 0) {
                        slot = j;
                        break;
                    }
                }
            }
            if (slot == null) {
                // Reuse first inactive slot
                for (0..model.MAX_TRACKED_PROCS) |j| {
                    if (!self.tracked_procs[j].active) {
                        slot = j;
                        // Reset history when reusing slot
                        self.tracked_procs[j].history = .{};
                        break;
                    }
                }
            }

            if (slot) |s| {
                var tp = &self.tracked_procs[s];
                tp.pid = entry.pid;
                tp.socket_count = entry.counts.total();
                tp.tcp_count = entry.counts.tcp;
                tp.udp_count = entry.counts.udp;
                tp.unix_count = entry.counts.unix;
                tp.active = true;
                tp.history.push(entry.counts.total());

                // Copy name
                const name_len = @min(name.len, tp.name.len);
                @memcpy(tp.name[0..name_len], name[0..name_len]);
                tp.name_len = @intCast(name_len);
            }
        }

        // Count active tracked procs
        var count: u8 = 0;
        for (self.tracked_procs) |tp| {
            if (tp.active) count += 1;
        }
        self.tracked_proc_count = count;
    }
};

pub const ToastLevel = enum { info, success, warning, err };

pub const CpuOverlayMode = enum { cores, aggregate };
pub const TempUnit = enum { celsius, fahrenheit };
pub const StorageDetailMode = enum { compact, full, with_swap };
pub const MountFilter = enum { user_only, all };
pub const DashboardGraphMode = enum { cpu, memory };
pub const NetworkDisplayMode = enum {
    by_interface,
    by_process, // Socket connection counts with sparklines
    by_process_detail, // Detailed I/O rates per process (from nettop)

    pub fn next(self: NetworkDisplayMode) NetworkDisplayMode {
        return switch (self) {
            .by_interface => .by_process,
            .by_process => .by_process_detail,
            .by_process_detail => .by_interface,
        };
    }

    pub fn label(self: NetworkDisplayMode) []const u8 {
        return switch (self) {
            .by_interface => "iface",
            .by_process => "connections",
            .by_process_detail => "process",
        };
    }
};
pub const NetworkProtocolFilter = enum {
    all,
    tcp,
    udp,
    unix,

    pub fn label(self: NetworkProtocolFilter) []const u8 {
        return switch (self) {
            .all => "All",
            .tcp => "TCP",
            .udp => "UDP",
            .unix => "Unix",
        };
    }

    pub fn next(self: NetworkProtocolFilter) NetworkProtocolFilter {
        return switch (self) {
            .all => .tcp,
            .tcp => .udp,
            .udp => .unix,
            .unix => .all,
        };
    }
};
pub const DetailViewMode = enum { info, network };

pub const ConfirmAction = enum {
    kill_term,
    kill_force,
};

pub const ConfirmDialog = struct {
    title_buf: [64]u8 = [_]u8{0} ** 64,
    title_len: usize = 0,
    message_buf: [128]u8 = [_]u8{0} ** 128,
    message_len: usize = 0,
    action: ConfirmAction = .kill_term,
    target_pid: model.pid_t = 0,
    target_name_buf: [64]u8 = [_]u8{0} ** 64,
    target_name_len: usize = 0,

    pub fn getTitle(self: *const ConfirmDialog) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn getMessage(self: *const ConfirmDialog) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn getTargetName(self: *const ConfirmDialog) []const u8 {
        return self.target_name_buf[0..self.target_name_len];
    }
};

pub const Toast = struct {
    message_buf: [128]u8 = [_]u8{0} ** 128,
    message_len: usize = 0,
    level: ToastLevel = .info,
    expired_at: i64 = 0,

    pub fn getMessage(self: *const Toast) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

pub const AppState = struct {
    running: bool = true,
    terminal: ?*zigtui.Terminal = null,
    gpa: std.mem.Allocator,
    selected_item: usize = 0,
    scroll_offset: usize = 0,
    active_toast: ?Toast = null,
    mode: keymap.Mode = .normal,
    previous_mode: keymap.Mode = .normal,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    last_update_ns: i128 = 0,
    detail_queue: *channel.DetailQueue = undefined,
    mount_queue: *channel.MountQueue = undefined,
    nettop_queue: *channel.NettopQueue = undefined,
    tcp_connections_queue: *channel.TcpConnectionsQueue = undefined,
    last_mount_collect_ns: i128 = 0,
    last_nettop_collect_ns: i128 = 0,
    last_tcp_collect_ns: i128 = 0,
    nettop_pending: bool = false,
    tcp_pending: bool = false,
    detail_pid: ?model.pid_t = null,
    detail_data: ?model.ProcessDetail = null,
    detail_arena: ?std.heap.ArenaAllocator = null,
    detail_scroll: usize = 0,
    detail_right_scroll: usize = 0,
    detail_focus: DetailFocus = .left,
    detail_view_mode: DetailViewMode = .info,
    detail_open_files: ?[]const model.OpenFile = null,
    help_scroll: usize = 0,
    procs: procs.Store,
    system: SystemState = .{},
    cpu_overlay_mode: CpuOverlayMode = .cores,
    dashboard_graph_mode: DashboardGraphMode = .cpu,
    temp_unit: TempUnit = .celsius,
    storage_detail_mode: StorageDetailMode = .with_swap,
    mount_filter: MountFilter = .all,
    network_display_mode: NetworkDisplayMode = .by_interface,
    network_protocol_filter: NetworkProtocolFilter = .all,
    confirm_dialog: ?ConfirmDialog = null,
    /// Maps pinned process identity to its pinned row position
    pinned_pids: std.AutoHashMap(model.ProcIdentity, usize) = undefined,
    pinned_pids_initialized: bool = false,

    pub const DetailFocus = enum { left, right };

    pub fn init(gpa: std.mem.Allocator) AppState {
        return .{
            .gpa = gpa,
            .procs = procs.Store.init(gpa),
            .pinned_pids = std.AutoHashMap(model.ProcIdentity, usize).init(gpa),
            .pinned_pids_initialized = true,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.closeDetail();
        self.procs.deinit();
        if (self.pinned_pids_initialized) {
            self.pinned_pids.deinit();
        }
    }

    /// Toggle pinning a process at its current row position
    pub fn toggleSelection(self: *AppState, pid: model.pid_t, start_time_ns: i128, row_position: usize) void {
        const id = model.ProcIdentity{ .pid = pid, .start_time_ns = start_time_ns };
        if (self.pinned_pids.contains(id)) {
            _ = self.pinned_pids.remove(id);
        } else {
            self.pinned_pids.put(id, row_position) catch {};
        }
    }

    pub fn isSelected(self: *const AppState, pid: model.pid_t, start_time_ns: i128) bool {
        const id = model.ProcIdentity{ .pid = pid, .start_time_ns = start_time_ns };
        return self.pinned_pids.contains(id);
    }

    pub fn clearSelections(self: *AppState) void {
        self.pinned_pids.clearRetainingCapacity();
    }

    pub fn getSelectedCount(self: *const AppState) usize {
        return self.pinned_pids.count();
    }

    /// Ensure pinned processes are visible and at their stored positions.
    /// In search view: pinned processes appear at the TOP (not at stored positions).
    /// In normal view: pinned processes stay at their stored positions.
    pub fn reorderPinnedRows(self: *AppState) void {
        if (self.pinned_pids.count() == 0) return;

        const in_search = (self.mode == .search_view or self.mode == .search_edit);

        const hot = self.procs.hot.slice();
        const pids = hot.items(.pid);
        const start_times = hot.items(.start_time_ns);
        const cpu_percents = hot.items(.cpu_percent);
        const mem_rsss = hot.items(.mem_rss);
        const cold = self.procs.cold.slice();
        const names = cold.items(.name);
        const paths = cold.items(.path);
        const nices = cold.items(.nice);

        // First, find which pinned processes are missing from render_rows
        var missing_rows: [64]model.RenderRow = undefined;
        var missing_count: usize = 0;

        var pinned_iter = self.pinned_pids.iterator();
        while (pinned_iter.next()) |entry| {
            const identity = entry.key_ptr.*;

            // Check if this pinned process is already in render_rows
            var found = false;
            const rows = self.procs.render_rows.items;
            for (rows) |row| {
                if (row.data_idx < start_times.len) {
                    if (pids[row.data_idx] == identity.pid and
                        start_times[row.data_idx] == identity.start_time_ns)
                    {
                        found = true;
                        break;
                    }
                }
            }

            if (!found and missing_count < 64) {
                // Find this process in hot/cold data
                for (0..pids.len) |data_idx| {
                    if (pids[data_idx] == identity.pid and
                        start_times[data_idx] == identity.start_time_ns)
                    {
                        // Create a RenderRow for this missing pinned process
                        missing_rows[missing_count] = .{
                            .pid = pids[data_idx],
                            .cpu_percent = cpu_percents[data_idx],
                            .mem_rss = mem_rsss[data_idx],
                            .name = names[data_idx],
                            .path = paths[data_idx],
                            .nice = nices[data_idx],
                            .depth = 0, // Pinned processes show at root level
                            .has_children = false,
                            .is_last = true,
                            .is_expanded = false,
                            .data_idx = @intCast(data_idx),
                        };
                        missing_count += 1;
                        break;
                    }
                }
            }
        }

        // In search view: insert missing pinned rows at the TOP
        if (in_search and missing_count > 0) {
            self.procs.render_rows.ensureUnusedCapacity(self.gpa, missing_count) catch return;
            // Shift existing rows down and insert pinned at top
            const rows = self.procs.render_rows.items;
            const new_len = rows.len + missing_count;
            self.procs.render_rows.resize(self.gpa, new_len) catch return;
            const new_rows = self.procs.render_rows.items;
            // Shift existing items to make room at the beginning
            var i: usize = rows.len;
            while (i > 0) {
                i -= 1;
                new_rows[i + missing_count] = new_rows[i];
            }
            // Insert missing pinned rows at the top
            for (0..missing_count) |j| {
                new_rows[j] = missing_rows[j];
            }
            return; // Don't do position-based reordering in search view
        }

        // Add missing pinned rows to render_rows (for normal view)
        if (missing_count > 0) {
            self.procs.render_rows.ensureUnusedCapacity(self.gpa, missing_count) catch return;
            for (0..missing_count) |i| {
                self.procs.render_rows.appendAssumeCapacity(missing_rows[i]);
            }
        }

        // In search view, don't reorder by stored positions - just keep natural order
        if (in_search) return;

        // Normal view: reorder all rows to place pinned ones at their stored positions
        const rows = self.procs.render_rows.items;
        if (rows.len == 0) return;

        // Collect all pinned rows with their target positions
        const PinnedEntry = struct { target_pos: usize, current_idx: usize };
        var pinned_entries: [64]PinnedEntry = undefined;
        var pinned_count: usize = 0;

        for (rows, 0..) |row, idx| {
            if (row.data_idx < start_times.len) {
                const identity = model.ProcIdentity{
                    .pid = row.pid,
                    .start_time_ns = start_times[row.data_idx],
                };
                if (self.pinned_pids.get(identity)) |target_pos| {
                    if (pinned_count < 64) {
                        pinned_entries[pinned_count] = .{
                            .target_pos = target_pos,
                            .current_idx = idx,
                        };
                        pinned_count += 1;
                    }
                }
            }
        }

        if (pinned_count == 0) return;

        // Allocate temp buffer
        var temp = self.gpa.alloc(model.RenderRow, rows.len) catch return;
        defer self.gpa.free(temp);

        // Mark which positions are reserved for pinned items
        var reserved = self.gpa.alloc(bool, rows.len) catch return;
        defer self.gpa.free(reserved);
        @memset(reserved, false);

        // First pass: place pinned items at their target positions (clamped)
        for (pinned_entries[0..pinned_count]) |entry| {
            const target = @min(entry.target_pos, rows.len - 1);
            var pos = target;
            // Find nearest free slot
            while (pos < rows.len and reserved[pos]) : (pos += 1) {}
            if (pos >= rows.len) {
                pos = target;
                while (pos > 0 and reserved[pos]) : (pos -= 1) {}
            }
            if (!reserved[pos]) {
                temp[pos] = rows[entry.current_idx];
                reserved[pos] = true;
            }
        }

        // Second pass: fill remaining slots with non-pinned items
        var write_idx: usize = 0;
        for (rows, 0..) |row, idx| {
            var is_pinned = false;
            for (pinned_entries[0..pinned_count]) |entry| {
                if (entry.current_idx == idx) {
                    is_pinned = true;
                    break;
                }
            }
            if (!is_pinned) {
                while (write_idx < rows.len and reserved[write_idx]) : (write_idx += 1) {}
                if (write_idx < rows.len) {
                    temp[write_idx] = row;
                    write_idx += 1;
                }
            }
        }

        // Copy back
        @memcpy(rows, temp[0..rows.len]);
    }

    pub fn showToast(self: *AppState, message: []const u8, level: ToastLevel) void {
        var toast = Toast{
            .level = level,
        };
        const len = @min(message.len, toast.message_buf.len);
        @memcpy(toast.message_buf[0..len], message[0..len]);
        toast.message_len = len;
        self.active_toast = toast;
    }

    pub fn showToastFmt(self: *AppState, comptime fmt: []const u8, args: anytype, level: ToastLevel) void {
        var toast = Toast{
            .level = level,
        };
        if (std.fmt.bufPrint(&toast.message_buf, fmt, args)) |result| {
            toast.message_len = result.len;
        } else |_| {
            const fallback = "Message too long";
            @memcpy(toast.message_buf[0..fallback.len], fallback);
            toast.message_len = fallback.len;
        }
        self.active_toast = toast;
    }

    pub fn showConfirmDialog(self: *AppState, title: []const u8, message: []const u8, action: ConfirmAction, pid: model.pid_t, name: []const u8) void {
        var dialog = ConfirmDialog{};

        const title_len = @min(title.len, dialog.title_buf.len);
        @memcpy(dialog.title_buf[0..title_len], title[0..title_len]);
        dialog.title_len = title_len;

        const msg_len = @min(message.len, dialog.message_buf.len);
        @memcpy(dialog.message_buf[0..msg_len], message[0..msg_len]);
        dialog.message_len = msg_len;

        const name_len = @min(name.len, dialog.target_name_buf.len);
        @memcpy(dialog.target_name_buf[0..name_len], name[0..name_len]);
        dialog.target_name_len = name_len;

        dialog.action = action;
        dialog.target_pid = pid;

        self.confirm_dialog = dialog;
        self.previous_mode = self.mode;
        self.mode = .confirm_dialog;
    }

    pub fn closeConfirmDialog(self: *AppState) void {
        self.confirm_dialog = null;
        self.mode = self.previous_mode;
    }

    pub fn setSort(self: *AppState, column: SortColumn) void {
        self.procs.setSort(column);
        self.sortView();
    }

    pub fn buildView(self: *AppState) void {
        const prev = self.getSelectedIdentity();
        self.procs.buildPipeline(self.searchSlice()) catch |err| {
            self.showToastFmt("buildView failed: {}", .{err}, .err);
            return;
        };
        self.reorderPinnedRows();
        self.restoreAndClamp(prev);
    }

    pub fn sortView(self: *AppState) void {
        const prev = self.getSelectedIdentity();
        self.procs.sortAndRebuild(self.searchSlice()) catch |err| {
            self.showToastFmt("sortView failed: {}", .{err}, .err);
            return;
        };
        self.reorderPinnedRows();
        self.restoreAndClamp(prev);
    }

    pub fn refreshFilter(self: *AppState) void {
        const prev = self.getSelectedIdentity();
        self.procs.rebuildVisible(self.searchSlice()) catch |err| {
            self.showToastFmt("refreshFilter failed: {}", .{err}, .err);
            return;
        };
        self.reorderPinnedRows();
        self.restoreAndClamp(prev);
    }

    pub fn toggleExpandAll(self: *AppState) void {
        const prev = self.getSelectedIdentity();
        self.procs.toggleExpandAll() catch |err| {
            self.showToastFmt("Expand all failed: {}", .{err}, .err);
            return;
        };
        self.procs.rebuildVisible(self.searchSlice()) catch |err| {
            self.showToastFmt("Rebuild failed: {}", .{err}, .err);
            return;
        };
        self.reorderPinnedRows();
        self.restoreAndClamp(prev);
    }

    pub fn toggleSelectedExpansion(self: *AppState) void {
        const rows = self.procs.render_rows.items;
        if (rows.len == 0) return;

        const prev = self.getSelectedIdentity();
        const idx = @min(self.selected_item, rows.len - 1);
        const row = rows[idx];
        if (!row.has_children) return;

        const data_idx: usize = @intCast(row.data_idx);
        const expand = !self.procs.isExpanded(data_idx);

        self.procs.setExpandedSubtree(row.data_idx, expand) catch |err| {
            self.showToastFmt("Expand failed: {}", .{err}, .err);
            return;
        };

        self.procs.rebuildVisible(self.searchSlice()) catch |err| {
            self.showToastFmt("Rebuild failed: {}", .{err}, .err);
            return;
        };
        self.reorderPinnedRows();
        self.restoreAndClamp(prev);
    }

    pub fn receiveBatch(self: *AppState, new_batch: channel.Batch) void {
        self.last_update_ns = new_batch.timestamp_ns;
        if (new_batch.system) |sys| {
            self.system.update(sys);
        }
        self.procs.receiveBatch(new_batch);
        self.buildView();

        // Update per-process socket tracking for network graphs
        const hot = self.procs.hot.slice();
        const cold = self.procs.cold.slice();
        if (hot.len > 0) {
            self.system.updateSocketTracking(hot.items(.pid), cold.items(.name));
        }

        // Trigger mount collection every 10 seconds (or on first batch)
        const now_ns = std.time.nanoTimestamp();
        const elapsed_ns = now_ns - self.last_mount_collect_ns;
        const ten_sec_ns: i128 = 10 * std.time.ns_per_s;
        if (self.last_mount_collect_ns == 0 or elapsed_ns >= ten_sec_ns) {
            self.last_mount_collect_ns = now_ns;
            const thread = std.Thread.spawn(.{}, collectMountWorker, .{self.mount_queue}) catch return;
            thread.detach();
        }

        // Lazy-load nettop for per-process network I/O (only in by_process or by_process_detail mode)
        // Rate-limited to every 2 seconds to avoid overhead
        const needs_nettop = self.network_display_mode == .by_process or self.network_display_mode == .by_process_detail;
        if (needs_nettop and !self.nettop_pending) {
            const nettop_elapsed = now_ns - self.last_nettop_collect_ns;
            const two_sec_ns: i128 = 2 * std.time.ns_per_s;
            if (self.last_nettop_collect_ns == 0 or nettop_elapsed >= two_sec_ns) {
                self.nettop_pending = true;
                const nettop_thread = std.Thread.spawn(.{}, collectNettopWorker, .{ self.nettop_queue, self.gpa }) catch {
                    self.nettop_pending = false;
                    return;
                };
                nettop_thread.detach();
            }
        }

        // Lazy-load TCP connections via sysctl (for detail view network info)
        // Rate-limited to every 2 seconds
        const needs_tcp = self.mode == .detail or needs_nettop;
        if (needs_tcp and !self.tcp_pending) {
            const tcp_elapsed = now_ns - self.last_tcp_collect_ns;
            const two_sec_ns: i128 = 2 * std.time.ns_per_s;
            if (self.last_tcp_collect_ns == 0 or tcp_elapsed >= two_sec_ns) {
                self.tcp_pending = true;
                const tcp_thread = std.Thread.spawn(.{}, collectTcpConnectionsWorker, .{ self.tcp_connections_queue, self.gpa }) catch {
                    self.tcp_pending = false;
                    return;
                };
                tcp_thread.detach();
            }
        }

        //close detail view if the inspected process exits
        if (self.detail_pid) |dpid| {
            const exists = self.procs.pid_to_index.get(dpid) != null;
            if (!exists) {
                self.showToast("Process exited", .warning);
                self.closeDetail();
            } else if (self.mode == .detail) {
                // Refresh open files/network connections while detail view is open
                self.refreshDetailOpenFiles();
            }
        }
    }

    fn getSelectedIdentity(self: *const AppState) ?model.ProcIdentity {
        const rows = self.procs.render_rows.items;
        if (rows.len == 0) return null;
        if (self.selected_item == 0) return null;
        const idx = @min(self.selected_item, rows.len - 1);
        const data_idx: usize = @intCast(rows[idx].data_idx);
        return self.procs.identityAt(data_idx);
    }

    fn restoreSelection(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        if (prev_identity) |identity| {
            // Don't follow pinned processes - keep cursor at same row position
            if (self.pinned_pids.contains(identity)) {
                return;
            }
            if (self.procs.findIdentity(identity)) |found_idx| {
                self.selected_item = found_idx;
            }
        }
    }

    fn restoreAndClamp(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        self.restoreSelection(prev_identity);
        const len = self.procs.render_rows.items.len;
        if (len == 0) {
            self.selected_item = 0;
            self.scroll_offset = 0;
        } else {
            self.selected_item = @min(self.selected_item, len - 1);
        }
    }

    pub fn down(self: *AppState) void {
        if (self.selected_item < self.procs.render_rows.items.len -| 1) {
            self.selected_item += 1;
        }
    }

    pub fn jumpTop(self: *AppState) void {
        self.selected_item = 0;
        self.scroll_offset = 0;
    }

    pub fn jumpBottom(self: *AppState) void {
        const len = self.procs.render_rows.items.len;
        if (len == 0) {
            self.selected_item = 0;
            self.scroll_offset = 0;
            return;
        }
        self.selected_item = len - 1;
    }

    pub fn up(self: *AppState) void {
        if (self.selected_item > 0) {
            self.selected_item -= 1;
        }
    }

    pub fn searchSlice(self: *const AppState) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    pub fn searchAppend(self: *AppState, c: u8) void {
        if (self.search_len < self.search_buf.len - 1) {
            self.search_buf[self.search_len] = c;
            self.search_len += 1;
        }
    }

    pub fn searchBackspace(self: *AppState) void {
        if (self.search_len > 0) {
            self.search_len -= 1;
        }
    }

    pub fn openDetail(self: *AppState, pid: model.pid_t) void {
        self.closeDetail();
        self.detail_pid = pid;
        self.detail_data = null;
        self.detail_scroll = 0;
        self.detail_right_scroll = 0;
        self.detail_focus = .left;
        self.detail_view_mode = .info;
        self.previous_mode = self.mode;
        self.mode = .detail;

        const thread = std.Thread.spawn(.{}, collectDetailWorker, .{ self.detail_queue, pid, self.gpa }) catch {
            self.showToast("Detail collection failed", .err);
            self.mode = self.previous_mode;
            return;
        };
        thread.detach();
    }

    fn collectDetailWorker(queue: *channel.DetailQueue, pid: model.pid_t, gpa: std.mem.Allocator) void {
        const platform = @import("platform");
        var arena = std.heap.ArenaAllocator.init(gpa);
        const alloc = arena.allocator();

        const data = platform.collectProcessDetail(pid, alloc) catch {
            arena.deinit();
            return;
        };

        if (!queue.tryPush(.{ .arena = arena, .data = data, .pid = pid })) {
            arena.deinit();
        }
    }

    fn collectMountWorker(queue: *channel.MountQueue) void {
        const platform = @import("platform");
        const snapshot = platform.collectMountInfo();
        _ = queue.tryPush(.{ .snapshot = snapshot });
    }

    /// Background worker to collect per-process network I/O via nettop
    fn collectNettopWorker(queue: *channel.NettopQueue, gpa: std.mem.Allocator) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const alloc = arena.allocator();

        // Run nettop in batch mode to get per-process network stats
        // -P: show per-process, -L 1: one sample, -x: extended output
        var child = std.process.Child.init(&.{ "nettop", "-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out" }, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch {
            arena.deinit();
            return;
        };

        // Read stdout first (before wait, to avoid pipe buffer filling)
        const stdout = child.stdout orelse {
            _ = child.wait() catch {};
            arena.deinit();
            return;
        };

        // Read all available data
        var output_buf: [64 * 1024]u8 = undefined;
        var read_buf: [4096]u8 = undefined;
        var total_read: usize = 0;

        while (true) {
            const n = stdout.read(&read_buf) catch break;
            if (n == 0) break;
            if (total_read + n > output_buf.len) break;
            @memcpy(output_buf[total_read..][0..n], read_buf[0..n]);
            total_read += n;
        }

        const output = output_buf[0..total_read];

        // Now wait for child to exit
        _ = child.wait() catch {};

        // Parse nettop output (CSV format)
        // Format: process_name.pid,bytes_in,bytes_out,
        var processes: std.ArrayListUnmanaged(channel.ProcessNetIO) = .empty;

        var lines = std.mem.splitScalar(u8, output, '\n');
        _ = lines.next(); // Skip header line: ",bytes_in,bytes_out,"

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            // Parse CSV: "process_name.pid,bytes_in,bytes_out,"
            var fields = std.mem.splitScalar(u8, line, ',');

            // First field: process_name.pid
            const proc_field = fields.next() orelse continue;
            if (proc_field.len == 0) continue;

            // Find last dot to extract pid
            const dot_idx = std.mem.lastIndexOfScalar(u8, proc_field, '.') orelse continue;
            if (dot_idx + 1 >= proc_field.len) continue;

            const pid = std.fmt.parseInt(model.pid_t, proc_field[dot_idx + 1 ..], 10) catch continue;

            // Bytes in
            const bytes_in_str = fields.next() orelse continue;
            const bytes_in = std.fmt.parseInt(u64, bytes_in_str, 10) catch continue;

            // Bytes out
            const bytes_out_str = fields.next() orelse continue;
            const bytes_out = std.fmt.parseInt(u64, bytes_out_str, 10) catch continue;

            processes.append(alloc, .{
                .pid = pid,
                .bytes_in = bytes_in,
                .bytes_out = bytes_out,
            }) catch continue;
        }

        const timestamp_ns = std.time.nanoTimestamp();

        if (!queue.tryPush(.{
            .arena = arena,
            .processes = processes.toOwnedSlice(alloc) catch &.{},
            .timestamp_ns = timestamp_ns,
        })) {
            arena.deinit();
        }
    }

    pub fn receiveNettop(self: *AppState, result: channel.NettopResult) void {
        self.nettop_pending = false;

        // Calculate time delta for rate computation
        const dt_ns = result.timestamp_ns - self.last_nettop_collect_ns;
        const dt_s: f64 = if (dt_ns > 0) @as(f64, @floatFromInt(dt_ns)) / 1_000_000_000.0 else 1.0;

        // Update tracked processes with network I/O data
        for (result.processes) |proc_io| {
            // Find matching tracked process
            for (&self.system.tracked_procs) |*tp| {
                if (tp.active and tp.pid == proc_io.pid) {
                    // Calculate rates
                    if (tp.prev_bytes_in > 0 or tp.prev_bytes_out > 0) {
                        tp.bytes_in_rate = @as(f64, @floatFromInt(proc_io.bytes_in -| tp.prev_bytes_in)) / dt_s;
                        tp.bytes_out_rate = @as(f64, @floatFromInt(proc_io.bytes_out -| tp.prev_bytes_out)) / dt_s;
                        // Push to history for sparklines
                        tp.in_rate_history.push(tp.bytes_in_rate);
                        tp.out_rate_history.push(tp.bytes_out_rate);
                    }
                    tp.bytes_in = proc_io.bytes_in;
                    tp.bytes_out = proc_io.bytes_out;
                    tp.prev_bytes_in = proc_io.bytes_in;
                    tp.prev_bytes_out = proc_io.bytes_out;
                    break;
                }
            }
        }

        self.last_nettop_collect_ns = result.timestamp_ns;

        var r = result;
        r.deinit();
    }

    pub fn receiveTcpConnections(self: *AppState, result: channel.TcpConnectionsResult) void {
        self.tcp_pending = false;

        // Copy connections to system state (up to max)
        const copy_count = @min(result.connections.len, SystemState.MAX_TCP_CONNECTIONS);
        @memcpy(self.system.tcp_connections[0..copy_count], result.connections[0..copy_count]);
        self.system.tcp_connection_count = @intCast(copy_count);

        self.last_tcp_collect_ns = result.timestamp_ns;

        var r = result;
        r.deinit();
    }

    /// Background worker to collect system-wide TCP connections via sysctl
    fn collectTcpConnectionsWorker(queue: *channel.TcpConnectionsQueue, gpa: std.mem.Allocator) void {
        const pl = @import("platform");
        var arena = std.heap.ArenaAllocator.init(gpa);
        const alloc = arena.allocator();

        const connections = pl.collectTcpConnections(alloc) catch {
            arena.deinit();
            return;
        };

        const now_ns = std.time.nanoTimestamp();

        // Try to push result - if queue is full, release the arena
        if (!queue.tryPush(.{
            .arena = arena,
            .connections = connections,
            .timestamp_ns = now_ns,
        })) {
            arena.deinit();
        }
    }

    /// Get TCP connections for a specific PID
    pub fn getTcpConnectionsForPid(self: *const AppState, pid: model.pid_t) []const model.TcpConnection {
        // Count connections for this PID
        var count: usize = 0;
        for (self.system.tcp_connections[0..self.system.tcp_connection_count]) |conn| {
            if (conn.pid == pid) count += 1;
        }
        if (count == 0) return &[_]model.TcpConnection{};

        // Return a view into the connections array (caller should copy if needed)
        // For simplicity, we return the whole slice and let caller filter
        return self.system.tcp_connections[0..self.system.tcp_connection_count];
    }

    pub fn receiveDetail(self: *AppState, result: channel.DetailResult) void {
        if (self.detail_pid) |current_pid| {
            if (current_pid == result.pid and self.mode == .detail) {
                if (self.detail_arena) |*old| old.deinit();
                self.detail_arena = result.arena;
                self.detail_data = result.data;
                // Initial collection of open files
                self.refreshDetailOpenFiles();
                return;
            }
        }
        var r = result;
        r.deinit();
    }

    /// Refresh open files/network connections for the current detail process.
    /// Called on initial detail open and on each batch update while detail view is active.
    /// Collects from: main process + all descendants (BFS) + same PGID processes.
    fn refreshDetailOpenFiles(self: *AppState) void {
        const current_pid = self.detail_pid orelse return;
        const arena = if (self.detail_arena) |*a| a else return;
        const platform = @import("platform");
        const alloc = arena.allocator();

        var all_files: std.ArrayListUnmanaged(model.OpenFile) = .empty;
        var collected_pids: std.AutoHashMapUnmanaged(model.pid_t, void) = .empty;

        // Collect from main process
        if (platform.collectOpenFiles(current_pid, alloc)) |main_files| {
            all_files.appendSlice(alloc, main_files) catch {};
        } else |_| {}
        collected_pids.put(alloc, current_pid, {}) catch {};

        const hot = self.procs.hot.slice();
        const cold = self.procs.cold.slice();
        const pids = hot.items(.pid);
        const ppids = cold.items(.ppid);
        const pgids = cold.items(.pgid);

        // Find current process's PGID for session-based grouping
        var current_pgid: ?model.pid_t = null;
        for (pids, pgids) |pid, pgid| {
            if (pid == current_pid) {
                current_pgid = pgid;
                break;
            }
        }

        // Recursive descendant collection using iterative BFS
        // This catches grandchildren, great-grandchildren, etc.
        // (e.g., kitty -> zsh -> curl)
        var queue: std.ArrayListUnmanaged(model.pid_t) = .empty;
        queue.append(alloc, current_pid) catch {};

        while (queue.items.len > 0) {
            const parent = queue.pop();

            // Find all children of this parent
            for (pids, ppids) |child_pid, ppid| {
                if (ppid == parent and !collected_pids.contains(child_pid)) {
                    // Collect files from this descendant
                    if (platform.collectOpenFiles(child_pid, alloc)) |child_files| {
                        all_files.appendSlice(alloc, child_files) catch {};
                    } else |_| {}
                    collected_pids.put(alloc, child_pid, {}) catch {};

                    // Add to queue to process its children
                    queue.append(alloc, child_pid) catch {};
                }
            }
        }

        // PGID-based collection: also collect from processes in the same process group
        // This catches related processes that share a session (e.g., pipeline commands)
        if (current_pgid) |pgid| {
            for (pids, pgids) |pid, proc_pgid| {
                if (proc_pgid == pgid and !collected_pids.contains(pid)) {
                    if (platform.collectOpenFiles(pid, alloc)) |pgid_files| {
                        all_files.appendSlice(alloc, pgid_files) catch {};
                    } else |_| {}
                    collected_pids.put(alloc, pid, {}) catch {};
                }
            }
        }

        self.detail_open_files = all_files.toOwnedSlice(alloc) catch null;
    }

    pub fn receiveMounts(self: *AppState, result: channel.MountResult) void {
        self.system.mount_count = result.snapshot.mount_count;
        self.system.mounts = result.snapshot.mounts;
    }

    pub fn closeDetail(self: *AppState) void {
        if (self.detail_arena) |*arena| {
            arena.deinit();
        }
        self.detail_arena = null;
        self.detail_data = null;
        self.detail_pid = null;
        self.detail_open_files = null;
        if (self.mode == .detail) {
            self.mode = self.previous_mode;
        }
    }

    pub fn detailScrollUp(self: *AppState) void {
        if (self.detail_scroll > 0) self.detail_scroll -= 1;
    }

    pub fn detailScrollDown(self: *AppState) void {
        self.detail_scroll += 1;
    }

    pub fn detailScrollToBottom(self: *AppState) void {
        // Use a large but safe value that won't overflow in render calculations
        self.detail_scroll = std.math.maxInt(usize) / 2;
    }

    pub fn searchClear(self: *AppState) void {
        self.search_len = 0;
    }
};

pub const DrawContext = struct {
    state: *AppState,
    scratch: std.mem.Allocator,
};
