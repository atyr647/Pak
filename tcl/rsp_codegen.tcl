# tcl/rsp_codegen.tcl — restricted codegen for the RSP target. Steps 1-3 of
# docs/rsp-microcode-in-pak.md's suggested order (scalar-only, vec8x16 +
# elementwise ops, rsp.vacc) plus the struct/array-of-vec8x16 machinery step
# 4's worked vertex-transform example needs: step 1 is "No vectors at all.
# entry, statics in DMEM, while, integer math -- compiled to the RSP's scalar
# half, which is a MIPS I subset tcl/n64enc.tcl already assembles correctly";
# step 2 is "vec8x16 and the elementwise operators"; step 3 is "vacc."
#
# A microcode is a program, not a function (same note): there is no crt0, no
# stack, no calling convention to set up, no linker. `entry {}` compiles
# straight to the microcode's first instruction and ends in `break`; every
# `static` is a fixed DMEM offset computed HERE, at compile time, because a
# microcode never references a symbol outside itself -- unlike the CPU
# backend's statics, which are resolved later by n64link.tcl, these are
# baked into the instruction stream directly, the same way rsp_add.S's
# hand-written `lw $8, 0($0)` bakes in DMEM offset 0. A `struct` (the design
# note's `VtxJob`) is the same idea one level down: a named sub-region of
# whatever static uses it, laid out by the same bump allocator, with no ABI
# padding rules to match some other compiler -- see register_struct.
#
# This is deliberately narrow, matching the design note's refusal table.
# Rejected (as an immediate Tcl error, RSPUNPORTED\t..., mirroring
# pak::mips_unported) rather than silently miscompiled:
#   - anything at top level besides `use`, `struct`, `static`, and exactly
#     one `entry`
#   - a `static` with an initializer (DMEM content comes from what the CPU
#     DMAs in before `sp.run()`, not from a Pak-level init), or a struct
#     field with a default value (same reason)
#   - a scalar type other than bool/u8/i8/u16/i16/u32/i32, or an array of
#     one of those
#   - `*` `/` `%` (no multiply or divide on the RSP scalar unit), any float
#     type, any `Call` besides `.broadcast(n)` on a vec8x16 (no functions,
#     no modules -- yet)
#   - `<<`/`>>` on a vec8x16 (no vector shift instruction on real hardware),
#     a non-literal vec8x16 lane index
#   - field access more than one level deep (`job.foo` is fine; `job.foo.bar`
#     is not -- no worked example needs it, and a struct field whose type is
#     itself a struct must already be a REGISTERED struct, i.e. declared
#     earlier in the same file: this is one file's worth of forward
#     declarations, not real cross-file `module` resolution, which is
#     project/CLI wiring task #45 still has open)
#   - running out of the ten scratch GPRs or 32 vector registers this v1
#     allocator uses (no spilling; "correct and slow" per the design note,
#     not optimized)
#
# One documented simplification, not a silent wrong answer: `<` `<=` `>`
# `>=` always compare UNSIGNED in this v1 (signed ordered comparison is not
# implemented yet). `==`/`!=` are exact either way. `&&`/`||` evaluate both
# sides always (no short-circuit) -- correct as long as evaluating a side
# has no effect that matters, which holds here since there is no divide (the
# usual reason short-circuiting is load-bearing) and no function calls.
#
# vec8x16 (step 2): a value type, 8 lanes of 16 bits, exactly the design
# note's shape -- statics/locals of it, arrays of it (`[64]vec8x16`, the
# design note's own vertex-batch shape -- LQV/SQV addressed the same way a
# scalar array is, just scaled by 16 instead of 1/2/4), `+ - & | ^` (VADD/
# VSUB/VAND/VOR/VXOR), `.broadcast(n)` with a literal lane (fused into the
# very next vector instruction's element-select field when it is that
# instruction's right operand -- no extra instruction -- or materialized as
# a real value otherwise), and lane read/write (`v[i]` / `v[i] = x`, MFC2/
# MTC2, literal index only -- "the encoding has a field for it, not a
# register"). `<<`/`>>` are refused, correcting the design note's own
# aspirational example: real RSP hardware has no vector shift instruction
# (checked against armips' opcode table, not memory) -- a vector shift needs
# a VMUDL/VMUDH-style multiply trick, not implemented yet.

namespace eval pak {}

# `node`, when given, is whatever AST node this refusal is about -- every
# node the parser builds carries its own source position out of band (see
# ast.tcl's "source positions" section), so passing it through costs the
# caller nothing and turns a bare message into a real file:line:col
# diagnostic. The tagged RSPUNPORTED\t<line>\t<col>\t<message> string
# (mirroring LEXERROR/PARSEERROR's own \t-delimited convention -- see
# cli.tcl's pak::_errmsg) is unwound as a plain Tcl error rather than
# collected like checker.tcl's E0xx diagnostics because RSP codegen has no
# collection pass yet: it stops at the first refusal, the same way it
# always has. cli.tcl's cmd_build_rsp/cmd_explain and
# cli_run_full_check's rsp branch are what turn this into an E701
# diagnostic printed the same way every other Pak error is.
proc pak::rsp_unported {what {node ""}} {
    set line 0; set col 0
    if {$node ne ""} { lassign [pak::nodepos $node] line col }
    return -code error "RSPUNPORTED\t$line\t$col\t$what"
}

# RSP DMEM: 4 KB, address 0 is valid (unlike RDRAM there is no reserved low
# page), addresses are absolute so every load/store uses $zero as its base.
set ::pak::RSP_DMEM_SIZE 4096

