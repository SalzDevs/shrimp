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

### Phase 0 — Hygiene (quick wins, do first)
1. Add `.gitignore` (`.zig-cache/`, `zig-out/`, `main`, `main.o`) and
   `git rm -r --cached .zig-cache`.
2. Add `build.zig` with `run` and `test` steps; move code to `src/main.zig`.
3. Flesh out the README: what shrimp is, how to build/run.

### Phase 1 — A correct, round-trippable core
4. Rework RLE to operate on a **bitstream across the whole input**, not
   per-byte. Decide the run encoding (e.g. count as fixed-width field, with
   an escape/max-run continuation for runs > max).
5. Write `BitWriter` / `BitReader` (MSB-first, matching `byte_to_bits`).
6. Write the decoder. **Property test: `decode(encode(x)) == x`** for random
   buffers, empty input, all-zeros, all-ones, alternating bits, and `hello`.
   This test is the foundation everything else stands on.

### Phase 2 — Real file format + CLI
7. Define a container format: magic bytes (`SHRIMP`/`0x53...`), format
   version, original length, checksum (CRC32 or xxhash), then block stream.
8. Add a **raw block type** so incompressible data is stored verbatim
   (small header overhead) instead of expanding.
9. CLI with subcommands: `shrimp compress <in> <out>`,
   `shrimp decompress <in> <out>`. Stream I/O, no hardcoded paths, no 1 MB cap.

### Phase 3 — The inspector (differentiator)
10. `shrimp inspect <file>`:
    - hex/ASCII dump view,
    - byte-value histogram + Shannon entropy (predicts compressibility),
    - run-length statistics (longest run, avg run, % of runs ≥ N),
    - for `.shrimp` files: header info, block breakdown, ratio, checksum verify.
11. Round-trip verification in CI: `compress | decompress | diff` on a corpus.

### Phase 4 — Beyond RLE (optional, if ratio matters)
RLE alone only wins on very repetitive data. A natural progression:
byte-level RLE (PackBits-style) → Huffman coding → LZ77 + Huffman
(DEFLATE-lite). Benchmark against `gzip -1` on a fixed corpus to keep honest
numbers.

## Suggested immediate next step
Phase 0, then Phase 1 items 4–6 as one unit of work: *"stream-wide bit RLE
with a decoder and a round-trip property test."* That converts shrimp from a
printer into a compressor with a safety net.
