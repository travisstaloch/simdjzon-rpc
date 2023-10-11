const std = @import("std");
const testing = std.testing;
const talloc = testing.allocator;
const mem = std.mem;
const simdjzon = @import("simdjzon");
const dom = simdjzon.dom;

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

pub const RpcInfo = struct {
    id_buf: [25]u8 = undefined,
    id: []const u8,
    method_name: []const u8,
    element: dom.Element = undefined,

    pub const empty = RpcInfo{ .id = "", .method_name = "" };

    // custom json parsing method
    pub fn jsonParse(doc: dom.Element, out: anytype, _: simdjzon.common.GetOptions) !void {
        if (try out.jsonParseImpl(doc)) |err| {
            std.log.err("{} - {s}", .{ err.code, err.note });
            return error.UserDefined;
        }
    }

    pub fn jsonParseImpl(out: *RpcInfo, doc: dom.Element) !?Error {
        if (!doc.is(.OBJECT))
            return Error.init(
                .invalid_request,
                "The JSON sent is not a valid request object.",
            );
        const version = doc.at_key("jsonrpc") orelse
            return Error.init(.invalid_request, "Invalid request. Missing 'jsonrpc' field.");

        if (!version.is(.STRING) or !mem.eql(u8, "2.0", try version.get_string()))
            return Error.init(
                .invalid_request,
                "Invalid request. 'version' field must equal '2.0'",
            );

        if (doc.at_key("id")) |id| {
            if (id.is(.STRING)) {
                out.id = try id.get_string();
            } else if (id.is(.INT64) or id.is(.UINT64)) {
                out.id = try std.fmt.bufPrint(&out.id_buf, "{}", .{try id.get_int64()});
            } else {
                return Error.init(
                    .invalid_request,
                    "Invalid request. 'id' must be an integer or string.",
                );
            }
        } else out.id = "";

        const method = doc.at_key("method") orelse
            return Error.init(.invalid_request, "Invalid request. Missing 'method' field.");

        if (!method.is(.STRING))
            return Error.init(.invalid_request, "Invalid request. 'method' field must be a string.");
        const params_ok = if (doc.at_key("params")) |params|
            params.is(.ARRAY) or params.is(.OBJECT)
        else
            true;

        if (!params_ok)
            return Error.init(
                .invalid_request,
                "Invalid Request. 'params' field must be an array or object.",
            );

        out.method_name = try method.get_string();
        out.element = doc;
        // std.debug.print("method_name={s} id={s}\n", .{ out.method_name, out.id });
        return null;
    }
};

fn checkField(
    comptime field_name: []const u8,
    expected: RpcInfo,
    actual: RpcInfo,
    input: []const u8,
) !void {
    const ex = @field(expected, field_name);
    const ac = @field(actual, field_name);
    testing.expectEqualStrings(ex, ac) catch |e| {
        std.log.err("field '{s}' expected '{s}' actual '{s}'", .{ field_name, ex, ac });
        std.log.err("input={s}", .{input});
        return e;
    };
}

