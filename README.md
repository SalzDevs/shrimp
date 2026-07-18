# shrimp

A binary file compressor and inspector, written in Zig.

**Status: early development.** Compression currently uses stream-wide
bit-level run-length encoding (RLE) with a raw-block fallback, wrapped in a
checksummed `.shrimp` container. See [ROADMAP.md](ROADMAP.md) for the plan.

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

## The `.shrimp` format (v1)

```
header:  "SHRM" | version:u8 | original_len:u64le | crc32:u32le
block:   type:u8 | raw_len:u32le | payload_len:u32le | payload
```

- Data is processed in 64 KiB blocks.
- A block is stored **rle** only when that is smaller, otherwise **raw** —
  so a `.shrimp` file never inflates its input beyond small fixed headers.
- RLE payloads encode bit runs across the whole block: a starting-bit byte
  followed by alternating run lengths (0 = empty run, used to continue runs
  past 255 bits).
- `crc32` (CRC-32/ISO-HDLC) covers the uncompressed data and is verified
  during decompression.

## Layout

- `src/rle.zig` — bitstream RLE encoder/decoder
- `src/format.zig` — `.shrimp` container (compress/decompress streams)
- `src/inspect.zig` — file analysis: entropy, histograms, run stats, reports
- `src/main.zig` — CLI entry point
- `fixtures/` — test fixtures (a compiled Mach-O binary, its source, text)
