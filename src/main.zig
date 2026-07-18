const std = @import("std");
const shrimp = @import("shrimp");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Safety limit for file size.
    const max_size = 1024 * 1024;

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "hello",
        allocator,
        .limited(max_size),
    );
    defer allocator.free(contents);

    var rle_buffer: [8]shrimp.RleRun = undefined;
    for (contents) |byte| {
        const bits = shrimp.byte_to_bits(byte);
        const run_count = shrimp.rle(bits, &rle_buffer);
        std.debug.print("{any}\n", .{rle_buffer[0..run_count]});
    }
}
