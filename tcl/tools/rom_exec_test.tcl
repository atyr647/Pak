#!/usr/bin/env tclsh
# tcl/tools/rom_exec_test.tcl — run the linked image from _start.
#
# Every other simulator test in this repo runs the codegen's RECORDS, starting
# at `main`. That leaves two things nothing has ever executed:
#
#   1. runtime/standalone/boot.S. The stack pointer, the .bss zero-fill, the
#      exception-vector install and the handoff to main were only ever read.
#   2. The bytes. Records are one step short of machine code, so an encoding or
#      relocation mistake is invisible to a record-level run by construction.
#
# This closes both. It links boot.S + the standalone runtime + a program the
# same way `pak build --backend mips` does, disassembles the resulting image
# with binutils -- the bytes Pak actually produced, at the addresses Pak
# actually assigned -- turns that listing into something tcl/mips_sim.tcl can
# execute, seeds memory from the image, and starts at _start.
#
# Using objdump rather than a hand-written decoder is deliberate: a decoder of
# mine could misread a field the same way tcl/n64enc.tcl does and agree with it.
#
# Requires mips64-elf binutils; skips loudly without them.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl optimize.tcl]
source [file join $REPO tcl n64enc.tcl]
source [file join $REPO tcl n64link.tcl]
source [file join $REPO tcl mips_sim.tcl]

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

proc find_tool {name} {
    foreach dir [list /opt/pak-n64/bin {*}[split $::env(PATH) :]] {
        set p [file join $dir $name]
        if {[file executable $p]} { return $p }
    }
    return ""
}
set OBJDUMP [find_tool mips64-elf-objdump]
if {$OBJDUMP eq ""} {
    puts "SKIP  no mips64-elf-objdump on PATH (run tools/build_n64_toolchain.sh)"
    exit 0
}

set TMP /tmp/pak-rom-exec
file delete -force $TMP
file mkdir $TMP

# ── link, exactly as pak::cli_build_mips_rom does ────────────────────────────

proc asm_of_pak {path} {
    set fh [open $path r]; fconfigure $fh -encoding utf-8
    set src [read $fh]; close $fh
    set lx [pak::Lexer new $src]
    set ast [pak::parse_tokens [$lx tokenize]]
    return [pak::records_to_asm [pak::optimize_records [pak::mips_generate_records $ast]]]
}

proc link_program {tag src} {
    global TMP
    set dir [file join $TMP $tag]
    file mkdir $dir
    set fh [open runtime/standalone/boot.S r]; set boot [read $fh]; close $fh
    set bo [file join $dir boot.pakobj]
    pak::enc::write_object_from_asm $boot $bo
    set ro [file join $dir runtime.pakobj]
    pak::enc::write_object_from_asm [asm_of_pak runtime/standalone/runtime.pk64] $ro
    set pk [file join $dir game.pk64]
    set fh [open $pk w]; puts -nonewline $fh $src; close $fh
    set go [file join $dir game.pakobj]
    pak::enc::write_object_from_asm [asm_of_pak $pk] $go
    return [pak::link_objects [list $bo $ro $go] _start]
}

# ── the linked image, as something the simulator can run ─────────────────────

