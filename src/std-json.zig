const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const talloc = testing.allocator;
const json = std.json;
const common = @import("common");
const Error = common.Error;

pub fn Request(comptime Params: type) type {
    // TODO support Params != json.Value
    return struct {
        id: Id,
        jsonrpc: []const u8, // TODO make this a u24
        method: []const u8,
        params: if (Params == json.Value) json.Value else ?Params,
        _error: []const u8,

        const Self = @This();
        pub const Id = u64;
        pub const empty_id = std.math.maxInt(Id);
        pub const empty = Self{
            .id = empty_id,
            .jsonrpc = "",
            .method = "",
            .params = if (Params == json.Value) .null else null,
            ._error = "",
        };

        pub fn format(
            req: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            try writer.print(
                \\"jsonrpc":"{s}","method":"{s}","id":"{}","params":{}"
            ,
                .{ req.jsonrpc, req.method, req.id, req.params },
            );
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            scanner: *json.Scanner,
            options: json.ParseOptions,
        ) !Self {
            var result = empty;
            const FieldEnum = std.meta.FieldEnum(Self);

            // first token must be object begin.
            if (try scanner.next() != .object_begin) {
                // instead of retuning an error, set the _error field.  this
                // allows for error reporting in arrays
                result._error = "Invalid request. Not an object.";
                return result;
            }

            while (true) {
                const token_type = try scanner.peekNextTokenType();
                switch (token_type) {
                    .object_end => {
                        _ = try scanner.next();
                        return result;
                    },
                    .end_of_document => {
                        _ = try scanner.next();
                        return result;
                    },
                    .string => {
                        const name_token: ?json.Token = try scanner.nextAllocMax(
                            allocator,
                            .alloc_if_needed,
                            options.max_value_len.?,
                        );
                        const field_name = switch (name_token.?) {
                            inline .string, .allocated_string => |slice| slice,
                            .object_end => break,
                            else => return error.UnexpectedToken,
                        };

                        const field = std.meta.stringToEnum(FieldEnum, field_name) orelse {
                            // invalid field. skip until object end
                            while (try scanner.next() != .object_end) {}
                            return result;
                        };

                        const next = try scanner.peekNextTokenType();

                        switch (field) {
                            inline .jsonrpc, .method => |tag| {
                                @field(result, @tagName(tag)) = json.innerParse(
                                    []const u8,
                                    allocator,
                                    scanner,
                                    options,
                                ) catch {
                                    _ = try scanner.next();
                                    continue;
                                };
                            },
                            .id => switch (next) {
                                .string => {
                                    const id = try json.innerParse(
                                        []const u8,
                                        allocator,
                                        scanner,
                                        options,
                                    );
                                    result.id =
                                        try std.fmt.parseUnsigned(Id, id, 10);
                                },
                                .number => {
                                    result.id = try json.innerParse(
                                        Id,
                                        allocator,
                                        scanner,
                                        options,
                                    );
                                },
                                else => return error.UnexpectedToken,
                            },
                            .params => result.params = try json.innerParse(
                                Params,
                                allocator,
                                scanner,
                                options,
                            ),
                            ._error => return error.UnknownField,
                        }
                    },
                    else => return error.UnexpectedToken,
                }
            }
            unreachable;
        }
    };
}

fn checkField(
    comptime field_name: []const u8,
    expected: anytype,
    actual: json.Value,
    input: []const u8,
) !void {
    const ex = @field(expected, field_name);
    const ac = actual.object.get(field_name) orelse
        return error.TestUnxpectedResult;
    if (comptime common.isZigString(@TypeOf(ex))) {
        testing.expectEqualStrings(ex, ac.string) catch |e| {
            std.log.err("field '{s}' expected '{s}' actual '{s}'", .{ field_name, ex, ac.string });
            std.log.err("input={s}", .{input});
            return e;
        };
    } else {
        testing.expectEqual(@as(@TypeOf(ac.integer), ex), ac.integer) catch |e| {
            std.log.err("field '{s}' expected '{}' actual '{}'", .{ field_name, ex, ac });
            std.log.err("input={s}", .{input});
            return e;
        };
    }
}

