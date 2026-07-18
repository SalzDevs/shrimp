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
        reportCompress(io, gpa, input_path, output_path) catch |e| fail(e);
    } else if (std.mem.eql(u8, cmd, "decompress")) {
        const input_path = args.next() orelse usage();
        const output_path = args.next() orelse usage();
        if (args.next() != null) usage();
        reportDecompress(io, input_path, output_path) catch |e| fail(e);
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        const input_path = args.next() orelse usage();
        if (args.next() != null) usage();
        reportInspect(io, input_path) catch |e| fail(e);
    } else {
        usage();
    }
}

fn reportCompress(io: std.Io, gpa: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const stats = try shrimp.format.compressFile(io, gpa, input_path, output_path);

    if (stats.input_bytes == 0) {
        std.debug.print("{s}: empty input\n", .{output_path});
    } else {
        const percent = @as(f64, @floatFromInt(stats.output_bytes)) /
            @as(f64, @floatFromInt(stats.input_bytes)) * 100.0;
        std.debug.print("{s}: {d} -> {d} bytes ({d:.1}%), {d} rle + {d} huffman + {d} raw blocks\n", .{
            output_path,       stats.input_bytes, stats.output_bytes,
            percent,           stats.rle_blocks,  stats.huffman_blocks,
            stats.raw_blocks,
        });
    }
}

fn reportDecompress(io: std.Io, input_path: []const u8, output_path: []const u8) !void {
    const stats = try shrimp.format.decompressFile(io, input_path, output_path);
    std.debug.print("{s}: {d} -> {d} bytes, checksum ok\n", .{
        output_path, stats.input_bytes, stats.output_bytes,
    });
}

fn reportInspect(io: std.Io, input_path: []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var dump: [256]u8 = undefined;
    const analysis = try shrimp.inspect.analyzePath(io, input_path, &dump);

    switch (analysis) {
        .plain => |p| try shrimp.inspect.renderReport(w, input_path, &p.stats, p.dump),
        .shrimp => |s| try shrimp.inspect.renderShrimpReport(w, input_path, s),
    }

    try w.flush();
}
