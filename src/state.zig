const std = @import("std");
const channel = @import("thread_channel");
const sort = @import("sort");
const zigtui = @import("zigtui");
const model = @import("model");
const platform = @import("platform");

pub const ProcHot = struct {
    pid: std.posix.pid_t,
    start_time_ns: i128,
    cpu_percent: f32,
    mem_rss_bytes: u64,
};

pub const ProcHotList = std.MultiArrayList(ProcHot);

pub const ProcView = struct {
    proc: *platform.backend.Proc,
    cpu_percent: f32 = 0,
};

pub const SortColumn = enum { pid, name, cpu, mem, path };
pub const SortDirection = enum { asc, desc };

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
    allocator: std.mem.Allocator,
    selected_item: usize = 0,
    scroll_offset: usize = 0,
    hot: ProcHotList = .{},
    sort_column: SortColumn = .cpu,
    sort_direction: SortDirection = .desc,
    active_toast: ?Toast = null,
    current_batch: ?channel.Batch = null,
    mode: enum { normal, search } = .normal,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    view: std.ArrayList(ProcView) = .empty,
    indices: std.ArrayList(usize) = .empty,
    previous_batch: ?channel.Batch = null,
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
        if (self.sort_column == column) {
            self.sort_direction = if (self.sort_direction == .asc) .desc else .asc;
        } else {
            self.sort_column = column;
            self.sort_direction = .desc;
        }
        self.sortView();
    }

    /// Full rebuild: populate data, sort, filter, restore selection.
    /// Called on new batch.
    pub fn buildView(self: *AppState) !void {
        const prev_identity = self.getSelectedIdentity();
        try self.populateView();
        try self.buildIndices();
        try self.applyFilter();
        self.applySelection(prev_identity);
    }

    /// Re-sort and filter without repopulating data.
    /// Called on sort column/direction change.
    pub fn sortView(self: *AppState) void {
        const prev_identity = self.getSelectedIdentity();
        self.buildIndices() catch return;
        self.applyFilter() catch return;
        self.applySelection(prev_identity);
    }

    /// Refresh filter without re-sorting.
    /// Called on search change.
    pub fn refreshFilter(self: *AppState) void {
        const prev_identity = self.getSelectedIdentity();
        self.buildIndices() catch return;
        self.applyFilter() catch return;
        self.applySelection(prev_identity);
    }

    /// Stage 1: Populate view with ALL processes and computed CPU%.
    fn populateView(self: *AppState) !void {
        self.view.clearRetainingCapacity();
        self.hot.shrinkRetainingCapacity(0);

        const batch = self.current_batch orelse return;
        const time_delta: i128 = if (self.previous_batch) |*prev|
            batch.timestamp_ns - prev.timestamp_ns
        else
            0;

        var iter = batch.map.iterator();
        while (iter.next()) |entry| {
            const proc_ptr = entry.value_ptr.*;

            // Compute CPU%
            var cpu_percent: f32 = 0;
            if (self.previous_batch) |*prev| {
                if (prev.map.get(proc_ptr.pid)) |old_proc| {
                    if (old_proc.start_time_ns == proc_ptr.start_time_ns and time_delta > 0) {
                        const new_total = proc_ptr.total_user + proc_ptr.total_system;
                        const old_total = old_proc.total_user + old_proc.total_system;
                        const cpu_delta = new_total -| old_total;
                        cpu_percent = @as(f32, @floatFromInt(cpu_delta)) / @as(f32, @floatFromInt(time_delta)) * 100.0;
                    }
                }
            }

            // Append ALL items (no search filter here)
            try self.view.append(self.allocator, .{
                .proc = proc_ptr,
                .cpu_percent = cpu_percent,
            });
            try self.hot.append(self.allocator, .{
                .pid = proc_ptr.pid,
                .start_time_ns = proc_ptr.start_time_ns,
                .cpu_percent = cpu_percent,
                .mem_rss_bytes = proc_ptr.mem_rss,
            });
        }
        std.debug.assert(self.view.items.len == self.hot.len); // For development ensure hot is in sync
    }

    /// Stage 2: Build sorted index array from view.
    fn buildIndices(self: *AppState) !void {
        self.indices.clearRetainingCapacity();
        try self.indices.ensureTotalCapacity(self.allocator, self.view.items.len);
        for (0..self.view.items.len) |i| {
            self.indices.appendAssumeCapacity(i);
        }
        std.mem.sort(usize, self.indices.items, self, compareByIndex);
    }

    /// Stage 3: Filter indices to only include items matching search.
    fn applyFilter(self: *AppState) !void {
        const search = self.searchSlice();
        if (search.len == 0) return; // No filter needed

        var search_lower_buf: [256]u8 = undefined;
        const search_lower = std.ascii.lowerString(&search_lower_buf, search);

        // Filter in-place: keep only matching indices
        var write_idx: usize = 0;
        for (self.indices.items) |data_idx| {
            const proc_ptr = self.view.items[data_idx].proc;
            if (self.matchesSearch(proc_ptr, search_lower)) {
                self.indices.items[write_idx] = data_idx;
                write_idx += 1;
            }
        }
        self.indices.shrinkRetainingCapacity(write_idx);
    }

    /// Stage 4: Restore selection by identity, or clamp to valid range.
    fn applySelection(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        self.restoreSelection(prev_identity);
        if (self.indices.items.len == 0) {
            self.selected_item = 0;
        } else {
            self.selected_item = @min(self.selected_item, self.indices.items.len - 1);
        }
        self.scroll_offset = 0;
    }
    pub fn down(self: *AppState) void {
        if (self.selected_item < self.indices.items.len -| 1) {
            self.selected_item += 1;
        }
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

    pub fn searchClear(self: *AppState) void {
        self.search_len = 0;
    }

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.view.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.hot.deinit(self.allocator);
        if (self.current_batch) |*batch| {
            batch.deinit();
        }
        if (self.previous_batch) |*batch| {
            batch.deinit();
        }
    }
    pub fn receive_batch(self: *AppState, new_batch: channel.Batch) void {
        // Ownership transfer: we now own new_batch and must deinit it later.
        // Slide the batch window: previous -> discard, current -> previous, new -> current.
        if (self.previous_batch) |*old| {
            old.deinit();
        }
        self.previous_batch = self.current_batch;
        self.current_batch = new_batch;

        self.buildView() catch |err| {
            std.debug.print("buildView failed :{}\n", .{err});
        };
    }

    fn matchesSearch(self: *const AppState, proc_ptr: *platform.backend.Proc, search: []const u8) bool {
        _ = self; //unused for now but keeps method on appstate for future changes
        //Buffers
        var name_lower_buf: [256]u8 = undefined;
        var path_lower_buf: [4096]u8 = undefined;

        const name_slice = std.mem.sliceTo(&proc_ptr.s_name, 0);
        const name_lower = std.ascii.lowerString(&name_lower_buf, name_slice);

        if (std.mem.indexOf(u8, name_lower, search) != null) {
            return true;
        }

        const path_slice = std.mem.sliceTo(&proc_ptr.path, 0);
        const path_lower = std.ascii.lowerString(&path_lower_buf, path_slice);

        if (std.mem.indexOf(u8, path_lower, search) != null) {
            return true;
        }

        return false;
    }
    fn getSelectedIdentity(self: *const AppState) ?model.ProcIdentity {
        if (self.indices.items.len == 0) return null;
        //Clamp selected time within item bounds
        const idx = @min(self.selected_item, self.indices.items.len - 1);
        const data_idx = self.indices.items[idx];
        return self.view.items[data_idx].proc.identity();
    }

    fn restoreSelection(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        if (prev_identity) |identity| {
            for (self.indices.items, 0..) |data_idx, i| {
                const pv = self.view.items[data_idx];
                if (pv.proc.identity().eql(identity)) {
                    self.selected_item = i;
                    return;
                }
            }
        }
    }
};

fn compareProcView(ctx: *const AppState, a: ProcView, b: ProcView) bool {
    return sort.compareProcView(ctx, a, b);
}

fn compareByIndex(ctx: *const AppState, a: usize, b: usize) bool {
    const pv_a = ctx.view.items[a];
    const pv_b = ctx.view.items[b];
    return sort.compareProcView(ctx, pv_a, pv_b);
}

pub const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
