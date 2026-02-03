const std = @import("std");
const model = @import("model");

pub const Adjacency = struct {
    offsets: std.ArrayListUnmanaged(u32) = .empty,
    flat: std.ArrayListUnmanaged(u32) = .empty,

    pub fn childrenOf(self: *const Adjacency, idx: usize) []const u32 {
        const start: usize = @intCast(self.offsets.items[idx]);
        const end: usize = @intCast(self.offsets.items[idx + 1]);
        return self.flat.items[start..end];
    }

    pub fn childrenOfMut(self: *Adjacency, idx: usize) []u32 {
        const start: usize = @intCast(self.offsets.items[idx]);
        const end: usize = @intCast(self.offsets.items[idx + 1]);
        return self.flat.items[start..end];
    }
};

pub fn buildPidIndexMap(pids: []const std.posix.pid_t, arena: std.mem.Allocator) !std.AutoHashMap(std.posix.pid_t, u32) {
    var map = std.AutoHashMap(std.posix.pid_t, u32).init(arena);
    try map.ensureTotalCapacity(@intCast(pids.len));
    for (pids, 0..) |pid, i| {
        map.putAssumeCapacity(pid, @intCast(i));
    }
    return map;
}

pub fn buildAdjacency(
    cold_items: []const model.ProcCold,
    pid_to_index: std.AutoHashMap(std.posix.pid_t, u32),
    n: usize,
    arena: std.mem.Allocator,
) !Adjacency {
    var adj = Adjacency{};
    if (n == 0) return adj;

    const child_counts = try arena.alloc(u32, n);
    @memset(child_counts, 0);

    for (cold_items) |cold_item| {
        if (pid_to_index.get(cold_item.ppid)) |parent_idx| {
            child_counts[@intCast(parent_idx)] += 1;
        }
    }

    try adj.offsets.ensureTotalCapacity(arena, n + 1);
    adj.offsets.items.len = n + 1;

    var total: u32 = 0;
    for (child_counts, 0..) |count, i| {
        adj.offsets.items[i] = total;
        total += count;
    }
    adj.offsets.items[n] = total;

    const total_children: usize = @intCast(total);
    try adj.flat.ensureTotalCapacity(arena, total_children);
    adj.flat.items.len = total_children;

    const write_cursor = try arena.alloc(u32, n);
    @memcpy(write_cursor, adj.offsets.items[0..n]);

    for (cold_items, 0..) |cold_item, child_i| {
        if (pid_to_index.get(cold_item.ppid)) |parent_idx| {
            const parent_u: usize = @intCast(parent_idx);
            const cursor = &write_cursor[parent_u];
            adj.flat.items[@intCast(cursor.*)] = @intCast(child_i);
            cursor.* += 1;
        }
    }

    return adj;
}

pub const CompareFn = fn (model.SortContext, u32, u32) bool;

pub fn sortChildren(adj: *Adjacency, n: usize, sort_ctx: model.SortContext, comptime compareFn: CompareFn) void {
    if (n == 0) return;
    if (adj.offsets.items.len != n + 1) return;

    for (0..n) |i| {
        const children = adj.childrenOfMut(i);
        if (children.len <= 1) continue;
        std.mem.sort(u32, children, sort_ctx, compareFn);
    }
}

fn isNodeExpanded(
    pids: []const std.posix.pid_t,
    start_times: []const i128,
    expanded_pids: *const std.AutoHashMap(model.ProcIdentity, void),
    data_idx: usize,
) bool {
    const id = model.ProcIdentity{
        .pid = pids[data_idx],
        .start_time_ns = start_times[data_idx],
    };
    return expanded_pids.contains(id);
}

fn matchesSearch(cold_data: model.ProcCold, search: []const u8) bool {
    if (std.mem.indexOf(u8, cold_data.name_lower, search) != null) return true;
    if (std.mem.indexOf(u8, cold_data.path_lower, search) != null) return true;
    return false;
}

