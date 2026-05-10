//! pkt-line framing as defined by gitprotocol-pack(5).
//!
//! Wire format: a 4-byte ASCII hex length prefix followed by `length - 4`
//! bytes of payload. Two reserved values control framing:
//!   - "0000" (flush)  : end of a logical message
//!   - "0001" (delim)  : delimits sub-sections within a message (v2)
//!
//! The length includes the 4-byte header itself, so payload length is
//! `parsed_len - 4`. Payload bytes 0..max_payload are allowed; longer
//! payloads must be split across multiple pkt-lines by the caller.

const std = @import("std");
const Writer = std.Io.Writer;

pub const max_payload = 65516; // 65520 max line - 4 header bytes

pub const WriteError = Writer.Error || error{PayloadTooLarge};

/// Write a pkt-line: 4-hex length prefix + payload (verbatim).
/// Caller is responsible for any trailing newline.
pub fn writeLine(w: *Writer, payload: []const u8) WriteError!void {
    if (payload.len > max_payload) return error.PayloadTooLarge;
    try w.print("{x:0>4}", .{@as(u16, @intCast(payload.len + 4))});
    try w.writeAll(payload);
}

/// Same as `writeLine` but appends a single '\n' after the payload.
/// Most lines in the git wire protocol end with '\n'.
pub fn writeLineLn(w: *Writer, payload: []const u8) WriteError!void {
    if (payload.len + 1 > max_payload) return error.PayloadTooLarge;
    try w.print("{x:0>4}", .{@as(u16, @intCast(payload.len + 1 + 4))});
    try w.writeAll(payload);
    try w.writeByte('\n');
}

/// Flush packet ("0000"). Marks end of a logical message.
pub fn writeFlush(w: *Writer) WriteError!void {
    try w.writeAll("0000");
}

/// Delimiter packet ("0001"). Used inside protocol v2 messages.
pub fn writeDelim(w: *Writer) WriteError!void {
    try w.writeAll("0001");
}

pub const ParsedKind = enum { data, flush, delim };

pub const Parsed = struct {
    kind: ParsedKind,
    /// Slice into the input buffer. For `flush` and `delim` this is empty.
    payload: []const u8,
    /// Number of bytes consumed from the input (header + payload).
    consumed: usize,
};

pub const ParseError = error{
    Truncated,
    InvalidLength,
};

/// Parse a single pkt-line out of `buf`. Errors if the buffer is too short
/// or if the length header isn't valid hex / out of range. The trailing
/// `\n` (if present) is *not* stripped from `payload`.
pub fn parse(buf: []const u8) ParseError!Parsed {
    if (buf.len < 4) return error.Truncated;
    const hdr = buf[0..4];
    var len: u16 = 0;
    for (hdr) |b| {
        const digit: u8 = switch (b) {
            '0'...'9' => b - '0',
            'a'...'f' => b - 'a' + 10,
            'A'...'F' => b - 'A' + 10,
            else => return error.InvalidLength,
        };
        len = (len << 4) | digit;
    }

    if (len == 0) return .{ .kind = .flush, .payload = &.{}, .consumed = 4 };
    if (len == 1) return .{ .kind = .delim, .payload = &.{}, .consumed = 4 };
    if (len < 4) return error.InvalidLength;
    if (len > buf.len) return error.Truncated;

    return .{
        .kind = .data,
        .payload = buf[4..len],
        .consumed = len,
    };
}

/// Iterator over pkt-lines in a buffer. Stops at end-of-buffer.
pub const Iterator = struct {
    rest: []const u8,

    pub fn init(buf: []const u8) Iterator {
        return .{ .rest = buf };
    }

    /// Returns the next pkt-line, or null at end-of-buffer.
    pub fn next(self: *Iterator) ParseError!?Parsed {
        if (self.rest.len == 0) return null;
        const p = try parse(self.rest);
        self.rest = self.rest[p.consumed..];
        return p;
    }
};

