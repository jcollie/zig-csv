// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A fuzzing loop for the CSV tokenizer.
//!
//! Zig 0.16.0 cannot build a test executable in fuzz mode, and even patched it
//! populates no coverage table, so this drives the targets in `test/fuzz.zig`
//! itself: it mutates a corpus of real CSV inputs, hands each result to a
//! target, and reports what came back.
//!
//! Usage: fuzz [--iterations N] [--seed N] [--target NAME]

const std = @import("std");
const fuzz = @import("fuzz");

const Smith = std.testing.Smith;

/// Seed inputs. Mutation works from real CSV rather than from noise, which is
/// what makes up for having no coverage feedback to steer with.
const corpus = [_][]const u8{
    "",
    "\n",
    "\r\n",
    "a",
    "a,b",
    "a,b\n",
    "a,b\r\nc,d\r\n",
    "a,b\rc,d\r",
    "1,,3\n",
    ",",
    ",,,\n",
    "\"a\"",
    "\"a\",\"b\"\r\n",
    "\"a\"\"b\",c\n",
    "\"a\r\nb\",c\r\n",
    "\"\"\n",
    "\"unclosed",
    "a\"b,c\n",
    "\"a\"x,b\n",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,b\n",
    "a,b\r\n\r\nc,d\n",
    "\"\"\"\"\"\"\n",
    "a\rb\r\nc",
    "x;y|z\tw\n",
    "\xef\xbb\xbfa,b\r\n",
    "\xef\xbb\xbf\"q\",r\n",
    "\xef\xbb\xbf",
};

/// Bytes a mutation is likely to reach for: the CSV metacharacters, plus a
/// couple of ordinary ones so inputs are not entirely punctuation.
const interesting = [_]u8{ ',', '"', '\r', '\n', ';', '\t', '|', 'a', 'b', '0', 0, 0xef, 0xbb, 0xbf };

