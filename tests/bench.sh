#!/bin/sh
# Compare native pdftotext against the WASI module: wall time, CPU, peak RSS.
#
# Generates its own large fixture; nothing is committed. Needs a native pdftotext and wasmtime.
#
# Usage: tests/bench.sh [pages] [runs]

set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
DIST=${DIST:-$REPO_ROOT/dist}
# 1000 pages by default: enough work that startup noise does not dominate the "work" row, and
# the size the README's table was measured at.
PAGES=${1:-1000}
RUNS=${2:-10}

command -v pdftotext >/dev/null 2>&1 || { echo "need a native pdftotext" >&2; exit 1; }
command -v wasmtime >/dev/null 2>&1 || { echo "need wasmtime" >&2; exit 1; }
[ -f "$DIST/pdftotext.wasm" ] || { echo "no $DIST/pdftotext.wasm; run 'make build'" >&2; exit 1; }

# /usr/bin/time is BSD on macOS (-l) and GNU on Linux (-v); the two report differently too.
if /usr/bin/time -l true >/dev/null 2>&1; then
    TIME_FLAG=-l
elif /usr/bin/time -v true >/dev/null 2>&1; then
    TIME_FLAG=-v
else
    echo "need /usr/bin/time supporting -l (BSD) or -v (GNU)" >&2; exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
pdf="$tmp/bench.pdf"

# DONTWRITEBYTECODE: importing make_fixtures would otherwise litter tests/fixtures/__pycache__.
PYTHONDONTWRITEBYTECODE=1 python3 - "$pdf" "$PAGES" "$HERE/fixtures" <<'PY'
import pathlib
import sys

out, pages, fixtures_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sys.path.insert(0, fixtures_dir)
from make_fixtures import build_pdf, text_block  # noqa: E402

body = []
for p in range(pages):
    lines = [f"Page {p + 1} line {i}: the quick brown fox jumps over the lazy dog." for i in range(40)]
    body.append(text_block(lines, 54, 740, size=9, leading=17))
pathlib.Path(out).write_bytes(build_pdf(body, compress=True))
PY

printf 'fixture: %s pages, %s KiB, %s runs each\n\n' \
    "$PAGES" "$(( $(wc -c <"$pdf") / 1024 ))" "$RUNS"

# best-of-N wall clock in milliseconds
best_wall() {
    _best=''
    _i=0
    while [ "$_i" -lt "$RUNS" ]; do
        _start=$(python3 -c 'import time;print(int(time.perf_counter()*1000))')
        "$@" >/dev/null 2>&1
        _end=$(python3 -c 'import time;print(int(time.perf_counter()*1000))')
        _ms=$((_end - _start))
        [ -n "$_best" ] && [ "$_best" -le "$_ms" ] || _best=$_ms
        _i=$((_i + 1))
    done
    printf '%s' "$_best"
}

# total cpu seconds and peak RSS in KiB, from one run. The two time formats cannot collide: BSD
# spells its RSS line lowercase and reports bytes, GNU capitalises it and reports KiB.
resources() {
    /usr/bin/time "$TIME_FLAG" "$@" >/dev/null 2>"$tmp/time.txt" || true
    awk '
        / real .* user .* sys/      { cpu = $3 + $5 }
        /maximum resident set size/ { rss = $1 / 1024 }
        /User time \(seconds\)/     { cpu += $NF }
        /System time \(seconds\)/   { cpu += $NF }
        /Maximum resident set size/ { rss = $NF }
        END { printf "%.2f %d", cpu, rss }
    ' "$tmp/time.txt"
}

# AOT-compile once, to separate JIT cost from execution.
cwasm="$tmp/pdftotext.cwasm"
wasmtime compile "$DIST/pdftotext.wasm" -o "$cwasm" 2>/dev/null

run_native() { pdftotext -layout - - <"$pdf"; }
run_wasm() { wasmtime run "$DIST/pdftotext.wasm" -layout - - <"$pdf"; }
run_aot() { wasmtime run --allow-precompiled "$cwasm" -layout - - <"$pdf"; }

# Identical output, or the numbers compare nothing.
run_native >"$tmp/native.txt" 2>/dev/null
run_wasm >"$tmp/wasm.txt" 2>/dev/null
if cmp -s "$tmp/native.txt" "$tmp/wasm.txt"; then
    printf 'output: identical (%s bytes)\n\n' "$(wc -c <"$tmp/native.txt" | tr -d ' ')"
else
    printf 'output: DIFFERS -- benchmark is not comparing like with like\n\n'
fi

nat_wall=$(best_wall run_native)
wasm_wall=$(best_wall run_wasm)
aot_wall=$(best_wall run_aot)

# Same binary, no PDF work: isolates JIT + instantiation.
nat_start=$(best_wall pdftotext -v)
wasm_start=$(best_wall wasmtime run "$DIST/pdftotext.wasm" -v)
aot_start=$(best_wall wasmtime run --allow-precompiled "$cwasm" -v)

set -- $(resources pdftotext -layout - - <"$pdf")
nat_cpu=$1 nat_rss=$2
set -- $(resources wasmtime run "$DIST/pdftotext.wasm" -layout - - <"$pdf")
wasm_cpu=$1 wasm_rss=$2
set -- $(resources wasmtime run --allow-precompiled "$cwasm" -layout - - <"$pdf")
aot_cpu=$1 aot_rss=$2

ratio() { python3 -c "print(f'{$2/$1:.2f}x')" 2>/dev/null || echo '-'; }

row() { printf '%-24s %10s %10s %10s %9s %9s\n' "$@"; }
row metric native wasm aot wasm/nat aot/nat
row ------------------------ ---------- ---------- ---------- --------- ---------
row "wall, best of $RUNS (ms)" "$nat_wall" "$wasm_wall" "$aot_wall" \
    "$(ratio "$nat_wall" "$wasm_wall")" "$(ratio "$nat_wall" "$aot_wall")"
row "startup floor (ms)" "$nat_start" "$wasm_start" "$aot_start" \
    "$(ratio "$nat_start" "$wasm_start")" "$(ratio "$nat_start" "$aot_start")"
row "work = wall-startup (ms)" "$((nat_wall - nat_start))" "$((wasm_wall - wasm_start))" \
    "$((aot_wall - aot_start))" \
    "$(ratio "$((nat_wall - nat_start))" "$((wasm_wall - wasm_start))")" \
    "$(ratio "$((nat_wall - nat_start))" "$((aot_wall - aot_start))")"
row "cpu user+sys (s)" "$nat_cpu" "$wasm_cpu" "$aot_cpu" \
    "$(ratio "$nat_cpu" "$wasm_cpu")" "$(ratio "$nat_cpu" "$aot_cpu")"
row "peak RSS (KiB)" "$nat_rss" "$wasm_rss" "$aot_rss" \
    "$(ratio "$nat_rss" "$wasm_rss")" "$(ratio "$nat_rss" "$aot_rss")"
