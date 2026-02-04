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
    total_cpu_percent: f32 = 0,
    cpu_history: model.CpuHistory = .{},
    mem_total: u64 = 0,
    mem_used: u64 = 0,
    load_avg: [3]f64 = .{ 0, 0, 0 },
    disk_read_rate: f64 = 0,
    disk_write_rate: f64 = 0,
    net_recv_rate: f64 = 0,
    net_sent_rate: f64 = 0,
    prev_metrics: ?model.SystemMetrics = null,
    has_data: bool = false,

    pub fn update(self: *SystemState, metrics: model.SystemMetrics) void {
        self.core_count = metrics.core_count;
        self.mem_total = metrics.mem_total;
        self.mem_used = metrics.mem_used;
        self.load_avg = metrics.load_avg;

        if (self.prev_metrics) |prev| {
            // Per-core CPU% from tick deltas
            var total_active: u64 = 0;
            var total_all: u64 = 0;
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
                    self.core_percents[i] = @as(f32, @floatFromInt(d_active)) / @as(f32, @floatFromInt(d_total)) * 100.0;
                } else {
                    self.core_percents[i] = 0;
                }
                total_active += d_active;
                total_all += d_total;
            }
            if (total_all > 0) {
                self.total_cpu_percent = @as(f32, @floatFromInt(total_active)) / @as(f32, @floatFromInt(total_all)) * 100.0;
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
            }
        }

        self.cpu_history.push(self.total_cpu_percent);
        self.prev_metrics = metrics;
        self.has_data = true;
    }
};

pub const ToastLevel = enum { info, success, warning, err };
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
    detail_pid: ?model.pid_t = null,
    detail_data: ?model.ProcessDetail = null,
    detail_arena: ?std.heap.ArenaAllocator = null,
    detail_scroll: usize = 0,
    detail_right_scroll: usize = 0,
    detail_focus: DetailFocus = .left,
    help_scroll: usize = 0,
    procs: procs.Store,
    system: SystemState = .{},

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
