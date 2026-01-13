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
    view: std.ArrayList(*proc.Proc) = .{},
    pub fn rebuildView(self: *AppState) void {
        self.view.clearRetainingCapacity();

        if (self.current_Batch) |*batch| {
            var iter = batch.map.iterator();
            while (iter.next()) |entry| {
                self.view.append(self.allocator, entry.value_ptr.*) catch {};
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

        self.rebuildView();
    }
};

pub const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
