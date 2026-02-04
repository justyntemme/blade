const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
    @cInclude("sys/sysctl.h");
    @cInclude("pwd.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/host_info.h");
    @cInclude("mach/mach_host.h");
    @cInclude("ifaddrs.h");
    @cInclude("net/if.h");
    @cInclude("stdlib.h");
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("sys/mount.h");
    @cInclude("arpa/inet.h");
    @cInclude("netinet/in.h");
});

const model = @import("model");
const platform = @import("platform.zig");

pub const Proc = model.Proc;
pub const pid_t = model.pid_t;

pub const PlatformError = error{
    FailedToGetProcessCount,
    FailedToGetProcessList,
    FailedToGetProcessPath,
    OutOfMemory,
    PermissionDenied,
    ProcessNotFound,
    Unexpected,
};

pub fn collectSnapshot(arena: std.mem.Allocator) PlatformError!std.AutoHashMap(pid_t, Proc) {
    var proc_map: std.AutoHashMap(pid_t, Proc) = .init(arena);
    const bytes = c.proc_listpids(c.PROC_ALL_PIDS, 0, null, 0);
    const count = @divExact(@as(usize, @intCast(bytes)), @sizeOf(pid_t));
    const pids = try arena.alloc(pid_t, count);
    defer arena.free(pids);
    if (count <= 0) {
        std.debug.print("Failed to get process count\n", .{});
        return error.FailedToGetProcessCount;
    }
    try proc_map.ensureTotalCapacity(@intCast(count));

    // Get the actual PIDs
    const bytes_returned = c.proc_listpids(
        c.PROC_ALL_PIDS,
        0,
        pids.ptr,
        @intCast(count * @sizeOf(pid_t)),
    );

    if (bytes_returned <= 0) {
        std.debug.print("Failed to get process list\n", .{});
        return error.FailedToGetProcessList;
    }
    const actual_count = @as(usize, @intCast(bytes_returned)) / @sizeOf(pid_t);

    // std.debug.print("Found {d} processes:\n\n", .{actual_count});

    // Get info for each process
    for (pids[0..actual_count]) |pid| {
        if (pid == 0) continue;
        // SAFETY: proc_pidinfo() fully initializes this struct; we only read fields if info_size > 0
        var proc_info: c.proc_bsdinfo = undefined;

        // SAFETY: proc_pidinfo() fully initializes this struct; we only read fields if info_size > 0
        var task_info: c.proc_taskinfo = undefined;

        const info_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTBSDINFO,
            0,
            &proc_info,
            @sizeOf(c.proc_bsdinfo),
        );

        const task_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTASKINFO,
            0,
            &task_info,
            @sizeOf(c.proc_taskinfo),
        );
        // SAFETY: proc_pidpath() writes to this buffer; we only read path_len bytes
        var path_buf: [4096]u8 = undefined;
        const path_len = c.proc_pidpath(pid, &path_buf, path_buf.len);

        if (info_size > 0) {
            const c_name = std.mem.sliceTo(&proc_info.pbi_name, 0);
            const start_sec: i128 = @intCast(proc_info.pbi_start_tvsec);
            const start_usec: i128 = @intCast(proc_info.pbi_start_tvusec);
            const start_time_ns = start_sec * std.time.ns_per_s + start_usec * std.time.ns_per_us;
            // SAFETY: s_name and path are fully written via @memcpy before struct is used
            var proc = Proc{
                .pid = pid,
                .ppid = @intCast(proc_info.pbi_ppid),
                .start_time_ns = start_time_ns,
                .s_name = undefined,
                .path = undefined,
                .mem_rss = if (task_size > 0) task_info.pti_resident_size else 0,
                .total_user = if (task_size > 0) task_info.pti_total_user else 0,
                .total_system = if (task_size > 0) task_info.pti_total_system else 0,
            };
            @memcpy(proc.s_name[0..c_name.len], c_name);
            proc.s_name[c_name.len] = 0;
            if (path_len > 0) {
                const len: usize = @intCast(@min(path_len, proc.path.len - 1));
                @memcpy(proc.path[0..len], path_buf[0..len]);

                proc.path[@intCast(path_len)] = 0;
            } else {
                const e = std.posix.errno(0);
                if (e == .SRCH) continue; // process exited between listing and path lookup
                const err_label: []const u8 = switch (e) {
                    .PERM => "[permission denied]",
                    .NOENT => "[binary deleted]",
                    else => "[path unavailable]",
                };
                @memcpy(proc.path[0..err_label.len], err_label);
                proc.path[err_label.len] = 0;
            }
            try proc_map.put(pid, proc);
        }
    } // for each PID

    return proc_map;
}

