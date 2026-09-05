#!/usr/bin/env tclsh
# tcl/tools/n64link_gas_test.tcl — Pak's flat linker agrees with GNU ld.
#
# tcl/n64link.tcl places sections and applies relocations with no toolchain.
# tcl/tools/n64link_test.tcl checks that structurally -- a symbol lands where
# the layout rules say, a jump target has the right low 26 bits -- against
# expectations written by the same hand that wrote the linker. This links the
# same objects with mips64-elf-ld and compares the loaded image byte for byte.
#
# Relocation is what this really tests. Every R_MIPS_26, HI16, LO16 and 32 is
# resolved by the time the image exists, so a byte match means Pak computed the
# same addresses and packed them into the same instruction fields as ld.
#
# Compared:
#   * the bytes from the .text base to the end of .data
#   * the address of every global symbol both linkers define
#
# Not compared: .bss. n64enc puts literal zeros in the object where gas emits
# NOBITS, so it is absent from ld's binary by construction; its base and size
# are covered by the __bss_start / __bss_end symbol check instead.
#
# The ld script mirrors tcl/n64link.tcl's own layout constants -- base
# 0x80000400, order .text .rodata .data .bss, and the per-section alignment in
# LINK_SECTION_ALIGN. It is generated from them, so a change to the layout
# cannot leave the two descriptions disagreeing in silence.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl optimize.tcl]
source [file join $REPO tcl n64enc.tcl]
source [file join $REPO tcl n64link.tcl]

set ::pass 0
set ::fail 0

proc find_tool {name} {
    foreach dir [list /opt/pak-n64/bin {*}[split $::env(PATH) :]] {
        set p [file join $dir $name]
        if {[file executable $p]} { return $p }
    }
    return ""
}
set AS      [find_tool mips64-elf-as]
set LD      [find_tool mips64-elf-ld]
set OBJCOPY [find_tool mips64-elf-objcopy]
set NM      [find_tool mips64-elf-nm]
foreach t {AS LD OBJCOPY NM} {
    if {[set $t] eq ""} {
        puts "SKIP  no mips64-elf binutils on PATH (run tools/build_n64_toolchain.sh)"
        exit 0
    }
}
set AS_FLAGS [list -march=vr4300 -mabi=32 -mgp32 -mfp32 -EB]

set TMP /tmp/pak-link-gas
file delete -force $TMP
file mkdir $TMP

