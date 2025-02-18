const std = @import("std");

const common = @import("common");
const jsonrpc = @import("simdjzon-rpc");

pub const read_buf_cap = 4096;

var net_server_ptr: *std.net.Server = undefined;
pub fn main() !void {
    const Gpa = std.heap.GeneralPurposeAllocator(.{});
    var gpa = Gpa{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

    // init net_server
    const localhost = try std.net.Address.parseIp("127.0.0.1", port);
    var net_server = try localhost.listen(.{ .reuse_address = true, .reuse_port = true });
    net_server_ptr = &net_server;
    defer net_server.deinit();

    std.debug.print("\nlistening on http://{}\n", .{net_server.listen_address.getPort()});

    // init jsonrpc engine
    var e = common.Engine(jsonrpc.Rpc){ .allocator = alloc };
    defer e.deinit();

    try e.putCallback(.{
        .name = "echo",
        .callback = struct {
            fn func(rpc: *jsonrpc.Rpc) void {
                const content = rpc.getParamByIndex(0) orelse unreachable;
                rpc.writeResult(
                    \\"{s}"
                , .{content.string}) catch
                    @panic("write failed");
            }
        }.func,
    });

    // handle ctrl+c
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{
            .handler = struct {
                fn func(sig: c_int) callconv(.C) void {
                    _ = sig;

                    std.posix.shutdown(net_server_ptr.stream.handle, .both) catch |err| {
                        std.debug.print("shutdown {s}\n", .{@errorName(err)});
                    };
                }
            }.func,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    // unbuffered echo server - handle requests
    while (true) {
        const conn = net_server.accept() catch |err| switch (err) {
            error.SocketNotListening => break,
            else => return err,
        };
        defer conn.stream.close();

        var header_buffer: [8192]u8 = undefined;
        var server = std.http.Server.init(conn, &header_buffer);
        var request = try server.receiveHead();
        const reader = try request.reader();

        var send_buffer: [8192]u8 = undefined;
        var res = request.respondStreaming(.{
            .send_buffer = &send_buffer,
            .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                .status = .ok,
                .transfer_encoding = .chunked,
            },
        });

        var rpc = jsonrpc.Rpc.init(reader, res.writer());
        defer rpc.deinit();

        try e.parseAndRespond(&rpc);
        try res.flush();
        try res.endChunked(.{});
    }

    std.debug.print("\ndone\n", .{});
}
