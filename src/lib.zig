const std = @import("std");
const testing = std.testing;
const talloc = testing.allocator;
const mem = std.mem;
const simdjzon = @import("simdjzon");
const dom = simdjzon.dom;

const json_pointer_capacity = 256;

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
};

pub const RpcObject = struct {
    id_buf: [json_pointer_capacity]u8 = undefined,
    id: []const u8,
    method_name: []const u8,
    element: dom.Element = undefined,

    pub fn jsonParse(doc: dom.Element, args: anytype) !void {
        const out = args[0];
        if (try out.jsonParseImpl(doc)) |err| {
            std.log.err("{} - {s}", .{ err.code, err.note });
            return error.UserDefined;
        }
    }

    pub fn jsonParseImpl(out: *RpcObject, doc: dom.Element) !?Error {
        if (!doc.is(.OBJECT))
            return Error.init(
                .invalid_request,
                "The JSON sent is not a valid request object.",
            );

        const version = doc.at_key("jsonrpc") orelse
            return Error.init(.invalid_request, "Missing 'jsonrpc' field.");

        if (!version.is(.STRING) or !mem.eql(u8, "2.0", try version.get_string()))
            return Error.init(
                .invalid_request,
                "The request 'version' field must be '2.0'",
            );

        const id = doc.at_key("id") orelse
            return Error.init(.invalid_request, "Missing 'id' field.");

        const id_invalid = (id.is(.DOUBLE) and !id.is(.INT64) and !id.is(.UINT64)) or
            id.is(.OBJECT) or id.is(.ARRAY);
        if (id_invalid)
            return Error.init(
                .invalid_request,
                "Request 'id' must be an integer or string.",
            );

        const method = doc.at_key("method") orelse
            return Error.init(.invalid_request, "Missing 'method' field.");

        if (!method.is(.STRING))
            return Error.init(.invalid_request, "'method' field must be a string.");

        const params_present_and_valid = if (doc.at_key("params")) |params|
            params.is(.ARRAY) or params.is(.OBJECT)
        else
            false;

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
        return null;
    }
};