oo::class create pak::RspCodegen {
    variable em statics structs dmem_used scopes free_regs vfree_regs label_n vacc_started

    constructor {} {
        set em [pak::Emitter new]
        set statics [dict create]
        # name -> {size align fields}; fields is name -> {offset layout}. A
        # struct field whose type is itself a struct must name one already
        # registered (single forward pass, source order) -- no need for
        # anything cleverer since the design note's own example (VtxJob)
        # never nests structs.
        set structs [dict create]
        set dmem_used 0
        set scopes {}
        # $t0-$t9: ten scratch GPRs. $zero/$at/$v0-$a3 are left alone (a
        # future step that adds calls or a real ABI will want them); nothing
        # here needs more than a handful at a time.
        set free_regs {{$t0} {$t1} {$t2} {$t3} {$t4} {$t5} {$t6} {$t7} {$t8} {$t9}}
        # $v0-$v31: the whole vector register file. There is no ABI yet to
        # reserve any of them, and $v0/$v1's textual collision with the GPR
        # ABI names of the same spelling (see n64enc.tcl's own comment on
        # this) never bites here, because every vector-register token this
        # codegen emits always carries an explicit element bracket -- see
        # vreg_tok -- which is exactly what keeps the encoder (and the text
        # simulator, for anyone hand-checking output against it) from ever
        # routing "$v0"/"$v1" through the GPR table instead.
        set vfree_regs {}
        for {set i 0} {$i < 32} {incr i} { lappend vfree_regs "\$v$i" }
        set label_n 0
        # rsp.vacc's checker rule: has SOME vacc.mul run before this point in
        # program order? Set by gen_vacc_call on "mul", required by "mac"
        # and by "high"/"mid"/"low". This is a lexical/program-order check
        # (matches the E201-style call-order rules elsewhere in Pak, e.g.
        # cache.writeback before dma.read), not a full dataflow proof -- a
        # `vacc.mul` reachable only through an untaken branch would still
        # satisfy it. Sound enough for the shape every real transform
        # microcode actually has (mul once, mac the rest, read once), and
        # honest about not being more than that.
        set vacc_started 0
    }

    method getrecords {} { return [$em getrecords] }

    # A vector-register operand, always with an explicit element bracket
    # (default element 0) -- see the constructor's comment on why that
    # matters. `e` may be a raw field value 0-15 (see n64enc.tcl's own
    # convention: this is the literal hardware field, not a named broadcast
    # form).
    method vreg_tok {reg {e 0}} { return "${reg}\[$e\]" }

    # ── register pools: two plain stacks, no spilling ─────────────────────────
    method alloc_reg {} {
        if {[llength $free_regs] == 0} {
            pak::rsp_unported "expression too complex for the v1 RSP register allocator (out of scratch GPRs -- no spilling yet)"
        }
        set r [lindex $free_regs 0]
        set free_regs [lrange $free_regs 1 end]
        return $r
    }
    method free_reg {r} {
        if {$r eq {$zero}} return
        set free_regs [linsert $free_regs 0 $r]
    }
    method valloc_reg {} {
        if {[llength $vfree_regs] == 0} {
            pak::rsp_unported "expression too complex for the v1 RSP register allocator (out of vector registers -- no spilling yet)"
        }
        set r [lindex $vfree_regs 0]
        set vfree_regs [lrange $vfree_regs 1 end]
        return $r
    }
    method vfree_reg {r} { set vfree_regs [linsert $vfree_regs 0 $r] }
    # Frees a {reg is_vector} pair from whichever pool it came from.
    method free_val {reg is_vector} {
        if {$is_vector} { my vfree_reg $reg } else { my free_reg $reg }
    }
    # A whole-register vector copy: there is no plain "vmove" -- VOR of a
    # register with itself (element 0, i.e. no broadcast) is the idiom real
    # microcode uses to materialize a copy.
    method vec_move {dst src} {
        $em instr vor "$dst," [my vreg_tok $src] [my vreg_tok $src]
    }

    # ── lexical scopes: name -> {reg is_signed is_vector} ─────────────────────
    method push_scope {} { lappend scopes [dict create] }
    method pop_scope {} {
        set top [lindex $scopes end]
        set scopes [lrange $scopes 0 end-1]
        dict for {_ v} $top { lassign $v reg _ isvec; my free_val $reg $isvec }
    }
    method declare_local {name reg is_signed is_vector} {
        set top [lindex $scopes end]
        dict set top $name [list $reg $is_signed $is_vector]
        lset scopes end $top
    }
    # {kind ...} where kind is "local" ({local reg is_signed is_vector}) or
    # "static" ({static offset size is_array elem_size is_signed is_vector}),
    # or "" if unknown.
    method resolve {name} {
        for {set i [expr {[llength $scopes] - 1}]} {$i >= 0} {incr i -1} {
            set s [lindex $scopes $i]
            if {[dict exists $s $name]} {
                lassign [dict get $s $name] reg is_signed is_vector
                return [list local $reg $is_signed $is_vector]
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
    method layout_scalar {name {node ""}} {
        switch -- $name {
            bool - u8  { return [list 1 1 0] }
            i8         { return [list 1 1 1] }
            u16        { return [list 2 2 0] }
            i16        { return [list 2 2 1] }
            u32        { return [list 4 4 0] }
            i32        { return [list 4 4 1] }
            default    { pak::rsp_unported "type '$name' (RSP scalars are bool/u8/i8/u16/i16/u32/i32 -- no float, no i64/u64)" $node }
        }
    }
    # Layout dicts always carry the same 8 keys (size align is_array
    # elem_size is_signed is_vector is_struct struct_name) regardless of
    # branch, so every caller can destructure uniformly instead of
    # special-casing which type shape it got. `is_vector` does double duty,
    # deliberately: when is_array is 0 it means "this IS one vec8x16
    # register value"; when is_array is 1 it means "each ELEMENT is a
    # vec8x16" (elem_size 16, which no scalar type ever uses, so the two
    # never collide). That reuse is why arrays of vec8x16 needed no new
    # field to stop being refused -- every caller that already branched on
    # is_array before looking at is_vector (gen_assign, gen_ident) already
    # had the right shape.
    method layout_type {typenode} {
        if {[pak::isnil $typenode]} { pak::rsp_unported "a static or local needs an explicit type on the RSP target" }
        switch -- [pak::kindof $typenode] {
            TypeName {
                set tname [pak::fval $typenode name]
                if {$tname eq "vec8x16"} {
                    return [dict create size 16 align 16 is_array 0 elem_size 0 is_signed 0 is_vector 1 is_struct 0 struct_name ""]
                }
                if {[dict exists $structs $tname]} {
                    set sdef [dict get $structs $tname]
                    return [dict create size [dict get $sdef size] align [dict get $sdef align] \
                        is_array 0 elem_size 0 is_signed 0 is_vector 0 is_struct 1 struct_name $tname]
                }
                lassign [my layout_scalar $tname $typenode] size align is_signed
                return [dict create size $size align $align is_array 0 elem_size 0 is_signed $is_signed is_vector 0 is_struct 0 struct_name ""]
            }
            TypeArray {
                set inner [pak::nfield $typenode inner]
                if {[pak::kindof $inner] ne "TypeName"} {
                    pak::rsp_unported "array element type must be a plain scalar or vec8x16 (got [pak::kindof $inner])" $inner
                }
                set n [pak::fval [pak::nfield $typenode size] value]
                if {[pak::fval $inner name] eq "vec8x16"} {
                    return [dict create size [expr {16 * $n}] align 16 is_array 1 elem_size 16 is_signed 0 is_vector 1 is_struct 0 struct_name ""]
                }
                lassign [my layout_scalar [pak::fval $inner name] $inner] esize align is_signed
                return [dict create size [expr {$esize * $n}] align $align is_array 1 elem_size $esize is_signed $is_signed is_vector 0 is_struct 0 struct_name ""]
            }
            default { pak::rsp_unported "type kind '[pak::kindof $typenode]' is not a scalar, scalar array, vec8x16, vec8x16 array, or a declared struct" $typenode }
        }
    }

    # Struct layout: fields laid out in declaration order, each rounded up
    # to its own alignment, exactly like layout_static's DMEM bump
    # allocator -- a struct here is just a named sub-region of DMEM, not an
    # ABI with padding rules to match some other compiler. `@aligned(16)`
    # on the struct decl itself (the design note's own `VtxJob` example)
    # widens the whole struct's alignment and rounds its total size up to
    # match, same as it does for a static.
    method register_struct {decl} {
        set name [pak::fval $decl name]
        if {[dict exists $structs $name]} { pak::rsp_unported "struct '$name' declared more than once" $decl }
        set used 0
        set salign 1
        set fields [dict create]
        foreach f [pak::items [pak::nfield $decl fields]] {
            set fname [pak::fval $f name]
            if {![pak::isnil [pak::nfield $f default_value]]} {
                pak::rsp_unported "struct field '$name.$fname' has a default value -- RSP struct statics have no Pak-level initializer, same as any other static" $f
            }
            set flayout [my layout_type [pak::nfield $f type]]
            set fa [dict get $flayout align]
            set off [expr {($used + $fa - 1) & ~($fa - 1)}]
            dict set fields $fname [list $off $flayout]
            set used [expr {$off + [dict get $flayout size]}]
            if {$fa > $salign} { set salign $fa }
        }
        set salign [pak::mips_ann_align [pak::mips_annlist $decl] $salign]
        set used [expr {($used + $salign - 1) & ~($salign - 1)}]
        dict set structs $name [dict create size $used align $salign fields $fields]
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
        set struct_decls {}
        foreach decl [pak::items [pak::nfield $program decls]] {
            switch -- [pak::kindof $decl] {
                StructDecl { lappend struct_decls $decl }
                StaticDecl { lappend static_decls $decl }
                EntryBlock {
                    if {$entry_decl ne ""} { pak::rsp_unported "more than one `entry` block (a microcode is one program)" $decl }
                    set entry_decl $decl
                }
                UseDecl {
                    # `use rsp.vacc` (and any other `use`): accepted and
                    # ignored. `vacc.*` is recognized in gen_call by the
                    # literal identifier "vacc" regardless of whether it was
                    # `use`d, so this isn't real import resolution -- just
                    # not rejecting syntax the design note's own examples
                    # use at the top of every microcode.
                    #
                    # A shared-module struct (`use shared.vtxjob`) is real
                    # cross-file resolution, but it doesn't happen HERE:
                    # this codegen still only ever registers structs
                    # declared in the program it is HANDED (see
                    # register_struct's comment). cli.tcl's
                    # pak::rsp_resolve_program is what makes that program
                    # contain more than one file's declarations -- when a
                    # `use` here names a project module, it finds the file
                    # that declares it and concatenates its source ahead of
                    # this one before ever calling rsp_generate_records, the
                    # same way cmd_dlist compiles a scene together with the
                    # standalone HAL as one translation unit. So a `use`
                    # left unresolved by the time it reaches here just means
                    # no project module by that name was found (or this
                    # codegen was called directly, bypassing cli.tcl, as
                    # every test harness in this repo still does) -- still
                    # not an error: whatever struct the microcode actually
                    # needs will fail to resolve on its own, at the point it
                    # is used, with a clear message.
                }
                ModuleDecl {
                    # The shared module file's OWN `module shared.vtxjob`
                    # line, present in the source pak::rsp_resolve_program
                    # concatenated ahead of this file. Accepted and ignored
                    # for the same reason UseDecl is: this codegen cares
                    # about the STRUCT the module declares, not the module
                    # wrapper around it.
                }
                default {
                    pak::rsp_unported "top-level '[pak::kindof $decl]' -- the RSP target only accepts `use`, `module`, `struct`, `static`, and one `entry`" $decl
                }
            }
        }
        if {$entry_decl eq ""} { pak::rsp_unported "no `entry` block (a microcode needs exactly one)" }

        foreach decl $struct_decls { my register_struct $decl }
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
            pak::rsp_unported "static '$name' has an initializer -- RSP DMEM content comes from what the CPU DMAs in before sp.run(), not from a Pak-level init" $decl
        }
        set layout [my layout_type [pak::nfield $decl type]]
        set align [pak::mips_ann_align [pak::mips_annlist $decl] [dict get $layout align]]
        set off [expr {($dmem_used + $align - 1) & ~($align - 1)}]
        dict set statics $name [list $off [dict get $layout size] [dict get $layout is_array] \
            [dict get $layout elem_size] [dict get $layout is_signed] [dict get $layout is_vector] \
            [dict get $layout is_struct] [dict get $layout struct_name]]
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
            default  { pak::rsp_unported "statement kind '[pak::kindof $stmt]' is not supported in the RSP target yet" $stmt }
        }
    }

    # A top-level expression-statement: an Assign is lowered as a store, any
    # other expression is evaluated for effect and its result discarded (an
    # RSP microcode has nothing meaningful to discard a value INTO besides a
    # store, but a bare call-like expression could still exist once modules
    # arrive -- so this stays a real dispatch, not an Assign-only path).
    method gen_stmt_expr {e} {
        if {[pak::kindof $e] eq "Assign"} { my gen_assign $e; return }
        lassign [my gen_expr $e] r isvec
        my free_val $r $isvec
    }

    # A vec8x16 local costs one whole-register copy on `let` (the initializer
    # evaluates into a fresh temp; the local needs its own stable register,
    # since the temp gets freed at the end of this statement like any other).
    method gen_let {decl} {
        set name [pak::fval $decl name]
        set v [pak::nfield $decl value]
        if {[pak::isnil $v]} { pak::rsp_unported "let '$name' has no initializer (required in the RSP target v1 -- no uninitialized locals)" $decl }
        set is_signed 0
        set t [pak::nfield $decl type]
        if {![pak::isnil $t] && [pak::kindof $t] eq "TypeName"} {
            if {[pak::fval $t name] ne "vec8x16"} {
                lassign [my layout_scalar [pak::fval $t name] $t] _ _ is_signed
            }
        }
        lassign [my gen_expr $v] reg isvec
        if {$isvec} {
            set home [my valloc_reg]
            my vec_move $home $reg
            my vfree_reg $reg
            my declare_local $name $home 0 1
        } else {
            my declare_local $name $reg $is_signed 0
        }
    }

    # target must be an Ident (local or static scalar/vec8x16), a lane of a
    # vec8x16 (`v[i] = ...`), a DotAccess into a struct-typed static's scalar
    # or vec8x16 field (`job.count = ...`), or an IndexAccess into a static
    # array or a struct field array (`job.vertices[i] = ...`) -- the only
    # things memory (or a vector lane) means on the RSP target.
    method gen_assign {node} {
        set op [pak::fval $node op]
        if {$op ne "="} { pak::rsp_unported "compound assignment '$op' is not supported yet -- write it as 'x = x $op...'" $node }
        set target [pak::nfield $node target]
        switch -- [pak::kindof $target] {
            Ident {
                set r [my resolve [pak::fval $target name]]
                if {$r eq ""} { pak::rsp_unported "assignment to undefined name '[pak::fval $target name]'" $target }
                lassign $r kind a b c d e f g
                if {$kind eq "local"} {
                    lassign [my gen_expr [pak::nfield $node value]] vreg visvec
                    if {$c} { my vec_move $a $vreg; my vfree_reg $vreg } \
                    else { $em move $a $vreg; my free_reg $vreg }
                } else {
                    # static: a b c d e f g = offset size is_array elem_size is_signed is_vector is_struct
                    if {$c} { pak::rsp_unported "'[pak::fval $target name]' is an array -- index it to assign an element" $target }
                    if {$g} { pak::rsp_unported "'[pak::fval $target name]' is a struct -- assign one of its fields" $target }
                    lassign [my gen_expr [pak::nfield $node value]] vreg visvec
                    if {$f} {
                        $em instr sqv "[my vreg_tok $vreg]," "${a}(\$zero)"
                        my vfree_reg $vreg
                    } else {
                        $em instr [my store_op $b] "$vreg," "${a}(\$zero)"
                        my free_reg $vreg
                    }
                }
            }
            DotAccess {
                lassign [my resolve_field $target] addr flayout
                if {[dict get $flayout is_array]} { pak::rsp_unported "field '[pak::fval $target field]' is an array -- index it to assign an element" $target }
                if {[dict get $flayout is_struct]} { pak::rsp_unported "field '[pak::fval $target field]' is a struct -- assign one of its fields" $target }
                lassign [my gen_expr [pak::nfield $node value]] vreg visvec
                if {[dict get $flayout is_vector]} {
                    $em instr sqv "[my vreg_tok $vreg]," "${addr}(\$zero)"
                    my vfree_reg $vreg
                } else {
                    $em instr [my store_op [dict get $flayout size]] "$vreg," "${addr}(\$zero)"
                    my free_reg $vreg
                }
            }
            IndexAccess {
                if {[my is_lane_index [pak::nfield $target obj]]} {
                    my gen_lane_write $target [pak::nfield $node value]
                    return
                }
                lassign [my gen_element_addr $target] areg elem_size is_signed is_vec
                lassign [my gen_expr [pak::nfield $node value]] vreg visvec
                if {$is_vec} {
                    $em instr sqv "[my vreg_tok $vreg]," "0($areg)"
                    my vfree_reg $vreg
                } else {
                    $em instr [my store_op $elem_size] "$vreg," "0($areg)"
                    my free_reg $vreg
                }
                my free_reg $areg
            }
            default { pak::rsp_unported "assignment target kind '[pak::kindof $target]' is not supported" $target }
        }
    }

    # Is `obj[...]` indexing a vec8x16's LANES (obj itself is a vec8x16
    # value) rather than an array element (obj is an array of scalars)?
    # Both are the same IndexAccess AST shape; only obj's own type tells
    # them apart.
    method is_lane_index {obj} {
        if {[pak::kindof $obj] ne "Ident"} { return 0 }
        set r [my resolve [pak::fval $obj name]]
        if {$r eq ""} { return 0 }
        if {[lindex $r 0] eq "local"} { return [lindex $r 3] }
        # static: {static offset size is_array elem_size is_signed is_vector ...}.
        # is_vector alone is not enough once arrays of vec8x16 exist -- it
        # also means "elements are vec8x16" when is_array is 1, and indexing
        # THAT is element addressing (gen_element_addr), not a lane read.
        return [expr {![lindex $r 3] && [lindex $r 6]}]
    }

    # A vec8x16 lane index is a hardware FIELD (MFC2/MTC2's element byte),
    # not a register operand -- "the index must be a literal because the
    # encoding has a field for it, not a register" (design note). Lane n
    # (0-7) maps to byte offset 2n, always even, which is also what keeps
    # clear of MFC2's odd-element byte-straddle quirk.
    method lane_byte {node} {
        set idx [pak::nfield $node index]
        if {[pak::kindof $idx] ne "IntLit"} {
            pak::rsp_unported "a vec8x16 lane index must be a literal (the hardware field is an immediate, not a register)" $idx
        }
        set n [pak::fval $idx value]
        if {$n < 0 || $n > 7} { pak::rsp_unported "vec8x16 lane index $n out of range 0-7" $idx }
        return [expr {$n * 2}]
    }
    method gen_lane_read {node} {
        set obj [pak::nfield $node obj]
        lassign [my resolve [pak::fval $obj name]] kind a
        set vreg [expr {$kind eq "local" ? $a : ""}]
        if {$kind eq "static"} {
            set vreg [my valloc_reg]
            $em instr lqv "[my vreg_tok $vreg]," "${a}(\$zero)"
        }
        set dst [my alloc_reg]
        $em instr mfc2 "$dst," [my vreg_tok $vreg [my lane_byte $node]]
        if {$kind eq "static"} { my vfree_reg $vreg }
        return $dst
    }
    method gen_lane_write {node value_node} {
        set obj [pak::nfield $node obj]
        lassign [my resolve [pak::fval $obj name]] kind a
        lassign [my gen_expr $value_node] vsrc vsrc_isvec
        if {$kind eq "local"} {
            $em instr mtc2 "$vsrc," [my vreg_tok $a [my lane_byte $node]]
        } else {
            set vreg [my valloc_reg]
            $em instr lqv "[my vreg_tok $vreg]," "${a}(\$zero)"
            $em instr mtc2 "$vsrc," [my vreg_tok $vreg [my lane_byte $node]]
            $em instr sqv "[my vreg_tok $vreg]," "${a}(\$zero)"
            my vfree_reg $vreg
        }
        my free_reg $vsrc
    }

    # `job.field` -- a struct-typed static's field. Every struct instance on
    # the RSP target is a single static (there is no array-of-struct, no
    # struct local, no pointer to reach one some other way), so the
    # object's own address is always a compile-time constant and so is the
    # field's offset within it -- there is never a register involved in
    # computing WHERE a field is, only in what's read from or written there.
    # Returns {const_addr field_layout}.
    method resolve_field {node} {
        set obj [pak::nfield $node obj]
        set field [pak::fval $node field]
        if {[pak::kindof $obj] ne "Ident"} {
            pak::rsp_unported "field access on '[pak::kindof $obj]' is not supported -- only one level of field access on a plain struct-typed static name" $obj
        }
        set r [my resolve [pak::fval $obj name]]
        if {$r eq "" || [lindex $r 0] ne "static" || ![lindex $r 7]} {
            pak::rsp_unported "'[pak::fval $obj name]' is not a struct-typed static" $obj
        }
        set base [lindex $r 1]
        set sname [lindex $r 8]
        set fields [dict get $structs $sname fields]
        if {![dict exists $fields $field]} {
            pak::rsp_unported "struct '$sname' has no field '$field'" $node
        }
        lassign [dict get $fields $field] foff flayout
        return [list [expr {$base + $foff}] $flayout]
    }

    # The base address and element layout of whatever `arr[...]` in
    # `obj[idx]` is indexing: either a plain static array name, or a struct
    # field that is itself an array (`job.vertices[i]`). Returns
    # {base_addr elem_size is_signed elem_is_vector}.
    method resolve_array {obj} {
        switch -- [pak::kindof $obj] {
            Ident {
                set r [my resolve [pak::fval $obj name]]
                if {$r eq "" || [lindex $r 0] ne "static" || ![lindex $r 3]} {
                    pak::rsp_unported "'[pak::fval $obj name]' is not a static array" $obj
                }
                return [list [lindex $r 1] [lindex $r 4] [lindex $r 5] [lindex $r 6]]
            }
            DotAccess {
                lassign [my resolve_field $obj] base flayout
                if {![dict get $flayout is_array]} {
                    pak::rsp_unported "field '[pak::fval $obj field]' is not an array" $obj
                }
                return [list $base [dict get $flayout elem_size] [dict get $flayout is_signed] [dict get $flayout is_vector]]
            }
            default { pak::rsp_unported "only a static array name or a struct field can be indexed (got [pak::kindof $obj])" $obj }
        }
    }

    # Computes the runtime byte address of `arr[i]` into a fresh register.
    # Returns {addr_reg elem_size is_signed elem_is_vector}. A constant index
    # folds to a single immediate; a variable index costs a shift-and-add,
    # same as any MIPS backend -- there is no addressing mode that takes a
    # scaled register operand. A vec8x16 element (elem_size 16) scales by
    # shifting 4 instead of 2 -- same idea as the byte/halfword/word cases,
    # just a wider element -- and the caller picks LQV/SQV over a scalar
    # load/store based on elem_is_vector rather than this method choosing an
    # instruction itself, since which one to use also depends on whether the
    # caller is reading or writing.
    method gen_element_addr {node} {
        set obj [pak::nfield $node obj]
        lassign [my resolve_array $obj] base elem_size is_signed elem_is_vector
        set idx [pak::nfield $node index]
        set areg [my alloc_reg]
        if {[pak::kindof $idx] eq "IntLit"} {
            $em instr addiu "$areg," {$zero,} [expr {$base + [pak::fval $idx value] * $elem_size}]
        } else {
            lassign [my gen_expr $idx] ireg iisvec
            if {$elem_size == 1} {
                $em instr addiu "$areg," "$ireg," $base
            } else {
                set shift [expr {$elem_size == 2 ? 1 : ($elem_size == 16 ? 4 : 2)}]
                $em sll $areg $ireg $shift
                $em instr addiu "$areg," "$areg," $base
            }
            my free_reg $ireg
        }
        return [list $areg $elem_size $is_signed $elem_is_vector]
    }

    method gen_if {node} {
        set has_else [expr {![pak::isnil [pak::nfield $node else_branch]] \
                             || [llength [pak::items [pak::nfield $node elif_branches]]] > 0}]
        set end_lbl [my new_label if_end]
        my gen_if_chain [pak::nfield $node condition] [pak::nfield $node then] \
            [pak::items [pak::nfield $node elif_branches]] [pak::nfield $node else_branch] $end_lbl
        $em label $end_lbl
    }
    # A branch condition is always a plain GPR 0/1 -- a vec8x16 has no
    # meaningful truthiness, so gen_expr producing a vector here is the
    # caller's mistake, not something to paper over.
    method gen_scalar_expr {node} {
        lassign [my gen_expr $node] r isvec
        if {$isvec} { pak::rsp_unported "a vec8x16 value used where a scalar is required" $node }
        return $r
    }

    method gen_if_chain {cond then elifs else_branch end_lbl} {
        set creg [my gen_scalar_expr $cond]
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
        set creg [my gen_scalar_expr [pak::nfield $node condition]]
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

    # ── expressions: every case returns {reg is_vector}. The caller owns the
    # register and must free it via free_val (an Ident read is copied out of
    # its home register/memory rather than handed back directly, so freeing
    # an expression's result never corrupts a live local) ────────────────────
    method gen_expr {node} {
        switch -- [pak::kindof $node] {
            IntLit { set r [my alloc_reg]; $em li $r [pak::fval $node value]; return [list $r 0] }
            Ident   { return [my gen_ident [pak::fval $node name] $node] }
            BinaryOp { return [my gen_binop $node] }
            UnaryOp  { return [list [my gen_unop $node] 0] }
            IndexAccess {
                if {[my is_lane_index [pak::nfield $node obj]]} {
                    return [list [my gen_lane_read $node] 0]
                }
                lassign [my gen_element_addr $node] areg elem_size is_signed elem_is_vector
                if {$elem_is_vector} {
                    set vdst [my valloc_reg]
                    $em instr lqv "[my vreg_tok $vdst]," "0($areg)"
                    my free_reg $areg
                    return [list $vdst 1]
                }
                $em instr [my load_op $elem_size $is_signed] "$areg," "0($areg)"
                return [list $areg 0]
            }
            DotAccess { return [my gen_field_read $node] }
            Cast { return [list [my gen_cast $node] 0] }
            Call { return [my gen_call $node] }
            default { pak::rsp_unported "expression kind '[pak::kindof $node]' is not supported in the RSP target yet" $node }
        }
    }

    # `job.count`, `job.mvp` (the latter only useful as an IndexAccess's obj,
    # not read directly -- see the is_array refusal below).
    method gen_field_read {node} {
        lassign [my resolve_field $node] addr flayout
        if {[dict get $flayout is_array]} { pak::rsp_unported "field '[pak::fval $node field]' is an array -- index it to read an element" $node }
        if {[dict get $flayout is_struct]} { pak::rsp_unported "field '[pak::fval $node field]' is a struct -- access one of its fields" $node }
        if {[dict get $flayout is_vector]} {
            set dst [my valloc_reg]
            $em instr lqv "[my vreg_tok $dst]," "${addr}(\$zero)"
            return [list $dst 1]
        }
        set dst [my alloc_reg]
        $em instr [my load_op [dict get $flayout size] [dict get $flayout is_signed]] "$dst," "${addr}(\$zero)"
        return [list $dst 0]
    }

    method gen_ident {name {node ""}} {
        set r [my resolve $name]
        if {$r eq ""} { pak::rsp_unported "undefined name '$name'" $node }
        lassign $r kind a b c d e
        if {$kind eq "local"} {
            # b here is is_signed, c is is_vector (local tuple: reg is_signed is_vector).
            if {$c} {
                set dst [my valloc_reg]
                my vec_move $dst $a
                return [list $dst 1]
            }
            set dst [my alloc_reg]
            $em move $dst $a
            return [list $dst 0]
        }
        # static: a b c d e f g = offset size is_array elem_size is_signed is_vector is_struct
        set f [lindex $r 6]
        if {$c} { pak::rsp_unported "'$name' is an array -- index it to read an element" $node }
        if {[lindex $r 7]} { pak::rsp_unported "'$name' is a struct -- access one of its fields" $node }
        if {$f} {
            set dst [my valloc_reg]
            $em instr lqv "[my vreg_tok $dst]," "${a}(\$zero)"
            return [list $dst 1]
        }
        set dst [my alloc_reg]
        $em instr [my load_op $b $e] "$dst," "${a}(\$zero)"
        return [list $dst 0]
    }

    method gen_cast {node} {
        set src [my gen_scalar_expr [pak::nfield $node expr]]
        set t [pak::nfield $node type]
        if {[pak::kindof $t] ne "TypeName"} { pak::rsp_unported "cast to non-scalar type" $t }
        lassign [my layout_scalar [pak::fval $t name] $t] size align is_signed
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
        set r [my gen_scalar_expr [pak::nfield $node operand]]
        switch -- $op {
            "-" { $em instr subu "$r," {$zero,} $r }
            "!" { $em instr sltiu "$r," "$r," 1 }
            default { pak::rsp_unported "unary operator '$op'" $node }
        }
        return $r
    }

    # rsp.vacc: the multiply family and the accumulator, per docs/rsp-
    # microcode-in-pak.md's "vacc -- the accumulator is hardware, so it is a
    # module". `vacc.mul(a, b)` starts the accumulator fresh (VMULF, signed
    # Q1.15 multiply with rounding); `vacc.mac(a, b)` adds into it (VMACF);
    # `.high()`/`.mid()`/`.low()` read one of its three 16-bit slices back
    # (VSAR). vd on the multiply instructions is a required field with no
    # meaningful use here -- the accumulator, not vd, is what vacc.mac/high
    # care about -- so a throwaway temp fills it, same as real microcode
    # does with a scratch register in that slot.
    method gen_vacc_call {field args_nodes {node ""}} {
        switch -- $field {
            mul - mac {
                if {[llength $args_nodes] != 2} { pak::rsp_unported "vacc.$field takes exactly two vec8x16 arguments" $node }
                if {$field eq "mac" && !$vacc_started} {
                    pak::rsp_unported "vacc.mac with no vacc.mul before it -- accumulating onto a stale value" $node
                }
                lassign [my gen_expr [lindex $args_nodes 0]] areg aisvec
                if {!$aisvec} { pak::rsp_unported "vacc.$field's first argument must be a vec8x16" [lindex $args_nodes 0] }
                set funct [expr {$field eq "mul" ? "vmulf" : "vmacf"}]
                set dst [my valloc_reg]
                set bc [my broadcast_call [lindex $args_nodes 1]]
                if {$bc ne ""} {
                    lassign $bc obj_node e
                    lassign [my gen_expr $obj_node] breg bisvec
                    if {!$bisvec} { pak::rsp_unported "vacc.$field's second argument must be a vec8x16" [lindex $args_nodes 1] }
                    $em instr $funct "[my vreg_tok $dst]," [my vreg_tok $areg] [my vreg_tok $breg $e]
                    my vfree_reg $breg
                } else {
                    lassign [my gen_expr [lindex $args_nodes 1]] breg bisvec
                    if {!$bisvec} { pak::rsp_unported "vacc.$field's second argument must be a vec8x16" [lindex $args_nodes 1] }
                    $em instr $funct "[my vreg_tok $dst]," [my vreg_tok $areg] [my vreg_tok $breg]
                    my vfree_reg $breg
                }
                my vfree_reg $areg
                set vacc_started 1
                return [list $dst 1]
            }
            high - mid - low {
                if {[llength $args_nodes] != 0} { pak::rsp_unported "vacc.$field takes no arguments" $node }
                if {!$vacc_started} {
                    pak::rsp_unported "vacc.$field with no vacc.mul or vacc.mac before it -- reading whatever the last unrelated multiply left behind" $node
                }
                set e [dict get {high 8 mid 9 low 10} $field]
                set dst [my valloc_reg]
                $em instr vsar "[my vreg_tok $dst]," [my vreg_tok $dst] [my vreg_tok $dst $e]
                return [list $dst 1]
            }
            default { pak::rsp_unported "unknown rsp.vacc method '$field'" $node }
        }
    }

    # `v.broadcast(n)` -- a value, materialized here as a real register:
    # zero a fresh vector temp (self-XOR, since RSP has no register that is
    # hardwired to zero the way $zero is for GPRs) and OR it with v's lane n
    # broadcast, since 0|x = x. When this call appears as a vector binop's
    # (or vacc.mul/vacc.mac's) right-hand operand instead, that caller fuses
    # it into the instruction's own element-select field for free (a real
    # instruction, not a temp) -- see broadcast_call, checked before ever
    # calling gen_expr on the right operand.
    method gen_call {node} {
        set func [pak::nfield $node func]
        if {[pak::kindof $func] eq "DotAccess"} {
            set obj [pak::nfield $func obj]
            if {[pak::kindof $obj] eq "Ident" && [pak::fval $obj name] eq "vacc"} {
                return [my gen_vacc_call [pak::fval $func field] [pak::items [pak::nfield $node args]] $node]
            }
        }
        if {[pak::kindof $func] ne "DotAccess" || [pak::fval $func field] ne "broadcast"} {
            pak::rsp_unported "the RSP target does not support function or module calls yet (only v.broadcast(n) on a vec8x16 and rsp.vacc.mul/mac/high/mid/low)" $node
        }
        set args [pak::items [pak::nfield $node args]]
        if {[llength $args] != 1 || [pak::kindof [lindex $args 0]] ne "IntLit"} {
            pak::rsp_unported "'broadcast' takes exactly one literal lane index (the encoding has a field for it, not a register)" $node
        }
        set lane [pak::fval [lindex $args 0] value]
        if {$lane < 0 || $lane > 7} { pak::rsp_unported "broadcast lane $lane out of range 0-7" [lindex $args 0] }
        lassign [my gen_expr [pak::nfield $func obj]] vreg isvec
        if {!$isvec} { pak::rsp_unported "'.broadcast' is only meaningful on a vec8x16" $node }
        set zero [my valloc_reg]
        $em instr vxor "[my vreg_tok $zero]," [my vreg_tok $zero] [my vreg_tok $zero]
        $em instr vor "[my vreg_tok $vreg]," [my vreg_tok $zero] [my vreg_tok $vreg [expr {8 + $lane}]]
        my vfree_reg $zero
        return [list $vreg 1]
    }

    # True exactly when `node` is `x.broadcast(n)` -- checked syntactically,
    # without evaluating it, so gen_binop can fuse it into the element-select
    # field of the instruction it is an operand of instead of materializing
    # a temporary that instruction would then have broadcast AGAIN.
    method broadcast_call {node} {
        if {[pak::kindof $node] ne "Call"} { return "" }
        set func [pak::nfield $node func]
        if {[pak::kindof $func] ne "DotAccess" || [pak::fval $func field] ne "broadcast"} { return "" }
        set args [pak::items [pak::nfield $node args]]
        if {[llength $args] != 1 || [pak::kindof [lindex $args 0]] ne "IntLit"} { return "" }
        set lane [pak::fval [lindex $args 0] value]
        if {$lane < 0 || $lane > 7} { return "" }
        return [list [pak::nfield $func obj] [expr {8 + $lane}]]
    }

    method gen_binop {node} {
        set op [pak::fval $node op]
        if {$op in {* / %}} {
            pak::rsp_unported "operator '$op' -- the RSP scalar unit has no multiply or divide" $node
        }
        lassign [my gen_expr [pak::nfield $node left]] l lisvec
        if {$lisvec} { return [my gen_vec_binop $op $l [pak::nfield $node right]] }
        set r [my gen_scalar_expr [pak::nfield $node right]]
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
            default { pak::rsp_unported "binary operator '$op'" $node }
        }
        my free_reg $r
        return [list $l 0]
    }

    # Elementwise vec8x16 ops. `l` is already a register this call owns.
    # `<<`/`>>` are refused: real RSP hardware has no vector shift
    # instruction (checked against armips' own opcode table, the same
    # source the rest of this session's RSP work was verified against) --
    # a vector shift needs VMUDL/VMUDH-style multiply tricks, not yet
    # implemented, so this corrects docs/rsp-microcode-in-pak.md's own
    # `a << 2 -- VSLL` example rather than silently pretending it exists.
    method gen_vec_binop {op l right_node} {
        set funct ""
        switch -- $op {
            "+" { set funct vadd }
            "-" { set funct vsub }
            "&" { set funct vand }
            "|" { set funct vor }
            "^" { set funct vxor }
            "<<" - ">>" {
                pak::rsp_unported "operator '$op' on vec8x16 -- real RSP hardware has no vector shift instruction (no VSLL/VSRL); shifting needs a VMUDL/VMUDH-based trick, not implemented yet" $right_node
            }
            default { pak::rsp_unported "binary operator '$op' on vec8x16" $right_node }
        }
        set bc [my broadcast_call $right_node]
        if {$bc ne ""} {
            lassign $bc obj_node e
            lassign [my gen_expr $obj_node] rreg risvec
            if {!$risvec} { pak::rsp_unported "'.broadcast' is only meaningful on a vec8x16" $obj_node }
            $em instr $funct "[my vreg_tok $l]," [my vreg_tok $l] [my vreg_tok $rreg $e]
            my vfree_reg $rreg
        } else {
            lassign [my gen_expr $right_node] rreg risvec
            if {!$risvec} { pak::rsp_unported "vec8x16 binary operator '$op' needs a vec8x16 on both sides" $right_node }
            $em instr $funct "[my vreg_tok $l]," [my vreg_tok $l] [my vreg_tok $rreg]
            my vfree_reg $rreg
        }
        return [list $l 1]
    }
}

proc pak::rsp_generate_records {program} {
    set cg [pak::RspCodegen new]
    set recs [$cg generate $program]
    $cg destroy
    return $recs
}
