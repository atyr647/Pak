# tcl/rsp_codegen.tcl — restricted scalar codegen for the RSP target. Step 1
# of docs/rsp-microcode-in-pak.md's suggested order: "No vectors at all.
# entry, statics in DMEM, while, integer math -- compiled to the RSP's
# scalar half, which is a MIPS I subset tcl/n64enc.tcl already assembles
# correctly."
#
# A microcode is a program, not a function (same note): there is no crt0, no
# stack, no calling convention to set up, no linker. `entry {}` compiles
# straight to the microcode's first instruction and ends in `break`; every
# `static` is a fixed DMEM offset computed HERE, at compile time, because a
# microcode never references a symbol outside itself -- unlike the CPU
# backend's statics, which are resolved later by n64link.tcl, these are
# baked into the instruction stream directly, the same way rsp_add.S's
# hand-written `lw $8, 0($0)` bakes in DMEM offset 0.
#
# This is deliberately narrow, matching the design note's refusal table.
# Rejected (as an immediate Tcl error, RSPUNPORTED\t..., mirroring
# pak::mips_unported) rather than silently miscompiled:
#   - anything at top level besides `static` and exactly one `entry`
#   - a `static` with an initializer (DMEM content comes from what the CPU
#     DMAs in before `sp.run()`, not from a Pak-level init)
#   - a scalar type other than bool/u8/i8/u16/i16/u32/i32, or an array of
#     one of those
#   - `*` `/` `%` (no multiply or divide on the RSP scalar unit), any float
#     type, any `Call` (no functions, no modules -- yet)
#   - running out of the ten scratch registers this v1 allocator uses (no
#     spilling; "correct and slow" per the design note, not optimized)
#
# One documented simplification, not a silent wrong answer: `<` `<=` `>`
# `>=` always compare UNSIGNED in this v1 (signed ordered comparison is not
# implemented yet). `==`/`!=` are exact either way. `&&`/`||` evaluate both
# sides always (no short-circuit) -- correct as long as evaluating a side
# has no effect that matters, which holds here since there is no divide (the
# usual reason short-circuiting is load-bearing) and no function calls.

namespace eval pak {}

proc pak::rsp_unported {what} { return -code error "RSPUNPORTED\t$what" }

# RSP DMEM: 4 KB, address 0 is valid (unlike RDRAM there is no reserved low
# page), addresses are absolute so every load/store uses $zero as its base.
set ::pak::RSP_DMEM_SIZE 4096

