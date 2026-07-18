# shrimp

A binary file compressor and inspector, written in Zig.

**Status: early development.** Compression picks the smallest of three
block encodings — raw, bit-level run-length encoding, or Huffman coding —
per 64 KiB block, wrapped in a checksummed `.shrimp` container.
See [ROADMAP.md](ROADMAP.md) for the plan and `scripts/bench.sh` for a
benchmark against gzip.

## Requirements

- Zig 0.16.0

## Build

```sh
zig build          # installs to zig-out/bin/shrimp
```

## Usage

```sh
shrimp compress   <input> <output>   # e.g. shrimp compress fixtures/hello hello.shrimp
shrimp decompress <input> <output>   # verifies the checksum while decoding
shrimp inspect    <input>            # works on plain files and .shrimp containers
```

`inspect` on a plain file shows a hex dump, byte histogram, Shannon
entropy, bit-run statistics, and the *exact* size `shrimp compress` would
produce. On a `.shrimp` file it shows the container breakdown and verifies
the checksum.

## Test

```sh
zig build test
```

## The `.shrimp` format (v2)

```
header:  "SHRM" | version:u8 | original_len:u64le | crc32:u32le
block:   type:u8 | raw_len:u32le | payload_len:u32le | payload
```

- Data is processed in 64 KiB blocks; each block uses whichever encoding is
  smallest, so a `.shrimp` file never inflates its input beyond small fixed
  headers.
- Block types:
  - **raw** (0) — bytes verbatim.
  - **rle** (1) — bit runs across the whole block: a starting-bit byte
    followed by alternating run lengths (0 = empty run, continues runs past
    255 bits).
  - **huffman** (2) — canonical Huffman codes: `num_syms:u16le`, then
    `num_syms` code-length bytes, then the MSB-first packed codes. Code
    lengths are capped at 15 bits.
- `crc32` (CRC-32/ISO-HDLC) covers the uncompressed data and is verified
  during decompression. v1 files (no huffman blocks) remain readable.

## Layout

- `src/rle.zig` — bitstream RLE encoder/decoder
- `src/huffman.zig` — canonical Huffman encoder/decoder
- `src/format.zig` — `.shrimp` container (block selection, compress/decompress)
- `src/inspect.zig` — file analysis: entropy, histograms, run stats, reports
- `src/main.zig` — CLI entry point
- `scripts/bench.sh` — benchmark vs gzip
- `fixtures/` — test fixtures (a compiled Mach-O binary, its source, text)
