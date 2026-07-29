# Shared helpers. Sourced, not executed.
# shellcheck shell=sh

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export REPO_ROOT

# shellcheck source=versions.env
. "$REPO_ROOT/scripts/versions.env"

POPPLER_SRC="$REPO_ROOT/third_party/poppler"
POPPLER_URL="https://gitlab.freedesktop.org/poppler/poppler.git"

# Dependency tarballs. Here rather than in fetch-deps.sh because build.sh records them in
# dist/BUILD-INFO.txt as the corresponding-source pointers.
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.xz"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
# SourceForge mirrors the identical tarball; Savannah 502s often enough to break CI.
FREETYPE_MIRROR="https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.xz"

BUILD_DIR="$REPO_ROOT/build"
SRC_CACHE="$BUILD_DIR/src"
DEPS_PREFIX="$BUILD_DIR/deps/prefix"
DIST_DIR="$REPO_ROOT/dist"
TOOLCHAIN_DIR="$REPO_ROOT/toolchain"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# fetch_verified DEST SHA256 URL [MIRROR...]
# No-op if DEST already matches. Mirrors are tried in order; Savannah 502s often enough to
# break CI. Every mirror must serve the identical artifact, which the checksum enforces.
fetch_verified() {
    _dest=$1
    _sha=$2
    shift 2
    if [ -f "$_dest" ] && [ "$(sha256_of "$_dest")" = "$_sha" ]; then
        log "cached $(basename "$_dest")"
        return 0
    fi
    mkdir -p "$(dirname "$_dest")"
    for _url in "$@"; do
        log "downloading $(basename "$_dest")"
        if curl -fsSL --retry 3 --retry-delay 2 -o "$_dest.tmp" "$_url"; then
            _got=$(sha256_of "$_dest.tmp")
            [ "$_got" = "$_sha" ] || die "checksum mismatch for $_dest
  expected $_sha
  actual   $_got"
            mv "$_dest.tmp" "$_dest"
            return 0
        fi
        log "failed, trying next mirror"
    done
    rm -f "$_dest.tmp"
    die "could not download $(basename "$_dest") from any of: $*"
}

# unpack_tarball TARBALL DEST SENTINEL
# Strips the single top-level directory so DEST is the project root. No-op if DEST/SENTINEL
# exists, which is what makes the fetch scripts safe to re-run. Extracts via .tmp so an
# interrupted unpack cannot leave a partial DEST that the sentinel check would accept.
unpack_tarball() {
    _tarball=$1
    _dest=$2
    _sentinel=$3
    if [ -e "$_dest/$_sentinel" ]; then
        log "already unpacked $(basename "$_dest")"
        return 0
    fi
    log "unpacking $(basename "$_tarball")"
    rm -rf "$_dest.tmp" "$_dest"
    mkdir -p "$_dest.tmp"
    tar -xf "$_tarball" -C "$_dest.tmp" --strip-components=1
    mv "$_dest.tmp" "$_dest"
    [ -e "$_dest/$_sentinel" ] || die "unpacked $_dest but $_sentinel is missing"
}

# Host slug matching wasi-sdk asset naming.
wasi_sdk_host() {
    _os=$(uname -s)
    _arch=$(uname -m)
    case "$_os" in
        Linux) _os=linux ;;
        Darwin) _os=macos ;;
        *) die "unsupported host OS '$_os'" ;;
    esac
    case "$_arch" in
        x86_64 | amd64) _arch=x86_64 ;;
        arm64 | aarch64) _arch=arm64 ;;
        riscv64) _arch=riscv64 ;;
        *) die "unsupported host architecture '$_arch'" ;;
    esac
    printf '%s-%s' "$_arch" "$_os"
}

wasi_sdk_path() {
    printf '%s/wasi-sdk-%s-%s' "$TOOLCHAIN_DIR" "$WASI_SDK_VERSION" "$(wasi_sdk_host)"
}
