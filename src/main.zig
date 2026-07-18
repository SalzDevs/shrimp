const std = @import("std");
const shrimp = @import("shrimp");

fn usage() noreturn {
    std.debug.print(
        \\shrimp — binary file compressor and inspector
        \\
        \\usage:
        \\  shrimp compress   <input> <output>
        \\  shrimp decompress <input> <output>
        \\
    , .{});
    std.process.exit(1);
}

fn fail(e: anyerror) noreturn {
    std.debug.print("error: {s}\n", .{@errorName(e)});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // executable name
    const cmd = args.next() orelse usage();
    const input_path = args.next() orelse usage();
    const output_path = args.next() orelse usage();
    if (args.next() != null) usage();

    if (std.mem.eql(u8, cmd, "compress")) {
        compressFile(io, gpa, input_path, output_path) catch |e| fail(e);
    } else if (std.mem.eql(u8, cmd, "decompress")) {
        decompressFile(io, input_path, output_path) catch |e| fail(e);
    } else {
        usage();
    }
}

fn compressFile(io: std.Io, gpa: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    const input = try cwd.openFile(io, input_path, .{});
    defer input.close(io);

    const size = (try input.stat(io)).size;

    // First pass: checksum the input (the header is written before the
    // blocks, so the checksum has to be known up front).
    var chunk: [shrimp.format.chunk_size]u8 = undefined;
    var crc = std.hash.Crc32.init();
    var offset: u64 = 0;
    while (true) {
        const n = try input.readPositionalAll(io, &chunk, offset);
        if (n == 0) break;
        crc.update(chunk[0..n]);
        offset += n;
    }

    // Second pass: write the container.
    const output = try cwd.createFile(io, output_path, .{});
    defer output.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr = input.reader(io, &read_buf);
    var write_buf: [8192]u8 = undefined;
    var fw = output.writer(io, &write_buf);

    const stats = try shrimp.format.compressStream(
        gpa,
        &fr.interface,
        &fw.interface,
        size,
        crc.final(),
    );
    try fw.interface.flush();

    if (stats.input_bytes == 0) {
        std.debug.print("{s}: empty input\n", .{output_path});
    } else {
        const percent = @as(f64, @floatFromInt(stats.output_bytes)) /
            @as(f64, @floatFromInt(stats.input_bytes)) * 100.0;
        std.debug.print("{s}: {d} -> {d} bytes ({d:.1}%), {d} rle + {d} raw blocks\n", .{
            output_path,           stats.input_bytes, stats.output_bytes,
            percent,               stats.rle_blocks,  stats.raw_blocks,
        });
    }
}

fn decompressFile(io: std.Io, input_path: []const u8, output_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    const input = try cwd.openFile(io, input_path, .{});
    defer input.close(io);

    const output = try cwd.createFile(io, output_path, .{});
    defer output.close(io);

    var read_buf: [8192]u8 = undefined;
    var fr = input.reader(io, &read_buf);
    var write_buf: [8192]u8 = undefined;
    var fw = output.writer(io, &write_buf);

    const stats = try shrimp.format.decompressStream(&fr.interface, &fw.interface);
    try fw.interface.flush();

    std.debug.print("{s}: {d} -> {d} bytes, checksum ok\n", .{
        output_path, stats.input_bytes, stats.output_bytes,
    });
}
