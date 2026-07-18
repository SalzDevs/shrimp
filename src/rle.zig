const std = @import("std");

/// Maximum length of a single encoded run. Longer runs are continued with
/// empty runs of the opposite bit (see `encodeAlloc`).
pub const max_run = 255;

/// Expand a byte into its 8 bits, most-significant bit first.
pub fn byte_to_bits(byte: u8) [8]u1 {
    var bits: [8]u1 = undefined;
    for (0..8) |i| {
        const shift_amount: u3 = @intCast(i);
        bits[i] = @intCast((byte >> (7 - shift_amount)) & 1);
    }
    return bits;
}

/// Run-length encode the bits of `input` (MSB-first) into a byte payload.
/// Runs cross byte boundaries: the whole input is treated as one bitstream.
///
/// Layout:
///   payload[0]   = the starting bit (0 or 1)
///   payload[1..] = run lengths; the bit value alternates with each run
///
/// A run length of 0 toggles the bit without emitting anything, which is how
/// runs longer than 255 bits are continued.
///
/// Worst case payload size is 8 * input.len + 1 bytes (alternating bits).
/// Caller owns the returned slice.
pub fn encodeAlloc(gpa: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    std.debug.assert(input.len > 0);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var current: u1 = @intCast(input[0] >> 7);
    try out.append(gpa, current);
    var count: u8 = 1;

    var first = true;
    for (input) |byte| {
        for (byte_to_bits(byte)) |bit| {
            if (first) {
                first = false;
                continue;
            }
            if (bit == current) {
                if (count == max_run) {
                    // Continue the run: empty run of the opposite bit, then
                    // the current bit picks up again.
                    try out.append(gpa, max_run);
                    try out.append(gpa, 0);
                    count = 1;
                } else {
                    count += 1;
                }
            } else {
                try out.append(gpa, count);
                current = bit;
                count = 1;
            }
        }
    }
    try out.append(gpa, count);

    return out.toOwnedSlice(gpa);
}

pub const DecodeError = error{
    /// The starting-bit byte is not 0 or 1, or the payload has trailing junk.
    InvalidPayload,
    /// The payload ended before `out` was filled.
    Truncated,
    /// A run length overruns the end of `out`.
    Overflow,
};

/// Decode a payload produced by `encodeAlloc` into `out` (`out.len * 8` bits).
/// The payload must decode to exactly `out.len` bytes.
pub fn decode(payload: []const u8, out: []u8) DecodeError!void {
    if (out.len == 0) {
        if (payload.len != 0) return error.InvalidPayload;
        return;
    }
    if (payload.len == 0) return error.Truncated;

    var current: u1 = switch (payload[0]) {
        0 => 0,
        1 => 1,
        else => return error.InvalidPayload,
    };

    @memset(out, 0);
    var payload_pos: usize = 1;
    var bit_pos: usize = 0;
    const total_bits = out.len * 8;

    while (bit_pos < total_bits) {
        if (payload_pos >= payload.len) return error.Truncated;
        const count = payload[payload_pos];
        payload_pos += 1;
        if (count > total_bits - bit_pos) return error.Overflow;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (current == 1) {
                out[bit_pos / 8] |= @as(u8, 1) << @intCast(7 - bit_pos % 8);
            }
            bit_pos += 1;
        }
        current = ~current;
    }

    if (payload_pos != payload.len) return error.InvalidPayload;
}

fn expectRoundTrip(input: []const u8) !void {
    const gpa = std.testing.allocator;
    const payload = try encodeAlloc(gpa, input);
    defer gpa.free(payload);

    const decoded = try gpa.alloc(u8, input.len);
    defer gpa.free(decoded);
    try decode(payload, decoded);

    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "byte_to_bits is MSB first" {
    try std.testing.expectEqualSlices(u1, &.{ 1, 0, 1, 1, 0, 0, 1, 1 }, &byte_to_bits(0b10110011));
    try std.testing.expectEqualSlices(u1, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, &byte_to_bits(0x00));
    try std.testing.expectEqualSlices(u1, &.{ 1, 1, 1, 1, 1, 1, 1, 1 }, &byte_to_bits(0xFF));
}

test "round trip: exhaustive single bytes" {
    var b: u16 = 0;
    while (b <= 0xFF) : (b += 1) {
        try expectRoundTrip(&.{@intCast(b)});
    }
}

test "round trip: repetitive data actually shrinks" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 300);
    defer gpa.free(input);
    @memset(input, 0xFF);

    const payload = try encodeAlloc(gpa, input);
    defer gpa.free(payload);

    // 2400 one-bits: roughly 2400/255 run segments, 2 bytes each.
    try std.testing.expect(payload.len < 32);

    const decoded = try gpa.alloc(u8, input.len);
    defer gpa.free(decoded);
    try decode(payload, decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "round trip: runs longer than 255 bits use continuation" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 1000);
    defer gpa.free(input);
    @memset(input, 0x00);

    const payload = try encodeAlloc(gpa, input);
    defer gpa.free(payload);

    // 8000 zero-bits = 31 full segments (255, 0) + a final run of 95:
    // 1 start byte + 31*2 + 1 = 64 bytes.
    try std.testing.expectEqual(64, payload.len);

    const decoded = try gpa.alloc(u8, input.len);
    defer gpa.free(decoded);
    try decode(payload, decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "round trip: alternating bits is the worst case" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 100);
    defer gpa.free(input);
    @memset(input, 0xAA);

    const payload = try encodeAlloc(gpa, input);
    defer gpa.free(payload);

    // Every bit is its own run: 800 counts + 1 start byte.
    try std.testing.expectEqual(801, payload.len);

    const decoded = try gpa.alloc(u8, input.len);
    defer gpa.free(decoded);
    try decode(payload, decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "round trip: pseudo-random data at many sizes" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();

    const sizes = [_]usize{ 1, 2, 3, 5, 8, 13, 64, 100, 1000, 4096, 65536 };
    var buf: [65536]u8 = undefined;
    for (sizes) |size| {
        const input = buf[0..size];
        rand.bytes(input);
        try expectRoundTrip(input);
    }
}

test "decode rejects malformed payloads" {
    var out: [4]u8 = undefined;

    // Starting bit must be 0 or 1.
    try std.testing.expectError(error.InvalidPayload, decode(&.{ 2, 8 }, &out));
    // Empty payload cannot fill a non-empty output.
    try std.testing.expectError(error.Truncated, decode(&.{}, &out));
    // Payload that ends too early.
    try std.testing.expectError(error.Truncated, decode(&.{ 0, 3 }, &out));
    // A run that overruns the output.
    try std.testing.expectError(error.Overflow, decode(&.{ 0, 255, 0, 255, 0, 255, 0, 255 }, &out));
    // Valid data followed by junk.
    try std.testing.expectError(error.InvalidPayload, decode(&.{ 1, 32, 99 }, &out));
}
