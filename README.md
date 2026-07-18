# shrimp

A binary file compressor and inspector, written in Zig.

**Status: early development.** The core currently performs bit-level
run-length encoding (RLE) of file contents. See [ROADMAP.md](ROADMAP.md)
for the plan.

## Requirements

- Zig 0.16.0

## Build

```sh
zig build          # installs to zig-out/bin/shrimp
```

## Run

```sh
zig build run      # reads ./hello and prints per-byte bit runs
```

## Test

```sh
zig build test
```

## Layout

- `src/root.zig` — compression core (library module, importable as `shrimp`)
- `src/main.zig` — CLI entry point
- `hello.c`, `hello`, `a.txt` — test fixtures
