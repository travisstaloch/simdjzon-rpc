const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const simdjzon_dep = b.dependency("simdjzon", .{ .target = target, .optimize = optimize });
    const simdjzon_mod = simdjzon_dep.module("simdjzon");
    const mod = b.addModule("simdjzon-rpc", .{
        .source_file = .{ .path = "src/lib.zig" },
        .dependencies = &.{.{ .name = "simdjzon", .module = simdjzon_mod }},
    });
    _ = mod;

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.addModule("simdjzon", simdjzon_mod);
    const run_main_tests = b.addRunArtifact(main_tests);
    run_main_tests.has_side_effects = true;
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
