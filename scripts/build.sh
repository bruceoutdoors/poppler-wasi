#!/bin/sh
# Cross-compile zlib, FreeType and Poppler for wasm32-wasip1 into dist/.
#
# With the optional backends off, Poppler needs only FreeType and zlib, and its "generic"
# font configuration needs no fontconfig or platform font API.

. "$(dirname -- "$0")/common.sh"

need cmake
need ninja

WASI_SDK_PATH=${WASI_SDK_PATH:-$(wasi_sdk_path)}
[ -x "$WASI_SDK_PATH/bin/clang" ] ||
    die "no wasi-sdk at $WASI_SDK_PATH; run 'make toolchain' first"

# Prefer wasi-sdk-p1.cmake: it targets wasm32-wasip1, while the generic wasi-sdk.cmake still
# uses the deprecated wasm32-wasi triple.
TOOLCHAIN_FILE="$WASI_SDK_PATH/share/cmake/wasi-sdk-p1.cmake"
[ -f "$TOOLCHAIN_FILE" ] || TOOLCHAIN_FILE="$WASI_SDK_PATH/share/cmake/wasi-sdk.cmake"
[ -f "$TOOLCHAIN_FILE" ] || die "no wasi-sdk CMake toolchain file in $WASI_SDK_PATH/share/cmake"

[ -f "$POPPLER_SRC/CMakeLists.txt" ] ||
    die "poppler submodule not initialised; run 'make submodule' first"

# Poppler declares a minimum FreeType (find_package(Freetype <ver> REQUIRED)) and no zlib
# constraint at all, so our exact pins are a reproducibility choice, not dictated. Check the floor
# so a bump that raises it does not surface as an opaque find_package failure. The release workflow
# repins automatically via update-deps.sh --if-needed, so this only fires on a manual build.
ft_required=$(sed -n 's/^set(FREETYPE_VERSION "\([0-9.]*\)").*/\1/p' "$POPPLER_SRC/CMakeLists.txt")
if [ -n "$ft_required" ]; then
    oldest=$(printf '%s\n%s\n' "$ft_required" "$FREETYPE_VERSION" | sort -V | head -1)
    [ "$oldest" = "$ft_required" ] ||
        die "poppler requires FreeType >= $ft_required but scripts/versions.env pins $FREETYPE_VERSION.
Run 'make update-deps' to repin."
fi

JOBS=${JOBS:-$( (getconf _NPROCESSORS_ONLN || sysctl -n hw.ncpu || echo 4) 2>/dev/null)}

# Two wasi-libc features need opting into, applied to all three projects so they cannot drift.
#
# sjlj: FreeType's tt_face_build_cmaps() wraps every TrueType cmap validation in ft_setjmp so
# a malformed table unwinds safely -- the hardening we want for untrusted PDFs, so it cannot be
# stubbed. wasi-libc's <setjmp.h> is a hard #error without the LLVM pass. Flags per wasi-sdk's
# SetjmpLongjmp.md. Implies the exception-handling proposal (phase 5) at runtime.
#
# signals: PSOutputDev.cc includes <csignal>. The emulation gives constants and an aborting
# raise(), which is all Poppler needs -- it only guards against a broken output pipe, and
# nothing can deliver signals here anyway.
WASI_CFLAGS="-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -D_WASI_EMULATED_SIGNAL"
WASI_LDFLAGS="-lsetjmp -lwasi-emulated-signal"

# Shared settings go in a CMake initial-cache file, not -D arguments: POSIX sh has no arrays,
# and round-tripping args through a string re-splits flags containing spaces. CMake reads -C
# before -D, so a per-project -D still wins.
#
# CMAKE_FIND_ROOT_PATH matters: the toolchain sets CMAKE_FIND_ROOT_PATH_MODE_*=ONLY but leaves
# the root path empty, and empty degrades to searching host paths -- so Poppler would link the
# host's libraries.
CACHE_FILE="$BUILD_DIR/wasi-common.cmake"
mkdir -p "$BUILD_DIR"
{
    printf 'set(CMAKE_BUILD_TYPE Release CACHE STRING "")\n'
    printf 'set(BUILD_SHARED_LIBS OFF CACHE BOOL "")\n'
    printf 'set(CMAKE_FIND_ROOT_PATH "%s" CACHE STRING "")\n' "$DEPS_PREFIX"
    printf 'set(CMAKE_PREFIX_PATH "%s" CACHE STRING "")\n' "$DEPS_PREFIX"
    printf 'set(CMAKE_C_FLAGS "%s" CACHE STRING "")\n' "$WASI_CFLAGS"
    printf 'set(CMAKE_CXX_FLAGS "%s" CACHE STRING "")\n' "$WASI_CFLAGS"
    printf 'set(CMAKE_EXE_LINKER_FLAGS "%s" CACHE STRING "")\n' "$WASI_LDFLAGS"
    if command -v ccache >/dev/null 2>&1; then
        printf 'set(CMAKE_C_COMPILER_LAUNCHER ccache CACHE STRING "")\n'
        printf 'set(CMAKE_CXX_COMPILER_LAUNCHER ccache CACHE STRING "")\n'
    fi
} >"$CACHE_FILE"

