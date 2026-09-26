# tcl/opt_inline.tcl — inline small, simple, non-recursive free functions at
# their call sites, as a pure AST-to-AST rewrite applied once, right before
# the MIPS backend sees the program (pak::mips_generate_records below calls
# pak::inline_program). The C/RSP backends never see this: the C compiler
# already inlines on its own, and RSP microcode has no call instruction to
# begin with.
#
# Runtime helpers like rdp_ch/dl_cmd/rdp_tex_hi are called a couple of dozen
# times per triangle, each call paying a `jal`/argument-marshal/`jr $ra`
# tax for what's often a two- or three-instruction body. This pass splices
# the callee's (renamed) body in at the call site instead.
#
# Scope, deliberately narrow:
#  - Only plain `fn` declarations (never `impl` methods -- no self-receiver
#    substitution to get right) with no type parameters, no variadic args,
#    no default-valued params, and every param/return type a scalar
#    (i32/u32/f32/bool) or a pointer -- exactly the set MipsCodegen's own
#    register-promotion pool (mips_codegen.tcl, compute_promotable) already
#    treats as "just a 4-byte value", so an inlined body's own locals get a
#    fair shot at that SAME promotion for free once this pass hands its
#    output back to ordinary codegen.
#  - The callee's body may use ordinary straight-line code, `if`/`elif`/
#    `else`, and any number of `return`s anywhere in it (including nested
#    inside an `if`) -- see the Return rewrite below, which turns every
#    `return expr` into an assignment to a synthesized result local
#    followed by a real Pak `goto` to a synthesized end label ([IMPLEMENTED]
#    per LANGUAGE.md, not a codegen-only construct, so this stays valid Pak
#    source the checker itself could parse and typecheck, even though this
#    pass runs after checking and only the MIPS backend ever sees it).
#  - No `asm` block anywhere in the body: an asm block's labels are literal
#    strings the author wrote by hand, not generated fresh per use the way
#    Pak's own `if`/`loop` labels are (see fresh_label in mips_codegen.tcl),
#    so splicing one in at more than one call site would collide.
#  - No `defer`, no `Closure`, no loop (`while`/`loop`/`for`/`do-while`), no
#    `match`, no existing `goto`/`label` of its own, and not (directly)
#    self-recursive. None of this is unsound to support in principle --
#    loops interact fine with Pak's own fresh-label scheme, defer's
#    interaction with an inlined early-return-turned-goto is the one place
#    that would need real thought -- it's just not needed for the actual
#    candidates (rdp_ch, dl_cmd, dl_word, to_fx102, to_fx142,
#    rdp_edge_slope, rdp_tex_hi/lo, rdp_rgba_hi/lo, rdp_z_coeffs) and each
#    one narrows the blast radius of a rewrite pass this size.
#  - Only inlines a call that IS an entire statement's value: `let x[: T] =
#    f(args)`, `x = f(args)`, or a bare `f(args)` statement. A call buried
#    inside a larger expression (`x = f(a) + g(b)`) is left alone -- that
#    would need hoisting the call out of the expression first, which this
#    pass does not attempt.
#  - Exactly one level: a call inside an already-eligible callee's own body
#    is spliced in as an ordinary call (compiled normally), never itself
#    further inlined by this same pass. Keeps the transform predictable
#    and its output size bounded regardless of how many eligible functions
#    call each other.
#
# Every call site gets its own globally-unique name prefix
# (__inl<N>_...), so the same function inlined at five call sites -- or
# five times around a loop that syntactically contains one call site --
# never aliases one expansion's locals with another's.

namespace eval pak {}

