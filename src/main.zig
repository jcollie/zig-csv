// SPDX-FileCopyrightText: © 2020-2024 @_beho
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const assert = std.debug.assert;

pub const CsvTokenType = enum {
    field,
    row_end,
};

pub const CsvToken = union(CsvTokenType) {
    field: []const u8,
    row_end: void,
};

pub const CsvError = error{
    /// A field did not fit in the buffer it was being assembled in.
    ShortBuffer,
    /// A quote appeared inside a field that was not itself quoted.
    MisplacedQuote,
    /// Something other than a separator or a record terminator followed a
    /// quoted field.
    NoSeparatorAfterField,
    /// The input ended while a quoted field was still open. Distinct from
    /// `ShortBuffer`: enlarging the buffer will not help, because there is no
    /// closing quote anywhere in the input.
    UnclosedQuote,
};

/// How records are terminated.
pub const RowSeparator = union(enum) {
    /// Accept CR, LF, or CRLF interchangeably, so that a file may use any of
    /// them -- and, in a file that is inconsistent about it, so may each
    /// individual record. A CR immediately followed by an LF is one
    /// terminator, not two, and so does not produce an empty record between
    /// them.
    any,

    /// Require exactly the two-byte sequence CR LF, as RFC 4180 specifies.
    /// A CR that is not followed by an LF, and an LF on its own, are both
    /// ordinary field data. This is the strict reading; `.any` is the
    /// forgiving one.
    crlf,

    /// Require exactly this byte. `.byte = '\n'` is the traditional Unix
    /// terminator and `.byte = '\r'` the classic Mac OS one; under either,
    /// the other byte is ordinary field data. Any other byte works too, for
    /// inputs that separate records by something else entirely.
    byte: u8,
};

pub const CsvConfig = struct {
    col_sep: u8 = ',',
    row_sep: RowSeparator = .any,
    quote: u8 = '"',
};

const QuoteFieldReadResult = struct {
    value: []u8,
    contains_quotes: bool,
};

