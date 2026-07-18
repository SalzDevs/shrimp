# shrimp — Status Report & Roadmap

_Report date: 2025-07-18, based on commit `14e5158`._

## What exists today

A single `main.zig` (~60 lines, Zig 0.16.0) that:

- `byte_to_bits(byte) -> [8]u1` — expands a byte into 8 bits, MSB first.
- `rle(bits, buffer) -> usize` — run-length encodes the **8 bits of one byte**
  into `RleRun { bit: u1, count: u8 }` records.
- `main` — reads a hardcoded file (`hello`, a 33 KB Mach-O binary), RLE-encodes
  each byte independently, and prints the runs with `std.debug.print`
  (33,432 lines of output — one per input byte).

Plus test fixtures: `hello.c` / `hello` (compiled test binary), `a.txt`.

## Where the gaps are

### 1. It doesn't compress anything yet
Nothing is ever written to disk. There is no output format, no bitstream,
no file. The program is currently a *visualizer* of per-byte bit runs.

### 2. The RLE is byte-aligned, which cripples the ratio
Runs reset every 8 bits. A run of 100 zeros crossing byte boundaries becomes
12+ separate runs. For a bit-level RLE scheme, runs must span the whole
stream, not stop at byte edges.

### 3. Worst case is expansion, silently
An alternating byte (`0b01010101`) produces 8 runs from 1 byte. Real binaries
(Mach-O code, compressed sections) are high-entropy — bit-level RLE will
*grow* `hello`, not shrink it. Any real format needs a "store raw" fallback
block type.

### 4. No decoder, so no proof of correctness
There is no `unrle`. Without a round-trip (`decode(encode(x)) == x`) there is
no way to know the encoder is even right.

### 5. No project scaffolding
- No `build.zig` (currently built ad-hoc with `zig build-exe`).
- No `.gitignore` — **`.zig-cache` is committed to git**.
- No tests, no CI, `README.md` is one line.

### 6. Code-level nits in `main.zig`
- `total_bits` exists only to assert its own counting — dead bookkeeping.
- `rle_buffer = undefined` inside the loop is a no-op.
- Whole-file read with a 1 MB cap — a compressor should stream.
- `count: u8` caps runs at 255; a stream-wide RLE needs wider counts or
  escape coding.
- Output goes to `std.debug.print` instead of a `Writer`.

## Roadmap

### Phase 0 — Hygiene ✅ DONE
1. ✅ `.gitignore` added; `.zig-cache` untracked.
2. ✅ `build.zig` + `build.zig.zon`; code under `src/` (`root.zig` library
   module + `main.zig` CLI).
3. ✅ README with build/run/test instructions.

### Phase 1 — A correct, round-trippable core ✅ DONE
4. ✅ Stream-wide bit RLE in `src/rle.zig`: runs cross byte boundaries;
   u8 counts with empty-run (0-count) continuation for runs > 255 bits.
5. ⏭️ Skipped a general `BitWriter`/`BitReader` for now: the RLE payload is
   byte-aligned (start bit + count bytes), so one wasn't needed. Revisit for
   Huffman (Phase 4).
6. ✅ Decoder + property tests: `decode(encode(x)) == x` over random buffers
   (many sizes), exhaustive single bytes, all-zeros, all-ones, alternating,
   plus malformed-payload rejection.

### Phase 2 — Real file format + CLI ✅ DONE
7. ✅ `.shrimp` v1 container: `"SHRM"` magic, version, original length,
   CRC-32/ISO-HDLC of the uncompressed data (verified on decompress).
8. ✅ Raw-block fallback is a *format rule* (rle only when smaller), so
   inflation is capped at 17 + 9 bytes per 64 KiB block.
9. ✅ `shrimp compress/decompress <in> <out>`: streaming, 64 KiB blocks,
   constant memory; compress does a checksum pre-pass (two passes total).

Verified end-to-end: `hello` 33,432 → 5,319 bytes (15.9%), 512 KiB of zeros
→ 6.3%, 512 KiB of random → 100.0% (raw fallback), empty file, corruption
detection (BadMagic / Overflow / ChecksumMismatch), all round-trips
byte-identical. Baseline: `gzip -1` gets `hello` to 1,227 bytes — the gap
is what Phase 4 is for.