proc ok {name got want} {
    if {$got eq $want} { incr ::pass; puts "ok    $name" } \
    else { incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want" }
}
proc fail {name msg} {
    incr ::fail
    puts "FAIL  $name"
    foreach l [split $msg \n] { puts "        $l" }
}

# ── the ld script, written from the linker's own constants ───────────────────

proc ld_script {} {
    set out "ENTRY(_start)\nSECTIONS {\n"
    append out "  . = [format 0x%08X $::pak::LINK_BASE_ADDR];\n"
    foreach sec $::pak::LINK_SECTION_ORDER {
        set a [dict get $::pak::LINK_SECTION_ALIGN $sec]
        if {$a > 1} { append out "  . = ALIGN($a);\n" }
        if {$sec eq ".bss"} {
            # The symbols go INSIDE the output section. Outside, they would be
            # taken before ld applies the section's own alignment -- a .bss
            # holding an @aligned(16) DMA pad starts 8 bytes further on than
            # `. = ALIGN(8)` leaves the dot, and boot.S would zero-fill from
            # 8 bytes inside .data. tcl/n64link.tcl aligns the base first and
            # then defines the symbol, which is the behaviour worth matching.
            append out "  $sec : { __bss_start = .; _fbss = .;\n"
            append out "           *($sec $sec.* COMMON)\n"
            append out "           __bss_end = .; _end = .; }\n"
        } else {
            append out "  $sec : { *($sec $sec.*) }\n"
        }
    }
    # gas synthesises these; Pak objects have no equivalent, and they would
    # otherwise land inside the image and shift everything after them.
    append out "  /DISCARD/ : { *(.pdr) *(.reginfo) *(.MIPS.abiflags) *(.comment) *(.gnu.attributes) }\n"
    append out "}\n"
    return $out
}

# ── assembly text for each translation unit of a standalone link ─────────────

proc asm_for_pak {path} {
    set fh [open $path r]; fconfigure $fh -encoding utf-8
    set src [read $fh]; close $fh
    set lx [pak::Lexer new $src]
    set ast [pak::parse_tokens [$lx tokenize]]
    return [pak::records_to_asm [pak::optimize_records [pak::mips_generate_records $ast]]]
}
proc asm_for_file {path} {
    set fh [open $path r]; set t [read $fh]; close $fh
    return $t
}

# ── the comparison ───────────────────────────────────────────────────────────

proc compare {name units} {
    global AS LD OBJCOPY NM AS_FLAGS TMP
    set dir [file join $TMP [regsub -all {[^A-Za-z0-9]} $name _]]
    file mkdir $dir

    # Pak: assemble each unit with n64enc, then link.
    set objs {}
    set i 0
    foreach u $units {
        lassign $u tag asm
        set o [file join $dir "$i-$tag.pakobj"]
        if {[catch {pak::enc::write_object_from_asm $asm $o} err]} {
            fail "$name (n64enc $tag)" $err
            return
        }
        lappend objs $o
        incr i
    }
    if {[catch {set r [pak::link_objects $objs _start]} err]} {
        fail "$name (n64link)" $err
        return
    }

    # GNU: assemble each unit with as, then link with the mirrored script.
    set gobjs {}
    set i 0
    foreach u $units {
        lassign $u tag asm
        set s [file join $dir "$i-$tag.s"]
        set o [file join $dir "$i-$tag.o"]
        set fh [open $s w]; puts $fh ".set noreorder"; puts -nonewline $fh $asm; close $fh
        if {[catch {exec $AS {*}$AS_FLAGS -o $o $s 2>@1} err]} {
            fail "$name (gas $tag)" $err
            return
        }
        lappend gobjs $o
        incr i
    }
    set lds [file join $dir link.ld]
    set fh [open $lds w]; puts -nonewline $fh [ld_script]; close $fh
    set elf [file join $dir out.elf]
    if {[catch {exec $LD -T $lds -o $elf {*}$gobjs 2>@1} err]} {
        fail "$name (ld)" $err
        return
    }
    set bin [file join $dir out.bin]
    exec $OBJCOPY -O binary $elf $bin

    # ── bytes ────────────────────────────────────────────────────────────────
    set fh [open $bin rb]; set gbytes [read $fh]; close $fh
    set pbytes [dict get $r image]
    # The Pak image runs to the end of .bss (literal zeros); ld's binary stops
    # at the end of .data. Compare the common prefix and require the remainder
    # to be the zeros .bss is.
    set gn [string length $gbytes]
    set pn [string length $pbytes]
    if {$gn > $pn} {
        fail "$name image size" "ld produced $gn bytes, n64link $pn"
        return
    }
    set tail [string range $pbytes $gn end]
    if {[string trim $tail "\x00"] ne ""} {
        fail "$name image tail" \
            "n64link's [expr {$pn - $gn}] bytes past ld's image are not all zero"
        return
    }
    # ld's image can end mid-word (a .data whose last object is a byte); pad it
    # out so the word-at-a-time comparison below has whole words to read. The
    # bytes it gains are the inter-section padding Pak already has there.
    set gn [expr {(($gn + 3) / 4) * 4}]
    while {[string length $gbytes] < $gn} { append gbytes "\x00" }
    set diffs {}
    for {set off 0} {$off < $gn} {incr off 4} {
        set a [string range $gbytes $off [expr {$off+3}]]
        set b [string range $pbytes $off [expr {$off+3}]]
        if {$a ne $b} {
            binary scan $a Iu aw; binary scan $b Iu bw
            lappend diffs [list [expr {$::pak::LINK_BASE_ADDR + $off}] $aw $bw]
        }
    }
    if {[llength $diffs] == 0} {
        incr ::pass
        puts [format "ok    %-34s image  %d bytes" $name $gn]
    } else {
        set msg "[llength $diffs] of [expr {$gn/4}] words differ"
        foreach d [lrange $diffs 0 7] {
            lassign $d va aw bw
            append msg [format "\n%08X  ld %08X  pak %08X" $va $aw $bw]
        }
        if {[llength $diffs] > 8} { append msg "\n... and [expr {[llength $diffs]-8}] more" }
        fail "$name image" $msg
    }

    # ── symbol addresses ─────────────────────────────────────────────────────
    set gsyms [dict create]
    foreach line [split [exec $NM $elf] \n] {
        if {[regexp {^([0-9a-fA-F]+)\s+(\S)\s+(\S+)$} $line -> addr type nm]} {
            if {$type in {t T d D r R b B a A}} {
                dict set gsyms $nm [expr {"0x$addr"}]
            }
        }
    }
    set psyms [dict get $r symbols]
    set bad {}
    set checked 0
    dict for {nm addr} $psyms {
        if {![dict exists $gsyms $nm]} continue
        incr checked
        if {[dict get $gsyms $nm] != $addr} {
            lappend bad [format "%s: ld %08X, pak %08X" $nm [dict get $gsyms $nm] $addr]
        }
    }
    if {[llength $bad] == 0} {
        incr ::pass
        puts [format "ok    %-34s syms   %d symbols" $name $checked]
    } else {
        fail "$name symbols" [join [lrange $bad 0 9] \n]
    }
}

# ── inputs: every standalone link the CLI can build ──────────────────────────

set BOOT [asm_for_file runtime/standalone/boot.S]
set RT   [asm_for_pak  runtime/standalone/runtime.pk64]

# boot.S calls main, so there is no link without a program: every case below
# is the real three-object link the CLI builds.
puts "== boot.S + runtime.pk64 + each standalone example =="
foreach f [lsort [glob examples/canonical/*.pk64]] {
    if {[catch {exec [info nameofexecutable] tcl/cli.tcl check $f --backend mips} ]} {
        continue
    }
    if {[catch {set asm [asm_for_pak $f]} err]} {
        puts "skip  [file tail $f] ([lindex [split $err \n] 0])"
        continue
    }
    compare [file tail $f] \
        [list [list boot $BOOT] [list runtime $RT] [list game $asm]]
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
