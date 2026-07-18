const std = @import("std");

/// Maximum Huffman code length, in bits. Blocks whose optimal codes exceed
/// this are not huffman-coded (the format layer falls back to another block
/// type).
pub const max_code_len = 15;

/// An encoding plan for one block: the code lengths, the table size, and the
/// exact payload size `encodeAlloc` would produce — so the format layer can
/// compare block types without encoding them all.
pub const Plan = struct {
    /// Code length per symbol (0 = symbol not present).
    lens: [256]u8,
    /// 1 + highest used symbol; the table is stored as that many length bytes.
    num_syms: u16,
    /// Total encoded size of the data, in bits.
    total_bits: u64,

    pub fn payloadBytes(self: *const Plan) u64 {
        return 2 + self.num_syms + (self.total_bits + 7) / 8;
    }
};

/// Compute the optimal code lengths for a frequency distribution, or null if
/// the data is empty or the optimal code exceeds `max_code_len`.
pub fn planFreqs(freqs: *const [256]u64) ?Plan {
    var used: usize = 0;
    var max_sym: u16 = 0;
    for (freqs, 0..) |f, s| {
        if (f != 0) {
            used += 1;
            max_sym = @intCast(s);
        }
    }
    if (used == 0) return null;

    var lens: [256]u8 = [_]u8{0} ** 256;

    if (used == 1) {
        // Degenerate case: a single symbol gets a 1-bit code.
        for (freqs, 0..) |f, s| {
            if (f != 0) {
                lens[s] = 1;
                break;
            }
        }
    } else {
        // Build the Huffman tree by repeatedly merging the two
        // lowest-frequency nodes (ties broken by lowest index, keeping this
        // deterministic). Leaves are 0..256, internal nodes follow.
        var freq: [512]u64 = undefined;
        var parent: [512]u16 = undefined;
        var alive: [512]bool = undefined;
        var nodes: usize = 256;
        for (0..256) |s| {
            freq[s] = freqs[s];
            parent[s] = 0;
            alive[s] = freqs[s] != 0;
        }

        var remaining = used;
        while (remaining > 1) : (remaining -= 1) {
            var m1: ?usize = null;
            var m2: ?usize = null;
            for (0..nodes) |i| {
                if (!alive[i]) continue;
                if (m1 == null or freq[i] < freq[m1.?]) {
                    m2 = m1;
                    m1 = i;
                } else if (m2 == null or freq[i] < freq[m2.?]) {
                    m2 = i;
                }
            }
            const a = m1.?;
            const b = m2.?;
            alive[a] = false;
            alive[b] = false;
            freq[nodes] = freq[a] + freq[b];
            parent[a] = @intCast(nodes);
            parent[b] = @intCast(nodes);
            alive[nodes] = true;
            nodes += 1;
        }

        const root = nodes - 1;
        for (0..256) |s| {
            if (freqs[s] == 0) continue;
            var depth: u16 = 0;
            var n = s;
            while (n != root) {
                depth += 1;
                n = parent[n];
            }
            if (depth > max_code_len) return null;
            lens[s] = @intCast(depth);
        }
    }

    var total_bits: u64 = 0;
    for (0..256) |s| total_bits += freqs[s] * lens[s];

    return .{
        .lens = lens,
        .num_syms = max_sym + 1,
        .total_bits = total_bits,
    };
}

/// Convenience wrapper: histogram `data`, then `planFreqs`.
pub fn plan(data: []const u8) ?Plan {
    var freqs: [256]u64 = [_]u64{0} ** 256;
    for (data) |b| freqs[b] += 1;
    return planFreqs(&freqs);
}

/// Assign canonical codes: same length => codes in symbol order, shorter
/// codes numerically smaller (RFC 1951 style). Decoder rebuilds identical
/// codes from the lengths alone.
fn canonicalCodes(lens: *const [256]u8) [256]u16 {
    var bl_count = [_]u16{0} ** (max_code_len + 1);
    for (lens) |l| {
        if (l != 0) bl_count[l] += 1;
    }
    var next = [_]u16{0} ** (max_code_len + 1);
    var code: u16 = 0;
    for (1..max_code_len + 1) |bits| {
        code = (code + bl_count[bits - 1]) << 1;
        next[bits] = code;
    }
    var codes = [_]u16{0} ** 256;
    for (0..256) |s| {
        const l = lens[s];
        if (l != 0) {
            codes[s] = next[l];
            next[l] += 1;
        }
    }
    return codes;
}

