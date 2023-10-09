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
    pub fn jsonParse(doc: dom.Element, args: anytype) !void {
        const out = args[0];
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
                "The request 'version' field must be '2.0'",
            );

        const id = doc.at_key("id") orelse
            return Error.init(.invalid_request, "Invalid request. Missing 'id' field.");
        // TODO simplify this logic
        if ((id.is(.DOUBLE) and !id.is(.INT64) and !id.is(.UINT64)) or
            id.is(.OBJECT) or id.is(.ARRAY))
            return Error.init(
                .invalid_request,
                "Request 'id' must be an integer or string.",
            );

        const method = doc.at_key("method") orelse
            return Error.init(.invalid_request, "Invalid request. Missing 'method' field.");

        if (!method.is(.STRING))
            return Error.init(.invalid_request, "'method' field must be a string.");
        const params_present_and_valid = if (doc.at_key("params")) |params|
            params.is(.ARRAY) or params.is(.OBJECT)
        else
            true;

        if (!params_present_and_valid)
            return Error.init(
                .invalid_request,
                "Parameters can only be passed in arrays or objects.",
            );

        if (id.is(.STRING)) {
            out.id = try id.get_string();
        } else if (id.is(.INT64) or id.is(.UINT64)) {
            out.id = try std.fmt.bufPrint(&out.id_buf, "{}", .{try id.get_int64()});
        }

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

pub const ProtocolType = enum { json_rpc };

pub fn Protocol(comptime R: type, comptime W: type) type {
    return struct {
        parser: dom.Parser,
        input: []const u8 = &.{},
        rpc_info: RpcInfo = RpcInfo.empty,
        elements: Elements,
        tag: ProtocolType,
        first_response: bool = true,
        // FIXME use AnyReader/Writer so that this type won't need to be generic
        // keep these fields last in hope that pointer casting is safe
        reader: Reader,
        writer: Writer,

        pub const Reader = R;
        pub const Writer = W;
        pub const Self = @This();

        pub fn deinit(self: *Self, allocator: mem.Allocator) void {
            self.parser.deinit();
            allocator.free(self.input);
        }

        pub fn startResponse(self: *Self) !void {
            if (self.elements == .array) try self.writer.writeByte('[');
        }
        pub fn finishResponse(self: *Self) !void {
            if (self.elements == .array) try self.writer.writeByte(']');
        }

        pub fn writeComma(self: *Self) !void {
            if (!self.first_response) {
                if (self.elements == .array) try self.writer.writeByte(',');
            } else self.first_response = false;
        }

        pub fn appendResult(
            self: *Self,
            comptime fmt: []const u8,
            args: anytype,
        ) !void {
            if (self.rpc_info.id.len == 0) return error.MissingId;
            try self.writeComma();

            try self.writer.print(
                \\{{"jsonrpc":"2.0","result":
                ++ fmt ++
                    \\,"id":"{s}"}}
            ,
                args ++ .{self.rpc_info.id},
            );
        }

        pub fn appendError(self: *Self, err: Error) !void {
            // const id = if (self.rpc_info.id.len != 0) self.rpc_info.id else "null";
            try self.writeComma();
            if (self.rpc_info.id.len == 0)
                try self.writer.print(
                    \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":null}}
                , .{ @intFromEnum(err.code), err.note })
            else
                try self.writer.print(
                    \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":"{s}"}}
                , .{ @intFromEnum(err.code), err.note, self.rpc_info.id });
        }

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
            const params = self.rpc_info.element.at_key("params") orelse
                return null;
            return JsonValue.init(params.at_key(name) orelse return null);
        }

        pub fn getParamByIndex(self: *Self, index: usize) ?JsonValue {
            const params = self.rpc_info.element.at_key("params") orelse
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
                            try self.appendError(Error.init(.invalid_request, "Invalid request. Not an object."));
                            continue;
                        }
                        self.rpc_info = RpcInfo.empty;
                        if (try self.rpc_info.jsonParseImpl(ele)) |err| {
                            try self.appendError(err);
                            continue;
                        }

                        if (!find_and_call(
                            engine,
                            self,
                            self.rpc_info.method_name,
                        )) {
                            try self.appendError(Error.init(.method_not_found, "Method not found"));
                        }
                    }
                    if (i == 0)
                        return Error.init(.invalid_request, "Invalid request. Empty array.");
                },
                .element => |element| {
                    self.rpc_info = RpcInfo.empty;
                    if (try self.rpc_info.jsonParseImpl(element)) |err|
                        return err;
                    if (!find_and_call(
                        engine,
                        self,
                        self.rpc_info.method_name,
                    )) {
                        return Error.init(.method_not_found, "Method not found");
                    }
                },
            }
            return null;
        }
    };
}

