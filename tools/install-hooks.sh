#!/usr/bin/env bash
# install-hooks.sh — Install git hooks for this repo.
#
# Usage:
#   tools/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "ERROR: .git/hooks not found. Are you in a git repo?"
    exit 1
fi

ln -sf "../../tools/pre-commit" "$HOOKS_DIR/pre-commit"
chmod +x "$SCRIPT_DIR/pre-commit"

echo "Installed: .git/hooks/pre-commit -> tools/pre-commit"
echo "Staged .pk64 files will now be validated before every commit."
