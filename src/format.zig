const std = @import("std");
const rle = @import("rle.zig");

/// `.shrimp` container format, version 1.
///
///   header:  "SHRM" | version:u8 | original_len:u64le | crc32:u32le
///   block:   type:u8 | raw_len:u32le | payload_len:u32le | payload bytes
///
/// `crc32` is CRC-32/ISO-HDLC of the *uncompressed* data.
///
/// Raw blocks store `raw_len` bytes verbatim (`payload_len == raw_len`).
/// Rle blocks store an `rle.encodeAlloc` payload. Encoders MUST fall back to
/// a raw block when rle would not shrink the block, so `payload_len <
/// raw_len` always holds and the format can never inflate data by more than
/// the per-block header.
pub const magic = "SHRM";
pub const version: u8 = 1;
pub const chunk_size: usize = 64 * 1024;

pub const header_size = magic.len + 1 + 8 + 4;
pub const block_header_size = 1 + 4 + 4;

pub const block_raw: u8 = 0;
pub const block_rle: u8 = 1;

pub const Stats = struct {
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
    raw_blocks: u32 = 0,
    rle_blocks: u32 = 0,
};

pub const FormatError = error{
    BadMagic,
    UnsupportedVersion,
    InvalidBlock,
    SizeMismatch,
    ChecksumMismatch,
};

/// Compress everything readable from `r` into `w`, chunked into blocks of at
/// most `chunk_size` bytes. `original_len` and `crc32` describe the
/// uncompressed input and must be computed by the caller beforehand (this
/// keeps compression single-pass and constant-memory; the CLI does a cheap
/// pre-pass over the input file).
pub fn compressStream(
    gpa: std.mem.Allocator,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    original_len: u64,
    crc32: u32,
) !Stats {
    try w.writeAll(magic);
    try w.writeByte(version);
    try w.writeInt(u64, original_len, .little);
    try w.writeInt(u32, crc32, .little);

    var stats: Stats = .{ .input_bytes = original_len, .output_bytes = header_size };
    var chunk: [chunk_size]u8 = undefined;
    var total: u64 = 0;

    while (true) {
        const n = try r.readSliceShort(&chunk);
        if (n == 0) break;
        total += n;

        const payload = try rle.encodeAlloc(gpa, chunk[0..n]);
        defer gpa.free(payload); // end of loop iteration

        if (payload.len < n) {
            try w.writeByte(block_rle);
            try w.writeInt(u32, @intCast(n), .little);
            try w.writeInt(u32, @intCast(payload.len), .little);
            try w.writeAll(payload);
            stats.rle_blocks += 1;
            stats.output_bytes += block_header_size + payload.len;
        } else {
            try w.writeByte(block_raw);
            try w.writeInt(u32, @intCast(n), .little);
            try w.writeInt(u32, @intCast(n), .little);
            try w.writeAll(chunk[0..n]);
            stats.raw_blocks += 1;
            stats.output_bytes += block_header_size + n;
        }
    }

    if (total != original_len) return FormatError.SizeMismatch;
    return stats;
}

/// Decompress a `.shrimp` stream from `r` into `w`, verifying the block
/// structure and the CRC-32 of the decoded data against the header.
pub fn decompressStream(r: *std.Io.Reader, w: *std.Io.Writer) !Stats {
    const magic_bytes = try r.take(magic.len);
    if (!std.mem.eql(u8, magic_bytes, magic)) return FormatError.BadMagic;

    const ver = try r.takeByte();
    if (ver != version) return FormatError.UnsupportedVersion;

    const original_len = try readIntLe(r, u64);
    const expected_crc = try readIntLe(r, u32);

    var stats: Stats = .{ .output_bytes = original_len, .input_bytes = header_size };
    var crc = std.hash.Crc32.init();
    var produced: u64 = 0;

    var chunk: [chunk_size]u8 = undefined;
    var payload_buf: [chunk_size]u8 = undefined;

    while (produced < original_len) {
        const block_type = try r.takeByte();
        const raw_len = try readIntLe(r, u32);
        const payload_len = try readIntLe(r, u32);

        if (raw_len == 0 or raw_len > chunk_size) return FormatError.InvalidBlock;
        if (raw_len > original_len - produced) return FormatError.InvalidBlock;

        const out = chunk[0..raw_len];
        switch (block_type) {
            block_raw => {
                if (payload_len != raw_len) return FormatError.InvalidBlock;
                try r.readSliceAll(out);
                stats.raw_blocks += 1;
            },
            block_rle => {
                // Guaranteed by the format's no-inflation rule.
                if (payload_len == 0 or payload_len >= raw_len) return FormatError.InvalidBlock;
                try r.readSliceAll(payload_buf[0..payload_len]);
                try rle.decode(payload_buf[0..payload_len], out);
                stats.rle_blocks += 1;
            },
            else => return FormatError.InvalidBlock,
        }

        try w.writeAll(out);
        crc.update(out);
        produced += raw_len;
        stats.input_bytes += block_header_size + payload_len;
    }

    if (crc.final() != expected_crc) return FormatError.ChecksumMismatch;
    return stats;
}

