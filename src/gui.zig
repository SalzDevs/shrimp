const std = @import("std");
const shrimp = @import("shrimp");

const rl = @cImport({
    @cInclude("raylib.h");
});

const W = 860;
const H = 640;
const pad = 28;

const inter_ttf = @embedFile("fonts/Inter.ttf");
const mono_ttf = @embedFile("fonts/JetBrainsMono.ttf");

const Fonts = struct { ui: rl.Font, mono: rl.Font };
var fonts: Fonts = undefined;

/// Load a TTF baked at 64px (scaled down per draw call). Falls back to
/// raylib's built-in font if loading fails.
fn loadFont(data: []const u8) rl.Font {
    const f = rl.LoadFontFromMemory(".ttf", data.ptr, @intCast(data.len), 64, null, 0);
    if (f.texture.id == 0) return rl.GetFontDefault();
    rl.SetTextureFilter(f.texture, rl.TEXTURE_FILTER_BILINEAR);
    return f;
}

fn col(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

// Shrimp brand: warm-neutral darks, coral reserved for actions and key
// numbers. green/amber/red stay semantic (entropy verdict, success, error).
const bg = col(25, 23, 22);
const panel = col(37, 34, 32);
const border = col(64, 57, 53);
const text_col = col(240, 236, 232);
const dim = col(160, 150, 142);
const accent = col(255, 107, 94); // coral #FF6B5E
const green = col(95, 198, 125);
const amber = col(232, 188, 95);
const red = col(238, 96, 90);

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
/// strings stay ASCII-safe for the loaded fonts).
fn drawText(font: rl.Font, x: i32, y: i32, size: i32, color: rl.Color, comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, fmt, args) catch return;
    rl.DrawTextEx(font, s.ptr, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, @floatFromInt(size), 0, color);
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
    const m = rl.MeasureTextEx(fonts.ui, s.ptr, 16, 0);
    rl.DrawTextEx(
        fonts.ui,
        s.ptr,
        .{ .x = rect.x + (rect.width - m.x) / 2, .y = rect.y + (rect.height - 16) / 2 },
        16,
        0,
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
    details_open: bool = false,
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
        drawText(fonts.ui, winW() - pad - 90, winH() - 26, 12, dim, "esc to quit", .{});
    }

    fn drawHeader(self: *App) void {
        drawText(fonts.ui, pad, 24, 28, accent, "shrimp", .{});
        if (self.view != .empty) {
            drawText(fonts.ui, winW() - pad - 220, 34, 13, dim, "drop another file to replace", .{});
        }
    }

    fn drawPlain(self: *App, v: *PlainView) void {
        self.drawHeader();
        const ww = winW();
        const wh = winH();
        var y: i32 = 76;
        var cb: [40]u8 = undefined;

        drawText(fonts.mono, pad, y, 22, text_col, "{s}", .{std.fs.path.basename(self.path())});
        y += 30;
        drawText(fonts.mono, pad, y, 14, dim, "{s} bytes", .{commas(&cb, v.stats.total_bytes)});
        y += 40;

        if (v.stats.total_bytes == 0) {
            drawText(fonts.ui, pad, y, 16, dim, "empty file", .{});
            y += 32;
        } else {
            const h = v.stats.entropy();
            drawText(fonts.ui, pad, y, 15, dim, "entropy", .{});
            bar(pad + 130, y + 1, @min(360, ww - 2 * pad - 130 - 340), 16, @floatCast(h / 8.0), verdictColor(h));
            drawText(fonts.mono, ww - pad - 324, y - 1, 15, text_col, "{d:.2} bits/byte - {s}", .{ h, shrimp.inspect.entropyVerdict(h) });
            y += 46;

            var cb3: [40]u8 = undefined;
            drawText(fonts.mono, pad, y, 18, accent, "shrinks to {s} bytes ({d:.1}%)", .{
                commas(&cb3, v.stats.predicted_bytes),
                pct(v.stats.predicted_bytes, v.stats.total_bytes),
            });
            y += 40;
        }

        var lb: [300]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "Compress -> {s}.shrimp", .{std.fs.path.basename(self.path())}) catch "Compress";
        if (button(.{ .x = pad, .y = @floatFromInt(y), .width = 300, .height = 42 }, label, accent)) {
            self.compress();
        }
        y += 58;

        if (v.result) |*r| {
            drawResult(y, r);
            y += 64;
        }

        // Progressive disclosure: analysis details on demand.
        if (v.stats.total_bytes > 0 and y < wh - 70) {
            if (link(pad, y, if (self.details_open) "[-] details" else "[+] details")) {
                self.details_open = !self.details_open;
            }
            y += 30;
            if (self.details_open) self.drawPlainDetails(v, y, ww, wh);
        }
    }

    fn drawPlainDetails(self: *App, v: *PlainView, y_start: i32, ww: i32, wh: i32) void {
        _ = self;
        var y = y_start;
        var cb: [40]u8 = undefined;
        var cb2: [40]u8 = undefined;

        drawText(fonts.ui, pad, y, 15, dim, "most common bytes", .{});
        y += 28;
        var top: [8]shrimp.inspect.ByteCount = undefined;
        const tops = shrimp.inspect.topBytes(&v.stats.histogram, &top);
        const maxc: f64 = @floatFromInt(tops[0].count);
        for (tops) |e| {
            if (y > wh - 70) break; // clip: window too short for more rows
            const p = @as(f64, @floatFromInt(e.count)) / @as(f64, @floatFromInt(v.stats.total_bytes)) * 100.0;
            drawText(fonts.mono, pad, y, 14, text_col, "0x{x:0>2} '{c}'", .{ e.byte, if (std.ascii.isPrint(e.byte)) e.byte else '.' });
            bar(pad + 110, y + 2, @min(520, ww - 2 * pad - 110 - 100), 14, @floatCast(@as(f64, @floatFromInt(e.count)) / maxc), accent);
            drawText(fonts.mono, ww - pad - 84, y, 14, dim, "{d:.1}%", .{p});
            y += 25;
        }
        y += 20;
        if (y < wh - 70) {
            drawText(fonts.mono, pad, y, 14, dim, "bit runs: {s} - avg {d:.1} bits - longest {s} bits", .{
                commas(&cb, v.stats.total_runs),
                v.stats.avgRunBits(),
                commas(&cb2, v.stats.longest_run),
            });
            y += 26;
            drawText(fonts.mono, pad, y, 13, dim, "{d} rle - {d} huffman - {d} raw blocks", .{
                v.stats.predicted_rle_blocks, v.stats.predicted_huffman_blocks, v.stats.predicted_raw_blocks,
            });
        }
    }

    fn drawShrimp(self: *App, v: *ShrimpView) void {
        self.drawHeader();
        var y: i32 = 76;
        var cb: [40]u8 = undefined;
        var cb2: [40]u8 = undefined;

        drawText(fonts.mono, pad, y, 22, text_col, "{s}", .{std.fs.path.basename(self.path())});
        y += 30;
        drawText(fonts.ui, pad, y, 14, dim, ".shrimp container (v{d})", .{shrimp.format.version});
        y += 42;

        drawText(fonts.ui, pad, y, 15, dim, "original", .{});
        drawText(fonts.mono, pad + 130, y, 15, text_col, "{s} bytes", .{commas(&cb, v.stats.output_bytes)});
        y += 28;
        drawText(fonts.ui, pad, y, 15, dim, "compressed", .{});
        drawText(fonts.mono, pad + 130, y, 15, text_col, "{s} bytes ({d:.1}%)", .{
            commas(&cb2, v.stats.input_bytes), pct(v.stats.input_bytes, v.stats.output_bytes),
        });
        y += 28;
        drawText(fonts.ui, pad, y, 15, dim, "blocks", .{});
        drawText(fonts.mono, pad + 130, y, 15, text_col, "{d} rle - {d} huffman - {d} raw", .{
            v.stats.rle_blocks, v.stats.huffman_blocks, v.stats.raw_blocks,
        });
        y += 28;
        drawText(fonts.ui, pad, y, 15, dim, "integrity", .{});
        drawText(fonts.ui, pad + 130, y, 15, green, "checksum ok", .{});
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

fn winW() i32 {
    return rl.GetScreenWidth();
}

fn winH() i32 {
    return rl.GetScreenHeight();
}

fn drawCentered(font: rl.Font, y: i32, size: i32, color: rl.Color, comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, fmt, args) catch return;
    const m = rl.MeasureTextEx(font, s.ptr, @floatFromInt(size), 0);
    rl.DrawTextEx(font, s.ptr, .{ .x = (@as(f32, @floatFromInt(winW())) - m.x) / 2, .y = @floatFromInt(y) }, @floatFromInt(size), 0, color);
}