/// MSB-first bit accumulator.
const BitWriter = struct {
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    acc: u8 = 0,
    nbits: u8 = 0,

    fn writeCode(self: *BitWriter, code: u16, len: u8) !void {
        var i: u8 = 0;
        while (i < len) : (i += 1) {
            const bit: u8 = @intCast((code >> @intCast(len - 1 - i)) & 1);
            self.acc = (self.acc << 1) | bit;
            self.nbits += 1;
            if (self.nbits == 8) {
                try self.list.append(self.gpa, self.acc);
                self.acc = 0;
                self.nbits = 0;
            }
        }
    }

    fn finish(self: *BitWriter) !void {
        if (self.nbits > 0) {
            self.acc <<= @intCast(8 - self.nbits);
            try self.list.append(self.gpa, self.acc);
        }
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readBit(self: *BitReader) error{Truncated}!u1 {
        if (self.pos >= self.data.len * 8) return error.Truncated;
        const bit: u1 = @intCast((self.data[self.pos / 8] >> @intCast(7 - self.pos % 8)) & 1);
        self.pos += 1;
        return bit;
    }
};

/// Encode `data` according to `p` (which must come from `plan(data)`).
///
/// Layout: num_syms:u16le | num_syms code-length bytes | packed bits
/// (MSB-first, zero-padded to a byte).
pub fn encodeAlloc(gpa: std.mem.Allocator, data: []const u8, p: *const Plan) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.append(gpa, @truncate(p.num_syms));
    try out.append(gpa, @truncate(p.num_syms >> 8));
    for (0..p.num_syms) |s| try out.append(gpa, p.lens[s]);

    const codes = canonicalCodes(&p.lens);
    var bw: BitWriter = .{ .list = &out, .gpa = gpa };
    for (data) |b| try bw.writeCode(codes[b], p.lens[b]);
    try bw.finish();

    return out.toOwnedSlice(gpa);
}

pub const DecodeError = error{
    /// Malformed code table (bad length, over-subscribed), or a code with no
    /// matching symbol.
    InvalidPayload,
    /// The payload ended before `out` was filled.
    Truncated,
};

