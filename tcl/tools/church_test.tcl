#!/usr/bin/env tclsh
# tcl/tools/church_test.tcl — the CHROMA nave, end to end, on generated MIPS.
#
# examples/chroma/church.pk64 is the FZ "Path A": no libdragon, no RSP.
# This runs the runtime plus that scene in tcl/mips_sim.tcl and asserts the
# three things the architecture rests on.
#
#   1. It fits. Code + .data must end below FB0 (0x80200000). The whole point
#      of streaming is that the nave costs tens of KB instead of the 2.25 MB
#      eighteen 256x256 RGBA16 sheets would cost, which would land on top of
#      the framebuffers.
#   2. It streams. PI_CART_ADDR / PI_WR_LEN show a real 2 KB page fetch from
#      the cart, not an embedded texture.
#   3. It draws textured. SET_TEXTURE_IMAGE / SET_TILE / LOAD_TILE / TRI_TEX_Z
#      appear in the display list the DP is handed, and the tile words are
#      byte-identical to the encodings tcl/tools/rdp_test.tcl already asserts.
#
# dma_read writes PI_STATUS to clear the interrupt, then dma_wait reads
# PI_STATUS back. On hardware those are different things: the write clears an
# interrupt, the read reports busy bits. The simulator used to hand back the
# 0x02 that was just written, so dma_wait spun on IO_BUSY forever; it now
# models the read side (see the lw handler in tcl/mips_sim.tcl) and the DP/VI
# presets below are the only ones a scene still needs.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]
source [file join $REPO tcl n64link.tcl]

set RUNTIME runtime/standalone/runtime.pk64
set SCENE   examples/chroma/church.pk64
set DL_BASE [expr {0xA0297000}]

set ::pass 0
set ::fail 0

proc ok {name got want} {
    if {$got eq $want} { incr ::pass; puts "ok    $name = $got" } \
    else { incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want" }
}
proc ok_true {name cond {detail ""}} {
    if {$cond} { incr ::pass; puts "ok    $name$detail" } \
    else { incr ::fail; puts "FAIL  $name$detail" }
}
proc word_at {mw addr} {
    set addr [expr {$addr}]
    if {![dict exists $mw $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mw $addr]]
}

# ── 1. the scene compiles for the standalone HAL and fits under FB0 ──────────

puts "== HAL contract and memory map =="

set rc [catch {exec [info nameofexecutable] tcl/cli.tcl check $SCENE --backend mips} out]
ok_true "church.pk64 passes pak check --backend mips" [expr {$rc == 0}] \
    [expr {$rc == 0 ? "" : "\n        $out"}]

set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] pak_church_test]
file delete -force $tmp
file mkdir $tmp
set boot [file join $tmp boot.pakobj]
set rt   [file join $tmp runtime.pakobj]
set obj  [file join $tmp church.pakobj]
foreach {args label} [list \
        [list asmobj runtime/standalone/boot.S -o $boot] "boot.S" \
        [list objgen $RUNTIME -o $rt]                    "runtime.pk64" \
        [list objgen $SCENE -o $obj]                     "church.pk64"] {
    if {[catch {exec [info nameofexecutable] tcl/cli.tcl {*}$args} e]} {
        puts "FAIL  cannot build $label: $e"
        incr ::fail
        puts "\nPASS=$::pass  FAIL=$::fail"
        exit 1
    }
}

if {[catch {set link [pak::link_objects [list $boot $rt $obj] _start]} e]} {
    puts "FAIL  church does not link: $e"
    incr ::fail
    puts "\nPASS=$::pass  FAIL=$::fail"
    exit 1
}
incr ::pass
puts "ok    church links against boot.S + runtime.pk64"

set syms [dict get $link symbols]
set end  [dict get $syms _end]
set fb0  $::pak::MEM_FB0
set used [expr {$end - 0x80000400}]
ok_true "code + .data ends below FB0" [expr {$end < $fb0}] \
    [format " (_end %#010x, FB0 %#010x, %d KB used, %.2f MB free)" \
        $end $fb0 [expr {$used / 1024}] [expr {($fb0 - $end) / 1048576.0}]]

# Eighteen 256x256 RGBA16 sheets are 2359296 bytes. The claim this scene makes
# is that streaming keeps it far under that, not merely under FB0.
ok_true "nave costs far less than the 18 embedded sheets" [expr {$used < 262144}] \
    [format " (%d KB vs 2304 KB embedded)" [expr {$used / 1024}]]