pub fn signal(pid: pid_t, force: bool) PlatformError!void {
    const sig: i32 = if (force) 9 else 15;
    const result = std.c.kill(pid, sig);
    const e = std.posix.errno(result);
    if (e != .SUCCESS) {
        return switch (e) {
            .PERM => PlatformError.PermissionDenied,
            .SRCH => PlatformError.ProcessNotFound,
            else => PlatformError.Unexpected,
        };
    }
}

pub fn capabilities() platform.Capabilities {
    return .{
        .can_signal = true,
        .has_cpu_time = true,
        .has_memory_info = true,
        .has_io_stats = true,
        .has_start_time = true,
    };
}

pub fn collectSystemMetrics() model.SystemMetrics {
    var metrics = model.SystemMetrics{};
    metrics.timestamp_ns = std.time.nanoTimestamp();

    // Per-core CPU ticks via host_processor_info()
    {
        var num_cpus: c.natural_t = 0;
        var info: c.processor_info_array_t = null;
        var info_count: c.mach_msg_type_number_t = 0;
        const kr = c.host_processor_info(
            c.mach_host_self(),
            c.PROCESSOR_CPU_LOAD_INFO,
            &num_cpus,
            &info,
            &info_count,
        );
        if (kr == c.KERN_SUCCESS) {
            metrics.core_count = @intCast(num_cpus);
            const cpu_load: [*]c.processor_cpu_load_info_data_t = @ptrCast(@alignCast(info));
            const count = @min(num_cpus, model.MAX_CORES);
            for (0..count) |i| {
                const load = cpu_load[i];
                metrics.core_ticks[i] = .{
                    .user = load.cpu_ticks[c.CPU_STATE_USER],
                    .system = load.cpu_ticks[c.CPU_STATE_SYSTEM],
                    .idle = load.cpu_ticks[c.CPU_STATE_IDLE],
                    .nice = load.cpu_ticks[c.CPU_STATE_NICE],
                };
            }
            // Free the allocated info array
            _ = c.vm_deallocate(
                c.mach_task_self(),
                @intFromPtr(info),
                @as(c.vm_size_t, info_count) * @sizeOf(c.natural_t),
            );
        }
    }

    // Memory via host_statistics64(HOST_VM_INFO64) + sysctl(HW_MEMSIZE)
    {
        // Total physical memory
        var mem_size: u64 = 0;
        var mib = [2]c_int{ c.CTL_HW, c.HW_MEMSIZE };
        var size: usize = @sizeOf(u64);
        if (std.c.sysctl(&mib, 2, @ptrCast(&mem_size), &size, null, 0) == 0) {
            metrics.mem_total = mem_size;
        }

        // VM stats for used memory calculation
        var vm_info: c.vm_statistics64_data_t = undefined;
        var count: c.mach_msg_type_number_t = @intCast(@sizeOf(c.vm_statistics64_data_t) / @sizeOf(c.natural_t));
        const kr = c.host_statistics64(
            c.mach_host_self(),
            c.HOST_VM_INFO64,
            @ptrCast(&vm_info),
            &count,
        );
        if (kr == c.KERN_SUCCESS) {
            const page_size: u64 = @intCast(c.vm_kernel_page_size);
            const free_count: u64 = @intCast(vm_info.free_count);
            const inactive_count: u64 = @intCast(vm_info.inactive_count);
            const external_count: u64 = @intCast(vm_info.external_page_count);
            const used_pages: u64 = @intCast(
                @as(u64, @intCast(vm_info.active_count)) +
                    @as(u64, @intCast(vm_info.wire_count)) +
                    @as(u64, @intCast(vm_info.compressor_page_count)),
            );
            metrics.mem_used = used_pages * page_size;
            metrics.mem_detail = .{
                .total = metrics.mem_total,
                .used = metrics.mem_used,
                .available = (free_count + inactive_count) * page_size,
                .cached = external_count * page_size,
                .free = free_count * page_size,
            };
        }
    }

    // Load averages
    {
        var loadavg: [3]f64 = undefined;
        if (c.getloadavg(&loadavg, 3) == 3) {
            metrics.load_avg = loadavg;
        }
    }

    // System uptime via KERN_BOOTTIME
    {
        var boottime: std.c.timeval = undefined;
        var bt_mib = [2]c_int{ c.CTL_KERN, c.KERN_BOOTTIME };
        var bt_size: usize = @sizeOf(std.c.timeval);
        if (std.c.sysctl(&bt_mib, 2, @ptrCast(&boottime), &bt_size, null, 0) == 0) {
            const now = std.time.timestamp();
            const boot_s: i64 = boottime.sec;
            if (now > boot_s) {
                metrics.uptime_seconds = @intCast(now - boot_s);
            }
        }
    }

    // Network IO via getifaddrs (per-interface + totals)
    {
        var ifap: ?*c.ifaddrs = null;
        if (c.getifaddrs(&ifap) == 0) {
            var ifa = ifap;
            while (ifa) |iface| {
                if (iface.ifa_addr != null and
                    iface.ifa_addr.*.sa_family == c.AF_LINK and
                    (iface.ifa_flags & c.IFF_LOOPBACK) == 0)
                {
                    if (iface.ifa_data) |data| {
                        const if_data: *c.if_data = @ptrCast(@alignCast(data));
                        const recv_bytes: u64 = @intCast(if_data.ifi_ibytes);
                        const sent_bytes: u64 = @intCast(if_data.ifi_obytes);
                        metrics.net.bytes_recv += recv_bytes;
                        metrics.net.bytes_sent += sent_bytes;

                        // Store per-interface data (skip interfaces with zero traffic)
                        if ((recv_bytes > 0 or sent_bytes > 0) and
                            metrics.net.iface_count < model.MAX_INTERFACES)
                        {
                            const idx = metrics.net.iface_count;
                            const name_ptr: [*:0]const u8 = @ptrCast(iface.ifa_name);
                            const name_slice = std.mem.sliceTo(name_ptr, 0);
                            const copy_len = @min(name_slice.len, model.IFACE_NAME_LEN);
                            @memcpy(metrics.net.interfaces[idx].name[0..copy_len], name_slice[0..copy_len]);
                            metrics.net.interfaces[idx].name_len = @intCast(copy_len);
                            metrics.net.interfaces[idx].bytes_recv = recv_bytes;
                            metrics.net.interfaces[idx].bytes_sent = sent_bytes;
                            metrics.net.iface_count += 1;
                        }
                    }
                }
                ifa = iface.ifa_next;
            }
            // Second pass: find first non-loopback IPv4 address
            ifa = ifap;
            while (ifa) |iface| {
                if (iface.ifa_addr != null and
                    iface.ifa_addr.*.sa_family == c.AF_INET and
                    (iface.ifa_flags & c.IFF_LOOPBACK) == 0 and
                    (iface.ifa_flags & c.IFF_UP) != 0)
                {
                    const sa_in: *const c.sockaddr_in = @ptrCast(@alignCast(iface.ifa_addr));
                    var ip_buf: [c.INET_ADDRSTRLEN]u8 = undefined;
                    if (c.inet_ntop(c.AF_INET, &sa_in.sin_addr, &ip_buf, c.INET_ADDRSTRLEN)) |ip_ptr| {
                        const ip_slice = std.mem.sliceTo(ip_ptr, 0);
                        const copy_len = @min(ip_slice.len, model.IP_ADDR_LEN);
                        @memcpy(metrics.net.ipv4_addr[0..copy_len], ip_slice[0..copy_len]);
                        metrics.net.ipv4_addr_len = @intCast(copy_len);
                        break;
                    }
                }
                ifa = iface.ifa_next;
            }

            c.freeifaddrs(ifap);
        }
    }

    // Disk IO via IOKit IOBlockStorageDriver
    metrics.disk = collectDiskIO();

    return metrics;
}