fn readIntLe(r: *std.Io.Reader, comptime T: type) !T {
    const bytes = try r.take(@sizeOf(T));
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn compressSlice(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(input);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    var crc = std.hash.Crc32.init();
    crc.update(input);
    _ = try compressStream(gpa, &reader, &aw.writer, input.len, crc.final());

    try aw.writer.flush();
    var list = aw.toArrayList();
    defer list.deinit(gpa);
    return list.toOwnedSlice(gpa);
}

fn decompressSlice(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(data);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    _ = try decompressStream(&reader, &aw.writer);

    try aw.writer.flush();
    var list = aw.toArrayList();
    defer list.deinit(gpa);
    return list.toOwnedSlice(gpa);
}

fn expectFileRoundTrip(gpa: std.mem.Allocator, input: []const u8) !Stats {
    const compressed = try compressSlice(gpa, input);
    defer gpa.free(compressed);

    const restored = try decompressSlice(gpa, compressed);
    defer gpa.free(restored);

    try std.testing.expectEqualSlices(u8, input, restored);

    var reader = std.Io.Reader.fixed(compressed);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    return decompressStream(&reader, &sink.writer);
}

test "round trip: empty input" {
    _ = try expectFileRoundTrip(std.testing.allocator, &.{});
}

test "round trip: single bytes" {
    try std.testing.expectEqual(0, (try expectFileRoundTrip(std.testing.allocator, &.{0x00})).rle_blocks);
    _ = try expectFileRoundTrip(std.testing.allocator, &.{0xFF});
    _ = try expectFileRoundTrip(std.testing.allocator, &.{0x55});
}

test "round trip: compressible data shrinks across multiple blocks" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 200_000);
    defer gpa.free(input);
    @memset(input, 0);

    const stats = try expectFileRoundTrip(gpa, input);

    try std.testing.expectEqual(4, stats.rle_blocks); // ceil(200_000 / 64K)
    try std.testing.expectEqual(0, stats.raw_blocks);
    // Decompress stats: input is the compressed size, output the original.
    try std.testing.expect(stats.input_bytes < stats.output_bytes);
}

test "round trip: incompressible data falls back to raw blocks" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 100_000);
    defer gpa.free(input);

    var prng = std.Random.DefaultPrng.init(0xbeef);
    prng.random().bytes(input);

    const stats = try expectFileRoundTrip(gpa, input);

    try std.testing.expectEqual(0, stats.rle_blocks);
    try std.testing.expect(stats.raw_blocks >= 2);
    // Overhead is only the container + block headers, never inflation.
    try std.testing.expect(stats.input_bytes <= stats.output_bytes + header_size + 3 * block_header_size);
}

test "round trip: patterned binary data" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 70_000);
    defer gpa.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i);

    _ = try expectFileRoundTrip(gpa, input);
}

test "round trip: repo fixtures" {
    // Fixture paths are relative to the repo root, i.e. the working
    // directory of `zig build test`.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    for ([_][]const u8{ "fixtures/hello", "fixtures/hello.c", "fixtures/a.txt" }) |path| {
        const bytes = try cwd.readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        _ = try expectFileRoundTrip(gpa, bytes);
    }
}

test "decompress rejects a non-shrimp file" {
    try std.testing.expectError(
        error.BadMagic,
        decompressSlice(std.testing.allocator, "just some plain text"),
    );
}

test "decompress rejects the wrong format version" {
    const gpa = std.testing.allocator;
    const compressed = try compressSlice(gpa, "hello hello hello");
    defer gpa.free(compressed);

    const corrupted = try gpa.dupe(u8, compressed);
    defer gpa.free(corrupted);
    corrupted[4] = 99;

    try std.testing.expectError(error.UnsupportedVersion, decompressSlice(gpa, corrupted));
}

test "decompress detects a tampered checksum" {
    const gpa = std.testing.allocator;
    const compressed = try compressSlice(gpa, "hello hello hello");
    defer gpa.free(compressed);

    const corrupted = try gpa.dupe(u8, compressed);
    defer gpa.free(corrupted);
    corrupted[13] ^= 0xFF; // first crc32 byte

    try std.testing.expectError(error.ChecksumMismatch, decompressSlice(gpa, corrupted));
}

test "decompress detects a corrupted payload" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 1000);
    defer gpa.free(input);
    @memset(input, 0);

    const compressed = try compressSlice(gpa, input);
    defer gpa.free(compressed);

    const corrupted = try gpa.dupe(u8, compressed);
    defer gpa.free(corrupted);
    corrupted[compressed.len - 1] ^= 0xFF; // inside the rle payload

    const result = decompressSlice(gpa, corrupted);
    if (result) |restored| {
        gpa.free(restored);
        return error.TestUnexpectedResult;
    } else |_| {}
}
