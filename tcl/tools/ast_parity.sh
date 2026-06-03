#!/usr/bin/env bash
# Compare the Tcl parser's AST against the Python parser (oracle) on every .pk64
# file. A file "ports" when both produce identical structural ASTs. Files the
# Tcl parser can't yet handle show as UNPORTED (Tcl emits PARSEERROR/ERROR).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

match=0; unported=0; mismatch=0; mism_files=""
while IFS= read -r f; do
    py="$(python3 "$HERE/ast_dump.py" "$f" 2>/dev/null)"
    tcl="$(tclsh "$HERE/ast_dump.tcl" "$f" 2>/dev/null)"
    if [ "$py" = "$tcl" ]; then
        match=$((match+1))
    elif printf '%s' "$tcl" | grep -q '^PARSEERROR\|^ERROR'; then
        unported=$((unported+1))
        [ "${SHOW_UNPORTED:-0}" = "1" ] && echo "UNPORTED: $f -> $tcl"
    else
        mismatch=$((mismatch+1))
        mism_files="$mism_files $f"
        if [ "${VERBOSE:-0}" = "1" ]; then
            echo "=== MISMATCH: $f ==="
            diff <(printf '%s' "$py") <(printf '%s' "$tcl") | head -25
        fi
    fi
done < <(find examples ai tests -name '*.pk64' | sort)

total=$((match+unported+mismatch))
echo "parser parity: MATCH=$match  UNPORTED=$unported  MISMATCH=$mismatch  (of $total)"
[ -n "$mism_files" ] && echo -e "MISMATCHED:\n$(echo $mism_files | tr ' ' '\n')"
[ "$mismatch" -eq 0 ]