fn cfDictGetI64(dict: c.CFDictionaryRef, key: c.CFStringRef) u64 {
    var value: i64 = 0;
    const cf_val = c.CFDictionaryGetValue(dict, @ptrCast(key));
    if (cf_val != null) {
        const cf_num: c.CFNumberRef = @ptrCast(@constCast(cf_val));
        _ = c.CFNumberGetValue(cf_num, c.kCFNumberSInt64Type, @ptrCast(&value));
    }
    return if (value > 0) @intCast(value) else 0;
}

fn collectDiskIO() model.DiskIO {
    var result = model.DiskIO{};
    const matching = c.IOServiceMatching("IOBlockStorageDriver");
    if (matching == null) return result;

    var iterator: c.io_iterator_t = 0;
    const kr = c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iterator);
    if (kr != c.KERN_SUCCESS) return result;
    defer _ = c.IOObjectRelease(iterator);

    while (true) {
        const service = c.IOIteratorNext(iterator);
        if (service == 0) break;
        defer _ = c.IOObjectRelease(service);

        var props: c.CFMutableDictionaryRef = null;
        if (c.IORegistryEntryCreateCFProperties(service, &props, c.kCFAllocatorDefault, 0) != c.KERN_SUCCESS) continue;
        defer c.CFRelease(@ptrCast(props));

        const stats_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "Statistics", c.kCFStringEncodingUTF8);
        if (stats_key == null) continue;
        defer c.CFRelease(@ptrCast(stats_key));

        const stats_val = c.CFDictionaryGetValue(@ptrCast(props), @ptrCast(stats_key));
        if (stats_val == null) continue;
        const stats_dict: c.CFDictionaryRef = @ptrCast(@constCast(stats_val));

        const read_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "Bytes (Read)", c.kCFStringEncodingUTF8);
        const write_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "Bytes (Write)", c.kCFStringEncodingUTF8);
        defer {
            if (read_key != null) c.CFRelease(@ptrCast(read_key));
            if (write_key != null) c.CFRelease(@ptrCast(write_key));
        }

        if (read_key != null) result.bytes_read += cfDictGetI64(stats_dict, read_key);
        if (write_key != null) result.bytes_written += cfDictGetI64(stats_dict, write_key);
    }

    return result;
}