/// Reads exactly one pkt-line from `r`. Returns null on a clean end-of-stream
/// (the reader is exhausted at a logical line boundary). A partial header or
/// payload returns `error.UnexpectedEof`.
pub fn nextLine(r: *std.Io.Reader) !?Parsed {
    std.debug.assert(r.buffer.len >= min_buffer_capacity);
    // Probe for a clean end-of-stream before consuming any bytes. takeArray(4)
    // can't tell "0 bytes left" from "1-3 bytes left"; peekByte can.
    _ = r.peekByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };

    const hdr = r.takeArray(4) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEof,
        else => |e| return e,
    };

    var len: u16 = 0;
    for (hdr) |b| {
        const digit: u8 = switch (b) {
            '0'...'9' => b - '0',
            'a'...'f' => b - 'a' + 10,
            'A'...'F' => b - 'A' + 10,
            else => return error.InvalidLength,
        };
        len = (len << 4) | digit;
    }

    if (len == 0) return .{ .kind = .flush, .payload = &.{}, .consumed = 4 };
    if (len == 1) return .{ .kind = .delim, .payload = &.{}, .consumed = 4 };
    if (len < 4) return error.InvalidLength;

    const payload = r.take(len - 4) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEof,
        else => |e| return e,
    };
    return .{ .kind = .data, .payload = payload, .consumed = len };
}

/// `r.buffer` must be at least this big for `nextLine` to handle every legal
/// pkt-line (4-byte header + max payload).
pub const min_buffer_capacity: usize = 4 + max_payload;

