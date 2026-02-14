const std = @import("std");

const actions = @import("event_action");

pub const Action = actions.Action;

pub const Mode = enum { normal, search_edit, search_view, help, detail, confirm_dialog };

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
    tab,
};

pub const keymap = [_]KeyBinding{
    .{ .key = .{ .char = '?' }, .action = .show_help, .modes = &.{ .normal, .search_view, .help }, .description = "Show Help", .category = "General" },

    // Navigation (all scrollable modes)
    .{ .key = .{ .char = 'j' }, .action = .move_down, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "down", .category = "Navigation" },
    .{ .key = .{ .char = 'k' }, .action = .move_up, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "up", .category = "Navigation" },
    .{ .key = .{ .special = .up }, .action = .move_up, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "" },
    .{ .key = .{ .special = .down }, .action = .move_down, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "" },
    .{ .key = .{ .char = 'u' }, .action = .page_up, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "page up", .category = "Navigation" },
    .{ .key = .{ .char = 'd' }, .action = .page_down, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "page down", .category = "Navigation" },
    .{ .key = .{ .char = 'g' }, .action = .jump_top, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "top", .category = "Navigation" },
    .{ .key = .{ .char = 'G' }, .action = .jump_bottom, .modes = &.{ .normal, .search_view, .help, .detail }, .description = "bottom", .category = "Navigation" },

    // Tree expand/collapse
    .{ .key = .{ .special = .tab }, .action = .toggle_expand, .modes = &.{ .normal, .search_view }, .description = "toggle expand", .category = "Tree" },
    .{ .key = .{ .char = '*' }, .action = .toggle_expand_all, .modes = &.{ .normal, .search_view }, .description = "Expand all", .category = "Tree" },

    // Selection
    .{ .key = .{ .char = ' ' }, .action = .toggle_select, .modes = &.{ .normal, .search_view }, .description = "select/pin", .category = "Selection" },
    .{ .key = .{ .char = 'c' }, .action = .clear_selections, .modes = &.{ .normal, .search_view }, .description = "clear selections", .category = "Selection" },

    // Process
    .{ .key = .{ .special = .enter }, .action = .open_detail, .modes = &.{ .normal, .search_view }, .description = "details", .category = "Process" },
    .{ .key = .{ .char = 'x' }, .action = .kill_term, .modes = &.{ .normal, .search_view, .detail }, .description = "kill", .category = "Process" },
    .{ .key = .{ .char = 'X' }, .action = .kill_force, .modes = &.{ .normal, .search_view, .detail }, .description = "kill -9", .category = "Process" },
    .{ .key = .{ .char = '+' }, .action = .nice_down, .modes = &.{ .normal, .search_view }, .description = "lower priority", .category = "Process" },
    .{ .key = .{ .char = '-' }, .action = .nice_up, .modes = &.{ .normal, .search_view }, .description = "raise priority", .category = "Process" },

    // Search
    .{ .key = .{ .char = '/' }, .action = .start_search, .modes = &.{ .normal, .search_view }, .description = "search", .category = "Search" },
    .{ .key = .{ .special = .esc }, .action = .exit_search_view, .modes = &.{.search_view}, .description = "clear/exit", .category = "Search" },

    // Sorting
    .{ .key = .{ .char = 'P' }, .action = .sort_by_pid, .modes = &.{ .normal, .search_view }, .description = "sort PID", .category = "Sorting" },
    .{ .key = .{ .char = 'N' }, .action = .sort_by_name, .modes = &.{ .normal, .search_view }, .description = "sort Name", .category = "Sorting" },
    .{ .key = .{ .char = 'C' }, .action = .sort_by_cpu, .modes = &.{ .normal, .search_view }, .description = "sort CPU", .category = "Sorting" },
    .{ .key = .{ .char = 'M' }, .action = .sort_by_mem, .modes = &.{ .normal, .search_view }, .description = "sort mem", .category = "Sorting" },

    // Dashboard graph toggle
    .{ .key = .{ .char = '1' }, .action = .dashboard_cpu, .modes = &.{ .normal, .search_view }, .description = "CPU graph", .category = "Display" },
    .{ .key = .{ .char = '2' }, .action = .dashboard_mem, .modes = &.{ .normal, .search_view }, .description = "Memory graph", .category = "Display" },

    // CPU Overlay
    .{ .key = .{ .char = 't' }, .action = .toggle_temp_unit, .modes = &.{ .normal, .search_view }, .description = "temp °C/°F", .category = "Display" },

    // Storage Overlay
    .{ .key = .{ .char = 's' }, .action = .cycle_storage_detail, .modes = &.{ .normal, .search_view }, .description = "storage detail", .category = "Display" },
    .{ .key = .{ .char = 'm' }, .action = .toggle_mount_filter, .modes = &.{ .normal, .search_view }, .description = "mount filter", .category = "Display" },

    // Network
    .{ .key = .{ .char = 'n' }, .action = .toggle_network_mode, .modes = &.{ .normal, .search_view }, .description = "network mode", .category = "Display" },
    .{ .key = .{ .char = 'p' }, .action = .toggle_protocol_filter, .modes = &.{ .normal, .search_view }, .description = "protocol filter", .category = "Display" },

    // Dashboard pane focus (H/L to switch between network pane on left and process list on right)
    .{ .key = .{ .char = 'H' }, .action = .focus_left, .modes = &.{ .normal, .search_view }, .description = "focus network", .category = "Navigation" },
    .{ .key = .{ .char = 'L' }, .action = .focus_right, .modes = &.{ .normal, .search_view }, .description = "focus processes", .category = "Navigation" },

    // Network column navigation (h/l when network pane focused)
    .{ .key = .{ .char = 'h' }, .action = .move_left, .modes = &.{ .normal, .search_view }, .description = "left column", .category = "Navigation" },
    .{ .key = .{ .char = 'l' }, .action = .move_right, .modes = &.{ .normal, .search_view }, .description = "right column", .category = "Navigation" },

    // Application
    .{ .key = .{ .char = 'q' }, .action = .quit, .modes = &.{ .normal, .search_view }, .description = "quit", .category = "General" },
    .{ .key = .{ .special = .esc }, .action = .quit, .modes = &.{.normal}, .description = "" },

    // Help mode (close)
    .{ .key = .{ .special = .esc }, .action = .show_help, .modes = &.{.help}, .description = "" },
    .{ .key = .{ .char = 'q' }, .action = .show_help, .modes = &.{.help}, .description = "" },

    // Detail mode (close + pane focus + view toggle)
    .{ .key = .{ .special = .esc }, .action = .close_detail, .modes = &.{.detail}, .description = "" },
    .{ .key = .{ .char = 'q' }, .action = .close_detail, .modes = &.{.detail}, .description = "" },
    .{ .key = .{ .char = 'h' }, .action = .focus_left, .modes = &.{.detail}, .description = "" },
    .{ .key = .{ .char = 'l' }, .action = .focus_right, .modes = &.{.detail}, .description = "" },
    .{ .key = .{ .char = 'v' }, .action = .toggle_detail_view, .modes = &.{.detail}, .description = "toggle info/network" },
    .{ .key = .{ .special = .tab }, .action = .toggle_detail_section, .modes = &.{.detail}, .description = "expand/collapse section" },
    .{ .key = .{ .char = 'p' }, .action = .toggle_preserve_log, .modes = &.{.detail}, .description = "preserve log mode" },
    .{ .key = .{ .char = 's' }, .action = .pause_process, .modes = &.{.detail}, .description = "suspend" },
    .{ .key = .{ .char = 'r' }, .action = .resume_process, .modes = &.{.detail}, .description = "resume" },

    // Confirm dialog mode
    .{ .key = .{ .char = 'y' }, .action = .confirm_dialog_yes, .modes = &.{.confirm_dialog}, .description = "" },
    .{ .key = .{ .char = 'Y' }, .action = .confirm_dialog_yes, .modes = &.{.confirm_dialog}, .description = "" },
    .{ .key = .{ .special = .enter }, .action = .confirm_dialog_yes, .modes = &.{.confirm_dialog}, .description = "" },
    .{ .key = .{ .char = 'n' }, .action = .confirm_dialog_no, .modes = &.{.confirm_dialog}, .description = "" },
    .{ .key = .{ .char = 'N' }, .action = .confirm_dialog_no, .modes = &.{.confirm_dialog}, .description = "" },
    .{ .key = .{ .special = .esc }, .action = .confirm_dialog_no, .modes = &.{.confirm_dialog}, .description = "" },
    .{ .key = .{ .char = 'q' }, .action = .confirm_dialog_no, .modes = &.{.confirm_dialog}, .description = "" },
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

