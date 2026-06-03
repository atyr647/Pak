# tcl/n64enc.tcl — self-contained MIPS (VR4300 / MIPS III, big-endian) binary
# ENCODER. Consumes a stream of structured records (Contract A) and produces a
# relocatable text object file (Contract B). No MIPS toolchain required;
# validated against hand-computed golden encodings (see tools/n64enc_test.tcl).
#
# Public API:
#   pak::enc::encode {records}            -> internal dict (for testing)
#   pak::enc::write_object {records out}  -> writes Contract-B object text to file
#
# The internal dict returned by encode is:
#   sections   : ordered list of section names that received content
#   <sec>      : dict {bytes <bytelist> syms <name->off> relocs <list of {off kind sym}>
#                      size <bytes-emitted>}
#   globals    : list of names marked .globl
#   externs    : list of names marked .extern
#   symsizes   : dict name -> size-expr (from .size)
#
# NOTE on .bss / .space: for simplicity we emit literal zero bytes into the
# section's byte buffer (so .bss carries real zero data in the object). The
# linker is told sections are 4-byte padded zero-fill is fine. Documented.
#
# NOTE on trailing data shorter than 4 bytes: sections are always padded with
# zero bytes up to a 4-byte boundary, and only `data` word lines (8 hex chars,
# big-endian) are emitted. No `bytes` tail lines are produced.

namespace eval pak::enc {}
if {[info exists ::pak::_n64enc_loaded]} { return }
set ::pak::_n64enc_loaded 1

# ── Register numbers (GPR) ───────────────────────────────────────────────────
set ::pak::enc::GPR [dict create \
    {$zero} 0 {$at} 1 {$v0} 2 {$v1} 3 {$a0} 4 {$a1} 5 {$a2} 6 {$a3} 7 \
    {$t0} 8 {$t1} 9 {$t2} 10 {$t3} 11 {$t4} 12 {$t5} 13 {$t6} 14 {$t7} 15 \
    {$s0} 16 {$s1} 17 {$s2} 18 {$s3} 19 {$s4} 20 {$s5} 21 {$s6} 22 {$s7} 23 \
    {$t8} 24 {$t9} 25 {$k0} 26 {$k1} 27 {$gp} 28 {$sp} 29 {$fp} 30 {$s8} 30 {$ra} 31]

proc pak::enc::gpr {r} {
    set r [string trim $r ,]
    if {![dict exists $::pak::enc::GPR $r]} {
        error "n64enc: unknown GPR register '$r'"
    }
    return [dict get $::pak::enc::GPR $r]
}

# Coprocessor-1 register slot -> register NUMBER (0-31).
# Accepts an explicit FP name ($fN) or any GPR name. The MIPS codegen emits
# COP1 loads/stores (swc1/lwc1/...) with GPR-named tokens like `swc1 $a0`;
# gas resolves these to the register number (here $a0 -> 4 -> $f4), so the
# encoder mirrors that: a register name in an FP slot encodes its number.
proc pak::enc::fpr {r} {
    set r [string trim $r ,]
    if {[regexp {^\$f([0-9]+)$} $r -> n]} {
        if {$n < 0 || $n > 31} { error "n64enc: FP register out of range '$r'" }
        return $n
    }
    if {[dict exists $::pak::enc::GPR $r]} {
        return [dict get $::pak::enc::GPR $r]
    }
    error "n64enc: unknown FP register '$r'"
}

# Is a token a register?
proc pak::enc::is_reg {tok} {
    set t [string trim $tok ,]
    return [expr {[dict exists $::pak::enc::GPR $t] || [regexp {^\$f[0-9]+$} $t]}]
}

# ── Immediate parsing ────────────────────────────────────────────────────────
# Accepts decimal (possibly negative) and hex (0x...). Returns an integer.
proc pak::enc::imm {tok} {
    set t [string trim $tok ,]
    if {[regexp {^-?0[xX][0-9a-fA-F]+$} $t]} {
        return [expr {$t}]
    }
    if {[regexp {^-?[0-9]+$} $t]} {
        return [expr {$t}]
    }
    error "n64enc: not an immediate: '$tok'"
}