# The PI needs its DRAM address 16-byte aligned (E202 is the compile-time half
# of this; the link is where it actually has to land).
ok_true "page_buf is 16-byte aligned in the link" \
    [expr {[dict exists $syms page_buf] && ([dict get $syms page_buf] & 15) == 0}] \
    [expr {[dict exists $syms page_buf] ? [format " (%#010x)" [dict get $syms page_buf]] : " (missing)"}]

# The counterfactual. "Streaming keeps it under FB0" only means something if
# NOT streaming would not. This links a scene that embeds the eighteen sheets
# and asserts the linker refuses it, naming the framebuffer.
#
# It doubles as a guard on .space: the encoder used to emit one byte per proc
# call, which made a 2 MB .bss look like a hang instead of reaching this error.
# If that regresses, this step stops completing.
puts ""
puts "== embedding the sheets instead is refused =="

set fat_src [file join $tmp fat.pk64]
set f [open $fat_src w]
puts $f "-- 18 sheets of 256x256 RGBA16, the thing church.pk64 does not embed."
puts $f "static fat_sheets: \[2359296\]u8 = undefined"
puts $f "entry {"
puts $f "    display.init(0, 2, 3, 0, 1)"
puts $f "    fat_sheets\[0\] = 1"
puts $f "    loop { }"
puts $f "}"
close $f
set fat_obj [file join $tmp fat.pakobj]
if {[catch {exec [info nameofexecutable] tcl/cli.tcl objgen $fat_src -o $fat_obj} e]} {
    puts "FAIL  cannot objgen the embedded-sheet scene: $e"
    incr ::fail
} else {
    incr ::pass
    puts "ok    a 2.25 MB .bss assembles (no quadratic .space)"
    set refused [catch {pak::link_objects [list $boot $rt $fat_obj] _start} linkerr]
    ok_true "linker refuses sheets that reach the framebuffer" \
        [expr {$refused && [string match "*memory map overlap*" $linkerr] \
               && [string match "*framebuffer 0*" $linkerr]}] \
        [expr {$refused ? "" : " (it linked, which it must not)"}]
}

# ── 2 & 3. execute it ────────────────────────────────────────────────────────

proc run_scene {budget} {
    global RUNTIME SCENE REPO
    set fh [open $RUNTIME r]; set rt [read $fh]; close $fh
    set fh [open $SCENE r];   set sc [read $fh]; close $fh
    # The runtime already declares the HAL; drop the scene's `use` lines so the
    # two concatenate into one program.
    set keep {}
    foreach l [split $sc "\n"] {
        if {[string match "use *" [string trim $l]]} continue
        lappend keep $l
    }
    set combined [file join $REPO .church_combined.pk64]
    set f [open $combined w]; puts -nonewline $f "$rt\n[join $keep \n]"; close $f
    set asm [exec [info nameofexecutable] tcl/tools/mips_dump.tcl $combined]
    file delete $combined
    if {[string match "UNPORTED*" $asm] || [string match "ERROR*" $asm]} {
        return [list err [lindex [split $asm "\n"] 0]]
    }
    # DP idle, VI past the active region.
    set preset [dict create \
        0xA410000C 0 \
        0xA4400010 {0x1E0 0x000}]
    return [list ok [pak::mips_sim_run $asm main $budget $preset]]
}

# display.init clears three framebuffers on the CPU before the first draw, so
# the first frame's display list does not exist until several million
# instructions in.
puts ""
puts "== streaming a page over the PI =="

lassign [run_scene 6400000] st r
if {$st eq "err"} {
    puts "FAIL  scene does not lower to MIPS: $r"
    incr ::fail
    puts "\nPASS=$::pass  FAIL=$::fail"
    exit 1
}
set mw [dict get $r mem_w]

# PAGE_BASE is 0x10200000 and a page is 2048 bytes, so every fetch is
# base + n*2048 and the length register is 2047.
set cart [word_at $mw 0xA4600004]
ok_true "PI_CART_ADDR is a page inside the atlas" \
    [expr {$cart ne "<unwritten>" && ("0x$cart" >= 0x10200000) && \
           (("0x$cart" - 0x10200000) % 2048) == 0}] \
    " ($cart)"
ok "PI_WR_LEN is 2048-1" [word_at $mw 0xA460000C] 000007FF
ok_true "PI_DRAM_ADDR is 16-byte aligned" \
    [expr {[word_at $mw 0xA4600000] ne "<unwritten>" && \
           ("0x[word_at $mw 0xA4600000]" & 15) == 0}] \
    " ([word_at $mw 0xA4600000])"

