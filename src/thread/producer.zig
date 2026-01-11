const std = @import("std");

const proc = @import("../proc/proc.zig");
const channel = @import("channel.zig");

const POLL_INTERVAL_MS: u64 = 3000;

// producer thread params. pointers MUST remain valid for threads lifetime
pub const ThreadArgs = struct {
    queue: *channel.BatchQueue,
    running: *std.atomic.Value(bool),
};

//entrypoint
pub fn run(args: ThreadArgs) void {
    while (args.running.load(.acquire)) {
        fetchAndSend(args.queue) catch |err| {
            std.debug.print("Producer Error: {}\n", .{err});
        };
        std.time.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
    }
}

fn fetchAndSend(queue: *channel.BatchQueue) !void {
    //crate a new batch
    var batch = channel.Batch{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .map = std.AutoHashMap(proc.pid_t, *proc.Proc).init(std.heap.page_allocator),
    };
    var rawMap = try proc.getProcList();
    rawMap.deinit();
    const arena_alloc = batch.arena.allocator();
    var iter = rawMap.iterator();
    while (iter.next()) |entry| {
        const p = try arena_alloc.create(proc.Proc);
        p.* = entry.value_ptr.*;
        try batch.map.put(entry.key_ptr.*, p);
    }

    while (!queue.tryPush(batch)) {
        std.atomic.spinLoopHint();
    }
}
