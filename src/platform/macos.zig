const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/resource.h");
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
    @cInclude("netinet/tcp_fsm.h");
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

            const name = arena.dupe(u8, c_name) catch return error.OutOfMemory;
            const path_str = if (path_len > 0)
                arena.dupe(u8, path_buf[0..@as(usize, @intCast(path_len))]) catch return error.OutOfMemory
            else blk: {
                const e = std.posix.errno(0);
                if (e == .SRCH) continue; // process exited between listing and path lookup
                const err_label: []const u8 = switch (e) {
                    .PERM => "[permission denied]",
                    .NOENT => "[binary deleted]",
                    else => "[path unavailable]",
                };
                break :blk arena.dupe(u8, err_label) catch return error.OutOfMemory;
            };

            const proc = Proc{
                .pid = pid,
                .ppid = @intCast(proc_info.pbi_ppid),
                .pgid = @intCast(proc_info.pbi_pgid),
                .start_time_ns = start_time_ns,
                .name = name,
                .path = path_str,
                .mem_rss = if (task_size > 0) task_info.pti_resident_size else 0,
                .total_user = if (task_size > 0) task_info.pti_total_user else 0,
                .total_system = if (task_size > 0) task_info.pti_total_system else 0,
                .nice = @intCast(proc_info.pbi_nice),
            };
            proc_map.putAssumeCapacity(pid, proc);
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