pub fn collectMountInfo() model.MountSnapshot {
    var snap = model.MountSnapshot{};

    // First call: get count of mounted filesystems
    const count = c.getfsstat(null, 0, c.MNT_NOWAIT);
    if (count <= 0) return snap;

    // Stack buffer for up to 64 mounts; if more, we just truncate
    const MAX_FS = 64;
    var fs_buf: [MAX_FS]c.struct_statfs = undefined;
    const fs_count: usize = @min(@as(usize, @intCast(count)), MAX_FS);
    const buf_size: c_int = @intCast(fs_count * @sizeOf(c.struct_statfs));
    const actual = c.getfsstat(&fs_buf, buf_size, c.MNT_NOWAIT);
    if (actual <= 0) return snap;

    const n: usize = @intCast(actual);
    for (fs_buf[0..n]) |*fs| {
        if (snap.mount_count >= model.MAX_MOUNTS) break;

        // Filter out pseudo-filesystems (f_blocks == 0)
        if (fs.f_blocks == 0) continue;

        const block_size: u64 = @intCast(fs.f_bsize);
        const total = fs.f_blocks * block_size;
        const avail = fs.f_bavail * block_size;
        const free_blocks = fs.f_bfree * block_size;
        const used = total -| free_blocks;

        // Extract mount point name: last path component, or "/" for root
        const mount_on = std.mem.sliceTo(&fs.f_mntonname, 0);
        const display_name = blk: {
            if (mount_on.len == 1 and mount_on[0] == '/') break :blk "/";
            // Find last '/'
            var last_slash: usize = 0;
            for (mount_on, 0..) |ch, i| {
                if (ch == '/') last_slash = i;
            }
            if (last_slash + 1 < mount_on.len) {
                break :blk mount_on[last_slash + 1 ..];
            }
            break :blk mount_on;
        };

        var mount = model.MountInfo{
            .total_bytes = total,
            .used_bytes = used,
            .available_bytes = avail,
        };

        const copy_len = @min(display_name.len, model.MOUNT_NAME_LEN);
        @memcpy(mount.name[0..copy_len], display_name[0..copy_len]);
        mount.name_len = @intCast(copy_len);

        snap.mounts[snap.mount_count] = mount;
        snap.mount_count += 1;
    }

    return snap;
}