proc pak::enc::is_imm {tok} {
    set t [string trim $tok ,]
    return [regexp {^-?(0[xX][0-9a-fA-F]+|[0-9]+)$} $t]
}

# Memory operand "off($base)" -> {off baseregnum}
proc pak::enc::mem {tok} {
    set t [string trim $tok ,]
    if {![regexp {^(-?(?:0[xX][0-9a-fA-F]+|[0-9]+))?\(([^)]+)\)$} $t -> off base]} {
        error "n64enc: bad memory operand '$tok'"
    }
    if {$off eq ""} { set off 0 } else { set off [imm $off] }
    return [list $off [gpr $base]]
}

# ── Field encoders (return a 32-bit int) ─────────────────────────────────────
proc pak::enc::R {op rs rt rd shamt funct} {
    return [expr {(($op & 0x3f) << 26) | (($rs & 0x1f) << 21) | (($rt & 0x1f) << 16) \
        | (($rd & 0x1f) << 11) | (($shamt & 0x1f) << 6) | ($funct & 0x3f)}]
}
proc pak::enc::I {op rs rt imm} {
    return [expr {(($op & 0x3f) << 26) | (($rs & 0x1f) << 21) | (($rt & 0x1f) << 16) | ($imm & 0xffff)}]
}
proc pak::enc::J {op target} {
    return [expr {(($op & 0x3f) << 26) | (($target >> 2) & 0x3ffffff)}]
}

# ── R-type funct / I-type op tables ──────────────────────────────────────────
# Real SPECIAL (op=0) 3-register: rd,rs,rt  (funct)
set ::pak::enc::RFUNCT3 [dict create \
    addu 0x21 subu 0x23 and 0x24 or 0x25 xor 0x26 nor 0x27 slt 0x2a sltu 0x2b]
# Variable shifts: sllv $d,$t,$s  (rd=$d rt=$t rs=$s)
set ::pak::enc::RVSHIFT [dict create sllv 0x04 srlv 0x06 srav 0x07]
# Constant shifts: sll $d,$t,sa   (rd=$d rt=$t shamt=sa rs=0)
set ::pak::enc::RCSHIFT [dict create sll 0x00 srl 0x02 sra 0x03]
# Hi/Lo producing: mult/multu/div/divu  rs,rt
set ::pak::enc::RHILO [dict create mult 0x18 multu 0x19 div 0x1a divu 0x1b]
# Move-from hi/lo: rd only
set ::pak::enc::RMF [dict create mfhi 0x10 mflo 0x12]

# I-type op codes
set ::pak::enc::IARITH [dict create \
    addiu 0x09 andi 0x0c ori 0x0d xori 0x0e slti 0x0a sltiu 0x0b]
set ::pak::enc::IMEM [dict create \
    lw 0x23 sw 0x2b lh 0x21 lhu 0x25 lb 0x20 lbu 0x24 sh 0x29 sb 0x28 \
    lwc1 0x31 swc1 0x39 ldc1 0x35 sdc1 0x3d]

# ── Encoder context ──────────────────────────────────────────────────────────
# We process records in two passes:
#   Pass 1: lay out everything (expand pseudos, compute byte offsets, record
#           labels, record pending branch fixups & relocs). Branch fixups store
#           the word offset and target label; relocs store {off kind sym}.
#   Pass 2: resolve local branches now that all label offsets are known.

proc pak::enc::new_section {ctxVar name} {
    upvar 1 $ctxVar ctx
    if {![dict exists $ctx sections]} { dict set ctx sections {} }
    if {![dict exists $ctx secdata $name]} {
        dict lappend ctx sections $name
        dict set ctx secdata $name [dict create bytes {} syms {} relocs {} branches {}]
    }
}

