const std = @import("std");

//Internal deps
const event = @import("event");
const render = @import("ui_render");
const state = @import("state");
const channel = @import("thread_channel");
const producer = @import("thread_producer");
// External deps
const tui = @import("zigtui");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_alloc = gpa.allocator();
    var backend = try tui.backend.AnsiBackend.init(gpa_alloc);
    defer backend.deinit();

    // // Initialize terminal
    var terminal = try tui.terminal.Terminal.init(gpa_alloc, backend.interface());
    defer terminal.deinit();

    // Hide cursor
    try terminal.hideCursor();
    try terminal.enableKeyboardProtocol(.{ .mode = .kitty });
    defer terminal.disableKeyboardProtocol() catch {};
    var app = state.AppState.init(gpa_alloc);
    app.terminal = &terminal;
    defer app.deinit();
    var queue = try channel.initQueue(gpa_alloc);
    defer queue.deinit();
    // details queue
    var detail_queue = try channel.DetailQueue.initCapacity(gpa_alloc, 2);
    defer detail_queue.deinit();
    app.detail_queue = &detail_queue;

    // mount info queue
    var mount_queue = try channel.MountQueue.initCapacity(gpa_alloc, 2);
    defer mount_queue.deinit();
    app.mount_queue = &mount_queue;

    // nettop queue (per-process network I/O, lazy-loaded)
    var nettop_queue = try channel.NettopQueue.initCapacity(gpa_alloc, 2);
    defer nettop_queue.deinit();
    app.nettop_queue = &nettop_queue;

    // TCP connections queue (system-wide connections via sysctl, lazy-loaded)
    var tcp_connections_queue = try channel.TcpConnectionsQueue.initCapacity(gpa_alloc, 2);
    defer tcp_connections_queue.deinit();
    app.tcp_connections_queue = &tcp_connections_queue;

    // Thread synch
    var mutex: std.Thread.Mutex = .{};
    var condition: std.Thread.Condition = .{};
    var thread_running = std.atomic.Value(bool).init(true);

    //thread shutdown
    const thread_args = producer.ThreadArgs{
        .queue = &queue,
        .running = &thread_running,
        .condition = &condition,
        .mutex = &mutex,
    };
    const handle = try std.Thread.spawn(.{}, producer.run, .{thread_args});
    defer {
        thread_running.store(false, .release);
        condition.signal();
        handle.join();
    }
    defer terminal.showCursor() catch {};

    // Frame-scoped scratch arena: all per-frame allocations (layout, formatting)
    // use bump-pointer allocation and bulk-free at frame end. .retain_capacity
    // keeps backing memory across frames — no repeated mmap/munmap.
    var frame_arena = std.heap.ArenaAllocator.init(gpa_alloc);
    defer frame_arena.deinit();

    while (app.running) {
        defer _ = frame_arena.reset(.retain_capacity);

        if (queue.front()) |batch_ptr| {
            const batch = batch_ptr.*;
            queue.pop();
            app.receiveBatch(batch);
        }

        if (detail_queue.front()) |result_ptr| {
            const result = result_ptr.*;
            detail_queue.pop();
            app.receiveDetail(result);
        }

        if (mount_queue.front()) |result_ptr| {
            const result = result_ptr.*;
            mount_queue.pop();
            app.receiveMounts(result);
        }

        if (nettop_queue.front()) |result_ptr| {
            const result = result_ptr.*;
            nettop_queue.pop();
            app.receiveNettop(result);
        }

        if (tcp_connections_queue.front()) |result_ptr| {
            const result = result_ptr.*;
            tcp_connections_queue.pop();
            app.receiveTcpConnections(result);
        }

        // Poll for events (100ms timeout)
        const e = try backend.interface().pollEvent(100);

        // Handle input
        try event.handleEvent(&app, e);

        const scratch = frame_arena.allocator();
        const ctx = state.DrawContext{ .state = &app, .scratch = scratch };

        // Draw UI
        try terminal.draw(ctx, render.render);
    }
}
