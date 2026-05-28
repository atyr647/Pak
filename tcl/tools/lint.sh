#!/usr/bin/env bash
# Static-check the Tcl compiler sources with nagelfar.
#
# Files are checked together (ast.tcl first) so cross-file proc definitions
# resolve. External commands are declared in pak.syntax (a nagelfar DB). Two
# benign message classes are still filtered:
#   - "... which is also a variable"  : intentional dict-key string literals
#   - "Non static subcommand"         : dynamic method dispatch (my $var)
# Exits non-zero on any error-severity (": E ") finding.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"
NAGELFAR="$HERE/vendor/nagelfar/nagelfar.tcl"

# ast_schema.tcl is generated (89 struct::record lines) and intentionally skipped.
FILES="tcl/ast.tcl tcl/ast_visit.tcl tcl/lexer.tcl tcl/parser.tcl"

out="$(tclsh "$NAGELFAR" -s "$HERE/pak.syntax" $FILES 2>&1 \
  | grep -vE 'which is also a variable|Non static subcommand')"
echo "$out"

if echo "$out" | grep -q ': E '; then
    echo "nagelfar: ERROR-severity findings present"
    exit 1
fi
echo "nagelfar: no warnings/errors (after benign filters)"
