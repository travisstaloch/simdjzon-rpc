const std = @import("std");
const jsonrpc = @import("simdjzon-rpc");

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var e = jsonrpc.Engine{ .allocator = alloc };
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

    var req_count: f64 = 0;
    var timer = try std.time.Timer.start();
    while (req_count < 30_000) : (req_count += 1) {
        infbs.pos = 0;
        outfbs.pos = 0;
        defer rpc.deinit(alloc);
        try e.parseAndRespond(&rpc);
    }

    const elapsed = timer.lap();
    const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
    std.debug.print(
        "\n reqs={d:.0}\n time={}\nreq/s={d:.1}K\n",
        .{ req_count, std.fmt.fmtDuration(elapsed), req_count / seconds / 1000 },
    );
}