# Mnemonics tcl/mips_sim.tcl actually implements, read out of its switch arms.
# An instruction it does not know is a silent no-op there, which would let this
# test "pass" a program the simulator never really ran, so anything missing is
# reported instead.
proc sim_mnemonics {} {
    set fh [open [file join tcl mips_sim.tcl] r]; set txt [read $fh]; close $fh
    set in 0
    set known [dict create]
    foreach line [split $txt \n] {
        if {[regexp {^\s*switch -- \$op \{} $line]} { set in 1; continue }
        if {!$in} continue
        if {[regexp {^\}} $line]} break
        # A switch arm: eight spaces, one mnemonic or several joined by "-".
        if {[regexp {^\s{8}([a-z0-9._ -]+?)\s*\{} $line -> arms]} {
            foreach a [split $arms -] {
                set a [string trim $a]
                if {$a ne ""} { dict set known $a 1 }
            }
        }
    }
    # Handled outside the switch by name-shaped dispatch.
    foreach m {b beqz bnez} { dict set known $m 1 }
    return $known
}

# objdump's listing -> assembly the simulator's parser accepts. Every
# instruction gets an address label so branch and jump targets, which objdump
# already prints as absolute addresses, resolve by name.
proc listing_to_sim {lines known text_end unknownVar} {
    upvar 1 $unknownVar unknown
    set out ".section .text\n"
    set first ""
    foreach line $lines {
        if {![regexp {^\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(\S+)\s*(.*)$} $line -> addr mnem ops]} {
            continue
        }
        set a [expr {"0x$addr" & 0xFFFFFFFF}]
        # objdump decodes the whole image, .rodata and .data included, where it
        # prints `.word` for anything that is not an instruction. Only .text is
        # code.
        if {$a >= $text_end} continue
        if {$first eq ""} { set first $a }
        # objdump spells `subu $d, $zero, $s` as negu. Put it back: it is an
        # instruction the simulator has, under the name the codegen uses.
        if {$mnem eq "negu"} {
            set mnem "subu"
            set ops [regsub {^(\w+),} $ops {\1,zero,}]
        }
        if {![dict exists $known $mnem]} { dict set unknown $mnem 1 }
        # An operand is a register name, a memory reference, an absolute
        # target, or a literal. Registers need the $ the simulator's parser
        # expects; targets become the label the address carries.
        set conv {}
        foreach tok [split [string trim [regsub {<.*$} $ops ""]] ,] {
            set tok [string trim $tok]
            if {$tok eq ""} continue
            if {[regexp {^(-?(?:0x)?[0-9a-fA-F]+)\((\w+)\)$} $tok -> off reg]} {
                lappend conv "[expr {$off}](\$$reg)"
            } elseif {[regexp {^0x8[0-9a-f]{7}$} $tok]} {
                lappend conv "L_[string range $tok 2 end]"
            } elseif {[regexp {^\$f\d+$} $tok]} {
                lappend conv $tok
            } elseif {[regexp {^\$\d+$} $tok]} {
                lappend conv $tok
            } elseif {[regexp {^[a-z][a-z0-9]*$} $tok] && [is_reg_name $tok]} {
                lappend conv "\$$tok"
            } else {
                lappend conv $tok
            }
        }
        append out "L_[format %08x $a]:\n"
        append out "    $mnem [join $conv ", "]\n"
    }
    return [list $out $first]
}

proc is_reg_name {n} {
    return [expr {$n in {zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7
                         s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp s8 ra}}]
}

proc disassemble {image base} {
    global OBJDUMP TMP
    set f [file join $TMP img.bin]
    set fh [open $f wb]; puts -nonewline $fh $image; close $fh
    set out [exec $OBJDUMP -D -b binary -m mips:4300 -EB \
                 --adjust-vma=[format 0x%08X $base] $f]
    return [split $out \n]
}

# ── running one linked image ─────────────────────────────────────────────────

# The MMIO a hardware wait loop polls. Without these the first
# `while (status & busy)` spins until the instruction budget runs out.
# VI_V_CURRENT alternates so vi_wait_vblank's two loops -- "wait until past the
# active region", then "wait for the new frame" -- each terminate. The
# simulator clamps a sequence at its last value, so it needs one pair per
# display.show the program makes, not just one pair in total.
set MMIO [dict create 0xA410000C 0 0xA4600010 0 0xA4800000 0 \
    0xA4400010 {0x1E0 0x000 0x1E0 0x000 0x1E0 0x000 0x1E0 0x000 0x1E0 0x000 0x1E0 0x000}]

proc execute {r poison_bss} {
    global MMIO OBJDUMP TMP POISON
    set image [dict get $r image]
    set base  $::pak::LINK_BASE_ADDR
    set lines [disassemble $image $base]
    set unknown [dict create]
    lassign [listing_to_sim $lines [sim_mnemonics] \
                 [expr {$base + [dict get $r section_sizes .text]}] unknown] simtext firstaddr
    set preset [dict create]
    for {set off 0} {$off + 4 <= [string length $image]} {incr off 4} {
        binary scan [string range $image $off [expr {$off+3}]] Iu w
        dict set preset [expr {$base + $off}] $w
    }
    if {$poison_bss} {
        set bb [dict get $r section_bases .bss]
        for {set off 0} {$off < [dict get $r section_sizes .bss]} {incr off 4} {
            dict set preset [expr {$bb + $off}] $POISON
        }
    }
    dict for {a v} $MMIO { dict set preset $a $v }
    set run [pak::mipsim::run $simtext L_[format %08x $base] 40000000 $preset "" $base]
    return [list $run $preset $unknown $firstaddr]
}

# ── scenario 1: the boot sequence itself ─────────────────────────────────────

# Small on purpose: what is proved here is that the boot sequence reaches main
# and that main's stores land, not what the program computes. `probe` is in
# .data and `bss_probe` in .bss, so the second also shows the zero-fill ran
# before main and not after.
set POISON 0xDEADBEEF

set SRC_BOOT {
static probe: u32 = 0
static bss_probe: u32 = 0

entry {
    probe = 0x1234ABCD
    bss_probe = probe
}
}

proc word_hex {mem addr} {
    set addr [expr {$addr}]
    if {![dict exists $mem $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mem $addr]]
}

puts "== boot.S: link, disassemble, execute from _start =="
set r [link_program boot $SRC_BOOT]
set base $::pak::LINK_BASE_ADDR
set syms [dict get $r symbols]
ok_true "linked an image" [expr {[string length [dict get $r image]] > 0}] \
    " ([string length [dict get $r image]] bytes, .text [dict get $r section_sizes .text])"
ok "_start is the link base" [format %08X [dict get $syms _start]] [format %08X $base]

lassign [execute $r 1] run preset unknown firstaddr
set mem  [dict get $run mem_w]
set regs [dict get $run regs]

ok "the first instruction is at the link base" [format %08X $firstaddr] [format %08X $base]
if {[dict size $unknown] > 0} {
    incr ::fail
    puts "FAIL  the simulator does not implement: [lsort [dict keys $unknown]]"
    puts "        Anything it does not implement is a silent no-op, so a test"
    puts "        that runs such an image is not running the program."
} else {
    incr ::pass
    puts "ok    every mnemonic in the image is one the simulator implements"
}
ok_true "the run ended rather than hitting the instruction budget" \
    [dict get $run halted] "  ([dict get $run insns] instructions)"

# boot.S set the stack pointer to the top of the map the linker reserves.
ok "boot.S set \$sp below the stack top" [format %08X [dict get $regs 29]] \
    [format %08X [expr {$::pak::MEM_STACK_TOP - 8}]]

# boot.S zero-filled .bss. Every poisoned word must be gone.
set bss_base [dict get $r section_bases .bss]
set bss_size [dict get $r section_sizes .bss]
set poisoned 0
for {set off 0} {$off < $bss_size} {incr off 4} {
    set a [expr {$bss_base + $off}]
    if {[dict exists $mem $a] && [dict get $mem $a] == $POISON} { incr poisoned }
}
ok ".bss has no poison left in it" $poisoned 0
ok_true ".bss was worth zeroing" [expr {$bss_size >= 4}] " ($bss_size bytes)"

# boot.S installed the exception trampoline at all four VR4300 vectors, through
# KSEG1. The stub is the two words at `exception_stub`.
set stub0 [dict get $preset [dict get $syms exception_stub]]
set stub1 [dict get $preset [expr {[dict get $syms exception_stub] + 4}]]
foreach v {0xA0000000 0xA0000080 0xA0000100 0xA0000180} {
    ok "vector [format %08X [expr {$v}]]" \
        "[word_hex $mem $v] [word_hex $mem [expr {$v + 4}]]" \
        "[format %08X $stub0] [format %08X $stub1]"
}

# main ran, and both sections took the store.
ok "main's store reached .data" [word_hex $mem [dict get $syms probe]] 1234ABCD
ok "main's store reached .bss"  [word_hex $mem [dict get $syms bss_probe]] 1234ABCD

# ── scenario 2: across the object boundary, into the runtime ─────────────────

# Every call here crosses from the program's object into runtime.pakobj, so it
# is R_MIPS_26 relocation being executed rather than inspected. The three
# framebuffer addresses are also the exact regression the delay-slot fix
# repaired: fb_addr returns them with `li $v0, 0xA0225800`, which is two words,
# and the optimizer used to put it in the delay slot of the `j` to the epilogue
# -- so the second and third came back as 0xA0200000 and 0xA0240000 with their
# low halves never written.
puts ""
puts "== the standalone runtime, executed as linked machine code =="

set SRC_RT {
static fb_a: u32 = 0
static fb_b: u32 = 0
static fb_c: u32 = 0

entry {
    display.init(0, 2, 3, 0, 1)
    fb_a = display.get()
    display.show(fb_a)
    fb_b = display.get()
    display.show(fb_b)
    fb_c = display.get()
}
}

set r2 [link_program runtime $SRC_RT]
set syms2 [dict get $r2 symbols]
lassign [execute $r2 0] run2 preset2 unknown2 first2
set mem2 [dict get $run2 mem_w]

ok_true "the run ended rather than hitting the instruction budget" \
    [dict get $run2 halted] "  ([dict get $run2 insns] instructions)"
# display.init(.., 3, ..) starts drawing into the buffer the VI is not showing,
# so the first get is FB1 and the sequence wraps to FB0 on the third.
ok "first display.get is FB1"  [word_hex $mem2 [dict get $syms2 fb_a]] A0225800
ok "second display.get is FB2" [word_hex $mem2 [dict get $syms2 fb_b]] A024B000
ok "third display.get wraps to FB0" [word_hex $mem2 [dict get $syms2 fb_c]] A0200000

# display.init programs the VI, and each display.show writes VI_ORIGIN with the
# physical address of the buffer it was handed.
ok "VI_ORIGIN is the last buffer shown" [word_hex $mem2 0xA4400004] 0024B000
ok "VI_WIDTH is 320" [word_hex $mem2 0xA4400008] 00000140
ok "VI_CTRL is 16bpp, pixel_advance 3, aa_mode 2" \
    [word_hex $mem2 0xA4400000] 00003202

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