### Phase 3 — The inspector ✅ DONE
10. ✅ `shrimp inspect <file>` (magic-detects `.shrimp` vs plain):
    - hex/ASCII dump of the first 256 bytes,
    - top-8 byte histogram with bars + Shannon entropy (with a plain-English
      verdict),
    - bit-run statistics (count, average, longest),
    - **exact** predicted `.shrimp` size — the stats accumulator mirrors the
      encoder's per-block raw/rle decisions (property-tested against the real
      compressor, including multi-block and fixture files),
    - `.shrimp` files: original/compressed sizes, ratio, rle/raw block
      counts, checksum verified via a full decode pass.
11. ✅ Corpus round-trip wired into `zig build test`: repo fixtures
    (`fixtures/hello`, `hello.c`, `a.txt`) round-trip on every test run.
    (No CI service yet — the suite is CI-ready.)

Future inspector ideas: per-block table for `.shrimp` files, `--dump-all`
hex view, histogram of run lengths, JSON output mode.

### Phase 4 — Huffman coding ✅ DONE
- ✅ Canonical Huffman as a third block type (`src/huffman.zig`): per-block
  code-length table, MSB-first packed codes, 15-bit length cap with
  fallback, full malformed-table validation. BitWriter/BitReader landed here
  (the Phase 1 item that was deferred).
- ✅ Best-of-block selection in `format.compressStream` (raw / rle /
  huffman per 64 KiB block, smallest wins) — the no-inflation rule now spans
  all three types. Format bumped to **v2**; v1 files remain readable.
- ✅ Inspector mirrors the three-way decision (prediction stays exact,
  property-tested) and reports predicted block types.
- ✅ `scripts/bench.sh` vs gzip. Current numbers:

  | file | orig | shrimp | gzip -1 | gzip -9 |
  |---|---|---|---|---|
  | hello (Mach-O) | 33,432 | 5,229 (15.6%) | 1,227 (3.7%) | 1,024 (3.1%) |
  | zig-source | 48,564 | 29,663 (61.1%) | 14,858 (30.6%) | 12,073 (24.9%) |
  | zeros-1M | 1,048,576 | 65,985 (6.3%) | 4,617 (0.4%) | 1,060 (0.1%) |
  | random-1M | 1,048,576 | 1,048,737 (100.0%) | 1,048,924 | 1,048,924 |
  | /bin/ls | 154,624 | 62,258 (40.3%) | 35,294 (22.8%) | 33,667 (21.8%) |

**Key finding:** Huffman floors at 1 bit per symbol occurrence — 32,535
zero bytes cost ≥ 32,535 bits no matter the skew. Approaching sub-1-bit
entropy requires coding a better token stream (runs/matches) or arithmetic
coding. Where Huffman shines vs our bit-RLE is skewed non-runny data
(source code: RLE inflates ~8×, Huffman gets 61%).

### GUI ✅ DONE (v1)
Native desktop app (`src/gui.zig`, all-Zig + raylib, cross-platform):
- Single-window, drag-and-drop driven: drop any file for instant analysis
  (entropy bar + verdict, top-bytes histogram, bit-run stats, exact
  predicted `.shrimp` size), one-click compress/decompress.
- Outputs auto-named next to the source (`<name>.shrimp` / stripped name),
  with a no-clobber fallback; every compress verified via in-memory
  round-trip.
- Library refactor: file-level `format.compressFile`/`decompressFile` and
  `inspect.analyzePath` are now shared by CLI and GUI (no logic duplication).
- `zig build run-gui`; `-Draylib-prefix=` for non-Homebrew installs;
  `--smoke [file]` headless self-test (also exercises the actions).
- Note: raylib 5.5 init crashed once flakily in this session (GLFW monitor
  detection race, not app code); `--smoke` is the regression check.

Future GUI polish: hex-dump view, native save/open dialogs
(tinyfiledialogs), recent-files list, .shrimp block map visualization,
app bundling (.app + icon).

### Phase 5 — LZ77 (next, if ratio still matters)
The remaining ~2× gap to gzip is all about repeated multi-byte patterns,
which neither RLE nor Huffman can see. Plan: greedy hash-chain LZ77 over a
32–64 KiB window, tokens (literals / length-distance pairs) written through
the existing Huffman machinery as a fourth block type (DEFLATE-lite).
Considered and skipped: Huffman-coding the RLE count stream — marginal
gains for a dead-end stepping stone.

## Suggested immediate next step
Phase 0, then Phase 1 items 4–6 as one unit of work: *"stream-wide bit RLE
with a decoder and a round-trip property test."* That converts shrimp from a
printer into a compressor with a safety net.
