const std = @import("std");

pub const RleRun = struct {
    bit: u1,
    count: u8,
};

pub fn byte_to_bits(byte: u8) [8]u1 {
    var bits: [8]u1 = undefined;
    for (0..8) |i| {
        const shift_amount: u3 = @intCast(i);
        bits[i] = @intCast((byte >> (7 - shift_amount)) & 1);
    }
    return bits;
}

pub fn rle(bits: [8]u1, buffer: []RleRun) usize {
    //buffer should have at minimun 8 slots (for 8 bits 1 byte)
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
    //make sure buffer has 8 bytes exactly after rle pass
    std.debug.assert(total_bits==8); 
    buffer[num_count] = .{ .bit = prev_bit, .count = count };
    
    // Return the total number of runs populated in the buffer
    return num_count + 1; 
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;     
    const allocator = init.gpa;

    //safety limit for file size
    const max_size = 1024 * 1024; 

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io, 
        "hello", 
        allocator, 
        .limited(max_size),
    );
    var rle_buffer: [8]RleRun = undefined;

    defer allocator.free(contents);
    for (contents) |byte| {
        rle_buffer = undefined;
        const bits = byte_to_bits(byte);
        const run_count = rle(bits,&rle_buffer);
        std.debug.print("{any}\n", .{rle_buffer[0..run_count]});
    }

}
