//  Copyright (c) 2021 beho
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const csv_mod = @import("csv");

fn getTokenizer(reader: *std.Io.Reader, buffer: []u8, config: csv_mod.CsvConfig) !csv_mod.CsvTokenizer {
    const csv = try csv_mod.CsvTokenizer.init(reader, buffer, config);
    return csv;
}

fn expectToken(comptime expected: csv_mod.CsvToken, maybe_actual: ?csv_mod.CsvToken) !void {
    if (maybe_actual) |actual| {
        if (@intFromEnum(expected) != @intFromEnum(actual)) {
            std.log.warn("Expected {t} but is {t}\n", .{ expected, actual });
            return error.TestFailed;
        }

        switch (expected) {
            .field => {
                try testing.expectEqualStrings(expected.field, actual.field);
            },
            else => {},
        }
    } else {
        std.log.warn("Expected {t} but is {?t}\n", .{ expected, maybe_actual });
        return error.TestFailed;
    }
}

test "Create iterator for file reader" {
    const data = @embedFile("resources/test-1.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [1024]u8 = undefined;

    _ = try getTokenizer(&reader, &csv_buf, .{});
}

test "Read single simple record from file" {
    const data = @embedFile("resources/test-1.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [1024]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    try expectToken(csv_mod.CsvToken{ .field = "1" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .field = "abc" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .row_end = {} }, try csv.next());

    const next = csv.next() catch unreachable;

    try expect(next == null);
}

test "Read multiple simple records from file" {
    const data = @embedFile("resources/test-2.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [1024]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    try expectToken(csv_mod.CsvToken{ .field = "1" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .field = "abc" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .row_end = {} }, try csv.next());

    try expectToken(csv_mod.CsvToken{ .field = "2" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .field = "def ghc" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .row_end = {} }, try csv.next());

    const next = csv.next() catch unreachable;

    try expect(next == null);
}

test "Read quoted fields" {
    const data = @embedFile("resources/test-4.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [1024]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    try expectToken(csv_mod.CsvToken{ .field = "1" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .field = "def ghc" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .row_end = {} }, try csv.next());

    try expectToken(csv_mod.CsvToken{ .field = "2" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .field = "abc \"def\"" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .row_end = {} }, try csv.next());

    const next = csv.next() catch unreachable;

    try expect(next == null);
}

test "Second read is necessary to obtain field" {
    const data = @embedFile("resources/test-read-required-for-field.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [1024]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    try expectToken(csv_mod.CsvToken{ .field = "12345" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .field = "67890" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .row_end = {} }, try csv.next());

    const next = csv.next() catch unreachable;

    try expect(next == null);
}

test "File is empty" {
    const data = @embedFile("resources/test-empty.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [1024]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    const next = csv.next() catch unreachable;

    try expect(next == null);
}

test "Field is longer than buffer" {
    const data = @embedFile("resources/test-error-short-buffer.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [8]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    const next = csv.next();
    try std.testing.expectError(csv_mod.CsvError.ShortBuffer, next);
}

test "Quoted field is longer than buffer" {
    const data = @embedFile("resources/test-error-short-buffer-quoted.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [8]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    const next = csv.next();
    try std.testing.expectError(csv_mod.CsvError.ShortBuffer, next);
}

test "Quoted field with double quotes is longer than buffer" {
    const data = @embedFile("resources/test-error-short-buffer-quoted-with-double.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [8]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    const next = csv.next();
    try std.testing.expectError(csv_mod.CsvError.ShortBuffer, next);
}

test "Quoted field with double quotes can be read on retry" {
    const data = @embedFile("resources/test-error-short-buffer-quoted-with-double.csv");
    var reader = std.Io.Reader.fixed(data);
    var csv_buf: [1024]u8 = undefined;
    var csv = try getTokenizer(&reader, &csv_buf, .{});

    try expectToken(csv_mod.CsvToken{ .field = "1234567890\"" }, try csv.next());
    try expectToken(csv_mod.CsvToken{ .row_end = {} }, try csv.next());

    const next = csv.next() catch unreachable;

    try expect(next == null);
}

// TODO test last line with new line and without
