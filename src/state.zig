const std = @import("std");
const channel = @import("thread_channel");
const sort = @import("sort");
const zigtui = @import("zigtui");
const model = @import("model");
const keymap = @import("event_keymap");
// const platform = @import("platform");

pub const ProcHot = struct {
    pid: std.posix.pid_t,
    start_time_ns: i128,
    cpu_percent: f32,
    mem_rss: u64,
};

pub const ProcHotList = std.MultiArrayList(ProcHot);

pub const ProcCold = struct {
    name: []const u8,
    path: []const u8,
    ppid: std.posix.pid_t,
    name_lower: []const u8,
    path_lower: []const u8,
};

pub const VisibleNode = struct {
    data_idx: u32,
    depth: u16,
    has_children: bool,
    is_last: bool,
    is_expanded: bool,
};
//TODO review this idea   Why slices instead of fixed arrays?
// - Slices are 16 bytes (pointer + length) vs 4352 bytes for [256]u8 + [4096]u8
// - The actual string bytes still live in the batch's Proc structs
// - We're just storing a view into that data

pub const SortColumn = enum { pid, name, cpu, mem, path };
pub const SortDirection = enum { asc, desc };

pub const ToastLevel = enum { info, success, warning, err };
pub const Toast = struct {
    message_buf: [128]u8 = [_]u8{0} ** 128,
    message_len: usize = 0,
    level: ToastLevel = .info,
    expired_at: i64 = 0,

    pub fn getMessage(self: *const Toast) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

pub const AppState = struct {
    running: bool = true,
    terminal: ?*zigtui.Terminal = null,
    gpa: std.mem.Allocator,
    selected_item: usize = 0,
    scroll_offset: usize = 0,
    hot: ProcHotList = .{},
    cold: std.ArrayList(ProcCold) = .empty,
    visible_nodes: std.ArrayListUnmanaged(VisibleNode) = .empty,
    sort_column: SortColumn = .cpu,
    sort_direction: SortDirection = .desc,
    active_toast: ?Toast = null,
    current_batch: ?channel.Batch = null,
    mode: keymap.Mode = .normal,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    indices: std.ArrayList(usize) = .empty,
    sorted_indices: std.ArrayList(usize) = .empty,
    previous_batch: ?channel.Batch = null,
    pid_to_index: std.AutoHashMap(std.posix.pid_t, u32),
    children_offsets: std.ArrayListUnmanaged(u32) = .empty,
    children_flat: std.ArrayListUnmanaged(u32) = .empty,
    expanded_pids: std.AutoHashMap(model.ProcIdentity, void),
    pub fn showToast(self: *AppState, message: []const u8, level: ToastLevel) void {
        var toast = Toast{
            .level = level,
        };
        const len = @min(message.len, toast.message_buf.len);
        @memcpy(toast.message_buf[0..len], message[0..len]);

        toast.message_len = len;

        self.active_toast = toast;
    }
    pub fn showToastFmt(self: *AppState, comptime fmt: []const u8, args: anytype, level: ToastLevel) void {
        var toast = Toast{
            .level = level,
        };
        if (std.fmt.bufPrint(&toast.message_buf, fmt, args)) |result| {
            toast.message_len = result.len;
        } else |_| {
            const fallback = "Message too long";
            @memcpy(toast.message_buf[0..fallback.len], fallback);
            toast.message_len = fallback.len;
        }
        self.active_toast = toast;
    }

    pub fn setSort(self: *AppState, column: SortColumn) void {
        if (self.sort_column == column) {
            self.sort_direction = if (self.sort_direction == .asc) .desc else .asc;
        } else {
            self.sort_column = column;
            self.sort_direction = .desc;
        }
        self.sortView();
    }

    /// Full rebuild: populate data, sort, filter, restore selection.
    /// Called on new batch.
    pub fn buildView(self: *AppState) !void {
        const prev_identity = self.getSelectedIdentity();
        try self.populateView();
        if (self.current_batch) |*batch| {
            const arena = batch.arena.allocator();
            try self.buildPidIndexMap(arena);
            try self.buildChildrenAdjacency(arena);
            self.sortChildrenRanges();
            try self.buildVisibleNodes(arena);
        } else {
            self.visible_nodes = .empty;
        }
        self.applySelection(prev_identity);
    }

    /// Re-sort and filter without repopulating data.
    /// Called on sort column/direction change.
    pub fn sortView(self: *AppState) void {
        const prev_identity = self.getSelectedIdentity();
        if (self.current_batch) |*batch| {
            const arena = batch.arena.allocator();
            self.sortChildrenRanges();
            self.buildVisibleNodes(arena) catch return;
        }
        self.applySelection(prev_identity);
    }

    /// Refresh filter without re-sorting.
    /// Called on search change.
    pub fn refreshFilter(self: *AppState) void {
        const prev_identity = self.getSelectedIdentity();
        if (self.current_batch) |*batch| {
            const arena = batch.arena.allocator();
            self.buildVisibleNodes(arena) catch return;
        }
        // self.applyFilter() catch return;
        self.applySelection(prev_identity);
    }

    /// Stage 1: Populate view with ALL processes and computed CPU%.
    fn populateView(self: *AppState) !void {
        self.hot.shrinkRetainingCapacity(0);
        for (self.cold.items) |cold_item| {
            self.gpa.free(cold_item.name_lower);
            self.gpa.free(cold_item.path_lower);
        }
        self.cold.clearRetainingCapacity();

        const batch = self.current_batch orelse return;
        const time_delta: i128 = if (self.previous_batch) |*prev|
            batch.timestamp_ns - prev.timestamp_ns
        else
            0;
        const count = batch.map.count();
        try self.hot.ensureTotalCapacity(self.gpa, count);
        try self.cold.ensureTotalCapacity(self.gpa, count);
        var iter = batch.map.iterator();
        while (iter.next()) |entry| {
            const proc_ptr = entry.value_ptr;

            // Compute CPU%
            var cpu_percent: f32 = 0;
            if (self.previous_batch) |*prev| {
                if (prev.map.getPtr(proc_ptr.pid)) |old_proc| {
                    if (old_proc.start_time_ns == proc_ptr.start_time_ns and time_delta > 0) {
                        const new_total = proc_ptr.total_user + proc_ptr.total_system;
                        const old_total = old_proc.total_user + old_proc.total_system;
                        const cpu_delta = new_total -| old_total;
                        cpu_percent = @as(f32, @floatFromInt(cpu_delta)) / @as(f32, @floatFromInt(time_delta)) * 100.0;
                    }
                }
            }

            const name_slice = std.mem.sliceTo(&proc_ptr.s_name, 0);
            const path_slice = std.mem.sliceTo(&proc_ptr.path, 0);
            const name_lower = try self.gpa.alloc(u8, name_slice.len);
            _ = std.ascii.lowerString(name_lower, name_slice);
            const path_lower = try self.gpa.alloc(u8, path_slice.len);
            _ = std.ascii.lowerString(path_lower, path_slice);

            // Append ALL items (no search filter here)
            self.cold.appendAssumeCapacity(.{
                .name = std.mem.sliceTo(&proc_ptr.s_name, 0),
                .path = std.mem.sliceTo(&proc_ptr.path, 0),
                .ppid = proc_ptr.ppid,
                .name_lower = name_lower,
                .path_lower = path_lower,
            });
            self.hot.appendAssumeCapacity(.{
                .pid = proc_ptr.pid,
                .start_time_ns = proc_ptr.start_time_ns,
                .cpu_percent = cpu_percent,
                .mem_rss = proc_ptr.mem_rss,
            });
        }
        std.debug.assert(self.hot.len == self.cold.items.len); // For development ensure hot is in sync
    }

    fn buildPidIndexMap(self: *AppState, arena: std.mem.Allocator) !void {
        self.pid_to_index = std.AutoHashMap(std.posix.pid_t, u32).init(arena);
        try self.pid_to_index.ensureTotalCapacity(@intCast(self.hot.len));

        const pids = self.hot.items(.pid);
        for (pids, 0..) |pid, i| {
            self.pid_to_index.putAssumeCapacity(pid, @intCast(i));
        }
    }

    fn buildChildrenAdjacency(self: *AppState, arena: std.mem.Allocator) !void {
        const n: usize = self.hot.len;
        self.children_offsets = .empty;
        self.children_flat = .empty;
        if (n == 0) return;

        const child_counts = try arena.alloc(u32, n);
        @memset(child_counts, 0);

        //count children
        for (self.cold.items) |cold_item| {
            if (self.pid_to_index.get(cold_item.ppid)) |parent_idx| {
                const parent_u: usize = @intCast(parent_idx);
                child_counts[parent_u] += 1;
            }
        }

        try self.children_offsets.ensureTotalCapacity(arena, n + 1);
        self.children_offsets.items.len = n + 1;

        var total: u32 = 0;
        for (child_counts, 0..) |count, i| {
            self.children_offsets.items[i] = total;
            total += count;
        }
        self.children_offsets.items[n] = total;

        //allocate flat children array
        const total_children: usize = @intCast(total);
        try self.children_flat.ensureTotalCapacity(arena, total_children);
        self.children_flat.items.len = total_children;

        //fill with write cursor
        const write_cursor = try arena.alloc(u32, n);
        @memcpy(write_cursor, self.children_offsets.items[0..n]);

        for (self.cold.items, 0..) |cold_item, child_i| {
            if (self.pid_to_index.get(cold_item.ppid)) |parent_idx| {
                const parent_u: usize = @intCast(parent_idx);
                const cursor = &write_cursor[parent_u];
                self.children_flat.items[@intCast(cursor.*)] = @intCast(child_i);
                cursor.* += 1;
            }
        }
    }

    fn sortChildrenRanges(self: *AppState) void {
        const n: usize = self.hot.len;
        if (n == 0) return;
        if (self.children_offsets.items.len != n + 1) return;

        for (0..n) |i| {
            const start: usize = @intCast(self.children_offsets.items[i]);
            const end: usize = @intCast(self.children_offsets.items[i + 1]);
            if (end - start <= 1) continue;

            std.mem.sort(u32, self.children_flat.items[start..end], self, compareByNodeIndex);
        }
    }

    fn buildVisibleNodes(self: *AppState, arena: std.mem.Allocator) !void {
        self.visible_nodes = .empty;

        const n: usize = self.hot.len;
        if (n == 0) return;
        if (self.children_offsets.items.len != n + 1) return;

        const search = self.searchSlice();
        var search_lower_buf: [256]u8 = undefined;
        const searching = search.len > 0;
        const search_lower = if (searching)
            std.ascii.lowerString(&search_lower_buf, search)
        else
            search;

        var roots = std.ArrayListUnmanaged(u32){};
        try roots.ensureTotalCapacity(arena, n);
        for (self.cold.items, 0..) |cold_item, idx| {
            if (!self.pid_to_index.contains(cold_item.ppid)) {
                roots.appendAssumeCapacity(@intCast(idx));
            }
        }
        if (roots.items.len > 1) {
            std.mem.sort(u32, roots.items, self, compareByNodeIndex);
        }

        var subtree_flags: ?[]bool = null;

        if (searching) {
            const matches = try arena.alloc(bool, n);
            const subtree = try arena.alloc(bool, n);
            @memset(matches, false);
            @memset(subtree, false);

            for (self.cold.items, 0..) |cold_item, idx| {
                if (self.matchesSearch(cold_item, search_lower)) {
                    matches[idx] = true;
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
                    const child_start: usize = @intCast(self.children_offsets.items[node_u]);
                    const child_end: usize = @intCast(self.children_offsets.items[node_u + 1]);
                    const children = self.children_flat.items[child_start..child_end];
                    var i: usize = children.len;
                    while (i > 0) {
                        i -= 1;
                        walk.appendAssumeCapacity(.{ .node = children[i], .visited = false });
                    }
                } else {
                    var has_match = matches[node_u];
                    const child_start: usize = @intCast(self.children_offsets.items[node_u]);
                    const child_end: usize = @intCast(self.children_offsets.items[node_u + 1]);
                    const children = self.children_flat.items[child_start..child_end];
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

        try self.visible_nodes.ensureTotalCapacity(arena, n);

        const StackItem = struct { node: u32, depth: u16, is_last: bool, force_show: bool };
        var stack = std.ArrayListUnmanaged(StackItem){};
        try stack.ensureTotalCapacity(arena, roots.items.len);

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

            const child_start: usize = @intCast(self.children_offsets.items[data_idx]);
            const child_end: usize = @intCast(self.children_offsets.items[data_idx + 1]);
            const has_children = child_end > child_start;

            const expanded_real = has_children and self.isExpanded(data_idx);
            var display_expanded = expanded_real;
            if (searching and has_children and !display_expanded) {
                if (subtree_flags.?[data_idx]) {
                    display_expanded = true; // auto-expand ancestors in search view
                }
            }

            const should_show = if (!searching)
                true
            else
                subtree_flags.?[data_idx] or item.force_show;

            if (should_show) {
                self.visible_nodes.appendAssumeCapacity(.{
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
                const children = self.children_flat.items[child_start..child_end];
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
                    const children = self.children_flat.items[child_start..child_end];
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
                    const children = self.children_flat.items[child_start..child_end];

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
    }

    /// Stage 2: Build sorted index array from view.
    fn buildIndices(self: *AppState) !void {
        self.sorted_indices.clearRetainingCapacity();
        try self.sorted_indices.ensureTotalCapacity(self.gpa, @intCast(self.hot.len));
        for (0..self.hot.len) |i| {
            self.sorted_indices.appendAssumeCapacity(i);
        }
        std.mem.sort(usize, self.sorted_indices.items, self, compareByIndex);
    }

    /// Stage 3: Filter indices to only include items matching search.
    fn applyFilter(self: *AppState) !void {
        const search = self.searchSlice();
        self.indices.clearRetainingCapacity();
        try self.indices.ensureTotalCapacity(self.gpa, self.sorted_indices.items.len);
        if (search.len == 0) {
            self.indices.appendSliceAssumeCapacity(self.sorted_indices.items);
            return;
        }

        var search_lower_buf: [256]u8 = undefined;
        const search_lower = std.ascii.lowerString(&search_lower_buf, search);

        for (self.sorted_indices.items) |data_idx| {
            const cold_data = self.cold.items[data_idx];
            if (self.matchesSearch(cold_data, search_lower)) {
                self.indices.appendAssumeCapacity(data_idx);
            }
        }
    }

    /// Stage 4: Restore selection by identity, or clamp to valid range.
    fn applySelection(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        self.restoreSelection(prev_identity);
        if (self.visible_nodes.items.len == 0) {
            self.selected_item = 0;
        } else {
            self.selected_item = @min(self.selected_item, self.visible_nodes.items.len - 1);
        }
        self.scroll_offset = 0;
    }
    pub fn down(self: *AppState) void {
        if (self.selected_item < self.visible_nodes.items.len -| 1) {
            self.selected_item += 1;
        }
    }

    pub fn jumpTop(self: *AppState) void {
        self.selected_item = 0;
        self.scroll_offset = 0;
    }

    pub fn jumpBottom(self: *AppState) void {
        if (self.visible_nodes.items.len == 0) {
            self.selected_item = 0;
            self.scroll_offset = 0;
            return;
        }
        self.selected_item = self.visible_nodes.items.len - 1;
    }

    pub fn up(self: *AppState) void {
        if (self.selected_item > 0) {
            self.selected_item -= 1;
        }
    }
    pub fn searchSlice(self: *const AppState) []const u8 {
        return self.search_buf[0..self.search_len];
    }
    pub fn searchAppend(self: *AppState, c: u8) void {
        if (self.search_len < self.search_buf.len - 1) {
            self.search_buf[self.search_len] = c;
            self.search_len += 1;
        }
    }
    pub fn searchBackspace(self: *AppState) void {
        if (self.search_len > 0) {
            self.search_len -= 1;
        }
    }

    pub fn searchClear(self: *AppState) void {
        self.search_len = 0;
    }

    pub fn isExpanded(self: *const AppState, data_idx: usize) bool {
        const id = model.ProcIdentity{
            .pid = self.hot.items(.pid)[data_idx],
            .start_time_ns = self.hot.items(.start_time_ns)[data_idx],
        };
        return self.expanded_pids.contains(id);
    }

    pub fn toggleExpanded(self: *AppState, data_idx: usize) void {
        const id = model.ProcIdentity{
            .pid = self.hot.items(.pid)[data_idx],
            .start_time_ns = self.hot.items(.start_time_ns)[data_idx],
        };
        if (self.expanded_pids.contains(id)) {
            _ = self.expanded_pids.remove(id);
        } else {
            self.expanded_pids.put(id, {}) catch |err| {
                self.showToastFmt("Toggle expand failed: {}", .{err}, .err);
            };
        }
    }
    pub fn toggleExpandAll(self: *AppState) void {
        const n: usize = self.hot.len;
        if (n == 0) return;
        if (self.children_offsets.items.len != n + 1) return;

        var any_collapsed = false;
        var parent_count: usize = 0;

        for (0..n) |i| {
            const child_start: usize = @intCast(self.children_offsets.items[i]);
            const child_end: usize = @intCast(self.children_offsets.items[i + 1]);
            if (child_end > child_start) {
                parent_count += 1;
                if (!self.isExpanded(i)) {
                    any_collapsed = true;
                }
            }
        }

        if (any_collapsed) {
            const needed_capacity: u32 = @intCast(@max(self.expanded_pids.count(), parent_count));
            self.expanded_pids.ensureTotalCapacity(needed_capacity) catch |err|
                {
                    self.showToastFmt("Expand all failed: {}", .{err}, .err);
                    return;
                };
            for (0..n) |i| {
                const child_start: usize = @intCast(self.children_offsets.items[i]);
                const child_end: usize = @intCast(self.children_offsets.items[i + 1]);
                if (child_end > child_start) {
                    const id = model.ProcIdentity{
                        .pid = self.hot.items(.pid)[i],
                        .start_time_ns = self.hot.items(.start_time_ns)[i],
                    };
                    self.expanded_pids.putAssumeCapacity(id, {});
                }
            }
        } else {
            for (0..n) |i| {
                const child_start: usize = @intCast(self.children_offsets.items[i]);
                const child_end: usize = @intCast(self.children_offsets.items[i + 1]);
                if (child_end > child_start) {
                    const id = model.ProcIdentity{
                        .pid = self.hot.items(.pid)[i],
                        .start_time_ns = self.hot.items(.start_time_ns)[i],
                    };
                    _ = self.expanded_pids.remove(id);
                }
            }
        }

        if (self.current_batch) |*batch| {
            const prev_identity = self.getSelectedIdentity();
            const prev_scroll = self.scroll_offset;
            const arena = batch.arena.allocator();
            self.buildVisibleNodes(arena) catch |err| {
                self.showToastFmt("Build visible nodes failed: {}", .{err}, .err);
                return;
            };
            self.restoreSelection(prev_identity);
            if (self.visible_nodes.items.len == 0) {
                self.selected_item = 0;
                self.scroll_offset = 0;
                return;
            }
            self.selected_item = @min(self.selected_item, self.visible_nodes.items.len - 1);
            self.scroll_offset = @min(prev_scroll, self.visible_nodes.items.len - 1);
        }
    }

    fn setExpandedSubtree(self: *AppState, root_idx: u32, expand: bool) !void {
        const n: usize = self.hot.len;
        if (n == 0) return;
        if (self.children_offsets.items.len != n + 1) return error.invalidState;

        var stack = std.ArrayListUnmanaged(u32){};
        defer stack.deinit(self.gpa);

        try stack.append(self.gpa, root_idx);

        while (stack.items.len > 0) {
            const last = stack.items.len - 1;
            const node_idx = stack.items[last];
            stack.items.len = last;

            const node_u: usize = @intCast(node_idx);
            const child_start: usize = @intCast(self.children_offsets.items[node_u]);
            const child_end: usize = @intCast(self.children_offsets.items[node_u + 1]);
            const has_children = child_end > child_start;

            if (has_children) {
                const id = model.ProcIdentity{
                    .pid = self.hot.items(.pid)[node_u],
                    .start_time_ns = self.hot.items(.start_time_ns)[node_u],
                };
                if (expand) {
                    try self.expanded_pids.put(id, {});
                } else {
                    _ = self.expanded_pids.remove(id);
                }

                const children = self.children_flat.items[child_start..child_end];
                var i: usize = children.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(self.gpa, children[i]);
                }
            }
        }
    }
    pub fn toggleSelectedExpansion(self: *AppState) void {
        if (self.visible_nodes.items.len == 0) return;

        const prev_identity = self.getSelectedIdentity();
        const idx = @min(self.selected_item, self.visible_nodes.items.len - 1);
        const node = self.visible_nodes.items[idx];
        if (!node.has_children) return;

        const data_idx: usize = @intCast(node.data_idx);
        const expand = !self.isExpanded(data_idx);

        self.setExpandedSubtree(node.data_idx, expand) catch |err| {
            self.showToastFmt("Expand failed: {}", .{err}, .err);
            return;
        };

        // self.toggleExpanded(pid);

        if (self.current_batch) |*batch| {
            const prev_scroll = self.scroll_offset;
            const arena = batch.arena.allocator();
            self.buildVisibleNodes(arena) catch |err| {
                self.showToastFmt("Build visible nodes failed: {}", .{err}, .err);
                return;
            };
            self.restoreSelection(prev_identity);
            if (self.visible_nodes.items.len == 0) {
                self.selected_item = 0;
                self.scroll_offset = 0;
                return;
            }
            self.selected_item = @min(self.selected_item, self.visible_nodes.items.len - 1);
            self.scroll_offset = @min(prev_scroll, self.visible_nodes.items.len - 1);
            // self.applySelection(prev_identity);
        }
    }

    pub fn init(gpa: std.mem.Allocator) AppState {
        return .{
            .gpa = gpa,
            .pid_to_index = std.AutoHashMap(std.posix.pid_t, u32).init(gpa),
            .expanded_pids = std.AutoHashMap(model.ProcIdentity, void).init(gpa),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.indices.deinit(self.gpa);
        self.sorted_indices.deinit(self.gpa);
        self.expanded_pids.deinit();
        self.hot.deinit(self.gpa);
        for (self.cold.items) |cold_item| {
            self.gpa.free(cold_item.name_lower);
            self.gpa.free(cold_item.path_lower);
        }
        self.cold.deinit(self.gpa);
        if (self.current_batch) |*batch| {
            batch.deinit();
        }
        if (self.previous_batch) |*batch| {
            batch.deinit();
        }
    }
    pub fn receive_batch(self: *AppState, new_batch: channel.Batch) void {
        // Ownership transfer: we now own new_batch and must deinit it later.
        // Slide the batch window: previous -> discard, current -> previous, new -> current.
        if (self.previous_batch) |*old| {
            old.deinit();
        }
        self.previous_batch = self.current_batch;
        self.current_batch = new_batch;

        self.buildView() catch |err| {
            std.debug.print("buildView failed :{}\n", .{err});
        };
    }

    fn matchesSearch(self: *const AppState, cold_data: ProcCold, search: []const u8) bool {
        _ = self; //unused for now but keeps method on appstate for future changes
        //Buffers

        if (std.mem.indexOf(u8, cold_data.name_lower, search) != null) {
            return true;
        }

        if (std.mem.indexOf(u8, cold_data.path_lower, search) != null) {
            return true;
        }

        return false;
    }
    fn getSelectedIdentity(self: *const AppState) ?model.ProcIdentity {
        if (self.visible_nodes.items.len == 0) return null;
        if (self.selected_item == 0) return null;
        //Clamp selected time within item bounds
        const idx = @min(self.selected_item, self.visible_nodes.items.len - 1);
        const node = self.visible_nodes.items[idx];
        const data_idx: usize = @intCast(node.data_idx);
        return .{
            .pid = self.hot.items(.pid)[data_idx],
            .start_time_ns = self.hot.items(.start_time_ns)[data_idx],
        };
    }

    fn restoreSelection(self: *AppState, prev_identity: ?model.ProcIdentity) void {
        if (prev_identity) |identity| {
            const pids = self.hot.items(.pid);
            const start_times = self.hot.items(.start_time_ns);
            for (self.visible_nodes.items, 0..) |node, i| {
                const data_idx: usize = @intCast(node.data_idx);
                if (pids[data_idx] == identity.pid and start_times[data_idx] == identity.start_time_ns) {
                    self.selected_item = i;
                    return;
                }
            }
        }
    }
};

fn compareByIndex(ctx: *const AppState, a: usize, b: usize) bool {
    return sort.compareByIndex(ctx, a, b);
}

fn compareByNodeIndex(ctx: *const AppState, a: u32, b: u32) bool {
    return compareByIndex(ctx, @intCast(a), @intCast(b));
}

pub const DrawContext = struct {
    state: *AppState,
    scratch: std.mem.Allocator,
};
