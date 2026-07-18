const std = @import("std");

pub const RleRun = struct {
    bit: u1,
    count: u8,
};

/// Expand a byte into its 8 bits, most-significant bit first.
pub fn byte_to_bits(byte: u8) [8]u1 {
    var bits: [8]u1 = undefined;
    for (0..8) |i| {
        const shift_amount: u3 = @intCast(i);
        bits[i] = @intCast((byte >> (7 - shift_amount)) & 1);
    }
    return bits;
}

/// Run-length encode the 8 bits of a single byte into `buffer`.
///
/// `buffer` must have room for at least 8 runs (worst case: an alternating
/// byte like 0b01010101 produces one run per bit).
///
/// Returns the number of runs written to `buffer`.
pub fn rle(bits: [8]u1, buffer: []RleRun) usize {
    std.debug.assert(buffer.len >= 8);
    var total_bits: u8 = 1;
    var num_count: usize = 0;
    var prev_bit = bits[0];
    var count: u8 = 1;

    for (bits[1..]) |bit| {
        if (bit == prev_bit) {
            count += 1;
            total_bits += 1;
        } else {
            buffer[num_count] = .{ .bit = prev_bit, .count = count };
            num_count += 1;
            prev_bit = bit;
            count = 1;
            total_bits += 1;
        }
    }
    std.debug.assert(total_bits == 8);
    buffer[num_count] = .{ .bit = prev_bit, .count = count };

    return num_count + 1;
}

test "byte_to_bits is MSB first" {
    const bits = byte_to_bits(0b10110011);
    try std.testing.expectEqualSlices(u1, &.{ 1, 0, 1, 1, 0, 0, 1, 1 }, &bits);
}

test "byte_to_bits of zero and max" {
    try std.testing.expectEqualSlices(u1, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, &byte_to_bits(0x00));
    try std.testing.expectEqualSlices(u1, &.{ 1, 1, 1, 1, 1, 1, 1, 1 }, &byte_to_bits(0xFF));
}

test "rle of a uniform byte is a single run of 8" {
    var buffer: [8]RleRun = undefined;
    const n = rle(byte_to_bits(0xFF), &buffer);
    try std.testing.expectEqual(1, n);
    try std.testing.expectEqual(RleRun{ .bit = 1, .count = 8 }, buffer[0]);
}

test "rle of an alternating byte is 8 runs of 1" {
    var buffer: [8]RleRun = undefined;
    const n = rle(byte_to_bits(0b01010101), &buffer);
    try std.testing.expectEqual(8, n);
    for (buffer[0..n], 0..) |run, i| {
        try std.testing.expectEqual(1, run.count);
        try std.testing.expectEqual(@as(u1, @intCast(i % 2)), run.bit);
    }
}

test "rle run counts always sum to 8" {
    var buffer: [8]RleRun = undefined;
    var byte: u16 = 0;
    while (byte <= 0xFF) : (byte += 1) {
        const n = rle(byte_to_bits(@intCast(byte)), &buffer);
        var sum: u8 = 0;
        for (buffer[0..n]) |run| sum += run.count;
        try std.testing.expectEqual(8, sum);
    }
}