set ::pak::_inline_ctr 0
set ::pak::INLINE_STMT_KINDS {Block LetDecl Assign ExprStmt Return IfStmt}
set ::pak::INLINE_EXPR_KINDS {
    Ident IntLit FloatLit BoolLit StringLit BinaryOp UnaryOp Call Cast
    DotAccess IndexAccess SliceExpr AddrOf Deref NamedArg TupleAccess
    TupleLit RangeExpr NoneLit SizeOf AlignOf OffsetOf ArrayLit StructLit
    UndefinedLit
}
# Type annotations (Cast.type, LetDecl.type, Param.type, ...) are pure
# static descriptions, never executable, so every type-node kind is always
# allowed regardless of what it names -- widening the *value* pool a
# candidate's params/return may use (INLINE_EXPR_KINDS's TypeName/
# TypePointer check above) is a separate, deliberate restriction.
set ::pak::INLINE_TYPE_KINDS {
    TypeName TypePointer TypeArray TypeSlice TypeGeneric TypeOption
    TypeResult TypeTuple TypeFn TypeVolatile TypeDynTrait TypeParam
}

proc pak::_inline_scalar_or_ptr_type {tn allow_void} {
    if {$tn eq "" || [pak::isnil $tn]} { return $allow_void }
    switch -- [pak::kindof $tn] {
        TypePointer { return 1 }
        TypeName    { return [expr {[pak::fval $tn name] in {i32 u32 f32 bool}}] }
        default     { return 0 }
    }
}

# Recursively checks that every node in the callee body is one this pass
# understands (see the scope note above), and that no Call inside it
# targets the function's own name (direct self-recursion).
proc pak::_inline_body_ok {tv self_name} {
    if {[pak::kindof $tv] eq ""} {
        if {[llength $tv] >= 1 && [lindex $tv 0] eq "seq"} {
            foreach item [lindex $tv 1] {
                if {![pak::_inline_body_ok $item $self_name]} { return 0 }
            }
        }
        return 1
    }
    set kind [pak::kindof $tv]
    if {$kind ni $::pak::INLINE_STMT_KINDS && $kind ni $::pak::INLINE_EXPR_KINDS \
            && $kind ni $::pak::INLINE_TYPE_KINDS} {
        return 0
    }
    if {$kind eq "Call"} {
        set fexpr [pak::nfield $tv func]
        if {[pak::kindof $fexpr] eq "Ident" && [pak::fval $fexpr name] eq $self_name} {
            return 0
        }
    }
    foreach f [dict get $::pak::SCHEMA $kind] {
        if {![pak::_inline_body_ok [pak::nfield $tv $f] $self_name]} { return 0 }
    }
    return 1
}

proc pak::_inline_node_count {tv} {
    if {[pak::kindof $tv] eq ""} {
        if {[llength $tv] >= 1 && [lindex $tv 0] eq "seq"} {
            set n 0
            foreach item [lindex $tv 1] { incr n [pak::_inline_node_count $item] }
            return $n
        }
        return 0
    }
    set n 1
    foreach f [dict get $::pak::SCHEMA [pak::kindof $tv]] {
        incr n [pak::_inline_node_count [pak::nfield $tv $f]]
    }
    return $n
}

# A param the callee body reassigns can't be a simple one-shot `let` binding
# of the argument -- reject rather than get that subtly wrong. `mutable` a
# param can still be true in the AST while nothing in the body writes to
# it, so this checks actual writes, not just the declared flag.
proc pak::_inline_body_writes_name {tv name} {
    if {[pak::kindof $tv] eq ""} {
        if {[llength $tv] >= 1 && [lindex $tv 0] eq "seq"} {
            foreach item [lindex $tv 1] {
                if {[pak::_inline_body_writes_name $item $name]} { return 1 }
            }
        }
        return 0
    }
    set kind [pak::kindof $tv]
    if {$kind eq "Assign"} {
        set t [pak::nfield $tv target]
        if {[pak::kindof $t] eq "Ident" && [pak::fval $t name] eq $name} { return 1 }
    }
    foreach f [dict get $::pak::SCHEMA $kind] {
        if {[pak::_inline_body_writes_name [pak::nfield $tv $f] $name]} { return 1 }
    }
    return 0
}

