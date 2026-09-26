#!/usr/bin/env tclsh
# tcl/tools/bench_codegen.tcl — how fast is the code the MIPS backend emits?
#
# Two measurements of the kernels in tcl/tests/bench/kernels.pk64:
#   sim   exact dynamic instruction counts from the MIPS simulator. Fast and
#         deterministic; what to watch while changing the codegen.
#   ares  real emulated VR4300 cycles (COP0 Count, 46.875 MHz) from a ROM run
#         on ares, plus two RDP-path kernels the simulator cannot run.
# Every kernel returns a checksum, and both modes check it against
# tcl/tests/bench/expected.txt: a faster kernel that computes something else
# is a failure, not a win.
#
#   tclsh tcl/tools/bench_codegen.tcl ?sim|ares|all? ?--save FILE? ?--compare FILE?
#
# --save writes "mode kernel value" lines; --compare prints the change against
# a file written by an earlier --save.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl optimize.tcl]
source [file join $REPO tcl mips_sim.tcl]
source [file join $REPO tcl n64enc.tcl]
source [file join $REPO tcl n64link.tcl]
source [file join $REPO tcl n64rom.tcl]

set mode all
set save ""
set compare ""
for {set i 0} {$i < $argc} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        --save    { incr i; set save [lindex $argv $i] }
        --compare { incr i; set compare [lindex $argv $i] }
        default   { set mode $a }
    }
}

proc slurp {p} { set fh [open $p r]; fconfigure $fh -encoding utf-8; set t [read $fh]; close $fh; return $t }
set KERNELS [slurp tcl/tests/bench/kernels.pk64]

set EXPECTED [dict create]
foreach line [split [slurp tcl/tests/bench/expected.txt] \n] {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} continue
    dict set EXPECTED [lindex $line 0] [lindex $line 1]
}

set ::results {}
set ::bad 0
proc record {m k v} { lappend ::results [list $m $k $v] }
proc check_sum {m k got} {
    if {![dict exists $::EXPECTED $k]} {
        puts "  $m $k: no expected checksum (got $got)"; return
    }
    set want [dict get $::EXPECTED $k]
    if {$got != $want} {
        puts "FAIL  $m $k checksum $got, want $want"
        incr ::bad
    }
}

proc asm_of {src} {
    set lx [pak::Lexer new $src]
    set ast [pak::parse_tokens [$lx tokenize]]
    return [pak::records_to_asm [pak::optimize_records [pak::mips_generate_records $ast]]]
}

# ── sim ──────────────────────────────────────────────────────────────────────
# Instruction counts are differences between runs, so each kernel's number is
# its own work with setup (and, for k_cull, the k_project it depends on)
# subtracted out.
proc sim_run {calls} {
    set body "static __out: i32 = 0\nentry \{\n    bench_setup()\n"
    foreach c $calls { append body "    __out = $c\n" }
    append body "\}\n"
    set r [pak::mips_sim_run [asm_of "$::KERNELS\n$body"] main 400000000]
    set addr [dict get [dict get $r data_syms] __out]
    set mw [dict get $r mem_w]
    set out 0
    if {[dict exists $mw $addr]} { set out [dict get $mw $addr] }
    if {$out >= 0x80000000} { set out [expr {$out - 0x100000000}] }
    return [list [dict get $r insns] $out]
}

proc do_sim {} {
    puts "sim (dynamic instruction counts):"
    lassign [sim_run {}] base
    lassign [sim_run {k_project()}] n_proj sum_proj
    lassign [sim_run {k_project() k_cull()}] n_cull sum_cull
    lassign [sim_run {k_calls()}] n_calls sum_calls
    lassign [sim_run {k_muldiv()}] n_md sum_md
    foreach {k n s} [list k_project [expr {$n_proj - $base}] $sum_proj \
                          k_cull [expr {$n_cull - $n_proj}] $sum_cull \
                          k_calls [expr {$n_calls - $base}] $sum_calls \
                          k_muldiv [expr {$n_md - $base}] $sum_md] {
        puts [format "  %-10s %10d insns   sum=%d" $k $n $s]
        record sim $k $n
        check_sum sim $k $s
    }
}

