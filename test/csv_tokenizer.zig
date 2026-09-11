// SPDX-FileCopyrightText: © 2021-2024 @_beho
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

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

/// Drive a tokenizer across `data` and assert the entire token stream, so a
/// terminator case can be stated as the fields and record breaks it ought to
/// produce. A `null` in `expected` stands for a `row_end`.
fn expectStream(
    data: []const u8,
    config: csv_mod.CsvConfig,
    comptime buffer_len: usize,
    expected: []const ?[]const u8,
) !void {
    var reader = std.Io.Reader.fixed(data);
    var buffer: [buffer_len]u8 = undefined;
    var csv = try getTokenizer(&reader, &buffer, config);

    for (expected) |maybe_field| {
        const token = (try csv.next()) orelse {
            std.log.warn("stream ended early, still expecting {?s}\n", .{maybe_field});
            return error.TestFailed;
        };

        switch (token) {
            .field => |value| {
                const expected_field = maybe_field orelse {
                    std.log.warn("expected row_end but got field {s}\n", .{value});
                    return error.TestFailed;
                };
                try testing.expectEqualStrings(expected_field, value);
            },
            .row_end => {
                if (maybe_field) |expected_field| {
                    std.log.warn("expected field {s} but got row_end\n", .{expected_field});
                    return error.TestFailed;
                }
            },
        }
    }

    try expect((try csv.next()) == null);
}

test "LF terminates a record" {
    try expectStream("1,abc\n2,def\n", .{}, 64, &.{ "1", "abc", null, "2", "def", null });
}

test "CRLF terminates a record" {
    try expectStream("1,abc\r\n2,def\r\n", .{}, 64, &.{ "1", "abc", null, "2", "def", null });
}

test "CR alone terminates a record" {
    try expectStream("1,abc\r2,def\r", .{}, 64, &.{ "1", "abc", null, "2", "def", null });
}

test "CRLF is a single terminator and makes no empty record" {
    try expectStream("1\r\n2\r\n3\r\n", .{}, 64, &.{ "1", null, "2", null, "3", null });
}

test "Terminators may be mixed within one input" {
    try expectStream(
        "1,a\n2,b\r\n3,c\r4,d\r\n",
        .{},
        64,
        &.{ "1", "a", null, "2", "b", null, "3", "c", null, "4", "d", null },
    );
}

test "Input ending in a bare CR terminates the last record" {
    try expectStream("1,abc\r", .{}, 64, &.{ "1", "abc", null });
}

test "Empty record under CRLF is one zero-length field" {
    try expectStream("1\r\n\r\n2\r\n", .{}, 64, &.{ "1", null, "", null, "2", null });
}

test "CRLF split across a buffer refill" {
    const data = "aaa,bbb\r\nccc,ddd\r\neee,fff\r\n";
    const expected: []const ?[]const u8 = &.{
        "aaa", "bbb", null,
        "ccc", "ddd", null,
        "eee", "fff", null,
    };

    // The interesting case is a refill landing between the CR and the LF.
    // Rather than compute which buffer length does that, run every small one
    // and require the same answer from each.
    inline for (.{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16, 32 }) |buffer_len| {
        expectStream(data, .{}, buffer_len, expected) catch |err| {
            std.log.warn("failed with buffer_len={d}\n", .{buffer_len});
            return err;
        };
    }
}

test "CRLF inside a quoted field is data, not a terminator" {
    try expectStream(
        "\"a\r\nb\",c\r\nd\r\n",
        .{},
        64,
        &.{ "a\r\nb", "c", null, "d", null },
    );
}

test "Quoted field followed by CRLF" {
    try expectStream(
        "\"a\",\"b\"\r\n\"c\",\"d\"\r\n",
        .{},
        64,
        &.{ "a", "b", null, "c", "d", null },
    );
}

test "Under .byte = LF a carriage return is field data" {
    try expectStream(
        "1,abc\r\n2,def\r\n",
        .{ .row_sep = .{ .byte = '\n' } },
        64,
        &.{ "1", "abc\r", null, "2", "def\r", null },
    );
}

test "Under .byte = CR a line feed is field data" {
    try expectStream(
        "1,abc\r2,def\r",
        .{ .row_sep = .{ .byte = '\r' } },
        64,
        &.{ "1", "abc", null, "2", "def", null },
    );
    try expectStream(
        "1,a\nb\r",
        .{ .row_sep = .{ .byte = '\r' } },
        64,
        &.{ "1", "a\nb", null },
    );
}

