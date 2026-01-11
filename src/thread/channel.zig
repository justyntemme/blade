const std = @import("std");
const spsc = @import("spsc_queue");
const proc = @import("../proc/proc.zig");

// Batch represents proc data with its own memory arena
// Ownership transfers through queue - consumer calls deinit
pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMap(proc.pid_t, *proc.Proc),

    pub fn deinit(self: *Batch) void {
        self.map.deinit();
        self.arena.deinit();
    }
};

// Queue for batch transfer
// cap of 4 - consumer drains faster than producer fills
pub const BatchQueue = spsc.SpscQueue(Batch, false);

// init
pub fn initQueue(allocator: std.mem.Allocator) !BatchQueue {
    return BatchQueue.initCapacity(allocator, 4);
}
