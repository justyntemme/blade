const std = @import("std");
const proc = @import("proc/proc.zig");
const channel = @import("thread/channel.zig");
const sort = @import("sort.zig");

pub const ProcView = struct {
    proc: *proc.Proc,
    cpu_percent: f32 = 0,
};

pub const SortColumn = enum { pid, name, cpu, mem, path };
pub const SortDirection = enum { asc, desc };

pub const ToastLevel = enum { info, success, warning, err };
pub const Toast = struct {
    message_buf: [128]u8 = [_]u8{0} ** 128,
    message_len: usize = 0,
    level: ToastLevel = .info,
    expired_at: i6 = 0,

    pub fn getMessage(self: *const Toast) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

pub const AppState = struct {
    running: bool = true,
    allocator: std.mem.Allocator,
    selected_item: usize = 0,
    scroll_offset: usize = 0,
    sort_column: SortColumn = .cpu,
    sort_direction: SortDirection = .desc,
    active_toast: ?Toast = null,
    // procs: std.AutoHashMap(proc.pid_t, proc.Proc),
    current_Batch: ?channel.Batch = null,
    mode: enum { normal, search } = .normal,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    view: std.ArrayList(ProcView) = .{},
    previous_Batch: ?channel.Batch = null,
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

        self.active_toast = toast;
    }

    pub fn setSort(self: *AppState, column: SortColumn) !void {
        if (self.sort_column == column) {
            self.sort_direction = if (self.sort_direction == .asc) .desc else .asc;
        } else {
            self.sort_column = column;
            self.sort_direction = .desc;
        }
        try self.rebuildView();
        self.selected_item = 0;
        self.scroll_offset = 0;
    }

    pub fn rebuildView(self: *AppState) !void {
        const prev_pid: ?proc.pid_t = if (self.view.items.len > 0)
            self.view.items[@min(self.selected_item, self.view.items.len - 1)].proc.pid
        else
            null;

        self.view.clearRetainingCapacity();
        if (self.current_Batch) |*batch| {
            const search = self.searchSlice();

            //calc time delta for cpu%
            const time_delta: i128 = if (self.previous_Batch) |*prev|
                batch.timestamp_ns - prev.timestamp_ns
            else
                0;

            var iter = batch.map.iterator();
            while (iter.next()) |entry| {
                const proc_ptr = entry.value_ptr.*;

                // compute cpu%
                var cpu_percent: f32 = 0;
                if (self.previous_Batch) |*prev| {
                    if (prev.map.get(proc_ptr.pid)) |old_proc| {
                        if (time_delta > 0) {
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
                    if (self.matchesSearch(proc_ptr, search)) {
                        try self.view.append(self.allocator, .{
                            .proc = proc_ptr,
                            .cpu_percent = cpu_percent,
                        });
                    }
                }
            }

            std.mem.sort(ProcView, self.view.items, self, sort.compareProcView);

            if (prev_pid) |pid| {
                for (self.view.items, 0..) |pv, i| {
                    if (pv.proc.pid == pid) {
                        self.selected_item = i;
                        return;
                    }
                }
            }
            self.selected_item = 0;
            self.scroll_offset = 0;
        }
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
            // .view = std.ArrayList(ProcView).init(allocator),
            // .procs = std.AutoHashMap(proc.pid_t, proc.Proc).init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.view.deinit(self.allocator);
        if (self.current_Batch) |*batch| {
            batch.deinit();
        }
        if (self.previous_Batch) |*batch| {
            batch.deinit();
        }
    }
    pub fn recieveBatch(self: *AppState, new_Batch: channel.Batch) void {
        if (self.previous_Batch) |*old| {
            old.deinit();
        }
        self.previous_Batch = self.current_Batch;
        // Free old batch -- will use to track
        // CPU percentage later but for now just free
        self.current_Batch = new_Batch;

        self.rebuildView() catch |err| {
            std.debug.print("rebuildView failed :{}\n", .{err});
        };
    }

    fn matchesSearch(self: *const AppState, proc_ptr: *proc.Proc, search: []const u8) bool {
        _ = self; //unused for now but keeps method on appstate for future changes
        //Buffers
        var search_lower_buf: [256]u8 = undefined;
        var name_lower_buf: [256]u8 = undefined;
        var path_lower_buf: [4096]u8 = undefined;

        const search_lower = std.ascii.lowerString(&search_lower_buf, search);

        const name_slice = std.mem.sliceTo(&proc_ptr.s_name, 0);
        const name_lower = std.ascii.lowerString(&name_lower_buf, name_slice);

        if (std.mem.indexOf(u8, name_lower, search_lower) != null) {
            return true;
        }

        const path_slice = std.mem.sliceTo(&proc_ptr.path, 0);
        const path_lower = std.ascii.lowerString(&path_lower_buf, path_slice);

        if (std.mem.indexOf(u8, path_lower, search_lower) != null) {
            return true;
        }

        return false;
    }
};

pub const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
