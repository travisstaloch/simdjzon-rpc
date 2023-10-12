const std = @import("std");
const jsonrpc = @import("simdjzon-rpc");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    // parse args
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    var i: usize = 1;
    var port: u16 = 4000;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, "-p", args[i])) {
            i += 1;
            port = try std.fmt.parseUnsigned(u16, args[i], 10);
        }
    }

    // init server
    const address = try std.net.Ip4Address.parse("127.0.0.1", port);
    var server = std.http.Server.init(
        alloc,
        .{ .reuse_port = true, .reuse_address = true },
    );
    defer server.deinit();
    try server.listen(.{ .in = address });
    std.debug.print("\nlistening on http://{}\n", .{address});

    // init jsonrpc engine
    var e = jsonrpc.Engine{ .allocator = alloc };
    defer e.deinit();
    const Rpc = jsonrpc.Rpc(
        std.http.Server.Response.Reader,
        std.http.Server.Response.Writer,
    );

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

    // unbuffered echo server - handle requests
    while (true) {
        var res = try server.accept(.{
            .allocator = alloc,
            .header_strategy = .{ .dynamic = std.mem.page_size },
        });
        defer res.deinit();
        defer _ = res.reset();
        try res.wait();

        var rpc = Rpc.init(res.reader(), res.writer());
        defer rpc.deinit();
        res.transfer_encoding = .chunked;
        try res.headers.append("content-type", "application/json");
        try res.do();
        try e.parseAndRespond(&rpc);
        try res.finish();
    }
}
