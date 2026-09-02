#!/usr/bin/env bash
# validate_pak.sh — Run the Pak compiler checker on one or more .pk64 files.
#
# Usage:
#   tools/validate_pak.sh file.pk64            # check one file
#   tools/validate_pak.sh src/*.pk64           # check multiple files individually
#   tools/validate_pak.sh                     # check whole project (pak.toml required)
#
# Exit codes:
#   0 — all files passed
#   1 — one or more errors found
#
# This is the mechanical enforcement layer. If pak check fails,
# the code is wrong. Fix the errors reported before proceeding.
#
# Note: checking multiple files with entry blocks together triggers E103
# (multiple entry blocks). Each standalone example file should be
# checked individually, not all at once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Ensure pak is installed
if ! command -v pak &>/dev/null; then
    echo "ERROR: 'pak' not found. Put the repo's bin/ directory on PATH." >&2
    exit 1
fi

if [ $# -eq 0 ]; then
    # No args: check whole project via pak.toml
    pak check
elif [ $# -eq 1 ]; then
    # Single file: check directly
    pak check "$1"
else
    # Multiple files: check each individually to avoid cross-file false positives
    # (e.g. E103 multiple entry blocks when checking standalone examples together)
    overall=0
    for f in "$@"; do
        if ! pak check "$f"; then
            overall=1
        fi
    done
    exit $overall
fi
