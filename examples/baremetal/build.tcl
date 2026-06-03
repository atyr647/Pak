# examples/baremetal/build.tcl — build a bootable .z64 entirely with the Pak
# toolchain: no gcc, no binutils, no libdragon. The pipeline is
#
#     main.pk64  --(pak explain --backend mips)-->  main.s
#     start.s + main.s  --(tcl/n64asm.tcl)-->       program image @ 0x80000400
#     ipl3.s            --(tcl/n64asm.tcl)-->        IPL3 image @ 0xA4000040 (DMEM)
#     program + IPL3    --(tcl/n64rom.tcl)-->        baremetal.z64
#
# Usage:  tclsh examples/baremetal/build.tcl  [out.z64]
#
# The .pk64 -> .s step is run via the `pak` CLI (see run note below); this
# script performs the assemble + ROM-build steps that are themselves pure Pak
# tooling. Run from the repository root.

set here [file dirname [file normalize [info script]]]
set repo [file dirname [file dirname $here]]
source [file join $repo tcl n64asm.tcl]
source [file join $repo tcl n64rom.tcl]

proc slurp {p} { set f [open $p r]; set d [read $f]; close $f; return $d }

set out [expr {$argc >= 1 ? [lindex $argv 0] : [file join $here baremetal.z64]}]

# 1. Assemble the IPL3 at its DMEM execution address (0xA4000040).
set ipl3 [pak::n64asm [slurp [file join $here ipl3.s]] 0xA4000040]
set ipl3bytes [dict get $ipl3 text]

# 2. Assemble startup + program at the cached entry address (0x80000400).
#    main.s is produced by:  pak explain --backend mips main.pk64 > main.s
set full [slurp [file join $here start.s]]
append full "\n" [slurp [file join $here main.s]]
set r [pak::n64asm $full 0x80000400]
set prog [dict get $r text][dict get $r rodata][dict get $r data]

puts "ipl3=[string length $ipl3bytes]B prog=[string length $prog]B entry=[format 0x%x [dict get $r entry]]"

# 3. Assemble the ROM with our own IPL3 embedded in the 0x40..0xFFF region.
proc pak::n64rom_custom {prog ipl3 title} {
    set hdr [binary format I 0x80371240]
    append hdr [binary format I 0x0000000F]
    append hdr [binary format I 0x80000400]
    append hdr [binary format I 0x00001444]
    append hdr [binary format IIII 0 0 0 0]
    append hdr [binary format a20 [format %-20s [string range $title 0 19]]]
    append hdr [binary format III 0 0 0]
    set ipl3pad [binary format a3008 $ipl3]
    set rom $hdr$ipl3pad$prog
    set min [expr {1<<19}]
    if {[string length $rom] < $min} { append rom [string repeat "\x00" [expr {$min-[string length $rom]}]] }
    return $rom
}
set rom [pak::n64rom_custom $prog $ipl3bytes "PAK BAREMETAL"]
set f [open $out wb]; puts -nonewline $f $rom; close $f
puts "wrote [file tail $out] ([string length $rom] bytes)"
