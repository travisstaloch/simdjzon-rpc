const std = @import("std");
const jsonrpc = @import("simdjzon-rpc");
const CountingAllocator = @import("CountingAllocator.zig");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 20 }){};
    defer _ = gpa.deinit();
    var ca = CountingAllocator.init(gpa.allocator(), .{ .timings = true });
    // var ca = CountingAllocator.init(std.heap.c_allocator, .{ .timings = true });
    const alloc = ca.allocator();

    var e = jsonrpc.common.Engine{ .allocator = alloc };
    defer e.deinit();
    const Rpc = jsonrpc.FbsRpc;
    try e.putCallback(.{
        .name = "echo",
        .callback = struct {
            fn func(rpc_impl: *anyopaque) void {
                const content = Rpc.getParamByIndex(0, rpc_impl) orelse unreachable;
                Rpc.writeResult(
                    \\"{s}"
                , .{content.string}, rpc_impl) catch
                    @panic("write failed");
            }
        }.func,
    });

    const input =
        \\{"jsonrpc":"2.0","method":"echo","params":["hello world"],"id":0}
    ;
    var infbs = std.io.fixedBufferStream(input);
    var buf: [256]u8 = undefined;
    var outfbs = std.io.fixedBufferStream(&buf);
    var rpc = Rpc.init(infbs.reader(), outfbs.writer());
    defer rpc.deinit();
    var req_count: f64 = 0;
    var timer = try std.time.Timer.start();
    while (req_count < build_options.bench_iterations) : (req_count += 1) {
        // std.debug.print("req_count={d:.0}\n", .{req_count});
        infbs.pos = 0;
        outfbs.pos = 0;
        defer rpc.parser.clearRetainingCapacity();

        try e.parseAndRespond(&rpc);
        if (std.mem.indexOf(u8, outfbs.getWritten(),
            \\"result":"hello world"
        ) == null) return error.UnexpectedResponse;
    }

    const elapsed = timer.lap();
    const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
    std.debug.print(
        "\n reqs={d:.0}\n time={}\nreq/s={d:.1}K\n",
        .{ req_count, std.fmt.fmtDuration(elapsed), req_count / seconds / 1000 },
    );
    ca.printSummary(std.debug.print);
}
