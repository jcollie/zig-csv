# zig-csv

A low-level CSV tokenizer for [Zig](https://ziglang.org/). It reads bytes from
any `std.Io.Reader` and yields a stream of tokens — one `field` per column,
followed by a `row_end` at the end of each record.

It does not allocate. The caller hands it a buffer, and fields are assembled
there, which makes it suitable for streaming a file larger than memory and for
environments where an allocator is unwelcome.

Originally written by [beho](https://github.com/beho), who describes it as a
Zig learning project rather than production software. This fork keeps it
building against current Zig releases; see [Credits](#credits).

## Where this lives

The canonical repository is on Forgejo, with a mirror on GitHub:

```console
git clone https://git.jcollie.dev/jeff/zig-csv.git
```

```console
git clone https://github.com/jcollie/zig-csv.git
```

## Requirements

Zig 0.16.0 or later. The 0.16 release reworked readers and writers, so earlier
versions will not build this.

## Installation

Add the dependency to your project:

```console
zig fetch --save git+https://git.jcollie.dev/jeff/zig-csv.git#v0.2.0
```

That records the resolved commit and hash in your `build.zig.zon` under the
name `zig_csv`. Naming a tag pins the release; leaving the `#v0.1.0` off
pins whatever `main` happened to point at when you ran the command, which is
rarely what you want in a committed manifest.

Then wire the module up in your `build.zig`:

```zig
const csv_dep = b.dependency("zig_csv", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("csv", csv_dep.module("csv"));
```

## Usage

```zig
const std = @import("std");
const csv = @import("csv");

pub fn main() !void {
    const data =
        \\name,quantity,note
        \\widget,4,"Contains a comma, and a ""quote"""
        \\gadget,11,
        \\
    ;

    // Any `*std.Io.Reader` will do; this one reads from memory.
    var reader: std.Io.Reader = .fixed(data);

    // The tokenizer never allocates: this buffer is where fields are
    // assembled, and it must be longer than the longest field in the input.
    var field_buf: [4096]u8 = undefined;

    var tokenizer = try csv.CsvTokenizer.init(&reader, &field_buf, .{});

    while (try tokenizer.next()) |token| switch (token) {
        .field => |value| std.debug.print("[{s}] ", .{value}),
        .row_end => std.debug.print("\n", .{}),
    };
}
```

which prints:

```text
[name] [quantity] [note]
[widget] [4] [Contains a comma, and a "quote"]
[gadget] [11] []
```

Note that the embedded comma and the doubled `""` are handled by the
tokenizer, and that the trailing empty field is reported as a zero-length
`field` rather than skipped.

### Reading from a file

The tokenizer only wants a `*std.Io.Reader`, so a file reader is the same code
with a different source. In 0.16 file access goes through an `Io`:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();
const io = threaded.io();

var file = try std.Io.Dir.cwd().openFile(io, "data.csv", .{});
defer file.close(io);

var read_buf: [4096]u8 = undefined;
var file_reader = file.reader(io, &read_buf);

var field_buf: [4096]u8 = undefined;
var tokenizer = try csv.CsvTokenizer.init(&file_reader.interface, &field_buf, .{});
```

The two buffers do different jobs: `read_buf` is how much of the file is held
at once, and `field_buf` bounds the longest single field.

## Record terminators

By default the tokenizer accepts CR, LF, or CRLF, so a file written on any of
the three platform conventions reads without configuration — including a file
that is inconsistent about it, since the terminator is decided per record. A CR
immediately followed by an LF counts as one terminator rather than two, so CRLF
input does not produce an empty record between every pair of real ones.

To require one exact byte instead, set `row_sep` to `.byte`:

```zig
// Strictly Unix: a CR is ordinary field data.
var tokenizer = try csv.CsvTokenizer.init(&reader, &field_buf, .{
    .row_sep = .{ .byte = '\n' },
});
```

```zig
// Classic Mac OS: an LF is ordinary field data.
var tokenizer = try csv.CsvTokenizer.init(&reader, &field_buf, .{
    .row_sep = .{ .byte = '\r' },
});
```

`.byte` takes any byte, not just the two, for input that separates records by
something else entirely. Note that `.any` is the default, so a CR that used to
survive to the end of a field under the old LF-only behavior is now consumed
as part of the terminator.

For the strict reading that RFC 4180 specifies — only CRLF ends a record, and
a CR or an LF on its own is ordinary field data — use `.crlf`:

```zig
var tokenizer = try csv.CsvTokenizer.init(&reader, &field_buf, .{
    .row_sep = .crlf,
});
```

`.crlf` needs one byte more headroom than the other modes: deciding whether a
CR ends a record takes both the CR and the byte behind it in the buffer at
once, so the buffer must exceed the longest field by two rather than one. It
reports `error.ShortBuffer` rather than misreading the input.

Inside a quoted field none of this applies: CR and LF are data there, and a
quoted field may span lines.

## API

| Item | Purpose |
| --- | --- |
| `CsvTokenizer.init(reader, buffer, config)` | Build a tokenizer over a `*std.Io.Reader`. |
| `CsvTokenizer.next()` | Return the next `?CsvToken`, or `null` at end of input. |
| `CsvToken` | Tagged union: `.field: []const u8` or `.row_end`. |
| `CsvConfig` | `col_sep` (default `,`), `row_sep` (default `.any`), `quote` (default `"`), `skip_bom` (default `true`). |
| `RowSeparator` | `.any` to accept CR, LF or CRLF, `.crlf` to require the pair, or `.{ .byte = c }` to require one byte. |
| `CsvError` | `ShortBuffer`, `MisplacedQuote`, `NoSeparatorAfterField`, `UnclosedQuote`. |

A `field` slice points into the caller's buffer and is only valid until the
next call to `next()`. Copy it if you need to keep it.

## Behavior and limitations

- Input is treated as bytes. UTF-8 passes through unharmed, but nothing
  validates it, and a field is a slice of the input rather than a sequence of
  code points.
- Quoted fields may contain the column separator, the row separator, and the
  quote character itself when doubled (`"He said ""hi"""`).
- The column separator and quote are configurable, but **only as single
  bytes** — a multi-byte column separator is not supported. Setting `quote`
  makes that byte the quote and leaves `"` as ordinary field data.
- The field buffer must be longer than the longest field in the input;
  otherwise `next()` fails with `error.ShortBuffer`.
- An empty line is not skipped: it yields a single zero-length `field`
  followed by `row_end`, the same shape as a one-column row.
- The final record need not be terminated. Input that simply stops yields its
  last record as usual, so a file with no trailing newline reads the same as
  one with it. A record ending in a column separator keeps its trailing empty
  field, so `a,` is two fields exactly as `a,\n` is.
- An unclosed quoted field and a field longer than the buffer are different
  errors. `error.UnclosedQuote` means the input ended with a field still open,
  so a larger buffer would not help; `error.ShortBuffer` means the buffer
  filled before the field ended, so it would.
- A UTF-8 byte order mark at the very start of the input is consumed rather
  than handed back as the opening bytes of the first field, since a header
  read with one attached does not compare equal to the name it appears to
  spell. Set `skip_bom = false` to pass the input through byte for byte. Only
  the first mark in the first position is treated as a mark; anywhere else it
  is ordinary data.

## An unclosed quote cannot run away

A quote that is never closed is the classic way to lose a CSV file: a parser
that buffers a record at a time will keep reading, and one stray quote can
swallow everything after it — two million rows of it, in the case [2]
recounts.

That cannot happen here, and not by being careful about it -- the tokenizer
does not allocate, so a field is bounded by the buffer it is being assembled
in, and a field that outgrows the buffer is an error rather than a larger
allocation. A 2.2 MB file with a single unclosed quote on its first line stops
at once, having produced no fields, whether the buffer is 1 KB or 64 KB.

Which error comes back says what to do about it. `error.UnclosedQuote` means
the input ran out with the field still open: the file is malformed and a
bigger buffer will not change that. `error.ShortBuffer` means the buffer
filled first, which a bigger one may well fix.

## RFC 4180

RFC 4180 [1] describes the format this implements. Every clause of its
section 2 is covered, and the checking is mechanical rather than a reading:
the `rfc4180` fuzz target builds documents that satisfy the RFC's ABNF —
records, quoting, `""` escaping, and `TEXTDATA` restricted to
`%x20-21 / %x23-2B / %x2D-7E` — and compares the fields that come back out to
the ones that went in, under the default configuration and under `.crlf`
alike. It runs with every other target, so the claim is rechecked rather than
recorded: a three million iteration run covers around 570,000 such documents.

The target earns its place. Breaking the doubled-quote unescaping by one
statement is caught by it within a dozen inputs, where a round trip cannot see
that class of fault at all, since a parser that loses information consistently
re-encodes to something that reads back the same.

Where this library is deliberately more permissive than the RFC:

- By default a lone CR or a lone LF also ends a record, where the RFC says
  CRLF. This cannot misread a valid RFC document, since `TEXTDATA` admits
  neither CR nor LF and so an unquoted field cannot contain one; it only
  accepts input the RFC would reject. Use `.crlf` for the strict reading.
- Unquoted fields accept any byte, where `TEXTDATA` is printable ASCII minus
  `"` and `,`. Tabs, control bytes and UTF-8 all pass through.
- An empty input yields no tokens. Read literally the ABNF makes an empty file
  one record holding one empty field.
- The grammar cannot distinguish a final record holding a single empty field
  from the optional trailing CRLF, since both are the same bytes; a trailing
  terminator is read as ending the file rather than as starting an empty
  record.

Two things the RFC mentions that a tokenizer is the wrong layer for: the
optional header line is just the first record, and the rule that every record
carry the same number of fields needs a record at a time rather than a token.

Skipping the byte order mark is the one thing here that does not round trip.
A first field whose own value begins with U+FEFF is written back out at the
start of the file, where it reads as a mark and is stripped. A producer that
quotes that field, or simply does not emit a mark, avoids the question.

## Development

The repository ships a Nix flake with the pinned toolchain:

```console
nix develop
```

```console
zig build test --summary all
```

The checks that CI enforces are formatting, licensing, the test suite, and the
build:

```console
zig fmt --check .
reuse lint
zig build test --summary all
zig build
```

CI runs on Forgejo Actions; see `.forgejo/workflows/test.yml`.

There is a fuzzing loop and a set of throughput benchmarks:

```console
zig build fuzz -- --iterations 100000 --seed 1
```

```console
zig build bench -- --seconds 2
```

Zig 0.16.0 cannot build a test executable in fuzz mode, so `tools/fuzz.zig`
drives the targets in `test/fuzz.zig` itself, mutating a corpus of real CSV.
Besides checking that nothing crashes, the targets assert that the field
buffer cannot change what is parsed, that a token stream survives being
re-encoded and read back, that the streaming tokenizer agrees with a naive
reference parser that sees the whole input at once, and that every document
the RFC's grammar admits parses back into the fields that built it. The targets also
run over a fixed corpus as part of `zig build test`, so they cannot rot
between fuzzing sessions.

Some notes on throughput and how to generate test data are in
[`docs/performance.md`](docs/performance.md).

## References cited

1. Shafranovich, Y. *Common Format and MIME Type for Comma-Separated Values
   (CSV) Files.* RFC 4180, Internet Engineering Task Force, October 2005.
   <https://www.rfc-editor.org/rfc/rfc4180.txt>

   The format this library implements. Section 2 and its ABNF are what the
   `rfc4180` fuzz target generates against; the section above records where
   this implementation is deliberately more permissive.

2. Hillman, Chris. *The CSV Test Suite Nobody Writes.* Ghost in the Data,
   4 March 2026.
   <https://ghostinthedata.info/posts/2026/2026-03-04-csv-test-suite/>

<!-- TODO: submit the Hillman post to the Internet Archive and record the
     Wayback snapshot alongside the original URL above, so the citation
     outlives the site. It was not done when the citation was added because
     archive.org was returning 429 and then serving its "Temporarily Offline"
     page; nothing is wrong with the URL itself, which answered 200. A
     personal blog is exactly the kind of source worth archiving. -->

   Turns the RFC and a catalogue of real-world failures into concrete tests.
   Two changes here came out of reading it: a byte order mark is consumed
   rather than handed back as part of the first field, and an unclosed quote
   reports itself as one instead of as a short buffer. Its worst fixture is
   the unclosed quote that swallows a file, which is the behavior the section
   on bounded quotes above exists to rule out.

## Credits

Original author: [beho](https://github.com/beho), whose repository at
[beho/zig-csv](https://github.com/beho/zig-csv) this is a fork of. The
tokenizer design and the test suite are theirs. Later upstream contributions
came from Roman Frołow, Nitin Prakash, xdBronch, and Deins.

This fork carries the library forward across Zig releases — currently 0.16 —
and adds the Nix flake, the Forgejo workflow, and REUSE licensing metadata.

## License

MIT, for the original work and this fork alike. The project follows the
[REUSE](https://reuse.software/) specification: every file carries its
copyright and license, either in an SPDX header or through `REUSE.toml`, and
the license text is in [`LICENSES/MIT.txt`](LICENSES/MIT.txt).
