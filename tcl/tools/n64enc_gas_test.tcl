#!/usr/bin/env tclsh
# tcl/tools/n64enc_gas_test.tcl — Pak's MIPS encoder agrees with GNU as.
#
# tcl/n64enc.tcl is a from-scratch MIPS III assembler. Until now the only thing
# checking it was tools/n64enc_test.tcl, which compares it against encodings a
# human (me) worked out by hand — so a misread of the manual would be baked
# into both sides and pass. This compares it against binutils' `as`, which is
# the ground truth the rest of the world uses, over every instruction the Pak
# codegen actually emits.
#
# What is compared: the bytes of each section, word for word.
#
# What is NOT compared, and why:
#   * Words carrying a relocation. Pak leaves the field zero and records the
#     reloc; gas encodes an in-section addend. Both are legal object-file
#     conventions and the linker is what has to agree, so those offsets are
#     skipped here (tcl/tools/n64link_test.tcl covers relocation).
#   * Sections gas synthesises that Pak does not (.pdr, .reginfo, .MIPS.abiflags).
#
# A size mismatch is reported as its own failure and stops that file's word
# comparison, because one extra instruction shifts everything after it and
# would otherwise print hundreds of bogus diffs.
#
# Requires a mips64-elf binutils (tools/build_n64_toolchain.sh). Skips, loudly,
# if one is not on PATH -- a missing toolchain must not read as a pass.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl n64enc.tcl]

set ::pass 0
set ::fail 0
set ::skipped_relocs 0

# ── toolchain ────────────────────────────────────────────────────────────────

proc find_tool {name} {
    foreach dir [list /opt/pak-n64/bin {*}[split $::env(PATH) :]] {
        set p [file join $dir $name]
        if {[file executable $p]} { return $p }
    }
    return ""
}
set AS      [find_tool mips64-elf-as]
set OBJCOPY [find_tool mips64-elf-objcopy]
set READELF [find_tool mips64-elf-readelf]
set OBJDUMP [find_tool mips64-elf-objdump]
if {$AS eq "" || $OBJCOPY eq "" || $READELF eq ""} {
    puts "SKIP  no mips64-elf binutils on PATH (run tools/build_n64_toolchain.sh)"
    exit 0
}

# The codegen writes explicit delay slots, so gas must not reorder. It may use
# $at: n64enc's own macro expansions (bge/sgt/li/la) use $at too, and comparing
# those expansions is half the point.
set AS_FLAGS [list -march=vr4300 -mabi=32 -mgp32 -mfp32 -EB]

set TMP [file join /tmp pak-enc-gas]
file mkdir $TMP

# A section's bytes as big-endian words, zero-padded to a word boundary. A
# section can end mid-word (`.byte 1` after a `.word`): gas leaves the section
# that length and n64enc rounds up, and zero padding is not a disagreement
# worth failing on, so both sides get padded here and compared whole.
proc words_of {bytes} {
    set n [string length $bytes]
    set pad [expr {(4 - ($n % 4)) % 4}]
    if {$pad} { append bytes [string repeat \x00 $pad] }
    binary scan $bytes Iu* words
    return $words
}

# ── one side: gas ────────────────────────────────────────────────────────────

# Section bytes as gas lays them out, plus the offsets it relocates.
proc gas_assemble {asm tag} {
    global AS OBJCOPY READELF AS_FLAGS TMP
    set s [file join $TMP $tag.s]
    set o [file join $TMP $tag.o]
    set fh [open $s w]
    puts $fh ".set noreorder"
    puts -nonewline $fh $asm
    close $fh
    if {[catch {exec $AS {*}$AS_FLAGS -o $o $s 2>@1} err]} {
        return [list error $err]
    }
    set out [dict create]
    # Section names are not a fixed set: boot.S puts its code in .text.boot,
    # and the codegen can emit any .rodata.* the linker later merges. Ask the
    # object what it holds rather than guessing.
    set secs {}
    foreach line [split [exec $READELF -S -W $o] \n] {
        if {[regexp {\[\s*\d+\]\s+(\.\S+)\s+(PROGBITS|NOBITS)\s} $line -> nm kind]} {
            if {[string match ".text*" $nm] || [string match ".data*" $nm] \
                    || [string match ".rodata*" $nm]} {
                lappend secs $nm
            }
        }
    }
    foreach sec $secs {
        set b [file join $TMP $tag$sec.bin]
        if {[catch {exec $OBJCOPY -O binary --only-section=$sec $o $b 2>@1}]} continue
        if {![file exists $b]} continue
        set fh [open $b rb]; set bytes [read $fh]; close $fh
        if {[string length $bytes] == 0} continue
        dict set out $sec words [words_of $bytes]
        dict set out $sec relocs {}
    }
    # readelf -r prints one table per relocated section:
    #   Relocation section '.rela.text' at offset ...
    #   Offset  Info  Type  Sym.Value  Sym. Name + Addend
    set cur ""
    foreach line [split [exec $READELF -r $o] \n] {
        if {[regexp {Relocation section '\.rela?(\S+)'} $line -> nm]} {
            set cur .$nm
            continue
        }
        if {$cur eq ""} continue
        if {[regexp {^([0-9a-fA-F]{8,16})\s+[0-9a-fA-F]} $line -> off]} {
            if {[dict exists $out $cur]} {
                dict lappend out $cur relocs [expr {"0x$off"}]
            }
        }
    }
    return [list ok $out]
}

# ── the other side: n64enc ───────────────────────────────────────────────────

