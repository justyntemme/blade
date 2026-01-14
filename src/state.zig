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

        if (self.current_Batch) |*batch| {
            var iter = batch.map.iterator();
            while (iter.next()) |entry| {
                try self.view.append(self.allocator, entry.value_ptr.*);
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
};

pub const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
