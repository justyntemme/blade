const std = @import("std");
const model = @import("model");

const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_port.h");
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});

pub const MachPortError = error{
    TaskForPidFailed,
    MachPortNamesFailed,
    PermissionDenied,
    ProcessNotFound,
    OutOfMemory,
};

/// Type of Mach port right
pub const PortType = enum(u8) {
    send = 1,
    receive = 2,
    send_once = 3,
    port_set = 4,
    dead_name = 5,
};

/// Individual Mach port information
pub const MachPort = struct {
    name: u32,
    port_type: PortType,
    // Service name if known (from bootstrap lookup)
    service_name: [64]u8 = [_]u8{0} ** 64,
    service_name_len: u8 = 0,
    // Receive status (only valid for receive rights)
    msg_count: u32 = 0,
    queue_limit: u32 = 0,
    make_send_count: u32 = 0,
};

/// Summary of Mach ports for a process
pub const MachPortInfo = struct {
    pid: model.pid_t,
    send_rights: []MachPort,
    receive_rights: []MachPort,
    port_sets: []MachPort,
    dead_names: []MachPort,

    pub fn totalCount(self: *const MachPortInfo) usize {
        return self.send_rights.len + self.receive_rights.len +
            self.port_sets.len + self.dead_names.len;
    }

    pub fn deinit(self: *MachPortInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.send_rights);
        alloc.free(self.receive_rights);
        alloc.free(self.port_sets);
        alloc.free(self.dead_names);
    }
};

/// Collect Mach port information for a process.
/// Tries task_for_pid first (requires root), falls back to proc_pidinfo for SIP-protected processes.
pub fn collectMachPorts(alloc: std.mem.Allocator, pid: model.pid_t) MachPortError!MachPortInfo {
    // Try task_for_pid first (gives complete port info)
    if (collectMachPortsViaTask(alloc, pid)) |info| {
        return info;
    } else |_| {
        // Fall back to proc_pidinfo (works for SIP-protected processes, but less detailed)
        return collectMachPortsViaProc(alloc, pid);
    }
}

/// Collect via task_for_pid - complete info but fails on SIP-protected processes
fn collectMachPortsViaTask(alloc: std.mem.Allocator, pid: model.pid_t) MachPortError!MachPortInfo {
    // Get task port for the process (requires root)
    var task: c.mach_port_t = undefined;
    const kr = c.task_for_pid(c.mach_task_self(), pid, &task);
    if (kr != c.KERN_SUCCESS) {
        // KERN_FAILURE (5) usually means SIP protection or process doesn't exist
        // KERN_INVALID_ARGUMENT (4) means invalid PID
        if (kr == 4) return MachPortError.ProcessNotFound;
        return MachPortError.TaskForPidFailed;
    }
    defer _ = c.mach_port_deallocate(c.mach_task_self(), task);

    // Get list of all port names in the task
    var names: [*c]c.mach_port_name_t = undefined;
    var name_count: c.mach_msg_type_number_t = undefined;
    var types: [*c]c.mach_port_type_t = undefined;
    var type_count: c.mach_msg_type_number_t = undefined;

    const kr2 = c.mach_port_names(task, &names, &name_count, &types, &type_count);
    if (kr2 != c.KERN_SUCCESS) {
        return MachPortError.MachPortNamesFailed;
    }
    defer {
        _ = c.vm_deallocate(c.mach_task_self(), @intFromPtr(names), name_count * @sizeOf(c.mach_port_name_t));
        _ = c.vm_deallocate(c.mach_task_self(), @intFromPtr(types), type_count * @sizeOf(c.mach_port_type_t));
    }

    // Categorize ports by type
    var send_rights: std.ArrayListUnmanaged(MachPort) = .empty;
    var receive_rights: std.ArrayListUnmanaged(MachPort) = .empty;
    var port_sets: std.ArrayListUnmanaged(MachPort) = .empty;
    var dead_names: std.ArrayListUnmanaged(MachPort) = .empty;

    const count: usize = @intCast(name_count);
    for (0..count) |i| {
        const name = names[i];
        const ptype = types[i];

        // A port can have multiple rights - check each
        if ((ptype & c.MACH_PORT_TYPE_SEND) != 0) {
            const port = MachPort{
                .name = name,
                .port_type = .send,
            };
            send_rights.append(alloc, port) catch return MachPortError.OutOfMemory;
        }

        if ((ptype & c.MACH_PORT_TYPE_RECEIVE) != 0) {
            var port = MachPort{
                .name = name,
                .port_type = .receive,
            };

            // Get receive status (queue depth, message count)
            var status: c.mach_port_status_t = undefined;
            var status_count: c.mach_msg_type_number_t = @intCast(@sizeOf(c.mach_port_status_t) / @sizeOf(c.natural_t));
            const attr_kr = c.mach_port_get_attributes(
                task,
                name,
                c.MACH_PORT_RECEIVE_STATUS,
                @ptrCast(&status),
                &status_count,
            );
            if (attr_kr == c.KERN_SUCCESS) {
                port.msg_count = @intCast(status.mps_msgcount);
                port.queue_limit = @intCast(status.mps_qlimit);
                port.make_send_count = @intCast(status.mps_mscount);
            }

            receive_rights.append(alloc, port) catch return MachPortError.OutOfMemory;
        }

        if ((ptype & c.MACH_PORT_TYPE_SEND_ONCE) != 0) {
            const port = MachPort{
                .name = name,
                .port_type = .send_once,
            };
            // Count send_once with send rights for simplicity
            send_rights.append(alloc, port) catch return MachPortError.OutOfMemory;
        }

        if ((ptype & c.MACH_PORT_TYPE_PORT_SET) != 0) {
            const port = MachPort{
                .name = name,
                .port_type = .port_set,
            };
            port_sets.append(alloc, port) catch return MachPortError.OutOfMemory;
        }

        if ((ptype & c.MACH_PORT_TYPE_DEAD_NAME) != 0) {
            const port = MachPort{
                .name = name,
                .port_type = .dead_name,
            };
            dead_names.append(alloc, port) catch return MachPortError.OutOfMemory;
        }
    }

    return MachPortInfo{
        .pid = pid,
        .send_rights = send_rights.toOwnedSlice(alloc) catch return MachPortError.OutOfMemory,
        .receive_rights = receive_rights.toOwnedSlice(alloc) catch return MachPortError.OutOfMemory,
        .port_sets = port_sets.toOwnedSlice(alloc) catch return MachPortError.OutOfMemory,
        .dead_names = dead_names.toOwnedSlice(alloc) catch return MachPortError.OutOfMemory,
    };
}

