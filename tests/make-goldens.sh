#!/bin/sh
# Regenerate tests/fixtures/expected/ using a NATIVE pdftotext.
#
# Goldens come from a native build, not the WASI modules, so the suite asserts "wasm extracts
# what native does" rather than "wasm agrees with itself".
#
# Manual step, never run in CI. Run it when a submodule bump legitimately changes output, and
# review the diff. Refuses to run unless the native version matches the submodule pin.

set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
FIXTURES="$HERE/fixtures"
EXPECTED="$FIXTURES/expected"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

command -v pdftotext >/dev/null 2>&1 ||
    die "no native pdftotext on PATH (try: brew install poppler / apt install poppler-utils)"

native_version=$(pdftotext -v 2>&1 | sed -n '1s/.*version //p')
pinned_tag=$(git -C "$REPO_ROOT/third_party/poppler" describe --tags --exact-match 2>/dev/null || echo '')
pinned_version=${pinned_tag#poppler-}

[ -n "$pinned_version" ] ||
    die "the poppler submodule is not checked out at a release tag, so goldens cannot be
attributed to a version. Check out the pinned tag first."

if [ "$native_version" != "$pinned_version" ]; then
    die "native pdftotext is $native_version but the submodule is pinned to $pinned_version.
Install a matching native poppler, or bump the submodule, before regenerating goldens."
fi

mkdir -p "$EXPECTED"
printf 'generating goldens with native pdftotext %s\n' "$native_version" >&2

count=0
while read -r name fixture flags; do
    case "$name" in '' | \#*) continue ;; esac
    # shellcheck disable=SC2086 # flags is an intentional word list
    pdftotext $flags - - <"$FIXTURES/$fixture" >"$EXPECTED/$name.txt"
    printf '  %-20s %s\n' "$name" "$(wc -c <"$EXPECTED/$name.txt" | tr -d ' ') bytes" >&2
    count=$((count + 1))
done <"$HERE/cases.txt"

printf 'wrote %s goldens to %s\n' "$count" "$EXPECTED" >&2
printf 'record the version they came from\n' >&2
printf '%s\n' "$pinned_version" >"$EXPECTED/.poppler-version"
