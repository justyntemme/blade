const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigtui = b.dependency("zigtui", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "Blade",
        .root_module = b.createModule(.{
            // .root_source_file = b.path("src/main.zig"),
            .root_source_file = b.path("src/example.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigtui", .module = zigtui.module("zigtui") },
            },
        }),
    });
    // Import ZigTUI module
    // Use external proc library on mac to get system procs
    exe.linkSystemLibrary("proc");
    // Your executable
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
