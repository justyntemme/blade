const std = @import("std");
const proc = @import("proc/proc.zig");
const channel = @import("thread/channel.zig");

pub const AppState = struct {
    running: bool = true,
    allocator: std.mem.Allocator,
    selected_item: usize = 0,
    scroll_offset: usize = 0,
    // procs: std.AutoHashMap(proc.pid_t, proc.Proc),
    current_Batch: ?channel.Batch = null,
    mode: enum { normal, search } = .normal,
    search_buf: [256]u8 = undefined,
    search_len: usize = 0,
    view: std.ArrayList(*proc.Proc) = .{},
    pub fn rebuildView(self: *AppState) !void {
        self.view.clearRetainingCapacity();

        self.selected_item = 0;
        self.scroll_offset = 0;

        // if (self.current_Batch) |*batch| {
        //     var iter = batch.map.iterator();
        //     while (iter.next()) |entry| {
        //         try self.view.append(self.allocator, entry.value_ptr.*);
        //     }
        // }

        if (self.current_Batch) |*batch| {
            const search = self.searchSlice();

            var iter = batch.map.iterator();
            while (iter.next()) |entry| {
                const proc_ptr = entry.value_ptr.*;

                if (search.len == 0) {
                    try self.view.append(self.allocator, proc_ptr);
                } else {
                    if (self.matchesSearch(proc_ptr, search)) {
                        try self.view.append(self.allocator, proc_ptr);
                    }
                }
            }
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
            // .procs = std.AutoHashMap(proc.pid_t, proc.Proc).init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.view.deinit(self.allocator);
        if (self.current_Batch) |*batch| {
            batch.deinit();
        }
    }
    pub fn recieveBatch(self: *AppState, new_Batch: channel.Batch) void {
        // Free old batch -- will use to track
        // CPU percentage later but for now just free
        if (self.current_Batch) |*old| {
            old.deinit();
        }
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
