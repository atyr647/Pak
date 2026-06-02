#!/usr/bin/env tclsh
# Emit Tcl-generated Makefiles for a fixed set of scenarios (the makefile_gen
# port has no .pak corpus; parity is checked over representative parameter
# combinations covering c/mips backends, tiny3d, pakfs, save types, repr()).
set here [file dirname [file normalize [info script]]]
source [file join $here .. makefile_gen.tcl]
set scenarios {
    {mygame {My Cool Game} {main.c player.c} {} none 16 320x240 3 debug 0 . c}
    {g2 {A Very Long Title That Exceeds Twenty Chars} {a.c} g2.pakfs eeprom16k 32 640x480 2 release 0 . c}
    {m3 {It's Mine} {x.s y.c} m3.pakfs none 16 320x240 3 debug 1 . mips}
    {m4 {3D Demo} {scene.s} {} flashram 16 320x240 3 debug 1 . mips}
}
set out {}
foreach sc $scenarios {
    lassign $sc pn rt cf pa st bd res fb opt t3d root be
    lappend out [pak::generate_makefile $pn $rt $cf $pa $st $bd $res $fb $opt $t3d $root $be]
}
puts -nonewline [join $out "\n=====SCENARIO=====\n"]
