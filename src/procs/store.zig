const std = @import("std");
const model = @import("model");
const tree = @import("procs_tree");
const _sort = @import("procs_sort");
const channel = @import("thread_channel");

pub const Store = struct {
    hot: model.ProcHotList = .{},
    cold: model.ProcColdList = .{},
    visible_nodes: std.ArrayListUnmanaged(model.VisibleNode) = .empty,
    render_rows: std.ArrayListUnmanaged(model.RenderRow) = .empty,
    sort_column: model.SortColumn = .cpu,
    sort_direction: model.SortDirection = .desc,
    adjacency: tree.Adjacency = .{},
    pid_to_index: std.AutoHashMap(model.pid_t, u32),
    expanded_pids: std.AutoHashMap(model.ProcIdentity, void),
    current_batch: ?channel.Batch = null,
    previous_batch: ?channel.Batch = null,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{
            .gpa = gpa,
            .pid_to_index = std.AutoHashMap(model.pid_t, u32).init(gpa),
            .expanded_pids = std.AutoHashMap(model.ProcIdentity, void).init(gpa),
        };
    }

    pub fn deinit(self: *Store) void {
        self.expanded_pids.deinit();
        self.hot.deinit(self.gpa);
        self.cold.deinit(self.gpa);
        self.render_rows.deinit(self.gpa);
        if (self.current_batch) |*batch| {
            batch.deinit();
        }
        if (self.previous_batch) |*batch| {
            batch.deinit();
        }
    }

    pub fn sortContext(self: *const Store) model.SortContext {
        return .{
            .pids = self.hot.items(.pid),
            .cpu_percents = self.hot.items(.cpu_percent),
            .mem_rsss = self.hot.items(.mem_rss),
            .cold_names = self.cold.items(.name),
            .cold_paths = self.cold.items(.path),
            .sort_column = self.sort_column,
            .sort_direction = self.sort_direction,
        };
    }

    pub fn identityAt(self: *const Store, data_idx: usize) model.ProcIdentity {
        return .{
            .pid = self.hot.items(.pid)[data_idx],
            .start_time_ns = self.hot.items(.start_time_ns)[data_idx],
        };
    }

    pub fn findIdentity(self: *const Store, identity: model.ProcIdentity) ?usize {
        const pids = self.hot.items(.pid);
        const start_times = self.hot.items(.start_time_ns);
        for (self.visible_nodes.items, 0..) |node, i| {
            const data_idx: usize = @intCast(node.data_idx);
            if (pids[data_idx] == identity.pid and start_times[data_idx] == identity.start_time_ns) {
                return i;
            }
        }
        return null;
    }

    pub fn receiveBatch(self: *Store, new_batch: channel.Batch) void {
        if (self.previous_batch) |*old| {
            old.deinit();
        }
        self.previous_batch = self.current_batch;
        self.current_batch = new_batch;
    }

    pub fn setSort(self: *Store, column: model.SortColumn) void {
        if (self.sort_column == column) {
            self.sort_direction = if (self.sort_direction == .asc) .desc else .asc;
        } else {
            self.sort_column = column;
            self.sort_direction = .desc;
        }
    }

    pub fn populateView(self: *Store) !void {
        self.hot.shrinkRetainingCapacity(0);
        self.cold.shrinkRetainingCapacity(0);

        if (self.current_batch == null) return;
        const batch = &self.current_batch.?;
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

            self.cold.appendAssumeCapacity(.{
                .name = proc_ptr.name,
                .path = proc_ptr.path,
                .ppid = proc_ptr.ppid,
            });
            self.hot.appendAssumeCapacity(.{
                .pid = proc_ptr.pid,
                .start_time_ns = proc_ptr.start_time_ns,
                .cpu_percent = cpu_percent,
                .mem_rss = proc_ptr.mem_rss,
            });
        }
        std.debug.assert(self.hot.len == self.cold.len);
    }

    pub fn rebuildVisible(self: *Store, search: []const u8) !void {
        const batch = if (self.current_batch) |*b| b else return;
        const arena = batch.arena.allocator();
        const ctx = self.sortContext();

        self.visible_nodes = try tree.buildVisibleNodes(
            self.hot,
            self.cold.items(.ppid),
            self.cold.items(.name),
            self.cold.items(.path),
            &self.adjacency,
            self.pid_to_index,
            &self.expanded_pids,
            search,
            ctx,
            _sort.compareByNodeIndex,
            arena,
        );
        try self.materializeRenderRows();
    }

    pub fn buildPipeline(self: *Store, search: []const u8) !void {
        try self.populateView();
        if (self.current_batch) |*batch| {
            const arena = batch.arena.allocator();
            self.pid_to_index = try tree.buildPidIndexMap(self.hot.items(.pid), arena);
            self.adjacency = try tree.buildAdjacency(self.cold.items(.ppid), self.pid_to_index, self.hot.len, arena);
            const ctx = self.sortContext();
            tree.sortChildren(&self.adjacency, self.hot.len, ctx, _sort.compareByNodeIndex);
        } else {
            self.visible_nodes = .empty;
            self.render_rows.clearRetainingCapacity();
            return;
        }
        try self.rebuildVisible(search);
    }

    pub fn sortAndRebuild(self: *Store, search: []const u8) !void {
        const ctx = self.sortContext();
        tree.sortChildren(&self.adjacency, self.hot.len, ctx, _sort.compareByNodeIndex);
        try self.rebuildVisible(search);
    }

    pub fn isExpanded(self: *const Store, data_idx: usize) bool {
        return self.expanded_pids.contains(self.identityAt(data_idx));
    }

    pub fn toggleExpanded(self: *Store, data_idx: usize) !void {
        const id = self.identityAt(data_idx);
        if (self.expanded_pids.contains(id)) {
            _ = self.expanded_pids.remove(id);
        } else {
            try self.expanded_pids.ensureUnusedCapacity(1);
            self.expanded_pids.putAssumeCapacity(id, {});
        }
    }

    pub fn setExpandedSubtree(self: *Store, root_idx: u32, expand: bool) !void {
        const n: usize = self.hot.len;
        if (n == 0) return;
        if (self.adjacency.offsets.items.len != n + 1) return error.invalidState;

        // Reserve capacity upfront — worst case is all nodes
        if (expand) {
            try self.expanded_pids.ensureUnusedCapacity(@intCast(n));
        }

        var stack = std.ArrayListUnmanaged(u32){};
        defer stack.deinit(self.gpa);
        try stack.ensureTotalCapacity(self.gpa, @intCast(n));

        // All mutations below are now infallible
        stack.appendAssumeCapacity(root_idx);

        while (stack.items.len > 0) {
            const last = stack.items.len - 1;
            const node_idx = stack.items[last];
            stack.items.len = last;

            const node_u: usize = @intCast(node_idx);
            const children = self.adjacency.childrenOf(node_u);
            const has_children = children.len > 0;

            if (has_children) {
                const id = self.identityAt(node_u);
                if (expand) {
                    self.expanded_pids.putAssumeCapacity(id, {});
                } else {
                    _ = self.expanded_pids.remove(id);
                }

                var i: usize = children.len;
                while (i > 0) {
                    i -= 1;
                    stack.appendAssumeCapacity(children[i]);
                }
            }
        }
    }

    pub fn materializeRenderRows(self: *Store) !void {
        self.render_rows.clearRetainingCapacity();
        try self.render_rows.ensureTotalCapacity(self.gpa, self.visible_nodes.items.len);

        const pids = self.hot.items(.pid);
        const cpus = self.hot.items(.cpu_percent);
        const mems = self.hot.items(.mem_rss);
        const names = self.cold.items(.name);
        const paths = self.cold.items(.path);

        for (self.visible_nodes.items) |vn| {
            const di: usize = @intCast(vn.data_idx);
            self.render_rows.appendAssumeCapacity(.{
                .pid = pids[di],
                .cpu_percent = cpus[di],
                .mem_rss = mems[di],
                .name = names[di],
                .path = paths[di],
                .depth = vn.depth,
                .has_children = vn.has_children,
                .is_last = vn.is_last,
                .is_expanded = vn.is_expanded,
                .data_idx = vn.data_idx,
            });
        }
    }

    pub fn toggleExpandAll(self: *Store) !void {
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
            try self.expanded_pids.ensureTotalCapacity(needed_capacity);
            for (0..n) |i| {
                if (self.adjacency.childrenOf(i).len > 0) {
                    self.expanded_pids.putAssumeCapacity(self.identityAt(i), {});
                }
            }
        } else {
            for (0..n) |i| {
                if (self.adjacency.childrenOf(i).len > 0) {
                    _ = self.expanded_pids.remove(self.identityAt(i));
                }
            }
        }
    }
};
