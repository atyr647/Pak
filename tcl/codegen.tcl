# tcl/codegen.tcl — Pak → C code generator, Tcl port of pak/codegen.py (incremental).
#
# Emits C byte-identical to the Python backend, verified per-file against
# `pak explain` via tcl/tools/cg_parity.sh. The port is incremental: any
# construct, module-API lambda, or builtin method not yet handled raises
# CodegenError, so the harness reports that file as UNPORTED rather than
# emitting wrong C (mirroring how the parser reports unported constructs).
#
# Concision idioms match the rest of the port: pak::kindof dispatch, pak::nfield
# / pak::fval reads, pak::items for seq fields.

set _cghere [file dirname [file normalize [info script]]]
source [file join $_cghere ast.tcl]
source [file join $_cghere cg_tables.tcl]

namespace eval pak {}

# Include guard (reachable via multiple consumers; see ast.tcl).
if {[info exists ::pak::_codegen_loaded]} { return }
set ::pak::_codegen_loaded 1

# Raised for any construct not yet ported. The harness treats it as UNPORTED.
proc pak::cg_unported {what} { return -code error "CGUNPORTED\t$what" }

# Remove one layer of matching outer parens (mirrors codegen._strip_parens).
proc pak::strip_parens {s} {
    if {[string length $s] >= 2 && [string index $s 0] eq "(" && [string index $s end] eq ")"} {
        set depth 0
        set n [string length $s]
        for {set i 0} {$i < $n} {incr i} {
            set ch [string index $s $i]
            if {$ch eq "("} { incr depth } elseif {$ch eq ")"} { incr depth -1 }
            if {$depth == 0 && $i < $n - 1} { return $s }
        }
        return [string range $s 1 end-1]
    }
    return $s
}

set ::pak::CG_FIXSHIFT [dict create fix16.16 16 fix10.5 5 fix1.15 15]
proc pak::cg_fixshift {typ} {
    if {[pak::kindof $typ] eq "TypeName"} {
        set n [pak::fval $typ name]
        if {[dict exists $::pak::CG_FIXSHIFT $n]} { return [dict get $::pak::CG_FIXSHIFT $n] }
    }
    return 0
}

