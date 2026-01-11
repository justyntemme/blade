const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigtui = b.dependency("zigtui", .{
        .target = target,
        .optimize = optimize,
    });
    const spsc = b.dependency("spsc_queue", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "Blade",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigtui", .module = zigtui.module("zigtui") },
                .{ .name = "spsc_queue", .module = spsc.module("spsc_queue") },
            },
        }),
    });
    if (target.result.os.tag == .macos) {
        //Darwin// Use external proc library for proc list
        exe.linkSystemLibrary("proc");
    }
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
