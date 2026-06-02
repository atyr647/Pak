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

# Mirror codegen._NUMERIC_CAST_METHODS / _FIXPOINT_CAST / _VEC*_INSTANCE / _MAT4_INSTANCE
set ::pak::CG_NUMERIC_CAST [dict create \
    as_i8 int8_t as_i16 int16_t as_i32 int32_t as_i64 int64_t \
    as_u8 uint8_t as_u16 uint16_t as_u32 uint32_t as_u64 uint64_t \
    as_f32 float as_f64 double as_bool bool as_byte uint8_t]
set ::pak::CG_FIXPOINT_CAST [dict create \
    as_fix16_16 {(int32_t)((%VAL%) * 65536.0f)} \
    as_fix10_5  {(int16_t)((%VAL%) * 32.0f)} \
    as_fix1_15  {(int16_t)((%VAL%) * 32768.0f)}]
set ::pak::CG_VEC3_INSTANCE [dict create \
    add          {pak_vec3_add(%OBJ%, %A0%)} \
    sub          {pak_vec3_sub(%OBJ%, %A0%)} \
    scale        {pak_vec3_scale(%OBJ%, %A0%)} \
    normalize    {pak_vec3_normalize(%OBJ%)} \
    length       {pak_vec3_length(%OBJ%)} \
    dot          {pak_vec3_dot(%OBJ%, %A0%)} \
    cross        {pak_vec3_cross(%OBJ%, %A0%)} \
    distance_to  {pak_vec3_distance(%OBJ%, %A0%)} \
    direction_to {pak_vec3_direction(%OBJ%, %A0%)} \
    negate       {pak_vec3_scale(%OBJ%, -1.0f)}]
set ::pak::CG_VEC2_INSTANCE [dict create \
    add    {pak_vec2_add(%OBJ%, %A0%)} \
    sub    {pak_vec2_sub(%OBJ%, %A0%)} \
    scale  {pak_vec2_scale(%OBJ%, %A0%)} \
    length {pak_vec2_length(%OBJ%)}]
set ::pak::CG_MAT4_INSTANCE [dict create \
    rotate_y     {pak_mat4_rotate_y(&(%OBJ%), %A0%)} \
    rotate_x     {pak_mat4_rotate_x(&(%OBJ%), %A0%)} \
    rotate_z     {pak_mat4_rotate_z(&(%OBJ%), %A0%)} \
    set_position {pak_mat4_set_position(&(%OBJ%), %A0%)} \
    translate    {pak_mat4_translate(&(%OBJ%), %A0%, %A1%, %A2%)} \
    scale        {pak_mat4_scale_uniform(&(%OBJ%), %A0%)} \
    to_fixed     {t3d_mat4_to_fixed(%A0%, &(%OBJ%))} \
    as_t3d       {pak_mat4_to_fp_alloc(&(%OBJ%))} \
    identity     {t3d_mat4_identity(&(%OBJ%))}]
proc pak::cg_fixshift {typ} {
    if {[pak::kindof $typ] eq "TypeName"} {
        set n [pak::fval $typ name]
        if {[dict exists $::pak::CG_FIXSHIFT $n]} { return [dict get $::pak::CG_FIXSHIFT $n] }
    }
    return 0
}

# Substitute type-param names in a type tree (mirror codegen._subst_type).
# `subst` maps a type-param name to its concrete type-arg value (a bare scalar
# like "i32", matching Python which stores the raw type_arg string).
proc pak::cg_subst_type {t subst} {
    if {[pak::isnil $t]} { return $t }
    if {[lindex $t 0] ne "node"} { return $t }
    switch -- [pak::kindof $t] {
        TypeParam {
            set n [pak::fval $t name]
            if {[dict exists $subst $n]} { return [dict get $subst $n] }
            return $t
        }
        TypeName {
            set n [pak::fval $t name]
            if {[dict exists $subst $n]} { return [dict get $subst $n] }
            return $t
        }
        TypePointer  { return [pak::N TypePointer inner [pak::cg_subst_type [pak::nfield $t inner] $subst] nullable [pak::fval $t nullable] mutable [pak::fval $t mutable]] }
        TypeSlice    { return [pak::N TypeSlice inner [pak::cg_subst_type [pak::nfield $t inner] $subst] mutable [pak::fval $t mutable]] }
        TypeArray    { return [pak::N TypeArray inner [pak::cg_subst_type [pak::nfield $t inner] $subst] size [pak::nfield $t size]] }
        TypeResult   { return [pak::N TypeResult ok [pak::cg_subst_type [pak::nfield $t ok] $subst] err [pak::cg_subst_type [pak::nfield $t err] $subst]] }
        TypeOption   { return [pak::N TypeOption inner [pak::cg_subst_type [pak::nfield $t inner] $subst]] }
        TypeGeneric  {
            set newargs {}
            foreach a [pak::items [pak::nfield $t args]] { lappend newargs [pak::cg_subst_type $a $subst] }
            return [pak::N TypeGeneric name [pak::fval $t name] args $newargs]
        }
        TypeFn {
            set newp {}
            foreach p [pak::items [pak::nfield $t params]] { lappend newp [pak::cg_subst_type $p $subst] }
            return [pak::N TypeFn params $newp ret [pak::cg_subst_type [pak::nfield $t ret] $subst]]
        }
        default { return $t }
    }
}

