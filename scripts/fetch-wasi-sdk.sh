#!/bin/sh
# Download and unpack the pinned wasi-sdk. Idempotent.

. "$(dirname -- "$0")/common.sh"

need curl
need tar

host=$(wasi_sdk_host)
prefix=$(wasi_sdk_path)
asset="wasi-sdk-${WASI_SDK_VERSION}-${host}.tar.gz"
url="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_MAJOR}/${asset}"

if [ -x "$prefix/bin/clang" ]; then
    log "wasi-sdk $WASI_SDK_VERSION already present"
    exit 0
fi

sha=$(grep -E "[[:space:]]${asset}\$" "$REPO_ROOT/scripts/wasi-sdk.sha256" | awk '{print $1}')
[ -n "$sha" ] || die "no pinned checksum for '$asset' in scripts/wasi-sdk.sha256
Add one; that file's header has the gh command that prints it."

tarball="$SRC_CACHE/$asset"
fetch_verified "$tarball" "$sha" "$url"
unpack_tarball "$tarball" "$prefix" bin/clang

log "wasi-sdk ready: $prefix"
