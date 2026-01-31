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
    // try tui.backend.NativeBackend.init(allocator);
    var backend = try tui.backend.AnsiBackend.init(gpa_alloc);
    defer backend.deinit();

    // // Initialize terminal
    var terminal = try tui.terminal.Terminal.init(gpa_alloc, backend.interface());
    defer terminal.deinit();

    // Hide cursor
    try terminal.hideCursor();
    var app = state.AppState.init(gpa_alloc);
    app.terminal = &terminal;
    defer app.deinit();
    var queue = try channel.initQueue(gpa_alloc);
    defer queue.deinit();

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

    while (app.running) {
        if (queue.front()) |batch_ptr| {
            const batch = batch_ptr.*;
            queue.pop();
            app.receive_batch(batch);
        }

        // Poll for events (100ms timeout)
        const e = try backend.interface().pollEvent(100);

        // Handle input
        try event.handleEvent(&app, e);

        const ctx = state.DrawContext{ .state = &app, .scratch = gpa_alloc };

        // Draw UI
        try terminal.draw(ctx, render.render);
    }
}