puts ""
puts "== the display list handed to the DP =="

set words {}
for {set i 0} {$i < 400} {incr i} {
    set a [expr {$DL_BASE + $i * 4}]
    if {![dict exists $mw $a]} break
    lappend words [format %08X [dict get $mw $a]]
}
ok_true "the scene built a display list" [expr {[llength $words] > 0}] \
    " ([llength $words] words)"

proc find_cmd {words op} {
    for {set i 0} {$i < [llength $words]} {incr i 2} {
        set hi [lindex $words $i]
        if {[expr {("0x$hi" >> 24) & 0x3F}] == $op} { return $i }
    }
    return -1
}

# The Z buffer has to be attached, not just reserved.
set zi [find_cmd $words 0x3E]
ok_true "SET_Z_IMAGE attaches the Z buffer" [expr {$zi >= 0}] \
    [expr {$zi >= 0 ? " (at +[expr {$zi*4}], [lindex $words [expr {$zi+1}]])" : ""}]

# The texture is the KSEG1 scratch buffer, 32 texels wide, RGBA 16-bit:
# 0x3D<<24 | fmt 0 | size 2 <<19 | (32-1) == 3D10001F. rdp_test asserts the
# same word for the same call.
set ti [find_cmd $words 0x3D]
ok_true "SET_TEXTURE_IMAGE present" [expr {$ti >= 0}]
if {$ti >= 0} {
    ok "SET_TEXTURE_IMAGE is RGBA/16-bit/32-wide" [lindex $words $ti] 3D10001F
}

# SET_TILE with cms/cmt = clamp and mask 5 (log2 32), so S and T clamp at the
# page edge instead of wrapping into the next page's texels. Byte-identical to
# the golden in rdp_test.tcl for set_tile_mask(0,0,2,8,0,0,2,2,5,5).
set si [find_cmd $words 0x35]
ok_true "SET_TILE present" [expr {$si >= 0}]
if {$si >= 0} {
    ok "SET_TILE is clamp/clamp, mask 5/5" \
        "[lindex $words $si] [lindex $words [expr {$si+1}]]" "35101000 00094250"
}

# LOAD_TILE over the full 32x32 page: SH/TH are 31 in 10.2, i.e. 0x7C.
set li [find_cmd $words 0x34]
ok_true "LOAD_TILE present" [expr {$li >= 0}]
if {$li >= 0} {
    ok "LOAD_TILE covers the whole 32x32 page" \
        "[lindex $words $li] [lindex $words [expr {$li+1}]]" "34000000 0007C07C"
}

# The thing this whole exercise is for: a textured, Z-buffered triangle.
set tri [find_cmd $words 0x0B]
ok_true "TRI_TEX_Z (RDP 0x0B) in the stream" [expr {$tri >= 0}] \
    [expr {$tri >= 0 ? " (at +[expr {$tri*4}])" : ""}]
if {$tri >= 0} {
    # TRI_TEX_Z is 14 double-words: 4 of edge setup, 8 of texture coefficients
    # and 2 of Z. (An earlier revision of this test said 11, which is the count
    # for no command at all.) The tile index lives in bits 16-18 of w0 and must
    # be the tile the page was just loaded into.
    ok_true "TRI_TEX_Z is a complete 14-doubleword command" \
        [expr {$tri + 28 <= [llength $words]}]
    ok "TRI_TEX_Z draws with tile 0" \
        [format %d [expr {("0x[lindex $words $tri]" >> 16) & 0x7}]] 0
}

puts ""
puts "== the DP is actually kicked, and the VI flips =="

lassign [run_scene 40000000] st2 r2
if {$st2 eq "ok"} {
    set mw2 [dict get $r2 mem_w]
    ok "DPC_START points at the display list" [word_at $mw2 0xA4100000] 00297000
    ok "DPC_STATUS clears xbus/freeze/flush" [word_at $mw2 0xA410000C] 00000015
    ok_true "VI_ORIGIN was set to a framebuffer" \
        [expr {[word_at $mw2 0xA4400004] in {00200000 00225800 0024B000}}] \
        " ([word_at $mw2 0xA4400004])"
} else {
    puts "FAIL  second run: $r2"
    incr ::fail
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
exit [expr {$::fail > 0 ? 1 : 0}]
