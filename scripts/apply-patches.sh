#!/bin/sh
# Apply (or reset) patches/poppler/*.patch against the submodule.
#
# Patches live outside the submodule so third_party/poppler stays a pristine upstream checkout
# and bumping it never means rebasing a fork.
#
# Usage: apply-patches.sh [--reset]

. "$(dirname -- "$0")/common.sh"

need git

[ -f "$POPPLER_SRC/CMakeLists.txt" ] ||
    die "poppler submodule not initialised; run 'make submodule' first"

if [ "${1:-}" = "--reset" ]; then
    log "restoring pristine poppler checkout"
    git -C "$POPPLER_SRC" checkout -- .
    git -C "$POPPLER_SRC" clean -fd
    exit 0
fi

patches=$(find "$REPO_ROOT/patches/poppler" -name '*.patch' -type f 2>/dev/null | sort)

if [ -z "$patches" ]; then
    log "no patches to apply"
    exit 0
fi

for p in $patches; do
    name=$(basename "$p")
    if git -C "$POPPLER_SRC" apply --reverse --check "$p" 2>/dev/null; then
        log "already applied: $name"
        continue
    fi
    git -C "$POPPLER_SRC" apply --check "$p" 2>/dev/null ||
        die "patch does not apply cleanly: $name
The submodule was probably bumped past it. Refresh or drop the patch."
    log "applying $name"
    git -C "$POPPLER_SRC" apply "$p"
done