/// Adapter that presents any value exposing `pub fn read(self, []u8) !usize`
/// as a `std.Io.Reader`. Returns `error.EndOfStream` when the underlying `read`
/// reports zero bytes.
pub fn IoReader(comptime Src: type) type {
    return struct {
        src: *Src,
        interface: std.Io.Reader,

        const Self = @This();
        const vtable: std.Io.Reader.VTable = .{ .stream = streamImpl };

        pub fn init(src: *Src, buf: []u8) Self {
            return .{
                .src = src,
                .interface = .{
                    .vtable = &vtable,
                    .buffer = buf,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn streamImpl(
            io_r: *std.Io.Reader,
            w: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_r));
            const dst = limit.slice(try w.writableSliceGreedy(1));
            const n = self.src.read(dst) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            w.advance(n);
            return n;
        }
    };
}

test "writeLine emits hex-prefixed payload" {
    var buf: [64]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    try writeLine(&fw, "hello");
    try std.testing.expectEqualStrings("0009hello", fw.buffered());
}

test "writeLineLn appends newline and accounts for it in length" {
    var buf: [64]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    try writeLineLn(&fw, "hello");
    try std.testing.expectEqualStrings("000ahello\n", fw.buffered());
}

test "writeFlush emits 0000" {
    var buf: [16]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    try writeFlush(&fw);
    try std.testing.expectEqualStrings("0000", fw.buffered());
}

test "writeDelim emits 0001" {
    var buf: [16]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    try writeDelim(&fw);
    try std.testing.expectEqualStrings("0001", fw.buffered());
}

test "service header line is 31 bytes for receive-pack" {
    var buf: [128]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    try writeLineLn(&fw, "# service=git-receive-pack");
    try std.testing.expectEqualStrings("001f# service=git-receive-pack\n", fw.buffered());
}

test "rejects payload exceeding max_payload" {
    const big = [_]u8{'x'} ** (max_payload + 1);
    var buf: [max_payload + 16]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    try std.testing.expectError(error.PayloadTooLarge, writeLine(&fw, &big));
}

test "parse data line" {
    const p = try parse("0009hello");
    try std.testing.expectEqual(ParsedKind.data, p.kind);
    try std.testing.expectEqualStrings("hello", p.payload);
    try std.testing.expectEqual(@as(usize, 9), p.consumed);
}

test "parse flush" {
    const p = try parse("0000extra");
    try std.testing.expectEqual(ParsedKind.flush, p.kind);
    try std.testing.expectEqual(@as(usize, 4), p.consumed);
}

test "parse delim" {
    const p = try parse("0001");
    try std.testing.expectEqual(ParsedKind.delim, p.kind);
}

test "parse invalid header" {
    try std.testing.expectError(error.InvalidLength, parse("zzzz"));
    try std.testing.expectError(error.InvalidLength, parse("0003"));
    try std.testing.expectError(error.Truncated, parse("ff"));
    try std.testing.expectError(error.Truncated, parse("00ff"));
}

test "Iterator walks lines until end" {
    // 0x000a = 10 = 4-byte header + 6-byte payload "hello\n".
    var it = Iterator.init("000ahello\n0000");
    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("hello\n", a.payload);
    const b = (try it.next()).?;
    try std.testing.expectEqual(ParsedKind.flush, b.kind);
    try std.testing.expectEqual(@as(?Parsed, null), try it.next());
}

const TestSource = struct {
    data: []const u8,
    /// Bytes returned per call; `0` means "fill the requested slice".
    chunk: usize = 0,

    pub fn read(self: *TestSource, into: []u8) !usize {
        if (self.data.len == 0) return 0;
        const want = if (self.chunk == 0) into.len else @min(self.chunk, into.len);
        const n = @min(want, self.data.len);
        @memcpy(into[0..n], self.data[0..n]);
        self.data = self.data[n..];
        return n;
    }
};

test "nextLine returns null on a fresh EOS" {
    var src = TestSource{ .data = "" };
    var buf: [min_buffer_capacity]u8 = undefined;
    var io = IoReader(TestSource).init(&src, &buf);
    try std.testing.expectEqual(@as(?Parsed, null), try nextLine(&io.interface));
}

test "nextLine walks data + flush" {
    var src = TestSource{ .data = "000ahello\n0000" };
    var buf: [min_buffer_capacity]u8 = undefined;
    var io = IoReader(TestSource).init(&src, &buf);

    const a = (try nextLine(&io.interface)).?;
    try std.testing.expectEqual(ParsedKind.data, a.kind);
    try std.testing.expectEqualStrings("hello\n", a.payload);

    const b = (try nextLine(&io.interface)).?;
    try std.testing.expectEqual(ParsedKind.flush, b.kind);

    try std.testing.expectEqual(@as(?Parsed, null), try nextLine(&io.interface));
}

test "nextLine handles short reads via IoReader (1 byte at a time)" {
    var src = TestSource{ .data = "000ahello\n0000", .chunk = 1 };
    var buf: [min_buffer_capacity]u8 = undefined;
    var io = IoReader(TestSource).init(&src, &buf);

    const a = (try nextLine(&io.interface)).?;
    try std.testing.expectEqualStrings("hello\n", a.payload);
    const b = (try nextLine(&io.interface)).?;
    try std.testing.expectEqual(ParsedKind.flush, b.kind);
    try std.testing.expectEqual(@as(?Parsed, null), try nextLine(&io.interface));
}

test "nextLine surfaces UnexpectedEof on a partial header" {
    var src = TestSource{ .data = "00" };
    var buf: [min_buffer_capacity]u8 = undefined;
    var io = IoReader(TestSource).init(&src, &buf);
    try std.testing.expectError(error.UnexpectedEof, nextLine(&io.interface));
}

test "nextLine rejects a bogus length header" {
    var src = TestSource{ .data = "zzzz" };
    var buf: [min_buffer_capacity]u8 = undefined;
    var io = IoReader(TestSource).init(&src, &buf);
    try std.testing.expectError(error.InvalidLength, nextLine(&io.interface));
}

test "nextLine surfaces UnexpectedEof on truncated payload" {
    // header says 11 bytes but only 8 are available
    var src = TestSource{ .data = "000bhi!!" };
    var buf: [min_buffer_capacity]u8 = undefined;
    var io = IoReader(TestSource).init(&src, &buf);
    try std.testing.expectError(error.UnexpectedEof, nextLine(&io.interface));
}
