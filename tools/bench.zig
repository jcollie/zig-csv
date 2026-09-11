// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Throughput benchmarks for the CSV tokenizer.
//!
//! Each case generates a body of CSV in memory, tokenizes it repeatedly, and
//! reports bytes per second. The point is not the absolute number, which says
//! as much about the machine as the code, but the spread between cases: a
//! shape that is much slower than its neighbours is where the work is going.
//!
//! Usage: bench [--seconds N] [--buffer N] [--case NAME]

const std = @import("std");
const csv = @import("csv");

const Allocator = std.mem.Allocator;

const Case = struct {
    name: []const u8,
    description: []const u8,
    generate: *const fn (gpa: Allocator, rows: usize) anyerror![]u8,
};

const cases = [_]Case{
    .{ .name = "plain", .description = "short unquoted fields, LF", .generate = genPlain },
    .{ .name = "plain-crlf", .description = "same, CRLF terminated", .generate = genPlainCrlf },
    .{ .name = "wide", .description = "32 short columns per row", .generate = genWide },
    .{ .name = "long-fields", .description = "few columns, 200-byte fields", .generate = genLongFields },
    .{ .name = "quoted", .description = "every field quoted", .generate = genQuoted },
    .{ .name = "quoted-escapes", .description = "quoted, with doubled quotes", .generate = genQuotedEscapes },
    .{ .name = "empty-fields", .description = "mostly empty fields", .generate = genEmptyFields },
    .{ .name = "one-column", .description = "a single column, so mostly terminators", .generate = genOneColumn },
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    // 0.16 has no free-standing clock (`.awake` is the monotonic one): timing comes from the `Io` handed to
    // `main`, rather than being reached for.
    const io = init.io;

    var seconds: f64 = 1.0;
    var buffer_len: usize = 64 * 1024;
    var only: ?[]const u8 = null;
    var rows: usize = 20_000;
    var col_sep: u8 = ',';
    var quote: u8 = '"';
    var strict = false;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seconds")) {
            seconds = try std.fmt.parseFloat(f64, args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--buffer")) {
            buffer_len = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            rows = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--col-sep")) {
            col_sep = (args.next() orelse return error.MissingValue)[0];
        } else if (std.mem.eql(u8, arg, "--quote")) {
            quote = (args.next() orelse return error.MissingValue)[0];
        } else if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, arg, "--case")) {
            only = args.next() orelse return error.MissingValue;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    // Built from parsed arguments so the optimizer cannot see through it.
    const config: csv.CsvConfig = .{
        .col_sep = col_sep,
        .row_sep = if (strict) .crlf else .any,
        .quote = quote,
    };

    std.debug.print("buffer {d} bytes, {d:.1}s per case\n\n", .{ buffer_len, seconds });
    std.debug.print("{s:<16} {s:>10} {s:>12} {s:>10} {s:>9}  {s}\n", .{
        "case", "size", "MB/s", "ns/field", "fields", "shape",
    });

    for (cases) |case| {
        if (only) |name| {
            if (!std.mem.eql(u8, name, case.name)) continue;
        }

        const data = try case.generate(gpa, rows);
        defer gpa.free(data);

        const buffer = try gpa.alloc(u8, buffer_len);
        defer gpa.free(buffer);

        // One pass first, both to warm the caches and to count the fields.
        const fields = try run(data, buffer, config);

        const budget: i96 = @intFromFloat(seconds * std.time.ns_per_s);
        const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
        var passes: u64 = 0;
        var elapsed: i96 = 0;
        while (elapsed < budget) : (passes += 1) {
            _ = try run(data, buffer, config);
            elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - started;
        }

        const bytes: f64 = @floatFromInt(data.len * passes);
        const nanos: f64 = @floatFromInt(elapsed);
        const mb_per_s = bytes / (nanos / std.time.ns_per_s) / (1024 * 1024);
        const ns_per_field = nanos / @as(f64, @floatFromInt(fields * passes));

        std.debug.print("{s:<16} {d:>9}K {d:>12.1} {d:>10.2} {d:>9}  {s}\n", .{
            case.name, data.len / 1024, mb_per_s, ns_per_field, fields, case.description,
        });
    }
}

/// Tokenize the whole input, returning how many fields came out. The token
/// is consumed so the loop cannot be optimized away.
///
/// The configuration is a parameter rather than a literal on purpose. Written
/// as `.{}` here it is comptime-known, and the optimizer folds it right
/// through `init` into the scan -- which measures constant folding rather
/// than the tokenizer a real caller gets.
fn run(data: []const u8, buffer: []u8, config: csv.CsvConfig) !usize {
    var reader: std.Io.Reader = .fixed(data);
    var tokenizer = try csv.CsvTokenizer.init(&reader, buffer, config);

    var fields: usize = 0;
    while (try tokenizer.next()) |token| {
        switch (token) {
            .field => |value| {
                fields += 1;
                std.mem.doNotOptimizeAway(value.len);
            },
            .row_end => {},
        }
    }
    return fields;
}

fn genPlain(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..rows) |i| {
        try out.print(gpa, "{d},abcdefghijkl,{d:0>10},mnopqrs,{d:0>20},tuvwx\n", .{ i, i, i });
    }
    return out.toOwnedSlice(gpa);
}

fn genPlainCrlf(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..rows) |i| {
        try out.print(gpa, "{d},abcdefghijkl,{d:0>10},mnopqrs,{d:0>20},tuvwx\r\n", .{ i, i, i });
    }
    return out.toOwnedSlice(gpa);
}

fn genWide(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..rows) |i| {
        for (0..32) |c| {
            if (c != 0) try out.append(gpa, ',');
            try out.print(gpa, "{d}", .{(i + c) % 1000});
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn genLongFields(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const filler = "x" ** 200;
    for (0..rows) |i| {
        try out.print(gpa, "{d},{s},{s}\n", .{ i, filler, filler });
    }
    return out.toOwnedSlice(gpa);
}

fn genQuoted(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..rows) |i| {
        try out.print(gpa, "\"{d}\",\"abcdefghijkl\",\"{d:0>10}\",\"mnopqrs\",\"tuvwx\"\n", .{ i, i });
    }
    return out.toOwnedSlice(gpa);
}

fn genQuotedEscapes(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..rows) |i| {
        try out.print(gpa, "\"{d}\",\"a\"\"b\"\"c\",\"say \"\"hello\"\" now\",\"tuvwx\"\n", .{i});
    }
    return out.toOwnedSlice(gpa);
}

fn genEmptyFields(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..rows) |_| {
        try out.appendSlice(gpa, ",,,,,,,,,,,,,,,\n");
    }
    return out.toOwnedSlice(gpa);
}

fn genOneColumn(gpa: Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..rows) |i| {
        try out.print(gpa, "{d}\n", .{i % 100});
    }
    return out.toOwnedSlice(gpa);
}

test "every case generates parseable data" {
    const gpa = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    for (cases) |case| {
        const data = try case.generate(gpa, 8);
        defer gpa.free(data);
        const fields = try run(data, &buffer, .{});
        try std.testing.expect(fields > 0);
    }
}
