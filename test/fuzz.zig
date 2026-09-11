// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Fuzz targets for the CSV tokenizer.
//!
//! Each target takes a `Smith` and asks it for an input and a configuration,
//! always in the same order, because the standalone driver in `tools/fuzz.zig`
//! has to write that encoding by hand -- see `readParams` for the layout.

const std = @import("std");
const builtin = @import("builtin");
const csv = @import("csv");

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;

/// The allocator targets run against. A target is reached both from the test
/// runner and from the standalone driver, and `std.testing.allocator` does
/// not exist outside a test build, so the driver points this at a checked
/// allocator of its own.
pub var backing: Allocator = if (builtin.is_test) std.testing.allocator else undefined;

/// The largest input any target will read. The driver needs this to write a
/// length `Smith` will accept: a length larger than the destination buffer
/// silently yields an empty slice rather than being reduced into range.
pub const max_input = 4096;

/// Column separators a target may choose between. The quote is left at its
/// default, because the tokenizer recognizes `"` directly in a couple of
/// places rather than consulting the configuration, so a custom quote is not
/// a supported configuration to fuzz.
pub const col_seps = [_]u8{ ',', ';', '\t', '|' };

/// How many row separator choices `readParams` offers.
pub const row_sep_choices = 4;

/// Smallest and largest field buffer, as powers of two.
pub const min_buffer_shift = 2;
pub const max_buffer_shift = 9;

pub const Params = struct {
    data: []const u8,
    config: csv.CsvConfig,
    buffer_len: usize,
};

/// Read an input and a configuration. The driver mirrors this exact sequence:
/// a slice, then three values.
fn readParams(smith: *Smith, in: []u8) Params {
    const n = smith.slice(in);

    const col_sep = col_seps[smith.valueRangeAtMost(u8, 0, col_seps.len - 1)];

    const row_sep: csv.RowSeparator = switch (smith.valueRangeAtMost(u8, 0, row_sep_choices - 1)) {
        0 => .any,
        1 => .crlf,
        2 => .{ .byte = '\n' },
        else => .{ .byte = '\r' },
    };

    const shift = smith.valueRangeAtMost(u8, min_buffer_shift, max_buffer_shift);

    return .{
        .data = in[0..n],
        .config = .{ .col_sep = col_sep, .row_sep = row_sep },
        .buffer_len = @as(usize, 1) << @intCast(shift),
    };
}

const Token = union(enum) {
    field: []const u8,
    row_end,
};

/// Tokenize into an owned list. Field slices point into the tokenizer's
/// buffer and are invalidated by the next call, so each one is copied.
fn collect(gpa: Allocator, data: []const u8, config: csv.CsvConfig, buffer_len: usize) ![]Token {
    const buffer = try gpa.alloc(u8, buffer_len);
    defer gpa.free(buffer);

    var reader: std.Io.Reader = .fixed(data);
    var tokenizer = try csv.CsvTokenizer.init(&reader, buffer, config);

    var tokens: std.ArrayList(Token) = .empty;
    // Declared before the errdefer so that it runs after it: defers run in
    // reverse, and freeing the list first would leave the errdefer reading
    // released memory.
    defer tokens.deinit(gpa);
    // Fields are duplicated as they are collected, so an error partway
    // through leaves copies to release.
    errdefer for (tokens.items) |token| switch (token) {
        .field => |value| gpa.free(value),
        .row_end => {},
    };

    while (try tokenizer.next()) |token| {
        switch (token) {
            .field => |value| {
                // A field must point into the buffer it was assembled in.
                std.debug.assert(value.len <= buffer.len);
                try tokens.append(gpa, .{ .field = try gpa.dupe(u8, value) });
            },
            .row_end => try tokens.append(gpa, .row_end),
        }

        // A pathological input must not produce unbounded output.
        if (tokens.items.len > 4 * max_input) return error.TooManyTokens;
    }

    return tokens.toOwnedSlice(gpa);
}

fn expectSameTokens(a: []const Token, b: []const Token) !void {
    if (a.len != b.len) return error.TokenCountDiffers;
    for (a, b) |x, y| {
        switch (x) {
            .field => |xv| switch (y) {
                .field => |yv| if (!std.mem.eql(u8, xv, yv)) return error.FieldDiffers,
                .row_end => return error.TokenKindDiffers,
            },
            .row_end => switch (y) {
                .field => return error.TokenKindDiffers,
                .row_end => {},
            },
        }
    }
}

