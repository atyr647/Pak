#!/usr/bin/env bash
# Compare the Tcl checker's diagnostics against the Python checker (oracle) on
# every .pak file, plus the dedicated fixtures in tcl/tests/check that exercise
# each diagnostic code. A file "matches" when both emit identical diagnostics
# (code + severity + message + hint), in the same order.
#
# Source positions are not yet tracked in the Tcl AST (parser-parity staging),
# so the one position-bearing text — E107's "first defined at line N" hint — is
# normalized to "line N" on both sides before diffing. Everything else, including
# argument counts in E105 messages, is compared verbatim.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

norm() { sed -E 's/line [0-9]+/line N/g'; }

match=0; unported=0; mismatch=0; mism_files=""
while IFS= read -r f; do
    py="$(python3 "$HERE/check_dump.py" "$f" 2>/dev/null | norm)"
    tcl="$(tclsh "$HERE/check_dump.tcl" "$f" 2>/dev/null | norm)"
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
done < <( { find examples ai tests -name '*.pak'; find tcl/tests/check -name '*.pak'; } | sort )

total=$((match+unported+mismatch))
echo "checker parity: MATCH=$match  UNPORTED=$unported  MISMATCH=$mismatch  (of $total)"
[ -n "$mism_files" ] && echo -e "MISMATCHED:\n$(echo $mism_files | tr ' ' '\n')"
[ "$mismatch" -eq 0 ]
