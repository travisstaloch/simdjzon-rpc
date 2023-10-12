const std = @import("std");
const zig_json_rpc = @import("zig-json-rpc.zig");
const CountingAllocator = @import("CountingAllocator.zig");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer _ = gpa.deinit();
    var ca = CountingAllocator.init(gpa.allocator(), .{ .timings = true });
    // var ca = CountingAllocator.init(std.heap.c_allocator, .{ .timings = true });
    const alloc = ca.allocator();
    const input =
        \\{"jsonrpc":"2.0","method":"echo","params":"hello world","id":0}
    ;
    const Req = zig_json_rpc.Request([]const u8);
    var req_count: f64 = 0;
    var timer = try std.time.Timer.start();
    while (req_count < build_options.bench_iterations) : (req_count += 1) {
        const req = try std.json.parseFromSlice(Req, alloc, input, .{});
        defer req.deinit();
        // std.debug.print("req={}\n", .{req});
        const Response = zig_json_rpc.Response([]const u8, []const u8);
        var res = Response{
            .id = req.value.id,
            .result = req.value.params,
        };
        var buf: [256]u8 = undefined;
        var out_fbs = std.io.fixedBufferStream(&buf);
        try std.json.stringify(res, .{}, out_fbs.writer());
        if (std.mem.indexOf(u8, out_fbs.getWritten(),
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