oo::class create pak::RspCodegen {
    variable em statics dmem_used scopes free_regs label_n

    constructor {} {
        set em [pak::Emitter new]
        set statics [dict create]
        set dmem_used 0
        set scopes {}
        # $t0-$t9: ten scratch registers. $zero/$at/$v0-$a3 are left alone
        # (a future step that adds calls or a real ABI will want them);
        # nothing here needs more than a handful at a time.
        set free_regs {{$t0} {$t1} {$t2} {$t3} {$t4} {$t5} {$t6} {$t7} {$t8} {$t9}}
        set label_n 0
    }

    method getrecords {} { return [$em getrecords] }

    # ── register pool: a plain stack, no spilling ─────────────────────────────
    method alloc_reg {} {
        if {[llength $free_regs] == 0} {
            pak::rsp_unported "expression too complex for the v1 RSP register allocator (out of scratch registers -- no spilling yet)"
        }
        set r [lindex $free_regs 0]
        set free_regs [lrange $free_regs 1 end]
        return $r
    }
    method free_reg {r} {
        if {$r eq {$zero}} return
        set free_regs [linsert $free_regs 0 $r]
    }

    # ── lexical scopes: name -> {reg is_signed} ───────────────────────────────
    method push_scope {} { lappend scopes [dict create] }
    method pop_scope {} {
        set top [lindex $scopes end]
        set scopes [lrange $scopes 0 end-1]
        dict for {_ v} $top { my free_reg [lindex $v 0] }
    }
    method declare_local {name reg is_signed} {
        set top [lindex $scopes end]
        dict set top $name [list $reg $is_signed]
        lset scopes end $top
    }
    # {kind ...} where kind is "local" ({local reg is_signed}) or "static"
    # ({static offset size is_array elem_size is_signed}), or "" if unknown.
    method resolve {name} {
        for {set i [expr {[llength $scopes] - 1}]} {$i >= 0} {incr i -1} {
            set s [lindex $scopes $i]
            if {[dict exists $s $name]} {
                lassign [dict get $s $name] reg is_signed
                return [list local $reg $is_signed]
            }
        }
        if {[dict exists $statics $name]} {
            return [list static {*}[dict get $statics $name]]
        }
        return ""
    }

    method new_label {tag} {
        incr label_n
        return ".L${tag}${label_n}"
    }

    # Unconditional intra-microcode jump. This is `beq $zero,$zero,label`,
    # not a real `j` -- n64enc.tcl's `j`/`jal` are J-type and encode an
    # ABSOLUTE address, which it cannot resolve itself (real MIPS `j` targets
    # a full linked address, so the encoder emits a placeholder and an
    # R_MIPS_26 relocation for a *linker* to patch; see n64link.tcl). A
    # microcode never runs through a linker -- it goes straight from this
    # codegen to raw bytes -- so that relocation would never be patched and
    # every backward jump would silently target word 0, forever. A branch is
    # PC-relative and n64enc.tcl resolves it locally, in the same pass that
    # already resolves every other label here; RSP IMEM is 4 KB, comfortably
    # inside a branch's +-128 KB reach, so there is no downside to preferring
    # it over `j` for anything this codegen emits.
    method emit_jump {lbl} {
        $em instr beq {$zero,} {$zero,} $lbl
        $em nop
    }

    # ── type layout: scalar width/signedness, or an array of one ──────────────
    # Returns {size align is_array elem_size elem_load elem_store is_signed}.
    # elem_load/elem_store are the mnemonic to use for one element (lw/lh/lhu/
    # lb/lbu and sw/sh/sb) -- unsigned loads for unsigned types, since a
    # zero-extending load is the only kind that matches "this is a u8", not a
    # style choice.
    method layout_scalar {name} {
        switch -- $name {
            bool - u8  { return [list 1 1 0] }
            i8         { return [list 1 1 1] }
            u16        { return [list 2 2 0] }
            i16        { return [list 2 2 1] }
            u32        { return [list 4 4 0] }
            i32        { return [list 4 4 1] }
            default    { pak::rsp_unported "type '$name' (RSP scalars are bool/u8/i8/u16/i16/u32/i32 -- no float, no i64/u64)" }
        }
    }
    method layout_type {typenode} {
        if {[pak::isnil $typenode]} { pak::rsp_unported "a static or local needs an explicit type on the RSP target" }
        switch -- [pak::kindof $typenode] {
            TypeName {
                lassign [my layout_scalar [pak::fval $typenode name]] size align is_signed
                return [dict create size $size align $align is_array 0 elem_size 0 is_signed $is_signed]
            }
            TypeArray {
                set inner [pak::nfield $typenode inner]
                if {[pak::kindof $inner] ne "TypeName"} {
                    pak::rsp_unported "array element type must be a plain scalar (got [pak::kindof $inner])"
                }
                lassign [my layout_scalar [pak::fval $inner name]] esize align is_signed
                set n [pak::fval [pak::nfield $typenode size] value]
                return [dict create size [expr {$esize * $n}] align $align is_array 1 elem_size $esize is_signed $is_signed]
            }
            default { pak::rsp_unported "type kind '[pak::kindof $typenode]' is not a scalar or scalar array" }
        }
    }
    method load_op {size is_signed} {
        switch -- $size {
            1 { return [expr {$is_signed ? "lb" : "lbu"}] }
            2 { return [expr {$is_signed ? "lh" : "lhu"}] }
            4 { return "lw" }
        }
    }
    method store_op {size} {
        switch -- $size { 1 { return "sb" } 2 { return "sh" } 4 { return "sw" } }
    }

    # ── top level ──────────────────────────────────────────────────────────────
    method generate {program} {
        set entry_decl ""
        set static_decls {}
        foreach decl [pak::items [pak::nfield $program decls]] {
            switch -- [pak::kindof $decl] {
                StaticDecl { lappend static_decls $decl }
                EntryBlock {
                    if {$entry_decl ne ""} { pak::rsp_unported "more than one `entry` block (a microcode is one program)" }
                    set entry_decl $decl
                }
                default {
                    pak::rsp_unported "top-level '[pak::kindof $decl]' -- the RSP target (step 1) only accepts `static` and one `entry`"
                }
            }
        }
        if {$entry_decl eq ""} { pak::rsp_unported "no `entry` block (a microcode needs exactly one)" }

        foreach decl $static_decls { my layout_static $decl }
        if {$dmem_used > $::pak::RSP_DMEM_SIZE} {
            pak::rsp_unported "statics use $dmem_used bytes of DMEM, which is only $::pak::RSP_DMEM_SIZE"
        }

        $em section_text
        $em globl entry
        $em label entry
        my push_scope
        my gen_block [pak::nfield $entry_decl body]
        my pop_scope
        $em instr break
        $em nop
        return [$em getrecords]
    }

    # A static's DMEM offset is assigned by a simple bump allocator, in
    # declaration order, rounded up to its alignment (`@aligned(N)` widens
    # it, same annotation and meaning as every other Pak backend). No
    # relocation is emitted anywhere -- callers of this codegen bake the
    # numeric offset directly into every load/store of the name, so the
    # CPU-side driver program must agree on this same layout (documented,
    # not yet automated -- see the shared-struct-module step in the design
    # note for where that's meant to come from).
    method layout_static {decl} {
        set name [pak::fval $decl name]
        if {![pak::isnil [pak::nfield $decl value]]} {
            pak::rsp_unported "static '$name' has an initializer -- RSP DMEM content comes from what the CPU DMAs in before sp.run(), not from a Pak-level init"
        }
        set layout [my layout_type [pak::nfield $decl type]]
        set align [pak::mips_ann_align [pak::mips_annlist $decl] [dict get $layout align]]
        set off [expr {($dmem_used + $align - 1) & ~($align - 1)}]
        dict set statics $name [list $off [dict get $layout size] [dict get $layout is_array] \
            [dict get $layout elem_size] [dict get $layout is_signed]]
        set dmem_used [expr {$off + [dict get $layout size]}]
    }

    # ── statements ─────────────────────────────────────────────────────────────
    method gen_block {block} {
        my push_scope
        foreach s [pak::items [pak::nfield $block stmts]] { my gen_stmt $s }
        my pop_scope
    }

    method gen_stmt {stmt} {
        switch -- [pak::kindof $stmt] {
            Block    { my gen_block $stmt }
            ExprStmt { my gen_stmt_expr [pak::nfield $stmt expr] }
            LetDecl  { my gen_let $stmt }
            IfStmt   { my gen_if $stmt }
            WhileStmt { my gen_while $stmt }
            LoopStmt  { my gen_loop $stmt }
            default  { pak::rsp_unported "statement kind '[pak::kindof $stmt]' is not supported in the RSP target yet" }
        }
    }

    # A top-level expression-statement: an Assign is lowered as a store, any
    # other expression is evaluated for effect and its result discarded (an
    # RSP microcode has nothing meaningful to discard a value INTO besides a
    # store, but a bare call-like expression could still exist once modules
    # arrive -- so this stays a real dispatch, not an Assign-only path).
    method gen_stmt_expr {e} {
        if {[pak::kindof $e] eq "Assign"} { my gen_assign $e; return }
        my free_reg [my gen_expr $e]
    }

    method gen_let {decl} {
        set name [pak::fval $decl name]
        set v [pak::nfield $decl value]
        if {[pak::isnil $v]} { pak::rsp_unported "let '$name' has no initializer (required in the RSP target v1 -- no uninitialized locals)" }
        set is_signed 0
        set t [pak::nfield $decl type]
        if {![pak::isnil $t] && [pak::kindof $t] eq "TypeName"} {
            lassign [my layout_scalar [pak::fval $t name]] _ _ is_signed
        }
        set reg [my gen_expr $v]
        my declare_local $name $reg $is_signed
    }

    # target must be an Ident (local or static scalar) or an IndexAccess into
    # a static array -- the only two things memory means on the RSP target.
    method gen_assign {node} {
        set op [pak::fval $node op]
        if {$op ne "="} { pak::rsp_unported "compound assignment '$op' is not supported yet -- write it as 'x = x $op...'" }
        set target [pak::nfield $node target]
        switch -- [pak::kindof $target] {
            Ident {
                set r [my resolve [pak::fval $target name]]
                if {$r eq ""} { pak::rsp_unported "assignment to undefined name '[pak::fval $target name]'" }
                lassign $r kind a b c d
                if {$kind eq "local"} {
                    set vreg [my gen_expr [pak::nfield $node value]]
                    $em move $a $vreg
                    my free_reg $vreg
                } else {
                    # static: a b c d = offset size is_array elem_size is_signed
                    if {$c} { pak::rsp_unported "'[pak::fval $target name]' is an array -- index it to assign an element" }
                    set vreg [my gen_expr [pak::nfield $node value]]
                    $em instr [my store_op $b] "$vreg," "${a}(\$zero)"
                    my free_reg $vreg
                }
            }
            IndexAccess {
                lassign [my gen_element_addr $target] areg elem_size is_signed store_op_
                set vreg [my gen_expr [pak::nfield $node value]]
                $em instr $store_op_ "$vreg," "0($areg)"
                my free_reg $vreg
                my free_reg $areg
            }
            default { pak::rsp_unported "assignment target kind '[pak::kindof $target]' is not supported" }
        }
    }

    # Computes the runtime byte address of `arr[i]` into a fresh register.
    # Returns {addr_reg elem_size is_signed store_op}. A constant index folds
    # to a single immediate; a variable index costs a shift-and-add, same as
    # any MIPS backend -- there is no addressing mode that takes a scaled
    # register operand.
    method gen_element_addr {node} {
        set obj [pak::nfield $node obj]
        if {[pak::kindof $obj] ne "Ident"} { pak::rsp_unported "only a plain array name can be indexed (got [pak::kindof $obj])" }
        set r [my resolve [pak::fval $obj name]]
        if {$r eq "" || [lindex $r 0] ne "static" || ![lindex $r 3]} {
            pak::rsp_unported "'[pak::fval $obj name]' is not a static array"
        }
        lassign $r _ base total_size is_array elem_size is_signed
        set idx [pak::nfield $node index]
        set areg [my alloc_reg]
        if {[pak::kindof $idx] eq "IntLit"} {
            $em instr addiu "$areg," {$zero,} [expr {$base + [pak::fval $idx value] * $elem_size}]
        } else {
            set ireg [my gen_expr $idx]
            if {$elem_size == 1} {
                $em instr addiu "$areg," "$ireg," $base
            } else {
                set shift [expr {$elem_size == 2 ? 1 : 2}]
                $em sll $areg $ireg $shift
                $em instr addiu "$areg," "$areg," $base
            }
            my free_reg $ireg
        }
        return [list $areg $elem_size $is_signed [my store_op $elem_size]]
    }

    method gen_if {node} {
        set has_else [expr {![pak::isnil [pak::nfield $node else_branch]] \
                             || [llength [pak::items [pak::nfield $node elif_branches]]] > 0}]
        set end_lbl [my new_label if_end]
        my gen_if_chain [pak::nfield $node condition] [pak::nfield $node then] \
            [pak::items [pak::nfield $node elif_branches]] [pak::nfield $node else_branch] $end_lbl
        $em label $end_lbl
    }
    method gen_if_chain {cond then elifs else_branch end_lbl} {
        set creg [my gen_expr $cond]
        set next_lbl [my new_label if_next]
        $em instr beqz "$creg," $next_lbl
        $em nop
        my free_reg $creg
        my gen_block $then
        if {[llength $elifs] > 0 || ![pak::isnil $else_branch]} {
            my emit_jump $end_lbl
        }
        $em label $next_lbl
        if {[llength $elifs] > 0} {
            lassign [pak::items [lindex $elifs 0]] ec eb
            my gen_if_chain $ec $eb [lrange $elifs 1 end] $else_branch $end_lbl
        } elseif {![pak::isnil $else_branch]} {
            my gen_block $else_branch
        }
    }

    method gen_while {node} {
        set start_lbl [my new_label while]
        set end_lbl [my new_label while_end]
        $em label $start_lbl
        set creg [my gen_expr [pak::nfield $node condition]]
        $em instr beqz "$creg," $end_lbl
        $em nop
        my free_reg $creg
        my gen_block [pak::nfield $node body]
        my emit_jump $start_lbl
        $em label $end_lbl
    }

    method gen_loop {node} {
        set start_lbl [my new_label loop]
        $em label $start_lbl
        my gen_block [pak::nfield $node body]
        my emit_jump $start_lbl
    }

    # ── expressions: every case returns a FRESH register the caller owns and
    # must free (an Ident read is copied out of its home register/memory
    # rather than handed back directly, so freeing an expression's result
    # never corrupts a live local) ────────────────────────────────────────────
    method gen_expr {node} {
        switch -- [pak::kindof $node] {
            IntLit { set r [my alloc_reg]; $em li $r [pak::fval $node value]; return $r }
            Ident   { return [my gen_ident [pak::fval $node name]] }
            BinaryOp { return [my gen_binop $node] }
            UnaryOp  { return [my gen_unop $node] }
            IndexAccess {
                lassign [my gen_element_addr $node] areg elem_size is_signed _
                $em instr [my load_op $elem_size $is_signed] "$areg," "0($areg)"
                return $areg
            }
            Cast { return [my gen_cast $node] }
            default { pak::rsp_unported "expression kind '[pak::kindof $node]' is not supported in the RSP target yet" }
        }
    }

    method gen_ident {name} {
        set r [my resolve $name]
        if {$r eq ""} { pak::rsp_unported "undefined name '$name'" }
        lassign $r kind a b c d
        if {$kind eq "local"} {
            set dst [my alloc_reg]
            $em move $dst $a
            return $dst
        }
        # static: a b c d = offset size is_array elem_size is_signed
        if {$c} { pak::rsp_unported "'$name' is an array -- index it to read an element" }
        set dst [my alloc_reg]
        $em instr [my load_op $b $d] "$dst," "${a}(\$zero)"
        return $dst
    }

    method gen_cast {node} {
        set src [my gen_expr [pak::nfield $node expr]]
        set t [pak::nfield $node type]
        if {[pak::kindof $t] ne "TypeName"} { pak::rsp_unported "cast to non-scalar type" }
        lassign [my layout_scalar [pak::fval $t name]] size align is_signed
        switch -- $size {
            1 { $em instr andi "$src," "$src," 0xFF
                if {$is_signed} { $em sll $src $src 24; $em sra $src $src 24 } }
            2 { $em instr andi "$src," "$src," 0xFFFF
                if {$is_signed} { $em sll $src $src 16; $em sra $src $src 16 } }
        }
        return $src
    }

    method gen_unop {node} {
        set op [pak::fval $node op]
        set r [my gen_expr [pak::nfield $node operand]]
        switch -- $op {
            "-" { $em instr subu "$r," {$zero,} $r }
            "!" { $em instr sltiu "$r," "$r," 1 }
            default { pak::rsp_unported "unary operator '$op'" }
        }
        return $r
    }

    method gen_binop {node} {
        set op [pak::fval $node op]
        if {$op in {* / %}} {
            pak::rsp_unported "operator '$op' -- the RSP scalar unit has no multiply or divide"
        }
        set l [my gen_expr [pak::nfield $node left]]
        set r [my gen_expr [pak::nfield $node right]]
        switch -- $op {
            "+"  { $em instr addu "$l," "$l," $r }
            "-"  { $em instr subu "$l," "$l," $r }
            "&"  { $em instr and "$l," "$l," $r }
            "|"  { $em instr or "$l," "$l," $r }
            "^"  { $em instr xor "$l," "$l," $r }
            "&&" { $em instr and "$l," "$l," $r }
            "||" { $em instr or "$l," "$l," $r }
            "<<" { $em sllv $l $l $r }
            ">>" { $em srlv $l $l $r }
            "==" { $em instr seq "$l," "$l," $r }
            "!=" { $em instr sne "$l," "$l," $r }
            "<"  { $em instr sltu "$l," "$l," $r }
            "<=" { $em instr sleu "$l," "$l," $r }
            ">"  { $em instr sgtu "$l," "$l," $r }
            ">=" { $em instr sgeu "$l," "$l," $r }
            default { pak::rsp_unported "binary operator '$op'" }
        }
        my free_reg $r
        return $l
    }
}

proc pak::rsp_generate_records {program} {
    set cg [pak::RspCodegen new]
    set recs [$cg generate $program]
    $cg destroy
    return $recs
}