pub fn renice(pid: pid_t, delta: i32) PlatformError!i32 {
    // Get current priority first
    const PRIO_PROCESS = 0;
    const current = c.getpriority(PRIO_PROCESS, @intCast(pid));
    const get_errno = std.posix.errno(0);
    // getpriority can return -1 legitimately, so check errno
    if (current == -1 and get_errno != .SUCCESS) {
        return switch (get_errno) {
            .PERM => PlatformError.PermissionDenied,
            .SRCH => PlatformError.ProcessNotFound,
            else => PlatformError.Unexpected,
        };
    }

    // Calculate new priority (clamped to -20..20)
    var new_nice = current + delta;
    if (new_nice < -20) new_nice = -20;
    if (new_nice > 20) new_nice = 20;

    // Set new priority
    const result = c.setpriority(PRIO_PROCESS, @intCast(pid), new_nice);
    const e = std.posix.errno(result);
    if (e != .SUCCESS) {
        return switch (e) {
            .PERM, .ACCES => PlatformError.PermissionDenied,
            .SRCH => PlatformError.ProcessNotFound,
            else => PlatformError.Unexpected,
        };
    }

    return new_nice;
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

// SMC structures for temperature reading
const SMCKeyData = extern struct {
    key: u32 = 0,
    vers: [6]u8 = [_]u8{0} ** 6,
    pLimitData: [16]u8 = [_]u8{0} ** 16,
    keyInfo: KeyInfo = .{},
    result: u8 = 0,
    status: u8 = 0,
    data8: u8 = 0,
    data32: u32 = 0,
    bytes: [32]u8 = [_]u8{0} ** 32,
};

const KeyInfo = extern struct {
    dataSize: u32 = 0,
    dataType: u32 = 0,
    dataAttributes: u8 = 0,
};

const SMC_CMD_READ_KEYINFO: u8 = 9;
const SMC_CMD_READ_BYTES: u8 = 5;

fn fourCharCode(s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

/// Read CPU temperature from SMC. Returns 0 if unavailable.
const CpuTempResult = struct {
    average: f32 = 0,
    cluster_temps: [12]f32 = [_]f32{0} ** 12,
    cluster_count: u8 = 0,
};

fn readSmcCpuTemps() CpuTempResult {
    var result = CpuTempResult{};

    // Open connection to AppleSMC
    const matching = c.IOServiceMatching("AppleSMC");
    if (matching == null) return result;

    const service = c.IOServiceGetMatchingService(c.kIOMainPortDefault, matching);
    if (service == 0) return result;
    defer _ = c.IOObjectRelease(service);

    var conn: c.io_connect_t = 0;
    if (c.IOServiceOpen(service, c.mach_task_self(), 0, &conn) != c.KERN_SUCCESS) return result;
    defer _ = c.IOServiceClose(conn);

    // Apple Silicon thermal sensors - comprehensive list
    // Tp0C = Die/Package, Tp01/05/09/0D/0H/0L/0P/0X/0b = various thermal zones
    const apple_keys = [_]*const [4]u8{
        "Tp0C", // Package/Die
        "Tp09", // Cluster
        "Tp01", // Cluster
        "Tp05", // Cluster
        "Tp0D", // Additional thermal zone
        "Tp0H", // Additional thermal zone
        "Tp0L", // Additional thermal zone
        "Tp0P", // Additional thermal zone
        "Tp0X", // Additional thermal zone
        "Tp0b", // Additional thermal zone
        "Tp0j", // Additional thermal zone
        "Tp0n", // Additional thermal zone
    };
    for (apple_keys) |key| {
        const temp = readSmcKey(conn, key);
        if (temp > 0 and temp < 150) {
            if (result.cluster_count < 12) {
                result.cluster_temps[result.cluster_count] = temp;
                result.cluster_count += 1;
            }
        }
    }

    // Use first cluster temp as average, or try Intel keys
    if (result.cluster_count > 0) {
        result.average = result.cluster_temps[0];
    } else {
        // Intel keys as fallback (per-core temps: TC0C-TC7C for up to 8 cores)
        const intel_keys = [_]*const [4]u8{
            "TC0C", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C", // Per-core
            "TC0P", "TC0D", "TC0E", "TC0F", // Package fallbacks
        };
        for (intel_keys) |key| {
            const temp = readSmcKey(conn, key);
            if (temp > 0 and temp < 150) {
                if (result.cluster_count < 12) {
                    result.cluster_temps[result.cluster_count] = temp;
                    result.cluster_count += 1;
                }
            }
        }
        if (result.cluster_count > 0) {
            result.average = result.cluster_temps[0];
        }
    }

    return result;
}

/// Derive max P-core frequency from Apple Silicon brand string.
/// Returns frequency in MHz, or 0 if not recognized.
fn appleChipFrequency(brand: []const u8) u32 {
    // Check for Apple Silicon chips and return known max P-core frequencies
    if (std.mem.indexOf(u8, brand, "Apple M4")) |_| {
        return 4400; // M4/M4 Pro/M4 Max: 4.4 GHz
    }
    if (std.mem.indexOf(u8, brand, "Apple M3")) |_| {
        return 4050; // M3/M3 Pro/M3 Max: ~4.05 GHz
    }
    if (std.mem.indexOf(u8, brand, "Apple M2")) |_| {
        return 3500; // M2/M2 Pro/M2 Max/M2 Ultra: 3.5 GHz
    }
    if (std.mem.indexOf(u8, brand, "Apple M1")) |_| {
        return 3200; // M1/M1 Pro/M1 Max/M1 Ultra: 3.2 GHz
    }
    return 0;
}

fn readSmcKey(conn: c.io_connect_t, key: *const [4]u8) f32 {
    var input = SMCKeyData{};
    var output = SMCKeyData{};
    var output_size: usize = @sizeOf(SMCKeyData);

    // First get key info
    input.key = fourCharCode(key);
    input.data8 = SMC_CMD_READ_KEYINFO;

    if (c.IOConnectCallStructMethod(
        conn,
        2, // kSMCHandleYPCEvent
        &input,
        @sizeOf(SMCKeyData),
        &output,
        &output_size,
    ) != c.KERN_SUCCESS) return 0;

    // Check for error result (132 = key not found)
    if (output.result != 0) return 0;

    const data_size = output.keyInfo.dataSize;
    const data_type = output.keyInfo.dataType;
    if (data_size == 0) return 0;

    // Now read the value
    input.keyInfo = output.keyInfo;
    input.data8 = SMC_CMD_READ_BYTES;
    output = SMCKeyData{};
    output_size = @sizeOf(SMCKeyData);

    if (c.IOConnectCallStructMethod(
        conn,
        2,
        &input,
        @sizeOf(SMCKeyData),
        &output,
        &output_size,
    ) != c.KERN_SUCCESS) return 0;

    // Parse based on data type
    // "flt " (0x666c7420) = 32-bit float (Apple Silicon)
    // "sp78" (0x73703738) = signed 7.8 fixed point (Intel)
    const FLT_TYPE: u32 = 0x666c7420; // "flt "
    const SP78_TYPE: u32 = 0x73703738; // "sp78"

    if (data_type == FLT_TYPE and data_size >= 4) {
        // Apple Silicon: 32-bit float
        const bytes = output.bytes[0..4];
        return @bitCast(bytes.*);
    } else if (data_type == SP78_TYPE and data_size >= 2) {
        // Intel: signed 7.8 fixed point
        const int_part: f32 = @floatFromInt(@as(i8, @bitCast(output.bytes[0])));
        const frac_part: f32 = @as(f32, @floatFromInt(output.bytes[1])) / 256.0;
        return int_part + frac_part;
    } else if (data_size >= 2) {
        // Fallback: try sp78 interpretation
        const int_part: f32 = @floatFromInt(@as(i8, @bitCast(output.bytes[0])));
        const frac_part: f32 = @as(f32, @floatFromInt(output.bytes[1])) / 256.0;
        return int_part + frac_part;
    }

    return 0;
}

pub fn collectSystemMetrics() model.SystemMetrics {
    var metrics = model.SystemMetrics{};
    metrics.timestamp_ns = std.time.nanoTimestamp();

    // CPU brand string via sysctl machdep.cpu.brand_string
    {
        var brand_buf: [64]u8 = [_]u8{0} ** 64;
        var brand_len: usize = brand_buf.len;
        // sysctlbyname for "machdep.cpu.brand_string"
        const name = "machdep.cpu.brand_string";
        const rc = std.c.sysctlbyname(name, &brand_buf, &brand_len, null, 0);
        if (rc == 0 and brand_len > 0) {
            // Remove trailing null if present
            const actual_len = if (brand_len > 0 and brand_buf[brand_len - 1] == 0)
                brand_len - 1
            else
                brand_len;
            const copy_len = @min(actual_len, metrics.cpu_brand.len);
            @memcpy(metrics.cpu_brand[0..copy_len], brand_buf[0..copy_len]);
            metrics.cpu_brand_len = @intCast(copy_len);
        }
    }

    // CPU frequency via sysctl hw.cpufrequency (Intel) or hw.cpufrequency_max
    {
        var freq: u64 = 0;
        var freq_size: usize = @sizeOf(u64);
        // Try hw.cpufrequency first (Intel)
        var rc = std.c.sysctlbyname("hw.cpufrequency", @ptrCast(&freq), &freq_size, null, 0);
        if (rc != 0) {
            // Try hw.cpufrequency_max as fallback
            rc = std.c.sysctlbyname("hw.cpufrequency_max", @ptrCast(&freq), &freq_size, null, 0);
        }
        if (rc == 0 and freq > 0) {
            metrics.cpu_freq_mhz = @intCast(freq / 1_000_000);
        } else {
            // Apple Silicon: derive frequency from brand string
            metrics.cpu_freq_mhz = appleChipFrequency(metrics.cpu_brand[0..metrics.cpu_brand_len]);
        }
    }

    // CPU temperature via IOKit SMC (AppleSMC)
    const temps = readSmcCpuTemps();
    metrics.cpu_temp_celsius = temps.average;
    metrics.cpu_cluster_temps = temps.cluster_temps;
    metrics.cpu_cluster_temp_count = temps.cluster_count;

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

pub fn collectThreads(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError![]model.ThreadInfo {
    // Get task port for the process
    var task_port: c.mach_port_t = 0;
    const kr = c.task_for_pid(c.mach_task_self(), pid, &task_port);
    if (kr != c.KERN_SUCCESS) {
        // Permission denied or process not found - return empty list
        return arena.alloc(model.ThreadInfo, 0) catch return error.OutOfMemory;
    }
    defer _ = c.mach_port_deallocate(c.mach_task_self(), task_port);

    // Get thread list
    var thread_list: c.thread_act_array_t = undefined;
    var thread_count: c.mach_msg_type_number_t = 0;
    const threads_kr = c.task_threads(task_port, &thread_list, &thread_count);
    if (threads_kr != c.KERN_SUCCESS) {
        return arena.alloc(model.ThreadInfo, 0) catch return error.OutOfMemory;
    }
    defer {
        // Deallocate thread ports
        for (thread_list[0..thread_count]) |thread| {
            _ = c.mach_port_deallocate(c.mach_task_self(), thread);
        }
        // Deallocate the thread list memory
        _ = c.vm_deallocate(c.mach_task_self(), @intFromPtr(thread_list), thread_count * @sizeOf(c.thread_act_t));
    }

    var threads = arena.alloc(model.ThreadInfo, thread_count) catch return error.OutOfMemory;
    var valid_count: usize = 0;

    for (thread_list[0..thread_count]) |thread| {
        var basic_info: c.thread_basic_info_data_t = undefined;
        var info_count: c.mach_msg_type_number_t = c.THREAD_BASIC_INFO_COUNT;

        const info_kr = c.thread_info(
            thread,
            c.THREAD_BASIC_INFO,
            @ptrCast(&basic_info),
            &info_count,
        );

        if (info_kr == c.KERN_SUCCESS) {
            const state: model.ThreadState = switch (basic_info.run_state) {
                c.TH_STATE_RUNNING => .running,
                c.TH_STATE_STOPPED => .stopped,
                c.TH_STATE_WAITING => .waiting,
                c.TH_STATE_HALTED => .halted,
                else => .unknown,
            };

            // Calculate CPU percentage from user+system time
            const user_time_us: u64 = @as(u64, @intCast(basic_info.user_time.seconds)) * 1_000_000 +
                @as(u64, @intCast(basic_info.user_time.microseconds));
            const system_time_us: u64 = @as(u64, @intCast(basic_info.system_time.seconds)) * 1_000_000 +
                @as(u64, @intCast(basic_info.system_time.microseconds));

            // cpu_usage is in TH_USAGE_SCALE (1000 = 100%)
            const cpu_percent: f32 = @as(f32, @floatFromInt(basic_info.cpu_usage)) / 10.0;

            threads[valid_count] = .{
                .tid = @intCast(thread),
                .cpu_percent = cpu_percent,
                .user_time_us = user_time_us,
                .system_time_us = system_time_us,
                .state = state,
                .name = "", // Thread names require additional API calls
            };
            valid_count += 1;
        }
    }

    return threads[0..valid_count];
}

pub fn collectOpenFiles(pid: std.posix.pid_t, arena: std.mem.Allocator) PlatformError![]model.OpenFile {
    // Get the number of file descriptors
    const buf_size = c.proc_pidinfo(pid, c.PROC_PIDLISTFDS, 0, null, 0);
    if (buf_size <= 0) {
        return arena.alloc(model.OpenFile, 0) catch return error.OutOfMemory;
    }

    const fd_count: usize = @intCast(@divExact(buf_size, @sizeOf(c.proc_fdinfo)));
    var fd_buffer = arena.alloc(c.proc_fdinfo, fd_count) catch return error.OutOfMemory;

    const actual_size = c.proc_pidinfo(
        pid,
        c.PROC_PIDLISTFDS,
        0,
        fd_buffer.ptr,
        buf_size,
    );

    if (actual_size <= 0) {
        return arena.alloc(model.OpenFile, 0) catch return error.OutOfMemory;
    }

    const actual_count: usize = @intCast(@divExact(actual_size, @sizeOf(c.proc_fdinfo)));
    var files = arena.alloc(model.OpenFile, actual_count) catch return error.OutOfMemory;
    var valid_count: usize = 0;

    for (fd_buffer[0..actual_count]) |fd_info| {
        var path: []const u8 = "";
        var fd_type: model.FdType = .other;
        var local_addr: []const u8 = "";
        var remote_addr: []const u8 = "";
        var tcp_state: model.TcpState = .unknown;

        switch (fd_info.proc_fdtype) {
            c.PROX_FDTYPE_VNODE => {
                // Regular file
                var vnode_info: c.vnode_fdinfowithpath = undefined;
                const vn_size = c.proc_pidfdinfo(
                    pid,
                    fd_info.proc_fd,
                    c.PROC_PIDFDVNODEPATHINFO,
                    &vnode_info,
                    @sizeOf(c.vnode_fdinfowithpath),
                );
                if (vn_size > 0) {
                    const path_slice = std.mem.sliceTo(&vnode_info.pvip.vip_path, 0);
                    path = arena.dupe(u8, path_slice) catch "";
                    fd_type = .file;
                }
            },
            c.PROX_FDTYPE_SOCKET => {
                // Socket
                var socket_info: c.socket_fdinfo = undefined;
                const sock_size = c.proc_pidfdinfo(
                    pid,
                    fd_info.proc_fd,
                    c.PROC_PIDFDSOCKETINFO,
                    &socket_info,
                    @sizeOf(c.socket_fdinfo),
                );
                if (sock_size > 0) {
                    const family = socket_info.psi.soi_family;
                    const sock_type = socket_info.psi.soi_type;

                    if (family == c.AF_INET or family == c.AF_INET6) {
                        if (sock_type == c.SOCK_STREAM) {
                            fd_type = .socket_tcp;
                            // Extract TCP state
                            const raw_state = socket_info.psi.soi_proto.pri_tcp.tcpsi_state;
                            tcp_state = switch (raw_state) {
                                c.TCPS_CLOSED => .closed,
                                c.TCPS_LISTEN => .listen,
                                c.TCPS_SYN_SENT => .syn_sent,
                                c.TCPS_SYN_RECEIVED => .syn_received,
                                c.TCPS_ESTABLISHED => .established,
                                c.TCPS_CLOSE_WAIT => .close_wait,
                                c.TCPS_FIN_WAIT_1 => .fin_wait_1,
                                c.TCPS_CLOSING => .closing,
                                c.TCPS_LAST_ACK => .last_ack,
                                c.TCPS_FIN_WAIT_2 => .fin_wait_2,
                                c.TCPS_TIME_WAIT => .time_wait,
                                else => .unknown,
                            };
                        } else if (sock_type == c.SOCK_DGRAM) {
                            fd_type = .socket_udp;
                        }

                        // Format addresses
                        if (family == c.AF_INET) {
                            const inp = &socket_info.psi.soi_proto.pri_tcp.tcpsi_ini;
                            var local_buf: [64]u8 = undefined;
                            var remote_buf: [64]u8 = undefined;

                            const local_str = std.fmt.bufPrint(&local_buf, "{d}.{d}.{d}.{d}:{d}", .{
                                (inp.insi_laddr.ina_46.i46a_addr4.s_addr >> 0) & 0xFF,
                                (inp.insi_laddr.ina_46.i46a_addr4.s_addr >> 8) & 0xFF,
                                (inp.insi_laddr.ina_46.i46a_addr4.s_addr >> 16) & 0xFF,
                                (inp.insi_laddr.ina_46.i46a_addr4.s_addr >> 24) & 0xFF,
                                @byteSwap(inp.insi_lport),
                            }) catch "";
                            local_addr = arena.dupe(u8, local_str) catch "";

                            const remote_str = std.fmt.bufPrint(&remote_buf, "{d}.{d}.{d}.{d}:{d}", .{
                                (inp.insi_faddr.ina_46.i46a_addr4.s_addr >> 0) & 0xFF,
                                (inp.insi_faddr.ina_46.i46a_addr4.s_addr >> 8) & 0xFF,
                                (inp.insi_faddr.ina_46.i46a_addr4.s_addr >> 16) & 0xFF,
                                (inp.insi_faddr.ina_46.i46a_addr4.s_addr >> 24) & 0xFF,
                                @byteSwap(inp.insi_fport),
                            }) catch "";
                            remote_addr = arena.dupe(u8, remote_str) catch "";
                        }
                    } else if (family == c.AF_UNIX) {
                        fd_type = .socket_unix;
                        // Unix socket path
                        const unp = &socket_info.psi.soi_proto.pri_un;
                        const path_slice = std.mem.sliceTo(&unp.unsi_addr.ua_sun.sun_path, 0);
                        if (path_slice.len > 0) {
                            path = arena.dupe(u8, path_slice) catch "";
                        }
                    }
                }
            },
            c.PROX_FDTYPE_PIPE => {
                fd_type = .pipe;
                path = arena.dupe(u8, "(pipe)") catch "";
            },
            c.PROX_FDTYPE_KQUEUE => {
                fd_type = .kqueue;
                path = arena.dupe(u8, "(kqueue)") catch "";
            },
            else => {
                fd_type = .other;
            },
        }

        files[valid_count] = .{
            .fd = fd_info.proc_fd,
            .fd_type = fd_type,
            .path = path,
            .local_addr = local_addr,
            .remote_addr = remote_addr,
            .tcp_state = tcp_state,
        };
        valid_count += 1;
    }

    return files[0..valid_count];
}

/// Socket counts by type
pub const SocketCounts = struct {
    tcp: u32 = 0,
    udp: u32 = 0,
    unix: u32 = 0,

    pub fn total(self: SocketCounts) u32 {
        return self.tcp + self.udp + self.unix;
    }
};

/// Count sockets by type (TCP, UDP, Unix) for a process
pub fn countSocketsByType(pid: std.posix.pid_t) SocketCounts {
    var counts = SocketCounts{};

    const buf_size = c.proc_pidinfo(pid, c.PROC_PIDLISTFDS, 0, null, 0);
    if (buf_size <= 0) return counts;

    const fd_count: usize = @intCast(@divExact(buf_size, @sizeOf(c.proc_fdinfo)));
    if (fd_count == 0) return counts;

    // Use stack buffer for small counts, otherwise skip detailed counting
    var stack_buf: [256]c.proc_fdinfo = undefined;
    const fd_buffer: []c.proc_fdinfo = if (fd_count <= stack_buf.len)
        stack_buf[0..fd_count]
    else
        return counts; // Too many FDs, skip to avoid allocation

    const actual_size = c.proc_pidinfo(
        pid,
        c.PROC_PIDLISTFDS,
        0,
        fd_buffer.ptr,
        @intCast(fd_count * @sizeOf(c.proc_fdinfo)),
    );

    if (actual_size <= 0) return counts;

    const actual_count: usize = @intCast(@divExact(actual_size, @sizeOf(c.proc_fdinfo)));

    for (fd_buffer[0..actual_count]) |fd_info| {
        if (fd_info.proc_fdtype != c.PROX_FDTYPE_SOCKET) continue;

        // Get socket info to determine family
        var socket_info: c.socket_fdinfo = undefined;
        const sock_size = c.proc_pidfdinfo(
            pid,
            fd_info.proc_fd,
            c.PROC_PIDFDSOCKETINFO,
            &socket_info,
            @sizeOf(c.socket_fdinfo),
        );

        if (sock_size <= 0) continue;

        const family = socket_info.psi.soi_family;
        if (family == c.AF_INET or family == c.AF_INET6) {
            const proto = socket_info.psi.soi_protocol;
            if (proto == c.IPPROTO_TCP) {
                counts.tcp += 1;
            } else if (proto == c.IPPROTO_UDP) {
                counts.udp += 1;
            }
        } else if (family == c.AF_UNIX) {
            counts.unix += 1;
        }
    }

    return counts;
}

/// Fast socket count - counts all sockets without type distinction
pub fn countSockets(pid: std.posix.pid_t) u32 {
    return countSocketsByType(pid).total();
}

// ═══════════════════════════════════════════════════════════════════════════
// System-wide TCP connection collector via sysctl
// This bypasses per-process permission restrictions by reading kernel tables
// ═══════════════════════════════════════════════════════════════════════════

/// Kernel structure for TCP PCB list header/footer
const xinpgen = extern struct {
    xig_len: u32,
    xig_count: u32,
    xig_gen: u64,
    xig_sogen: u64,
};

/// Socket info subset - we only need the PID
const xsocket_n = extern struct {
    xso_len: u32,
    xso_kind: u32,
    xso_so: u64,
    xso_pcb: u64,
    xso_type: i16,
    xso_options: i16,
    xso_linger: i16,
    xso_state: i16,
    xso_qlen: u16,
    xso_incqlen: u16,
    xso_qlimit: u16,
    xso_timeo: i16,
    xso_error: u16,
    xso_pgid: i32,
    xso_oobmark: u32,
    xso_uid: u32,
    xso_e_pid: i32, // Effective PID - this is what we need!
    xso_last_pid: i32,
    // More fields follow but we don't need them
};

/// Input PCB - contains addresses and ports
const xinpcb_n = extern struct {
    xi_len: u32,
    xi_kind: u32,
    xi_inpp: u64,
    inp_fport: u16, // Foreign port (network byte order)
    inp_lport: u16, // Local port (network byte order)
    inp_ppcb: u64,
    inp_gencnt: u64,
    inp_flags: i32,
    inp_flow: u32,
    inp_vflag: u8,
    inp_ip_ttl: u8,
    inp_ip_p: u8,
    inp_dependfaddr: [16]u8, // IPv6 foreign address or IPv4 in last 4 bytes
    inp_dependladdr: [16]u8, // IPv6 local address or IPv4 in last 4 bytes
    inp_depend4: extern struct {
        inp4_ip_tos: u8,
        pad: [3]u8,
    },
    inp_depend6: extern struct {
        inp6_hlim: u8,
        inp6_cksum: i8,
        inp6_ifindex: u16,
        inp6_hops: i16,
    },
    inp_flowhash: u32,
    inp_flags2: u32,
    xi_socket: xsocket_n,
};

/// TCP PCB - contains state and input PCB
const xtcpcb_n = extern struct {
    xt_len: u32,
    xt_kind: u32,
    t_segq: u64,
    t_dupacks: i32,
    t_timer: [4]i32,
    t_state: i32, // TCP state (TCPS_* values)
    t_flags: u32,
    t_force: i32,
    snd_una: u32,
    snd_max: u32,
    snd_nxt: u32,
    snd_up: u32,
    snd_wl1: u32,
    snd_wl2: u32,
    iss: u32,
    irs: u32,
    rcv_nxt: u32,
    rcv_adv: u32,
    rcv_wnd: u32,
    rcv_up: u32,
    snd_wnd: u32,
    snd_cwnd: u32,
    snd_ssthresh: u32,
    t_maxopd: u32,
    t_rcvtime: u32,
    t_starttime: u32,
    t_rtttime: i32,
    t_rtseq: u32,
    t_rxtcur: i32,
    t_maxseg: u32,
    t_srtt: i32,
    t_rttvar: i32,
    t_rxtshift: i32,
    t_rttmin: u32,
    t_rttupdated: u32,
    max_sndwnd: u32,
    t_softerror: i32,
    t_oobflags: u8,
    t_iobc: u8,
    snd_scale: u8,
    rcv_scale: u8,
    request_r_scale: u8,
    requested_s_scale: u8,
    ts_recent: u32,
    ts_recent_age: u32,
    last_ack_sent: u32,
    cc_send: u32,
    cc_recv: u32,
    snd_recover: u32,
    snd_cwnd_prev: u32,
    snd_ssthresh_prev: u32,
    t_badrxtwin: u32,
    xt_inpcb: xinpcb_n,
};

/// Collect all TCP connections system-wide using sysctl
/// Helper to create a TcpConnection with formatted addresses
fn makeConnection(pid: i32, local_port: u16, foreign_port: u16, local_addr: *const [16]u8, foreign_addr: *const [16]u8, is_ipv6: bool, tcp_state: i32) model.TcpConnection {
    var conn: model.TcpConnection = .{
        .pid = pid,
        .local_port = local_port,
        .remote_port = foreign_port,
        .local_addr = [_]u8{0} ** 46,
        .local_addr_len = 0,
        .remote_addr = [_]u8{0} ** 46,
        .remote_addr_len = 0,
        .state = model.TcpState.fromKernelState(tcp_state),
        .is_ipv6 = is_ipv6,
    };

    // Format addresses
    if (is_ipv6) {
        var local_buf: [c.INET6_ADDRSTRLEN]u8 = undefined;
        var remote_buf: [c.INET6_ADDRSTRLEN]u8 = undefined;

        const local_ptr = c.inet_ntop(c.AF_INET6, local_addr, &local_buf, c.INET6_ADDRSTRLEN);
        const remote_ptr = c.inet_ntop(c.AF_INET6, foreign_addr, &remote_buf, c.INET6_ADDRSTRLEN);

        if (local_ptr != null) {
            const local_str = std.mem.sliceTo(&local_buf, 0);
            const copy_len = @min(local_str.len, conn.local_addr.len);
            @memcpy(conn.local_addr[0..copy_len], local_str[0..copy_len]);
            conn.local_addr_len = @intCast(copy_len);
        }
        if (remote_ptr != null) {
            const remote_str = std.mem.sliceTo(&remote_buf, 0);
            const copy_len = @min(remote_str.len, conn.remote_addr.len);
            @memcpy(conn.remote_addr[0..copy_len], remote_str[0..copy_len]);
            conn.remote_addr_len = @intCast(copy_len);
        }
    } else {
        // IPv4 - last 4 bytes of the 16-byte address
        var local_buf: [c.INET_ADDRSTRLEN]u8 = undefined;
        var remote_buf: [c.INET_ADDRSTRLEN]u8 = undefined;

        const local_ptr = c.inet_ntop(c.AF_INET, local_addr[12..16], &local_buf, c.INET_ADDRSTRLEN);
        const remote_ptr = c.inet_ntop(c.AF_INET, foreign_addr[12..16], &remote_buf, c.INET_ADDRSTRLEN);

        if (local_ptr != null) {
            const local_str = std.mem.sliceTo(&local_buf, 0);
            const copy_len = @min(local_str.len, conn.local_addr.len);
            @memcpy(conn.local_addr[0..copy_len], local_str[0..copy_len]);
            conn.local_addr_len = @intCast(copy_len);
        }
        if (remote_ptr != null) {
            const remote_str = std.mem.sliceTo(&remote_buf, 0);
            const copy_len = @min(remote_str.len, conn.remote_addr.len);
            @memcpy(conn.remote_addr[0..copy_len], remote_str[0..copy_len]);
            conn.remote_addr_len = @intCast(copy_len);
        }
    }

    return conn;
}

pub fn collectTcpConnections(arena: std.mem.Allocator) PlatformError![]model.TcpConnection {
    // First call to get required buffer size
    var len: usize = 0;
    const name = "net.inet.tcp.pcblist_n";

    if (c.sysctlbyname(name, null, &len, null, 0) != 0) {
        return arena.alloc(model.TcpConnection, 0) catch return error.OutOfMemory;
    }

    if (len == 0) {
        return arena.alloc(model.TcpConnection, 0) catch return error.OutOfMemory;
    }

    // Allocate buffer
    const buf = arena.alloc(u8, len) catch return error.OutOfMemory;

    // Get the data
    if (c.sysctlbyname(name, buf.ptr, &len, null, 0) != 0) {
        return arena.alloc(model.TcpConnection, 0) catch return error.OutOfMemory;
    }

    var connections: std.ArrayListUnmanaged(model.TcpConnection) = .empty;

    // Header is xinpgen (24 bytes)
    if (len < 24) {
        return connections.toOwnedSlice(arena) catch return error.OutOfMemory;
    }

    const xig_len = std.mem.readInt(u32, buf[0..4], .little);
    var offset: usize = xig_len;

    // Entry kind values from XNU kernel
    const XSO_SOCKET: u32 = 0x001;
    const XSO_INPCB: u32 = 0x010;
    const XSO_TCPCB: u32 = 0x020;

    // Current connection being accumulated from multiple entries
    var have_inpcb = false;
    var local_port: u16 = 0;
    var foreign_port: u16 = 0;
    var local_addr: [16]u8 = undefined;
    var foreign_addr: [16]u8 = undefined;
    var is_ipv6: bool = false;
    var pid: i32 = 0;
    var tcp_state: i32 = 0;

    // Parse entries - each connection has multiple sub-entries (INPCB, SOCKET, TCPCB)
    while (offset + 8 <= len) {
        var xt_len = std.mem.readInt(u32, buf[offset..][0..4], .little);
        var xt_kind = std.mem.readInt(u32, buf[offset + 4 ..][0..4], .little);

        // Footer check
        if (xt_len == xig_len) {
            // Save last connection if pending
            if (have_inpcb and pid > 0) {
                const conn = makeConnection(pid, local_port, foreign_port, &local_addr, &foreign_addr, is_ipv6, tcp_state);
                connections.append(arena, conn) catch {};
            }
            break;
        }

        // Handle padding (xt_len=0) by scanning forward
        if (xt_len == 0) {
            var scan = offset;
            while (scan + 8 <= len) {
                scan += 4;
                const try_len = std.mem.readInt(u32, buf[scan..][0..4], .little);
                if (try_len >= 24 and try_len < 1024) {
                    const try_kind = std.mem.readInt(u32, buf[scan + 4 ..][0..4], .little);
                    if (try_kind >= 1 and try_kind <= 0x20) {
                        offset = scan;
                        xt_len = try_len;
                        xt_kind = try_kind;
                        break;
                    }
                }
            }
            if (xt_len == 0) break;
        }

        if (offset + xt_len > len) break;

        // INPCB (kind=16) - start of new connection, contains ports and addresses
        if (xt_kind == XSO_INPCB and xt_len >= 64) {
            // Save previous connection if any
            if (have_inpcb and pid > 0) {
                const conn = makeConnection(pid, local_port, foreign_port, &local_addr, &foreign_addr, is_ipv6, tcp_state);
                connections.append(arena, conn) catch {};
            }

            have_inpcb = true;
            pid = 0;
            tcp_state = 0;

            // Ports at offset 16/18 (network byte order - readInt handles conversion)
            foreign_port = std.mem.readInt(u16, buf[offset + 16 ..][0..2], .big);
            local_port = std.mem.readInt(u16, buf[offset + 18 ..][0..2], .big);

            // Addresses: foreign at offset 48, local at offset 64 (16 bytes each)
            @memcpy(&foreign_addr, buf[offset + 48 ..][0..16]);
            @memcpy(&local_addr, buf[offset + 64 ..][0..16]);

            // IPv6 flag at offset 44 (inp_vflag)
            const vflag = buf[offset + 44];
            is_ipv6 = (vflag & 0x2) != 0;
        }
        // SOCKET (kind=1) - contains UID at offset 64, PID at offset 68
        else if (xt_kind == XSO_SOCKET and xt_len >= 72) {
            pid = std.mem.readInt(i32, buf[offset + 68 ..][0..4], .little);
        }
        // TCPCB (kind=32) - contains state at offset 36
        else if (xt_kind == XSO_TCPCB and xt_len >= 40) {
            tcp_state = std.mem.readInt(i32, buf[offset + 36 ..][0..4], .little);
        }

        offset += xt_len;
    }

    return connections.toOwnedSlice(arena) catch return error.OutOfMemory;
}