proc pak::enc::cur_off {ctxVar} {
    upvar 1 $ctxVar ctx
    set sec [dict get $ctx cur]
    return [llength [dict get $ctx secdata $sec bytes]]
}

# Append a list of byte ints to current section.
proc pak::enc::emit_bytes {ctxVar bytelist} {
    upvar 1 $ctxVar ctx
    set sec [dict get $ctx cur]
    if {$sec eq ""} { error "n64enc: data/instruction emitted with no active section" }
    set cur [dict get $ctx secdata $sec bytes]
    foreach b $bytelist { lappend cur [expr {$b & 0xff}] }
    dict set ctx secdata $sec bytes $cur
}

# Append a 32-bit word big-endian.
proc pak::enc::emit_word {ctxVar w} {
    upvar 1 $ctxVar ctx
    set w [expr {$w & 0xffffffff}]
    emit_bytes ctx [list \
        [expr {($w >> 24) & 0xff}] \
        [expr {($w >> 16) & 0xff}] \
        [expr {($w >> 8) & 0xff}] \
        [expr {$w & 0xff}]]
}

proc pak::enc::add_reloc {ctxVar off kind sym} {
    upvar 1 $ctxVar ctx
    set sec [dict get $ctx cur]
    set rl [dict get $ctx secdata $sec relocs]
    lappend rl [list $off $kind $sym]
    dict set ctx secdata $sec relocs $rl
}

proc pak::enc::add_branch_fixup {ctxVar word_off label} {
    upvar 1 $ctxVar ctx
    set sec [dict get $ctx cur]
    set bl [dict get $ctx secdata $sec branches]
    lappend bl [list $word_off $label $sec]
    dict set ctx secdata $sec branches $bl
}

proc pak::enc::add_label {ctxVar name} {
    upvar 1 $ctxVar ctx
    set sec [dict get $ctx cur]
    if {$sec eq ""} { error "n64enc: label '$name' defined with no active section" }
    set syms [dict get $ctx secdata $sec syms]
    dict set syms $name [cur_off ctx]
    dict set ctx secdata $sec syms $syms
}

proc pak::enc::pad_to {ctxVar n} {
    upvar 1 $ctxVar ctx
    set sec [dict get $ctx cur]
    set len [llength [dict get $ctx secdata $sec bytes]]
    while {$len % $n != 0} { emit_bytes ctx {0}; incr len }
}

