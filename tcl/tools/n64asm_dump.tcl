#!/usr/bin/env tclsh
source [file join [file dirname [file normalize [info script]]] .. n64asm.tcl]
set s [read [open [lindex $argv 0]]]
set r [pak::n64asm $s 0x80000400]
binary scan [dict get $r text][dict get $r rodata] H* h; puts -nonewline $h
