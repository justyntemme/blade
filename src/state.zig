const std = @import("std");
const channel = @import("thread_channel");
const procs = @import("procs");
const zigtui = @import("zigtui");
const model = @import("model");
const keymap = @import("event_keymap");

pub const SortColumn = model.SortColumn;
pub const SortDirection = model.SortDirection;

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
    help_scroll: usize = 0,
    procs: procs.Store,

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
