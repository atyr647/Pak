#!/usr/bin/env python3
"""
pak_hook.py — Claude Code PostToolUse hook for automatic Pak validation.

Claude Code calls this after every Write or Edit tool use, passing the
tool input as JSON on stdin. This script:

  1. Reads the tool input JSON from stdin.
  2. Extracts the file path.
  3. Skips non-.pk64 files silently.
  4. Runs `pak check` on the file.
  5. If errors are found, prints them and exits with code 2.
     Claude Code surfaces the output to Claude, which must fix the
     errors before continuing.
  6. If clean, runs `pak explain` and prints the generated C so Claude
     can verify the semantics match intent, then exits 0.

Exit codes:
  0 — file is valid (or not a .pk64 file, no action needed)
  2 — pak check failed; errors printed to stdout for Claude to read

Environment variables:
  PAK_HOOK_NO_EXPLAIN=1  — skip the pak explain step (faster, less output)
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Marker that separates the standard runtime preamble from user-defined code.
# The preamble ends after the pak_arena_reset inline definition.
_PREAMBLE_END_RE = re.compile(r"pak_arena_reset[^\n]*\n")


def _extract_user_code(c_source: str) -> str:
    """Strip the standard Pak runtime preamble from generated C output.

    Returns only the user-defined types, functions, and entry point.
    This makes the hook output readable without scrolling through 20 lines
    of boilerplate on every file save.
    """
    m = _PREAMBLE_END_RE.search(c_source)
    if m:
        return c_source[m.end():]
    # Fallback: if marker not found, return everything after the first blank
    # line following the #include block
    lines = c_source.splitlines(keepends=True)
    in_includes = True
    for i, line in enumerate(lines):
        if in_includes and line.startswith("#include"):
            continue
        if in_includes and not line.startswith("#"):
            in_includes = False
        if not in_includes and line.strip() == "":
            return "".join(lines[i + 1:])
    return c_source


def main():
    # Read tool input from stdin
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            sys.exit(0)
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        # Can't parse input — skip silently
        sys.exit(0)

    # Extract file path from Write or Edit tool input
    file_path = (
        data.get("file_path")      # Write tool
        or data.get("path")        # alternative key
    )

    if not file_path:
        sys.exit(0)

    path = Path(file_path)

    # Only act on .pk64 files
    if path.suffix != ".pk64":
        sys.exit(0)

    # Run pak check on the file
    try:
        result = subprocess.run(
            ["pak", "check", str(path)],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("WARNING: 'pak' not found — cannot validate. Install with: pip install -e .")
        sys.exit(0)

    if result.returncode != 0:
        print("=" * 60)
        print(f"PAK VALIDATION FAILED: {path}")
        print("=" * 60)
        if result.stderr.strip():
            print(result.stderr.strip())
        if result.stdout.strip():
            print(result.stdout.strip())
        print()
        print("Fix the errors above before proceeding.")
        print("Reference LANGUAGE.md and NOT_SUPPORTED.md.")
        print("=" * 60)
        sys.exit(2)

    # Clean — optionally run pak explain for semantic verification
    if os.environ.get("PAK_HOOK_NO_EXPLAIN") == "1":
        sys.exit(0)

    try:
        explain = subprocess.run(
            ["pak", "explain", str(path)],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        sys.exit(0)

    if explain.returncode == 0 and explain.stdout.strip():
        user_code = _extract_user_code(explain.stdout)
        if user_code.strip():
            print("=" * 60)
            print(f"PAK EXPLAIN (user code): {path}")
            print("=" * 60)
            print(user_code.strip())
            print("=" * 60)
            print("Generated C above is your code only (preamble omitted).")
            print("If the output does not match intent, fix the .pk64 source.")
            print("=" * 60)

    sys.exit(0)


if __name__ == "__main__":
    main()
