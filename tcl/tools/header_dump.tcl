#!/usr/bin/env tclsh
# Emit the Tcl header generator's output for a .pak file + module path.
set here [file dirname [file normalize [info script]]]
source [file join $here .. parser.tcl]
source [file join $here .. headergen.tcl]
set path [lindex $argv 0]
set modpath [lindex $argv 1]
set f [open $path r]; fconfigure $f -encoding utf-8; set src [read $f]; close $f
if {[catch { set lx [pak::Lexer new $src]; set ast [pak::parse_tokens [$lx tokenize]] } err]} {
    puts "UNPORTED\tparse"; exit 0
}
if {[catch { set h [pak::generate_header $ast $modpath] } err]} {
    if {[string match "CGUNPORTED*" $err]} { puts "UNPORTED\t[lindex [split $err \t] 1]" } else { puts "ERROR\t$err" }
    exit 0
}
puts -nonewline $h