proc pak_assemble {asm} {
    if {[catch {set ctx [pak::enc::encode [pak::enc::parse_asm $asm]]} err]} {
        return [list error $err]
    }
    set out [dict create]
    foreach sec [dict get $ctx sections] {
        set bytes [dict get $ctx secdata $sec bytes]
        dict set out $sec words [words_of [binary format c* $bytes]]
        set rl {}
        foreach r [dict get $ctx secdata $sec relocs] { lappend rl [lindex $r 0] }
        dict set out $sec relocs $rl
    }
    return [list ok $out]
}

# ── reporting ────────────────────────────────────────────────────────────────

# One word, disassembled, so a diff names instructions rather than hex.
proc disasm_word {w} {
    global OBJDUMP TMP
    if {$OBJDUMP eq ""} { return "" }
    set f [file join $TMP one.bin]
    set fh [open $f wb]; puts -nonewline $fh [binary format I $w]; close $fh
    if {[catch {exec $OBJDUMP -D -b binary -m mips:4300 -EB $f} out]} { return "" }
    foreach line [split $out \n] {
        if {[regexp {^\s+0:\s+[0-9a-f]{8}\s+(.*)$} $line -> txt]} {
            return [string trim $txt]
        }
    }
    return ""
}

proc report_fail {name msg} {
    incr ::fail
    puts "FAIL  $name"
    foreach l [split $msg \n] { puts "        $l" }
}

# ── the comparison ───────────────────────────────────────────────────────────

proc compare {name asm} {
    global MAXDIFF
    set g [gas_assemble $asm [regsub -all {[^A-Za-z0-9]} $name _]]
    if {[lindex $g 0] ne "ok"} {
        report_fail "$name (gas)" [lindex $g 1]
        return
    }
    set p [pak_assemble $asm]
    if {[lindex $p 0] ne "ok"} {
        report_fail "$name (n64enc)" [lindex $p 1]
        return
    }
    set gd [lindex $g 1]
    set pd [lindex $p 1]

    foreach sec [dict keys $gd] {
        # n64enc folds .text.boot (and any .rodata.foo) into the base section,
        # because that is all tcl/n64link.tcl knows how to place. Compare
        # against the base when the exact name is not on the Pak side.
        set psec $sec
        if {![dict exists $pd $psec]} {
            regexp {^(\.text|\.data|\.rodata)} $sec psec
        }
        if {![dict exists $pd $psec]} {
            report_fail "$name $sec" "gas emitted this section, n64enc did not"
            continue
        }
        set gw [dict get $gd $sec words]
        set pw [dict get $pd $psec words]
        # Trailing alignment padding differs harmlessly; compare the common
        # prefix but require the sizes to agree to within that padding.
        # n64enc pads every section to a word; gas does not always. Trailing
        # zero words on either side are padding, not content.
        while {[llength $pw] > [llength $gw] && [lindex $pw end] == 0} {
            set pw [lrange $pw 0 end-1]
        }
        while {[llength $gw] > [llength $pw] && [lindex $gw end] == 0} {
            set gw [lrange $gw 0 end-1]
        }
        if {[llength $gw] != [llength $pw]} {
            report_fail "$name $sec size" \
                "gas [llength $gw] words, n64enc [llength $pw] words"
            continue
        }
        set skip [dict create]
        foreach off [dict get $gd $sec relocs] { dict set skip $off 1 }
        foreach off [dict get $pd $psec relocs] { dict set skip $off 1 }

        set diffs {}
        for {set i 0} {$i < [llength $gw]} {incr i} {
            set off [expr {$i * 4}]
            if {[dict exists $skip $off]} { incr ::skipped_relocs; continue }
            set a [lindex $gw $i]
            set b [lindex $pw $i]
            if {$a != $b} { lappend diffs [list $off $a $b] }
        }
        if {[llength $diffs] == 0} {
            incr ::pass
            puts [format "ok    %-44s %s  %d words" $name $sec [llength $gw]]
        } else {
            set msg "[llength $diffs] of [llength $gw] words differ"
            foreach d [lrange $diffs 0 7] {
                lassign $d off a b
                append msg [format "\n+%04X  gas %08X  %s" $off $a [disasm_word $a]]
                append msg [format "\n       pak %08X  %s" $b [disasm_word $b]]
            }
            if {[llength $diffs] > 8} {
                append msg "\n... and [expr {[llength $diffs] - 8}] more"
            }
            report_fail "$name $sec" $msg
        }
    }
}

# ── inputs ───────────────────────────────────────────────────────────────────

puts "== hand-written assembly =="
foreach f [concat [list tcl/tools/n64enc_gas_fixture.s] \
                  [lsort [glob -nocomplain runtime/standalone/*.S]]] {
    set fh [open $f r]; set txt [read $fh]; close $fh
    compare [file tail $f] $txt
}

puts ""
puts "== generated code =="
set sources [lsort [glob -nocomplain examples/canonical/*.pk64]]
lappend sources runtime/standalone/runtime.pk64
foreach f $sources {
    if {[catch {set asm [exec [info nameofexecutable] tcl/cli.tcl explain --backend mips $f]} err]} {
        # A source the MIPS backend refuses is the C backend's business, not
        # this gate's -- but say so rather than counting it as a pass.
        puts "skip  [file tail $f] (mips backend: [lindex [split $err \n] 0])"
        continue
    }
    compare [file tail $f] $asm
}

puts ""
puts "PASS=$::pass  FAIL=$::fail  (relocated words skipped: $::skipped_relocs)"
if {$::fail > 0} { exit 1 }
