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

    prev_metrics: ?model.SystemMetrics = null,
    has_data: bool = false,

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
};

pub const ToastLevel = enum { info, success, warning, err };

pub const CpuOverlayMode = enum { cores, aggregate };
pub const TempUnit = enum { celsius, fahrenheit };

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
    last_mount_collect_ns: i128 = 0,
    detail_pid: ?model.pid_t = null,
    detail_data: ?model.ProcessDetail = null,
    detail_arena: ?std.heap.ArenaAllocator = null,
    detail_scroll: usize = 0,
    detail_right_scroll: usize = 0,
    detail_focus: DetailFocus = .left,
    help_scroll: usize = 0,
    procs: procs.Store,
    system: SystemState = .{},
    cpu_overlay_mode: CpuOverlayMode = .cores,
    temp_unit: TempUnit = .celsius,

    pub const DetailFocus = enum { left, right };

    pub fn init(gpa: std.mem.Allocator) AppState {
        return .{
            .gpa = gpa,
            .procs = procs.Store.init(gpa),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.closeDetail();
        self.procs.deinit();
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
        self.restoreAndClamp(prev);
    }

    pub fn sortView(self: *AppState) void {
        const prev = self.getSelectedIdentity();
        self.procs.sortAndRebuild(self.searchSlice()) catch |err| {
            self.showToastFmt("sortView failed: {}", .{err}, .err);
            return;
        };
        self.restoreAndClamp(prev);
    }

    pub fn refreshFilter(self: *AppState) void {
        const prev = self.getSelectedIdentity();
        self.procs.rebuildVisible(self.searchSlice()) catch |err| {
            self.showToastFmt("refreshFilter failed: {}", .{err}, .err);
            return;
        };
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
        self.restoreAndClamp(prev);
    }

    pub fn receiveBatch(self: *AppState, new_batch: channel.Batch) void {
        self.last_update_ns = new_batch.timestamp_ns;
        if (new_batch.system) |sys| {
            self.system.update(sys);
        }
        self.procs.receiveBatch(new_batch);
        self.buildView();

        // Trigger mount collection every 10 seconds (or on first batch)
        const now_ns = std.time.nanoTimestamp();
        const elapsed_ns = now_ns - self.last_mount_collect_ns;
        const ten_sec_ns: i128 = 10 * std.time.ns_per_s;
        if (self.last_mount_collect_ns == 0 or elapsed_ns >= ten_sec_ns) {
            self.last_mount_collect_ns = now_ns;
            const thread = std.Thread.spawn(.{}, collectMountWorker, .{self.mount_queue}) catch return;
            thread.detach();
        }

        //close detail view if the inspected process exits
        if (self.detail_pid) |dpid| {
            const exists = self.procs.pid_to_index.get(dpid) != null;
            if (!exists) {
                self.showToast("Process exited", .warning);
                self.closeDetail();
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

    pub fn receiveDetail(self: *AppState, result: channel.DetailResult) void {
        if (self.detail_pid) |current_pid| {
            if (current_pid == result.pid and self.mode == .detail) {
                if (self.detail_arena) |*old| old.deinit();
                self.detail_arena = result.arena;
                self.detail_data = result.data;
                return;
            }
        }
        var r = result;
        r.deinit();
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
        self.detail_scroll = std.math.maxInt(usize);
    }

    pub fn searchClear(self: *AppState) void {
        self.search_len = 0;
    }
};

pub const DrawContext = struct {
    state: *AppState,
    scratch: std.mem.Allocator,
};