test {
    inline for (common.test_cases_1) |ie| {
        const input, const expected = ie;
        const actual = try json.parseFromSlice(json.Value, talloc, input, .{});
        defer actual.deinit();
        try checkField("id", expected, actual.value, input);
        try checkField("method", expected, actual.value, input);
    }
}

fn RpcImpl(comptime R: type, comptime W: type) type {
    return struct {
        req: Req,
        current_req: SingleRequest = SingleRequest.empty,
        input: std.ArrayListUnmanaged(u8) = .{},
        arena: *std.heap.ArenaAllocator,
        flags: Flags = .{},
        // TODO use AnyReader/Writer so that this type won't need to be generic
        reader: Reader,
        writer: Writer,

        pub const Reader = R;
        pub const Writer = std.io.BufferedWriter(std.mem.page_size, W);
        pub const SingleRequest = Request(json.Value);
        const Self = @This();

        pub const Req = union(enum) {
            object: SingleRequest,
            array: []const SingleRequest,
            null,

            pub fn jsonParse(
                allocator: std.mem.Allocator,
                scanner: *json.Scanner,
                options: json.ParseOptions,
            ) !Req {
                return switch (try scanner.peekNextTokenType()) {
                    .object_begin => .{ .object = json.parseFromTokenSourceLeaky(
                        SingleRequest,
                        allocator,
                        scanner,
                        options,
                    ) catch SingleRequest.empty },
                    .array_begin => blk: {
                        const result = .{
                            .array = try json.parseFromTokenSourceLeaky(
                                []const SingleRequest,
                                allocator,
                                scanner,
                                options,
                            ),
                        };
                        if (try scanner.next() != .end_of_document)
                            return error.UnexpectedToken;
                        break :blk result;
                    },
                    else => .null,
                };
            }
        };

        pub const Flags = packed struct {
            is_first_response: bool = true,
            is_init: bool = false,
        };

        pub fn deinit(self: *Self, allocator: mem.Allocator) void {
            self.input.deinit(allocator);
            if (self.flags.is_init) {
                self.arena.deinit();
                allocator.destroy(self.arena);
            }
        }

        pub fn startResponse(self: *Self) !void {
            self.flags.is_first_response = true;
            if (self.req == .array)
                try self.writer.writer().writeByte('[');
        }

        pub fn finishResponse(self: *Self) !void {
            if (self.req == .array) {
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

        fn writeComma(self: *Self) !void {
            if (!self.flags.is_first_response) {
                if (self.req == .array) try self.writer.writer().writeByte(',');
            } else self.flags.is_first_response = false;
        }

        /// write a jsonrpc result record to 'self.writer'
        pub fn writeResult(
            self: *Self,
            comptime fmt: []const u8,
            args: anytype,
        ) !void {
            if (self.current_req.id != SingleRequest.empty_id) {
                try self.writeComma();
                try self.writer.writer().print(
                    \\{{"jsonrpc":"2.0","result":
                    ++ fmt ++
                        \\,"id":"{}"}}
                ,
                    args ++ .{self.current_req.id},
                );
            } else return error.MissingId;
        }

        /// write a jsonrpc error record to 'self.writer'
        pub fn writeError(self: *Self, err: Error) !void {
            try self.writeComma();
            if (self.current_req.id != SingleRequest.empty_id) {
                try self.writer.writer().print(
                    \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":"{}"}}
                , .{ @intFromEnum(err.code), err.note, self.current_req.id });
                return;
            }
            try self.writer.writer().print(
                \\{{"jsonrpc":"2.0","error":{{"code":{},"message":"{s}"}},"id":null}}
            , .{ @intFromEnum(err.code), err.note });
        }

        fn checkRequest(req: SingleRequest) ?Error {
            if (req._error.len != 0)
                return Error.init(.invalid_request, req._error);

            if (req.jsonrpc.len == 0)
                return Error.init(
                    .invalid_request,
                    "Invalid request. Missing 'jsonrpc' field.",
                );
            if (!mem.eql(u8, req.jsonrpc, "2.0"))
                return Error.init(
                    .invalid_request,
                    "Invalid request. 'jsonrpc' field must be '2.0'.",
                );

            if (req.method.len == 0)
                return Error.init(
                    .invalid_request,
                    "Invalid request. 'method' field must be a string.",
                );
            return null;
        }

        /// read input from 'reader', init 'parsed' from json.parseFromSlice().
        pub fn parse(self: *Self, allocator: mem.Allocator) ?Error {
            self.req = .null;
            self.current_req = SingleRequest.empty;
            // read input
            self.input.items.len = 0;
            var l = self.input.toManaged(allocator);
            self.reader.readAllArrayList(&l, std.math.maxInt(u32)) catch
                return Error.init(@enumFromInt(-32000), "Out of memory");
            self.input.items = l.items;
            self.input.capacity = l.capacity;

            if (!self.flags.is_init) {
                self.arena = allocator.create(std.heap.ArenaAllocator) catch
                    return Error.init(@enumFromInt(-32000), "Out of memory");
                self.arena.* = std.heap.ArenaAllocator.init(allocator);
                self.flags.is_init = true;
            } else {
                _ = self.arena.reset(.retain_capacity);
            }

            // parse json
            self.req = json.parseFromSliceLeaky(
                Req,
                self.arena.allocator(),
                self.input.items,
                .{},
            ) catch return Error.init(
                .parse_error,
                "Invalid JSON was received by the server.",
            );

            switch (self.req) {
                .object, .array => {},
                else => return Error.init(
                    .parse_error,
                    "Invalid JSON was received by the server.",
                ),
            }
            return null;
        }

        pub fn getParamByName(self: *Self, name: []const u8) ?json.Value {
            const params = self.current_req.params;
            if (params != .object) return null;
            return params.object.get(name);
        }

        pub fn getParamByIndex(self: *Self, index: usize) ?json.Value {
            const params = self.current_req.params;
            if (params != .array) return null;

            return if (index >= params.array.items.len)
                null
            else
                params.array.items[index];
        }

        const FindAndCall = @TypeOf(common.Engine.findAndCall);

        pub fn respond(
            self: *Self,
            engine: common.Engine,
            find_and_call: *const FindAndCall,
        ) !?Error {
            switch (self.req) {
                .array => |array| {
                    for (array) |ele| {
                        self.current_req = ele;
                        if (checkRequest(ele)) |err| {
                            try self.writeError(err);
                            continue;
                        }

                        if (ele.method.len != 0) {
                            if (!find_and_call(engine, self, ele.method)) {
                                if (ele.id != SingleRequest.empty_id)
                                    try self.writeError(Error.init(
                                        .method_not_found,
                                        "Method not found",
                                    ));
                            }
                        } else try self.writeError(Error.init(
                            .invalid_request,
                            "Method missing",
                        ));
                    }
                    if (array.len == 0) return Error.init(
                        .invalid_request,
                        "Invalid request. Empty array.",
                    );
                },
                .object => |object| {
                    self.current_req = object;
                    if (checkRequest(object)) |err| return err;

                    if (!find_and_call(engine, self, object.method)) {
                        if (object.id != SingleRequest.empty_id)
                            return Error.init(
                                .method_not_found,
                                "Method not found",
                            );
                    }
                },
                .null => try self.writeError(Error.init(
                    .invalid_request,
                    "Invalid request. Not an object.",
                )),
            }
            return null;
        }
    };
}

/// exposes user facing type erased methods
pub fn Rpc(comptime R: type, comptime W: type) type {
    return struct {
        pub const TypedRpc = RpcImpl(R, W);

        /// initialize a jsonrpc object with the given reader and writer
        pub fn init(reader: R, writer: W) TypedRpc {
            return .{
                .reader = reader,
                .writer = std.io.bufferedWriter(writer),
                .req = .null,
                .arena = undefined,
            };
        }

        /// write a jsonrpc result record
        pub fn writeResult(
            comptime fmt: []const u8,
            args: anytype,
            rpc_ptr: *anyopaque,
        ) !void {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_ptr));
            try rpc.writeResult(fmt, args);
        }

        /// write a jsonrpc error record
        pub fn writeError(
            err: Error,
            rpc_ptr: *anyopaque,
        ) !void {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_ptr));
            try rpc.writeError(err);
        }

        /// return a 'params' array element at the given index if it exists
        pub fn getParamByIndex(index: usize, rpc_ptr: *anyopaque) ?json.Value {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_ptr));
            return rpc.getParamByIndex(index);
        }

        /// return a 'params' object field with the given name if it exists
        pub fn getParamByName(name: []const u8, rpc_ptr: *anyopaque) ?json.Value {
            const rpc: *TypedRpc = @ptrCast(@alignCast(rpc_ptr));
            return rpc.getParamByName(name);
        }
    };
}

