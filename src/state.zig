const std = @import("std");
const channel = @import("thread_channel");
const sort = @import("sort");
const zigtui = @import("zigtui");
const model = @import("model");
const platform = @import("platform");

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
    sort_column: SortColumn = .cpu,
    sort_direction: SortDirection = .desc,
    active_toast: ?Toast = null,
    current_batch: ?channel.Batch = null,
    mode: enum { normal, search } = .normal,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    view: std.ArrayList(ProcView) = .empty,
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

    pub fn buildView(self: *AppState) !void {
        const prev_identity = self.getSelectedIdentity();

        self.view.clearRetainingCapacity();
        if (self.current_batch) |*batch| {
            const search = self.searchSlice();
            var search_lower_buf: [256]u8 = undefined;
            const search_lower = std.ascii.lowerString(&search_lower_buf, search);

            //calc time delta for cpu%
            const time_delta: i128 = if (self.previous_batch) |*prev|
                batch.timestamp_ns - prev.timestamp_ns
            else
                0;

            var iter = batch.map.iterator();
            while (iter.next()) |entry| {
                const proc_ptr = entry.value_ptr.*;

                // compute cpu%
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

                if (search.len == 0) {
                    try self.view.append(self.allocator, .{
                        .proc = proc_ptr,
                        .cpu_percent = cpu_percent,
                    });
                } else {
                    if (self.matchesSearch(proc_ptr, search_lower)) {
                        try self.view.append(self.allocator, .{
                            .proc = proc_ptr,
                            .cpu_percent = cpu_percent,
                        });
                    }
                }
            }

            std.mem.sort(ProcView, self.view.items, self, compareProcView);

            self.restoreSelection(prev_identity);

            self.selected_item = 0;
            self.scroll_offset = 0;
        }
    }
    pub fn sortView(self: *AppState) void {
        const prev_identity = self.getSelectedIdentity();
        std.mem.sort(ProcView, self.view.items, self, compareProcView);
        self.restoreSelection(prev_identity);
    }
    pub fn down(self: *AppState) void {
        if (self.selected_item < self.view.items.len -| 1) {
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
        if (self.view.items.len == 0) return null;
        //Clamp selected time within item bounds
        const idx = @min(self.selected_item, self.view.items.len - 1);
        return self.view.items[idx].proc.identity();
    }

    fn restoreSelection(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        if (prev_identity) |identity| {
            for (self.view.items, 0..) |pv, i| {
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

pub const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