// TODO comptime
pub const CsvReader = struct {
    buffer: []u8,
    current: []u8,

    reader: *std.Io.Reader,
    all_read: bool = false,

    const Self = @This();

    pub fn init(reader: *std.Io.Reader, buffer: []u8) Self {
        return .{
            .buffer = buffer,
            .current = buffer[0..0],
            .reader = reader,
        };
    }

    inline fn empty(self: *Self) bool {
        return self.current.len == 0;
    }

    pub fn char(self: *Self) !?u8 {
        if (!try self.ensureData()) {
            return null;
        }

        const c = self.current[0];
        self.current = self.current[1..];

        return c;
    }

    pub inline fn peek(self: *Self) !?u8 {
        if (!try self.ensureData()) {
            return null;
        }

        return self.current[0];
    }

    /// A byte is a terminator or it is not; the table answers in one load,
    /// where a list of terminators costs a comparison apiece for every byte
    /// scanned.
    pub const TerminalSet = [256]bool;

    /// Read up to the first byte in `set`. This is `until` with the inner
    /// loop hoisted into a table, and is the hot path for unquoted fields.
    pub fn untilAny(self: *Self, set: *const TerminalSet) !?[]u8 {
        if (!try self.ensureData()) {
            return null;
        }

        for (self.current, 0..) |c, pos| {
            if (set[c]) {
                const s = self.current[0..pos];
                self.current = self.current[pos..];
                return s;
            }
        }

        return null;
    }

    /// Read up to the first byte in `set`, or to a CR that is immediately
    /// followed by an LF. A CR with anything else behind it is data.
    ///
    /// Returns null when the answer is not yet knowable -- including when a
    /// CR is the last byte read, since whether it ends the record depends on
    /// a byte that has not arrived. The caller reads more and asks again; at
    /// end of input there is nothing more to come and the trailing CR is
    /// data, which is what taking the rest of the buffer yields.
    pub fn untilCrlf(self: *Self, set: *const TerminalSet) !?[]u8 {
        if (!try self.ensureData()) {
            return null;
        }

        for (self.current, 0..) |c, pos| {
            if (c == '\r') {
                if (pos + 1 >= self.current.len) return null;
                if (self.current[pos + 1] != '\n') continue;
            } else if (!set[c]) {
                continue;
            }

            const s = self.current[0..pos];
            self.current = self.current[pos..];
            return s;
        }

        return null;
    }

    pub fn until(self: *Self, terminators: []const u8) !?[]u8 {
        if (!try self.ensureData()) {
            return null;
        }

        for (self.current, 0..) |c, pos| {
            // TODO inline
            for (terminators) |ct| {
                if (c == ct) {
                    const s = self.current[0..pos];
                    self.current = self.current[pos..];
                    // print("{}|{}", .{ s, self.current });
                    return s;
                }
            }
        }

        // print("ALL_READ: {}\n", .{self.all_read});
        return null;
    }

    pub fn untilClosingQuote(self: *Self, quote: u8) !?QuoteFieldReadResult {
        if (!try self.ensureData()) {
            return null;
        }

        var idx: usize = 0;
        var contains_quotes: bool = false;
        while (idx < self.current.len) : (idx += 1) {
            const c = self.current[idx];
            // print("IDX QUOTED: {}={c}\n", .{ idx, c });
            if (c == quote) {
                // double quotes, shift forward
                // print("PEEK {c}\n", .{buffer[idx + 1]});
                if (idx < self.current.len - 1 and self.current[idx + 1] == quote) {
                    // print("DOUBLE QUOTES\n", .{});
                    contains_quotes = true;
                    idx += 1;
                } else {
                    // print("ALL_READ {}\n", .{self.all_read});
                    if (!self.all_read and idx == self.current.len - 1) {
                        return null;
                    }

                    const s = self.current[0..idx];
                    self.current = self.current[idx..];

                    return QuoteFieldReadResult{ .value = s, .contains_quotes = contains_quotes };
                }
            }
        }

        return null;
    }

    /// Take everything left in the buffer, leaving it empty. Only meaningful
    /// once the underlying reader is exhausted: it is how the final field of
    /// an input that ends without a record terminator is recovered.
    pub fn takeRest(self: *Self) []u8 {
        const rest = self.current;
        self.current = self.current[rest.len..];
        return rest;
    }

    /// Tries to read more data from an underlying reader if buffer is not already full.
    /// If anything was read returns true, otherwise false.
    pub fn read(self: *Self) !bool {
        const current_len = self.current.len;

        if (current_len == self.buffer.len) {
            return false;
        }

        if (current_len > 0) {
            mem.copyForwards(u8, self.buffer, self.current);
        }

        const read_len = try self.reader.readSliceShort(self.buffer[current_len..]);
        // print("READ: current_len={} read_len={}\n", .{ current_len, read_len });

        self.current = self.buffer[0 .. current_len + read_len];
        self.all_read = read_len == 0;

        return read_len > 0;
    }

    // Ensures that there are some data in the buffer. Returns false if no data are available
    pub inline fn ensureData(self: *Self) !bool {
        if (!self.empty()) {
            return true;
        }

        if (self.all_read) {
            return false;
        }

        return self.read();
    }
};

