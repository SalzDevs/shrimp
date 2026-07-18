const std = @import("std");
const shrimp = @import("shrimp");

fn usage() noreturn {
    std.debug.print(
        \\shrimp — binary file compressor and inspector
        \\
        \\usage:
        \\  shrimp compress   <input> <output>
        \\  shrimp decompress <input> <output>
        \\  shrimp inspect    <input>
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

    if (std.mem.eql(u8, cmd, "compress")) {
        const input_path = args.next() orelse usage();
        const output_path = args.next() orelse usage();
        if (args.next() != null) usage();
        compressFile(io, gpa, input_path, output_path) catch |e| fail(e);
    } else if (std.mem.eql(u8, cmd, "decompress")) {
        const input_path = args.next() orelse usage();
        const output_path = args.next() orelse usage();
        if (args.next() != null) usage();
        decompressFile(io, input_path, output_path) catch |e| fail(e);
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        const input_path = args.next() orelse usage();
        if (args.next() != null) usage();
        inspectFile(io, input_path) catch |e| fail(e);
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

/// Inspect a plain file or a `.shrimp` container (detected by magic bytes).
fn inspectFile(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var magic_buf: [shrimp.format.magic.len]u8 = undefined;
    const magic_n = try file.readPositionalAll(io, &magic_buf, 0);

    if (magic_n == magic_buf.len and std.mem.eql(u8, &magic_buf, shrimp.format.magic)) {
        // A full decompress pass doubles as structure + checksum verification.
        var read_buf: [8192]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        const stats = try shrimp.format.decompressStream(&fr.interface, &sink.writer);
        try shrimp.inspect.renderShrimpReport(w, path, stats);
    } else {
        var stats: shrimp.inspect.ByteStats = .{};
        var dump: [256]u8 = undefined;
        var dump_len: usize = 0;
        var chunk: [shrimp.format.chunk_size]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try file.readPositionalAll(io, &chunk, offset);
            if (n == 0) break;
            if (dump_len < dump.len) {
                const keep = @min(dump.len - dump_len, n);
                @memcpy(dump[dump_len..][0..keep], chunk[0..keep]);
                dump_len += keep;
            }
            stats.update(chunk[0..n]);
            offset += n;
        }
        try shrimp.inspect.renderReport(w, path, &stats, dump[0..dump_len]);
    }

    try w.flush();
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
