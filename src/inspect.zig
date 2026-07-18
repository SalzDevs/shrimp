const std = @import("std");
const format = @import("format.zig");
const huffman = @import("huffman.zig");

/// Exact number of count bytes a bit run of `len` occupies in an rle payload
/// (see `rle.encodeAlloc`): one byte per 255-bit segment, plus a 0-count
/// continuation byte for every full segment.
pub fn runPayloadBytes(len: u64) u64 {
    std.debug.assert(len > 0);
    return 2 * ((len - 1) / 255) + 1;
}

/// Shannon entropy of a byte distribution, in bits per byte (0–8).
pub fn entropyBitsPerByte(histogram: *const [256]u64, total: u64) f64 {
    if (total == 0) return 0;
    const n: f64 = @floatFromInt(total);
    var h: f64 = 0;
    for (histogram) |count| {
        if (count == 0) continue;
        const p = @as(f64, @floatFromInt(count)) / n;
        h -= p * std.math.log2(p);
    }
    return h;
}

/// Streaming statistics for a plain (uncompressed) file.
///
/// Feed it one encoder block (up to `format.chunk_size` bytes) at a time:
/// bit runs are reset at block boundaries exactly like the real encoder, so
/// `predicted_bytes` is the *exact* size `shrimp compress` would produce,
/// not an estimate.
pub const ByteStats = struct {
    total_bytes: u64 = 0,
    histogram: [256]u64 = [_]u64{0} ** 256,
    total_runs: u64 = 0,
    longest_run: u64 = 0,
    run_bits_sum: u64 = 0,
    predicted_bytes: u64 = format.header_size,
    predicted_raw_blocks: u32 = 0,
    predicted_rle_blocks: u32 = 0,
    predicted_huffman_blocks: u32 = 0,

    pub fn update(self: *ByteStats, chunk: []const u8) void {
        if (chunk.len == 0) return;
        self.total_bytes += chunk.len;

        var chunk_freqs: [256]u64 = [_]u64{0} ** 256;
        for (chunk) |b| {
            self.histogram[b] += 1;
            chunk_freqs[b] += 1;
        }

        var rle_payload: u64 = 1; // the start-bit byte
        var cur: u1 = @intCast(chunk[0] >> 7);
        var len: u64 = 1;
        var first = true;
        for (chunk) |byte| {
            for (0..8) |i| {
                const bit: u1 = @intCast((byte >> (7 - @as(u3, @intCast(i)))) & 1);
                if (first) {
                    first = false;
                    continue;
                }
                if (bit == cur) {
                    len += 1;
                } else {
                    rle_payload += self.recordRun(len);
                    cur = bit;
                    len = 1;
                }
            }
        }
        rle_payload += self.recordRun(len);

        // Mirrors the smallest-block decision in format.compressStream.
        var best: u64 = chunk.len;
        var kind: enum { raw, rle, huffman } = .raw;
        if (rle_payload < best) {
            best = rle_payload;
            kind = .rle;
        }
        if (huffman.planFreqs(&chunk_freqs)) |hp| {
            if (hp.payloadBytes() < best) {
                best = hp.payloadBytes();
                kind = .huffman;
            }
        }
        switch (kind) {
            .raw => self.predicted_raw_blocks += 1,
            .rle => self.predicted_rle_blocks += 1,
            .huffman => self.predicted_huffman_blocks += 1,
        }
        self.predicted_bytes += format.block_header_size + best;
    }

    fn recordRun(self: *ByteStats, len: u64) u64 {
        self.total_runs += 1;
        self.run_bits_sum += len;
        self.longest_run = @max(self.longest_run, len);
        return runPayloadBytes(len);
    }

    pub fn entropy(self: *const ByteStats) f64 {
        return entropyBitsPerByte(&self.histogram, self.total_bytes);
    }

    pub fn avgRunBits(self: *const ByteStats) f64 {
        if (self.total_runs == 0) return 0;
        return @as(f64, @floatFromInt(self.run_bits_sum)) /
            @as(f64, @floatFromInt(self.total_runs));
    }
};

/// Classic hex viewer format: offset, 16 hex bytes (split at the half),
/// ASCII gutter.
pub fn hexDump(w: *std.Io.Writer, bytes: []const u8, base_offset: u64) !void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 16) {
        const row = bytes[i..@min(i + 16, bytes.len)];
        try w.print("{x:0>8}  ", .{base_offset + i});
        for (0..16) |j| {
            if (j == 8) try w.writeByte(' ');
            if (j < row.len) {
                try w.print("{x:0>2} ", .{row[j]});
            } else {
                try w.writeAll("   ");
            }
        }
        try w.writeAll(" |");
        for (row) |b| try w.writeByte(if (std.ascii.isPrint(b)) b else '.');
        try w.writeAll("|\n");
    }
}

