const std = @import("std");

const platform = @import("platform");
const channel = @import("thread_channel");

const poll_interval_ns: u64 = 3 * std.time.ns_per_s;

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
            args.condition.timedWait(args.mutex, poll_interval_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
        }
        args.mutex.unlock();
    }
}

fn fetchAndSend(queue: *channel.BatchQueue) !void {
    var batch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = batch_arena.allocator();
    //create a new batch
    var batch = channel.Batch{
        .arena = batch_arena,
        .map = std.AutoHashMap(std.posix.pid_t, *platform.backend.Proc).init(arena_alloc),
        .timestamp_ns = std.time.nanoTimestamp(),
    };
    var raw_map = try platform.collectSnapshot(arena_alloc);
    // const arena_alloc = batch.arena.allocator();
    var iter = raw_map.iterator();
    while (iter.next()) |entry| {
        const p = try arena_alloc.create(platform.backend.Proc);
        p.* = entry.value_ptr.*;
        try batch.map.put(entry.key_ptr.*, p);
    }
    var backoff_ns: u64 = 100_000; // Start at 100µs
    const max_backoff_ns: u64 = 10 * std.time.ns_per_ms; // Cap at 10ms

    while (!queue.tryPush(batch)) {
        std.Thread.sleep(backoff_ns);
        backoff_ns = @min(backoff_ns * 2, max_backoff_ns);
    }
}