# ── Instruction emission (one real instruction -> one word) ──────────────────
# emit_real: encode a single REAL instruction record {mnem op...} into the
# current section. Pseudo-ops must be expanded before calling this.
proc pak::enc::emit_real {ctxVar mnem args} {
    upvar 1 $ctxVar ctx
    set ops $args

    # SPECIAL 3-register: rd,rs,rt
    if {[dict exists $::pak::enc::RFUNCT3 $mnem]} {
        lassign $ops d s t
        emit_word ctx [R 0 [gpr $s] [gpr $t] [gpr $d] 0 [dict get $::pak::enc::RFUNCT3 $mnem]]
        return
    }
    # Variable shift: sllv $d,$t,$s -> rd=$d rt=$t rs=$s
    if {[dict exists $::pak::enc::RVSHIFT $mnem]} {
        lassign $ops d t s
        emit_word ctx [R 0 [gpr $s] [gpr $t] [gpr $d] 0 [dict get $::pak::enc::RVSHIFT $mnem]]
        return
    }
    # Constant shift: sll $d,$t,sa -> rd=$d rt=$t shamt=sa rs=0
    if {[dict exists $::pak::enc::RCSHIFT $mnem]} {
        lassign $ops d t sa
        emit_word ctx [R 0 0 [gpr $t] [gpr $d] [imm $sa] [dict get $::pak::enc::RCSHIFT $mnem]]
        return
    }
    # mult/multu/div/divu: rs,rt
    if {[dict exists $::pak::enc::RHILO $mnem]} {
        lassign $ops s t
        emit_word ctx [R 0 [gpr $s] [gpr $t] 0 0 [dict get $::pak::enc::RHILO $mnem]]
        return
    }
    # mfhi/mflo: rd
    if {[dict exists $::pak::enc::RMF $mnem]} {
        lassign $ops d
        emit_word ctx [R 0 0 0 [gpr $d] 0 [dict get $::pak::enc::RMF $mnem]]
        return
    }
    switch -- $mnem {
        jr {
            lassign $ops s
            emit_word ctx [R 0 [gpr $s] 0 0 0 0x08]
            return
        }
        jalr {
            # jalr $link,$rs  (default link $ra)
            if {[llength $ops] == 1} {
                set link {$ra}; set s [lindex $ops 0]
            } else {
                lassign $ops link s
            }
            emit_word ctx [R 0 [gpr $s] 0 [gpr $link] 0 0x09]
            return
        }
        sync {
            emit_word ctx [R 0 0 0 0 0 0x0f]
            return
        }
    }
    # I-type arith: op $rt,$rs,imm
    if {[dict exists $::pak::enc::IARITH $mnem]} {
        lassign $ops t s im
        emit_word ctx [I [dict get $::pak::enc::IARITH $mnem] [gpr $s] [gpr $t] [imm $im]]
        return
    }
    if {$mnem eq "lui"} {
        lassign $ops t im
        emit_word ctx [I 0x0f 0 [gpr $t] [imm $im]]
        return
    }
    # I-type mem: op $rt, off($base)
    if {[dict exists $::pak::enc::IMEM $mnem]} {
        lassign $ops t m
        # FP loads/stores use FP reg for rt
        if {$mnem in {lwc1 swc1 ldc1 sdc1}} {
            set rt [fpr $t]
        } else {
            set rt [gpr $t]
        }
        lassign [mem $m] off base
        emit_word ctx [I [dict get $::pak::enc::IMEM $mnem] $base $rt $off]
        return
    }
    # Branches beq/bne $rs,$rt,label  (PC-relative, resolved at encode time)
    if {$mnem eq "beq" || $mnem eq "bne"} {
        lassign $ops s t label
        set op [expr {$mnem eq "beq" ? 0x04 : 0x05}]
        set woff [cur_off ctx]
        # placeholder, fixup later
        emit_word ctx [I $op [gpr $s] [gpr $t] 0]
        add_branch_fixup ctx $woff $label
        # stash op/rs/rt so fixup can re-encode (store alongside)
        set sec [dict get $ctx cur]
        dict set ctx secdata $sec brmeta $woff [list $op [gpr $s] [gpr $t]]
        return
    }
    # J-type
    if {$mnem eq "j" || $mnem eq "jal"} {
        lassign $ops target
        set op [expr {$mnem eq "j" ? 0x02 : 0x03}]
        set woff [cur_off ctx]
        emit_word ctx [J $op 0]
        add_reloc ctx $woff R_MIPS_26 $target
        return
    }
    # FPU: mtc1/mfc1
    if {$mnem eq "mtc1"} {
        # mtc1 $gpr,$fpr -> COP1 rs=0x04 rt=$gpr rd/fs=$fpr
        lassign $ops g f
        emit_word ctx [R 0x11 0x04 [gpr $g] [fpr $f] 0 0]
        return
    }
    if {$mnem eq "mfc1"} {
        # mfc1 $gpr,$fpr -> COP1 rs=0x00 rt=$gpr fs=$fpr
        lassign $ops g f
        emit_word ctx [R 0x11 0x00 [gpr $g] [fpr $f] 0 0]
        return
    }
    # COP1 fmt ALU: add.s/sub.s/mul.s/div.s  fd,fs,ft
    # Encoding: op=0x11 rs=fmt rt=ft rd=fs(->fs field) ... standard COP1 layout:
    #   [31:26]=0x11 [25:21]=fmt [20:16]=ft [15:11]=fs [10:6]=fd [5:0]=funct
    if {[regexp {^(add|sub|mul|div)\.(s|d)$} $mnem -> opn fmtc]} {
        lassign $ops fd fs ft
        set fmt [expr {$fmtc eq "s" ? 16 : 17}]
        set funct [dict get {add 0 sub 1 mul 2 div 3} $opn]
        emit_word ctx [R 0x11 $fmt [fpr $ft] [fpr $fs] [fpr $fd] $funct]
        return
    }
    # COP1 cvt: cvt.s.w / cvt.w.s / cvt.d.w / cvt.w.d  fd,fs
    # source format is the SECOND suffix; funct selects destination type.
    if {[regexp {^cvt\.(s|w|d)\.(s|w|d)$} $mnem -> dst src]} {
        lassign $ops fd fs
        set fmt [dict get {s 16 d 17 w 20} $src]
        set funct [dict get {s 0x20 d 0x21 w 0x24} $dst]
        emit_word ctx [R 0x11 $fmt 0 [fpr $fs] [fpr $fd] $funct]
        return
    }
    error "n64enc: unknown/unsupported instruction '$mnem $ops'"
}

