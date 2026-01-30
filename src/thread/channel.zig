const std = @import("std");
const spsc = @import("spsc_queue");
const platform = @import("platform");

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
    map: std.AutoHashMap(platform.backend.pid_t, platform.backend.Proc),
    timestamp_ns: i128 = 0,

    pub fn deinit(self: *Batch) void {
        // Note: map.deinit() is intentionally omitted.
        // The map's internal storage was allocated from the arena.
        // Calling map.deinit() would use a stale allocator pointer
        // (the Allocator struct captured &batch_arena from the producer's stack).
        // The arena.deinit() below frees all memory in one operation.
        self.arena.deinit();
    }
};

// Queue for batch transfer
// cap of 4 - consumer drains faster than producer fills
pub const BatchQueue = spsc.SpscQueue(Batch, false);

// init
pub fn initQueue(gpa: std.mem.Allocator) !BatchQueue {
    return BatchQueue.initCapacity(gpa, 4);
}
