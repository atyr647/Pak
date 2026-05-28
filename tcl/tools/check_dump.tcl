#!/usr/bin/env tclsh
# Dump the Tcl checker's diagnostics in the same canonical form as check_dump.py:
# errors first, then warnings, one "(CODE SEVERITY \"msg\" \"hint\")" per line.

set here [file dirname [file normalize [info script]]]
source [file join $here .. parser.tcl]
source [file join $here .. checker.tcl]

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

set diags [pak::semantic_check $ast $path]
# errors first, then warnings — matching check_dump.py / semantic_check split.
foreach want {error warning} {
    foreach d $diags {
        if {[dict get $d severity] ne $want} continue
        set msg [pak::esc [dict get $d message]]
        set hint [pak::esc [dict get $d hint]]
        puts "([dict get $d code] [dict get $d severity] $msg $hint)"
    }
}