test RpcInfo {
    // some test cases from https://www.jsonrpc.org/specification
    const input_expecteds = [_]struct { []const u8, RpcInfo }{
        // call with positional params
        .{
            \\{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
            ,
            .{ .method_name = "subtract", .id = "1" },
        },
        .{
            \\{"jsonrpc": "2.0", "method": "subtract", "params": [23, 42], "id": 2}
            ,
            .{ .method_name = "subtract", .id = "2" },
        },
        // call with named params
        .{
            \\{"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3}
            ,
            .{ .method_name = "subtract", .id = "3" },
        },
        .{
            \\{"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 4}
            ,
            .{ .method_name = "subtract", .id = "4" },
        },
    };

    for (input_expecteds) |ie| {
        const input, const expected = ie;
        var parser = try dom.Parser.initFixedBuffer(talloc, input, .{});
        defer parser.deinit();
        try parser.parse();

        var actual: RpcInfo = undefined;
        // std.debug.print("input={s}\n", .{input});
        try parser.element().get(&actual);
        try checkField("id", expected, actual, input);
        try checkField("method_name", expected, actual, input);
    }
}

pub const Elements = union(enum) {
    element: dom.Element,
    array: dom.Array,
};

pub const JsonValue = union(enum) {
    null,
    bool: bool,
    int: i64,
    double: f64,
    string: []const u8,

    pub const Tag = std.meta.Tag(JsonValue);

    pub fn init(ele: dom.Element) JsonValue {
        return if (ele.is(.BOOL))
            .{ .bool = ele.get_bool() catch unreachable }
        else if (ele.is(.INT64))
            .{ .int = ele.get_int64() catch unreachable }
        else if (ele.is(.DOUBLE))
            .{ .double = ele.get_double() catch unreachable }
        else if (ele.is(.STRING))
            .{ .string = ele.get_string() catch unreachable }
        else
            .null;
    }
};

fn RpcImpl(comptime R: type, comptime W: type) type {
    return struct {
        parser: dom.Parser,
        input: []const u8 = &.{},
        info: RpcInfo = RpcInfo.empty,
        elements: Elements,
        is_first_response: bool = true,
        // TODO use AnyReader/Writer so that this type won't need to be generic
        reader: Reader,
        writer: Writer,

        pub const Reader = R;
        pub const Writer = W;
        const Self = @This();

        pub fn deinit(self: *Self, allocator: mem.Allocator) void {
            self.parser.deinit();
            allocator.free(self.input);
        }

        fn startResponse(self: *Self) !void {
            if (self.elements == .array) try self.writer.writeByte('[');
        }
        fn finishResponse(self: *Self) !void {
            if (self.elements == .array) try self.writer.writeByte(']');
        }

        fn writeComma(self: *Self) !void {
            if (!self.is_first_response) {
                if (self.elements == .array) try self.writer.writeByte(',');
            } else self.is_first_response = false;
        }

        /// write a jsonrpc result record to 'self.writer'
        pub fn writeResult(
            self: *Self,
            comptime fmt: []const u8,
            args: anytype,
        ) !void {
            if (self.info.id.len == 0) return error.MissingId;
            try self.writeComma();

            try self.writer.print(
                \\{{"jsonrpc":"2.0","result":
                ++ fmt ++
                    \\,"id":"{s}"}}
            ,
                args ++ .{self.info.id},
            );
        }

        /// write a jsonrpc error record to 'self.writer'
        pub fn writeError(self: *Self, err: Error) !void {
            try self.writeComma();
            if (self.info.id.len == 0)
                try self.writer.print(
                    \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":null}}
                , .{ @intFromEnum(err.code), err.note })
            else
                try self.writer.print(
                    \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":"{s}"}}
                , .{ @intFromEnum(err.code), err.note, self.info.id });
        }

        /// read input from 'reader', init 'parser' and call parser.parse(),
        /// assign 'elements' field.
        /// note: doesn't initialize 'info' field.  that happens in
        /// respond().  if you want to manually initialize 'info', it can
        /// be done like this: `try self.info.jsonParseImpl(self.elements.element)`
        pub fn parse(self: *Self, allocator: mem.Allocator) ?Error {
            self.input = self.reader.readAllAlloc(allocator, std.math.maxInt(u32)) catch
                return Error.init(@enumFromInt(-32000), "Out of memory");
            self.parser = dom.Parser.initFixedBuffer(allocator, self.input, .{}) catch
                return Error.init(@enumFromInt(-32000), "Out of memory");

            self.parser.parse() catch
                return Error.init(.parse_error, "Invalid JSON was received by the server.");

            const ele = self.parser.element();
            self.elements = if (ele.is(.ARRAY))
                .{ .array = ele.get_array() catch unreachable }
            else
                .{ .element = ele };
            return null;
        }

        pub fn getParamByName(self: *Self, name: []const u8) ?JsonValue {
            const params = self.info.element.at_key("params") orelse
                return null;
            return JsonValue.init(params.at_key(name) orelse return null);
        }

        pub fn getParamByIndex(self: *Self, index: usize) ?JsonValue {
            const params = self.info.element.at_key("params") orelse
                return null;
            const arr = params.get_array() catch return null;
            return JsonValue.init(arr.at(index) orelse return null);
        }

        const FindAndCall = @TypeOf(Engine.findAndCall);

        pub fn respond(
            self: *Self,
            engine: Engine,
            find_and_call: *const FindAndCall,
        ) !?Error {
            switch (self.elements) {
                .array => |array| {
                    var i: usize = 0;
                    while (array.at(i)) |ele| : (i += 1) {
                        if (!ele.is(.OBJECT)) {
                            try self.writeError(Error.init(.invalid_request, "Invalid request. Not an object."));
                            continue;
                        }
                        self.info = RpcInfo.empty;
                        if (try self.info.jsonParseImpl(ele)) |err| {
                            try self.writeError(err);
                            continue;
                        }

                        if (!find_and_call(
                            engine,
                            self,
                            self.info.method_name,
                        )) {
                            if (self.info.id.len != 0)
                                try self.writeError(Error.init(.method_not_found, "Method not found"));
                        }
                    }
                    if (i == 0)
                        return Error.init(.invalid_request, "Invalid request. Empty array.");
                },
                .element => |element| {
                    self.info = RpcInfo.empty;
                    if (try self.info.jsonParseImpl(element)) |err|
                        return err;
                    if (!find_and_call(
                        engine,
                        self,
                        self.info.method_name,
                    )) {
                        if (self.info.id.len != 0)
                            return Error.init(.method_not_found, "Method not found");
                    }
                },
            }
            return null;
        }
    };
}

const ConstFbs = std.io.FixedBufferStream([]const u8);
const Fbs = std.io.FixedBufferStream([]u8);
pub const FbsRpc = Rpc(ConstFbs.Reader, Fbs.Writer);

test "named params" {
    var input_fbs = std.io.fixedBufferStream(
        \\{"jsonrpc": "2.0", "method": "sum", "params": {"a": 1, "b": 2}, "id": 1}
    );
    var buf: [256]u8 = undefined;
    var output_fbs = std.io.fixedBufferStream(&buf);

    var rpc = FbsRpc.init(input_fbs.reader(), output_fbs.writer());
    defer rpc.deinit(talloc);
    const merr = rpc.parse(talloc);
    try testing.expect(merr == null);
    _ = try rpc.info.jsonParseImpl(rpc.elements.element);

    const prm_a = rpc.getParamByName("a") orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_a);
    try testing.expectEqual(@as(i64, 1), prm_a.int);

    const prm_b = rpc.getParamByName("b") orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_b);
    try testing.expectEqual(@as(i64, 2), prm_b.int);

    try testing.expect(rpc.getParamByName("c") == null);
}

test "indexed params" {
    var input_fbs = std.io.fixedBufferStream(
        \\{"jsonrpc": "2.0", "method": "sum", "params": [1,2], "id": 1}
    );
    var buf: [256]u8 = undefined;
    var output_fbs = std.io.fixedBufferStream(&buf);

    var rpc = FbsRpc.init(input_fbs.reader(), output_fbs.writer());
    defer rpc.deinit(talloc);
    const merr = rpc.parse(talloc);
    try testing.expect(merr == null);
    _ = try rpc.info.jsonParseImpl(rpc.elements.element);

    const prm_0 = rpc.getParamByIndex(0) orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_0);
    try testing.expectEqual(@as(i64, 1), prm_0.int);

    const prm_1 = rpc.getParamByIndex(1) orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_1);
    try testing.expectEqual(@as(i64, 2), prm_1.int);

    try testing.expect(rpc.getParamByIndex(2) == null);
}

