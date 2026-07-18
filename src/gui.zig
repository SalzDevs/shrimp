const std = @import("std");
const shrimp = @import("shrimp");

const rl = @cImport({
    @cInclude("raylib.h");
});

const W = 860;
const H = 640;
const pad = 28;

fn col(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const bg = col(22, 23, 31);
const panel = col(33, 35, 47);
const border = col(60, 63, 80);
const text_col = col(232, 233, 240);
const dim = col(148, 151, 166);
const accent = col(99, 179, 237);
const green = col(90, 200, 130);
const amber = col(230, 185, 90);
const red = col(225, 95, 95);

fn lighten(c: rl.Color) rl.Color {
    return .{
        .r = c.r +| (255 - c.r) / 5,
        .g = c.g +| (255 - c.g) / 5,
        .b = c.b +| (255 - c.b) / 5,
        .a = 255,
    };
}

fn verdictColor(h: f64) rl.Color {
    if (h < 4.0) return green;
    if (h < 6.0) return amber;
    return red;
}

/// Format and draw text in one call (all rendering goes through here so
/// strings stay ASCII-safe for raylib's default font).
fn drawText(x: i32, y: i32, size: i32, color: rl.Color, comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, fmt, args) catch return;
    rl.DrawText(s.ptr, x, y, size, color);
}

fn commas(buf: []u8, value: u64) []const u8 {
    var tmp: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    var n: usize = 0;
    for (digits, 0..) |d, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = d;
        n += 1;
    }
    return buf[0..n];
}

fn bar(x: i32, y: i32, w: i32, h: i32, frac: f32, fill: rl.Color) void {
    rl.DrawRectangle(x, y, w, h, panel);
    const fw: i32 = @intFromFloat(@as(f32, @floatFromInt(w)) * @max(0, @min(1, frac)));
    if (fw > 0) rl.DrawRectangle(x, y, fw, h, fill);
}

fn button(rect: rl.Rectangle, label: []const u8, color: rl.Color) bool {
    var b: [256]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, "{s}", .{label}) catch return false;

    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), rect);
    rl.DrawRectangleRounded(rect, 0.3, 8, if (hover) lighten(color) else color);
    const tw = rl.MeasureText(s.ptr, 16);
    rl.DrawText(
        s.ptr,
        @intFromFloat(rect.x + (rect.width - @as(f32, @floatFromInt(tw))) / 2),
        @intFromFloat(rect.y + (rect.height - 16) / 2),
        16,
        bg,
    );
    return hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
}

const Result = struct {
    text: [320]u8 = undefined,
    len: usize = 0,
    ok: bool = true,
};

const PlainView = struct {
    stats: shrimp.inspect.ByteStats,
    result: ?Result = null,
};

const ShrimpView = struct {
    stats: shrimp.format.Stats,
    result: ?Result = null,
};

const View = union(enum) {
    empty,
    plain: PlainView,
    shrimp: ShrimpView,
    failure: []const u8,
};