# pkg-config ignores CMAKE_FIND_ROOT_PATH, so clamp it too.
PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig"
PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

# Quiet unless it fails. Ninja reports compiler errors on stdout, so both streams are captured.
quietly() {
    _logfile="$BUILD_DIR/last-command.log"
    if ! "$@" >"$_logfile" 2>&1; then
        printf '\n--- output of: %s ---\n' "$*" >&2
        cat "$_logfile" >&2
        die "command failed: $*"
    fi
}

configure_build_install() {
    _name=$1
    _src=$2
    shift 2
    _build="$BUILD_DIR/deps/$_name"
    log "building $_name"
    quietly cmake -S "$_src" -B "$_build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -C "$CACHE_FILE" \
        -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
        "$@"
    quietly cmake --build "$_build" --parallel "$JOBS"
    quietly cmake --install "$_build"
}

# Each build tree under build/deps is configured against a source path carrying the dependency
# version, and build/deps/prefix holds their install. A CI cache restored across a version bump
# hands cmake a tree configured for the old source dir, which is a hard error -- so start clean
# whenever the pins move. Also stops old versions accumulating in the cache.
DEPS_STAMP="$BUILD_DIR/deps/.pins"
DEPS_PINS="zlib=$ZLIB_VERSION freetype=$FREETYPE_VERSION wasi-sdk=$WASI_SDK_VERSION"
if [ "$(cat "$DEPS_STAMP" 2>/dev/null || true)" != "$DEPS_PINS" ]; then
    [ ! -d "$BUILD_DIR/deps" ] || log "dependency pins changed; rebuilding deps"
    rm -rf "$BUILD_DIR/deps"
fi

# The shared library cannot link for wasm; examples are test-only. The static target's
# OUTPUT_NAME is plain "z", so CMake's FindZLIB finds libz.a.
configure_build_install zlib "$SRC_CACHE/zlib-${ZLIB_VERSION}" \
    -DZLIB_BUILD_SHARED=OFF \
    -DZLIB_BUILD_STATIC=ON \
    -DZLIB_BUILD_TESTING=OFF \
    -DZLIB_INSTALL=ON

# Poppler needs only glyph metrics and embedded font parsing. WASI does not set UNIX, so
# FreeType picks the portable ANSI-stdio src/base/ftsystem.c over the mmap-based one.
configure_build_install freetype "$SRC_CACHE/freetype-${FREETYPE_VERSION}" \
    -DFT_DISABLE_ZLIB=TRUE \
    -DFT_DISABLE_BZIP2=TRUE \
    -DFT_DISABLE_PNG=TRUE \
    -DFT_DISABLE_HARFBUZZ=TRUE \
    -DFT_DISABLE_BROTLI=TRUE

printf '%s' "$DEPS_PINS" >"$DEPS_STAMP"

"$REPO_ROOT/scripts/apply-patches.sh"

POPPLER_BUILD="$BUILD_DIR/poppler"
log "configuring poppler"
quietly cmake -S "$POPPLER_SRC" -B "$POPPLER_BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -C "$CACHE_FILE" \
    -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/poppler-install" \
    -DFONT_CONFIGURATION=generic \
    -DENABLE_UTILS=ON \
    -DENABLE_CPP=OFF \
    -DENABLE_GLIB=OFF \
    -DENABLE_GOBJECT_INTROSPECTION=OFF \
    -DENABLE_GTK_DOC=OFF \
    -DENABLE_QT5=OFF \
    -DENABLE_QT6=OFF \
    -DENABLE_BOOST=OFF \
    -DENABLE_LIBOPENJPEG=OFF \
    -DENABLE_LIBJPEG=OFF \
    -DENABLE_LCMS=OFF \
    -DENABLE_LIBCURL=OFF \
    -DENABLE_LIBTIFF=OFF \
    -DENABLE_NSS3=OFF \
    -DENABLE_GPGME=OFF \
    -DENABLE_ZLIB_UNCOMPRESS=OFF \
    -DBUILD_GTK_TESTS=OFF \
    -DBUILD_QT5_TESTS=OFF \
    -DBUILD_QT6_TESTS=OFF \
    -DBUILD_CPP_TESTS=OFF \
    -DBUILD_MANUAL_TESTS=OFF \
    -DRUN_GPERF_IF_PRESENT=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_Cairo=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_ECM=ON \
    -DCMAKE_CXX_SCAN_FOR_MODULES=OFF
