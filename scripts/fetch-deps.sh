#!/bin/sh
# Download and unpack Poppler's two mandatory dependencies. Idempotent.
#
# Pinned release tarballs rather than submodules: they are build inputs, not the subject of
# this project, and are cheaper to pin and cache than git history.

. "$(dirname -- "$0")/common.sh"

need curl
need tar

zlib_tarball="$SRC_CACHE/zlib-${ZLIB_VERSION}.tar.xz"
fetch_verified "$zlib_tarball" "$ZLIB_SHA256" \
    "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.xz"
unpack_tarball "$zlib_tarball" "$SRC_CACHE/zlib-${ZLIB_VERSION}" CMakeLists.txt

# SourceForge mirrors the identical tarball; Savannah 502s often enough to break CI.
freetype_tarball="$SRC_CACHE/freetype-${FREETYPE_VERSION}.tar.xz"
fetch_verified "$freetype_tarball" "$FREETYPE_SHA256" \
    "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz" \
    "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.xz"
unpack_tarball "$freetype_tarball" "$SRC_CACHE/freetype-${FREETYPE_VERSION}" CMakeLists.txt

log "dependency sources ready"
