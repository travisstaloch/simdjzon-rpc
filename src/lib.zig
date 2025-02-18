const std = @import("std");
const testing = std.testing;
const talloc = testing.allocator;
const mem = std.mem;

const common = @import("common");
pub const Error = common.Error;
const simdjzon = @import("simdjzon");
const dom = simdjzon.dom;

pub const RpcInfo = struct {
    id: Id,
    method: []const u8,
    element: dom.Element = undefined,

    pub const Id = u64;
    pub const empty_id = std.math.maxInt(Id);
    pub const empty = RpcInfo{ .id = empty_id, .method = "" };

    // custom json parsing method
    pub fn jsonParse(doc: dom.Element, out: anytype, _: simdjzon.common.GetOptions) !void {
        if (try out.jsonParseImpl(doc)) |err| {
            std.log.err("{} - {s}", .{ err.code, err.note });
            return error.UserDefined;
        }
    }

    pub fn jsonParseImpl(out: *RpcInfo, doc: dom.Element) !?Error {
        out.element = doc;

        if (!doc.is(.OBJECT))
            return Error.init(
                .invalid_request,
                "The JSON sent is not a valid request object.",
            );
        const version = doc.at_key("jsonrpc") orelse
            return Error.init(.invalid_request, "Invalid request. Missing 'jsonrpc' field.");

        const invalid_version_error = Error.init(
            .invalid_request,
            "Invalid request. 'jsonrpc' field must equal '2.0'",
        );

        if (!version.is(.STRING)) return invalid_version_error;

        const version_string = version.get_string() catch unreachable;
        if (version_string.len != 3) return invalid_version_error;
        const version_int = mem.readInt(u24, version_string[0..3], .big);
        if (version_int != @intFromEnum(common.Version.two))
            return invalid_version_error;

        if (doc.at_key("id")) |id| {
            if (id.is(.STRING)) {
                out.id = id.get_string_uint64() catch
                    return Error.init(
                    .invalid_request,
                    "Invalid request. 'id' field is an invalid integer.",
                );
            } else if (id.is(.UINT64)) {
                out.id = id.get_uint64() catch unreachable;
            } else if (id.is(.INT64)) {
                out.id = std.math.cast(u64, id.get_int64() catch unreachable) orelse
                    return Error.init(
                    .invalid_request,
                    "Invalid request. 'id' field is an invalid integer.",
                );
            } else {
                return Error.init(
                    .invalid_request,
                    "Invalid request. 'id' must be an integer or string.",
                );
            }
        } else out.id = empty_id;

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

        out.method = try method.get_string();
        // std.debug.print("method={s} id={s}\n", .{ out.method, out.id });
        return null;
    }
};

test RpcInfo {
    const input_expecteds: []const struct { []const u8, common.RpcInfo } =
        &common.test_cases_1;

    for (input_expecteds) |ie| {
        const input, const expected = ie;
        var parser = try dom.Parser.initFixedBuffer(talloc, input, .{});
        defer parser.deinit();
        try parser.parse();

        var actual: RpcInfo = undefined;
        // std.debug.print("input={s}\n", .{input});
        try parser.element().get(&actual);
        try testing.expectEqualStrings(expected.method, actual.method);
        try testing.expectEqual(expected.id, actual.id);
    }
}

