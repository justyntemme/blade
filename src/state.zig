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
    mem_rss: u64,
};

pub const ProcHotList = std.MultiArrayList(ProcHot);

pub const ProcCold = struct {
    name: []const u8,
    path: []const u8,
    name_lower: []const u8,
    path_lower: []const u8,
};
//TODO review this idea   Why slices instead of fixed arrays?
// - Slices are 16 bytes (pointer + length) vs 4352 bytes for [256]u8 + [4096]u8
// - The actual string bytes still live in the batch's Proc structs
// - We're just storing a view into that data

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
    cold: std.ArrayList(ProcCold) = .empty,
    sort_column: SortColumn = .cpu,
    sort_direction: SortDirection = .desc,
    active_toast: ?Toast = null,
    current_batch: ?channel.Batch = null,
    mode: enum { normal, search } = .normal,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    indices: std.ArrayList(usize) = .empty,
    sorted_indices: std.ArrayList(usize) = .empty,
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
        self.applyFilter() catch return;
        self.applySelection(prev_identity);
    }

    /// Stage 1: Populate view with ALL processes and computed CPU%.
    fn populateView(self: *AppState) !void {
        self.hot.shrinkRetainingCapacity(0);
        for (self.cold.items) |cold_item| {
            self.allocator.free(cold_item.name_lower);
            self.allocator.free(cold_item.path_lower);
        }
        self.cold.clearRetainingCapacity();

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

            const name_slice = std.mem.sliceTo(&proc_ptr.s_name, 0);
            const path_slice = std.mem.sliceTo(&proc_ptr.path, 0);
            const name_lower = try self.allocator.alloc(u8, name_slice.len);
            _ = std.ascii.lowerString(name_lower, name_slice);
            const path_lower = try self.allocator.alloc(u8, path_slice.len);
            _ = std.ascii.lowerString(path_lower, path_slice);

            // Append ALL items (no search filter here)
            try self.cold.append(self.allocator, .{
                .name = std.mem.sliceTo(&proc_ptr.s_name, 0),
                .path = std.mem.sliceTo(&proc_ptr.path, 0),
                .name_lower = name_lower,
                .path_lower = path_lower,
            });
            try self.hot.append(self.allocator, .{
                .pid = proc_ptr.pid,
                .start_time_ns = proc_ptr.start_time_ns,
                .cpu_percent = cpu_percent,
                .mem_rss = proc_ptr.mem_rss,
            });
        }
        std.debug.assert(self.hot.len == self.cold.items.len); // For development ensure hot is in sync
    }

    /// Stage 2: Build sorted index array from view.
    fn buildIndices(self: *AppState) !void {
        self.sorted_indices.clearRetainingCapacity();
        try self.sorted_indices.ensureTotalCapacity(self.allocator, self.hot.len);
        for (0..self.hot.len) |i| {
            self.sorted_indices.appendAssumeCapacity(i);
        }
        std.mem.sort(usize, self.sorted_indices.items, self, compareByIndex);
    }

    /// Stage 3: Filter indices to only include items matching search.
    fn applyFilter(self: *AppState) !void {
        const search = self.searchSlice();
        self.indices.clearRetainingCapacity();
        try self.indices.ensureTotalCapacity(self.allocator, self.sorted_indices.items.len);
        if (search.len == 0) {
            self.indices.appendSliceAssumeCapacity(self.sorted_indices.items);
            return;
        }

        var search_lower_buf: [256]u8 = undefined;
        const search_lower = std.ascii.lowerString(&search_lower_buf, search);

        for (self.sorted_indices.items) |data_idx| {
            const cold_data = self.cold.items[data_idx];
            if (self.matchesSearch(cold_data, search_lower)) {
                self.indices.appendAssumeCapacity(data_idx);
            }
        }
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
        self.indices.deinit(self.allocator);
        self.sorted_indices.deinit(self.allocator);
        self.hot.deinit(self.allocator);
        for (self.cold.items) |cold_item| {
            self.allocator.free(cold_item.name_lower);
            self.allocator.free(cold_item.path_lower);
        }
        self.cold.deinit(self.allocator);
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

    fn matchesSearch(self: *const AppState, cold_data: ProcCold, search: []const u8) bool {
        _ = self; //unused for now but keeps method on appstate for future changes
        //Buffers

        if (std.mem.indexOf(u8, cold_data.name_lower, search) != null) {
            return true;
        }

        if (std.mem.indexOf(u8, cold_data.path_lower, search) != null) {
            return true;
        }

        return false;
    }
    fn getSelectedIdentity(self: *const AppState) ?model.ProcIdentity {
        if (self.indices.items.len == 0) return null;
        //Clamp selected time within item bounds
        const idx = @min(self.selected_item, self.indices.items.len - 1);
        const data_idx = self.indices.items[idx];
        return .{ .pid = self.hot.items(.pid)[data_idx], .start_time_ns = self.hot.items(.start_time_ns)[data_idx] };
    }

    fn restoreSelection(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        if (prev_identity) |identity| {
            const pids = self.hot.items(.pid);
            const start_times = self.hot.items(.start_time_ns);
            for (self.indices.items, 0..) |data_idx, i| {
                if (pids[data_idx] == identity.pid and start_times[data_idx] == identity.start_time_ns) {
                    self.selected_item = i;
                    return;
                }
            }
        }
    }
};

fn compareByIndex(ctx: *const AppState, a: usize, b: usize) bool {
    return sort.compareByIndex(ctx, a, b);
}

pub const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
