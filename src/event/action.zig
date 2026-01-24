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
};