/// Write `tokens` back out as CSV that the same configuration will read.
fn encode(gpa: Allocator, tokens: []const Token, config: csv.CsvConfig) ![]u8 {
    const terminator: []const u8 = switch (config.row_sep) {
        .any, .crlf => "\r\n",
        .byte => |b| &[_]u8{b},
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var first_in_row = true;
    for (tokens) |token| {
        switch (token) {
            .field => |value| {
                if (!first_in_row) try out.append(gpa, config.col_sep);
                first_in_row = false;

                const needs_quotes = for (value) |c| {
                    if (c == config.col_sep or c == config.quote or c == '\r' or c == '\n') break true;
                } else false;

                if (!needs_quotes) {
                    try out.appendSlice(gpa, value);
                } else {
                    try out.append(gpa, config.quote);
                    for (value) |c| {
                        if (c == config.quote) try out.append(gpa, config.quote);
                        try out.append(gpa, c);
                    }
                    try out.append(gpa, config.quote);
                }
            },
            .row_end => {
                try out.appendSlice(gpa, terminator);
                first_in_row = true;
            },
        }
    }

    return out.toOwnedSlice(gpa);
}

fn freeTokens(gpa: Allocator, tokens: []Token) void {
    for (tokens) |token| switch (token) {
        .field => |value| gpa.free(value),
        .row_end => {},
    };
    gpa.free(tokens);
}

/// The tokenizer must not crash, however malformed the input.
fn tokenize(smith: *Smith) anyerror!void {
    var in: [max_input]u8 = undefined;
    const p = readParams(smith, &in);

    const tokens = collect(backing, p.data, p.config, p.buffer_len) catch |err| switch (err) {
        error.ShortBuffer, error.MisplacedQuote, error.NoSeparatorAfterField, error.UnclosedQuote => return,
        else => return err,
    };
    freeTokens(backing, tokens);
}

/// The buffer is an implementation detail: if a small buffer parses an input
/// at all, it must see exactly what a large buffer sees.
fn bufferInvariance(smith: *Smith) anyerror!void {
    var in: [max_input]u8 = undefined;
    const p = readParams(smith, &in);

    const small = collect(backing, p.data, p.config, p.buffer_len) catch return;
    defer freeTokens(backing, small);

    const large = collect(backing, p.data, p.config, max_input + 16) catch |err| {
        // The small buffer succeeded, so the large one has no excuse.
        std.debug.print("large buffer failed where {d} succeeded: {t}\n", .{ p.buffer_len, err });
        return err;
    };
    defer freeTokens(backing, large);

    try expectSameTokens(small, large);
}

/// Re-encoding a token stream and parsing it again must give that same
/// stream back: the quoting rules have to survive a round trip.
fn roundTrip(smith: *Smith) anyerror!void {
    var in: [max_input]u8 = undefined;
    const p = readParams(smith, &in);

    const first = collect(backing, p.data, p.config, max_input + 16) catch return;
    defer freeTokens(backing, first);

    const encoded = try encode(backing, first, p.config);
    defer backing.free(encoded);

    const second = collect(backing, encoded, p.config, encoded.len + 16) catch |err| {
        std.debug.print("re-parse of encoded output failed: {t}\n", .{err});
        return err;
    };
    defer freeTokens(backing, second);

    try expectSameTokens(first, second);
}

/// A deliberately naive reference tokenizer, used as an oracle.
///
/// It sees the whole input at once and does no buffering, so it shares none of
/// the streaming tokenizer's machinery -- which is the point: the two agreeing
/// is evidence, where the streaming one agreeing with itself is not. A parser
/// that loses information consistently survives a round trip but not this.
fn reference(gpa: Allocator, data: []const u8, config: csv.CsvConfig) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);
    errdefer for (tokens.items) |token| switch (token) {
        .field => |value| gpa.free(value),
        .row_end => {},
    };

    if (data.len == 0) return tokens.toOwnedSlice(gpa);

    const isTerm = struct {
        fn f(bytes: []const u8, at: usize, sep: csv.RowSeparator) bool {
            return switch (sep) {
                .any => bytes[at] == '\r' or bytes[at] == '\n',
                // Only the pair terminates; a lone CR is data.
                .crlf => bytes[at] == '\r' and at + 1 < bytes.len and bytes[at + 1] == '\n',
                .byte => |b| bytes[at] == b,
            };
        }
    }.f;

    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(gpa);

    var i: usize = 0;
    while (true) {
        field.clearRetainingCapacity();

        if (i < data.len and data[i] == config.quote) {
            // Quoted field: a doubled quote is a literal one.
            i += 1;
            while (true) {
                if (i >= data.len) return error.UnclosedQuote;
                if (data[i] == config.quote) {
                    if (i + 1 < data.len and data[i + 1] == config.quote) {
                        try field.append(gpa, config.quote);
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                try field.append(gpa, data[i]);
                i += 1;
            }

            // Only a separator, a terminator, or the end may follow.
            if (i < data.len and data[i] != config.col_sep and !isTerm(data, i, config.row_sep)) {
                return error.NoSeparatorAfterField;
            }
        } else {
            while (i < data.len and data[i] != config.col_sep and !isTerm(data, i, config.row_sep)) {
                if (data[i] == config.quote) return error.MisplacedQuote;
                try field.append(gpa, data[i]);
                i += 1;
            }
        }

        try tokens.append(gpa, .{ .field = try gpa.dupe(u8, field.items) });

        if (i >= data.len) {
            try tokens.append(gpa, .row_end);
            break;
        }

        if (data[i] == config.col_sep) {
            i += 1;
            continue;
        }

        // A record terminator; under `.any`, CR takes a following LF with it.
        const c = data[i];
        i += 1;
        switch (config.row_sep) {
            .any => if (c == '\r' and i < data.len and data[i] == '\n') {
                i += 1;
            },
            // `isTerm` already established that an LF follows.
            .crlf => i += 1,
            .byte => {},
        }

        try tokens.append(gpa, .row_end);
        if (i >= data.len) break;
    }

    return tokens.toOwnedSlice(gpa);
}

/// The streaming tokenizer must agree with the reference on every input.
fn differential(smith: *Smith) anyerror!void {
    var in: [max_input]u8 = undefined;
    const p = readParams(smith, &in);

    // A buffer that cannot be too short, so a ShortBuffer here would itself
    // be a finding rather than a limitation of the configuration.
    const roomy = p.data.len + 16;

    const actual: ?[]Token = collect(backing, p.data, p.config, roomy) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    defer if (actual) |tokens| freeTokens(backing, tokens);

    const expected: ?[]Token = reference(backing, p.data, p.config) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    defer if (expected) |tokens| freeTokens(backing, tokens);

    // The two report different error values for the same malformed input, so
    // only whether an input was rejected is compared, not why.
    if (actual == null and expected == null) {
        rejected += 1;
        return;
    }
    if (actual == null) return error.ReferenceAcceptedButTokenizerRejected;
    if (expected == null) return error.TokenizerAcceptedButReferenceRejected;

    accepted += 1;
    try expectSameTokens(actual.?, expected.?);
}

/// Counters the driver reports, so that a run which tested nothing is
/// visible rather than silently green.
pub var accepted: u64 = 0;
pub var rejected: u64 = 0;

pub const Target = struct {
    name: []const u8,
    run: *const fn (smith: *Smith) anyerror!void,
};

pub const targets = [_]Target{
    .{ .name = "tokenize", .run = tokenize },
    .{ .name = "buffer-invariance", .run = bufferInvariance },
    .{ .name = "round-trip", .run = roundTrip },
    .{ .name = "differential", .run = differential },
};

test "every target runs over a small corpus" {
    const corpus = [_][]const u8{
        "",
        "\n",
        "a",
        "a,b\r\nc,d\r\n",
        "\"a\"\"b\",c\n",
        "\"unclosed",
        "1,,3\r\n\r\n",
        "a\rb\r\nc",
    };

    for (targets) |target| {
        for (corpus) |payload| {
            for (0..col_seps.len) |col| {
                for (0..row_sep_choices) |row| {
                    var buf: [max_input + 64]u8 = undefined;
                    const input = writeInput(&buf, payload, @intCast(col), @intCast(row), 5);
                    var smith: Smith = .{ .in = input };
                    try target.run(&smith);
                }
            }
        }
    }
}

/// Lay out the bytes `readParams` expects: a 4-byte little-endian length and
/// the payload, then one 8-byte little-endian value per question asked.
pub fn writeInput(buf: []u8, payload: []const u8, col: u8, row: u8, shift: u8) []const u8 {
    std.debug.assert(payload.len <= max_input);
    std.debug.assert(buf.len >= 4 + payload.len + 3 * 8);

    std.mem.writeInt(u32, buf[0..4], @intCast(payload.len), .little);
    @memcpy(buf[4..][0..payload.len], payload);

    var at: usize = 4 + payload.len;
    for ([_]u64{ col, row, shift }) |value| {
        std.mem.writeInt(u64, buf[at..][0..8], value, .little);
        at += 8;
    }

    return buf[0..at];
}