# Builds the table of inline-eligible free functions across the whole
# program (both files handed to objgen individually only ever see their
# own decls, same as every other whole-program table this backend keeps).
proc pak::_inline_build_table {program} {
    set table [dict create]
    foreach decl [pak::items [pak::nfield $program decls]] {
        if {[pak::kindof $decl] ne "FnDecl"} continue
        if {[pak::fval $decl is_method]} continue
        if {[pak::fval $decl variadic]} continue
        if {[llength [pak::items [pak::nfield $decl type_params]]] > 0} continue
        set body [pak::nfield $decl body]
        if {[pak::isnil $body]} continue
        if {![pak::_inline_scalar_or_ptr_type [pak::nfield $decl ret_type] 1]} continue
        set ok 1
        foreach p [pak::items [pak::nfield $decl params]] {
            if {![pak::_inline_scalar_or_ptr_type [pak::nfield $p type] 0]} { set ok 0; break }
            if {![pak::isnil [pak::nfield $p default_value]]} { set ok 0; break }
        }
        if {!$ok} continue
        set name [pak::fval $decl name]
        if {![pak::_inline_body_ok $body $name]} continue
        foreach p [pak::items [pak::nfield $decl params]] {
            if {[pak::_inline_body_writes_name $body [pak::fval $p name]]} { set ok 0; break }
        }
        if {!$ok} continue
        if {[pak::_inline_node_count $body] > 40} continue
        dict set table $name $decl
    }
    return $table
}

# Renames every Ident/LetDecl inside a copy of the callee body (mutating
# `renameVar` as new locals are discovered, scoped to the enclosing Block
# exactly like the source's own lexical scoping -- a shadowed name inside a
# nested `if` doesn't leak its renamed target back out to sibling code),
# and turns every `return` into `<result> = <value>; goto <end>` (or a bare
# `goto <end>` for a void return).
proc pak::_inline_rename_tv {tv renameVar pfx retname endlabel} {
    upvar 1 $renameVar rename
    if {[pak::kindof $tv] eq ""} {
        if {[llength $tv] >= 1 && [lindex $tv 0] eq "seq"} {
            # A plain 1:1 map -- this seq might be a statement list, but it
            # might just as well be StructLit.fields' name/value pairs,
            # IfStmt.elif_branches' cond/block pairs, or a Call's args: none
            # of those may be flattened. The one shape that legitimately
            # expands into more than one sibling (a `return` becoming
            # `<result> = <value>; goto <end>`) is handled explicitly below,
            # in the Block case, which is the only context a Return can
            # actually appear in.
            set out {}
            foreach item [lindex $tv 1] {
                lappend out [pak::_inline_rename_tv $item rename $pfx $retname $endlabel]
            }
            return [list seq $out]
        }
        return $tv
    }
    set kind [pak::kindof $tv]
    if {$kind eq "Ident"} {
        set nm [pak::fval $tv name]
        if {[dict exists $rename $nm]} {
            return [list node Ident \
                [dict create name [pak::Lit [dict get $rename $nm]] \
                             type_args [pak::nfield $tv type_args]] \
                [pak::nodepos $tv]]
        }
        return $tv
    }
    if {$kind eq "LetDecl"} {
        set nm [pak::fval $tv name]
        set newtype [pak::_inline_rename_tv [pak::nfield $tv type] rename $pfx $retname $endlabel]
        set newvalue [pak::_inline_rename_tv [pak::nfield $tv value] rename $pfx $retname $endlabel]
        set newanns [pak::_inline_rename_tv [pak::nfield $tv annotations] rename $pfx $retname $endlabel]
        set newnm "${pfx}${nm}"
        dict set rename $nm $newnm
        return [list node LetDecl \
            [dict create name [pak::Lit $newnm] type $newtype value $newvalue \
                         mutable [pak::nfield $tv mutable] annotations $newanns] \
            [pak::nodepos $tv]]
    }
    if {$kind eq "Return"} {
        set v [pak::nfield $tv value]
        set goto [list node GotoStmt [dict create label [pak::Lit $endlabel]] {0 0}]
        if {[pak::isnil $v]} { return [list seq [list $goto]] }
        set newv [pak::_inline_rename_tv $v rename $pfx $retname $endlabel]
        set asg [list node Assign \
            [dict create target [list node Ident [dict create name [pak::Lit $retname] \
                                                                type_args [pak::Seq {}]] {0 0}] \
                         value $newv op [pak::Lit "="]] \
            {0 0}]
        return [list seq [list $asg $goto]]
    }
    if {$kind eq "Block"} {
        set saved $rename
        set new_stmts {}
        foreach s [pak::items [pak::nfield $tv stmts]] {
            set r [pak::_inline_rename_tv $s rename $pfx $retname $endlabel]
            if {[pak::kindof $s] eq "Return"} {
                # Only a Return's own rewrite legitimately expands into more
                # than one sibling statement (see the Return case above) --
                # flatten by the ORIGINAL kind, never by "the result looks
                # like a seq", which a renamed StructLit/Call/etc. sub-value
                # can also look like without meaning "splice me in".
                foreach x [lindex $r 1] { lappend new_stmts $x }
            } else {
                lappend new_stmts $r
            }
        }
        set rename $saved
        return [list node Block [dict create stmts [list seq $new_stmts]] [pak::nodepos $tv]]
    }
    set fields [dict get $::pak::SCHEMA $kind]
    set args {}
    foreach f $fields {
        lappend args $f [pak::_inline_rename_tv [pak::nfield $tv $f] rename $pfx $retname $endlabel]
    }
    return [list node $kind [dict create {*}$args] [pak::nodepos $tv]]
}

