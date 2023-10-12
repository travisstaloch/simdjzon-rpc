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
    const build_options = b.addOptions();
    build_options.addOption(
        usize,
        "bench_iterations",
        b.option(usize, "bench-iterations", "for benchmarking. number times " ++
            "for benchmark to loop. default 100.") orelse 100,
    );
    const build_opts_mod = build_options.createModule();

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

    try buildExample(b, target, optimize, &.{.{ "simdjzon-rpc", mod }}, "http-echo-server", &.{});
    try buildExample(b, target, optimize, &.{
        .{ "simdjzon-rpc", mod },
        .{ "build_options", build_opts_mod },
    }, "bench", &.{"c"});
    try buildExample(b, target, optimize, &.{
        .{ "build_options", build_opts_mod },
    }, "bench-zig-json-rpc", &.{"c"});
}

const NamedModule = struct { []const u8, *std.Build.Module };
fn buildExample(
    b: *std.Build,
    target: std.zig.CrossTarget,
    optimize: std.builtin.OptimizeMode,
    mods: []const NamedModule,
    name: []const u8,
    libs: []const []const u8,
) !void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{
            .path = b.fmt("examples/{s}.zig", .{name}),
        },
        .target = target,
        .optimize = optimize,
    });
    for (mods) |mod| exe.addModule(mod[0], mod[1]);
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    const run_exe_step = b.step(b.fmt("{s}", .{name}), b.fmt("Run {s}", .{name}));
    run_exe_step.dependOn(&run_exe.step);
    if (b.args) |args| run_exe.addArgs(args);
    for (libs) |lib| exe.linkSystemLibrary(lib);
}