/// A clickable text link (used for the details toggle).
fn link(x: i32, y: i32, label: []const u8) bool {
    var b: [64]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, "{s}", .{label}) catch return false;
    const m = rl.MeasureTextEx(fonts.ui, s.ptr, 15, 0);
    const rect: rl.Rectangle = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = m.x, .height = 20 };
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), rect);
    drawText(fonts.ui, x, y, 15, if (hover) accent else dim, "{s}", .{label});
    return hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
}

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
    const ww = winW();
    const wh = winH();
    drawText(fonts.ui, pad, 24, 28, accent, "shrimp", .{});
    drawText(fonts.ui, pad, 58, 13, dim, "binary file compressor and inspector", .{});

    const rect: rl.Rectangle = .{
        .x = pad,
        .y = @floatFromInt(@divTrunc(wh, 2) - 170),
        .width = @floatFromInt(ww - 2 * pad),
        .height = 340,
    };
    rl.DrawRectangleRounded(rect, 0.06, 12, panel);
    rl.DrawRectangleRoundedLines(rect, 0.06, 12, border);

    drawCentered(fonts.ui, @divTrunc(wh, 2) - 50, 24, text_col, "Drop a file here", .{});
    drawCentered(fonts.ui, @divTrunc(wh, 2) - 10, 14, dim, "any file is analyzed the moment it lands", .{});
    drawCentered(fonts.ui, @divTrunc(wh, 2) + 70, 13, dim, "entropy - histogram - predicted compressed size", .{});
}