pub const Elements = union(enum) {
    null,
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

pub fn Rpc() type {
    return struct {
        parser: dom.Parser,
        info: RpcInfo = RpcInfo.empty,
        elements: Elements,
        flags: Flags = .{},
        reader: std.io.AnyReader,
        writer: Writer,

        pub const Reader = std.io.AnyReader;
        pub const Writer = std.io.BufferedWriter(4096, std.io.AnyWriter);
        pub const Flags = packed struct {
            is_first_response: bool = true,
            is_init: bool = false,
        };

        /// initialize a jsonrpc object with the given reader and writer
        pub fn init(reader: std.io.AnyReader, writer: std.io.AnyWriter) Rpc {
            return .{
                .reader = reader,
                .writer = std.io.bufferedWriter(writer),
                .elements = .{ .element = undefined },
                .parser = undefined,
            };
        }

        pub fn deinit(self: *Rpc) void {
            self.parser.deinit();
        }

        pub fn startResponse(self: *Rpc) !void {
            self.flags.is_first_response = true;
            if (self.elements == .array) try self.writer.writer().writeByte('[');
        }

        pub fn finishResponse(self: *Rpc) !void {
            if (self.elements == .array) {
                // instead of writing an empty array, skip flush and don't
                // write anything
                if (self.writer.end == 1 and self.writer.buf[0] == '[') {
                    // reset the writer - clear to make sure subsequent reused
                    // responses don't start with '['
                    self.writer.end = 0;
                    return;
                }
                try self.writer.writer().writeByte(']');
            }
            try self.writer.flush();
        }

        fn writeComma(self: *Rpc) !void {
            if (!self.flags.is_first_response) {
                if (self.elements == .array) try self.writer.writer().writeByte(',');
            } else self.flags.is_first_response = false;
        }

        /// write a jsonrpc result record to 'self.writer'
        pub fn writeResult(
            self: *Rpc,
            comptime fmt: []const u8,
            args: anytype,
        ) !void {
            if (self.info.id == RpcInfo.empty_id) return error.MissingId;
            try self.writeComma();

            try self.writer.writer().print(
                \\{{"jsonrpc":"2.0","result":
                ++ fmt ++
                    \\,"id":"{}"}}
            ,
                args ++ .{self.info.id},
            );
        }

        /// write a jsonrpc error record to 'self.writer'
        pub fn writeError(self: *Rpc, err: Error) !void {
            try self.writeComma();
            if (self.info.id == RpcInfo.empty_id)
                try self.writer.writer().print(
                    \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":null}}
                , .{ @intFromEnum(err.code), err.note })
            else
                try self.writer.writer().print(
                    \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":"{}"}}
                , .{ @intFromEnum(err.code), err.note, self.info.id });
        }

        /// read input from 'reader', init 'parser' and call parser.parse(),
        /// assign 'elements' field.
        /// note: initializes 'info' field to RpcInfo.empty.  if you want to
        /// manually initialize 'info', it can be done like this:
        /// `try self.info.jsonParseImpl(self.elements.element)`
        pub fn parse(self: *Rpc, allocator: mem.Allocator) ?Error {
            self.info = RpcInfo.empty;
            self.elements = .null;
            if (!self.flags.is_init) {
                self.parser = dom.Parser.initFromReader(allocator, self.reader, .{}) catch
                    return Error.init(@enumFromInt(-32000), "Out of memory");
                self.flags.is_init = true;
            } else {
                self.parser.initExistingFromReader(self.reader, .{}) catch
                    return Error.init(@enumFromInt(-32000), "Out of memory");
            }
            self.parser.parse() catch
                return Error.init(.parse_error, "Invalid JSON was received by the server.");

            const ele = self.parser.element();
            self.elements = if (ele.is(.ARRAY))
                .{ .array = ele.get_array() catch unreachable }
            else
                .{ .element = ele };
            return null;
        }

        /// return a 'params' object field with the given name if it exists
        pub fn getParamByName(self: *Rpc, name: []const u8) ?JsonValue {
            const params = self.info.element.at_key("params") orelse
                return null;
            return JsonValue.init(params.at_key(name) orelse return null);
        }

        /// return a 'params' array element at the given index if it exists
        pub fn getParamByIndex(self: *Rpc, index: usize) ?JsonValue {
            const params = self.info.element.at_key("params") orelse
                return null;
            const arr = params.get_array() catch return null;
            return JsonValue.init(arr.at(index) orelse return null);
        }

        pub fn respond(
            self: *Rpc,
            engine: common.Engine,
            find_and_call: *const common.FindAndCall,
        ) !?Error {
            switch (self.elements) {
                .null => {},
                .array => |array| {
                    var i: usize = 0;
                    while (array.at(i)) |ele| : (i += 1) {
                        self.info = RpcInfo.empty;
                        if (!ele.is(.OBJECT)) {
                            try self.writeError(Error.init(.invalid_request, "Invalid request. Not an object."));
                            continue;
                        }
                        if (try self.info.jsonParseImpl(ele)) |err| {
                            try self.writeError(err);
                            continue;
                        }

                        if (!find_and_call(
                            engine,
                            self,
                            self.info.method,
                        )) {
                            if (self.info.id != RpcInfo.empty_id)
                                try self.writeError(Error.init(.method_not_found, "Method not found"));
                        }
                    }
                    if (i == 0)
                        return Error.init(.invalid_request, "Invalid request. Empty array.");
                },
                .element => |element| {
                    if (try self.info.jsonParseImpl(element)) |err|
                        return err;
                    if (!find_and_call(
                        engine,
                        self,
                        self.info.method,
                    )) {
                        if (self.info.id != RpcInfo.empty_id)
                            return Error.init(.method_not_found, "Method not found");
                    }
                },
            }
            return null;
        }
    };
}

test "named params" {
    var input_fbs = std.io.fixedBufferStream(
        \\{"jsonrpc": "2.0", "method": "sum", "params": {"a": 1, "b": 2}, "id": 1}
    );
    var buf: [256]u8 = undefined;
    var output_fbs = std.io.fixedBufferStream(&buf);

    var rpc = Rpc.init(input_fbs.reader().any(), output_fbs.writer().any());
    defer rpc.deinit();
    const merr = rpc.parse(talloc);
    try testing.expect(merr == null);
    _ = try rpc.info.jsonParseImpl(rpc.elements.element);

    const prm_a = rpc.getParamByName("a") orelse return testing.expect(false);
    try testing.expect(prm_a == .int);
    try testing.expectEqual(@as(i64, 1), prm_a.int);

    const prm_b = rpc.getParamByName("b") orelse return testing.expect(false);
    try testing.expect(prm_b == .int);
    try testing.expectEqual(@as(i64, 2), prm_b.int);

    try testing.expect(rpc.getParamByName("c") == null);
}

test "indexed params" {
    var input_fbs = std.io.fixedBufferStream(
        \\{"jsonrpc": "2.0", "method": "sum", "params": [1,2], "id": 1}
    );
    var buf: [256]u8 = undefined;
    var output_fbs = std.io.fixedBufferStream(&buf);

    var rpc = Rpc.init(input_fbs.reader().any(), output_fbs.writer().any());
    defer rpc.deinit();
    const merr = rpc.parse(talloc);
    try testing.expect(merr == null);
    _ = try rpc.info.jsonParseImpl(rpc.elements.element);

    const prm_0 = rpc.getParamByIndex(0) orelse return testing.expect(false);
    try testing.expect(prm_0 == .int);
    try testing.expectEqual(@as(i64, 1), prm_0.int);

    const prm_1 = rpc.getParamByIndex(1) orelse return testing.expect(false);
    try testing.expect(prm_1 == .int);
    try testing.expectEqual(@as(i64, 2), prm_1.int);

    try testing.expect(rpc.getParamByIndex(2) == null);
}

pub fn setupTestEngine(e: *common.Engine) !void {
    try e.putCallback(.{
        .name = "sum",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                var r: i64 = 0;
                var i: usize = 0;
                const rpc: *Rpc = @alignCast(@ptrCast(rpc_ptr));
                while (rpc.getParamByIndex(i)) |param| : (i += 1) {
                    r += param.int;
                }
                rpc.writeResult("{}", .{r}) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "sum_named",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                const rpc: *Rpc = @alignCast(@ptrCast(rpc_ptr));
                const a = rpc.getParamByName("a") orelse unreachable;
                const b = rpc.getParamByName("b") orelse unreachable;
                rpc.writeResult("{}", .{a.int + b.int}) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "subtract",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                const rpc: *Rpc = @alignCast(@ptrCast(rpc_ptr));
                const a = rpc.getParamByIndex(0) orelse unreachable;
                const b = rpc.getParamByIndex(1) orelse unreachable;
                rpc.writeResult("{}", .{a.int - b.int}) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "get_data",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                const rpc: *Rpc = @alignCast(@ptrCast(rpc_ptr));
                rpc.writeResult(
                    \\["hello",5]
                , .{}) catch
                    @panic("write failed");
            }
        }.func,
    });
}

test {
    var e = common.Engine{ .allocator = talloc };
    defer e.deinit();
    try setupTestEngine(&e);

    for (common.test_cases_2) |ie| {
        const input, const expected = ie;
        var input_fbs = std.io.fixedBufferStream(input);
        var buf: [512]u8 = undefined;
        var output_fbs = std.io.fixedBufferStream(&buf);

        var rpc = Rpc.init(input_fbs.reader().any(), output_fbs.writer().any());
        defer rpc.deinit();
        try e.parseAndRespond(&rpc);
        try testing.expectEqualStrings(expected, output_fbs.getWritten());
    }
}