# ── Pseudo expansion -> list of real instruction records ─────────────────────
# Returns a list of {mnem op...} real-instruction records.
proc pak::enc::expand {mnem ops} {
    switch -- $mnem {
        nop {
            return [list [list sll {$zero} {$zero} 0]]
        }
        move {
            # move $d,$s -> addu $d,$s,$zero  (rs=$s, rt=$zero).
            # Golden: move $t0,$t1 = 0x01204021 (rs=9,rt=0,rd=8), i.e. $s in rs.
            lassign $ops d s
            return [list [list addu $d $s {$zero}]]
        }
        li {
            lassign $ops d im
            set v [imm $im]
            if {$v >= -32768 && $v <= 32767} {
                return [list [list addiu $d {$zero} $v]]
            } elseif {$v >= 0 && $v <= 65535} {
                return [list [list ori $d {$zero} $v]]
            } else {
                set hi [expr {($v >> 16) & 0xffff}]
                set lo [expr {$v & 0xffff}]
                return [list [list lui $d $hi] [list ori $d $d $lo]]
            }
        }
        la {
            # handled specially in pass1 (needs reloc on each word)
            error "n64enc: la must be expanded inline (internal)"
        }
        beqz {
            lassign $ops r label
            return [list [list beq $r {$zero} $label]]
        }
        bnez {
            lassign $ops r label
            return [list [list bne $r {$zero} $label]]
        }
        bge {
            lassign $ops s1 s2 label
            return [list [list slt {$at} $s1 $s2] [list beq {$at} {$zero} $label]]
        }
        sle {
            lassign $ops d s1 s2
            return [list [list slt $d $s2 $s1] [list xori $d $d 1]]
        }
        sgt {
            lassign $ops d s1 s2
            return [list [list slt $d $s2 $s1]]
        }
        sge {
            lassign $ops d s1 s2
            return [list [list slt $d $s1 $s2] [list xori $d $d 1]]
        }
        seq {
            lassign $ops d s1 s2
            return [list [list subu $d $s1 $s2] [list sltiu $d $d 1]]
        }
        sne {
            lassign $ops d s1 s2
            return [list [list subu $d $s1 $s2] [list sltu $d {$zero} $d]]
        }
        mul {
            lassign $ops d s1 s2
            return [list [list mult $s1 $s2] [list mflo $d]]
        }
    }
    return ""  ;# not a pseudo
}

# Is this mnemonic a pseudo we expand here?
proc pak::enc::is_pseudo {mnem} {
    return [expr {$mnem in {nop move li la beqz bnez bge sle sgt sge seq sne mul}}]
}

# ── Data-directive value: number or label ────────────────────────────────────
# Returns {kind value}: kind="num" value=int, or kind="sym" value=name.
proc pak::enc::data_val {tok} {
    if {[is_imm $tok]} { return [list num [imm $tok]] }
    return [list sym $tok]
}

