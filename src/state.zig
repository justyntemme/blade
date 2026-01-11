const std = @import("std");
const proc = @import("proc/proc.zig");

pub const AppState = struct {
    running: bool = true,
    allocator: std.mem.Allocator,
    selected_item: usize = 0,
    procs: std.AutoHashMap(proc.pid_t, proc.Proc),
    view: std.ArrayList(*proc.Proc) = .{},
    scroll_offset: usize = 0,
    pub fn rebuildView(self: *AppState) void {
        self.view.clearRetainingCapacity();
        var iter = self.procs.iterator();
        while (iter.next()) |entry| {
            self.view.append(self.allocator, entry.value_ptr) catch {};
        }
    }
    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .procs = std.AutoHashMap(proc.pid_t, proc.Proc).init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.view.deinit(self.allocator);
        self.procs.deinit();
    }
};

pub const DrawContext = struct {
    state: *AppState,
    allocator: std.mem.Allocator,
};
