const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The compression core as a library module, importable as `shrimp`.
    const mod = b.addModule("shrimp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "shrimp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shrimp", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run shrimp");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // The GUI application, linked against raylib.
    const raylib_prefix = b.option(
        []const u8,
        "raylib-prefix",
        "Installation prefix of raylib (headers in <prefix>/include, libs in <prefix>/lib)",
    ) orelse "/opt/homebrew/opt/raylib";

    const gui = b.addExecutable(.{
        .name = "shrimp-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "shrimp", .module = mod },
            },
        }),
    });
    gui.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{raylib_prefix}) });
    gui.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{raylib_prefix}) });
    gui.root_module.linkSystemLibrary("raylib", .{});

    b.installArtifact(gui);

    const gui_run_step = b.step("run-gui", "Run the shrimp GUI");
    const gui_run_cmd = b.addRunArtifact(gui);
    gui_run_step.dependOn(&gui_run_cmd.step);
    gui_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        gui_run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
