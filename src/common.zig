const std = @import("std");
const mem = std.mem;

pub const Version = enum(u24) {
    two = mem.readInt(u24, "2.0", .big),
};

pub const Error = struct {
    code: Code,
    note: []const u8,

    pub const Code = enum(i32) {
        parse_error = -32700,
        invalid_request = -32600,
        method_not_found = -32601,
        invalid_params = -32602,
        internal_error = -32603,
        _, // -32000 to -32099: server_error
    };

    pub fn init(code: Code, note: []const u8) Error {
        return .{ .code = code, .note = note };
    }

    pub fn format(err: Error, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        try writer.print("code={} note={s}", .{ @intFromEnum(err.code), err.note });
    }
};

pub const Callback = fn (rpc_ptr: *anyopaque) void;

pub const NamedCallback = struct {
    name: []const u8,
    callback: *const Callback,
    rpc_ptr: *anyopaque = undefined,
};

pub const FindAndCall = @TypeOf(Engine.findAndCall);

pub const Engine = struct {
    callbacks: std.StringHashMapUnmanaged(NamedCallback) = .{},
    allocator: mem.Allocator,

    pub fn deinit(e: *Engine) void {
        e.callbacks.deinit(e.allocator);
    }

    pub fn putCallback(e: *Engine, named_callback: NamedCallback) !void {
        try e.callbacks.put(e.allocator, named_callback.name, named_callback);
    }

    pub fn findAndCall(engine: Engine, rpc_ptr: *anyopaque, name: []const u8) bool {
        const named_cb = engine.callbacks.get(name) orelse return false;
        named_cb.callback(rpc_ptr);
        return true;
    }

    pub fn parseAndRespond(engine: Engine, rpc: anytype) !void {
        if (rpc.parse(engine.allocator)) |err| {
            try rpc.writeError(err);
            try rpc.writer.flush();
            return;
        }
        try rpc.startResponse();
        if (try rpc.respond(engine, findAndCall)) |err|
            try rpc.writeError(err);
        try rpc.finishResponse();
    }
};

/// some test cases from https://www.jsonrpc.org/specification
pub const test_cases_1 = .{
    // call with positional params
    .{
        \\{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
        ,
        .{ .method = "subtract", .id = 1 },
    },
    .{
        \\{"jsonrpc": "2.0", "method": "subtract", "params": [23, 42], "id": 2}
        ,
        .{ .method = "subtract", .id = 2 },
    },
    // call with named params
    .{
        \\{"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3}
        ,
        .{ .method = "subtract", .id = 3 },
    },
    .{
        \\{"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 4}
        ,
        .{ .method = "subtract", .id = 4 },
    },
};

// from https://www.jsonrpc.org/specification#examples
pub const test_cases_2 = [_][2][]const u8{
    .{ // rpc call with positional parameters
        \\{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": 1}
        ,
        \\{"jsonrpc":"2.0","result":7,"id":"1"}
    },
    .{ // rpc call with named parameters
        \\{"jsonrpc": "2.0", "method": "sum_named", "params": {"a": 1, "b": 2}, "id": 2}
        ,
        \\{"jsonrpc":"2.0","result":3,"id":"2"}
    },
    .{ // notifications
        \\{"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]}
        ,
        "",
    },
    .{
        \\{"jsonrpc": "2.0", "method": "foobar"}
        ,
        "",
    },
    .{ // valid rpc call Batch
        \\[{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4],  "id": 1},
        \\ {"jsonrpc": "2.0", "method": "sum", "params": [1,2,10], "id": 2}]
        ,
        \\[{"jsonrpc":"2.0","result":7,"id":"1"},{"jsonrpc":"2.0","result":13,"id":"2"}]
    },
    .{ // rpc call of non-existent method
        \\{"jsonrpc": "2.0", "method": "foobar", "id": "1"}
        ,
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":"1"}
    },
    .{ // rpc call with invalid JSON
        \\{"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]
        ,
        \\{"jsonrpc":"2.0","error":{"code":-32700,"message":"Invalid JSON was received by the server."},"id":null}
    },
    .{ // rpc call with invalid Request object
        \\{"jsonrpc": "2.0", "method": 1, "params": "bar"}
        ,
        \\{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. 'method' field must be a string."},"id":null}
    },
    .{ // rpc call Batch, invalid JSON
        \\[
        \\  {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
        \\  {"jsonrpc": "2.0", "method"
        \\]
        ,
        \\{"jsonrpc":"2.0","error":{"code":-32700,"message":"Invalid JSON was received by the server."},"id":null}
    },
    .{ // rpc call with an empty Array
        \\[]
        ,
        \\[{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Empty array."},"id":null}]
    },
    .{ // rpc call with an invalid Batch (but not empty)
        \\[1]
        ,
        \\[{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Not an object."},"id":null}]
    },
    .{ // rpc call with invalid Batch
        \\[1,2,3]
        ,
        \\[{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Not an object."},"id":null},{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Not an object."},"id":null},{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Not an object."},"id":null}]
    },
    .{ // rpc call Batch
        \\[
        \\    {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
        \\    {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},
        \\    {"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},
        \\    {"foo": "boo"},
        \\    {"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},
        \\    {"jsonrpc": "2.0", "method": "get_data", "id": "9"} 
        \\]
        ,
        \\[{"jsonrpc":"2.0","result":7,"id":"1"},{"jsonrpc":"2.0","result":19,"id":"2"},{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Missing 'jsonrpc' field."},"id":null},{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":"5"},{"jsonrpc":"2.0","result":["hello",5],"id":"9"}]
    },
    .{ // rpc call Batch (all notifications)
        \\[
        \\    {"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]},
        \\    {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}
        \\]
        ,
        "",
    },
};

pub fn benchInputExpected(
    index: usize,
) [2][]const u8 {
    return test_cases_2[@mod(index, test_cases_2.len)];
}

pub fn isZigString(comptime T: type) bool {
    return comptime blk: {
        // Only pointer types can be strings, no optionals

        const info = @typeInfo(T);
        if (info != .pointer) break :blk false;

        const ptr = &info.pointer;
        // Check for CV qualifiers that would prevent coerction to []const u8

        if (ptr.is_volatile or ptr.is_allowzero) break :blk false;

        // If it's already a slice, simple check.

        if (ptr.size == .Slice) {
            break :blk ptr.child == u8;
        }

        // Otherwise check if it's an array type that coerces to slice.

        if (ptr.size == .One) {
            const child = @typeInfo(ptr.child);
            if (child == .array) {
                const arr = &child.array;
                break :blk arr.child == u8;
            }
        }

        break :blk false;
    };
}