fn checkField(
    comptime field_name: []const u8,
    expected: RpcObject,
    actual: RpcObject,
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

test RpcObject {
    // some test cases from https://www.jsonrpc.org/specification
    const input_expecteds = [_]struct { []const u8, RpcObject }{
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

        var actual: RpcObject = undefined;
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

pub const AnyParam = union(enum) {
    null,
    bool: bool,
    int: i64,
    double: f64,
    string: []const u8,

    pub fn init(x: void) !AnyParam {
        _ = x;
        unreachable;
    }
};

pub fn ProtocolJsonRpc(comptime T: type, comptime R: type, comptime W: type) type {
    return struct {
        base: T,
        rpc_object: RpcObject = .{ .id = &.{}, .method_name = &.{} },
        elements: Elements,
        reader: Reader,
        writer: Writer,
        parser: dom.Parser,
        input: []const u8 = &.{},
        active_request: RpcObject,

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

        pub fn appendResponse(self: *Self, response: []const u8, writer: W) !void {
            _ = response;
            _ = writer;
            _ = self;
            unreachable;
        }

        pub fn appendError(self: *Self, error_code: []const u8, message: []const u8, writer: W) !void {
            _ = message;
            _ = error_code;
            _ = writer;
            _ = self;
            unreachable;
        }

        pub fn parseContent(self: *Self, allocator: mem.Allocator) ?Error {
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

        pub fn getParam(self: *Self, name: []const u8) !AnyParam {
            var buf: [json_pointer_capacity]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();
            const has_slash = name.len != 0 and name[0] == '/';
            _ = try writer.write(if (has_slash) "/params" else "/params/");
            _ = try writer.write(name);

            return AnyParam.init(self.active_request.element.at_pointer(fbs.getWritten()));
        }

        pub fn populateResponse(
            self: *Self,
            engine: *const anyopaque,
            find_and_call: *const fn (*const anyopaque, dom.Element, []const u8) bool,
        ) !?Error {
            switch (self.elements) {
                .array => {
                    var i: usize = 0;
                    while (self.elements.array.at(i)) |e| : (i += 1) {
                        _ = try self.active_request.jsonParseImpl(e);
                        if (!find_and_call(engine, e, self.active_request.method_name)) {
                            return Error.init(.method_not_found, "Method not found");
                        }
                    }
                },
                .element => {
                    _ = try self.active_request.jsonParseImpl(self.elements.element);
                    if (!find_and_call(engine, self.elements.element, self.active_request.method_name)) {
                        return Error.init(.method_not_found, "Method not found");
                    }
                },
            }
            return null;
        }
    };
}

pub fn protocolJsonRpc(
    x: anytype,
    reader: anytype,
    writer: anytype,
) ProtocolJsonRpc(@TypeOf(x), @TypeOf(reader), @TypeOf(writer)) {
    return .{
        .base = x,
        .elements = undefined,
        .parser = undefined,
        .active_request = undefined,
        .reader = reader,
        .writer = writer,
    };
}

pub const Callback = fn (doc: dom.Element, out: ?*anyopaque) void;

pub const NamedCallback = struct {
    name: []const u8,
    output_buf: [2]usize = undefined,
    callback: *const Callback,

    pub fn outputAs(nc: *const NamedCallback, comptime T: type) T {
        const t: *const T = @ptrCast(&nc.output_buf);
        return t.*;
    }
};

pub const Engine = struct {
    callbacks: std.ArrayListUnmanaged(NamedCallback) = .{},
    allocator: mem.Allocator,

    fn deinit(e: *Engine) void {
        e.callbacks.deinit(e.allocator);
    }

    fn findAndCall(_e: *const anyopaque, ele: dom.Element, name: []const u8) bool {
        const e: *const Engine = @ptrCast(@alignCast(_e));
        const mcb = for (e.callbacks.items) |*cb| {
            if (mem.eql(u8, cb.name, name)) break cb;
        } else null;
        var named_cb = mcb orelse return false;
        named_cb.callback(ele, &named_cb.output_buf);
        return true;
    }

    fn raiseRequest(engine: *const Engine, protocol: anytype) !void {
        if (protocol.parseContent(engine.allocator)) |e| {
            std.log.err("{} - {s}", .{ e.code, e.note });
            return error.UserDefined;
            // TODO ucall_call_reply_error()
        }
        try protocol.startResponse();
        const merr = try protocol.populateResponse(
            engine,
            findAndCall,
        );
        if (merr) |err| {
            _ = err;
            // TODO ucall_call_reply_error()
            unreachable;
        }
        try protocol.finishResponse();
    }
};

test {
    var input_fbs = std.io.fixedBufferStream(
        \\{"jsonrpc": "2.0", "method": "add", "params": [1,2,3], "id": 1}
    );
    var buf: [256]u8 = undefined;
    var output_fbs = std.io.fixedBufferStream(&buf);

    var rpc = protocolJsonRpc({}, input_fbs.reader(), output_fbs.writer());
    defer rpc.deinit(talloc);
    var e = Engine{ .allocator = talloc };
    defer e.deinit();
    try e.callbacks.append(e.allocator, .{
        .name = "add",
        .callback = struct {
            fn func(doc: dom.Element, _out: ?*anyopaque) void {
                const ele = doc.at_key("params") orelse unreachable;
                var r: i64 = 0;
                var i: usize = 0;
                while (ele.at(i)) |param| : (i += 1) {
                    r += param.get_int64() catch @panic("param not an integer");
                }
                const out: *i64 = @ptrCast(@alignCast(_out));
                out.* = r;
            }
        }.func,
    });

    try e.raiseRequest(&rpc);
    try testing.expectEqual(@as(u64, 6), e.callbacks.items[0].outputAs(u64));
}