const Stats = struct {
    iterations: u64 = 0,
    ok: u64 = 0,
    expected_errors: u64 = 0,
    empty_payloads: u64 = 0,
    payload_bytes: u64 = 0,
    max_payload: usize = 0,
    by_config: [fuzz.col_seps.len][fuzz.row_sep_choices]u64 =
        @splat(@splat(0)),
};

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) std.process.exit(1);
    const gpa = debug_allocator.allocator();

    // Targets cannot name `std.testing.allocator` outside a test build, so
    // they are given one here, and it reports any leak on the way out.
    fuzz.backing = gpa;

    var iterations: u64 = 100_000;
    var seed: u64 = 0;
    var only: ?[]const u8 = null;

    var args = try std.process.Args.Iterator.initAllocator(init.args, gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iterations")) {
            iterations = try std.fmt.parseInt(u64, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            seed = try std.fmt.parseInt(u64, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--target")) {
            only = args.next() orelse return error.MissingValue;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var payload: [fuzz.max_input]u8 = undefined;
    var input_buf: [fuzz.max_input + 64]u8 = undefined;

    var stats: Stats = .{};
    var failures: u64 = 0;

    for (0..iterations) |i| {
        const target = fuzz.targets[random.uintLessThan(usize, fuzz.targets.len)];
        if (only) |name| {
            if (!std.mem.eql(u8, name, target.name)) continue;
        }

        const len = mutate(random, &payload);
        const col = random.uintLessThan(u8, fuzz.col_seps.len);
        const row = random.uintLessThan(u8, fuzz.row_sep_choices);
        const shift = fuzz.min_buffer_shift +
            random.uintLessThan(u8, fuzz.max_buffer_shift - fuzz.min_buffer_shift + 1);

        const skip_bom = random.uintLessThan(u8, 2);
        const input = fuzz.writeInput(&input_buf, payload[0..len], col, row, shift, skip_bom);

        stats.iterations += 1;
        stats.payload_bytes += len;
        stats.max_payload = @max(stats.max_payload, len);
        if (len == 0) stats.empty_payloads += 1;
        stats.by_config[col][row] += 1;

        var smith: Smith = .{ .in = input };
        target.run(&smith) catch |err| {
            switch (err) {
                error.ShortBuffer, error.MisplacedQuote, error.NoSeparatorAfterField, error.UnclosedQuote => {
                    stats.expected_errors += 1;
                    continue;
                },
                else => {},
            }

            failures += 1;
            std.debug.print(
                \\
                \\=== FAILURE ===
                \\iteration : {d}
                \\target    : {s}
                \\error     : {t}
                \\col_sep   : {d} row_sep: {d} buffer: {d}
                \\payload   : "{f}"
                \\
            , .{ i, target.name, err, col, row, @as(usize, 1) << @intCast(shift), std.zig.fmtString(payload[0..len]) });

            if (failures >= 10) {
                std.debug.print("stopping after {d} failures\n", .{failures});
                break;
            }
            continue;
        };
        stats.ok += 1;
    }

    report(stats, failures);
    if (failures > 0) std.process.exit(1);
}

fn report(stats: Stats, failures: u64) void {
    std.debug.print(
        \\
        \\iterations        : {d}
        \\clean             : {d}
        \\expected errors   : {d}
        \\failures          : {d}
        \\
        \\-- oracle --
        \\agreed (parsed) : {d}
        \\agreed (rejected): {d}
        \\
        \\-- generation sanity --
        \\empty payloads    : {d} ({d}%)
        \\mean payload      : {d} bytes
        \\largest payload   : {d} bytes
        \\
    , .{
        stats.iterations,
        stats.ok,
        stats.expected_errors,
        failures,
        fuzz.accepted,
        fuzz.rejected,
        stats.empty_payloads,
        if (stats.iterations == 0) 0 else stats.empty_payloads * 100 / stats.iterations,
        if (stats.iterations == 0) 0 else stats.payload_bytes / stats.iterations,
        stats.max_payload,
    });

    // Silent mis-generation is the failure mode that makes a fuzzer report
    // millions of iterations having tested nothing, so show the spread.
    for (stats.by_config, 0..) |row_counts, col| {
        for (row_counts, 0..) |count, row| {
            std.debug.print("col={c} row={d}: {d}\n", .{ fuzz.col_seps[col], row, count });
        }
    }
}

/// Build the next payload: pick a corpus entry, then apply a few edits.
fn mutate(random: std.Random, out: []u8) usize {
    const seed_input = corpus[random.uintLessThan(usize, corpus.len)];
    var len = @min(seed_input.len, out.len);
    @memcpy(out[0..len], seed_input[0..len]);

    const edits = random.uintLessThan(u8, 6);
    for (0..edits) |_| {
        switch (random.uintLessThan(u8, 6)) {
            // Overwrite a byte with an interesting one.
            0 => if (len > 0) {
                out[random.uintLessThan(usize, len)] = interesting[random.uintLessThan(usize, interesting.len)];
            },
            // Overwrite a byte with anything at all.
            1 => if (len > 0) {
                out[random.uintLessThan(usize, len)] = random.int(u8);
            },
            // Insert an interesting byte.
            2 => if (len < out.len) {
                const at = random.uintAtMost(usize, len);
                std.mem.copyBackwards(u8, out[at + 1 .. len + 1], out[at..len]);
                out[at] = interesting[random.uintLessThan(usize, interesting.len)];
                len += 1;
            },
            // Delete a byte.
            3 => if (len > 0) {
                const at = random.uintLessThan(usize, len);
                std.mem.copyForwards(u8, out[at .. len - 1], out[at + 1 .. len]);
                len -= 1;
            },
            // Append another corpus entry, which is how long inputs and
            // multi-record inputs appear.
            4 => {
                const extra = corpus[random.uintLessThan(usize, corpus.len)];
                const room = @min(extra.len, out.len - len);
                @memcpy(out[len..][0..room], extra[0..room]);
                len += room;
            },
            // Repeat what is there, to reach past the field buffer.
            else => {
                const room = @min(len, out.len - len);
                @memcpy(out[len..][0..room], out[0..room]);
                len += room;
            },
        }
    }

    return len;
}
