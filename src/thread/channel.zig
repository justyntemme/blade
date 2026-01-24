const std = @import("std");
const spsc = @import("spsc_queue");
const proc = @import("../proc/proc.zig");

/// Batch represents a snapshot of process data with its own memory arena.
///
/// Ownership model:
/// - Producer creates the batch and pushes it to the queue (ownership transferred)
/// - Consumer pops the batch and owns it until calling deinit()
/// - All data (map entries, Proc structs) are allocated from `arena`
/// - Calling `deinit()` frees all batch memory in one operation
///
/// Invariant: Never store references to batch data outside the batch lifetime.
pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMap(proc.pid_t, *proc.Proc),
    timestamp_ns: i128 = 0,

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
