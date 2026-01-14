const std = @import("std");

//Internal deps
const event = @import("event.zig");
// const proc = @import("proc/proc.zig");
const render = @import("ui/render.zig");
const state = @import("state.zig");
const channel = @import("thread/channel.zig");
const producer = @import("thread/producer.zig");

// External deps
const tui = @import("zigtui");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // try tui.backend.NativeBackend.init(allocator);
    var backend = try tui.backend.AnsiBackend.init(allocator);
    defer backend.deinit();

    // // Initialize terminal
    var terminal = try tui.terminal.Terminal.init(allocator, backend.interface());
    defer terminal.deinit();

    // Hide cursor
    try terminal.hideCursor();
    var app = state.AppState.init(allocator);
    defer app.deinit();
    var queue = try channel.initQueue(allocator);
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

    while (app.running) {
        if (queue.front()) |batch_ptr| {
            const batch = batch_ptr.*;
            queue.pop();
            app.recieveBatch(batch);
        }

        // Poll for events (100ms timeout)
        const e = try backend.interface().pollEvent(100);

        // Handle input
        try event.handleEvent(&app, e);

        const ctx = state.DrawContext{ .state = &app, .allocator = allocator };

        // Draw UI
        try terminal.draw(ctx, render.render);
    }
    thread_running.store(false, .release);
    condition.signal();
    handle.join();
    try terminal.showCursor();
}