oo::class create pak::Codegen {
    variable filename uses assets module_name fn_names enum_variants variant_types \
             struct_fields scopes method_registry trait_decls const_values \
             generic_fns generic_structs module_headers defer_stack result_typedefs \
             result_typedef_names current_ret_type closures fmt_counter tmp_counter \
             mono_cache pending_mono

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
        set defer_stack [list {}]
        set method_registry [dict create]
        set trait_decls [dict create]
        set const_values [dict create]
        set generic_fns [dict create]
        set generic_structs [dict create]
        set module_headers $mod_headers
        set result_typedefs {}
        set result_typedef_names [dict create]
        set current_ret_type ""
        set closures {}
        set fmt_counter 0
        set tmp_counter 0
        set mono_cache [dict create]
        set pending_mono {}
    }

    # Seed enum_variants from a program (case/variant name -> type name), used
    # by headergen, mirroring the first pass of pak/headergen.generate_header.
    method seed_enums {program} {
        foreach decl [pak::items [pak::nfield $program decls]] {
            if {[pak::kindof $decl] eq "EnumDecl"} {
                foreach v [pak::items [pak::nfield $decl variants]] {
                    dict set enum_variants [pak::fval $v name] [pak::fval $decl name]
                }
            } elseif {[pak::kindof $decl] eq "VariantDecl"} {
                foreach c [pak::items [pak::nfield $decl cases]] {
                    dict set enum_variants [pak::fval $c name] [pak::fval $decl name]
                }
            }
        }
    }

    # Register (dedup) and return the C typedef name for Result(ok, err).
    method result_typedef {ok_type err_type} {
        set c_ok [expr {[pak::isnil $ok_type] ? "void *" : [my gen_type $ok_type]}]
        set c_err [expr {[pak::isnil $err_type] ? "int32_t" : [my gen_type $err_type]}]
        set safe_ok [string map {" " _ "*" p} $c_ok]
        set safe_err [string map {" " _ "*" p} $c_err]
        set tdname "PakResult_${safe_ok}_${safe_err}"
        if {![dict exists $result_typedef_names $tdname]} {
            dict set result_typedef_names $tdname 1
            lappend result_typedefs [list $tdname $c_ok $c_err]
        }
        return $tdname
    }

    # ── scope helpers ─────────────────────────────────────────────────────────
    method scope_push {} { lappend scopes [dict create]; lappend defer_stack {} }
    method scope_pop {}  { set scopes [lrange $scopes 0 end-1]; set defer_stack [lrange $defer_stack 0 end-1] }
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

    # ── defer helpers (mirror codegen._defer_* / _emit_defers_*) ───────────────
    method defer_push {stmt} {
        set frame [lindex $defer_stack end]; lappend frame $stmt; lset defer_stack end $frame
    }
    # Emit the current scope's defers (LIFO) at the given indent. Returns a list
    # of lines (empty when there are no defers, so output is unchanged otherwise).
    method emit_defers_for_scope {indent} {
        set lines {}
        set frame [lindex $defer_stack end]
        for {set i [expr {[llength $frame]-1}]} {$i >= 0} {incr i -1} {
            set d [lindex $frame $i]
            set body [pak::nfield $d body]
            if {[pak::kindof $body] eq "Block"} {
                foreach st [pak::items [pak::nfield $body stmts]] {
                    set s [my gen_stmt $st $indent]
                    if {$s ne ""} { lappend lines $s }
                }
            }
        }
        return $lines
    }
    # Emit ALL active defers (every scope, innermost first) — used before return.
    method emit_all_defers {indent} {
        set lines {}
        for {set i [expr {[llength $defer_stack]-1}]} {$i >= 0} {incr i -1} {
            set frame [lindex $defer_stack $i]
            for {set j [expr {[llength $frame]-1}]} {$j >= 0} {incr j -1} {
                set d [lindex $frame $j]
                set body [pak::nfield $d body]
                if {[pak::kindof $body] eq "Block"} {
                    foreach st [pak::items [pak::nfield $body stmts]] {
                        set s [my gen_stmt $st $indent]
                        if {$s ne ""} { lappend lines $s }
                    }
                }
            }
        }
        return $lines
    }

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
        # Substituted (monomorphized) type args are stored as bare scalars, not
        # tagged AST nodes; mirror Python's gen_type catch-all of 'void *'.
        if {[lindex $t 0] ne "node"} { return "void *" }
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
            TypeResult { return [my result_typedef [pak::nfield $t ok] [pak::nfield $t err]] }
            TypeDynTrait { return [pak::fval $t name] }
            TypeVolatile { return "volatile [my gen_type [pak::nfield $t inner]]" }
            TypeFn {
                set tret [pak::nfield $t ret]
                set rc [expr {[pak::isnil $tret] ? "void" : [my gen_type $tret]}]
                set ps {}
                foreach p [pak::items [pak::nfield $t params]] { lappend ps [my gen_type $p] }
                return "$rc (*)([join $ps {, }])"
            }
            TypeParam { return "void *" }
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
            AllocExpr {
                if {![pak::isnil [pak::nfield $e allocator]]} { pak::cg_unported "alloc:allocator" }
                set ct [my gen_type [pak::nfield $e type_node]]
                set count [pak::nfield $e count]
                if {![pak::isnil $count]} {
                    return "($ct *)malloc(sizeof($ct) * (size_t)([my gen_expr $count]))"
                }
                return "($ct *)malloc(sizeof($ct))"
            }
            FreeExpr {
                if {![pak::isnil [pak::nfield $e allocator]]} { pak::cg_unported "free:allocator" }
                return "free([my gen_expr [pak::nfield $e ptr]])"
            }
            OkExpr {
                set val [my gen_expr [pak::nfield $e value]]
                set rt [expr {($current_ret_type ne "" && ![pak::isnil $current_ret_type]) ? [my gen_type $current_ret_type] : "PakResult"}]
                return "($rt)\{ .is_ok = true, .data.value = $val \}"
            }
            ErrExpr {
                set val [my gen_expr [pak::nfield $e value]]
                set rt [expr {($current_ret_type ne "" && ![pak::isnil $current_ret_type]) ? [my gen_type $current_ret_type] : "PakResult"}]
                return "($rt)\{ .is_ok = false, .data.error = $val \}"
            }
            FmtStr    { return [my gen_fmtstr $e] }
            Closure   { return [my gen_closure $e] }
            CatchExpr { return [my gen_expr [pak::nfield $e expr]] }
            NullCheck { return [my gen_expr [pak::nfield $e expr]] }
            RangeExpr {
                set start [my gen_expr [pak::nfield $e start]]
                set end_node [pak::nfield $e end]
                set end [expr {[pak::isnil $end_node] ? "" : [my gen_expr $end_node]}]
                return "$start..$end"
            }
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

    # ── format strings (mirror codegen._gen_fmtstr / _fmt_* helpers) ───────────
    method fmt_spec_for_expr {expr} {
        set t [my expr_type $expr]
        if {$t ne "" && ![pak::isnil $t]} {
            set c [my gen_type $t]
            if {[dict exists $::pak::CG_FMT_SPEC $c]} { return [dict get $::pak::CG_FMT_SPEC $c] }
            if {[string match "*\*" $c] || $c eq "const char *"} { return "%s" }
        }
        return "%ld"
    }
    method fmt_arg_for_expr {expr spec} {
        set c [my gen_expr $expr]
        switch -- $spec {
            "%ld"  { return "(long)($c)" }
            "%lld" { return "(long long)($c)" }
            "%lu" - "%llu" { return "(unsigned long)($c)" }
            "%.*s" { return "($c).len, ($c).data" }
        }
        return $c
    }
    method gen_fmtstr {e} {
        set fmt_parts {}
        set arg_parts {}
        foreach part [pak::items [pak::nfield $e parts]] {
            if {[lindex $part 0] eq "lit"} {
                set s [pak::sval $part]
                set s [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n"] $s]
                lappend fmt_parts $s
            } else {
                set spec [my fmt_spec_for_expr $part]
                lappend fmt_parts $spec
                lappend arg_parts [my fmt_arg_for_expr $part $spec]
            }
        }
        set fmt_str [join $fmt_parts ""]
        set n $fmt_counter
        incr fmt_counter
        set buf "_pak_fmt_$n"
        set args [expr {[llength $arg_parts] > 0 ? ", [join $arg_parts {, }]" : ""}]
        return "(\{ static char $buf\[256\]; snprintf($buf, 256, \"$fmt_str\"$args); (const char*)$buf; \})"
    }

    # ── closures (mirror codegen._gen_closure / _emit_closures) ────────────────
    method gen_closure {e} {
        set name "_pak_closure_[llength $closures]"
        lappend closures [list $name $e]
        return $name
    }
    method emit_closures {} {
        set lines {}
        foreach pair $closures {
            lassign $pair name e
            set rt [pak::nfield $e ret_type]
            set ret [expr {[pak::isnil $rt] ? "void" : [my gen_type $rt]}]
            set params {}
            foreach p [pak::items [pak::nfield $e params]] {
                lappend params "[my gen_type [pak::nfield $p type]] [pak::fval $p name]"
            }
            set param_str [expr {[llength $params] > 0 ? [join $params {, }] : "void"}]
            lappend lines "static $ret ${name}($param_str) {"
            my scope_push
            foreach p [pak::items [pak::nfield $e params]] {
                my scope_set [pak::fval $p name] [pak::nfield $p type]
            }
            foreach st [pak::items [pak::nfield [pak::nfield $e body] stmts]] {
                set s [my gen_stmt $st 1]
                if {$s ne ""} { lappend lines $s }
            }
            my scope_pop
            lappend lines "}"
            lappend lines ""
        }
        return $lines
    }

    # ── generic monomorphization (mirror codegen._infer_type_args / _monomorphize_fn) ──
    # Infer concrete type args for a generic fn from call-site argument expressions.
    # Returns a list of type values (nodes), or {} if not fully inferable.
    method infer_type_args {fn_decl call_args} {
        set type_params [pak::items [pak::nfield $fn_decl type_params]]
        if {[llength $type_params] == 0} { return {} }
        set tpnames {}
        foreach tp $type_params { lappend tpnames [pak::sval $tp] }
        set inferred [dict create]
        set params [pak::items [pak::nfield $fn_decl params]]
        set n [expr {min([llength $params], [llength $call_args])}]
        for {set i 0} {$i < $n} {incr i} {
            my collect_type_param_inferences [pak::nfield [lindex $params $i] type] [lindex $call_args $i] $tpnames inferred
        }
        set result {}
        foreach tpn $tpnames {
            if {[dict exists $inferred $tpn]} {
                lappend result [dict get $inferred $tpn]
            } else {
                return {}
            }
        }
        return $result
    }

    method collect_type_param_inferences {param_type arg_expr tpnames inferredVar} {
        upvar 1 $inferredVar inferred
        switch -- [pak::kindof $param_type] {
            TypeName {
                set pn [pak::fval $param_type name]
                if {$pn in $tpnames} {
                    set t [my expr_type $arg_expr]
                    if {$t eq "" || [pak::isnil $t]} {
                        switch -- [pak::kindof $arg_expr] {
                            IntLit    { set t [pak::N TypeName name i32] }
                            FloatLit  { set t [pak::N TypeName name f32] }
                            BoolLit   { set t [pak::N TypeName name bool] }
                            StringLit { set t [pak::N TypeName name Str] }
                            default   { set t "" }
                        }
                    }
                    if {$t ne "" && ![pak::isnil $t] && ![dict exists $inferred $pn]} {
                        dict set inferred $pn $t
                    }
                }
            }
            TypePointer {
                my collect_type_param_inferences [pak::nfield $param_type inner] $arg_expr $tpnames inferred
            }
            TypeGeneric {
                foreach sub [pak::items [pak::nfield $param_type args]] {
                    my collect_type_param_inferences $sub $arg_expr $tpnames inferred
                }
            }
        }
    }

    method monomorphize_fn {fn_name type_args} {
        set fn_decl [dict get $generic_fns $fn_name]
        set c_type_args {}
        foreach t $type_args { lappend c_type_args [my gen_type $t] }
        set cache_key [list $fn_name $c_type_args]
        if {[dict exists $mono_cache $cache_key]} { return [dict get $mono_cache $cache_key] }
        set safe_parts {}
        foreach c $c_type_args { lappend safe_parts [string map {" " _ "*" p} $c] }
        set specialized_name "${fn_name}_[join $safe_parts _]"
        dict set mono_cache $cache_key $specialized_name
        set type_params [pak::items [pak::nfield $fn_decl type_params]]
        set subst [dict create]
        for {set i 0} {$i < [llength $type_params]} {incr i} {
            if {$i < [llength $type_args]} {
                dict set subst [pak::sval [lindex $type_params $i]] [lindex $type_args $i]
            }
        }
        # Build a specialized FnDecl with substituted param/ret types.
        set new_params {}
        foreach p [pak::items [pak::nfield $fn_decl params]] {
            set np [pak::N Param \
                name [pak::fval $p name] \
                type [pak::cg_subst_type [pak::nfield $p type] $subst] \
                mutable [pak::fval $p mutable] \
                default_value [pak::nfield $p default_value]]
            lappend new_params $np
        }
        set anns {}
        foreach a [pak::items [pak::nfield $fn_decl annotations]] { lappend anns [pak::sval $a] }
        set spec_decl [pak::N FnDecl \
            name $specialized_name \
            params $new_params \
            ret_type [pak::cg_subst_type [pak::nfield $fn_decl ret_type] $subst] \
            body [pak::nfield $fn_decl body] \
            type_params {} \
            annotations $anns \
            is_method [pak::fval $fn_decl is_method] \
            self_type [pak::nfield $fn_decl self_type] \
            variadic [pak::fval $fn_decl variadic]]
        lappend pending_mono $spec_decl
        return $specialized_name
    }

    # Static type-method calls: Vec3.zero(), Mat4.identity(), Vec3.from(...) etc.
    # Mirror codegen._gen_static_type_method. Returns "" if not handled.
    method gen_static_type_method {type_name method arglist} {
        if {$type_name in {Vec3 T3DVec3}} {
            switch -- $method {
                zero    { return "(T3DVec3){{0.0f, 0.0f, 0.0f}}" }
                up      { return "(T3DVec3){{0.0f, 1.0f, 0.0f}}" }
                right   { return "(T3DVec3){{1.0f, 0.0f, 0.0f}}" }
                forward { return "(T3DVec3){{0.0f, 0.0f, -1.0f}}" }
                one     { return "(T3DVec3){{1.0f, 1.0f, 1.0f}}" }
            }
            if {$method eq "from" && [llength $arglist] == 3} {
                return "(T3DVec3){{[lindex $arglist 0], [lindex $arglist 1], [lindex $arglist 2]}}"
            }
        }
        if {$type_name in {Vec2 T3DVec2}} {
            switch -- $method {
                zero { return "(T3DVec2){{0.0f, 0.0f}}" }
                one  { return "(T3DVec2){{1.0f, 1.0f}}" }
            }
        }
        if {$type_name in {Vec4 T3DVec4}} {
            if {$method eq "zero"} { return "(T3DVec4){{0.0f, 0.0f, 0.0f, 0.0f}}" }
        }
        if {$type_name in {Mat4 T3DMat4}} {
            if {$method eq "identity"} { return "pak_mat4_identity()" }
        }
        if {$type_name in {Mat4Fp T3DMat4FP}} {
            if {$method eq "create"} { return "malloc_uncached(sizeof(T3DMat4FP))" }
        }
        if {$type_name in {FixedList RingBuffer FixedMap Pool}} {
            if {$method eq "init"} { return "{0}" }
        }
        return ""
    }

    # Built-in instance method dispatch. Mirror codegen._gen_builtin_method.
    # Returns "" if not handled (caller falls through). Raises CGUNPORTED for
    # branches whose typedef machinery is not yet ported to the Tcl codegen.
    method gen_builtin_method {obj c_type method arglist obj_type} {
        set na [llength $arglist]
        set a0 [expr {$na > 0 ? [lindex $arglist 0] : ""}]
        set a1 [expr {$na > 1 ? [lindex $arglist 1] : ""}]
        set a2 [expr {$na > 2 ? [lindex $arglist 2] : ""}]
        # Numeric cast methods
        if {[dict exists $::pak::CG_NUMERIC_CAST $method]} {
            return "([dict get $::pak::CG_NUMERIC_CAST $method])($obj)"
        }
        if {[dict exists $::pak::CG_FIXPOINT_CAST $method]} {
            return [string map [list {%VAL%} $obj] [dict get $::pak::CG_FIXPOINT_CAST $method]]
        }
        if {$method eq "integer"} { return "(int32_t)(($obj) >> 16)" }
        if {$method eq "fraction"} { return "((float)(($obj) & 0xFFFF) / 65536.0f)" }
        if {$method eq "clamp" && $na == 2} {
            return "(($obj) < ($a0) ? ($a0) : ($obj) > ($a1) ? ($a1) : ($obj))"
        }
        if {$method in {as_slice as_slice_mut}} {
            if {[pak::kindof $obj_type] eq "TypeArray"} { pak::cg_unported "builtin:as_slice" }
            return "(\{ __auto_type _arr = &($obj)\[0\]; (void*)_arr; \})"
        }
        if {$method eq "get_unchecked" && $na == 1} {
            if {[pak::kindof $obj_type] eq "TypeSlice"} { return "($obj).data\[$a0\]" }
            return "($obj)\[$a0\]"
        }
        if {$method eq "len" && $na == 0} {
            if {[pak::kindof $obj_type] eq "TypeSlice"} { return "($obj).len" }
            if {[pak::kindof $obj_type] eq "TypeArray"} { return "(int32_t)(sizeof($obj)/sizeof(($obj)\[0\]))" }
            return "($obj).len"
        }
        if {$method eq "free" && $na == 0} {
            if {$c_type in {"T3DMat4FP *" "T3DMat4FP*"}} { return "free_uncached($obj)" }
            if {$c_type in {"T3DModel *" "T3DModel*"}} { return "t3d_model_free($obj)" }
        }
        # Vec3 instance methods
        if {$c_type in {"T3DVec3" "T3DVec3 *"} || [dict exists $::pak::CG_VEC3_INSTANCE $method]} {
            if {[dict exists $::pak::CG_VEC3_INSTANCE $method]} {
                set tmpl [dict get $::pak::CG_VEC3_INSTANCE $method]
                return [string map [list {%OBJ%} $obj {%A0%} [expr {$na>0?$a0:"0"}] {%A1%} [expr {$na>1?$a1:"0"}] {%A2%} [expr {$na>2?$a2:"0"}]] $tmpl]
            }
        }
        if {$c_type in {"T3DVec2" "T3DVec2 *"}} {
            if {[dict exists $::pak::CG_VEC2_INSTANCE $method]} {
                set tmpl [dict get $::pak::CG_VEC2_INSTANCE $method]
                return [string map [list {%OBJ%} $obj {%A0%} [expr {$na>0?$a0:"0"}]] $tmpl]
            }
        }
        if {$c_type in {"T3DMat4" "T3DMat4 *"}} {
            if {[dict exists $::pak::CG_MAT4_INSTANCE $method]} {
                set tmpl [dict get $::pak::CG_MAT4_INSTANCE $method]
                return [string map [list {%OBJ%} $obj {%A0%} [expr {$na>0?$a0:"0"}] {%A1%} [expr {$na>1?$a1:"0"}] {%A2%} [expr {$na>2?$a2:"0"}]] $tmpl]
            }
        }
        # Container / Vec / string methods require typedef machinery not yet ported
        if {[pak::kindof $obj_type] eq "TypeGeneric"} {
            set gn [pak::fval $obj_type name]
            if {$gn in {FixedList Pool RingBuffer FixedMap Vec}} { pak::cg_unported "builtin:container-method" }
        }
        set is_cstr [expr {$c_type in {"const char *" "char *"} || ([pak::kindof $obj_type] eq "TypeName" && [pak::fval $obj_type name] in {CStr c_char})}]
        set is_pakstr [expr {$c_type eq "PakStr" || ([pak::kindof $obj_type] eq "TypeName" && [pak::fval $obj_type name] in {Str PakStr})}]
        if {$is_cstr || $is_pakstr} {
            if {$method in {len contains starts_with ends_with eq cmp is_empty as_bytes to_pakstr find slice copy_to concat_into format_into data as_cstr}} {
                pak::cg_unported "builtin:string-method"
            }
        }
        return ""
    }

    method gen_call {e} {
        set args {}
        foreach a [pak::items [pak::nfield $e args]] { lappend args [my gen_expr $a] }
        set func [pak::nfield $e func]
        # comptime_assert(cond, msg) → _Static_assert(cond, msg)
        if {[pak::kindof $func] eq "Ident"} {
            set fnm [pak::fval $func name]
            if {$fnm eq "comptime_assert"} {
                set cond [expr {[llength $args] > 0 ? [lindex $args 0] : "true"}]
                set msg [expr {[llength $args] > 1 ? [lindex $args 1] : {"assertion"}}]
                return "_Static_assert($cond, $msg)"
            }
            if {$fnm eq "heap_allocator"} { return "pak_heap_allocator()" }
            if {$fnm eq "arena_allocator"} {
                set arg [expr {[llength $args] > 0 ? [lindex $args 0] : "0"}]
                return "Allocator_from_Arena($arg)"
            }
        }
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set type_name [pak::fval [pak::nfield $func obj] name]
            set method [pak::fval $func field]
            # Static type-method calls
            set r [my gen_static_type_method $type_name $method $args]
            if {$r ne ""} { return $r }
        }
        # Method call: obj.method(args) → TypeName_method(&obj, args)
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set obj_name [pak::fval [pak::nfield $func obj] name]
            set method_name [pak::fval $func field]
            set obj_type [my scope_get $obj_name]
            set tname ""
            if {[pak::kindof $obj_type] eq "TypeName"} {
                set tname [pak::fval $obj_type name]
            } elseif {[pak::kindof $obj_type] eq "TypePointer" && [pak::kindof [pak::nfield $obj_type inner]] eq "TypeName"} {
                set tname [pak::fval [pak::nfield $obj_type inner] name]
            }
            if {$tname ne "" && [dict exists $method_registry $tname] && [dict exists [dict get $method_registry $tname] $method_name]} {
                set fn_decl [dict get [dict get $method_registry $tname] $method_name]
                set c_fn "${tname}_${method_name}"
                set params [pak::items [pak::nfield $fn_decl params]]
                if {[llength $params] > 0} {
                    set sp [lindex $params 0]
                    if {[pak::kindof [pak::nfield $sp type]] eq "TypePointer"} {
                        if {[pak::kindof $obj_type] eq "TypePointer"} {
                            set self_arg $obj_name
                        } else {
                            set self_arg "&$obj_name"
                        }
                    } else {
                        set self_arg $obj_name
                    }
                } else {
                    set self_arg "&$obj_name"
                }
                set all_args [concat [list $self_arg] $args]
                return "${c_fn}([join $all_args {, }])"
            }
        }
        # Trait-object method dispatch: d.method(args) → (d.vtable->method)(d.self, args)
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set obj_name [pak::fval [pak::nfield $func obj] name]
            set method_name [pak::fval $func field]
            set obj_type [my scope_get $obj_name]
            set trait_tn ""
            if {[pak::kindof $obj_type] eq "TypeName" && [dict exists $trait_decls [pak::fval $obj_type name]]} {
                set trait_tn [pak::fval $obj_type name]
            } elseif {[pak::kindof $obj_type] eq "TypeDynTrait"} {
                set trait_tn [pak::fval $obj_type name]
            }
            if {$trait_tn ne ""} {
                set vtable_args [concat [list "${obj_name}.self"] $args]
                return "(${obj_name}.vtable->${method_name})([join $vtable_args {, }])"
            }
        }
        # Built-in instance method dispatch
        if {[pak::kindof $func] eq "DotAccess"} {
            set obj_expr [pak::nfield $func obj]
            set method [pak::fval $func field]
            set obj_str [my gen_expr $obj_expr]
            set obj_type [my expr_type $obj_expr]
            set c_type [expr {($obj_type ne "" && ![pak::isnil $obj_type]) ? [my gen_type $obj_type] : ""}]
            set r [my gen_builtin_method $obj_str $c_type $method $args $obj_type]
            if {$r ne ""} { return $r }
        }
        # Module API call: module.function(args) → C API
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set mod [pak::fval [pak::nfield $func obj] name]
            set fn [pak::fval $func field]
            set key [list $mod $fn]
            if {[dict exists $::pak::CG_API $key]} {
                return "[dict get $::pak::CG_API $key]([join $args {, }])"
            }
            if {[dict exists $::pak::CG_API_LAMBDA $key]} {
                return [pak::cg_api_lambda $mod $fn $args]
            }
        }
        # Generic call: foo::<T>(args) or inferred-generic foo(args)
        if {[pak::kindof $func] eq "Ident"} {
            set fname [pak::fval $func name]
            if {[dict exists $generic_fns $fname]} {
                set type_args [pak::items [pak::nfield $e type_args]]
                if {[llength $type_args] == 0} {
                    set type_args [my infer_type_args [dict get $generic_fns $fname] [pak::items [pak::nfield $e args]]]
                }
                if {[llength $type_args] > 0} {
                    set specialized [my monomorphize_fn $fname $type_args]
                    return "${specialized}([join $args {, }])"
                }
            }
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
                set defers [my emit_all_defers $indent]
                set v [pak::nfield $stmt value]
                if {[pak::isnil $v]} { set r "${pad}return;" } else { set r "${pad}return [my gen_expr $v];" }
                return [join [concat $defers [list $r]] \n]
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
                if {[pak::kindof $ex] eq "CatchExpr"} { return [my gen_catch_stmt $ex $pad $indent] }
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
            DeferStmt   { my defer_push $stmt; return "" }
            ForStmt     { return [my gen_for $stmt $pad $indent] }
            MatchStmt   { return [my gen_match $stmt $pad $indent] }
            NullCheckStmt { return [my gen_null_check $stmt $pad $indent] }
            StructDecl  { return [my gen_struct $stmt] }
            EnumDecl    { return [my gen_enum $stmt] }
            VariantDecl { return [my gen_variant $stmt] }
            UnionDecl   { return [my gen_union $stmt] }
            ComptimeIf  { pak::cg_unported "stmt:comptime-if" }
            default     { pak::cg_unported "stmt:[pak::kindof $stmt]" }
        }
    }

    method gen_let_stmt {s pad} {
        set anns [pak::annlist_or $s]
        set typ [pak::nfield $s type]
        set name [pak::fval $s name]
        set prefix ""
        if {[string first "@aligned" [join $anns " "]] >= 0} {
            foreach ann $anns {
                if {[string first "@aligned" $ann] >= 0} {
                    set n [string range $ann [expr {[string first ( $ann]+1}] [expr {[string first ) $ann]-1}]]
                    set prefix "__attribute__((aligned($n))) "
                }
            }
        }
        if {"@dma_safe" in $anns} { set prefix "__attribute__((aligned(16))) $prefix" }
        if {"@uncached" in $anns} {
            if {![pak::isnil $typ] && [pak::kindof $typ] eq "TypeArray"} {
                set elem_t [my gen_type [pak::nfield $typ inner]]
                set n_elems [my gen_expr [pak::nfield $typ size]]
                my scope_set $name [pak::N TypePointer inner [pak::nfield $typ inner] nullable 0 mutable 0]
                return "${pad}$elem_t * const $name = ($elem_t *)malloc_uncached($n_elems * sizeof($elem_t));"
            }
            set prefix "/* @uncached */ $prefix"
        }
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
            if {[pak::kindof $val] eq "CatchExpr"} { return [my gen_catch_let $s $val $pad $prefix $decl] }
            if {[pak::kindof $val] eq "ArrayLit" && ![pak::isnil [pak::nfield $val repeat]]} {
                set rep [pak::nfield $val repeat]
                set elems [pak::items [pak::nfield $val elements]]
                if {[llength $elems] > 0} { set v [my gen_expr [lindex $elems 0]] } else { set v 0 }
                set zero [expr {$v in {0 false NULL 0.0f 0.0}}]
                set small [expr {[pak::kindof $rep] eq "IntLit" && [pak::fval $rep value] <= 64}]
                if {$zero || $small} { return "${pad}${prefix}${decl} = [my gen_expr $val];" }
                set count [my gen_expr $rep]
                return "${pad}${prefix}${decl} = {0};\n${pad}for (int _fi = 0; _fi < (int)($count); _fi++) $name\[_fi\] = $v;"
            }
            if {[pak::kindof $val] in {OkExpr ErrExpr} && ![pak::isnil $typ]} {
                set result_c [my gen_type $typ]
                set inner [my gen_expr [pak::nfield $val value]]
                if {[pak::kindof $val] eq "OkExpr"} {
                    return "${pad}${prefix}${decl} = ($result_c)\{ .is_ok = true, .data.value = $inner \};"
                }
                return "${pad}${prefix}${decl} = ($result_c)\{ .is_ok = false, .data.error = $inner \};"
            }
            return "${pad}${prefix}${decl} = [my gen_expr $val];"
        } elseif {[pak::kindof $val] eq "UndefinedLit"} {
            return "${pad}${prefix}${decl}; /* undefined */"
        }
        return "${pad}${prefix}${decl};"
    }

    # ── catch expressions (mirror codegen._gen_catch_let / _gen_catch_stmt) ─────
    method gen_catch_let {s catch pad prefix decl} {
        set name [pak::fval $s name]
        set inner_c [my gen_expr [pak::nfield $catch expr]]
        set tmp "_catch_$name"
        set lines {}
        set inner_pad "${pad}    "
        set handler [pak::nfield $catch handler]
        set binding [pak::nfield $catch binding]

        # Detect fallback form: handler is a Block with a single ExprStmt.
        set is_fallback 0
        set fallback_expr ""
        if {[pak::kindof $handler] eq "Block"} {
            set stmts {}
            foreach st [pak::items [pak::nfield $handler stmts]] {
                if {![pak::isnil $st]} { lappend stmts $st }
            }
            if {[llength $stmts] == 1 && [pak::kindof [lindex $stmts 0]] eq "ExprStmt"} {
                set is_fallback 1
                set fallback_expr [my gen_expr [pak::nfield [lindex $stmts 0] expr]]
            }
        }

        if {$is_fallback && $fallback_expr ne ""} {
            lappend lines "${pad}__auto_type $tmp = $inner_c;"
            lappend lines "${pad}${prefix}${decl} = $tmp.is_ok ? $tmp.data.value : ($fallback_expr);"
            return [join $lines \n]
        }

        # Propagation form
        lappend lines "${pad}__auto_type $tmp = $inner_c;"
        lappend lines "${pad}if (!$tmp.is_ok) {"
        if {![pak::isnil $binding]} {
            lappend lines "${inner_pad}__auto_type [pak::sval $binding] = $tmp.data.error;"
        }
        if {[pak::kindof $handler] eq "Block"} {
            foreach st [pak::items [pak::nfield $handler stmts]] {
                set r [my gen_stmt $st [expr {[string length $inner_pad] / 4}]]
                if {$r ne ""} { lappend lines $r }
            }
        } else {
            lappend lines "${inner_pad}[my gen_expr $handler];"
        }
        lappend lines "${pad}}"
        lappend lines "${pad}${prefix}${decl} = $tmp.data.value;"
        return [join $lines \n]
    }

    method gen_catch_stmt {catch pad indent} {
        incr tmp_counter
        set tmp "_catch_tmp_$tmp_counter"
        set inner_pad "${pad}    "
        set handler [pak::nfield $catch handler]
        set binding [pak::nfield $catch binding]
        set lines [list "${pad}{"]
        lappend lines "${inner_pad}__auto_type $tmp = [my gen_expr [pak::nfield $catch expr]];"
        lappend lines "${inner_pad}if (!$tmp.is_ok) {"
        set handler_pad "${inner_pad}    "
        if {![pak::isnil $binding]} {
            lappend lines "${handler_pad}__auto_type [pak::sval $binding] = $tmp.data.error;"
        }
        if {[pak::kindof $handler] eq "Block"} {
            foreach st [pak::items [pak::nfield $handler stmts]] {
                set r [my gen_stmt $st [expr {$indent+2}]]
                if {$r ne ""} { lappend lines $r }
            }
        } else {
            lappend lines "${handler_pad}[my gen_expr $handler];"
        }
        lappend lines "${inner_pad}}"
        lappend lines "${pad}}"
        return [join $lines \n]
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
        foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
        my scope_pop
        lappend lines "${pad}}"
        foreach pair [pak::items [pak::nfield $s elif_branches]] {
            set p [pak::items $pair]
            lappend lines "${pad}else if ([pak::strip_parens [my gen_expr [lindex $p 0]]]) {"
            my scope_push
            foreach st [pak::items [pak::nfield [lindex $p 1] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
            foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
            my scope_pop
            lappend lines "${pad}}"
        }
        set eb [pak::nfield $s else_branch]
        if {![pak::isnil $eb]} {
            lappend lines "${pad}else {"
            my scope_push
            foreach st [pak::items [pak::nfield $eb stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
            foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
            my scope_pop
            lappend lines "${pad}}"
        }
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_null_check {s pad indent} {
        set expr [my gen_expr [pak::nfield $s expr]]
        set binding [pak::fval $s binding]
        set inner_pad [string repeat "    " [expr {$indent+1}]]
        set lines [list "${pad}if ($expr != NULL) {"]
        my scope_push
        my scope_set $binding [pak::N TypePointer inner [pak::N TypeName name auto] nullable 0 mutable 0]
        lappend lines "${inner_pad}__typeof__($expr) $binding = $expr;"
        foreach st [pak::items [pak::nfield [pak::nfield $s then] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
        my scope_pop
        lappend lines "${pad}}"
        set eb [pak::nfield $s else_branch]
        if {![pak::isnil $eb]} {
            lappend lines "${pad}else {"
            my scope_push
            foreach st [pak::items [pak::nfield $eb stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
            foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
            my scope_pop
            lappend lines "${pad}}"
        }
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_loop {s pad indent} {
        set lines [list "${pad}while (true) {"]
        my scope_push
        foreach st [pak::items [pak::nfield [pak::nfield $s body] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
        my scope_pop
        lappend lines "${pad}}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_while {s pad indent} {
        set cond [pak::strip_parens [my gen_expr [pak::nfield $s condition]]]
        set lines [list "${pad}while ($cond) {"]
        my scope_push
        foreach st [pak::items [pak::nfield [pak::nfield $s body] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
        my scope_pop
        lappend lines "${pad}}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_for {s pad indent} {
        set inner_pad [string repeat "    " [expr {$indent+1}]]
        set iterable [pak::nfield $s iterable]
        set binding [pak::fval $s binding]
        set index_tv [pak::nfield $s index]
        set has_index [expr {![pak::isnil $index_tv]}]
        set index [expr {$has_index ? [pak::sval $index_tv] : ""}]
        set lines {}
        if {[pak::kindof $iterable] eq "RangeExpr"} {
            set start [my gen_expr [pak::nfield $iterable start]]
            set end_tv [pak::nfield $iterable end]
            set end [expr {[pak::isnil $end_tv] ? "0" : [my gen_expr $end_tv]}]
            if {$has_index} {
                lappend lines "${pad}for (int $index = $start; $index < $end; $index++) \{"
                lappend lines "${inner_pad}int $binding = $index;"
            } else {
                lappend lines "${pad}for (int $binding = $start; $binding < $end; $binding++) \{"
            }
        } else {
            set coll [my gen_expr $iterable]
            set coll_type [my expr_type $iterable]
            my scope_set $binding [pak::N TypeName name auto]
            set idx [expr {$has_index ? $index : "_i_$binding"}]
            if {[pak::kindof $coll_type] eq "TypeSlice"} {
                lappend lines "${pad}for (int $idx = 0; $idx < ($coll).len; $idx++) \{"
                lappend lines "${inner_pad}__typeof__(($coll).data\[0\]) $binding = ($coll).data\[$idx\];"
            } else {
                lappend lines "${pad}for (int $idx = 0; $idx < (int)(sizeof($coll)/sizeof(($coll)\[0\])); $idx++) \{"
                lappend lines "${inner_pad}__typeof__(($coll)\[0\]) $binding = ($coll)\[$idx\];"
            }
        }
        my scope_push
        foreach st [pak::items [pak::nfield [pak::nfield $s body] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+1}]] }
        foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
        my scope_pop
        lappend lines "${pad}\}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method match_type_name {expr} {
        set t [my expr_type $expr]
        switch -- [pak::kindof $t] {
            TypeName    { return [pak::fval $t name] }
            TypePointer {
                set inner [pak::nfield $t inner]
                if {[pak::kindof $inner] eq "TypeName"} { return [pak::fval $inner name] }
            }
        }
        return ""
    }

    method gen_match {s pad indent} {
        set expr [my gen_expr [pak::nfield $s expr]]
        set inner_pad [string repeat "    " [expr {$indent+1}]]
        set inner2_pad [string repeat "    " [expr {$indent+2}]]
        set match_type [my match_type_name [pak::nfield $s expr]]
        set is_variant [dict exists $variant_types $match_type]
        set switch_expr [expr {$is_variant ? "${expr}.tag" : $expr}]
        set lines [list "${pad}switch ($switch_expr) {"]
        foreach arm [pak::items [pak::nfield $s arms]] {
            set pat [pak::nfield $arm pattern]
            switch -- [pak::kindof $pat] {
                Ident {
                    if {[pak::fval $pat name] eq "_"} {
                        lappend lines "${inner_pad}default:"
                    } else {
                        lappend lines "${inner_pad}case /* [my gen_expr $pat] */:"
                    }
                }
                EnumVariantAccess {
                    set pn [pak::fval $pat name]
                    set tn [expr {[dict exists $enum_variants $pn] ? [dict get $enum_variants $pn] : ""}]
                    if {[dict exists $variant_types $tn]} {
                        lappend lines "${inner_pad}case ${tn}_tag_${pn}:"
                    } elseif {$tn ne ""} {
                        lappend lines "${inner_pad}case ${tn}_${pn}:"
                    } else {
                        lappend lines "${inner_pad}case ${pn}:"
                    }
                }
                DotAccess {
                    set variant [pak::fval $pat field]
                    set obj_name [my gen_expr [pak::nfield $pat obj]]
                    if {[dict exists $variant_types $obj_name]} {
                        lappend lines "${inner_pad}case ${obj_name}_tag_${variant}:"
                    } else {
                        lappend lines "${inner_pad}case ${obj_name}_${variant}:"
                    }
                }
                IntLit  { lappend lines "${inner_pad}case [pak::fval $pat value]:" }
                BoolLit { lappend lines "${inner_pad}case [expr {[pak::fval $pat value] ? 1 : 0}]:" }
                default { lappend lines "${inner_pad}case /* [my gen_expr $pat] */:" }
            }
            lappend lines "${inner_pad}{"
            my scope_push
            if {[pak::kindof $pat] eq "DotAccess" && ![pak::isnil [pak::nfield $pat binding]]} {
                set obj_name [my gen_expr [pak::nfield $pat obj]]
                if {[dict exists $variant_types $obj_name]} {
                    set bind [pak::sval [pak::nfield $pat binding]]
                    set field_name [string tolower [pak::fval $pat field]]
                    lappend lines "${inner2_pad}__auto_type $bind = ${expr}.data.${field_name};"
                    my scope_set $bind [pak::N TypeName name auto]
                }
            }
            set body [pak::nfield $arm body]
            if {[pak::kindof $body] eq "Block"} {
                foreach st [pak::items [pak::nfield $body stmts]] { lappend lines [my gen_stmt $st [expr {$indent+2}]] }
            } else {
                lappend lines "${inner2_pad}[my gen_expr $body];"
            }
            foreach d [my emit_defers_for_scope [expr {$indent+2}]] { lappend lines $d }
            my scope_pop
            lappend lines "${inner2_pad}break;"
            lappend lines "${inner_pad}}"
        }
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
            VariantDecl { return [my gen_variant $decl] }
            ImplBlock      { return [my gen_impl $decl] }
            TraitDecl      { return [my gen_trait $decl] }
            ImplTraitBlock { return [my gen_impl_trait $decl] }
            ExternBlock { return [my gen_extern $decl] }
            StaticDecl  { return [my gen_static_global $decl] }
            LetDecl     { return [my gen_let_global $decl] }
            CfgBlock    { return [my gen_cfg_block $decl] }
            ComptimeIf  { pak::cg_unported "decl:comptime-if" }
            default     { pak::cg_unported "decl:[pak::kindof $decl]" }
        }
    }

    method gen_struct {s} {
        set attrs {}
        foreach ann [pak::annlist_or $s] {
            if {[string match "*@packed*" $ann] || [string match "*@c_layout*" $ann]} {
                if {[string match "*@packed*" $ann]} { lappend attrs "__attribute__((packed))" }
            } elseif {[string match "*@aligned*" $ann]} {
                set n [string range $ann [expr {[string first ( $ann]+1}] [expr {[string first ) $ann]-1}]]
                lappend attrs "__attribute__((aligned($n)))"
            }
        }
        set attr_str [join $attrs " "]
        set lines [list "typedef struct {"]
        foreach field [pak::items [pak::nfield $s fields]] {
            set bw [pak::nfield $field bit_width]
            if {![pak::isnil $bw]} {
                lappend lines "    [my gen_type [pak::nfield $field type]] [pak::fval $field name] : [pak::sval $bw];"
            } else {
                lappend lines "    [my gen_array_decl [pak::fval $field name] [pak::nfield $field type]];"
            }
        }
        set suffix [expr {$attr_str ne "" ? " $attr_str" : ""}]
        lappend lines "} [pak::fval $s name]${suffix};"
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

    method gen_variant {v} {
        set lines {}
        set name [pak::fval $v name]
        foreach case [pak::items [pak::nfield $v cases]] {
            set cfields [pak::items [pak::nfield $case fields]]
            set cname [pak::fval $case name]
            if {[llength $cfields] > 0} {
                lappend lines "typedef struct {"
                set i 0
                foreach f $cfields {
                    if {[lindex $f 0] eq "seq"} {
                        set p [pak::items $f]
                        lappend lines "    [my gen_array_decl [pak::sval [lindex $p 0]] [lindex $p 1]];"
                    } else {
                        lappend lines "    [my gen_type $f] field${i};"
                    }
                    incr i
                }
                lappend lines "} ${name}_${cname};"
                lappend lines ""
            }
        }
        lappend lines "typedef enum {"
        foreach case [pak::items [pak::nfield $v cases]] {
            lappend lines "    ${name}_tag_[pak::fval $case name],"
        }
        lappend lines "} ${name}_tag;"
        lappend lines ""
        lappend lines "typedef struct {"
        lappend lines "    ${name}_tag tag;"
        lappend lines "    union {"
        foreach case [pak::items [pak::nfield $v cases]] {
            set cname [pak::fval $case name]
            if {[llength [pak::items [pak::nfield $case fields]]] > 0} {
                lappend lines "        ${name}_${cname} ${cname};"
            }
        }
        lappend lines "    } data;"
        lappend lines "} ${name};"
        return [join $lines \n]
    }

    method gen_impl {impl} {
        set parts {}
        foreach m [pak::items [pak::nfield $impl methods]] {
            lappend parts [my gen_fn $m [pak::fval $impl type_name]]
        }
        return [join $parts "\n\n"]
    }

    method gen_trait {t} {
        set name [pak::fval $t name]
        dict set trait_decls $name $t
        set lines [list "/* trait $name */"]
        lappend lines "typedef struct {"
        foreach m [pak::items [pak::nfield $t methods]] {
            set ret [my gen_type [pak::nfield $m ret_type]]
            set ptypes [list "void *"]
            foreach p [pak::items [pak::nfield $m params]] {
                if {[pak::fval $p name] eq "self"} continue
                lappend ptypes [my gen_type [pak::nfield $p type]]
            }
            set mname [pak::fval $m name]
            lappend lines "    $ret (*${mname})([join $ptypes {, }]);"
        }
        lappend lines "} ${name}_vtable;"
        lappend lines ""
        lappend lines "typedef struct {"
        lappend lines "    void *self;"
        lappend lines "    const ${name}_vtable *vtable;"
        lappend lines "} ${name};"
        return [join $lines \n]
    }

    method gen_impl_trait {impl} {
        set tname [pak::fval $impl type_name]
        set trait [pak::fval $impl trait_name]
        set lines [list "/* impl $tname for $trait */"]
        foreach m [pak::items [pak::nfield $impl methods]] {
            dict set method_registry $tname [pak::fval $m name] $m
        }
        foreach m [pak::items [pak::nfield $impl methods]] {
            set ret [my gen_type [pak::nfield $m ret_type]]
            set mname [pak::fval $m name]
            set thunk "_pak_${trait}_${mname}_${tname}"
            set thunk_params [list "void *_self"]
            set call_params [list "($tname *)_self"]
            foreach p [pak::items [pak::nfield $m params]] {
                if {[pak::fval $p name] eq "self"} continue
                lappend thunk_params "[my gen_type [pak::nfield $p type]] [pak::fval $p name]"
                lappend call_params [pak::fval $p name]
            }
            lappend lines "static $ret ${thunk}([join $thunk_params {, }]) {"
            set call_str "${tname}_${mname}([join $call_params {, }])"
            if {$ret eq "void"} {
                lappend lines "    ${call_str};"
            } else {
                lappend lines "    return ${call_str};"
            }
            lappend lines "}"
            lappend lines ""
        }
        set vtable_var "_pak_${trait}_vtable_${tname}"
        lappend lines "static const ${trait}_vtable ${vtable_var} = {"
        foreach m [pak::items [pak::nfield $impl methods]] {
            set mname [pak::fval $m name]
            lappend lines "    .${mname} = _pak_${trait}_${mname}_${tname},"
        }
        lappend lines "};"
        lappend lines ""
        set ctor "${trait}_from_${tname}"
        lappend lines "static inline $trait ${ctor}($tname *p) {"
        lappend lines "    return (${trait})\{ .self = (void *)p, .vtable = &${vtable_var} \};"
        lappend lines "}"
        return [join $lines \n]
    }

    method gen_cfg_block {cfg} {
        set inner [my gen_decl [pak::nfield $cfg decl]]
        if {$inner eq ""} { return "" }
        set feature [pak::fval $cfg feature]
        set directive [expr {[pak::fval $cfg negated] ? "#ifndef" : "#ifdef"}]
        return "$directive $feature\n$inner\n#endif  /* $feature */"
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
        if {[pak::fval $fn variadic]} {
            lappend params "..."
            set param_str [join $params {, }]
        } elseif {[llength $params] > 0} {
            set param_str [join $params {, }]
        } else {
            set param_str "void"
        }
        # annotations → C attribute line + optional @export rename
        set attrs {}
        set export_name ""
        foreach ann [pak::annlist_or $fn] {
            if {$ann eq "@hot"} { lappend attrs "__attribute__((hot))" } \
            elseif {$ann eq "@inline"} { lappend attrs "static inline" } \
            elseif {$ann eq "@no_alloc"} { } \
            elseif {[string match "@export*" $ann]} {
                if {[regexp {@export\s*\(\s*"([^"]+)"\s*\)} $ann -> en]} { set export_name $en }
            }
        }
        set name [pak::fval $fn name]
        if {$prefix ne ""} { set name "${prefix}_$name" }
        if {$export_name ne ""} { set name $export_name }
        set attr_str [join $attrs " "]
        set head {}
        if {$attr_str ne ""} { lappend head $attr_str }
        set body [pak::nfield $fn body]
        if {[pak::isnil $body]} {
            lappend head "$ret ${name}($param_str);"
            return [join $head \n]
        }
        set lines [concat $head [list "$ret ${name}($param_str) {"]]
        set prev_ret $current_ret_type
        set current_ret_type [pak::nfield $fn ret_type]
        my scope_push
        foreach p [pak::items [pak::nfield $fn params]] { my scope_set [pak::fval $p name] [pak::nfield $p type] }
        foreach st [pak::items [pak::nfield $body stmts]] {
            set s [my gen_stmt $st 1]
            if {$s ne ""} { lappend lines $s }
        }
        foreach d [my emit_defers_for_scope 1] { lappend lines $d }
        my scope_pop
        set current_ret_type $prev_ret
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
        foreach d [my emit_defers_for_scope 1] { lappend lines $d }
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
                CfgBlock {
                    set inner [pak::nfield $decl decl]
                    switch -- [pak::kindof $inner] {
                        StructDecl {
                            set fmap [dict create]
                            foreach f [pak::items [pak::nfield $inner fields]] {
                                dict set fmap [pak::fval $f name] [pak::nfield $f type]
                            }
                            dict set struct_fields [pak::fval $inner name] $fmap
                        }
                        EnumDecl {
                            foreach v [pak::items [pak::nfield $inner variants]] {
                                dict set enum_variants [pak::fval $v name] [pak::fval $inner name]
                            }
                        }
                        VariantDecl {
                            dict set variant_types [pak::fval $inner name] 1
                            foreach c [pak::items [pak::nfield $inner cases]] {
                                dict set enum_variants [pak::fval $c name] [pak::fval $inner name]
                            }
                        }
                        FnDecl { lappend fn_names [pak::fval $inner name] }
                    }
                }
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

        # Result typedefs (collected as a side effect of body generation above).
        if {[llength $result_typedefs] > 0} {
            lappend out ""
            foreach td $result_typedefs {
                lassign $td tdname c_ok c_err
                lappend out "typedef struct { bool is_ok; union { $c_ok value; $c_err error; } data; } ${tdname};"
            }
        }

        # Emit closures (non-capturing fn literals) as static functions.
        if {[llength $closures] > 0} {
            set closure_lines [my emit_closures]
            set closures {}
            lappend out ""
            lappend out "/* -- Closures -- */"
            foreach cl $closure_lines { lappend out $cl }
        }

        foreach b $body { lappend out $b }

        # Emit monomorphized generic specializations generated during body codegen.
        if {[llength $pending_mono] > 0} {
            lappend out ""
            lappend out "/* -- Generic specializations -- */"
            foreach decl $pending_mono {
                switch -- [pak::kindof $decl] {
                    FnDecl     { lappend out [my gen_fn $decl ""] }
                    StructDecl { lappend out [my gen_struct $decl] }
                }
                lappend out ""
            }
            set pending_mono {}
        }
        return [join $out \n]
    }
}

# Mirror codegen._addr: &args[i] unless already a pointer expression.
proc pak::cg_addr {arglist i} {
    if {$i < [llength $arglist]} {
        set a [lindex $arglist $i]
        if {[string index $a 0] in {& *}} { return $a }
        return "&$a"
    }
    return "NULL"
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
        "t3d mat4_identity" { return "t3d_mat4_identity([pak::cg_addr $arglist 0])" }
        "t3d mat4_rotate_y" { return "t3d_mat4_rotate([pak::cg_addr $arglist 0], &(T3DVec3){{0,1,0}}, [lindex $arglist 1])" }
        "t3d mat4_rotate_x" { return "t3d_mat4_rotate([pak::cg_addr $arglist 0], &(T3DVec3){{1,0,0}}, [lindex $arglist 1])" }
        "t3d mat4_rotate_z" { return "t3d_mat4_rotate([pak::cg_addr $arglist 0], &(T3DVec3){{0,0,1}}, [lindex $arglist 1])" }
        "t3d mat4_translate" { return "t3d_mat4_translate([pak::cg_addr $arglist 0], [lindex $arglist 1], [lindex $arglist 2], [lindex $arglist 3])" }
        "t3d mat4_scale" { return "t3d_mat4_scale([pak::cg_addr $arglist 0], [lindex $arglist 1], [lindex $arglist 2], [lindex $arglist 3])" }
        "t3d mat4_mul" { return "t3d_mat4_mul([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2])" }
        "t3d mat4_from_srt" { return "t3d_mat4_from_srt([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2], [pak::cg_addr $arglist 3])" }
        "t3d mat4_from_srt_euler" { return "t3d_mat4_from_srt_euler([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2], [pak::cg_addr $arglist 3])" }
        "t3d mat4_invert" { return "t3d_mat4_invert([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1])" }
        "t3d mat4_transpose" { return "t3d_mat4_transpose([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1])" }
        "t3d vec3_norm" { return "t3d_vec3_norm([pak::cg_addr $arglist 0])" }
        "t3d vec3_cross" { return "t3d_vec3_cross([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2])" }
        "t3d vec3_dot" { return "t3d_vec3_dot([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1])" }
        "t3d vec3_lerp" { return "t3d_vec3_lerp([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2], [lindex $arglist 3])" }
        "t3d quat_identity" { return "t3d_quat_identity([pak::cg_addr $arglist 0])" }
        "t3d quat_from_axis_angle" { return "t3d_quat_from_axis_angle([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [lindex $arglist 2])" }
        "t3d quat_mul" { return "t3d_quat_mul([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2])" }
        "t3d quat_nlerp" { return "t3d_quat_nlerp([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2], [lindex $arglist 3])" }
        "t3d quat_slerp" { return "t3d_quat_slerp([pak::cg_addr $arglist 0], [pak::cg_addr $arglist 1], [pak::cg_addr $arglist 2], [lindex $arglist 3])" }
        "t3d fog_set_enabled" { return "t3d_fog_set_enabled([expr {[llength $arglist] > 0 ? [lindex $arglist 0] : "true"}])" }
        "math abs_i32"   { return "abs([lindex $arglist 0])" }
        "math min_i32"   { return "MIN([lindex $arglist 0], [lindex $arglist 1])" }
        "math max_i32"   { return "MAX([lindex $arglist 0], [lindex $arglist 1])" }
        "math clamp_i32" { return "CLAMP([lindex $arglist 0], [lindex $arglist 1], [lindex $arglist 2])" }
        "math sin_f"     { return "sinf([lindex $arglist 0])" }
        "math cos_f"     { return "cosf([lindex $arglist 0])" }
        "math sqrt_f"    { return "sqrtf([lindex $arglist 0])" }
        "math atan2_f"   { return "atan2f([lindex $arglist 0], [lindex $arglist 1])" }
        "math lerp_f"    { return "([lindex $arglist 0] + ([lindex $arglist 1] - [lindex $arglist 0]) * [lindex $arglist 2])" }
        "math fix_to_f"  { return "((float)([lindex $arglist 0]) / 65536.0f)" }
        "math f_to_fix"  { return "((int32_t)(([lindex $arglist 0]) * 65536.0f))" }
        "math abs_f"     { return "fabsf([lindex $arglist 0])" }
        "math min_f"     { return "fminf([lindex $arglist 0], [lindex $arglist 1])" }
        "math max_f"     { return "fmaxf([lindex $arglist 0], [lindex $arglist 1])" }
        "math clamp_f"   { return "fminf(fmaxf([lindex $arglist 0], [lindex $arglist 1]), [lindex $arglist 2])" }
        "math floor_f"   { return "floorf([lindex $arglist 0])" }
        "math ceil_f"    { return "ceilf([lindex $arglist 0])" }
        "math pow_f"     { return "powf([lindex $arglist 0], [lindex $arglist 1])" }
        "math tan_f"     { return "tanf([lindex $arglist 0])" }
        "math fix_sin"   { return "((int32_t)(sinf((float)([lindex $arglist 0]) / 65536.0f) * 65536.0f))" }
        "math fix_cos"   { return "((int32_t)(cosf((float)([lindex $arglist 0]) / 65536.0f) * 65536.0f))" }
        "math fix_sqrt"  { return "((int32_t)(sqrtf((float)([lindex $arglist 0]) / 65536.0f) * 65536.0f))" }
        "math rand"        { return "__pak_rand()" }
        "math rand_seed"   { return "__pak_srand([lindex $arglist 0])" }
        "math rand_range"  { return "__pak_rand_range([lindex $arglist 0], [lindex $arglist 1])" }
        "math rand_f"      { return "__pak_rand_f()" }
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