pub fn collectProcessDetail(pid: pid_t, arena: std.mem.Allocator) PlatformError!model.ProcessDetail {
    // PROC_PIDTASKALLINFO = bsd + task in one syscall
    // SAFETY: proc_pidinfo(PROC_PIDTASKALLINFO) fully initializes this struct;
    var task_all: c.proc_taskallinfo = undefined;
    const task_size = c.proc_pidinfo(
        pid,
        c.PROC_PIDTASKALLINFO,
        0,
        &task_all,
        @sizeOf(c.proc_taskallinfo),
    );
    if (task_size <= 0) return error.ProcessNotFound;

    const bsd = task_all.pbsd;
    const task = task_all.ptinfo;

    // Name
    const c_name = std.mem.sliceTo(&bsd.pbi_name, 0);
    const name = arena.dupe(u8, c_name) catch return error.OutOfMemory;

    // Path
    var path_buf: [4096]u8 = undefined;
    const path_len = c.proc_pidpath(pid, &path_buf, path_buf.len);
    const path = if (path_len > 0)
        arena.dupe(u8, path_buf[0..@intCast(path_len)]) catch return error.OutOfMemory
    else
        arena.dupe(u8, "[path unavailable]") catch return error.OutOfMemory;

    // Cmdline + environ via KERN_PROCARGS2
    // Buffer format: [argc:u32][exec_path\0][padding\0s][arg0\0]...[argN\0][env0\0]...[envM\0]
    const ArgsResult = struct { cmdline: []const u8, environ: []const []const u8 };
    const unavail = "[unavailable]";
    const parsed_args = blk: {
        var mib = [4]c_int{ c.CTL_KERN, c.KERN_PROCARGS2, pid, 0 };
        var arg_size: usize = 0;
        if (std.c.sysctl(&mib, 3, null, &arg_size, null, 0) != 0) {
            break :blk ArgsResult{
                .cmdline = arena.dupe(u8, unavail) catch return error.OutOfMemory,
                .environ = &.{},
            };
        }
        const arg_buf = arena.alloc(u8, arg_size) catch break :blk ArgsResult{
            .cmdline = arena.dupe(u8, unavail) catch return error.OutOfMemory,
            .environ = &.{},
        };
        if (std.c.sysctl(&mib, 3, arg_buf.ptr, &arg_size, null, 0) != 0) {
            break :blk ArgsResult{
                .cmdline = arena.dupe(u8, unavail) catch return error.OutOfMemory,
                .environ = &.{},
            };
        }
        if (arg_size <= 4) break :blk ArgsResult{
            .cmdline = arena.dupe(u8, unavail) catch return error.OutOfMemory,
            .environ = &.{},
        };

        // Read argc from first 4 bytes
        const argc: u32 = @bitCast(arg_buf[0..4].*);
        var pos: usize = 4;

        // Skip exec path (null-terminated)
        while (pos < arg_size and arg_buf[pos] != 0) pos += 1;
        // Skip padding nulls
        while (pos < arg_size and arg_buf[pos] == 0) pos += 1;

        // Parse argc arguments → cmdline (join with spaces)
        const args_start = pos;
        var args_count: u32 = 0;
        while (pos < arg_size and args_count < argc) {
            if (arg_buf[pos] == 0) args_count += 1;
            pos += 1;
        }
        const args_data = arg_buf[args_start..pos];
        const display = arena.alloc(u8, args_data.len) catch break :blk ArgsResult{
            .cmdline = arena.dupe(u8, unavail) catch return error.OutOfMemory,
            .environ = &.{},
        };
        for (args_data, 0..) |byte, i| {
            display[i] = if (byte == 0) ' ' else byte;
        }
        var end: usize = display.len;
        while (end > 0 and display[end - 1] == ' ') end -= 1;
        const cmdline_str = display[0..end];

        // Parse remaining null-terminated strings → environ
        // Reserve-first: count env vars, allocate once, then fill
        while (pos < arg_size and arg_buf[pos] == 0) pos += 1;

        var env_count: usize = 0;
        var scan = pos;
        while (scan < arg_size) {
            const start = scan;
            while (scan < arg_size and arg_buf[scan] != 0) scan += 1;
            if (scan > start) env_count += 1;
            if (scan < arg_size) scan += 1;
        }

        const env_slices = arena.alloc([]const u8, env_count) catch break :blk ArgsResult{
            .cmdline = cmdline_str, .environ = &.{},
        };
        var env_idx: usize = 0;
        while (pos < arg_size and env_idx < env_count) {
            const start = pos;
            while (pos < arg_size and arg_buf[pos] != 0) pos += 1;
            if (pos > start) {
                env_slices[env_idx] = arena.dupe(u8, arg_buf[start..pos]) catch break;
                env_idx += 1;
            }
            if (pos < arg_size) pos += 1;
        }

        break :blk ArgsResult{ .cmdline = cmdline_str, .environ = env_slices };
    };
    const cmdline = parsed_args.cmdline;
    const environ = parsed_args.environ;

    // CWD via PROC_PIDVNODEPATHINFO
    const cwd = blk: {
        // SAFETY: proc_pidinfo(PROC_PIDVNODEPATHINFO) fully initializes this struct;
        var vnode_info: c.proc_vnodepathinfo = undefined;
        const vn_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDVNODEPATHINFO,
            0,
            &vnode_info,
            @sizeOf(c.proc_vnodepathinfo),
        );
        if (vn_size > 0) {
            const cwd_path = std.mem.sliceTo(&vnode_info.pvi_cdir.vip_path, 0);
            break :blk arena.dupe(u8, cwd_path) catch return error.OutOfMemory;
        }
        break :blk arena.dupe(u8, "[unavailable]") catch return error.OutOfMemory;
    };

    // FD count via PROC_PIDLISTFDS
    const fd_count: u32 = blk: {
        const fd_bytes = c.proc_pidinfo(pid, c.PROC_PIDLISTFDS, 0, null, 0);
        if (fd_bytes > 0) {
            break :blk @intCast(@divExact(
                @as(u32, @intCast(fd_bytes)),
                @sizeOf(c.proc_fdinfo),
            ));
        }
        break :blk 0;
    };

    // User name from UID
    const uid: u32 = bsd.pbi_uid;
    const user_name = blk: {
        const pw = c.getpwuid(uid);
        if (pw) |pwd| {
            const name_slice = std.mem.sliceTo(pwd.*.pw_name, 0);
            break :blk arena.dupe(u8, name_slice) catch return error.OutOfMemory;
        }
        break :blk arena.dupe(u8, "[unknown]") catch return error.OutOfMemory;
    };

    // Process state
    const proc_state: model.ProcState = switch (bsd.pbi_status) {
        2 => .running,
        1 => .sleeping,
        3 => .stopped,
        4 => .zombie,
        else => .unkown,
    };

    const start_sec: i128 = @intCast(bsd.pbi_start_tvsec);
    const start_usec: i128 = @intCast(bsd.pbi_start_tvusec);

    return .{
        .pid = pid,
        .ppid = @intCast(bsd.pbi_ppid),
        .name = name,
        .path = path,
        .cmdline = cmdline,
        .cwd = cwd,
        .user_name = user_name,
        .uid = uid,
        .state = proc_state,
        .thread_count = @intCast(task.pti_threadnum),
        .nice = @intCast(bsd.pbi_nice),
        .virtual_mem = task.pti_virtual_size,
        .fd_count = fd_count,
        .start_time_ns = start_sec * std.time.ns_per_s + start_usec * std.time.ns_per_us,
        .environ = environ,
    };
}
