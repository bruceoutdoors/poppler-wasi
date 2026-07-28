#!/bin/sh
# Print the newest stable upstream Poppler tag, e.g. "poppler-26.07.0".
#
# The single source of truth for "what is the latest release", so the answer always comes from
# upstream's tags rather than anything pinned here.
#
# Poppler uses date-based YY.MM.MICRO versioning with no unstable series, so every strict
# three-component tag is a release. The pattern also excludes oddities like
# "poppler-before-fontconfig".

. "$(dirname -- "$0")/common.sh"

need git

tags=$(git ls-remote --tags --refs "$POPPLER_URL" 'poppler-*' 2>/dev/null |
    awk '{print $2}' |
    sed 's|refs/tags/||' |
    grep -E '^poppler-[0-9]+\.[0-9]+\.[0-9]+$' |
    sort -V)

[ -n "$tags" ] || die "could not list stable poppler tags from $POPPLER_URL"

printf '%s\n' "$tags" | tail -1