oo::class create pak::Codegen {
    variable filename uses assets module_name fn_names enum_variants variant_types \
             struct_fields scopes method_registry trait_decls const_values \
             generic_fns generic_structs module_headers

    constructor {{fname "<unknown>"} {mod_headers {}}} {
        set filename $fname
        set uses {}
        set assets {}
        set module_name ""
        set fn_names {}
        set enum_variants [dict create]
        set variant_types [dict create]
        set struct_fields [dict create]
        set scopes [list [dict create]]
        set method_registry [dict create]
        set trait_decls [dict create]
        set const_values [dict create]
        set generic_fns [dict create]
        set generic_structs [dict create]
        set module_headers $mod_headers
    }

    # ── scope helpers ─────────────────────────────────────────────────────────
    method scope_push {} { lappend scopes [dict create] }
    method scope_pop {}  { set scopes [lrange $scopes 0 end-1] }
    method scope_set {name typ} {
        set f [lindex $scopes end]; dict set f $name $typ; lset scopes end $f
    }
    method scope_get {name} {
        for {set i [expr {[llength $scopes]-1}]} {$i >= 0} {incr i -1} {
            set f [lindex $scopes $i]
            if {[dict exists $f $name]} { return [dict get $f $name] }
        }
        return ""
    }
    method is_pointer {name} { return [expr {[pak::kindof [my scope_get $name]] eq "TypePointer"}] }

    method expr_type {e} {
        switch -- [pak::kindof $e] {
            Ident { return [my scope_get [pak::fval $e name]] }
            DotAccess {
                set obj [pak::nfield $e obj]
                if {[pak::kindof $obj] eq "Ident"} {
                    set ot [my scope_get [pak::fval $obj name]]
                    set sname ""
                    if {[pak::kindof $ot] eq "TypeName"} {
                        set sname [pak::fval $ot name]
                    } elseif {[pak::kindof $ot] eq "TypePointer" && [pak::kindof [pak::nfield $ot inner]] eq "TypeName"} {
                        set sname [pak::fval [pak::nfield $ot inner] name]
                    }
                    if {$sname ne "" && [dict exists $struct_fields $sname]} {
                        set fields [dict get $struct_fields $sname]
                        set fld [pak::fval $e field]
                        if {[dict exists $fields $fld]} { return [dict get $fields $fld] }
                    }
                }
            }
        }
        return ""
    }

    # ── types ─────────────────────────────────────────────────────────────────
    method gen_type {t} {
        if {[pak::isnil $t]} { return "void" }
        switch -- [pak::kindof $t] {
            TypeName {
                set n [pak::fval $t name]
                if {[dict exists $struct_fields $n] || [dict exists $variant_types $n] \
                        || $n in [dict values $enum_variants]} { return $n }
                if {[dict exists $::pak::CG_PRIM $n]} { return [dict get $::pak::CG_PRIM $n] }
                return $n
            }
            TypePointer {
                set inner [pak::nfield $t inner]
                if {[pak::kindof $inner] eq "TypeDynTrait"} { return [pak::fval $inner name] }
                return "[my gen_type $inner] *"
            }
            TypeArray {
                return "[my gen_type [pak::nfield $t inner]]\[[my gen_expr [pak::nfield $t size]]\]"
            }
            TypeOption { return "[my gen_type [pak::nfield $t inner]] *" }
            TypeDynTrait { return [pak::fval $t name] }
            TypeVolatile { return "volatile [my gen_type [pak::nfield $t inner]]" }
            default { pak::cg_unported "type:[pak::kindof $t]" }
        }
    }

    method gen_array_decl {name t} {
        if {[pak::kindof $t] eq "TypeArray"} {
            return "[my gen_type [pak::nfield $t inner]] $name\[[my gen_expr [pak::nfield $t size]]\]"
        }
        return "[my gen_type $t] $name"
    }

    # ── expressions ───────────────────────────────────────────────────────────
    method gen_expr {e} {
        if {[pak::isnil $e]} { return "" }
        switch -- [pak::kindof $e] {
            IntLit {
                set raw [pak::fval $e raw]
                if {$raw ne ""} { return $raw }
                return [pak::fval $e value]
            }
            FloatLit  { return "[pak::sval [pak::nfield $e value]]f" }
            BoolLit   { return [expr {[pak::fval $e value] ? "true" : "false"}] }
            StringLit {
                set v [pak::fval $e value]
                set v [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n"] $v]
                return "\"$v\""
            }
            NoneLit      { return "NULL" }
            UndefinedLit { return "/* undefined */" }
            Ident        { return [pak::fval $e name] }
            DotAccess    { return [my gen_dot $e] }
            IndexAccess {
                set obj [my gen_expr [pak::nfield $e obj]]
                set ot [my expr_type [pak::nfield $e obj]]
                set idx [my gen_expr [pak::nfield $e index]]
                if {[pak::kindof $ot] eq "TypeSlice"} { return "($obj).data\[$idx\]" }
                return "$obj\[$idx\]"
            }
            Call      { return [my gen_call $e] }
            StructLit {
                set parts {}
                foreach pair [pak::items [pak::nfield $e fields]] {
                    set p [pak::items $pair]
                    lappend parts ".[pak::sval [lindex $p 0]] = [my gen_expr [lindex $p 1]]"
                }
                return "([pak::fval $e type_name]){[join $parts {, }]}"
            }
            ArrayLit  { return [my gen_array_lit $e] }
            UnaryOp {
                set op [pak::fval $e op]
                return "$op[my gen_expr [pak::nfield $e operand]]"
            }
            BinaryOp {
                set left [my gen_expr [pak::nfield $e left]]
                set right [my gen_expr [pak::nfield $e right]]
                set op [pak::fval $e op]
                set shift [pak::cg_fixshift [my expr_type [pak::nfield $e left]]]
                if {$shift == 0} { set shift [pak::cg_fixshift [my expr_type [pak::nfield $e right]]] }
                if {$shift != 0 && $op eq "*"} {
                    return "(int32_t)(((int64_t)($left) * ($right)) >> $shift)"
                }
                if {$shift != 0 && $op eq "/"} {
                    return "(int32_t)(((int64_t)($left) << $shift) / ($right))"
                }
                return "($left $op $right)"
            }
            Assign {
                return "[my gen_expr [pak::nfield $e target]] [pak::fval $e op] [my gen_expr [pak::nfield $e value]]"
            }
            AddrOf { return "&[my gen_expr [pak::nfield $e expr]]" }
            Deref  { return "*[my gen_expr [pak::nfield $e expr]]" }
            Cast   { return "([my gen_type [pak::nfield $e type]])[my gen_expr [pak::nfield $e expr]]" }
            NamedArg { return [my gen_expr [pak::nfield $e value]] }
            EnumVariantAccess {
                set n [pak::fval $e name]
                if {[dict exists $enum_variants $n]} { return "[dict get $enum_variants $n]_$n" }
                return $n
            }
            TupleAccess { return "([my gen_expr [pak::nfield $e obj]]).f[pak::fval $e index]" }
            SizeOf {
                set op [pak::nfield $e operand]
                if {[pak::kindof $op] in {TypeName TypePointer TypeArray TypeSlice TypeResult TypeGeneric TypeVolatile}} {
                    return "sizeof([my gen_type $op])"
                }
                return "sizeof([my gen_expr $op])"
            }
            OffsetOf { return "offsetof([pak::fval $e type_name], [pak::fval $e field])" }
            default { pak::cg_unported "expr:[pak::kindof $e]" }
        }
    }

    method gen_dot {e} {
        set obj [pak::nfield $e obj]
        set obj_str [my gen_expr $obj]
        set field [pak::fval $e field]
        if {[pak::kindof $obj] eq "Ident"} {
            set n [pak::fval $obj name]
            if {$n in [dict values $enum_variants]} { return "${obj_str}_$field" }
            if {[dict exists $enum_variants $field]} { return "${obj_str}_$field" }
            if {[dict exists $::pak::CG_API [list $n $field]] || [dict exists $::pak::CG_API_LAMBDA [list $n $field]]} {
                return "${obj_str}.$field"
            }
            if {[my is_pointer $n]} { return "${obj_str}->$field" }
        }
        return "${obj_str}.$field"
    }

    method gen_array_lit {e} {
        set repeat [pak::nfield $e repeat]
        set elems [pak::items [pak::nfield $e elements]]
        if {![pak::isnil $repeat]} {
            if {[llength $elems] > 0} { set val [my gen_expr [lindex $elems 0]] } else { set val "0" }
            if {$val in {0 false NULL 0.0f 0.0}} { return "{0}" }
            if {[pak::kindof $repeat] eq "IntLit" && [pak::fval $repeat value] <= 64} {
                set n [pak::fval $repeat value]
                set lst {}
                for {set i 0} {$i < $n} {incr i} { lappend lst $val }
                return "{[join $lst {, }]}"
            }
            return "{0}"
        }
        set parts {}
        foreach el $elems { lappend parts [my gen_expr $el] }
        return "{[join $parts {, }]}"
    }

    method gen_call {e} {
        set args {}
        foreach a [pak::items [pak::nfield $e args]] { lappend args [my gen_expr $a] }
        set func [pak::nfield $e func]
        # module API: mod.fn(args)
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set mod [pak::fval [pak::nfield $func obj] name]
            set fn [pak::fval $func field]
            set key [list $mod $fn]
            # builtin / static type methods + method-registry dispatch not yet ported:
            # only fall through to those when this isn't a known module-API call.
            if {[dict exists $::pak::CG_API $key]} {
                return "[dict get $::pak::CG_API $key]([join $args {, }])"
            }
            if {[dict exists $::pak::CG_API_LAMBDA $key]} {
                return [pak::cg_api_lambda $mod $fn $args]
            }
            # could be a struct method / builtin method / enum access — not yet ported
            if {[my scope_get $mod] ne "" || [dict exists $method_registry $mod]} {
                pak::cg_unported "call:method-or-builtin"
            }
        }
        if {[pak::kindof $func] eq "Ident"} {
            set fname [pak::fval $func name]
            if {[dict exists $generic_fns $fname]} { pak::cg_unported "call:generic" }
            if {$fname in {comptime_assert heap_allocator arena_allocator}} { pak::cg_unported "call:builtin-fn" }
        }
        return "[my gen_expr $func]([join $args {, }])"
    }

    # ── statements ────────────────────────────────────────────────────────────
    method gen_stmt {stmt indent} {
        set pad [string repeat "    " $indent]
        switch -- [pak::kindof $stmt] {
            LetDecl    { return [my gen_let_stmt $stmt $pad] }
            StaticDecl { return [my gen_static_stmt $stmt $pad] }
            Return {
                set v [pak::nfield $stmt value]
                if {[pak::isnil $v]} { return "${pad}return;" }
                return "${pad}return [my gen_expr $v];"
            }
            Break    { return "${pad}break;" }
            Continue { return "${pad}continue;" }
            GotoStmt { return "${pad}goto [pak::fval $stmt label];" }
            LabelStmt {
                set lp [expr {[string length $pad] >= 4 ? [string range $pad 4 end] : ""}]
                return "${lp}[pak::fval $stmt name]:"
            }
            ExprStmt {
                set ex [pak::nfield $stmt expr]
                if {[pak::kindof $ex] eq "CatchExpr"} { pak::cg_unported "stmt:catch" }
                return "${pad}[my gen_expr $ex];"
            }
            IfStmt    { return [my gen_if $stmt $pad $indent] }
            LoopStmt  { return [my gen_loop $stmt $pad $indent] }
            WhileStmt { return [my gen_while $stmt $pad $indent] }
            Block     { return [my gen_block_inline $stmt $pad $indent] }
            ConstDecl { return [my gen_const $stmt] }
            AsmStmt {
                set parts {}
                foreach ln [pak::items [pak::nfield $stmt lines]] { lappend parts "\"[pak::sval $ln]\\n\\t\"" }
                set vol [expr {[pak::fval $stmt volatile] ? "__volatile__" : ""}]
                return "${pad}__asm__ ${vol}([join $parts { }]);"
            }
            DoWhileStmt {
                set body {}
                foreach s [pak::items [pak::nfield [pak::nfield $stmt body] stmts]] {
                    set r [my gen_stmt $s [expr {$indent+1}]]
                    if {$r ne ""} { lappend body $r }
                }
                set cond [my gen_expr [pak::nfield $stmt condition]]
                return "${pad}do {\n[join $body \n]\n${pad}} while ($cond);"
            }
            DeferStmt   { pak::cg_unported "stmt:defer" }
            ForStmt     { pak::cg_unported "stmt:for" }
            MatchStmt   { pak::cg_unported "stmt:match" }
            NullCheckStmt { pak::cg_unported "stmt:nullcheck" }
            StructDecl  { return [my gen_struct $stmt] }
            EnumDecl    { return [my gen_enum $stmt] }
            VariantDecl { pak::cg_unported "stmt:variant" }
            UnionDecl   { return [my gen_union $stmt] }
            ComptimeIf  { pak::cg_unported "stmt:comptime-if" }
            default     { pak::cg_unported "stmt:[pak::kindof $stmt]" }
        }
    }

    method gen_let_stmt {s pad} {
        set anns [pak::annlist_or $s]
        if {[llength $anns] > 0} { pak::cg_unported "let:annotations" }
        set typ [pak::nfield $s type]
        set name [pak::fval $s name]
        if {![pak::isnil $typ]} {
            set decl [my gen_array_decl $name $typ]
            my scope_set $name $typ
        } else {
            set decl "__auto_type $name"
            if {[pak::kindof [pak::nfield $s value]] eq "AddrOf"} {
                my scope_set $name [pak::N TypePointer inner [pak::N TypeName name auto] nullable 0 mutable 0]
            }
        }
        set val [pak::nfield $s value]
        if {![pak::isnil $val] && [pak::kindof $val] ne "UndefinedLit"} {
            if {[pak::kindof $val] eq "CatchExpr"} { pak::cg_unported "let:catch" }
            if {[pak::kindof $val] eq "ArrayLit" && ![pak::isnil [pak::nfield $val repeat]]} {
                set rep [pak::nfield $val repeat]
                set elems [pak::items [pak::nfield $val elements]]
                if {[llength $elems] > 0} { set v [my gen_expr [lindex $elems 0]] } else { set v 0 }
                set zero [expr {$v in {0 false NULL 0.0f 0.0}}]
                set small [expr {[pak::kindof $rep] eq "IntLit" && [pak::fval $rep value] <= 64}]
                if {$zero || $small} { return "${pad}${decl} = [my gen_expr $val];" }
                set count [my gen_expr $rep]
                return "${pad}${decl} = {0};\n${pad}for (int _fi = 0; _fi < (int)($count); _fi++) $name\[_fi\] = $v;"
            }
            if {[pak::kindof $val] in {OkExpr ErrExpr}} { pak::cg_unported "let:result" }
            return "${pad}${decl} = [my gen_expr $val];"
        } elseif {[pak::kindof $val] eq "UndefinedLit"} {
            return "${pad}${decl}; /* undefined */"
        }
        return "${pad}${decl};"
    }

    method gen_static_stmt {s pad} {
        set anns [pak::annlist_or $s]
        if {[llength $anns] > 0} { pak::cg_unported "static:annotations" }
        set typ [pak::nfield $s type]
        if {![pak::isnil $typ]} { set decl [my gen_array_decl [pak::fval $s name] $typ] } \
        else { set decl "__auto_type [pak::fval $s name]" }
        set val [pak::nfield $s value]
        if {![pak::isnil $val] && [pak::kindof $val] ne "UndefinedLit"} {
            return "${pad}static $decl = [my gen_expr $val];"
        }
        return "${pad}static $decl;"
    }

    method gen_if {s pad indent} {
        set cond [pak::strip_parens [my gen_expr [pak::nfield $s condition]]]
        set lines [list "${pad}if ($cond) {"]
        my scope_push
        foreach st [pak::items [pak::nfield [pak::nfield $s then] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        my scope_pop
        lappend lines "${pad}}"
        foreach pair [pak::items [pak::nfield $s elif_branches]] {
            set p [pak::items $pair]
            lappend lines "${pad}else if ([pak::strip_parens [my gen_expr [lindex $p 0]]]) {"
            my scope_push
            foreach st [pak::items [pak::nfield [lindex $p 1] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
            my scope_pop
            lappend lines "${pad}}"
        }
        set eb [pak::nfield $s else_branch]
        if {![pak::isnil $eb]} {
            lappend lines "${pad}else {"
            my scope_push
            foreach st [pak::items [pak::nfield $eb stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
            my scope_pop
            lappend lines "${pad}}"
        }
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_loop {s pad indent} {
        set lines [list "${pad}while (true) {"]
        my scope_push
        foreach st [pak::items [pak::nfield [pak::nfield $s body] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        my scope_pop
        lappend lines "${pad}}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_while {s pad indent} {
        set cond [pak::strip_parens [my gen_expr [pak::nfield $s condition]]]
        set lines [list "${pad}while ($cond) {"]
        my scope_push
        foreach st [pak::items [pak::nfield [pak::nfield $s body] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        my scope_pop
        lappend lines "${pad}}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_block_inline {block pad indent} {
        set lines [list "${pad}{"]
        foreach st [pak::items [pak::nfield $block stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        lappend lines "${pad}}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    # ── declarations ──────────────────────────────────────────────────────────
    method gen_decl {decl} {
        switch -- [pak::kindof $decl] {
            StructDecl  { return [my gen_struct $decl] }
            EnumDecl    { return [my gen_enum $decl] }
            UnionDecl   { return [my gen_union $decl] }
            FnDecl {
                if {[llength [pak::items [pak::nfield $decl type_params]]] > 0} { return "" }
                return [my gen_fn $decl ""]
            }
            EntryBlock  { return [my gen_entry $decl] }
            ConstDecl   { return [my gen_const $decl] }
            ExternConst { return [my gen_extern_const $decl] }
            VariantDecl { pak::cg_unported "decl:variant" }
            ImplBlock - ImplTraitBlock - TraitDecl { pak::cg_unported "decl:impl/trait" }
            ExternBlock { return [my gen_extern $decl] }
            StaticDecl  { return [my gen_static_global $decl] }
            LetDecl     { return [my gen_let_global $decl] }
            CfgBlock    { pak::cg_unported "decl:cfg" }
            ComptimeIf  { pak::cg_unported "decl:comptime-if" }
            default     { pak::cg_unported "decl:[pak::kindof $decl]" }
        }
    }

    method gen_struct {s} {
        if {[llength [pak::annlist_or $s]] > 0} { pak::cg_unported "struct:annotations" }
        set lines [list "typedef struct {"]
        foreach field [pak::items [pak::nfield $s fields]] {
            set bw [pak::nfield $field bit_width]
            if {![pak::isnil $bw]} {
                lappend lines "    [my gen_type [pak::nfield $field type]] [pak::fval $field name] : [pak::sval $bw];"
            } else {
                lappend lines "    [my gen_array_decl [pak::fval $field name] [pak::nfield $field type]];"
            }
        }
        lappend lines "} [pak::fval $s name];"
        return [join $lines \n]
    }

    method gen_union {u} {
        set lines [list "typedef union {"]
        foreach field [pak::items [pak::nfield $u fields]] {
            lappend lines "    [my gen_array_decl [pak::fval $field name] [pak::nfield $field type]];"
        }
        lappend lines "} [pak::fval $u name];"
        return [join $lines \n]
    }

    method gen_enum {e} {
        set lines [list "typedef enum {"]
        foreach v [pak::items [pak::nfield $e variants]] {
            set val [pak::nfield $v value]
            if {![pak::isnil $val]} {
                lappend lines "    [pak::fval $e name]_[pak::fval $v name] = [my gen_expr $val],"
            } else {
                lappend lines "    [pak::fval $e name]_[pak::fval $v name],"
            }
        }
        lappend lines "} [pak::fval $e name];"
        return [join $lines \n]
    }

    method gen_const {c} {
        set val [my gen_expr [pak::nfield $c value]]
        set typ [pak::nfield $c type]
        if {![pak::isnil $typ]} {
            set ct [my gen_type $typ]
            if {$ct in {int32_t uint32_t int int16_t uint16_t int8_t uint8_t int64_t uint64_t}} {
                return "enum { [pak::fval $c name] = $val };"
            }
            return "static const $ct [pak::fval $c name] = $val;"
        }
        return "enum { [pak::fval $c name] = $val };"
    }

    method gen_extern_const {e} {
        return "/* extern const [my gen_type [pak::nfield $e type]] [pak::fval $e name]; (C macro passthrough) */"
    }

    method gen_extern {ext} {
        set lines [list "/* extern \"[pak::fval $ext abi]\" */"]
        foreach decl [pak::items [pak::nfield $ext decls]] { lappend lines [my gen_fn $decl ""] }
        return [join $lines \n]
    }

    # extract N from an @aligned(N) annotation string
    method aligned_n {anns} {
        foreach a $anns {
            if {[string match "@aligned(*" $a]} {
                return [string range $a [expr {[string first ( $a]+1}] [expr {[string first ) $a]-1}]]
            }
        }
        return ""
    }

    method gen_static_global {s} {
        set anns [pak::annlist_or $s]
        if {"@uncached" in $anns} { pak::cg_unported "static:uncached" }
        set typ [pak::nfield $s type]
        if {![pak::isnil $typ]} { set decl [my gen_array_decl [pak::fval $s name] $typ] } \
        else { set decl "__auto_type [pak::fval $s name]" }
        set n [my aligned_n $anns]
        if {$n ne ""} { set decl "__attribute__((aligned($n))) $decl" }
        set val [pak::nfield $s value]
        if {![pak::isnil $val] && [pak::kindof $val] ne "UndefinedLit"} {
            return "static $decl = [my gen_expr $val];"
        }
        return "static $decl;"
    }

    method gen_let_global {s} {
        set typ [pak::nfield $s type]
        if {![pak::isnil $typ]} { set decl [my gen_array_decl [pak::fval $s name] $typ] } \
        else { set decl "__auto_type [pak::fval $s name]" }
        set val [pak::nfield $s value]
        if {![pak::isnil $val] && [pak::kindof $val] ne "UndefinedLit"} {
            return "$decl = [my gen_expr $val];"
        }
        return "$decl;"
    }

    method gen_fn {fn prefix} {
        set anns [pak::annlist_or $fn]
        if {[llength $anns] > 0} { pak::cg_unported "fn:annotations" }
        if {[pak::fval $fn variadic]} { pak::cg_unported "fn:variadic" }
        set ret [my gen_type [pak::nfield $fn ret_type]]
        set params {}
        foreach p [pak::items [pak::nfield $fn params]] {
            set pt [pak::nfield $p type]
            if {[pak::kindof $pt] eq "TypeArray"} {
                lappend params [my gen_array_decl [pak::fval $p name] $pt]
            } else {
                lappend params "[my gen_type $pt] [pak::fval $p name]"
            }
        }
        if {[llength $params] > 0} { set param_str [join $params {, }] } else { set param_str "void" }
        set name [pak::fval $fn name]
        if {$prefix ne ""} { set name "${prefix}_$name" }
        set body [pak::nfield $fn body]
        if {[pak::isnil $body]} { return "$ret ${name}($param_str);" }
        set lines [list "$ret ${name}($param_str) {"]
        my scope_push
        foreach p [pak::items [pak::nfield $fn params]] { my scope_set [pak::fval $p name] [pak::nfield $p type] }
        foreach st [pak::items [pak::nfield $body stmts]] {
            set s [my gen_stmt $st 1]
            if {$s ne ""} { lappend lines $s }
        }
        my scope_pop
        lappend lines "}"
        return [join $lines \n]
    }

    method gen_entry {entry} {
        set lines [list "int main(void) {"]
        my scope_push
        foreach st [pak::items [pak::nfield [pak::nfield $entry body] stmts]] {
            set s [my gen_stmt $st 1]
            if {$s ne ""} { lappend lines $s }
        }
        my scope_pop
        lappend lines "    return 0;"
        lappend lines "}"
        return [join $lines \n]
    }

    # ── program (preamble + body assembly) ────────────────────────────────────
    method gen_program {program} {
        set decls [pak::items [pak::nfield $program decls]]
        # pass 1: collect declarations
        foreach decl $decls {
            switch -- [pak::kindof $decl] {
                UseDecl { lappend uses [pak::fval $decl path] }
                AssetDecl { lappend assets $decl }
                ModuleDecl { set module_name [pak::fval $decl path] }
                FnDecl {
                    lappend fn_names [pak::fval $decl name]
                    if {[llength [pak::items [pak::nfield $decl type_params]]] > 0} {
                        dict set generic_fns [pak::fval $decl name] $decl
                    }
                    if {[pak::fval $decl is_method] && ![pak::isnil [pak::nfield $decl self_type]]} {
                        set tname [pak::sval [pak::nfield $decl self_type]]
                        dict set method_registry $tname [pak::fval $decl name] $decl
                    }
                }
                StructDecl - UnionDecl {
                    set fmap [dict create]
                    foreach f [pak::items [pak::nfield $decl fields]] {
                        dict set fmap [pak::fval $f name] [pak::nfield $f type]
                    }
                    dict set struct_fields [pak::fval $decl name] $fmap
                    if {[pak::kindof $decl] eq "StructDecl" && [llength [pak::items [pak::nfield $decl type_params]]] > 0} {
                        dict set generic_structs [pak::fval $decl name] $decl
                    }
                }
                EnumDecl {
                    foreach v [pak::items [pak::nfield $decl variants]] {
                        dict set enum_variants [pak::fval $v name] [pak::fval $decl name]
                    }
                }
                VariantDecl {
                    dict set variant_types [pak::fval $decl name] 1
                    foreach c [pak::items [pak::nfield $decl cases]] {
                        dict set enum_variants [pak::fval $c name] [pak::fval $decl name]
                    }
                }
                ImplBlock - ImplTraitBlock {
                    set tname [pak::fval $decl type_name]
                    foreach m [pak::items [pak::nfield $decl methods]] {
                        dict set method_registry $tname [pak::fval $m name] $m
                    }
                }
                TraitDecl { dict set trait_decls [pak::fval $decl name] $decl }
                ConstDecl { dict set const_values [pak::fval $decl name] [my gen_expr [pak::nfield $decl value]] }
                CfgBlock  { pak::cg_unported "program:cfg-collect" }
            }
        }

        set out {}
        lappend out "/* Generated by Pak Compiler - $filename */"
        lappend out ""
        lappend out "#include <libdragon.h>"
        lappend out "#include <stdint.h>"
        lappend out "#include <stdbool.h>"
        lappend out "#include <string.h>"
        lappend out "#include <math.h>"
        lappend out "#include \"pak_math.h\""
        lappend out "#include \"pak_containers.h\""

        set seen [dict create]
        foreach use_path $uses {
            if {[dict exists $::pak::CG_USE_INCLUDES $use_path]} {
                set inc [dict get $::pak::CG_USE_INCLUDES $use_path]
                if {$inc ne "" && ![dict exists $seen $inc]} { lappend out $inc; dict set seen $inc 1 }
            } elseif {[dict exists $module_headers $use_path]} {
                set hl "#include \"[dict get $module_headers $use_path]\""
                if {![dict exists $seen $hl]} { lappend out $hl; dict set seen $hl 1 }
            }
        }

        if {[llength $assets] > 0} { lappend out "#include <pakfs.h>" }

        if {"n64.timer" in $uses} {
            lappend out ""
            lappend out "static uint32_t _pak_last_tick = 0;"
            lappend out "static inline float _pak_delta_time(void) {"
            lappend out "    uint32_t now = TICKS_READ();"
            lappend out "    float dt = (float)TIMER_MICROS(now - _pak_last_tick) / 1000000.0f;"
            lappend out "    _pak_last_tick = now;"
            lappend out "    return dt;"
            lappend out "}"
        }

        lappend out ""

        foreach asset $assets {
            lappend out "/* asset: [pak::fval $asset name] from \"[pak::fval $asset path]\" */"
            lappend out "static const char *[pak::fval $asset name]_path = \"pak:/[pak::fval $asset path]\";"
        }
        if {[llength $assets] > 0} { lappend out "" }

        # body (generated before preamble runtime types are appended, matching Python)
        set body {}
        foreach decl $decls {
            if {[pak::kindof $decl] in {UseDecl AssetDecl ModuleDecl}} continue
            set r [my gen_decl $decl]
            if {$r ne ""} { lappend body $r; lappend body "" }
        }

        lappend out ""
        lappend out "/* -- Pak runtime types -- */"
        lappend out "typedef struct { const char *data; int32_t len; } PakStr;"
        lappend out "typedef struct { uint8_t *base; uint8_t *ptr; size_t capacity; } PakArena;"
        lappend out "static inline PakStr pak_str_from_cstr(const char *s) {"
        lappend out "    return (PakStr){ .data = s, .len = (int32_t)strlen(s) }; }"
        lappend out "static inline bool pak_str_eq(PakStr a, PakStr b) {"
        lappend out "    return a.len == b.len && memcmp(a.data, b.data, (size_t)a.len) == 0; }"
        lappend out "static inline void *pak_arena_alloc(PakArena *a, size_t sz) {"
        lappend out "    sz = (sz + 7) & ~(size_t)7;  /* 8-byte align */"
        lappend out "    if (a->ptr + sz > a->base + a->capacity) return NULL;"
        lappend out "    void *p = a->ptr; a->ptr += sz; return p; }"
        lappend out "static inline void pak_arena_reset(PakArena *a) { a->ptr = a->base; }"

        foreach b $body { lappend out $b }
        return [join $out \n]
    }
}

# ── module-API lambda lowering (hand-ported subset; raises for the rest) ───────
# Param is named `arglist` deliberately: a proc parameter literally named `args`
# is Tcl's variadic collector, which would re-wrap the passed list one level deep.
proc pak::cg_api_lambda {mod fn arglist} {
    switch -- "$mod $fn" {
        "controller read" {
            if {[llength $arglist] > 0} { return "joypad_get_status([lindex $arglist 0])" }
            return "joypad_get_status(0)"
        }
        "sprite blit" {
            if {[llength $arglist] >= 3} {
                return "rdpq_sprite_blit([lindex $arglist 0], [lindex $arglist 1], [lindex $arglist 2], NULL)"
            }
            return "rdpq_sprite_blit([join $arglist {, }], NULL)"
        }
        "timer delta" { return "_pak_delta_time()" }
        default { pak::cg_unported "api-lambda:$mod $fn" }
    }
}

# annotations list, or {} if the node has no annotations field (helper for cg).
proc pak::annlist_or {node} {
    set k [pak::kindof $node]
    if {$k eq "" || [lsearch -exact [dict get $::pak::SCHEMA $k] annotations] < 0} { return {} }
    set out {}
    foreach a [pak::items [pak::nfield $node annotations]] { lappend out [pak::sval $a] }
    return $out
}

# ── public entry ───────────────────────────────────────────────────────────────
proc pak::generate {program {filename "<unknown>"} {module_headers {}}} {
    set cg [pak::Codegen new $filename $module_headers]
    set out [$cg gen_program $program]
    $cg destroy
    return $out
}