# If `stmt` is `let x[: T] = f(args)` / `x = f(args)` / a bare `f(args)`
# statement and `f` is in the eligible-function table, returns the list of
# statements to splice in its place; otherwise returns {} (unchanged).
proc pak::_inline_try_expand {stmt table} {
    set kind [pak::kindof $stmt]
    set call ""
    set mode ""
    if {$kind eq "LetDecl"} {
        set v [pak::nfield $stmt value]
        if {[pak::kindof $v] eq "Call"} { set call $v; set mode "let" }
    } elseif {$kind eq "Assign"} {
        set v [pak::nfield $stmt value]
        if {[pak::kindof $v] eq "Call" && [pak::fval $stmt op] eq "="} { set call $v; set mode "assign" }
    } elseif {$kind eq "ExprStmt"} {
        set v [pak::nfield $stmt expr]
        if {[pak::kindof $v] eq "Call"} { set call $v; set mode "bare" }
    }
    if {$call eq ""} { return {} }
    set fexpr [pak::nfield $call func]
    if {[pak::kindof $fexpr] ne "Ident"} { return {} }
    set fname [pak::fval $fexpr name]
    if {![dict exists $table $fname]} { return {} }
    set fn [dict get $table $fname]
    set arg_tvs [pak::items [pak::nfield $call args]]
    set params [pak::items [pak::nfield $fn params]]
    if {[llength $arg_tvs] != [llength $params]} { return {} }
    foreach a $arg_tvs { if {[pak::kindof $a] eq "NamedArg"} { return {} } }

    incr ::pak::_inline_ctr
    set pfx "__inl$::pak::_inline_ctr\_"
    set rename [dict create]
    set out {}
    foreach p $params a $arg_tvs {
        set pname [pak::fval $p name]
        set newname "${pfx}${pname}"
        dict set rename $pname $newname
        lappend out [list node LetDecl \
            [dict create name [pak::Lit $newname] type [pak::nfield $p type] value $a \
                         mutable [pak::Bool 0] annotations [pak::Seq {}]] \
            {0 0}]
    }
    set ret_type [pak::nfield $fn ret_type]
    set has_ret [expr {!([pak::isnil $ret_type])}]
    set retname "${pfx}ret"
    if {$has_ret} {
        lappend out [list node LetDecl \
            [dict create name [pak::Lit $retname] type $ret_type \
                         value [list node UndefinedLit {} {0 0}] \
                         mutable [pak::Bool 1] annotations [pak::Seq {}]] \
            {0 0}]
    }
    # .L-prefixed: n64link.tcl treats that prefix as local-to-the-object-
    # file (never entered in the global symbol table), exactly like every
    # label MipsCodegen's own fresh_label generates for if/loop control
    # flow -- anything else is a global symbol, and linking two separately
    # objgen'd files that each inlined a call (say, runtime.pk64 and any
    # program that links against it) would collide on "the first inlined
    # call site in this file" being named identically in both.
    set endlabel ".Linl$::pak::_inline_ctr\_end"
    set body_stmts [pak::items [pak::nfield [pak::nfield $fn body] stmts]]
    foreach bs $body_stmts {
        set r [pak::_inline_rename_tv $bs rename $pfx $retname $endlabel]
        if {[lindex $r 0] eq "seq"} {
            foreach x [lindex $r 1] { lappend out $x }
        } else {
            lappend out $r
        }
    }
    lappend out [list node LabelStmt [dict create name [pak::Lit $endlabel]] {0 0}]
    switch -- $mode {
        let {
            lappend out [list node LetDecl \
                [dict create name [pak::nfield $stmt name] type [pak::nfield $stmt type] \
                             value [list node Ident [dict create name [pak::Lit $retname] \
                                                                  type_args [pak::Seq {}]] {0 0}] \
                             mutable [pak::nfield $stmt mutable] \
                             annotations [pak::nfield $stmt annotations]] \
                {0 0}]
        }
        assign {
            lappend out [list node Assign \
                [dict create target [pak::nfield $stmt target] \
                             value [list node Ident [dict create name [pak::Lit $retname] \
                                                                  type_args [pak::Seq {}]] {0 0}] \
                             op [pak::Lit "="]] \
                {0 0}]
        }
    }
    return $out
}