const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    view: View = .empty,
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    out_buf: [4096]u8 = undefined,
    err_buf: [128]u8 = undefined,

    fn path(self: *const App) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn fail(self: *App, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.view = .{ .failure = self.err_buf[0..n] };
    }

    fn loadPath(self: *App, p: []const u8) void {
        if (p.len >= self.path_buf.len) {
            self.fail("path too long");
            return;
        }
        @memcpy(self.path_buf[0..p.len], p);
        self.path_len = p.len;

        const analysis = shrimp.inspect.analyzePath(self.io, self.path(), &.{}) catch |e| {
            self.fail(@errorName(e));
            return;
        };
        switch (analysis) {
            .plain => |pl| self.view = .{ .plain = .{ .stats = pl.stats } },
            .shrimp => |st| self.view = .{ .shrimp = .{ .stats = st } },
        }
    }

    fn outPath(self: *App, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(&self.out_buf, fmt, args) catch unreachable;
    }

    fn compress(self: *App) void {
        const result = &self.view.plain.result;
        result.* = .{};

        const out = self.outPath("{s}.shrimp", .{self.path()});
        const stats = shrimp.format.compressFile(self.io, self.gpa, self.path(), out) catch |e| {
            self.setResult(result, "compress failed: {s}", .{@errorName(e)}, false);
            return;
        };

        const verified = verifyRoundTrip(self.io, self.gpa, self.path(), out);
        const ok = verified orelse true;
        self.setResult(result, "{s} written - {d} bytes ({d:.1}%){s}", .{
            std.fs.path.basename(out),
            stats.output_bytes,
            pct(stats.output_bytes, stats.input_bytes),
            if (verified) |v| (if (v) " - verified identical" else " - VERIFICATION FAILED") else " - not verified (large file)",
        }, ok);
    }

    fn decompress(self: *App) void {
        const result = &self.view.shrimp.result;
        result.* = .{};

        // Output: the input name minus ".shrimp", with a fallback that never
        // clobbers an existing file.
        const p = self.path();
        const stripped = if (std.mem.endsWith(u8, p, ".shrimp")) p[0 .. p.len - ".shrimp".len] else p;
        var out = self.outPath("{s}", .{stripped});
        if (fileExists(self.io, out)) out = self.outPath("{s}.out", .{stripped});

        const stats = shrimp.format.decompressFile(self.io, p, out) catch |e| {
            self.setResult(result, "decompress failed: {s}", .{@errorName(e)}, false);
            return;
        };
        self.setResult(result, "{s} written - {d} bytes - checksum ok", .{
            std.fs.path.basename(out),
            stats.output_bytes,
        }, true);
    }

    fn setResult(self: *App, result: *?Result, comptime fmt: []const u8, args: anytype, ok: bool) void {
        _ = self;
        var r: Result = .{ .ok = ok };
        const s = std.fmt.bufPrint(&r.text, fmt, args) catch blk: {
            const truncated = "message too long";
            @memcpy(r.text[0..truncated.len], truncated);
            break :blk r.text[0..truncated.len];
        };
        r.len = s.len;
        result.* = r;
    }

    fn draw(self: *App) void {
        rl.ClearBackground(bg);
        switch (self.view) {
            .empty => drawEmpty(),
            .plain => |*v| self.drawPlain(v),
            .shrimp => |*v| self.drawShrimp(v),
            .failure => |msg| drawFailure(msg),
        }
        drawText(W - pad - 90, H - 26, 12, dim, "esc to quit", .{});
    }

    fn drawHeader(self: *App) void {
        drawText(pad, 24, 28, accent, "shrimp", .{});
        if (self.view != .empty) {
            drawText(W - pad - 220, 34, 13, dim, "drop another file to replace", .{});
        }
    }

    fn drawPlain(self: *App, v: *PlainView) void {
        self.drawHeader();
        var y: i32 = 76;
        var cb: [40]u8 = undefined;

        drawText(pad, y, 20, text_col, "{s}", .{std.fs.path.basename(self.path())});
        y += 28;
        drawText(pad, y, 14, dim, "{s} bytes", .{commas(&cb, v.stats.total_bytes)});
        y += 34;

        if (v.stats.total_bytes == 0) {
            drawText(pad, y, 16, dim, "empty file", .{});
            y += 30;
        } else {
            const h = v.stats.entropy();
            drawText(pad, y, 15, dim, "entropy", .{});
            bar(pad + 130, y + 2, 330, 14, @floatCast(h / 8.0), verdictColor(h));
            drawText(pad + 476, y - 1, 15, text_col, "{d:.2} bits/byte - {s}", .{ h, shrimp.inspect.entropyVerdict(h) });
            y += 42;

            drawText(pad, y, 15, dim, "most common bytes", .{});
            y += 26;
            var top: [8]shrimp.inspect.ByteCount = undefined;
            const tops = shrimp.inspect.topBytes(&v.stats.histogram, &top);
            const maxc: f64 = @floatFromInt(tops[0].count);
            for (tops) |e| {
                const p = @as(f64, @floatFromInt(e.count)) / @as(f64, @floatFromInt(v.stats.total_bytes)) * 100.0;
                drawText(pad, y, 14, text_col, "0x{x:0>2} '{c}'", .{ e.byte, if (std.ascii.isPrint(e.byte)) e.byte else '.' });
                bar(pad + 110, y + 2, 330, 12, @floatCast(@as(f64, @floatFromInt(e.count)) / maxc), accent);
                drawText(pad + 456, y, 14, dim, "{d:.1}%", .{p});
                y += 24;
            }
            y += 18;

            var cb2: [40]u8 = undefined;
            var cb3: [40]u8 = undefined;
            drawText(pad, y, 14, dim, "bit runs: {s} - avg {d:.1} bits - longest {s} bits", .{
                commas(&cb, v.stats.total_runs),
                v.stats.avgRunBits(),
                commas(&cb2, v.stats.longest_run),
            });
            y += 28;
            drawText(pad, y, 15, text_col, "shrinks to {s} bytes ({d:.1}%)", .{
                commas(&cb3, v.stats.predicted_bytes),
                pct(v.stats.predicted_bytes, v.stats.total_bytes),
            });
            y += 22;
            drawText(pad, y, 13, dim, "{d} rle - {d} huffman - {d} raw blocks", .{
                v.stats.predicted_rle_blocks, v.stats.predicted_huffman_blocks, v.stats.predicted_raw_blocks,
            });
            y += 34;
        }

        var lb: [300]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "Compress -> {s}.shrimp", .{std.fs.path.basename(self.path())}) catch "Compress";
        if (button(.{ .x = pad, .y = @floatFromInt(y), .width = 300, .height = 42 }, label, accent)) {
            self.compress();
        }
        y += 58;

        if (v.result) |*r| drawResult(y, r);
    }

    fn drawShrimp(self: *App, v: *ShrimpView) void {
        self.drawHeader();
        var y: i32 = 76;
        var cb: [40]u8 = undefined;
        var cb2: [40]u8 = undefined;

        drawText(pad, y, 20, text_col, "{s}", .{std.fs.path.basename(self.path())});
        y += 28;
        drawText(pad, y, 14, dim, ".shrimp container (v{d})", .{shrimp.format.version});
        y += 40;

        drawText(pad, y, 15, dim, "original", .{});
        drawText(pad + 130, y, 15, text_col, "{s} bytes", .{commas(&cb, v.stats.output_bytes)});
        y += 28;
        drawText(pad, y, 15, dim, "compressed", .{});
        drawText(pad + 130, y, 15, text_col, "{s} bytes ({d:.1}%)", .{
            commas(&cb2, v.stats.input_bytes), pct(v.stats.input_bytes, v.stats.output_bytes),
        });
        y += 28;
        drawText(pad, y, 15, dim, "blocks", .{});
        drawText(pad + 130, y, 15, text_col, "{d} rle - {d} huffman - {d} raw", .{
            v.stats.rle_blocks, v.stats.huffman_blocks, v.stats.raw_blocks,
        });
        y += 28;
        drawText(pad, y, 15, dim, "integrity", .{});
        drawText(pad + 130, y, 15, green, "checksum ok", .{});
        y += 46;

        var lb: [300]u8 = undefined;
        const base = std.fs.path.basename(self.path());
        const stripped = if (std.mem.endsWith(u8, base, ".shrimp")) base[0 .. base.len - ".shrimp".len] else base;
        const label = std.fmt.bufPrint(&lb, "Decompress -> {s}", .{stripped}) catch "Decompress";
        if (button(.{ .x = pad, .y = @floatFromInt(y), .width = 300, .height = 42 }, label, accent)) {
            self.decompress();
        }
        y += 58;

        if (v.result) |*r| drawResult(y, r);
    }
};

fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole)) * 100.0;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Decompress `shrimp_path` in memory and compare against the source.
/// Returns null when verification is skipped (unreadable/large source).
fn verifyRoundTrip(io: std.Io, gpa: std.mem.Allocator, src_path: []const u8, shrimp_path: []const u8) ?bool {
    const cwd = std.Io.Dir.cwd();
    const original = cwd.readFileAlloc(io, src_path, gpa, .limited(256 * 1024 * 1024)) catch return null;
    defer gpa.free(original);

    const file = cwd.openFile(io, shrimp_path, .{}) catch return null;
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = shrimp.format.decompressStream(&fr.interface, &aw.writer) catch return false;
    aw.writer.flush() catch return false;

    var list = aw.toArrayList();
    defer list.deinit(gpa);
    return std.mem.eql(u8, original, list.items);
}

fn drawEmpty() void {
    drawText(pad, 24, 28, accent, "shrimp", .{});
    drawText(pad, 58, 13, dim, "binary file compressor and inspector", .{});

    const rect: rl.Rectangle = .{ .x = pad, .y = 150, .width = W - 2 * pad, .height = 300 };
    rl.DrawRectangleRounded(rect, 0.06, 12, panel);
    rl.DrawRectangleRoundedLines(rect, 0.06, 12, border);

    drawText(W / 2 - 130, 270, 24, text_col, "Drop a file here", .{});
    drawText(W / 2 - 150, 310, 14, dim, "any file is analyzed the moment it lands", .{});
    drawText(W / 2 - 160, 380, 13, dim, "entropy - histogram - predicted compressed size", .{});
}