/// Plain-English reading of a bits-per-byte entropy value.
pub fn entropyVerdict(h: f64) []const u8 {
    if (h < 1.0) return "extremely repetitive";
    if (h < 4.0) return "compressible";
    if (h < 6.0) return "mixed content";
    if (h < 7.5) return "hard to compress";
    return "likely random or already compressed";
}

pub const ByteCount = struct { byte: u8, count: u64 };

/// The `out.len` most common bytes, most frequent first (zero counts
/// excluded).
pub fn topBytes(histogram: *const [256]u64, out: []ByteCount) []ByteCount {
    var entries: [256]ByteCount = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .byte = @intCast(i), .count = histogram[i] };
    std.mem.sort(ByteCount, &entries, {}, struct {
        fn desc(_: void, a: ByteCount, b: ByteCount) bool {
            return a.count > b.count;
        }
    }.desc);

    var n: usize = 0;
    for (entries) |e| {
        if (e.count == 0 or n == out.len) break;
        out[n] = e;
        n += 1;
    }
    return out[0..n];
}

/// The result of analyzing a file on disk: either a plain file (with
/// statistics) or a verified `.shrimp` container.
pub const Analysis = union(enum) {
    plain: Plain,
    shrimp: format.Stats,

    pub const Plain = struct {
        stats: ByteStats,
        /// First bytes of the file, as many as fit in the caller's buffer.
        dump: []const u8,
    };
};

/// Sniff the magic bytes and analyze `path` accordingly. For `.shrimp`
/// files this performs a full decode pass, so a returned `.shrimp` analysis
/// is structurally valid with a verified checksum. Up to `dump_buf.len` of
/// the first bytes of a plain file are copied into `dump_buf`.
pub fn analyzePath(io: std.Io, path: []const u8, dump_buf: []u8) !Analysis {
    const cwd = std.Io.Dir.cwd();

    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    var magic_buf: [format.magic.len]u8 = undefined;
    const magic_n = try file.readPositionalAll(io, &magic_buf, 0);

    if (magic_n == magic_buf.len and std.mem.eql(u8, &magic_buf, format.magic)) {
        var read_buf: [8192]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        const stats = try format.decompressStream(&fr.interface, &sink.writer);
        return .{ .shrimp = stats };
    }

    var stats: ByteStats = .{};
    var dump_len: usize = 0;
    var chunk: [format.chunk_size]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &chunk, offset);
        if (n == 0) break;
        if (dump_len < dump_buf.len) {
            const keep = @min(dump_buf.len - dump_len, n);
            @memcpy(dump_buf[dump_len..][0..keep], chunk[0..keep]);
            dump_len += keep;
        }
        stats.update(chunk[0..n]);
        offset += n;
    }
    return .{ .plain = .{ .stats = stats, .dump = dump_buf[0..dump_len] } };
}

/// Report for a plain (uncompressed) file.
pub fn renderReport(
    w: *std.Io.Writer,
    path: []const u8,
    stats: *const ByteStats,
    dump: []const u8,
) !void {
    try w.print("inspect: {s} ({d} bytes)\n\n", .{ path, stats.total_bytes });
    if (stats.total_bytes == 0) {
        try w.writeAll("empty file\n");
        return;
    }

    try w.print("first {d} bytes:\n", .{dump.len});
    try hexDump(w, dump, 0);

    const h = stats.entropy();
    try w.print("\nentropy: {d:.2} bits/byte — {s}\n", .{ h, entropyVerdict(h) });

    try w.writeAll("top bytes:\n");
    var top: [8]ByteCount = undefined;
    const top_slice = topBytes(&stats.histogram, &top);
    const top_count = top_slice[0].count;
    for (top_slice) |e| {
        const pct = @as(f64, @floatFromInt(e.count)) /
            @as(f64, @floatFromInt(stats.total_bytes)) * 100.0;
        const bar_len: usize = @intFromFloat(@as(f64, @floatFromInt(e.count)) /
            @as(f64, @floatFromInt(top_count)) * 24.0);
        try w.print("  0x{x:0>2} '{c}' {d:>10} {d:>5.1}%  ", .{
            e.byte,
            if (std.ascii.isPrint(e.byte)) e.byte else '.',
            e.count,
            pct,
        });
        for (0..bar_len) |_| try w.writeAll("█");
        try w.writeByte('\n');
    }

    try w.print("\nbit runs: {d} runs, avg {d:.1} bits, longest {d} bits\n", .{
        stats.total_runs, stats.avgRunBits(), stats.longest_run,
    });
    const pct = @as(f64, @floatFromInt(stats.predicted_bytes)) /
        @as(f64, @floatFromInt(stats.total_bytes)) * 100.0;
    try w.print("predicted .shrimp size: {d} bytes ({d:.1}%), {d} rle + {d} huffman + {d} raw blocks\n", .{
        stats.predicted_bytes, pct, stats.predicted_rle_blocks,
        stats.predicted_huffman_blocks, stats.predicted_raw_blocks,
    });
}

