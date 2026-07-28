#!/bin/sh
# Repin FreeType and zlib in scripts/versions.env, resolving versions and checksums from
# upstream tags the same way check-upstream.sh resolves Poppler's.
#
#   update-deps.sh              bump both to newest stable
#   update-deps.sh --if-needed  bump FreeType only, and only if poppler's declared floor
#                               exceeds the current pin
#
# --if-needed is what the release workflow runs, so a poppler bump that raises the FreeType
# floor repins itself instead of failing and waiting for a human. It deliberately touches
# nothing when the pins already satisfy the floor: unattended releases should not quietly
# change dependency versions that were working.

. "$(dirname -- "$0")/common.sh"

need git
need curl

VERSIONS_FILE="$REPO_ROOT/scripts/versions.env"
IF_NEEDED=false
[ "${1:-}" = "--if-needed" ] && IF_NEEDED=true

# newest_tag URL REGEX SED_TRANSFORM -- highest matching tag, normalised to a dotted version
newest_tag() {
    _v=$(git ls-remote --tags --refs "$1" 2>/dev/null |
        awk '{print $2}' | sed 's|refs/tags/||' |
        grep -E "$2" | sed "$3" | sort -V | tail -1)
    [ -n "$_v" ] || die "could not resolve any release tag from $1"
    printf '%s' "$_v"
}

# repin NAME VERSION SHA256 -- rewrite the <NAME>_VERSION and <NAME>_SHA256 lines in place
repin() {
    _name=$1
    _ver=$2
    _sha=$3
    _tmp="$VERSIONS_FILE.tmp"
    sed -e "s|^${_name}_VERSION=.*|${_name}_VERSION=${_ver}|" \
        -e "s|^${_name}_SHA256=.*|${_name}_SHA256=${_sha}|" \
        "$VERSIONS_FILE" >"$_tmp"
    mv "$_tmp" "$VERSIONS_FILE"
}

# sha256_of_url URL -- download to the source cache and hash it, so a pin is only ever recorded
# for a tarball that was actually fetched. The tar check matters: curl -f rejects HTTP errors but
# not a 200 that returns an error page, and pinning the hash of an HTML page would pass
# verification later and only fail at extraction.
sha256_of_url() {
    _out="$SRC_CACHE/$(basename "$1")"
    mkdir -p "$SRC_CACHE"
    curl -fsSL --retry 3 --retry-delay 2 -o "$_out" "$1" || die "cannot download $1"
    tar -tf "$_out" >/dev/null 2>&1 || die "$1 did not return a readable tarball"
    sha256_of "$_out"
}

ft_floor=$(sed -n 's/^set(FREETYPE_VERSION "\([0-9.]*\)").*/\1/p' "$POPPLER_SRC/CMakeLists.txt" 2>/dev/null)

if [ "$IF_NEEDED" = true ]; then
    [ -n "$ft_floor" ] || die "could not read poppler's FREETYPE_VERSION floor"
    oldest=$(printf '%s\n%s\n' "$ft_floor" "$FREETYPE_VERSION" | sort -V | head -1)
    if [ "$oldest" = "$ft_floor" ]; then
        log "pins satisfy poppler's floors (FreeType >= $ft_floor, pinned $FREETYPE_VERSION)"
        exit 0
    fi
    log "poppler now needs FreeType >= $ft_floor but $FREETYPE_VERSION is pinned; repinning"
fi

log "resolving newest FreeType"
ft_new=$(newest_tag https://gitlab.freedesktop.org/freetype/freetype.git \
    '^VER-[0-9]+-[0-9]+-[0-9]+$' 's/^VER-//; s/-/./g')

if [ -n "$ft_floor" ]; then
    oldest=$(printf '%s\n%s\n' "$ft_floor" "$ft_new" | sort -V | head -1)
    [ "$oldest" = "$ft_floor" ] ||
        die "newest FreeType is $ft_new but poppler requires >= $ft_floor; nothing to repin to"
fi

if [ "$ft_new" = "$FREETYPE_VERSION" ]; then
    log "FreeType already at $ft_new"
else
    ft_sha=$(sha256_of_url \
        "https://download.savannah.gnu.org/releases/freetype/freetype-${ft_new}.tar.xz")
    repin FREETYPE "$ft_new" "$ft_sha"
    log "FreeType $FREETYPE_VERSION -> $ft_new"
fi

# --if-needed exists to unblock a poppler bump, so it stops here rather than also moving zlib,
# which poppler puts no constraint on at all.
if [ "$IF_NEEDED" = true ]; then
    exit 0
fi

log "resolving newest zlib"
zlib_new=$(newest_tag https://github.com/madler/zlib.git '^v[0-9]+(\.[0-9]+){1,3}$' 's/^v//')
if [ "$zlib_new" = "$ZLIB_VERSION" ]; then
    log "zlib already at $zlib_new"
else
    zlib_sha=$(sha256_of_url \
        "https://github.com/madler/zlib/releases/download/v${zlib_new}/zlib-${zlib_new}.tar.xz")
    repin ZLIB "$zlib_new" "$zlib_sha"
    log "zlib $ZLIB_VERSION -> $zlib_new"
fi
