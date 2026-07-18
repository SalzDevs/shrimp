#!/bin/sh
# Benchmark shrimp against gzip on a small corpus.
# Usage: scripts/bench.sh
set -e
cd "$(dirname "$0")/.."

zig build
S=./zig-out/bin/shrimp
WORK=/tmp/shrimp-bench
mkdir -p "$WORK"

# Generated corpus entries.
dd if=/dev/zero of="$WORK/zeros-1M" bs=1024 count=1024 2>/dev/null
dd if=/dev/urandom of="$WORK/random-1M" bs=1024 count=1024 2>/dev/null
cat src/*.zig > "$WORK/zig-source"

printf '%-14s %10s %10s %8s %10s %8s %10s %8s\n' \
    file orig shrimp '%' 'gzip -1' '%' 'gzip -9' '%'

bench() {
    f=$1
    orig=$(stat -f%z "$f")
    $S compress "$f" "$WORK/out.shrimp" >/dev/null 2>&1
    sh=$(stat -f%z "$WORK/out.shrimp")
    g1=$(gzip -1 -c "$f" | wc -c | tr -d ' ')
    g9=$(gzip -9 -c "$f" | wc -c | tr -d ' ')
    pct() { awk "BEGIN { if ($1 == 0) print \"-\"; else printf \"%.1f\", $2 * 100 / $1 }"; }
    printf '%-14s %10s %10s %8s %10s %8s %10s %8s\n' \
        "$(basename "$f")" "$orig" \
        "$sh" "$(pct "$orig" "$sh")" \
        "$g1" "$(pct "$orig" "$g1")" \
        "$g9" "$(pct "$orig" "$g9")"
}

for f in fixtures/hello fixtures/hello.c fixtures/a.txt \
         "$WORK/zig-source" "$WORK/zeros-1M" "$WORK/random-1M" /bin/ls; do
    bench "$f"
done

rm -rf "$WORK"
