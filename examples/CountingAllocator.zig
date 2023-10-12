const std = @import("std");

const CountingAllocator = @This();

const Allocator = std.mem.Allocator;

const Timed = struct {
    num: usize = 0,
    time: u64 = 0,
};

parent_allocator: Allocator,
bytes_in_use: usize = 0,
total_bytes_allocated: usize = 0,
max_bytes_in_use: usize = 0,
allocs: Timed = .{},
frees: Timed = .{},
shrinks: Timed = .{},
expands: Timed = .{},
total_time: u64 = 0,
timings: bool,

pub fn init(parent_allocator: Allocator, options: struct { timings: bool = false }) CountingAllocator {
    return CountingAllocator{
        .parent_allocator = parent_allocator,
        .timings = options.timings,
    };
}

pub fn allocator(ca: *CountingAllocator) Allocator {
    return .{
        .ptr = ca,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    var timer: std.time.Timer = if (self.timings)
        std.time.Timer.start() catch unreachable
    else
        undefined;
    defer {
        if (self.timings) self.total_time += timer.read();
    }
    const result = self.parent_allocator.rawAlloc(len, log2_ptr_align, ra);
    if (result) |_| {
        self.allocs.time += if (self.timings) timer.read() else 0;
        self.allocs.num += 1;
        self.bytes_in_use += len;
        self.total_bytes_allocated += len;
        self.max_bytes_in_use = @max(self.bytes_in_use, self.max_bytes_in_use);
    } else {}
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, log2_old_align_u8: u8, new_len: usize, ra: usize) bool {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    var timer: std.time.Timer = if (self.timings)
        std.time.Timer.start() catch unreachable
    else
        undefined;
    if (self.parent_allocator.rawResize(buf, log2_old_align_u8, new_len, ra)) {
        const t = if (self.timings) timer.read() else 0;
        self.total_time += t;

        if (new_len == 0) {
            // free
            self.frees.time += t;
            self.frees.num += 1;
            self.bytes_in_use -= buf.len;
        } else if (new_len <= buf.len) {
            // shrink
            self.shrinks.time += t;
            self.shrinks.num += 1;
            self.bytes_in_use -= buf.len - new_len;
        } else {
            // expand
            self.expands.time += t;
            self.expands.num += 1;
            self.bytes_in_use += new_len - buf.len;
            self.total_bytes_allocated += new_len - buf.len;
            self.max_bytes_in_use = @max(self.bytes_in_use, self.max_bytes_in_use);
        }
        return true;
    } else {
        return false;
    }
}

pub fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ret_addr: usize) void {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    var timer: std.time.Timer = if (self.timings)
        std.time.Timer.start() catch unreachable
    else
        undefined;

    self.parent_allocator.rawFree(buf, log2_buf_align, ret_addr);
    if (self.timings) {
        const t = timer.read();
        self.total_time += t;
        self.frees.time += t;
    }
    self.frees.num += 1;
    self.bytes_in_use -= buf.len;
}

const fmt = "{s: <17}";

fn printTimed(
    timed: Timed,
    name: []const u8,
    comptime printfn: fn (comptime fmt: []const u8, args: anytype) void,
) void {
    printfn(fmt ++ "{d:.1}/{} (avg {d:.1})\n", .{
        name,
        std.fmt.fmtDuration(timed.time),
        timed.num,

        std.fmt.fmtDuration(if (timed.num == 0) timed.time else timed.time / timed.num),
    });
}

pub fn printSummary(
    ca: CountingAllocator,
    // precision: Precision,
    comptime printfn: fn (comptime fmt: []const u8, args: anytype) void,
) void {
    printfn("\n" ++ fmt ++ "{d:.1}\n", .{ "total_bytes_allocated", std.fmt.fmtIntSizeBin(ca.total_bytes_allocated) });
    printfn(fmt ++ "{d:.1}\n", .{ "bytes_in_use", std.fmt.fmtIntSizeBin(ca.bytes_in_use) });
    printfn(fmt ++ "{d:.1}\n", .{ "max_bytes_in_use", std.fmt.fmtIntSizeBin(ca.max_bytes_in_use) });
    printTimed(ca.allocs, "allocs", printfn);
    printTimed(ca.frees, "frees", printfn);
    printTimed(ca.shrinks, "shrinks", printfn);
    printTimed(ca.expands, "expands", printfn);
    // printTimed(ca.failures, "failures", printfn);
    printfn("total_time {}\n", .{std.fmt.fmtDuration(ca.total_time)});
}