test "A record separator may be any byte" {
    try expectStream(
        "1,abc;2,def;",
        .{ .row_sep = .{ .byte = ';' } },
        64,
        &.{ "1", "abc", null, "2", "def", null },
    );
}

test "Final record need not be terminated" {
    try expectStream("1,abc\r\n2,def", .{}, 64, &.{ "1", "abc", null, "2", "def", null });
    try expectStream("1,abc\n2,def", .{}, 64, &.{ "1", "abc", null, "2", "def", null });
}

test "Input of a single unterminated field" {
    try expectStream("abc", .{}, 64, &.{ "abc", null });
}

test "Unterminated record ending in a column separator keeps the empty field" {
    // `1,` is two fields, exactly as `1,\n` is.
    try expectStream("1,", .{}, 64, &.{ "1", "", null });
    try expectStream("1,\n", .{}, 64, &.{ "1", "", null });
    try expectStream("a,b\r\nc,", .{}, 64, &.{ "a", "b", null, "c", "", null });
}

test "Unterminated record ending in a quoted field" {
    try expectStream("1,\"abc\"", .{}, 64, &.{ "1", "abc", null });
    try expectStream("\"a\",\"b\"", .{}, 64, &.{ "a", "b", null });
}

test "Unterminated final field spanning a buffer refill" {
    const data = "aaa,bbb\r\nccc,dddddddddddddddddddd";
    const expected: []const ?[]const u8 = &.{ "aaa", "bbb", null, "ccc", "dddddddddddddddddddd", null };

    inline for (.{ 21, 22, 24, 28, 32, 64 }) |buffer_len| {
        expectStream(data, .{}, buffer_len, expected) catch |err| {
            std.log.warn("failed with buffer_len={d}\n", .{buffer_len});
            return err;
        };
    }
}

test "Unterminated final record under an explicit byte separator" {
    try expectStream("1,abc\n2,def", .{ .row_sep = .{ .byte = '\n' } }, 64, &.{ "1", "abc", null, "2", "def", null });
    try expectStream("1,abc\r2,def", .{ .row_sep = .{ .byte = '\r' } }, 64, &.{ "1", "abc", null, "2", "def", null });
}

test "A field longer than the buffer is still a short buffer" {
    // The unterminated-last-record path must not swallow the genuine error:
    // here the input has not run out, the buffer has.
    var reader = std.Io.Reader.fixed("aaaaaaaaaaaaaaaaaaaa,b\n");
    var buffer: [8]u8 = undefined;
    var csv = try getTokenizer(&reader, &buffer, .{});

    try testing.expectError(csv_mod.CsvError.ShortBuffer, csv.next());
}

test "Unterminated quoted field with a doubled quote" {
    try expectStream("\"a\"\"b\"", .{}, 64, &.{ "a\"b", null });
    try expectStream("\"\"", .{}, 64, &.{ "", null });
    try expectStream("\"a\r\nb\"", .{}, 64, &.{ "a\r\nb", null });
}

test "An unclosed quoted field is an error" {
    var reader = std.Io.Reader.fixed("1,\"abc");
    var buffer: [64]u8 = undefined;
    var csv = try getTokenizer(&reader, &buffer, .{});

    try expectToken(csv_mod.CsvToken{ .field = "1" }, try csv.next());
    try testing.expectError(csv_mod.CsvError.UnclosedQuote, csv.next());
}

test "An unclosed quote is told apart from a short buffer" {
    // The input ends with the field still open, and the buffer has room to
    // spare. Reporting ShortBuffer here would send the caller looking for a
    // bigger buffer that cannot help.
    {
        var reader = std.Io.Reader.fixed("\"oops,a\r\nb,c\r\n");
        var buffer: [256]u8 = undefined;
        var csv = try getTokenizer(&reader, &buffer, .{});
        try testing.expectError(csv_mod.CsvError.UnclosedQuote, csv.next());
    }

    // Here the quote does close, but not before the buffer fills.
    {
        var reader = std.Io.Reader.fixed("\"aaaaaaaaaaaaaaaaaaaa\"\r\n");
        var buffer: [8]u8 = undefined;
        var csv = try getTokenizer(&reader, &buffer, .{});
        try testing.expectError(csv_mod.CsvError.ShortBuffer, csv.next());
    }
}

test "An unclosed quote is bounded by the buffer, not the input" {
    // A single unclosed quote must not swallow the rest of the file, however
    // much of it there is.
    const gpa = testing.allocator;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try input.appendSlice(gpa, "\"oops");
    for (0..20000) |i| try input.print(gpa, "row{d},a,b\r\n", .{i});

    var reader = std.Io.Reader.fixed(input.items);
    var buffer: [1024]u8 = undefined;
    var csv = try getTokenizer(&reader, &buffer, .{});

    try testing.expectError(csv_mod.CsvError.ShortBuffer, csv.next());
}