/// Decode a payload produced by `encodeAlloc` into `out` (exactly `out.len`
/// symbols; padding bits in the final byte are ignored).
pub fn decode(payload: []const u8, out: []u8) DecodeError!void {
    if (payload.len < 2) return error.Truncated;
    const num_syms = std.mem.readInt(u16, payload[0..2], .little);
    if (num_syms == 0) return error.InvalidPayload;
    if (payload.len < 2 + num_syms) return error.Truncated;

    var lens: [256]u8 = [_]u8{0} ** 256;
    @memcpy(lens[0..num_syms], payload[2..][0..num_syms]);

    var counts = [_]u16{0} ** (max_code_len + 1);
    for (lens) |l| {
        if (l > max_code_len) return error.InvalidPayload;
        if (l != 0) counts[l] += 1;
    }

    // Over-subscription check (incomplete codes are fine: the degenerate
    // single-symbol table is one).
    var left: i32 = 1;
    for (1..max_code_len + 1) |len| {
        left <<= 1;
        left -= counts[len];
        if (left < 0) return error.InvalidPayload;
    }

    // Symbols ordered by (code length, symbol value) — the canonical order.
    var symbols: [256]u8 = undefined;
    var nsyms: usize = 0;
    for (1..max_code_len + 1) |len| {
        for (0..256) |s| {
            if (lens[s] == len) {
                symbols[nsyms] = @intCast(s);
                nsyms += 1;
            }
        }
    }
    if (nsyms == 0) return error.InvalidPayload;

    var br: BitReader = .{ .data = payload[2 + num_syms ..] };
    for (out) |*o| {
        // Walk lengths, accumulating one bit at a time, until the accumulated
        // code lands in a range assigned to this length.
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        var matched = false;
        for (1..max_code_len + 1) |len| {
            code |= @intCast(try br.readBit());
            const count = counts[len];
            if (code - first < count) {
                o.* = symbols[@intCast(index + (code - first))];
                matched = true;
                break;
            }
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        if (!matched) return error.InvalidPayload;
    }
}

fn expectRoundTrip(gpa: std.mem.Allocator, data: []const u8) !void {
    const p = plan(data) orelse return error.TestUnexpectedResult;
    const payload = try encodeAlloc(gpa, data, &p);
    defer gpa.free(payload);

    // The plan's size estimate must be exact — the format layer relies on it.
    try std.testing.expectEqual(p.payloadBytes(), payload.len);

    const decoded = try gpa.alloc(u8, data.len);
    defer gpa.free(decoded);
    try decode(payload, decoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "round trip: skewed data at many sizes" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xfeed);
    const rand = prng.random();

    const sizes = [_]usize{ 2, 3, 10, 100, 1000, 4096, 65536 };
    var buf: [65536]u8 = undefined;
    for (sizes) |size| {
        const data = buf[0..size];
        for (data) |*b| {
            // 87.5% zeros, rest spread over a few symbols.
            b.* = if (rand.uintLessThan(u8, 8) == 0) rand.uintLessThan(u8, 16) else 0;
        }
        try expectRoundTrip(gpa, data);
    }
}

test "round trip: single repeated symbol" {
    const gpa = std.testing.allocator;
    const data = try gpa.alloc(u8, 1000);
    defer gpa.free(data);
    @memset(data, 0xAB);

    const p = plan(data).?;
    try std.testing.expectEqual(1, p.lens[0xAB]);
    try std.testing.expectEqual(1000, p.total_bits);
    try expectRoundTrip(gpa, data);
}

test "round trip: two symbols get 1-bit codes" {
    try expectRoundTrip(std.testing.allocator, "ababababba");
    const p = plan("ababababba").?;
    try std.testing.expectEqual(1, p.lens['a']);
    try std.testing.expectEqual(1, p.lens['b']);
}

test "round trip: all 256 symbols" {
    const gpa = std.testing.allocator;
    var data: [256 * 100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    try expectRoundTrip(gpa, &data);
}

test "planning rejects code lengths beyond the limit" {
    // Fibonacci frequencies force a maximally deep Huffman tree.
    var freqs: [256]u64 = [_]u64{0} ** 256;
    var a: u64 = 1;
    var b: u64 = 1;
    for (0..20) |s| {
        freqs[s] = a;
        const next = a + b;
        a = b;
        b = next;
    }
    try std.testing.expect(planFreqs(&freqs) == null);
}

test "empty data has no plan" {
    try std.testing.expect(plan(&.{}) == null);
}

test "frequent symbols get shorter codes" {
    const p = plan("aaaabbc").?;
    try std.testing.expect(p.lens['a'] < p.lens['b']);
    try std.testing.expect(p.lens['b'] <= p.lens['c']);
    // 4*1 + 2*2 + 1*2 = 10 bits.
    try std.testing.expectEqual(10, p.total_bits);
}

test "decode rejects malformed payloads" {
    var out: [4]u8 = undefined;

    // Too short to hold a table header.
    try std.testing.expectError(error.Truncated, decode(&.{0}, &out));
    // Empty table.
    try std.testing.expectError(error.InvalidPayload, decode(&.{ 0, 0 }, &out));
    // Table says 4 length bytes, payload is shorter.
    try std.testing.expectError(error.Truncated, decode(&.{ 4, 0, 1, 1 }, &out));
    // Code length over the limit.
    try std.testing.expectError(error.InvalidPayload, decode(&.{ 1, 0, 99 }, &out));
    // Over-subscribed: three 1-bit codes cannot exist.
    try std.testing.expectError(error.InvalidPayload, decode(&.{ 3, 0, 1, 1, 1 }, &out));
}
