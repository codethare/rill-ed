const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const pie = b.option(bool, "pie", "Build position independent executable") orelse true;

    const scanner = Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_xkb_bindings_v1", 1);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const imports = [_]std.Build.Module.Import{
        .{ .name = "wayland", .module = wayland },
        .{ .name = "xkbcommon", .module = xkbcommon },
    };

    const rill = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
        .strip = strip,
    });
    rill.linkSystemLibrary("wayland-client", .{});
    rill.linkSystemLibrary("xkbcommon", .{});

    const exe = b.addExecutable(.{
        .name = "rill",
        .root_module = rill,
    });
    exe.pie = pie;
    b.installArtifact(exe);

    const default_config = b.createModule(.{ .root_source_file = b.path("config.zon") });
    rill.addImport("default_config", default_config);

    const tests = b.addTest(.{ .root_module = rill });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