test "Strict CRLF: only the pair terminates a record" {
    const strict: csv_mod.CsvConfig = .{ .row_sep = .crlf };

    try expectStream("a,b\r\nc,d\r\n", strict, 64, &.{ "a", "b", null, "c", "d", null });
    try expectStream("a,b\r\nc,d", strict, 64, &.{ "a", "b", null, "c", "d", null });
    try expectStream("a\r\n\r\nb\r\n", strict, 64, &.{ "a", null, "", null, "b", null });
}

test "Strict CRLF: a lone CR or LF is field data" {
    const strict: csv_mod.CsvConfig = .{ .row_sep = .crlf };

    try expectStream("a\nb\r\n", strict, 64, &.{ "a\nb", null });
    try expectStream("a\rb\r\n", strict, 64, &.{ "a\rb", null });
    try expectStream("a\r", strict, 64, &.{ "a\r", null });
    try expectStream("x\r\ry\r\n", strict, 64, &.{ "x\r\ry", null });
}

test "Strict CRLF: a CR split across a buffer refill" {
    const data = "aaa,bbb\r\nccc\rddd\r\neee\r\n";
    const expected: []const ?[]const u8 = &.{ "aaa", "bbb", null, "ccc\rddd", null, "eee", null };

    // A refill landing between a CR and the byte that decides its meaning is
    // the whole difficulty of this mode, so try every small buffer.
    inline for (.{ 9, 10, 11, 12, 13, 14, 16, 24, 64 }) |buffer_len| {
        expectStream(data, .{ .row_sep = .crlf }, buffer_len, expected) catch |err| {
            std.log.warn("failed with buffer_len={d}\n", .{buffer_len});
            return err;
        };
    }
}

test "Strict CRLF: quoted fields carry CR and LF unharmed" {
    const strict: csv_mod.CsvConfig = .{ .row_sep = .crlf };

    try expectStream("\"x\ry\nz\r\nw\"\r\n", strict, 64, &.{ "x\ry\nz\r\nw", null });
    try expectStream("\"a\",\"b\"\r\n", strict, 64, &.{ "a", "b", null });
}

test "Strict CRLF: a bare CR after a quoted field is an error" {
    var reader = std.Io.Reader.fixed("\"a\"\rb\r\n");
    var buffer: [64]u8 = undefined;
    var csv = try getTokenizer(&reader, &buffer, .{ .row_sep = .crlf });

    try expectToken(csv_mod.CsvToken{ .field = "a" }, try csv.next());
    try testing.expectError(csv_mod.CsvError.NoSeparatorAfterField, csv.next());
}

test "A configured quote is honored in place of the default" {
    const single: csv_mod.CsvConfig = .{ .quote = '\'' };

    try expectStream("'a,b',c\n", single, 64, &.{ "a,b", "c", null });
    try expectStream("'a''b'\n", single, 64, &.{ "a'b", null });
    // The default quote becomes ordinary data once it is not the quote.
    try expectStream("a\"b,c\n", single, 64, &.{ "a\"b", "c", null });
    try expectStream("'a;b';c\n", .{ .quote = '\'', .col_sep = ';' }, 64, &.{ "a;b", "c", null });
}

test "A configured quote still rejects what the default would" {
    var reader = std.Io.Reader.fixed("'a'x\n");
    var buffer: [64]u8 = undefined;
    var csv = try getTokenizer(&reader, &buffer, .{ .quote = '\'' });

    try expectToken(csv_mod.CsvToken{ .field = "a" }, try csv.next());
    try testing.expectError(csv_mod.CsvError.NoSeparatorAfterField, csv.next());
}

test "Strict CRLF needs one byte more headroom than the buffer alone" {
    // Deciding whether a CR ends the record takes the CR and the byte behind
    // it in the buffer together, so `.crlf` wants one byte more than `.any`
    // does for the same field. It says so with an error rather than
    // misreading the input.
    const data = "ccc\rddd\r\neee\r\n"; // longest field is 7 bytes

    try expectStream(data, .{ .row_sep = .crlf }, 9, &.{ "ccc\rddd", null, "eee", null });

    var reader = std.Io.Reader.fixed(data);
    var buffer: [8]u8 = undefined;
    var csv = try getTokenizer(&reader, &buffer, .{ .row_sep = .crlf });
    try testing.expectError(csv_mod.CsvError.ShortBuffer, csv.next());
}
