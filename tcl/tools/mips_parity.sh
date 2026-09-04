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
while IFS= read -r f; do
    name=$(basename "$f" .pk64)
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
echo "mips: PASS=$pass  FAIL=$fail  (of $total canonical)"
[ -n "$fail_files" ] && echo -e "FAILED:\n$(echo $fail_files | tr ' ' '\n')"
[ "$fail" -eq 0 ]
