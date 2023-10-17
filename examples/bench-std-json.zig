const std = @import("std");
const jsonrpc = @import("std-json-rpc");
const CountingAllocator = @import("CountingAllocator.zig");
const build_options = @import("build_options");
const common = @import("common");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 20 }){};
    defer _ = gpa.deinit();
    var ca = CountingAllocator.init(if (build_options.bench_use_gpa)
        gpa.allocator()
    else
        std.heap.c_allocator, .{ .timings = true });
    const alloc = ca.allocator();

    var e = common.Engine{ .allocator = alloc };
    defer e.deinit();
    const Rpc = jsonrpc.FbsRpc;
    try jsonrpc.setupTestEngine(&e, Rpc);

    var infbs = std.io.fixedBufferStream("");
    var buf: [512]u8 = undefined;
    var outfbs = std.io.fixedBufferStream(&buf);

    var req_count: f64 = 0;
    var timer = try std.time.Timer.start();
    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();
    var rpc = Rpc.init(infbs.reader(), outfbs.writer());
    defer rpc.deinit(alloc);

    while (req_count < build_options.bench_iterations) : (req_count += 1) {
        infbs.pos = 0;
        outfbs.pos = 0;
        const input, const expected = common.benchInputExpected(
            random.int(usize),
        );
        infbs.buffer = input;

        // std.debug.print("req_count={d:.0} input={s}\n", .{ req_count, input });
        try e.parseAndRespond(&rpc);
        if (build_options.bench_validate) {
            if (!std.mem.eql(u8, outfbs.getWritten(), expected)) {
                std.debug.print("\ninput   ={s}\n", .{input});
                std.debug.print("expected={s}\n", .{expected});
                std.debug.print("got     ={s}\n", .{outfbs.getWritten()});
                return error.UnexpectedResponse;
            }
        }
    }

    if (build_options.bench_summary) {
        const elapsed = timer.lap();
        const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
        std.debug.print(
            "\n reqs={d:.0}\n time={}\nreq/s={d:.1}K\n",
            .{ req_count, std.fmt.fmtDuration(elapsed), req_count / seconds / 1000 },
        );
        ca.printSummary(std.debug.print);
    }
}
