pub const Action = enum {
    move_up,
    move_down,
    page_up,
    page_down,

    quit,

    start_search,
    clear_search,

    kill_term,
    kill_force,

    sort_by_pid,
    sort_by_name,
    sort_by_cpu,
    sort_by_mem,
    toggle_expand,
    toggle_expand_all,
    jump_top,
    jump_bottom,
    exit_search_view,
    show_help,
    open_detail,
    close_detail,
    focus_left,
    focus_right,
};
