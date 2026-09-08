#!/usr/bin/env bash
# Static-check the Tcl compiler sources with nagelfar.
#
# Files are checked together (ast.tcl first) so cross-file proc definitions
# resolve. External commands are declared in pak.syntax (a nagelfar DB). Three
# benign message classes are still filtered:
#   - "... which is also a variable"  : intentional dict-key string literals
#   - "Non static subcommand"         : dynamic method dispatch (my $var)
#   - "Unescaped close brace"         : literal '}' inside emitted-C strings in
#                                       codegen.tcl (a C generator prints braces)
# Exits non-zero on any error-severity (": E ") finding.
#
# NOTE on the DB flags: nagelfar loads its built-in syntax database (which
# defines core commands like `package`, `string`, `dict`) ONLY when no `-s` is
# given. Passing just `-s pak.syntax` therefore suppressed the base DB and made
# nagelfar crash on `package require` ("can't read ::syntax(package)"). `-s _`
# explicitly re-adds the built-in DB, then `-s pak.syntax` layers ours on top.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"
NAGELFAR="$HERE/vendor/nagelfar/nagelfar.tcl"

# ast_schema/check_tables/tc_tables/cg_tables/mips_tables are generated and skipped.
FILES="tcl/ast.tcl tcl/ast_visit.tcl tcl/lexer.tcl tcl/parser.tcl tcl/checker.tcl tcl/typechecker.tcl tcl/codegen.tcl tcl/mips_codegen.tcl tcl/rdpdis.tcl"

out="$(tclsh "$NAGELFAR" -s _ -s "$HERE/pak.syntax" $FILES 2>&1 \
  | grep -vE 'which is also a variable|Non static subcommand|Unescaped close brace')"
echo "$out"

# The base DB ships per-Tcl-version variants (syntaxdb86/87/90). Defaulting to
# the generic syntaxdb.tcl is fine for our purposes; we only rely on it for core
# command arity, not version-specific subcommands.

# Guard against nagelfar itself failing (e.g. a missing base DB makes it crash
# with a Tcl stack trace rather than a ": E " finding). Such a crash is not a
# clean bill of health — treat it as a lint failure so the tool can't silently
# pass on its own breakage, which is exactly how the ::syntax(package) crash hid.
if echo "$out" | grep -qE 'while executing|can.t read "::syntax|invoked from within'; then
    echo "nagelfar: internal failure (the linter crashed, not a clean pass)"
    exit 1
fi

if echo "$out" | grep -q ': E '; then
    echo "nagelfar: ERROR-severity findings present"
    exit 1
fi
echo "nagelfar: no warnings/errors (after benign filters)"