const JsonValueTag = std.meta.Tag(json.Value);
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
    rpc.current_req = rpc.req.object;
    const prm_a = rpc.getParamByName("a") orelse return error.TestUnxpectedResult;
    try testing.expect(prm_a == .integer);
    try testing.expectEqual(@as(i64, 1), prm_a.integer);

    const prm_b = rpc.getParamByName("b") orelse return error.TestUnxpectedResult;
    try testing.expect(prm_b == .integer);
    try testing.expectEqual(@as(i64, 2), prm_b.integer);

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
    rpc.current_req = rpc.req.object;
    const prm_0 = rpc.getParamByIndex(0) orelse return error.TestUnxpectedResult;

    try testing.expect(prm_0 == .integer);
    try testing.expectEqual(@as(i64, 1), prm_0.integer);

    const prm_1 = rpc.getParamByIndex(1) orelse return error.TestUnxpectedResult;
    try testing.expect(prm_1 == .integer);
    try testing.expectEqual(@as(i64, 2), prm_1.integer);

    try testing.expect(rpc.getParamByIndex(2) == null);
}

pub fn setupTestEngine(e: *common.Engine, comptime RpcType: type) !void {
    _ = RpcType;
    try e.putCallback(.{
        .name = "sum",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                var r: i64 = 0;
                var i: usize = 0;
                while (FbsRpc.getParamByIndex(i, rpc_ptr)) |param| : (i += 1) {
                    r += param.integer;
                }
                FbsRpc.writeResult("{}", .{r}, rpc_ptr) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "sum_named",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                const a = FbsRpc.getParamByName("a", rpc_ptr) orelse unreachable;
                const b = FbsRpc.getParamByName("b", rpc_ptr) orelse unreachable;
                FbsRpc.writeResult("{}", .{a.integer + b.integer}, rpc_ptr) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "subtract",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                const a = FbsRpc.getParamByIndex(0, rpc_ptr) orelse unreachable;
                const b = FbsRpc.getParamByIndex(1, rpc_ptr) orelse unreachable;
                FbsRpc.writeResult("{}", .{a.integer - b.integer}, rpc_ptr) catch
                    @panic("write failed");
            }
        }.func,
    });

    try e.putCallback(.{
        .name = "get_data",
        .callback = struct {
            fn func(rpc_ptr: *anyopaque) void {
                FbsRpc.writeResult(
                    \\["hello",5]
                , .{}, rpc_ptr) catch
                    @panic("write failed");
            }
        }.func,
    });
}

test {
    var e = common.Engine{ .allocator = talloc };
    defer e.deinit();
    try setupTestEngine(&e, FbsRpc);

    for (common.test_cases_2) |ie| {
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