pub const Callback = fn (rpc_impl: *anyopaque) void;

pub const NamedCallback = struct {
    name: []const u8,
    callback: *const Callback,
    rpc_impl: *anyopaque = undefined,
};

pub const Engine = struct {
    callbacks: std.StringHashMapUnmanaged(NamedCallback) = .{},
    allocator: mem.Allocator,

    pub fn deinit(e: *Engine) void {
        e.callbacks.deinit(e.allocator);
    }

    pub fn putCallback(e: *Engine, named_callback: NamedCallback) !void {
        try e.callbacks.put(e.allocator, named_callback.name, named_callback);
    }

    fn findAndCall(engine: Engine, rpc_impl: *anyopaque, name: []const u8) bool {
        const named_cb = engine.callbacks.get(name) orelse return false;
        named_cb.callback(rpc_impl);
        return true;
    }

    pub fn parseAndRespond(engine: Engine, rpc_impl: anytype) !void {
        if (rpc_impl.parse(engine.allocator)) |err| {
            try rpc_impl.writeError(err);
            return;
        }
        try rpc_impl.startResponse();
        if (try rpc_impl.respond(engine, findAndCall)) |err|
            try rpc_impl.writeError(err);
        try rpc_impl.finishResponse();
    }
};

/// exposes type erased methods for use in user implementations
pub fn Rpc(comptime R: type, comptime W: type) type {
    return struct {
        pub const TypedRpc = RpcImpl(R, W);

        /// initialize a jsonrpc object with the given reader and writer
        pub fn init(reader: R, writer: W) TypedRpc {
            return .{
                .reader = reader,
                .writer = writer,
                .elements = .{ .element = undefined },
                .parser = undefined,
            };
        }

        /// write a jsonrpc result record
        pub fn writeResult(
            comptime fmt: []const u8,
            args: anytype,
            rpc_impl: *anyopaque,
        ) !void {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_impl));
            try rpc.writeResult(fmt, args);
        }

        /// write a jsonrpc error record
        pub fn writeError(
            err: Error,
            rpc_impl: *anyopaque,
        ) !void {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_impl));
            try rpc.writeError(err);
        }

        /// return a 'params' array element at the given index if it exists
        pub fn getParamByIndex(index: usize, rpc_impl: *anyopaque) ?JsonValue {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_impl));
            return rpc.getParamByIndex(index);
        }

        /// return a 'params' object field with the given name if it exists
        pub fn getParamByName(name: []const u8, rpc_impl: *anyopaque) ?JsonValue {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_impl));
            return rpc.getParamByName(name);
        }
    };
}

