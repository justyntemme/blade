const std = @import("std");

const actions = @import("action.zig");

pub const Action = actions.Action;

pub const Mode = enum {
    normal,
    search,
};

pub const KeyBinding = struct {
    key: Key,
    action: Action,
    modes: []const Mode,
    description: []const u8,
};

pub const Key = union(enum) {
    char: u8,
    special: SpecialKey,
};

pub const SpecialKey = enum {
    up,
    down,
    esc,
    enter,
    backspace,
};

pub const keymap = [_]KeyBinding{
    // Navigation (both modes)
    .{ .key = .{ .char = 'j' }, .action = .move_down, .modes = &.{.normal}, .description = "down" },
    .{ .key = .{ .char = 'k' }, .action = .move_up, .modes = &.{.normal}, .description = "up" },
    .{ .key = .{ .special = .up }, .action = .move_up, .modes = &.{ .normal, .search }, .description = "" },
    .{ .key = .{ .special = .down }, .action = .move_down, .modes = &.{ .normal, .search }, .description = "" },
    .{ .key = .{ .char = 'u' }, .action = .page_up, .modes = &.{.normal}, .description = "page up" },
    .{ .key = .{ .char = 'd' }, .action = .page_down, .modes = &.{.normal}, .description = "page down" },
    // Application
    .{ .key = .{ .char = 'q' }, .action = .quit, .modes = &.{.normal}, .description = "quit" },
    .{ .key = .{ .special = .esc }, .action = .quit, .modes = &.{.normal}, .description = "" },
    // Search
    .{ .key = .{ .char = '/' }, .action = .start_search, .modes = &.{.normal}, .description = "search" },
    .{ .key = .{ .char = 'c' }, .action = .clear_search, .modes = &.{.normal}, .description = "clear" },

    // Process control
    .{ .key = .{ .char = 'x' }, .action = .kill_graceful, .modes = &.{.normal}, .description = "kill" },
    .{ .key = .{ .char = 'X' }, .action = .kill_force, .modes = &.{.normal}, .description = "kill -9" },

    // Sorting
    .{ .key = .{ .char = 'P' }, .action = .sort_by_pid, .modes = &.{.normal}, .description = "sort PID" },
    .{ .key = .{ .char = 'N' }, .action = .sort_by_name, .modes = &.{.normal}, .description = "sort Name" },
    .{ .key = .{ .char = 'C' }, .action = .sort_by_cpu, .modes = &.{.normal}, .description = "sort CPU" },
    .{ .key = .{ .char = 'M' }, .action = .sort_by_mem, .modes = &.{.normal}, .description = "sort mem" },
};