fn drawFailure(msg: []const u8) void {
    drawText(fonts.ui, pad, 24, 28, accent, "shrimp", .{});
    const rect: rl.Rectangle = .{ .x = pad, .y = 200, .width = @floatFromInt(winW() - 2 * pad), .height = 120 };
    rl.DrawRectangleRounded(rect, 0.08, 12, panel);
    rl.DrawRectangle(pad, 200, 4, 120, red);
    drawText(fonts.ui, pad + 20, 232, 17, red, "could not read that file", .{});
    drawText(fonts.mono, pad + 20, 264, 15, text_col, "{s}", .{msg});
    drawText(fonts.ui, pad + 20, 296, 13, dim, "drop another file to try again", .{});
}

fn drawResult(y: i32, r: *const Result) void {
    const c = if (r.ok) green else red;
    rl.DrawRectangle(pad, y, winW() - 2 * pad, 48, panel);
    rl.DrawRectangle(pad, y, 4, 48, c);
    drawText(fonts.mono, pad + 16, y + 15, 15, text_col, "{s}", .{r.text[0..r.len]});
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

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(W, H, "shrimp");
    defer rl.CloseWindow();
    rl.SetWindowMinSize(800, 560);
    rl.SetTargetFPS(60);

    fonts = .{ .ui = loadFont(inter_ttf), .mono = loadFont(mono_ttf) };
    defer {
        const default_id = rl.GetFontDefault().texture.id;
        if (fonts.ui.texture.id != default_id) rl.UnloadFont(fonts.ui);
        if (fonts.mono.texture.id != default_id) rl.UnloadFont(fonts.mono);
    }

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
