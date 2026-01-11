const std = @import("std");

//Internal deps
const event = @import("event.zig");
const proc = @import("proc/proc.zig");
const render = @import("render.zig");
const state = @import("state.zig");

// External deps
const tui = @import("zigtui");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // // Initialize backend (platform-specific)
    // try tui.backend.AnsiBackend.init(allocator);
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

    var procMap = try proc.getProcList();
    defer procMap.deinit();

    var iter = procMap.iterator();
    while (iter.next()) |entry| {
        try app.procs.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    // rebuild view state from procs map buffer
    app.rebuildView();

    while (app.running) {
        // Process event triggers

        // Poll for events (100ms timeout)
        const e = try backend.interface().pollEvent(100);

        // Handle input
        event.handleEvent(&app, e);

        const ctx = state.DrawContext{ .state = &app, .allocator = allocator };

        // Draw UI
        try terminal.draw(ctx, render.render);
    }

    try terminal.showCursor();
}
