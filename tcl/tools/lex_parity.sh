#!/usr/bin/env bash
# Compare the Tcl lexer against the Python lexer (the oracle) on every .pak
# file in the repo. Exits non-zero if any token stream differs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

pass=0; fail=0; failed_files=""
while IFS= read -r f; do
    py="$(python3 "$HERE/lex_dump.py" "$f" 2>/dev/null)"
    tcl="$(tclsh "$HERE/lex_dump.tcl" "$f" 2>/dev/null)"
    if [ "$py" = "$tcl" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        failed_files="$failed_files\n$f"
        if [ "${VERBOSE:-0}" = "1" ]; then
            echo "=== DIFF: $f ==="
            diff <(printf '%s' "$py") <(printf '%s' "$tcl") | head -20
        fi
    fi
done < <(find examples ai tests -name '*.pak' | sort)

echo "lexer parity: PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
    echo -e "MISMATCHED:$failed_files"
    exit 1
fi