fn drawFailure(msg: []const u8) void {
    drawText(pad, 24, 28, accent, "shrimp", .{});
    const rect: rl.Rectangle = .{ .x = pad, .y = 200, .width = W - 2 * pad, .height = 120 };
    rl.DrawRectangleRounded(rect, 0.08, 12, panel);
    rl.DrawRectangle(pad, 200, 4, 120, red);
    drawText(pad + 20, 232, 17, red, "could not read that file", .{});
    drawText(pad + 20, 264, 15, text_col, "{s}", .{msg});
    drawText(pad + 20, 296, 13, dim, "drop another file to try again", .{});
}

fn drawResult(y: i32, r: *const Result) void {
    const c = if (r.ok) green else red;
    rl.DrawRectangle(pad, y, W - 2 * pad, 48, panel);
    rl.DrawRectangle(pad, y, 4, 48, c);
    drawText(pad + 16, y + 15, 15, text_col, "{s}", .{r.text[0..r.len]});
}

pub fn main(init: std.process.Init) !void {
    var smoke = false;
    var initial: ?[]const u8 = null;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--smoke")) {
            smoke = true;
        } else if (initial == null) {
            initial = a;
        }
    }

    rl.InitWindow(W, H, "shrimp");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    var app: App = .{ .io = init.io, .gpa = init.gpa };
    if (initial) |p| app.loadPath(p);

    var frames: u32 = 0;
    while (!rl.WindowShouldClose()) {
        if (rl.IsFileDropped()) {
            const dropped = rl.LoadDroppedFiles();
            if (dropped.count > 0) app.loadPath(std.mem.span(dropped.paths[0]));
            rl.UnloadDroppedFiles(dropped);
        }

        rl.BeginDrawing();
        app.draw();
        rl.EndDrawing();

        frames += 1;
        if (smoke and frames >= 2) {
            // Headless smoke test: exercise the action of the current view.
            switch (app.view) {
                .plain => {
                    app.compress();
                    const r = app.view.plain.result.?;
                    std.debug.print("smoke compress: {s}\n", .{r.text[0..r.len]});
                },
                .shrimp => {
                    app.decompress();
                    const r = app.view.shrimp.result.?;
                    std.debug.print("smoke decompress: {s}\n", .{r.text[0..r.len]});
                },
                else => {},
            }
            break;
        }
    }
}
