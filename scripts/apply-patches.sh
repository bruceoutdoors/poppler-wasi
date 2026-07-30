#!/bin/sh
# Reset the poppler submodule to its pinned commit, then apply patches/poppler.patch.
#
# Resetting first makes this idempotent without tracking whether the patch is already applied:
# the submodule worktree is always exactly "upstream tag + patches/poppler.patch". The cost is
# that hand edits inside third_party/poppler are discarded on every build.
#
# Usage: apply-patches.sh [--reset]   (--reset leaves the tree pristine, unpatched)

. "$(dirname -- "$0")/common.sh"

need git

[ -f "$POPPLER_SRC/CMakeLists.txt" ] ||
    die "poppler submodule not initialised; run 'make submodule' first"

git -C "$POPPLER_SRC" checkout --quiet -- .

if [ "${1:-}" = "--reset" ]; then
    log "poppler checkout is pristine"
    exit 0
fi

git -C "$POPPLER_SRC" apply "$REPO_ROOT/patches/poppler.patch" ||
    die "patches/poppler.patch does not apply to this poppler version.
Refresh it, or drop the hunks upstream has fixed."

log "applied patches/poppler.patch"