# ── Process one instruction record (expanding pseudos) ───────────────────────
proc pak::enc::do_instr {ctxVar mnem ops} {
    upvar 1 $ctxVar ctx
    set mnem [string trim $mnem ,]
    # `la` needs per-word relocs:
    if {$mnem eq "la"} {
        lassign $ops d label
        set w1 [cur_off ctx]
        emit_word ctx [I 0x0f 0 [gpr $d] 0]        ;# lui $d,%hi -> imm 0
        add_reloc ctx $w1 R_MIPS_HI16 $label
        set w2 [cur_off ctx]
        emit_word ctx [I 0x09 [gpr $d] [gpr $d] 0] ;# addiu $d,$d,%lo -> imm 0
        add_reloc ctx $w2 R_MIPS_LO16 $label
        return
    }
    if {[is_pseudo $mnem]} {
        foreach real [expand $mnem $ops] {
            set rm [lindex $real 0]
            set ro [lrange $real 1 end]
            emit_real ctx $rm {*}$ro
        }
        return
    }
    emit_real ctx $mnem {*}$ops
}

# ── Process a directive record ───────────────────────────────────────────────
proc pak::enc::do_directive {ctxVar args} {
    upvar 1 $ctxVar ctx
    set kind [lindex $args 0]
    set rest [lrange $args 1 end]
    switch -- $kind {
        section {
            set name [lindex $rest 0]
            new_section ctx $name
            dict set ctx cur $name
        }
        globl {
            dict lappend ctx globals [lindex $rest 0]
        }
        extern {
            dict lappend ctx externs [lindex $rest 0]
        }
        type {
            # {d type NAME @function} — recorded but no bytes
        }
        size {
            set name [lindex $rest 0]
            set expr [lrange $rest 1 end]
            dict set ctx symsizes $name $expr
        }
        align {
            set exp [lindex $rest 0]
            pad_to ctx [expr {1 << $exp}]
        }
        word {
            lassign [data_val [lindex $rest 0]] vk vv
            if {$vk eq "sym"} {
                set off [cur_off ctx]
                add_reloc ctx $off R_MIPS_32 $vv
                emit_word ctx 0
            } else {
                emit_word ctx $vv
            }
        }
        half {
            set v [imm [lindex $rest 0]]
            emit_bytes ctx [list [expr {($v >> 8) & 0xff}] [expr {$v & 0xff}]]
        }
        byte {
            set v [imm [lindex $rest 0]]
            emit_bytes ctx [list [expr {$v & 0xff}]]
        }
        space {
            set n [imm [lindex $rest 0]]
            for {set i 0} {$i < $n} {incr i} { emit_bytes ctx {0} }
        }
        asciiz {
            # rest is the raw (already-unescaped) string. Rejoin in case it
            # contained spaces split by Tcl list parsing of the record.
            set s [join $rest " "]
            set bytes {}
            foreach ch [split $s ""] {
                # Latin-1 / UTF-8 byte expansion
                set codes [encoding convertto utf-8 $ch]
                foreach b [split $codes ""] {
                    lappend bytes [scan $b %c]
                }
            }
            lappend bytes 0
            emit_bytes ctx $bytes
        }
        default {
            error "n64enc: unknown directive '.$kind'"
        }
    }
}

# ── verbatim: best-effort parse as instruction ───────────────────────────────
proc pak::enc::do_verbatim {ctxVar line} {
    upvar 1 $ctxVar ctx
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { return }
    # tokenize: mnemonic then operands separated by commas/space
    set parts [regexp -all -inline {[^ \t,]+} $line]
    if {[llength $parts] == 0} { return }
    set mnem [lindex $parts 0]
    set ops [lrange $parts 1 end]
    if {[catch {do_instr ctx $mnem $ops} err]} {
        error "n64enc: cannot parse verbatim line '$line': $err"
    }
}