pub fn protocol(
    tag: ProtocolType,
    reader: anytype,
    writer: anytype,
) Protocol(@TypeOf(reader), @TypeOf(writer)) {
    return .{
        .reader = reader,
        .writer = writer,
        .tag = tag,
        .elements = undefined,
        .parser = undefined,
    };
}

test "named params" {
    var input_fbs = std.io.fixedBufferStream(
        \\{"jsonrpc": "2.0", "method": "sum", "params": {"a": 1, "b": 2}, "id": 1}
    );
    var buf: [256]u8 = undefined;
    var output_fbs = std.io.fixedBufferStream(&buf);

    var impl = protocol(.json_rpc, input_fbs.reader(), output_fbs.writer());
    defer impl.deinit(talloc);
    const merr = impl.parse(talloc);
    try testing.expect(merr == null);
    _ = try impl.rpc_info.jsonParseImpl(impl.elements.element);

    const prm_a = impl.getParamByName("a") orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_a);
    try testing.expectEqual(@as(i64, 1), prm_a.int);

    const prm_b = impl.getParamByName("b") orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_b);
    try testing.expectEqual(@as(i64, 2), prm_b.int);

    try testing.expect(impl.getParamByName("c") == null);
}

test "indexed params" {
    var input_fbs = std.io.fixedBufferStream(
        \\{"jsonrpc": "2.0", "method": "sum", "params": [1,2], "id": 1}
    );
    var buf: [256]u8 = undefined;
    var output_fbs = std.io.fixedBufferStream(&buf);

    var impl = protocol(.json_rpc, input_fbs.reader(), output_fbs.writer());
    defer impl.deinit(talloc);
    const merr = impl.parse(talloc);
    try testing.expect(merr == null);
    _ = try impl.rpc_info.jsonParseImpl(impl.elements.element);

    const prm_0 = impl.getParamByIndex(0) orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_0);
    try testing.expectEqual(@as(i64, 1), prm_0.int);

    const prm_1 = impl.getParamByIndex(1) orelse return testing.expect(false);
    try testing.expectEqual(JsonValue.Tag.int, prm_1);
    try testing.expectEqual(@as(i64, 2), prm_1.int);

    try testing.expect(impl.getParamByIndex(2) == null);
}

pub const Callback = fn (protocol_impl: *anyopaque) void;

pub const NamedCallback = struct {
    name: []const u8,
    callback: *const Callback,
    protocol_impl: *anyopaque = undefined,
};

pub const Engine = struct {
    callbacks: std.ArrayListUnmanaged(NamedCallback) = .{},
    allocator: mem.Allocator,

    fn deinit(e: *Engine) void {
        e.callbacks.deinit(e.allocator);
    }

    fn findAndCall(engine: Engine, protocol_impl: *anyopaque, name: []const u8) bool {
        const mcb = for (engine.callbacks.items) |*cb| {
            if (mem.eql(u8, cb.name, name)) break cb;
        } else null;
        var named_cb = mcb orelse return false;
        named_cb.callback(protocol_impl);
        return true;
    }

    fn parseAndRespond(engine: Engine, protocol_impl: anytype) !void {
        if (protocol_impl.parse(engine.allocator)) |err| {
            try protocol_impl.appendError(err);
            return;
        }
        try protocol_impl.startResponse();
        if (try protocol_impl.respond(engine, findAndCall)) |err|
            try protocol_impl.appendError(err);
        try protocol_impl.finishResponse();
    }
};

// FIXME: for now json_rpc uses this Stream type
const Fbs = std.io.FixedBufferStream([]u8);

pub fn appendResult(
    comptime fmt: []const u8,
    args: anytype,
    protocol_impl: *anyopaque,
) !void {
    const P = Protocol(Fbs.Reader, Fbs.Writer);
    const p: *P = @ptrCast(@alignCast(protocol_impl));
    switch (p.tag) {
        .json_rpc => try p.appendResult(fmt, args),
    }
}