test {
    var e = Engine{ .allocator = talloc };
    defer e.deinit();

    try e.putCallback(.{
        .name = "sum",
        .callback = struct {
            fn func(rpc_impl: *anyopaque) void {
                var r: i64 = 0;
                var i: usize = 0;
                while (FbsRpc.getParamByIndex(i, rpc_impl)) |param| : (i += 1) {
                    r += param.int;
                }
                FbsRpc.writeResult("{}", .{r}, rpc_impl) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "sum_named",
        .callback = struct {
            fn func(rpc_impl: *anyopaque) void {
                const a = FbsRpc.getParamByName("a", rpc_impl) orelse unreachable;
                const b = FbsRpc.getParamByName("b", rpc_impl) orelse unreachable;
                FbsRpc.writeResult("{}", .{a.int + b.int}, rpc_impl) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "subtract",
        .callback = struct {
            fn func(rpc_impl: *anyopaque) void {
                const a = FbsRpc.getParamByIndex(0, rpc_impl) orelse unreachable;
                const b = FbsRpc.getParamByIndex(1, rpc_impl) orelse unreachable;
                FbsRpc.writeResult("{}", .{a.int - b.int}, rpc_impl) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "get_data",
        .callback = struct {
            fn func(rpc_impl: *anyopaque) void {
                FbsRpc.writeResult(
                    \\["hello",5]
                , .{}, rpc_impl) catch
                    @panic("write failed");
            }
        }.func,
    });

    // from https://www.jsonrpc.org/specification#examples
    const input_expecteds = [_][2][]const u8{
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
            // FIXME this should be empty, no array
            "[]",
        },
    };

    for (input_expecteds) |ie| {
        const input, const expected = ie;
        var input_fbs = std.io.fixedBufferStream(input);
        var buf: [512]u8 = undefined;
        var output_fbs = std.io.fixedBufferStream(&buf);

        var rpc = FbsRpc.init(input_fbs.reader(), output_fbs.writer());
        defer rpc.deinit(talloc);
        try e.parseAndRespond(&rpc);

        try testing.expectEqualStrings(expected, output_fbs.getWritten());
    }
}
