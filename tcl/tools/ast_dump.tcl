#!/usr/bin/env tclsh
# Dump the Tcl parser's AST in the same canonical S-expression as ast_dump.py.

set here [file dirname [file normalize [info script]]]
source [file join $here .. parser.tcl]

set path [lindex $argv 0]
set f [open $path r]
fconfigure $f -encoding utf-8
set src [read $f]
close $f

if {[catch {
    set lx [pak::Lexer new $src]
    set toks [$lx tokenize]
    set ast [pak::parse_tokens $toks]
} err]} {
    if {[string match "PARSEERROR*" $err] || [string match "LEXERROR*" $err]} {
        set parts [split $err "\t"]
        puts "PARSEERROR\t[lindex $parts 1]\t[lindex $parts 2]"
    } else {
        puts "ERROR\t$err"
    }
    exit 0
}
puts [pak::serialize $ast]
