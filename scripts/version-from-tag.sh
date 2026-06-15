#!/bin/bash
# Canonical mapping from a stable release tag (vMAJOR.MINOR.PATCH) to Sparkle version fields.
# Used by release.sh (to stamp Info.plist) and by release.yml (to assert the committed value).
#
# On success prints two eval-able lines and exits 0:
#   short=<MAJOR.MINOR.PATCH>     # CFBundleShortVersionString (human/display)
#   build=<monotonic integer>     # CFBundleVersion (Sparkle comparison key)
#
# On a non-stable tag (two-part, prerelease, malformed, or minor/patch >= 1000) it prints a
# diagnostic to stderr and exits 1. CFBundleVersion MUST be monotonic because Sparkle's
# SUStandardVersionComparator compares it against the installed bundle version.
set -euo pipefail

tag="${1:-}"

if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "version-from-tag: '$tag' is not a stable vMAJOR.MINOR.PATCH tag" >&2
    exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

# Packing requires minor/patch < 1000 so the integer ordering matches semver ordering.
if (( minor >= 1000 || patch >= 1000 )); then
    echo "version-from-tag: minor/patch must each be < 1000 for monotonic packing ('$tag')" >&2
    exit 1
fi

short="${major}.${minor}.${patch}"
build=$(( major * 1000000 + minor * 1000 + patch ))

echo "short=${short}"
echo "build=${build}"
