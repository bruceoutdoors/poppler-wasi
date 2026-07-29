#!/bin/sh
# Download and unpack Poppler's two mandatory dependencies. Idempotent.
#
# Pinned release tarballs rather than submodules: they are build inputs, not the subject of
# this project, and are cheaper to pin and cache than git history.

. "$(dirname -- "$0")/common.sh"

need curl
need tar

zlib_tarball="$SRC_CACHE/zlib-${ZLIB_VERSION}.tar.xz"
fetch_verified "$zlib_tarball" "$ZLIB_SHA256" "$ZLIB_URL"
unpack_tarball "$zlib_tarball" "$SRC_CACHE/zlib-${ZLIB_VERSION}" CMakeLists.txt

freetype_tarball="$SRC_CACHE/freetype-${FREETYPE_VERSION}.tar.xz"
fetch_verified "$freetype_tarball" "$FREETYPE_SHA256" "$FREETYPE_URL" "$FREETYPE_MIRROR"
unpack_tarball "$freetype_tarball" "$SRC_CACHE/freetype-${FREETYPE_VERSION}" CMakeLists.txt

# Drop sources for versions no longer pinned, so a restored CI cache does not accumulate them
# bump after bump. The '*' case is an unmatched glob.
for stale in "$SRC_CACHE"/zlib-* "$SRC_CACHE"/freetype-*; do
    case $stale in
        *'*') continue ;;
        "$SRC_CACHE/zlib-${ZLIB_VERSION}" | "$zlib_tarball") continue ;;
        "$SRC_CACHE/freetype-${FREETYPE_VERSION}" | "$freetype_tarball") continue ;;
    esac
    log "removing stale source $(basename "$stale")"
    rm -rf "$stale"
done

log "dependency sources ready"