# ── ares ─────────────────────────────────────────────────────────────────────
proc find_tool {name} {
    foreach dir [concat [list /opt/pak-ares/bin] [split $::env(PATH) :]] {
        set p [file join $dir $name]
        if {[file executable $p]} { return $p }
    }
    return ""
}

proc build_rom {dir src} {
    file mkdir $dir
    set bo [file join $dir boot.pakobj]
    pak::enc::write_object_from_asm [slurp runtime/standalone/boot.S] $bo
    set ro [file join $dir runtime.pakobj]
    pak::enc::write_object_from_asm [asm_of [slurp runtime/standalone/runtime.pk64]] $ro
    set go [file join $dir bench.pakobj]
    pak::enc::write_object_from_asm [asm_of $src] $go
    set r [pak::link_objects [list $bo $ro $go] _start]
    set rom [pak::n64rom [dict get $r image] PAKBENCH [pak::n64rom_default_ipl3] \
                 [expr {4 * 1024 * 1024}] ""]
    set path [file join $dir bench.z64]
    set fh [open $path wb]; puts -nonewline $fh $rom; close $fh
    return $path
}

proc do_ares {} {
    set ares [find_tool ares]
    set xvfb [find_tool Xvfb]
    if {$ares eq "" || $xvfb eq ""} {
        puts "SKIP  ares: ares or Xvfb not found (run tools/build_ares.sh)"
        return
    }
    set dir /tmp/pak-bench
    file delete -force $dir
    set rom [build_rom $dir "$::KERNELS\n[slurp tcl/tests/bench/ares_main.pk64]"]
    set disp ""
    for {set d 90} {$d < 120} {incr d} {
        if {[file exists /tmp/.X$d-lock]} continue
        set xpid [exec $xvfb :$d -screen 0 640x480x24 -ac -nolisten tcp >& /dev/null &]
        after 2000
        if {[file exists /tmp/.X$d-lock]} { set disp $d; break }
        catch {exec kill -9 $xpid}
    }
    if {$disp eq ""} { puts "FAIL  ares: no free X display"; incr ::bad; return }
    set log [file join $dir ares.log]
    set pid [exec env DISPLAY=:$disp LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy \
                 $ares --system "Nintendo 64" --no-file-prompt \
                 --setting Audio/Mute=true $rom >& $log &]
    set deadline [expr {[clock seconds] + 300}]
    set txt ""
    while {[clock seconds] < $deadline} {
        after 2000
        catch {set txt [slurp $log]}
        if {[string match "*BENCH done*" $txt]} break
    }
    catch {exec kill -9 $pid}
    catch {exec kill -9 $xpid}
    if {![string match "*BENCH done*" $txt]} {
        puts "FAIL  ares: the benchmark ROM never finished"
        puts [string range $txt end-2000 end]
        incr ::bad
        return
    }
    puts "ares (COP0 ticks at 46.875 MHz; 1 tick = 2 CPU cycles):"
    foreach line [split $txt \n] {
        if {[regexp {BENCH (\S+) ticks=(\d+) sum=(-?\d+)} $line -> k t s]} {
            puts [format "  %-10s %10d ticks  %8.1f us   sum=%d" $k $t [expr {$t / 46.875}] $s]
            record ares $k $t
            check_sum ares $k $s
        }
    }
}

if {$mode in {sim all}}  { do_sim }
if {$mode in {ares all}} { do_ares }

if {$compare ne ""} {
    set old [dict create]
    foreach line [split [slurp $compare] \n] {
        if {[llength $line] == 3} { dict set old "[lindex $line 0] [lindex $line 1]" [lindex $line 2] }
    }
    puts "change vs $compare:"
    foreach r $::results {
        lassign $r m k v
        if {![dict exists $old "$m $k"]} continue
        set o [dict get $old "$m $k"]
        puts [format "  %-4s %-10s %10d -> %10d   %6.2fx" $m $k $o $v [expr {double($o) / max($v, 1)}]]
    }
}
if {$save ne ""} {
    set fh [open $save w]
    foreach r $::results { puts $fh $r }
    close $fh
}
exit [expr {$::bad ? 1 : 0}]
