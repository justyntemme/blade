const std = @import("std");

const proc = @import("../proc/proc.zig");
const channel = @import("channel.zig");

const poll_interval_ms: u64 = 3 * std.time.ns_per_s;

// producer thread params. pointers MUST remain valid for threads lifetime
pub const ThreadArgs = struct {
    queue: *channel.BatchQueue,
    running: *std.atomic.Value(bool),
    condition: *std.Thread.Condition,
    mutex: *std.Thread.Mutex,
};

//entrypoint
pub fn run(args: ThreadArgs) void {
    while (args.running.load(.acquire)) {
        fetchAndSend(args.queue) catch |err| {
            std.debug.print("Producer Error: {}\n", .{err});
        };

        //Sleep w interupt
        args.mutex.lock();
        if (args.running.load(.acquire)) {
            args.condition.timedWait(args.mutex, poll_interval_ms) catch {};
        }
        args.mutex.unlock();
    }
}

fn fetchAndSend(queue: *channel.BatchQueue) !void {
    //crate a new batch
    var batch = channel.Batch{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .map = std.AutoHashMap(proc.pid_t, *proc.Proc).init(std.heap.page_allocator),
    };
    var raw_Map = try proc.getProcList();
    defer raw_Map.deinit();
    const arena_alloc = batch.arena.allocator();
    var iter = raw_Map.iterator();
    while (iter.next()) |entry| {
        const p = try arena_alloc.create(proc.Proc);
        p.* = entry.value_ptr.*;
        try batch.map.put(entry.key_ptr.*, p);
    }

    while (!queue.tryPush(batch)) {
        std.atomic.spinLoopHint();
    }
}