proc pak::_inline_rewrite_stmts {stmts table} {
    set out {}
    foreach s $stmts {
        set expansion [pak::_inline_try_expand $s $table]
        if {[llength $expansion] > 0} {
            foreach e $expansion { lappend out $e }
        } else {
            lappend out [pak::_inline_rewrite_node $s $table]
        }
    }
    return $out
}

proc pak::_inline_rewrite_node {tv table} {
    if {[pak::kindof $tv] eq ""} {
        if {[llength $tv] >= 1 && [lindex $tv 0] eq "seq"} {
            set out {}
            foreach item [lindex $tv 1] { lappend out [pak::_inline_rewrite_node $item $table] }
            return [list seq $out]
        }
        return $tv
    }
    set kind [pak::kindof $tv]
    if {$kind eq "Block"} {
        set new_stmts [pak::_inline_rewrite_stmts [pak::items [pak::nfield $tv stmts]] $table]
        return [list node Block [dict create stmts [list seq $new_stmts]] [pak::nodepos $tv]]
    }
    set fields [dict get $::pak::SCHEMA $kind]
    set args {}
    foreach f $fields {
        lappend args $f [pak::_inline_rewrite_node [pak::nfield $tv $f] $table]
    }
    return [list node $kind [dict create {*}$args] [pak::nodepos $tv]]
}

# Entry point: returns a new Program with eligible call-site statements
# (in every function/method/entry body, including inside nested blocks)
# expanded in place. Called once by pak::mips_generate_records, so it
# never affects the C or RSP backends.
proc pak::inline_program {program} {
    set table [pak::_inline_build_table $program]
    if {[dict size $table] == 0} { return $program }
    return [pak::_inline_rewrite_node $program $table]
}
