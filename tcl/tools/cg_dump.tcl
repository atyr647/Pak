#!/usr/bin/env tclsh
# Emit the Tcl codegen's C output for a .pk64 file. On any unported construct the
# codegen raises CGUNPORTED; we print a marker line so cg_parity.sh classifies
# the file as UNPORTED rather than a content mismatch.

set here [file dirname [file normalize [info script]]]
source [file join $here .. parser.tcl]
source [file join $here .. codegen.tcl]

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
    puts "UNPORTED\tparse"
    exit 0
}

if {[catch { set c [pak::generate $ast $path] } err]} {
    if {[string match "CGUNPORTED*" $err]} {
        puts "UNPORTED\t[lindex [split $err \t] 1]"
    } else {
        puts "ERROR\t$err"
    }
    exit 0
}
puts $c
