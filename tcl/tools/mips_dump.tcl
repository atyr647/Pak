#!/usr/bin/env tclsh
# Emit the Tcl MIPS backend's assembly for a .pak file. On any unported
# construct the backend raises MIPSUNPORTED; print a marker so mips_parity.sh
# classifies the file as UNPORTED rather than a content mismatch.

set here [file dirname [file normalize [info script]]]
source [file join $here .. parser.tcl]
source [file join $here .. mips_codegen.tcl]

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

if {[catch { set asm [pak::mips_generate $ast] } err]} {
    if {[string match "MIPSUNPORTED*" $err]} {
        puts "UNPORTED\t[lindex [split $err \t] 1]"
    } else {
        puts "ERROR\t$err"
    }
    exit 0
}
# getvalue() already ends with a newline; avoid adding a second.
puts -nonewline $asm
