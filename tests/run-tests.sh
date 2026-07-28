#!/bin/sh
# Test the built WASI modules under wasmtime.
#
#   1. Golden tests: pdftotext output compared byte-for-byte against expected text from a
#      NATIVE poppler (see make-goldens.sh). The real correctness check.
#   2. Smoke tests: every other published utility runs and produces recognisable output.
#
# Do not add "--" before module arguments: wasmtime forwards it to the guest as a literal argv
# entry and poppler's argument parser then rejects it.

set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
DIST=${DIST:-$REPO_ROOT/dist}
FIXTURES="$HERE/fixtures"
EXPECTED="$FIXTURES/expected"
WASMTIME=${WASMTIME:-wasmtime}

pass=0
fail=0
failed_names=''

command -v "$WASMTIME" >/dev/null 2>&1 || {
    printf 'error: no wasmtime on PATH (set WASMTIME= to override)\n' >&2
    exit 1
}
[ -f "$DIST/pdftotext.wasm" ] || {
    printf 'error: no modules in %s -- run "make build" first\n' "$DIST" >&2
    exit 1
}

ok() {
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
}

no() {
    fail=$((fail + 1))
    failed_names="$failed_names $1"
    printf '  FAIL %s\n' "$1"
    [ $# -lt 2 ] || printf '%s\n' "$2" | sed 's/^/         /'
}

# No filesystem access at all: stdin/stdout only, the strongest form of the sandbox case.
run_sealed() {
    _mod=$1
    shift
    "$WASMTIME" run "$DIST/$_mod.wasm" "$@"
}

# Current directory preopened, for utilities that write files.
run_in_dir() {
    _mod=$1
    shift
    "$WASMTIME" run --dir=. "$DIST/$_mod.wasm" "$@"
}

# ---------------------------------------------------------------------------------------
printf '\npdftotext golden tests (vs native poppler output)\n'

[ -d "$EXPECTED" ] || {
    printf 'error: no goldens in %s -- run "make goldens" with a native poppler\n' "$EXPECTED" >&2
    exit 1
}

golden_version=$(cat "$EXPECTED/.poppler-version" 2>/dev/null || echo '?')
pinned=$(git -C "$REPO_ROOT/third_party/poppler" describe --tags --exact-match 2>/dev/null || echo '')
pinned=${pinned#poppler-}
if [ -n "$pinned" ] && [ "$golden_version" != "$pinned" ]; then
    printf '  note: goldens were generated from poppler %s, submodule is %s\n' \
        "$golden_version" "$pinned"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

while read -r name fixture flags; do
    case "$name" in '' | \#*) continue ;; esac
    want="$EXPECTED/$name.txt"
    got="$tmp/$name.actual"
    if [ ! -f "$want" ]; then
        no "$name" "no golden file: $want"
        continue
    fi
    # shellcheck disable=SC2086 # flags is an intentional word list
    if ! run_sealed pdftotext $flags - - <"$FIXTURES/$fixture" >"$got" 2>"$tmp/$name.err"; then
        no "$name" "pdftotext exited non-zero: $(cat "$tmp/$name.err")"
        continue
    fi
    if diff_out=$(diff -u "$want" "$got" 2>&1); then
        ok "$name"
    else
        no "$name" "$diff_out"
    fi
done <"$HERE/cases.txt"

# ---------------------------------------------------------------------------------------
printf '\nsandbox behaviour\n'

# denied NAME command...
# Requires the command to fail *and* to have failed while opening the PDF. Asserting only a
# non-zero exit would also pass if the module crashed on startup or was missing entirely.
denied() {
    _name=$1
    shift
    if "$@" >"$tmp/denied.out" 2>&1; then
        no "$_name" "succeeded, expected denial: $(head -2 "$tmp/denied.out")"
    elif grep -q "Couldn't open file" "$tmp/denied.out"; then
        ok "$_name"
    else
        no "$_name" "failed, but not by being denied the file: $(head -2 "$tmp/denied.out")"
    fi
}

# The converse of the golden tests: with no preopen, a file argument must be unreachable.
denied "file access denied without --dir" run_sealed pdfinfo "$FIXTURES/simple.pdf"

# A preopen must not be escapable, or --dir would be a false promise. Targets a file that really
# exists outside the preopen, so the refusal cannot be mistaken for "not found".
cp "$FIXTURES/simple.pdf" "$tmp/outside.pdf"
mkdir -p "$tmp/inside"
denied "preopen cannot be escaped" \
    "$WASMTIME" run --dir="$tmp/inside" "$DIST/pdfinfo.wasm" "$tmp/inside/../outside.pdf"

# AOT changes when compilation happens, not what the guest may do. Asserted because the README
# promises it.
if "$WASMTIME" compile "$DIST/pdfinfo.wasm" -o "$tmp/pdfinfo.cwasm" >/dev/null 2>&1; then
    denied "precompiled module is still sandboxed" \
        "$WASMTIME" run --allow-precompiled --dir="$tmp/inside" "$tmp/pdfinfo.cwasm" \
        "$tmp/outside.pdf"
else
    no "precompiled module is still sandboxed" "wasmtime compile failed"
fi

# ---------------------------------------------------------------------------------------
printf '\nutility smoke tests\n'

work="$tmp/work"
mkdir -p "$work"
cp "$FIXTURES"/*.pdf "$work/"
printf 'attachment payload\n' >"$work/attachment.txt"
cd "$work"

# check NAME "expected substring" command...
check() {
    _name=$1
    _want=$2
    shift 2
    if ! "$@" >"$tmp/out" 2>"$tmp/err"; then
        no "$_name" "exited non-zero: $(head -3 "$tmp/err")"
        return
    fi
    if grep -q "$_want" "$tmp/out"; then
        ok "$_name"
    else
        no "$_name" "output did not contain '$_want':
$(head -5 "$tmp/out")"
    fi
}

# check_file NAME FILE "expected substring" command...
check_file() {
    _name=$1
    _file=$2
    _want=$3
    shift 3
    if ! "$@" >"$tmp/out" 2>"$tmp/err"; then
        no "$_name" "exited non-zero: $(head -3 "$tmp/err")"
        return
    fi
    if [ ! -f "$_file" ]; then
        no "$_name" "did not create $_file"
    elif head -c 200 "$_file" | grep -q "$_want"; then
        ok "$_name"
    else
        no "$_name" "$_file did not start with '$_want'"
    fi
}

check pdfinfo 'Pages: *2' run_in_dir pdfinfo multipage.pdf
check pdffonts 'Helvetica' run_in_dir pdffonts simple.pdf
check pdfimages-list 'page' run_in_dir pdfimages -list simple.pdf
check pdftohtml 'Hello from poppler-wasi' run_in_dir pdftohtml -stdout simple.pdf

check_file pdftops out.ps '%!PS-Adobe' run_in_dir pdftops simple.pdf out.ps
# "Config Error: No display font" on stderr is expected: generic font config has no fonts.
check_file pdftoppm ppm-1.pgm 'P5' run_in_dir pdftoppm -r 36 -gray simple.pdf ppm

if run_in_dir pdfseparate multipage.pdf page-%d.pdf >"$tmp/out" 2>&1 &&
    [ -f page-1.pdf ] && [ -f page-2.pdf ]; then
    ok pdfseparate
    # Read the result back, so this checks a valid two-page PDF, not just a non-empty file.
    if run_in_dir pdfunite page-1.pdf page-2.pdf united.pdf >"$tmp/out" 2>&1; then
        check pdfunite 'Pages: *2' run_in_dir pdfinfo united.pdf
    else
        no pdfunite "$(head -3 "$tmp/out")"
    fi
else
    no pdfseparate "$(head -3 "$tmp/out")"
    no pdfunite "skipped: pdfseparate failed"
fi

if run_in_dir pdfattach simple.pdf attachment.txt attached.pdf >"$tmp/out" 2>&1 &&
    [ -f attached.pdf ]; then
    ok pdfattach
    check pdfdetach 'attachment.txt' run_in_dir pdfdetach -list attached.pdf
else
    no pdfattach "$(head -3 "$tmp/out")"
    no pdfdetach "skipped: pdfattach failed"
fi

# ---------------------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    printf 'failed:%s\n' "$failed_names"
    exit 1
fi
