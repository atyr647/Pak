#!/usr/bin/env tclsh
# Dump the Tcl typechecker's diagnostics in the same canonical form as
# tc_dump.py: one "(CODE SEVERITY \"msg\" \"hint\")" per line, in the order the
# checker accumulates them (errors and warnings interleaved).

set here [file dirname [file normalize [info script]]]
source [file join $here .. parser.tcl]
source [file join $here .. typechecker.tcl]

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

foreach d [pak::typecheck $ast $path] {
    set msg [pak::esc [dict get $d message]]
    set hint [pak::esc [dict get $d hint]]
    puts "([dict get $d code] [dict get $d severity] $msg $hint)"
}
