const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const simdjzon_rpc_dep = b.dependency("simdjzon-rpc", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = simdjzon_rpc_dep.module("simdjzon-rpc");
    const exe = b.addExecutable(.{
        .name = "http-echo-server",
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("simdjzon-rpc", mod);
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    const run_exe_step = b.step("run", "Run the echo server");
    run_exe_step.dependOn(&run_exe.step);
    if (b.args) |args| run_exe.addArgs(args);
}
