#!/usr/bin/env tclsh
# tcl/tools/rsp_diag_test.tcl — cli.tcl's pak::rsp_diag, the piece that
# turns a caught RSPUNPORTED\t<line>\t<col>\t<message> string (rsp_codegen.
# tcl's pak::rsp_unported) into a real E701 diagnostic dict, printed by
# pak::diag_str exactly like every other Pak error. Before this (task #45),
# `pak build --backend rsp`/`pak explain --backend rsp` stripped a fixed
# 12-character prefix off the raw string and printed the rest verbatim --
# which broke the moment rsp_unported started embedding line/col, and
# never had a real file:line:col in the first place. This is the CLI-side
# half of that fix; tcl/tools/rsp_codegen_test.tcl covers the codegen side
# (that rsp_unported actually captures a node's real position).

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl cli.tcl]

set ::pass 0
set ::fail 0
proc check_eq {name got want} {
    if {$got eq $want} { incr ::pass; puts "ok    $name" } \
    else { incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want" }
}

puts "== pak::rsp_diag: RSPUNPORTED string -> diagnostic dict =="
set d [pak::rsp_diag "RSPUNPORTED\t7\t5\toperator '*' -- the RSP scalar unit has no multiply or divide" myfile.pk64]
check_eq "code is E701" [dict get $d code] E701
check_eq "line carried through" [dict get $d line] 7
check_eq "col carried through" [dict get $d col] 5
check_eq "message carried through, tag stripped" [dict get $d message] \
    "operator '*' -- the RSP scalar unit has no multiply or divide"
check_eq "severity is error" [dict get $d severity] error
check_eq "filename carried through" [dict get $d filename] myfile.pk64

puts ""
puts "== pak::diag_str: prints the same shape as every other Pak diagnostic =="
check_eq "full formatted diagnostic" [pak::diag_str $d] \
    "error\[E701\]: operator '*' -- the RSP scalar unit has no multiply or divide\n  --> myfile.pk64:7:5"

puts ""
puts "== a message that itself contains tabs doesn't get truncated =="
# join [lrange $parts 3 end] "\t" (not [lindex $parts 3]) is what makes this
# safe -- a message with a literal tab character would otherwise silently
# lose everything after the first one.
set d2 [pak::rsp_diag "RSPUNPORTED\t3\t1\tfield 'x'\thas a tab in it somehow" f.pk64]
check_eq "message past the 3rd tab is preserved, not dropped" [dict get $d2 message] \
    "field 'x'\thas a tab in it somehow"

puts ""
puts "== a malformed/unrecognized error string degrades gracefully =="
set d3 [pak::rsp_diag "some other unrelated Tcl error" f.pk64]
check_eq "code still E701" [dict get $d3 code] E701
check_eq "line defaults to 0" [dict get $d3 line] 0
check_eq "whole string becomes the message" [dict get $d3 message] "some other unrelated Tcl error"

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