# ── Branch fixups (pass 2) ───────────────────────────────────────────────────
proc pak::enc::resolve_branches {ctxVar} {
    upvar 1 $ctxVar ctx
    foreach sec [dict get $ctx sections] {
        if {![dict exists $ctx secdata $sec branches]} continue
        set bytes [dict get $ctx secdata $sec bytes]
        set syms [dict get $ctx secdata $sec syms]
        foreach fix [dict get $ctx secdata $sec branches] {
            lassign $fix woff label _s
            if {![dict exists $syms $label]} {
                error "n64enc: branch to '$label' which is not a local label in section '$sec' (branches cannot cross sections)"
            }
            set target [dict get $syms $label]
            set off [expr {($target - ($woff + 4)) >> 2}]
            lassign [dict get $ctx secdata $sec brmeta $woff] op rs rt
            set w [I $op $rs $rt $off]
            # patch the 4 bytes at woff
            lset bytes $woff       [expr {($w >> 24) & 0xff}]
            lset bytes [expr {$woff+1}] [expr {($w >> 16) & 0xff}]
            lset bytes [expr {$woff+2}] [expr {($w >> 8) & 0xff}]
            lset bytes [expr {$woff+3}] [expr {$w & 0xff}]
        }
        dict set ctx secdata $sec bytes $bytes
    }
}

# ── Main encode entry ────────────────────────────────────────────────────────
proc pak::enc::encode {records} {
    set ctx [dict create sections {} secdata {} cur "" globals {} externs {} symsizes {}]
    foreach rec $records {
        set tag [lindex $rec 0]
        switch -- $tag {
            i {
                set mnem [lindex $rec 1]
                set ops [lrange $rec 2 end]
                do_instr ctx $mnem $ops
            }
            label {
                add_label ctx [lindex $rec 1]
            }
            d {
                do_directive ctx {*}[lrange $rec 1 end]
            }
            verbatim {
                do_verbatim ctx [lindex $rec 1]
            }
            default {
                error "n64enc: unknown record tag '$tag' in record: $rec"
            }
        }
    }
    resolve_branches ctx
    # pad all sections to 4 bytes
    foreach sec [dict get $ctx sections] {
        dict set ctx cur $sec
        pad_to ctx 4
    }
    return $ctx
}

# ── Object-file writer (Contract B) ──────────────────────────────────────────
proc pak::enc::format_object {ctx} {
    set out "# pak object v1\n"
    foreach sec [dict get $ctx sections] {
        append out "section $sec\n"
        set syms [dict get $ctx secdata $sec syms]
        foreach name [dict keys $syms] {
            append out "sym $name [dict get $syms $name]\n"
        }
        foreach rl [dict get $ctx secdata $sec relocs] {
            lassign $rl off kind sym
            append out "reloc $off $kind $sym\n"
        }
        set bytes [dict get $ctx secdata $sec bytes]
        set n [llength $bytes]
        # emit word lines, up to 4 words per line
        set words {}
        for {set i 0} {$i < $n} {incr i 4} {
            set w 0
            for {set j 0} {$j < 4} {incr j} {
                set b [expr {($i+$j) < $n ? [lindex $bytes [expr {$i+$j}]] : 0}]
                set w [expr {($w << 8) | ($b & 0xff)}]
            }
            lappend words [format %08x $w]
        }
        for {set i 0} {$i < [llength $words]} {incr i 4} {
            set chunk [lrange $words $i [expr {$i+3}]]
            append out "data [join $chunk " "]\n"
        }
    }
    return $out
}

proc pak::enc::write_object {records outfile} {
    set ctx [encode $records]
    set txt [format_object $ctx]
    set fh [open $outfile w]
    puts -nonewline $fh $txt
    close $fh
    return $outfile
}

# Helper for tests: encode a single instruction in a fresh .text section and
# return the first 32-bit word as an integer.
proc pak::enc::word_of {rec} {
    set recs [list {d section .text} $rec]
    set ctx [encode $recs]
    set bytes [dict get $ctx secdata .text bytes]
    set w 0
    for {set j 0} {$j < 4} {incr j} {
        set w [expr {($w << 8) | ([lindex $bytes $j] & 0xff)}]
    }
    return $w
}