pub fn appendError(
    err: Error,
    protocol_impl: *anyopaque,
) !void {
    const P = Protocol(Fbs.Reader, Fbs.Writer);
    const p: *P = @ptrCast(@alignCast(protocol_impl));
    switch (p.tag) {
        .json_rpc => try p.appendError(err),
    }
}

pub fn getParamByIndex(index: usize, protocol_impl: *anyopaque) ?JsonValue {
    const P = Protocol(Fbs.Reader, Fbs.Writer);
    const p: *P = @ptrCast(@alignCast(protocol_impl));

    return switch (p.tag) {
        .json_rpc => p.getParamByIndex(index),
    };
}

pub fn getParamByName(name: []const u8, protocol_impl: *anyopaque) ?JsonValue {
    const P = Protocol(Fbs.Reader, Fbs.Writer);
    const p: *P = @ptrCast(@alignCast(protocol_impl));

    return switch (p.tag) {
        .json_rpc => p.getParamByName(name),
    };
}

test {
    var e = Engine{ .allocator = talloc };
    defer e.deinit();

    try e.callbacks.append(e.allocator, .{
        .name = "sum",
        .callback = struct {
            fn func(protocol_impl: *anyopaque) void {
                var r: i64 = 0;
                var i: usize = 0;
                while (getParamByIndex(i, protocol_impl)) |param| : (i += 1) {
                    r += param.int;
                }
                appendResult("{}", .{r}, protocol_impl) catch
                    @panic("append response");
            }
        }.func,
    });

    try e.callbacks.append(e.allocator, .{
        .name = "sum_named",
        .callback = struct {
            fn func(protocol_impl: *anyopaque) void {
                const a = getParamByName("a", protocol_impl) orelse unreachable;
                const b = getParamByName("b", protocol_impl) orelse unreachable;
                appendResult("{}", .{a.int + b.int}, protocol_impl) catch
                    @panic("append response");
            }
        }.func,
    });

    try e.callbacks.append(e.allocator, .{
        .name = "subtract",
        .callback = struct {
            fn func(protocol_impl: *anyopaque) void {
                const a = getParamByIndex(0, protocol_impl) orelse unreachable;
                const b = getParamByIndex(1, protocol_impl) orelse unreachable;
                appendResult("{}", .{a.int - b.int}, protocol_impl) catch
                    @panic("append response");
            }
        }.func,
    });

    try e.callbacks.append(e.allocator, .{
        .name = "get_data",
        .callback = struct {
            fn func(protocol_impl: *anyopaque) void {
                appendResult(
                    \\["hello",5]
                , .{}, protocol_impl) catch
                    @panic("append response");
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
        // TODO
        // .{ // notifications
        //     \\{"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]}
        //     ,
        //     "",
        // },
        // .{
        //     \\{"jsonrpc": "2.0", "method": "foobar"}
        //     ,
        //     "",
        // },
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
            \\{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Missing 'id' field."},"id":null}
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
            // TODO notifications
            // \\    {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},
            \\    {"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},
            \\    {"foo": "boo"},
            \\    {"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},
            \\    {"jsonrpc": "2.0", "method": "get_data", "id": "9"} 
            \\]
            ,
            \\[{"jsonrpc":"2.0","result":7,"id":"1"},{"jsonrpc":"2.0","result":19,"id":"2"},{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid request. Missing 'jsonrpc' field."},"id":null},{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":"5"},{"jsonrpc":"2.0","result":["hello",5],"id":"9"}]
        },
        // TODO
        // .{ // rpc call Batch (all notifications)
        //     \\[
        //     \\    {"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]},
        //     \\    {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}
        //     \\]
        //     ,
        //     "",
        // },
    };

    for (input_expecteds) |ie| {
        const input, const expected = ie;
        var input_fbs = std.io.fixedBufferStream(input);
        var buf: [512]u8 = undefined;
        var output_fbs = std.io.fixedBufferStream(&buf);

        var impl = protocol(.json_rpc, input_fbs.reader(), output_fbs.writer());
        defer impl.deinit(talloc);
        try e.parseAndRespond(&impl);

        try testing.expectEqualStrings(expected, output_fbs.getWritten());
    }
}
