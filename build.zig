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
    const zigtui_mod = zigtui.module("zigtui");
    const spsc_mod = spsc.module("spsc_queue");

    const module_target = b.graph.host;

    const model_mod = b.createModule(.{
        .root_source_file = b.path("src/model.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = module_target,
        .optimize = optimize,
    });

    const procs_sort_mod = b.createModule(.{
        .root_source_file = b.path("src/procs/sort.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const procs_tree_mod = b.createModule(.{
        .root_source_file = b.path("src/procs/tree.zig"),
        .target = module_target,
        .optimize = optimize,
    });

    const thread_channel_mod = b.createModule(.{
        .root_source_file = b.path("src/thread/channel.zig"),
        .target = module_target,
        .optimize = optimize,
    });

    const procs_mod = b.createModule(.{
        .root_source_file = b.path("src/procs/store.zig"),
        .target = module_target,
        .optimize = optimize,
    });

    const state_mod = b.createModule(.{
        .root_source_file = b.path("src/state.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const thread_producer_mod = b.createModule(.{
        .root_source_file = b.path("src/thread/producer.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const ui_layout_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/layout.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const ui_render_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/render.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const event_action_mod = b.createModule(.{
        .root_source_file = b.path("src/event/action.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const event_keymap_mod = b.createModule(.{
        .root_source_file = b.path("src/event/keymap.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const event_mod = b.createModule(.{
        .root_source_file = b.path("src/event/event.zig"),
        .target = module_target,
        .optimize = optimize,
    });
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = module_target,
        .optimize = optimize,
    });

    // procs domain wiring
    procs_sort_mod.addImport("model", model_mod);
    procs_tree_mod.addImport("model", model_mod);
    procs_mod.addImport("model", model_mod);
    procs_mod.addImport("procs_tree", procs_tree_mod);
    procs_mod.addImport("procs_sort", procs_sort_mod);
    procs_mod.addImport("thread_channel", thread_channel_mod);

    // state wiring
    state_mod.addImport("thread_channel", thread_channel_mod);
    state_mod.addImport("procs", procs_mod);
    state_mod.addImport("zigtui", zigtui_mod);
    state_mod.addImport("model", model_mod);
    state_mod.addImport("event_keymap", event_keymap_mod);

    // thread wiring
    thread_channel_mod.addImport("spsc_queue", spsc_mod);
    thread_channel_mod.addImport("platform", platform_mod);
    thread_channel_mod.addImport("model", model_mod);

    thread_producer_mod.addImport("thread_channel", thread_channel_mod);
    thread_producer_mod.addImport("platform", platform_mod);

    // event wiring
    event_keymap_mod.addImport("event_action", event_action_mod);
    event_mod.addImport("event_keymap", event_keymap_mod);
    event_mod.addImport("state", state_mod);
    event_mod.addImport("platform", platform_mod);
    event_mod.addImport("zigtui", zigtui_mod);

    // ui wiring
    ui_render_mod.addImport("state", state_mod);
    ui_render_mod.addImport("ui_layout", ui_layout_mod);
    ui_render_mod.addImport("event_keymap", event_keymap_mod);
    ui_render_mod.addImport("zigtui", zigtui_mod);
    ui_render_mod.addImport("model", model_mod);

    // main wiring
    main_mod.addImport("event", event_mod);
    main_mod.addImport("ui_render", ui_render_mod);
    main_mod.addImport("state", state_mod);
    main_mod.addImport("thread_channel", thread_channel_mod);
    main_mod.addImport("thread_producer", thread_producer_mod);
    main_mod.addImport("zigtui", zigtui_mod);
    main_mod.addImport("spsc_queue", spsc_mod);

    // platform wiring
    platform_mod.addImport("model", model_mod);

    const exe = b.addExecutable(.{
        .name = "Blade",
        .root_module = main_mod,
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