/// Report for a `.shrimp` container. `stats` comes from a full
/// `format.decompressStream` pass, so reaching this function at all means
/// the structure was valid and the checksum matched.
pub fn renderShrimpReport(w: *std.Io.Writer, path: []const u8, stats: format.Stats) !void {
    try w.print("inspect: {s} (.shrimp v{d})\n\n", .{ path, format.version });

    const pct: f64 = if (stats.output_bytes == 0) 0 else
        @as(f64, @floatFromInt(stats.input_bytes)) /
            @as(f64, @floatFromInt(stats.output_bytes)) * 100.0;

    try w.print("original:   {d} bytes\n", .{stats.output_bytes});
    try w.print("compressed: {d} bytes ({d:.1}% of original)\n", .{ stats.input_bytes, pct });
    try w.print("blocks:     {d} rle + {d} huffman + {d} raw\n", .{
        stats.rle_blocks, stats.huffman_blocks, stats.raw_blocks,
    });
    try w.writeAll("integrity:  checksum ok\n");
}

fn analyze(input: []const u8) ByteStats {
    var stats: ByteStats = .{};
    var i: usize = 0;
    while (i < input.len) : (i += format.chunk_size) {
        stats.update(input[i..@min(i + format.chunk_size, input.len)]);
    }
    return stats;
}

fn compressedLen(gpa: std.mem.Allocator, input: []const u8) !usize {
    var reader = std.Io.Reader.fixed(input);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var crc = std.hash.Crc32.init();
    crc.update(input);
    _ = try format.compressStream(gpa, &reader, &aw.writer, input.len, crc.final());
    try aw.writer.flush();

    var list = aw.toArrayList();
    defer list.deinit(gpa);
    return list.items.len;
}

test "runPayloadBytes matches the encoder's continuation scheme" {
    try std.testing.expectEqual(1, runPayloadBytes(1));
    try std.testing.expectEqual(1, runPayloadBytes(255));
    try std.testing.expectEqual(3, runPayloadBytes(256));
    try std.testing.expectEqual(3, runPayloadBytes(510));
    try std.testing.expectEqual(5, runPayloadBytes(511));
    try std.testing.expectEqual(64 - 1, runPayloadBytes(8000)); // the rle.zig case
}

test "entropy of simple distributions" {
    var single: [256]u64 = [_]u64{0} ** 256;
    single[42] = 100;
    try std.testing.expectApproxEqAbs(0.0, entropyBitsPerByte(&single, 100), 1e-12);

    var two: [256]u64 = [_]u64{0} ** 256;
    two[0] = 50;
    two[1] = 50;
    try std.testing.expectApproxEqAbs(1.0, entropyBitsPerByte(&two, 100), 1e-12);

    var uniform: [256]u64 = [_]u64{0} ** 256;
    for (&uniform) |*c| c.* = 1;
    try std.testing.expectApproxEqAbs(8.0, entropyBitsPerByte(&uniform, 256), 1e-12);
}

test "byte stats count runs like the encoder" {
    const stats = analyze(&.{ 0xFF, 0x00, 0xFF });
    try std.testing.expectEqual(3, stats.total_runs);
    try std.testing.expectEqual(8, stats.longest_run);
    try std.testing.expectApproxEqAbs(8.0, stats.avgRunBits(), 1e-12);
    try std.testing.expectEqual(2, stats.histogram[0xFF]);
    try std.testing.expectEqual(1, stats.histogram[0x00]);
}

test "predicted size equals the real compressed size" {
    const gpa = std.testing.allocator;

    const cases = [_][]const u8{
        "",
        "a",
        "short but not that short",
    };
    for (cases) |input| {
        try std.testing.expectEqual(try compressedLen(gpa, input), analyze(input).predicted_bytes);
    }

    // Fixture paths are relative to the repo root (the cwd of `zig build test`).
    const hello = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/hello", gpa, .unlimited);
    defer gpa.free(hello);
    try std.testing.expectEqual(try compressedLen(gpa, hello), analyze(hello).predicted_bytes);

    // Larger generated cases, crossing block boundaries.
    const zeros = try gpa.alloc(u8, 100_000);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    try std.testing.expectEqual(try compressedLen(gpa, zeros), analyze(zeros).predicted_bytes);

    const random = try gpa.alloc(u8, 70_000);
    defer gpa.free(random);
    var prng = std.Random.DefaultPrng.init(0xcafe);
    prng.random().bytes(random);
    try std.testing.expectEqual(try compressedLen(gpa, random), analyze(random).predicted_bytes);
}

test "hexDump full row" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try hexDump(&aw.writer, "Hello, world!\n\x00\xff", 0);
    try aw.writer.flush();

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "00000000  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 00 ff  |Hello, world!...|\n",
        list.items,
    );
}