log "building poppler"
quietly cmake --build "$POPPLER_BUILD" --parallel "$JOBS"

log "staging dist/"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Detect by magic number rather than trusting CMAKE_EXECUTABLE_SUFFIX: the toolchain sets the
# old language-agnostic variable, which CMake 4 ignores in favour of
# CMAKE_EXECUTABLE_SUFFIX_<LANG>. Also guards against staging a host binary.
is_wasm() {
    [ "$(od -N4 -An -tx1 "$1" | tr -d ' \n')" = "0061736d" ]
}

# An explicit list, not whatever turns up in utils/: a utility added by a future poppler release
# must not reach a release without a test, a README entry and a look at what it links.
MODULES='pdfattach pdfdetach pdffonts pdfimages pdfinfo pdfseparate
         pdftohtml pdftoppm pdftops pdftotext pdfunite'

# Nearly two thirds of each module is DWARF from wasi-sdk's prebuilt libc and libc++, not from our
# own -O2 -DNDEBUG compilation. Stripped when staging rather than with a linker flag, so the
# binaries under build/ keep their debug info.
STRIP="$WASI_SDK_PATH/bin/llvm-strip"

count=0
for name in $MODULES; do
    built="$POPPLER_BUILD/utils/$name"
    [ -f "$built" ] || built="$built.wasm"
    [ -f "$built" ] || die "expected module '$name' was not built in $POPPLER_BUILD/utils"
    is_wasm "$built" || die "$built is not a wasm module"
    "$STRIP" "$built" -o "$DIST_DIR/$name.wasm"
    (cd "$DIST_DIR" &&
        printf '%s  %s\n' "$(sha256_of "$name.wasm")" "$name.wasm" >"$name.wasm.sha256")
    count=$((count + 1))
done

# Logged, not fatal: a new upstream utility should not block an unattended release.
for built in "$POPPLER_BUILD"/utils/*; do
    { [ -f "$built" ] && is_wasm "$built"; } || continue
    extra=$(basename "$built" .wasm)
    [ -f "$DIST_DIR/$extra.wasm" ] ||
        log "note: upstream built '$extra', which is not in the published module list"
done

poppler_commit=$(git -C "$POPPLER_SRC" rev-parse HEAD)
{
    printf 'poppler-wasi build info\n'
    printf 'poppler tag:        %s\n' \
        "$(git -C "$POPPLER_SRC" describe --tags --exact-match 2>/dev/null || echo '(untagged)')"
    printf 'poppler commit:     %s\n' "$poppler_commit"
    printf 'wasi-sdk:           %s\n' "$WASI_SDK_VERSION"
    printf 'freetype:           %s\n' "$FREETYPE_VERSION"
    printf 'zlib:               %s\n' "$ZLIB_VERSION"
    printf 'target:             wasm32-wasip1\n'
    printf 'font configuration: generic (no fontconfig)\n'
    printf 'stripped:           yes (DWARF and name sections removed)\n'
    printf 'modules:            %s\n' "$count"
    printf '\ncorresponding source\n'
    printf '  poppler:  git clone %s && git checkout %s\n' "$POPPLER_URL" "$poppler_commit"
    printf '  patches:  patches/poppler/*.patch in this repository\n'
    printf '  freetype: %s\n' "$FREETYPE_URL"
    printf '            sha256 %s\n' "$FREETYPE_SHA256"
    printf '  zlib:     %s\n' "$ZLIB_URL"
    printf '            sha256 %s\n' "$ZLIB_SHA256"
} >"$DIST_DIR/BUILD-INFO.txt"

log "built $count modules into $DIST_DIR"
for wasm in "$DIST_DIR"/*.wasm; do
    printf '  %s\n' "$(basename "$wasm")" >&2
done
