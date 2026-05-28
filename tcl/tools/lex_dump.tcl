#!/usr/bin/env tclsh
# Dump the Tcl lexer's tokens in the same canonical format as lex_dump.py.
#   TYPE \t LINE \t COL \t ESCAPED_VALUE       (one per token)
#   LEXERROR \t LINE \t COL                    (on lex error)

set here [file dirname [file normalize [info script]]]
source [file join $here .. lexer.tcl]

proc escval {v} {
    return [string map [list "\\" "\\\\" "\n" "\\n" "\t" "\\t" "\r" "\\r"] $v]
}

set path [lindex $argv 0]
set f [open $path r]
fconfigure $f -encoding utf-8
set src [read $f]
close $f

set lx [pak::Lexer new $src]
if {[catch {$lx tokenize} toks]} {
    # lexerror message is "LEXERROR\tLINE\tCOL\tmsg"; emit location only.
    set parts [split $toks "\t"]
    puts "[lindex $parts 0]\t[lindex $parts 1]\t[lindex $parts 2]"
    exit 0
}

set lines {}
foreach t $toks {
    lappend lines "[dict get $t type]\t[dict get $t line]\t[dict get $t col]\t[escval [dict get $t value]]"
}
puts [join $lines "\n"]
