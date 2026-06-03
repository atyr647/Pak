#!/usr/bin/env tclsh
# Tcl c2pak transpile of a .c file -> .pk64 text (CGUNPORTED -> UNPORTED marker).
set here [file dirname [file normalize [info script]]]
source [file join $here .. c2pak.tcl]
set path [lindex $argv 0]
set f [open $path r]; fconfigure $f -encoding utf-8; set src [read $f]; close $f
if {[catch { set out [pak::c2pak_transpile $src [file tail $path]] } err]} {
    if {[string match "C2PAKUNPORTED*" $err]} { puts "UNPORTED\t[lindex [split $err \t] 1]" } else { puts "ERROR\t$err" }
    exit 0
}
puts -nonewline $out
