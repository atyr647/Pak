#!/usr/bin/env bash
# Verify the Tcl MIPS backend compiles all canonical examples without error and
# stays byte-identical to itself across successive runs (regression gate).
#
# The Python MIPS backend has been deprecated. This script is now Tcl-only:
# a file PASSES when tclsh mips_dump.tcl emits assembly (no UNPORTED/ERROR).
# Any previously-passing file that now emits an error is a REGRESSION.
#
# Snapshots are regenerated with REGEN=1.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SNAP_DIR="$REPO/tests/snapshots/mips"
cd "$REPO"

pass=0; fail=0; fail_files=""
skipped=0
while IFS= read -r f; do
    name=$(basename "$f" .pk64)
    # Only examples the HAL contract accepts are standalone programs. Asking
    # the MIPS backend to lower one that `pak check --backend mips` rejects is
    # meaningless -- it refuses, correctly, and that refusal is not a
    # regression. Same rule as tcl/tools/link_test.tcl, so the two agree.
    if ! tclsh "$REPO/tcl/cli.tcl" check "$f" --backend mips >/dev/null 2>&1; then
        skipped=$((skipped+1))
        [ "${VERBOSE:-0}" = "1" ] && echo "SKIP (not standalone): $f"
        continue
    fi
    out="$(tclsh "$HERE/mips_dump.tcl" "$f" 2>/dev/null)"
    first=$(printf '%s' "$out" | head -1)
    if printf '%s' "$first" | grep -q '^UNPORTED\|^ERROR'; then
        fail=$((fail+1))
        fail_files="$fail_files $f"
        [ "${VERBOSE:-0}" = "1" ] && echo "FAIL: $f  ($first)"
        continue
    fi
    # Snapshot regression check
    snap="$SNAP_DIR/${name}.s"
    if [ "${REGEN:-0}" = "1" ]; then
        mkdir -p "$SNAP_DIR"
        printf '%s\n' "$out" > "$snap"
    fi
    if [ ! -s "$snap" ]; then
        # A missing OR empty snapshot is a failure, not a free pass: a truncated
        # snapshot is how a regression gate silently stops checking anything.
        # Regenerate with REGEN=1.
        echo "MISSING OR EMPTY SNAPSHOT: $snap"
        fail=$((fail+1))
        fail_files="$fail_files $f"
    else
        expected=$(cat "$snap")
        if [ "$out" = "$expected" ]; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
            fail_files="$fail_files $f"
            [ "${VERBOSE:-0}" = "1" ] && { echo "=== REGRESSION: $f ==="; diff <(printf '%s\n' "$expected") <(printf '%s\n' "$out") | head -40; }
        fi
    fi
done < <(find examples/canonical -name '*.pk64' | sort)

total=$((pass+fail))
echo "mips: PASS=$pass  FAIL=$fail  SKIP=$skipped (not standalone)  (of $((total+skipped)) canonical)"
[ -n "$fail_files" ] && echo -e "FAILED:\n$(echo $fail_files | tr ' ' '\n')"
[ "$fail" -eq 0 ]
