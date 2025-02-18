const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const simdjzon_dep = b.dependency(
        "simdjzon",
        .{ .target = target, .optimize = optimize },
    );
    const simdjzon_mod = simdjzon_dep.module("simdjzon");
    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
    });
    const mod = b.addModule("simdjzon-rpc", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "simdjzon", .module = simdjzon_mod },
            .{ .name = "common", .module = common_mod },
        },
    });
    const std_json_mod = b.addModule("std-json-rpc", .{
        .root_source_file = b.path("src/std-json.zig"),
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });
    const build_options = b.addOptions();
    build_options.addOption(
        usize,
        "bench_iterations",
        b.option(usize, "bench-iterations", "number times for benchmark to " ++
            "loop. default 100.") orelse 100,
    );
    build_options.addOption(
        bool,
        "bench_summary",
        b.option(bool, "bench-summary", "whether or not to show bench timing " ++
            "and memory usage summary. default false.") orelse false,
    );
    build_options.addOption(
        bool,
        "bench_use_gpa",
        b.option(bool, "bench-use-gpa", "whether or not to use zig's " ++
            "general purpose allocator.  use std.heap.c_allocator when " ++
            "false.  default false.") orelse false,
    );
    build_options.addOption(
        bool,
        "bench_validate",
        b.option(bool, "bench-validate", "whether to check that rpc " ++
            "output matches expected output.  default false.") orelse false,
    );
    const build_opts_mod = build_options.createModule();

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addImport("simdjzon", simdjzon_mod);
    main_tests.root_module.addImport("common", common_mod);

    const run_main_tests = b.addRunArtifact(main_tests);
    run_main_tests.has_side_effects = true;
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    try buildExample("http-echo-server", b, target, optimize, &.{
        .{ "simdjzon-rpc", mod },
        .{ "common", common_mod },
    }, &.{});
    try buildExample("bench", b, target, optimize, &.{
        .{ "simdjzon-rpc", mod },
        .{ "build_options", build_opts_mod },
        .{ "common", common_mod },
    }, &.{"c"});
    try buildExample("bench-std-json", b, target, optimize, &.{
        .{ "std-json-rpc", std_json_mod },
        .{ "build_options", build_opts_mod },
        .{ "common", common_mod },
    }, &.{"c"});
}

const NamedModule = struct { []const u8, *std.Build.Module };
fn buildExample(
    name: []const u8,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mods: []const NamedModule,
    libs: []const []const u8,
) !void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
    });
    for (mods) |mod| exe.root_module.addImport(mod[0], mod[1]);
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    const run_exe_step = b.step(b.fmt("{s}", .{name}), b.fmt("Run {s}", .{name}));
    run_exe_step.dependOn(&run_exe.step);
    if (b.args) |args| run_exe.addArgs(args);
    for (libs) |lib| exe.linkSystemLibrary(lib);
    b.getInstallStep().dependOn(&exe.step);
}
