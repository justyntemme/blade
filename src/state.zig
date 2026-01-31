const std = @import("std");
const channel = @import("thread_channel");
const sort = @import("sort");
const zigtui = @import("zigtui");
const model = @import("model");
const keymap = @import("event_keymap");
const tree = @import("tree");

// Re-exports for backward compatibility (used by render.zig, etc.)
pub const ProcHot = model.ProcHot;
pub const ProcHotList = model.ProcHotList;
pub const ProcCold = model.ProcCold;
pub const VisibleNode = model.VisibleNode;
pub const SortColumn = model.SortColumn;
pub const SortDirection = model.SortDirection;

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
    previous_batch: ?channel.Batch = null,
    pid_to_index: std.AutoHashMap(std.posix.pid_t, u32),
    adjacency: tree.Adjacency = .{},
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
            self.pid_to_index = try tree.buildPidIndexMap(self.hot.items(.pid), arena);
            self.adjacency = try tree.buildAdjacency(self.cold.items, self.pid_to_index, self.hot.len, arena);
            tree.sortChildren(&self.adjacency, self.hot.len, self, compareByNodeIndex);
        } else {
            self.visible_nodes = .empty;
            self.selected_item = 0;
            self.scroll_offset = 0;
            return;
        }
        self.rebuildVisibleAndRestore(prev_identity, false);
    }

    /// Re-sort and filter without repopulating data.
    /// Called on sort column/direction change.
    pub fn sortView(self: *AppState) void {
        const prev_identity = self.getSelectedIdentity();
        tree.sortChildren(&self.adjacency, self.hot.len, self, compareByNodeIndex);
        self.rebuildVisibleAndRestore(prev_identity, false);
    }

    /// Refresh filter without re-sorting.
    /// Called on search change.
    pub fn refreshFilter(self: *AppState) void {
        const prev_identity = self.getSelectedIdentity();
        self.rebuildVisibleAndRestore(prev_identity, false);
    }

    /// Stage 1: Populate view with ALL processes and computed CPU%.
    fn populateView(self: *AppState) !void {
        self.hot.shrinkRetainingCapacity(0);
        self.cold.clearRetainingCapacity();

        if (self.current_batch == null) return;
        const batch = &self.current_batch.?;
        const arena = batch.arena.allocator();
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
            const name_lower = try arena.alloc(u8, name_slice.len);
            _ = std.ascii.lowerString(name_lower, name_slice);
            const path_lower = try arena.alloc(u8, path_slice.len);
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

    fn rebuildVisibleAndRestore(self: *AppState, prev_identity: ?model.ProcIdentity, preserve_scroll: bool) void {
        const batch = if (self.current_batch) |*b| b else return;
        const prev_scroll = self.scroll_offset;
        const arena = batch.arena.allocator();

        self.visible_nodes = tree.buildVisibleNodes(
            self.hot,
            self.cold.items,
            &self.adjacency,
            self.pid_to_index,
            &self.expanded_pids,
            self.searchSlice(),
            self,
            compareByNodeIndex,
            arena,
        ) catch |err| {
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
        self.scroll_offset = if (preserve_scroll)
            @min(prev_scroll, self.visible_nodes.items.len - 1)
        else
            0;
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
        if (self.adjacency.offsets.items.len != n + 1) return;

        var any_collapsed = false;
        var parent_count: usize = 0;

        for (0..n) |i| {
            if (self.adjacency.childrenOf(i).len > 0) {
                parent_count += 1;
                if (!self.isExpanded(i)) {
                    any_collapsed = true;
                }
            }
        }

        if (any_collapsed) {
            const needed_capacity: u32 = @intCast(self.expanded_pids.count() + parent_count);
            self.expanded_pids.ensureTotalCapacity(needed_capacity) catch |err|
                {
                    self.showToastFmt("Expand all failed: {}", .{err}, .err);
                    return;
                };
            for (0..n) |i| {
                if (self.adjacency.childrenOf(i).len > 0) {
                    const id = model.ProcIdentity{
                        .pid = self.hot.items(.pid)[i],
                        .start_time_ns = self.hot.items(.start_time_ns)[i],
                    };
                    self.expanded_pids.putAssumeCapacity(id, {});
                }
            }
        } else {
            for (0..n) |i| {
                if (self.adjacency.childrenOf(i).len > 0) {
                    const id = model.ProcIdentity{
                        .pid = self.hot.items(.pid)[i],
                        .start_time_ns = self.hot.items(.start_time_ns)[i],
                    };
                    _ = self.expanded_pids.remove(id);
                }
            }
        }

        self.rebuildVisibleAndRestore(self.getSelectedIdentity(), true);
    }

    fn setExpandedSubtree(self: *AppState, root_idx: u32, expand: bool) !void {
        const n: usize = self.hot.len;
        if (n == 0) return;
        if (self.adjacency.offsets.items.len != n + 1) return error.invalidState;

        var stack = std.ArrayListUnmanaged(u32){};
        defer stack.deinit(self.gpa);

        try stack.append(self.gpa, root_idx);

        while (stack.items.len > 0) {
            const last = stack.items.len - 1;
            const node_idx = stack.items[last];
            stack.items.len = last;

            const node_u: usize = @intCast(node_idx);
            const children = self.adjacency.childrenOf(node_u);
            const has_children = children.len > 0;

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

        self.rebuildVisibleAndRestore(prev_identity, true);
    }

    pub fn init(gpa: std.mem.Allocator) AppState {
        return .{
            .gpa = gpa,
            .pid_to_index = std.AutoHashMap(std.posix.pid_t, u32).init(gpa),
            .expanded_pids = std.AutoHashMap(model.ProcIdentity, void).init(gpa),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.expanded_pids.deinit();
        self.hot.deinit(self.gpa);
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