/// Tokenizes input from reader into stream of CsvTokens
pub const CsvTokenizer = struct {
    const Status = enum {
        initial,
        row_start,
        field,
        quoted_field_end,
        row_end,
        eof,
    };
    const Self = @This();

    config: CsvConfig,

    /// The bytes that end an unquoted field. `.any` contributes both CR and
    /// LF, so this is sized for the largest case and used through
    /// `terminals()`, which trims it to what was actually filled in. It is
    /// deliberately not stored as a slice: `init` returns by value, and a
    /// slice into the returned struct's own array would point at the
    /// temporary rather than at the copy the caller keeps.
    terminal_chars: [4]u8 = undefined,
    terminal_chars_len: u8 = 0,

    /// The same terminators as a lookup table, which is what the scan
    /// actually uses.
    terminal_set: CsvReader.TerminalSet = @splat(false),

    reader: CsvReader,

    status: Status = .initial,

    pub fn init(reader: *std.Io.Reader, buffer: []u8, config: CsvConfig) !Self {
        var terminal_chars: [4]u8 = undefined;
        var len: u8 = 0;

        terminal_chars[len] = config.col_sep;
        len += 1;

        switch (config.row_sep) {
            .any => {
                terminal_chars[len] = '\r';
                len += 1;
                terminal_chars[len] = '\n';
                len += 1;
            },
            .byte => |b| {
                terminal_chars[len] = b;
                len += 1;
            },
            // Neither CR nor LF ends a field on its own here: only the pair
            // does, which `untilCrlf` recognizes as it scans.
            .crlf => {},
        }

        terminal_chars[len] = config.quote;
        len += 1;

        var terminal_set: CsvReader.TerminalSet = @splat(false);
        for (terminal_chars[0..len]) |c| terminal_set[c] = true;

        return Self{
            .config = config,
            .terminal_chars = terminal_chars,
            .terminal_chars_len = len,
            .terminal_set = terminal_set,
            .reader = CsvReader.init(reader, buffer),
        };
    }

    /// The bytes that end an unquoted field, for this configuration.
    inline fn terminals(self: *const Self) []const u8 {
        return self.terminal_chars[0..self.terminal_chars_len];
    }

    /// Whether `c` begins a record terminator. Under `.any` this is true of
    /// both CR and LF; whether a CR is followed by an LF is decided later, by
    /// `consumeRowSeparator`.
    inline fn isRowSepStart(self: *const Self, c: u8) bool {
        return switch (self.config.row_sep) {
            .any => c == '\r' or c == '\n',
            .crlf => c == '\r',
            .byte => |b| c == b,
        };
    }

    /// Consume one record terminator, which has already been shown to be
    /// next by `isRowSepStart`. Under `.any`, a CR takes an LF with it when
    /// one follows, so that CRLF ends a single record.
    fn consumeRowSeparator(self: *Self) !void {
        const c = (try self.reader.char()).?;
        assert(self.isRowSepStart(c));

        switch (self.config.row_sep) {
            .any => if (c == '\r') {
                // The LF may not have been read yet, and there may be no LF
                // at all -- a lone CR ends the record, and so does a CR that
                // is the last byte in the input.
                if (try self.reader.ensureData()) {
                    if (try self.reader.peek()) |next_c| {
                        if (next_c == '\n') {
                            _ = try self.reader.char();
                        }
                    }
                }
            },
            .crlf => {
                // The scan only stops on a CR that an LF follows, so for an
                // unquoted field this is already known. After a quoted field
                // it is not: there, a CR with no LF behind it is a byte that
                // has no business between two fields.
                if (!try self.reader.ensureData()) return CsvError.NoSeparatorAfterField;
                const lf = (try self.reader.char()) orelse return CsvError.NoSeparatorAfterField;
                if (lf != '\n') return CsvError.NoSeparatorAfterField;
            },
            .byte => {},
        }
    }

    pub fn next(self: *Self) !?CsvToken {
        var next_status: ?Status = self.status;

        // Cannot use anonymous enum literals for Status
        // https://github.com/ziglang/zig/issues/4255

        while (next_status) |status| {
            // print("STATUS: {}\n", .{self.status});
            next_status = switch (status) {
                .initial => if (try self.reader.read()) Status.row_start else Status.eof,
                .row_start => if (!try self.reader.ensureData()) Status.eof else Status.field,
                .field => {
                    if (!try self.reader.ensureData()) {
                        // Reaching `.field` with nothing left to read can
                        // only mean that a column separator was consumed and
                        // then the input ended, so the record has one last,
                        // empty field: `a,` is two fields, exactly as `a,\n`
                        // is. `.row_start` sends an exhausted reader to
                        // `.eof` instead, so a record never starts here.
                        self.status = .row_end;
                        return CsvToken{ .field = "" };
                    }

                    return try self.parseField();
                },
                .quoted_field_end => blk: {
                    // read closing quotes
                    const quote = try self.reader.char();
                    assert(quote == self.config.quote);

                    if (!try self.reader.ensureData()) {
                        break :blk Status.row_end;
                    }

                    const c = (try self.reader.peek());

                    if (c) |value| {
                        // print("END: {}\n", .{value});
                        if (value == self.config.col_sep) {
                            // TODO write repro for assert with optional
                            // const col_sep = try self.reader.char();
                            // assert(col_sep == self.config.col_sep);
                            const col_sep = (try self.reader.char()).?;
                            assert(col_sep == self.config.col_sep);

                            break :blk Status.field;
                        }

                        if (self.isRowSepStart(value)) {
                            break :blk Status.row_end;
                        }

                        // quote means that it did not fit into buffer and it cannot be analyzed as ""
                        if (value == self.config.quote) {
                            return CsvError.ShortBuffer;
                        }
                    } else {
                        break :blk Status.eof;
                    }

                    return CsvError.NoSeparatorAfterField;
                },
                .row_end => {
                    if (!try self.reader.ensureData()) {
                        self.status = Status.eof;
                        return CsvToken{ .row_end = {} };
                    }

                    try self.consumeRowSeparator();

                    self.status = Status.row_start;

                    return CsvToken{ .row_end = {} };
                },
                .eof => {
                    return null;
                },
            };

            // make the transition and also ensure that next_status is set at this point
            self.status = next_status.?;
        }

        unreachable;
    }

    /// Read up to whatever ends an unquoted field, which depends on how
    /// records are terminated: under `.crlf` a CR only counts when an LF
    /// follows it, so that scan has to look ahead.
    inline fn scanField(self: *Self) !?[]u8 {
        return switch (self.config.row_sep) {
            .crlf => self.reader.untilCrlf(&self.terminal_set),
            .any, .byte => self.reader.untilAny(&self.terminal_set),
        };
    }

    fn parseField(self: *Self) !CsvToken {
        const first = (try self.reader.peek()).?;

        if (first != self.config.quote) {
            var field = try self.scanField();
            while (field == null) {
                // No terminator among what has been read so far, which means
                // either that more is coming or that the input has run out.
                const has_data = try self.reader.read();
                if (!has_data) {
                    if (self.reader.all_read) {
                        // The input ends without terminating its last
                        // record, so whatever remains in the buffer is that
                        // record's final field. Go straight to `.row_end`,
                        // which closes the record off an exhausted reader.
                        self.status = .row_end;
                        return CsvToken{ .field = self.reader.takeRest() };
                    }

                    // The buffer filled up without a terminator appearing.
                    return CsvError.ShortBuffer;
                }

                field = try self.scanField();
            }

            const terminator = (try self.reader.peek()).?;

            if (terminator == self.config.col_sep) {
                _ = try self.reader.char();
                return CsvToken{ .field = field.? };
            }

            if (self.isRowSepStart(terminator)) {
                self.status = .row_end;
                return CsvToken{ .field = field.? };
            }

            if (terminator == self.config.quote) {
                return CsvError.MisplacedQuote;
            }

            return CsvError.ShortBuffer;
        } else {
            // consume opening quote
            _ = try self.reader.char();
            var quoted_field = try self.reader.untilClosingQuote(self.config.quote);
            while (quoted_field == null) {
                const has_data = try self.reader.read();

                // `untilClosingQuote` withholds a closing quote that is the
                // last byte in the buffer, because it cannot yet tell a `""`
                // escape from the end of the field. Once the reader is
                // exhausted there is nothing left to wait for, so ask again
                // rather than give up -- that is what lets an input end on a
                // quoted field with no terminator after it.
                if (!has_data and !self.reader.all_read) {
                    // The buffer filled up and no closing quote was in it.
                    return CsvError.ShortBuffer;
                }

                quoted_field = try self.reader.untilClosingQuote(self.config.quote);
                if (quoted_field == null and !has_data) {
                    // Nothing more was read and there is still no closing
                    // quote, so there is none to come: the field is open at
                    // the end of the input. A bigger buffer would not help,
                    // and saying `ShortBuffer` here would send the caller to
                    // find one.
                    return CsvError.UnclosedQuote;
                }
            }

            self.status = .quoted_field_end;

            const field = quoted_field.?;
            if (!field.contains_quotes) {
                return CsvToken{ .field = field.value };
            } else {
                // walk the field and remove double quotes by shifting bytes
                const value = field.value;
                var diff: u64 = 0;
                var idx: usize = 0;
                while (idx < value.len) : (idx += 1) {
                    const c = value[idx];
                    value[idx - diff] = c;

                    if (c == self.config.quote) {
                        diff += 1;
                        idx += 1;
                    }
                }

                return CsvToken{ .field = value[0 .. value.len - diff] };
            }
        }
    }
};