pub fn buildVisibleNodes(
    hot: model.ProcHotList,
    cold_items: []const model.ProcCold,
    adj: *const Adjacency,
    pid_to_index: std.AutoHashMap(std.posix.pid_t, u32),
    expanded_pids: *const std.AutoHashMap(model.ProcIdentity, void),
    search: []const u8,
    sort_ctx: model.SortContext,
    comptime compareFn: CompareFn,
    arena: std.mem.Allocator,
) !std.ArrayListUnmanaged(model.VisibleNode) {
    var visible_nodes = std.ArrayListUnmanaged(model.VisibleNode){};

    const n: usize = hot.len;
    if (n == 0) return visible_nodes;
    if (adj.offsets.items.len != n + 1) return visible_nodes;

    var search_lower_buf: [256]u8 = undefined;
    const searching = search.len > 0;
    const search_lower = if (searching)
        std.ascii.lowerString(&search_lower_buf, search)
    else
        search;

    var roots = std.ArrayListUnmanaged(u32){};
    try roots.ensureTotalCapacity(arena, n);
    for (cold_items, 0..) |cold_item, idx| {
        if (!pid_to_index.contains(cold_item.ppid)) {
            roots.appendAssumeCapacity(@intCast(idx));
        }
    }
    if (roots.items.len > 1) {
        std.mem.sort(u32, roots.items, sort_ctx, compareFn);
    }

    var subtree_flags: ?[]bool = null;

    if (searching) {
        const matches_arr = try arena.alloc(bool, n);
        const subtree = try arena.alloc(bool, n);
        @memset(matches_arr, false);
        @memset(subtree, false);

        for (cold_items, 0..) |cold_item, idx| {
            if (matchesSearch(cold_item, search_lower)) {
                matches_arr[idx] = true;
            }
        }

        const WalkItem = struct { node: u32, visited: bool };
        var walk = std.ArrayListUnmanaged(WalkItem){};
        try walk.ensureTotalCapacity(arena, n);

        var r: usize = 0;
        while (r < roots.items.len) : (r += 1) {
            walk.appendAssumeCapacity(.{ .node = roots.items[r], .visited = false });
        }

        while (walk.items.len > 0) {
            const last = walk.items.len - 1;
            const item = walk.items[last];
            walk.items.len = last;

            const node_u: usize = @intCast(item.node);
            if (!item.visited) {
                walk.appendAssumeCapacity(.{ .node = item.node, .visited = true });
                const children = adj.childrenOf(node_u);
                var i: usize = children.len;
                while (i > 0) {
                    i -= 1;
                    walk.appendAssumeCapacity(.{ .node = children[i], .visited = false });
                }
            } else {
                var has_match = matches_arr[node_u];
                const children = adj.childrenOf(node_u);
                for (children) |child| {
                    if (subtree[@intCast(child)]) {
                        has_match = true;
                        break;
                    }
                }
                subtree[node_u] = has_match;
            }
        }

        subtree_flags = subtree;
    }

    const pids = hot.items(.pid);
    const start_times = hot.items(.start_time_ns);

    try visible_nodes.ensureTotalCapacity(arena, n);

    const StackItem = struct { node: u32, depth: u16, is_last: bool, force_show: bool };
    var stack = std.ArrayListUnmanaged(StackItem){};
    try stack.ensureTotalCapacity(arena, n);

    var i: usize = roots.items.len;
    while (i > 0) {
        i -= 1;
        const root = roots.items[i];
        if (!searching or subtree_flags.?[@intCast(root)]) {
            stack.appendAssumeCapacity(.{
                .node = root,
                .depth = 0,
                .is_last = i == roots.items.len - 1,
                .force_show = false,
            });
        }
    }

    while (stack.items.len > 0) {
        const last_index = stack.items.len - 1;
        const item = stack.items[last_index];
        stack.items.len = last_index;

        const data_idx: usize = @intCast(item.node);
        const children = adj.childrenOf(data_idx);
        const has_children = children.len > 0;

        const expanded_real = has_children and isNodeExpanded(pids, start_times, expanded_pids, data_idx);
        var display_expanded = expanded_real;
        if (searching and has_children and !display_expanded) {
            if (subtree_flags.?[data_idx]) {
                display_expanded = true;
            }
        }

        const should_show = if (!searching)
            true
        else
            subtree_flags.?[data_idx] or item.force_show;

        if (should_show) {
            visible_nodes.appendAssumeCapacity(.{
                .data_idx = item.node,
                .depth = item.depth,
                .has_children = has_children,
                .is_last = item.is_last,
                .is_expanded = expanded_real,
            });
        }

        if (!has_children) continue;

        if (!searching) {
            if (!expanded_real) continue;
            var j: usize = children.len;
            while (j > 0) {
                j -= 1;
                stack.appendAssumeCapacity(.{
                    .node = children[j],
                    .depth = item.depth + 1,
                    .is_last = j == children.len - 1,
                    .force_show = false,
                });
            }
        } else {
            if (expanded_real) {
                var j: usize = children.len;
                while (j > 0) {
                    j -= 1;
                    stack.appendAssumeCapacity(.{
                        .node = children[j],
                        .depth = item.depth + 1,
                        .is_last = j == children.len - 1,
                        .force_show = true,
                    });
                }
            } else if (subtree_flags.?[data_idx]) {
                var last_visible: ?u32 = null;
                var k: usize = children.len;
                while (k > 0) {
                    k -= 1;
                    const child = children[k];
                    if (subtree_flags.?[@intCast(child)]) {
                        last_visible = child;
                        break;
                    }
                }
                if (last_visible) |last_child| {
                    var j: usize = children.len;
                    while (j > 0) {
                        j -= 1;
                        const child = children[j];
                        if (!subtree_flags.?[@intCast(child)]) continue;
                        stack.appendAssumeCapacity(.{
                            .node = child,
                            .depth = item.depth + 1,
                            .is_last = child == last_child,
                            .force_show = false,
                        });
                    }
                }
            }
        }
    }

    return visible_nodes;
}