/// Fallback: Collect via proc_pidinfo - works on SIP-protected processes
/// This shows Mach ports associated with file descriptors (partial view)
fn collectMachPortsViaProc(alloc: std.mem.Allocator, pid: model.pid_t) MachPortError!MachPortInfo {
    // Get buffer size needed for fd list
    const buf_size = c.proc_pidinfo(pid, c.PROC_PIDLISTFDS, 0, null, 0);
    if (buf_size <= 0) {
        return MachPortError.ProcessNotFound;
    }

    // Allocate buffer and get fd list
    const fd_count: usize = @intCast(@divFloor(buf_size, @sizeOf(c.proc_fdinfo)));
    const fd_buf = alloc.alloc(c.proc_fdinfo, fd_count) catch return MachPortError.OutOfMemory;
    defer alloc.free(fd_buf);

    const actual_size = c.proc_pidinfo(
        pid,
        c.PROC_PIDLISTFDS,
        0,
        fd_buf.ptr,
        buf_size,
    );
    if (actual_size <= 0) {
        return MachPortError.ProcessNotFound;
    }

    const actual_count: usize = @intCast(@divFloor(actual_size, @sizeOf(c.proc_fdinfo)));

    // Collect Mach port file descriptors
    var send_rights: std.ArrayListUnmanaged(MachPort) = .empty;

    for (fd_buf[0..actual_count]) |fd_info| {
        // PROX_FDTYPE_MACH = 10 (Mach port)
        if (fd_info.proc_fdtype == 10) {
            const port = MachPort{
                .name = @intCast(fd_info.proc_fd),
                .port_type = .send, // Assume send right (most common for fd-backed ports)
            };
            send_rights.append(alloc, port) catch return MachPortError.OutOfMemory;
        }
    }

    // Return partial info (only shows ports with associated fds)
    return MachPortInfo{
        .pid = pid,
        .send_rights = send_rights.toOwnedSlice(alloc) catch return MachPortError.OutOfMemory,
        .receive_rights = &[_]MachPort{}, // Not available via this method
        .port_sets = &[_]MachPort{},
        .dead_names = &[_]MachPort{},
    };
}

