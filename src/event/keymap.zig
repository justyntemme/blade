const std = @import("std");

const actions = @import("event_action");

pub const Action = actions.Action;

pub const Mode = enum { normal, search_edit, search_view, help };

pub const KeyBinding = struct {
    key: Key,
    action: Action,
    modes: []const Mode,
    description: []const u8,
    category: []const u8 = "",
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
    .{ .key = .{ .char = '?' }, .action = .show_help, .modes = &.{ .normal, .search_view }, .description = "Show Help", .category = "General" },
    //expand
    .{ .key = .{ .special = .enter }, .action = .toggle_expand, .modes = &.{ .normal, .search_view }, .description = "toggle expand", .category = "Tree" },
    // Navigation (both modes)
    .{ .key = .{ .char = 'g' }, .action = .jump_top, .modes = &.{ .normal, .search_view }, .description = "top", .category = "Navigation" },
    .{ .key = .{ .char = 'G' }, .action = .jump_bottom, .modes = &.{ .normal, .search_view }, .description = "bottom", .category = "Navigation" },
    .{ .key = .{ .char = '*' }, .action = .toggle_expand_all, .modes = &.{ .normal, .search_view }, .description = "Expand all", .category = "Tree" },
    .{ .key = .{ .char = 'j' }, .action = .move_down, .modes = &.{ .normal, .search_view }, .description = "down", .category = "Navigation" },
    .{ .key = .{ .char = 'k' }, .action = .move_up, .modes = &.{ .normal, .search_view }, .description = "up", .category = "Navigation" },
    .{ .key = .{ .special = .up }, .action = .move_up, .modes = &.{ .normal, .search_view }, .description = "" },
    .{ .key = .{ .special = .down }, .action = .move_down, .modes = &.{ .normal, .search_view }, .description = "" },
    .{ .key = .{ .char = 'u' }, .action = .page_up, .modes = &.{ .normal, .search_view }, .description = "page up", .category = "Navigation" },
    .{ .key = .{ .char = 'd' }, .action = .page_down, .modes = &.{ .normal, .search_view }, .description = "page down", .category = "Navigation" },
    // Application
    .{ .key = .{ .char = 'q' }, .action = .quit, .modes = &.{ .normal, .search_view }, .description = "quit", .category = "General" },
    .{ .key = .{ .special = .esc }, .action = .quit, .modes = &.{.normal}, .description = "" },
    // Search
    .{ .key = .{ .special = .esc }, .action = .exit_search_view, .modes = &.{.search_view}, .description = "Exit search", .category = "Search" },
    .{ .key = .{ .char = '/' }, .action = .start_search, .modes = &.{ .normal, .search_view }, .description = "search", .category = "Search" },
    .{ .key = .{ .char = 'c' }, .action = .clear_search, .modes = &.{ .normal, .search_view }, .description = "clear", .category = "Search" },

    // Process control
    .{ .key = .{ .char = 'x' }, .action = .kill_term, .modes = &.{.normal}, .description = "kill", .category = "Process" },
    .{ .key = .{ .char = 'X' }, .action = .kill_force, .modes = &.{.normal}, .description = "kill -9", .category = "Process" },

    // Sorting
    .{ .key = .{ .char = 'P' }, .action = .sort_by_pid, .modes = &.{ .normal, .search_view }, .description = "sort PID", .category = "Sorting" },
    .{ .key = .{ .char = 'N' }, .action = .sort_by_name, .modes = &.{ .normal, .search_view }, .description = "sort Name", .category = "Sorting" },
    .{ .key = .{ .char = 'C' }, .action = .sort_by_cpu, .modes = &.{ .normal, .search_view }, .description = "sort CPU", .category = "Sorting" },
    .{ .key = .{ .char = 'M' }, .action = .sort_by_mem, .modes = &.{ .normal, .search_view }, .description = "sort mem", .category = "Sorting" },

    // Help mode (close help)
    .{ .key = .{ .char = '?' }, .action = .show_help, .modes = &.{.help}, .description = "" },
    .{ .key = .{ .special = .esc }, .action = .show_help, .modes = &.{.help}, .description = "" },
    .{ .key = .{ .char = 'q' }, .action = .show_help, .modes = &.{.help}, .description = "" },
};

pub fn getAction(key: Key, mode: Mode) ?Action {
    for (keymap) |binding| {
        if (std.meta.eql(binding.key, key)) {
            for (binding.modes) |m| {
                if (m == mode) return binding.action;
            }
        }
    }
    return null;
}

pub fn getHelpText(mode: Mode, buf: []u8) []const u8 {
    var pos: usize = 0;

    for (keymap) |binding| {
        if (binding.description.len == 0) continue;

        var in_mode = false;
        for (binding.modes) |m| {
            if (m == mode) {
                in_mode = true;
                break;
            }
        }
        if (!in_mode) continue;

        const key_str = switch (binding.key) {
            .char => |c| &[_]u8{c},
            .special => |s| switch (s) {
                .up => "↑",
                .down => "↓",
                .esc => "esc",
                .enter => "enter",
                .backspace => "bksp",
            },
        };

        if (pos > 0 and pos + 2 < buf.len) {
            buf[pos] = ' ';
            buf[pos + 1] = ' ';
            pos += 2;
        }

        //add key:description
        for (key_str) |c| {
            if (pos >= buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
        if (pos < buf.len) {
            buf[pos] = ':';
            pos += 1;
        }
        for (binding.description) |c| {
            if (pos >= buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
    }

    return buf[0..pos];
}
