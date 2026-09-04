# tcl/codegen.tcl — Pak → C code generator (the libdragon backend).
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
             variant_case_fields \
             struct_fields scopes method_registry trait_decls const_values \
             generic_fns generic_structs generic_impls mono_struct_origin \
             module_headers defer_stack result_typedefs \
             result_typedef_names slice_typedefs slice_typedef_names \
             tuple_typedefs tuple_typedef_names vec_typedefs vec_typedef_names vec_used \
             container_typedefs container_typedef_names \
             current_ret_type current_self_type closures fmt_counter tmp_counter \
             mono_cache pending_mono pending_nested _in_stmt loop_result_var loop_res_counter \
             fn_decls use_aliases allocator_used

    constructor {{fname "<unknown>"} {mod_headers {}}} {
        set filename $fname
        set uses {}
        set assets {}
        set module_name ""
        set fn_names {}
        set fn_decls [dict create]
        set use_aliases [dict create]
        set allocator_used 0
        set enum_variants [dict create]
        set variant_types [dict create]
        set variant_case_fields [dict create]
        set struct_fields [dict create]
        set scopes [list [dict create]]
        set defer_stack [list {}]
        set method_registry [dict create]
        set trait_decls [dict create]
        set const_values [dict create]
        set generic_fns [dict create]
        set generic_structs [dict create]
        set generic_impls [dict create]
        set mono_struct_origin [dict create]
        set module_headers $mod_headers
        set result_typedefs {}
        set result_typedef_names [dict create]
        set slice_typedefs {}
        set slice_typedef_names [dict create]
        set tuple_typedefs {}
        set tuple_typedef_names [dict create]
        set vec_typedefs {}
        set vec_typedef_names [dict create]
        set vec_used 0
        set container_typedefs {}
        set container_typedef_names [dict create]
        set current_ret_type ""
        set current_self_type ""
        set closures {}
        set fmt_counter 0
        set tmp_counter 0
        set mono_cache [dict create]
        set pending_mono {}
        set pending_nested {}
        set _in_stmt 0
        set loop_result_var {}
        set loop_res_counter 0
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

    method slice_typedef {inner_type} {
        set c_inner [my gen_type $inner_type]
        set safe [string map {" " _ "*" p "," "" "(" "" ")" ""} $c_inner]
        set tdname "PakSlice_$safe"
        if {![dict exists $slice_typedef_names $tdname]} {
            dict set slice_typedef_names $tdname 1
            lappend slice_typedefs [list $tdname $c_inner]
        }
        return $tdname
    }

    method tuple_typedef {c_types} {
        set safe [join [lmap ct $c_types {string map {" " _ "*" p "," "" "(" "" ")" ""} $ct}] _]
        set tdname "PakTuple[llength $c_types]_$safe"
        if {![dict exists $tuple_typedef_names $tdname]} {
            dict set tuple_typedef_names $tdname 1
            lappend tuple_typedefs [list $tdname $c_types]
        }
        return $tdname
    }

    method vec_typedef {elem_c_type} {
        set safe [string map {" " _ "*" p "," ""} $elem_c_type]
        set tdname "_PakVec_$safe"
        if {![dict exists $vec_typedef_names $tdname]} {
            dict set vec_typedef_names $tdname 1
            lappend vec_typedefs [list $tdname $elem_c_type]
            set vec_used 1
        }
        return $tdname
    }

    method container_typedef {t} {
        set kind [pak::fval $t name]
        set args [pak::items [pak::nfield $t args]]
        if {$kind eq "FixedMap"} {
            set k_type [expr {[llength $args] > 0 ? [my gen_type [lindex $args 0]] : "int32_t"}]
            set v_type [expr {[llength $args] > 1 ? [my gen_type [lindex $args 1]] : "int32_t"}]
            set cap    [expr {[llength $args] > 2 && [pak::kindof [lindex $args 2]] eq "IntLit" ? [pak::fval [lindex $args 2] value] : 16}]
            set safe_k [string map {" " _ "*" p} $k_type]
            set safe_v [string map {" " _ "*" p} $v_type]
            set tname "_PakMap_${safe_k}_${safe_v}_${cap}"
            if {![dict exists $container_typedef_names $tname]} {
                dict set container_typedef_names $tname 1
                lappend container_typedefs [list $tname FixedMap $k_type $v_type $cap]
            }
        } else {
            set elem_type [expr {[llength $args] > 0 ? [my gen_type [lindex $args 0]] : "int32_t"}]
            set cap [expr {[llength $args] > 1 && [pak::kindof [lindex $args 1]] eq "IntLit" ? [pak::fval [lindex $args 1] value] : 16}]
            set safe [string map {" " _ "*" p} $elem_type]
            set prefix [dict get {FixedList _PakList RingBuffer _PakRBuf Pool _PakPool} $kind]
            set tname "${prefix}_${safe}_${cap}"
            if {![dict exists $container_typedef_names $tname]} {
                dict set container_typedef_names $tname 1
                lappend container_typedefs [list $tname $kind $elem_type {} $cap]
            }
        }
        return $tname
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

    method container_kind {t} {
        if {[pak::kindof $t] eq "TypeGeneric" && [pak::fval $t name] in {Vec FixedList RingBuffer FixedMap Pool}} {
            return [pak::fval $t name]
        }
        return ""
    }
    method infer_c_type_for_elem {e} {
        set t [my expr_type $e]
        if {$t ne "" && ![pak::isnil $t]} { return [my gen_type $t] }
        switch -- [pak::kindof $e] {
            IntLit    { return "int32_t" }
            FloatLit  { return "float" }
            BoolLit   { return "bool" }
            StringLit { return "const char *" }
            TupleLit  {
                set inner [lmap el [pak::items [pak::nfield $e elements]] {my infer_c_type_for_elem $el}]
                return [my tuple_typedef $inner]
            }
        }
        return "void *"
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
                if {$n eq "Self" && $current_self_type ne ""} { return $current_self_type }
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
            TypeSlice  { return [my slice_typedef [pak::nfield $t inner]] }
            TypeTuple  {
                set ctypes [lmap el [pak::items [pak::nfield $t elements]] {my gen_type $el}]
                return [my tuple_typedef $ctypes]
            }
            TypeGeneric {
                set gname [pak::fval $t name]
                set args  [pak::items [pak::nfield $t args]]
                if {$gname in {List Slice Array} && [llength $args] == 1} {
                    return [my slice_typedef [lindex $args 0]]
                }
                if {$gname in {FixedList RingBuffer FixedMap Pool}} {
                    return [my container_typedef $t]
                }
                if {$gname eq "Vec" && [llength $args] > 0} {
                    return [my vec_typedef [my gen_type [lindex $args 0]]]
                }
                # Generic struct: Foo<i32, Str> → Foo_i32_Str
                set cargs [join [lmap a $args {
                    if {[pak::kindof $a] eq "IntLit"} { pak::fval $a value } \
                    else { string map {" " _ "*" p "," ""} [my gen_type $a] }
                }] _]
                return "${gname}_${cargs}"
            }
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
                if {[my container_kind $ot] in {Vec FixedList Pool RingBuffer}} { return "($obj).data\[$idx\]" }
                return "$obj\[$idx\]"
            }
            Call      { return [my gen_call $e] }
            StructLit {
                set type_name [my struct_lit_c_name $e]
                set parts {}
                foreach pair [pak::items [pak::nfield $e fields]] {
                    set p [pak::items $pair]
                    lappend parts ".[pak::sval [lindex $p 0]] = [my gen_expr [lindex $p 1]]"
                }
                return "($type_name){[join $parts {, }]}"
            }
            VariantLit {
                set vt [pak::fval $e variant_type]
                set vc [pak::fval $e case_name]
                set parts {}
                foreach pair [pak::items [pak::nfield $e fields]] {
                    set p [pak::items $pair]
                    lappend parts ".[pak::sval [lindex $p 0]] = [my gen_expr [lindex $p 1]]"
                }
                return "($vt)\{.tag = ${vt}_tag_$vc, .data.$vc = \{[join $parts {, }]\}\}"
            }
            ArrayLit  { return [my gen_array_lit $e] }
            UnaryOp {
                set op [pak::fval $e op]
                if {$op eq "?"} {
                    # Postfix null-check: true when the pointer/option is not none.
                    return "([my gen_expr [pak::nfield $e operand]] != NULL)"
                }
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
                if {[dict exists $enum_variants $n]} {
                    set owner [dict get $enum_variants $n]
                    set vc [my gen_variant_ctor $owner $n {}]
                    if {$vc ne ""} { return $vc }
                    return "${owner}_$n"
                }
                return $n
            }
            TupleAccess { return "([my gen_expr [pak::nfield $e obj]]).f[pak::fval $e index]" }
            TupleLit {
                set elems [pak::items [pak::nfield $e elements]]
                set ctypes [lmap el $elems { my infer_c_type_for_elem $el }]
                set tdname [my tuple_typedef $ctypes]
                set parts {}
                set i 0
                foreach el $elems { lappend parts ".f$i = [my gen_expr $el]"; incr i }
                return "($tdname)\{[join $parts {, }]\}"
            }
            SliceExpr {
                set obj_str [my gen_expr [pak::nfield $e obj]]
                set start_node [pak::nfield $e start]
                set end_node   [pak::nfield $e end]
                set start [expr {[pak::isnil $start_node] ? "0" : [my gen_expr $start_node]}]
                set obj_type [my expr_type [pak::nfield $e obj]]
                if {![pak::isnil $end_node]} {
                    set end_str [my gen_expr $end_node]
                    set length "($end_str) - ($start)"
                } elseif {[pak::kindof $obj_type] eq "TypeArray" && [pak::kindof [pak::nfield $obj_type size]] eq "IntLit"} {
                    set sz [pak::fval [pak::nfield $obj_type size] value]
                    set length "(int)($sz) - ($start)"
                } else {
                    set length "/* slice length unknown */ 0"
                }
                if {[pak::kindof $obj_type] eq "TypeArray"} {
                    set inner_type [pak::nfield $obj_type inner]
                } elseif {[pak::kindof $obj_type] eq "TypeSlice"} {
                    set inner_type [pak::nfield $obj_type inner]
                } else {
                    set inner_type [pak::N TypeName name auto]
                }
                set tdname [my slice_typedef $inner_type]
                return "($tdname)\{ .data = &($obj_str)\[$start\], .len = $length \}"
            }
            SizeOf {
                set op [pak::nfield $e operand]
                if {[pak::kindof $op] in {TypeName TypePointer TypeArray TypeSlice TypeResult TypeGeneric TypeVolatile}} {
                    return "sizeof([my gen_type $op])"
                }
                return "sizeof([my gen_expr $op])"
            }
            AlignOf {
                set op [pak::nfield $e operand]
                if {[pak::kindof $op] in {TypeName TypePointer TypeArray TypeSlice TypeResult TypeGeneric TypeVolatile}} {
                    return "__alignof__([my gen_type $op])"
                }
                return "__alignof__([my gen_expr $op])"
            }
            AsmExpr { return [my gen_asm_expr $e] }
            OffsetOf { return "offsetof([pak::fval $e type_name], [pak::fval $e field])" }
            AllocExpr {
                set ct [my gen_type [pak::nfield $e type_node]]
                set count [pak::nfield $e count]
                set alloc [pak::nfield $e allocator]
                # `alloc(T using a)` dispatches through the allocator vtable;
                # the plain form goes straight to malloc.
                if {![pak::isnil $alloc]} {
                    set allocator_used 1
                    set ac [my gen_expr $alloc]
                    if {![pak::isnil $count]} {
                        return "($ct *)($ac).vtable->alloc_bytes(($ac).self,\
 sizeof($ct) * (size_t)([my gen_expr $count]))"
                    }
                    return "($ct *)($ac).vtable->alloc_bytes(($ac).self, sizeof($ct))"
                }
                if {![pak::isnil $count]} {
                    return "($ct *)malloc(sizeof($ct) * (size_t)([my gen_expr $count]))"
                }
                return "($ct *)malloc(sizeof($ct))"
            }
            FreeExpr {
                set ptr [my gen_expr [pak::nfield $e ptr]]
                set alloc [pak::nfield $e allocator]
                if {![pak::isnil $alloc]} {
                    set allocator_used 1
                    set ac [my gen_expr $alloc]
                    return "($ac).vtable->dealloc_bytes(($ac).self, $ptr)"
                }
                return "free($ptr)"
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
            RangeExpr { pak::cg_unported "RangeExpr-as-expr (only valid in for-loop or slice)" }
            default { pak::cg_unported "expr:[pak::kindof $e]" }
        }
    }

    method gen_dot {e} {
        set obj [pak::nfield $e obj]
        set obj_str [my gen_expr $obj]
        set field [pak::fval $e field]
        if {[pak::kindof $obj] eq "Ident"} {
            set n [pak::fval $obj name]
            # A unit variant case is still a value of the variant type, so it
            # needs the tagged literal an enum member does not.
            set vc [my gen_variant_ctor $n $field {}]
            if {$vc ne ""} { return $vc }
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
        return "%d"
    }
    method fmt_arg_for_expr {expr spec} {
        set c [my gen_expr $expr]
        switch -- $spec {
            "%lld" { return "(long long)($c)" }
            "%llu" { return "(unsigned long long)($c)" }
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

    # Inline assembly expression: __asm__ __volatile__("tmpl" : outs : ins : clobbers)
    method gen_asm_expr {e} {
        set vol [expr {[pak::fval $e volatile] ? "__volatile__" : ""}]
        set out "__asm__ ${vol}(\"[pak::fval $e template]\""
        set outs [pak::items [pak::nfield $e outputs]]
        set ins  [pak::items [pak::nfield $e inputs]]
        set clob [pak::fval $e clobbers]
        if {[llength $outs] || [llength $ins] || [llength $clob]} {
            set op {}
            foreach o $outs {
                set pair [pak::items $o]
                lappend op "\"[pak::sval [lindex $pair 0]]\"([my gen_expr [lindex $pair 1]])"
            }
            set ip {}
            foreach i $ins {
                set pair [pak::items $i]
                lappend ip "\"[pak::sval [lindex $pair 0]]\"([my gen_expr [lindex $pair 1]])"
            }
            append out " : [join $op {, }] : [join $ip {, }]"
            if {[llength $clob]} {
                set cp {}
                foreach c $clob { lappend cp "\"[pak::sval $c]\"" }
                append out " : [join $cp {, }]"
            }
        }
        append out ")"
        return $out
    }

    # ── closures (mirror codegen._gen_closure / _emit_closures) ────────────────
    method gen_closure {e} {
        if {$_in_stmt} {
            # Inside a statement: emit as GCC nested function inline (mirrors Python _pending_nested)
            set name "_pak_clo_[expr {[llength $closures] + [llength $pending_nested]}]"
            lappend pending_nested [list $name $e]
            return $name
        }
        # At top level: emit as static function at file scope
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
    # Emit pending_nested closures as GCC nested function definitions at indent.
    # Mirrors Python _emit_nested_closure / the hoisted-defs loop in gen_stmt.
    method emit_nested_closures {indent pairs} {
        set pad [string repeat "    " $indent]
        set inner [string repeat "    " [expr {$indent + 1}]]
        set lines {}
        foreach pair $pairs {
            lassign $pair name e
            set rt [pak::nfield $e ret_type]
            set ret [expr {[pak::isnil $rt] ? "void" : [my gen_type $rt]}]
            set params {}
            foreach p [pak::items [pak::nfield $e params]] {
                lappend params "[my gen_type [pak::nfield $p type]] [pak::fval $p name]"
            }
            set param_str [expr {[llength $params] > 0 ? [join $params {, }] : "void"}]
            lappend lines "${pad}$ret ${name}($param_str) {"
            my scope_push
            foreach p [pak::items [pak::nfield $e params]] {
                my scope_set [pak::fval $p name] [pak::nfield $p type]
            }
            foreach st [pak::items [pak::nfield [pak::nfield $e body] stmts]] {
                set s [my gen_stmt $st [expr {$indent + 1}]]
                if {$s ne ""} { lappend lines $s }
            }
            my scope_pop
            lappend lines "${pad}}"
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

    method monomorphize_struct {struct_name type_args} {
        set struct_decl [dict get $generic_structs $struct_name]
        set c_type_args [lmap t $type_args {my gen_type $t}]
        set cache_key "${struct_name}:[join $c_type_args ,]"
        if {[dict exists $mono_cache $cache_key]} { return [dict get $mono_cache $cache_key] }
        set safe [join [lmap t $c_type_args {string map {" " _ "*" p "," ""} $t}] _]
        set specialized_name "${struct_name}_${safe}"
        dict set mono_cache $cache_key $specialized_name
        set subst [dict create]
        set type_params [pak::items [pak::nfield $struct_decl type_params]]
        for {set i 0} {$i < [llength $type_params]} {incr i} {
            if {$i < [llength $type_args]} {
                dict set subst [pak::sval [lindex $type_params $i]] [lindex $type_args $i]
            }
        }
        set new_fields {}
        foreach f [pak::items [pak::nfield $struct_decl fields]] {
            lappend new_fields [pak::N StructField \
                name [pak::fval $f name] \
                type [pak::cg_subst_type [pak::nfield $f type] $subst] \
                annotations {} default_value [pak::Nil] bit_width [pak::Nil]]
        }
        set spec_decl [pak::N StructDecl \
            name $specialized_name fields $new_fields \
            type_params {} annotations [pak::nfield $struct_decl annotations]]
        lappend pending_mono $spec_decl
        foreach f $new_fields {
            dict set struct_fields $specialized_name [pak::fval $f name] [pak::nfield $f type]
        }
        dict set mono_struct_origin $specialized_name [list $struct_name $type_args]
        return $specialized_name
    }

    method struct_lit_c_name {e} {
        set tname [pak::fval $e type_name]
        set type_args [pak::items [pak::nfield $e type_args]]
        if {[llength $type_args] > 0 && [dict exists $generic_structs $tname]} {
            return [my monomorphize_struct $tname $type_args]
        }
        return $tname
    }

    method monomorphize_impl_methods {spec_struct} {
        if {[dict exists $method_registry $spec_struct]} { return }
        if {![dict exists $mono_struct_origin $spec_struct]} { return }
        lassign [dict get $mono_struct_origin $spec_struct] base type_args
        if {![dict exists $generic_impls $base]} { return }
        set impl [dict get $generic_impls $base]
        set subst [dict create]
        set impl_type_params [pak::items [pak::nfield $impl type_params]]
        for {set i 0} {$i < [llength $impl_type_params]} {incr i} {
            if {$i < [llength $type_args]} {
                dict set subst [pak::sval [lindex $impl_type_params $i]] [lindex $type_args $i]
            }
        }
        dict set method_registry $spec_struct [dict create]
        foreach m [pak::items [pak::nfield $impl methods]] {
            set new_params {}
            foreach p [pak::items [pak::nfield $m params]] {
                if {[pak::fval $p name] eq "self"} {
                    set new_type [pak::N TypePointer inner [pak::N TypeName name $spec_struct] nullable 0 mutable 1]
                } else {
                    set new_type [pak::cg_subst_type [pak::nfield $p type] $subst]
                }
                lappend new_params [pak::N Param \
                    name [pak::fval $p name] type $new_type \
                    mutable [pak::fval $p mutable] default_value [pak::nfield $p default_value]]
            }
            set new_ret [pak::cg_subst_type [pak::nfield $m ret_type] $subst]
            set spec_m [pak::N FnDecl \
                name [pak::fval $m name] params $new_params ret_type $new_ret \
                body [pak::nfield $m body] type_params {} annotations {} \
                is_method 1 self_type [pak::N TypeName name $spec_struct] variadic 0]
            dict set method_registry $spec_struct [pak::fval $m name] $spec_m
            lappend pending_mono [list impl_method $spec_struct $spec_m]
        }
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
        if {$type_name in {FixedList RingBuffer FixedMap Pool Vec}} {
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
            if {[pak::kindof $obj_type] eq "TypeArray"} {
                set inner_t [pak::nfield $obj_type inner]
                set td [my slice_typedef $inner_t]
                set sz [my gen_expr [pak::nfield $obj_type size]]
                return "($td)\{.data = ($obj), .len = (int32_t)($sz)\}"
            }
            return "(\{ __auto_type _arr = &($obj)\[0\]; (void*)_arr; \})"
        }
        if {$method eq "get_unchecked" && $na == 1} {
            if {[pak::kindof $obj_type] eq "TypeSlice"} { return "($obj).data\[$a0\]" }
            return "($obj)\[$a0\]"
        }
        if {$method eq "len" && $na == 0} {
            if {[pak::kindof $obj_type] eq "TypeSlice"} { return "($obj).len" }
            if {[pak::kindof $obj_type] eq "TypeArray"} { return "(int32_t)(sizeof($obj)/sizeof(($obj)\[0\]))" }
            # A CStr is char *, which has no .len -- fall through to the string
            # block below, where len is strlen. Returning ($obj).len here made
            # cstr.len() a member access on a pointer.
            if {!($c_type in {"const char *" "char *"} \
                  || ([pak::kindof $obj_type] eq "TypeName" \
                      && [pak::fval $obj_type name] in {CStr c_char}))} {
                return "($obj).len"
            }
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
        # ── FixedList / Pool instance methods ────────────────────────────────
        if {[pak::kindof $obj_type] eq "TypeGeneric"} {
            set gn [pak::fval $obj_type name]
            if {$gn in {FixedList Pool}} {
                set args [pak::fval $obj_type args]
                set cap [expr {[llength $args] > 1 ? [pak::fval [lindex $args 1] value] : 16}]
                set elem_t [my gen_type [lindex $args 0]]
                if {$method eq "init"} {
                    return "memset(&($obj), 0, sizeof($obj))"
                }
                if {$method eq "push" && $na > 0} {
                    return "(($obj).len < $cap ? (($obj).data\[($obj).len++\] = ($a0), 1) : 0)"
                }
                if {$method eq "pop"} {
                    return "($obj).data\[--($obj).len\]"
                }
                if {$method eq "remove" && $na > 0} {
                    return "({ int32_t _ri = ($a0); ($obj).data\[_ri\] = ($obj).data\[--($obj).len\]; })"
                }
                if {$method in {items slice}} {
                    return "($elem_t \*){ .data = ($obj).data, .len = ($obj).len }"
                }
                if {$method eq "len" && $na == 0} {
                    return "($obj).len"
                }
                if {$method eq "is_empty" && $na == 0} {
                    return "(($obj).len == 0)"
                }
                if {$method eq "acquire"} {
                    return "(($elem_t *)pak_pool_acquire(&($obj)))"
                }
                if {$method eq "release" && $na > 0} {
                    return "pak_pool_release(&($obj), $a0)"
                }
            }
            # ── RingBuffer instance methods ───────────────────────────────────
            if {$gn eq "RingBuffer"} {
                set args [pak::fval $obj_type args]
                set cap [expr {[llength $args] > 1 ? [pak::fval [lindex $args 1] value] : 16}]
                if {$method eq "init"} {
                    return "memset(&($obj), 0, sizeof($obj))"
                }
                if {$method eq "push" && $na > 0} {
                    return "({ ($obj).data\[($obj).tail\] = ($a0); ($obj).tail = (($obj).tail + 1) % $cap; if (($obj).len < $cap) ($obj).len++; })"
                }
                if {$method eq "peek_back" && $na > 0} {
                    return "($obj).data\[(($obj).tail - ($a0) - 1 + $cap) % $cap\]"
                }
                if {$method eq "pop"} {
                    return "({ __auto_type _v = ($obj).data\[($obj).head\]; ($obj).head = (($obj).head + 1) % $cap; if (($obj).len > 0) ($obj).len--; _v; })"
                }
                if {$method eq "is_empty" && $na == 0} {
                    return "(($obj).len == 0)"
                }
            }
            # ── FixedMap instance methods ─────────────────────────────────────
            if {$gn eq "FixedMap"} {
                set args [pak::fval $obj_type args]
                set k_type [expr {[llength $args] > 0 ? [my gen_type [lindex $args 0]] : "int32_t"}]
                set v_type [expr {[llength $args] > 1 ? [my gen_type [lindex $args 1]] : "int32_t"}]
                set cap [expr {[llength $args] > 2 ? [pak::fval [lindex $args 2] value] : 16}]
                set ksuf [expr {$k_type in {"const char *" "char *"} ? "_str" : ""}]
                if {$method eq "init"} {
                    return "memset(&($obj), 0, sizeof($obj))"
                }
                if {$method eq "set" && $na == 2} {
                    return "pak_map_set${ksuf}(&($obj), $cap, $a0, $a1)"
                }
                if {$method eq "get" && $na > 0} {
                    return "(($v_type *)pak_map_get${ksuf}(&($obj), $cap, $a0))"
                }
                if {$method in {has contains} && $na > 0} {
                    return "pak_map_has${ksuf}(&($obj), $cap, $a0)"
                }
                if {$method eq "remove" && $na > 0} {
                    return "pak_map_remove${ksuf}(&($obj), $cap, $a0)"
                }
                if {$method in {len count} && $na == 0} {
                    return "($obj).len"
                }
                if {$method eq "is_empty" && $na == 0} {
                    return "(($obj).len == 0)"
                }
            }
            # ── Vec(T) dynamic vector methods ─────────────────────────────────
            if {$gn eq "Vec"} {
                set args [pak::fval $obj_type args]
                set elem_t [expr {[llength $args] > 0 ? [my gen_type [lindex $args 0]] : "void *"}]
                if {$method eq "init"} {
                    return "memset(&($obj), 0, sizeof($obj))"
                }
                if {$method eq "push" && $na > 0} {
                    return "_PAK_VEC_PUSH(&($obj), ($a0))"
                }
                if {$method eq "pop"} {
                    return "(($obj).len > 0 ? ($obj).data\[--($obj).len\] : ($obj).data\[0\])"
                }
                if {$method eq "get" && $na > 0} {
                    return "($obj).data\[$a0\]"
                }
                if {$method eq "len" && $na == 0} {
                    return "($obj).len"
                }
                if {$method eq "is_empty" && $na == 0} {
                    return "(($obj).len == 0)"
                }
                if {$method eq "clear" && $na == 0} {
                    return "(($obj).len = 0)"
                }
                if {$method eq "reserve" && $na > 0} {
                    return "(($obj).cap < ($a0) ? (($obj).data = ($elem_t *)realloc(($obj).data, (size_t)($a0) * sizeof(*($obj).data)), ($obj).cap = ($a0), (void)0) : (void)0)"
                }
                if {$method eq "free" && $na == 0} {
                    return "({ free(($obj).data); ($obj).data = NULL; ($obj).len = ($obj).cap = 0; })"
                }
            }
        }
        # ── CStr / Str / PakStr string methods ───────────────────────────────
        set is_cstr [expr {$c_type in {"const char *" "char *"} || ([pak::kindof $obj_type] eq "TypeName" && [pak::fval $obj_type name] in {CStr c_char})}]
        set is_pakstr [expr {$c_type eq "PakStr" || ([pak::kindof $obj_type] eq "TypeName" && [pak::fval $obj_type name] in {Str PakStr})}]
        if {$is_cstr} {
            if {$method eq "len" && $na == 0} {
                return "(int32_t)strlen($obj)"
            }
            if {$method eq "contains" && $na == 1} {
                return "(strstr($obj, $a0) != NULL)"
            }
            if {$method eq "starts_with" && $na == 1} {
                return "(strncmp($obj, $a0, strlen($a0)) == 0)"
            }
            if {$method eq "ends_with" && $na == 1} {
                return "(strlen($obj) >= strlen($a0) && strcmp(($obj) + strlen($obj) - strlen($a0), $a0) == 0)"
            }
            if {$method eq "eq" && $na == 1} {
                return "(strcmp($obj, $a0) == 0)"
            }
            if {$method eq "cmp" && $na == 1} {
                return "strcmp($obj, $a0)"
            }
            if {$method eq "is_empty" && $na == 0} {
                return "(($obj)\[0\] == '\\0')"
            }
            if {$method eq "as_bytes" && $na == 0} {
                return "(const uint8_t *)($obj)"
            }
            if {$method eq "to_pakstr" && $na == 0} {
                return "pak_str_from_cstr($obj)"
            }
            if {$method eq "find" && $na == 1} {
                return "({ const char *_h = strstr($obj, $a0); _h ? (int32_t)(_h - ($obj)) : -1; })"
            }
            if {$method eq "slice" && $na == 1} {
                return "(($obj) + ($a0))"
            }
            if {$method eq "slice" && $na == 2} {
                return "(PakStr){ .data = ($obj) + ($a0), .len = ($a1) }"
            }
            if {$method eq "copy_to" && $na == 2} {
                return "(snprintf($a0, (size_t)($a1), \"%s\", $obj), $a0)"
            }
            if {$method eq "concat_into" && $na == 3} {
                set a2 [lindex $arglist 2]
                return "(snprintf($a0, (size_t)($a1), \"%s%s\", $obj, $a2), $a0)"
            }
            if {$method eq "format_into" && $na >= 2} {
                set rest_args [lrange $arglist 2 end]
                set fmt_arg [expr {[llength $rest_args] > 0 ? ", [join $rest_args {, }]" : ""}]
                return "snprintf($a0, (size_t)($a1), $obj$fmt_arg)"
            }
        }
        if {$is_pakstr} {
            if {$method eq "len" && $na == 0} {
                return "($obj).len"
            }
            if {$method eq "data" && $na == 0} {
                return "($obj).data"
            }
            if {$method eq "eq" && $na == 1} {
                return "pak_str_eq($obj, $a0)"
            }
            if {$method eq "is_empty" && $na == 0} {
                return "(($obj).len == 0)"
            }
            if {$method eq "as_cstr" && $na == 0} {
                return "($obj).data"
            }
            if {$method eq "contains" && $na == 1} {
                return "(memmem(($obj).data, (size_t)($obj).len, ($a0).data, (size_t)($a0).len) != NULL)"
            }
            if {$method eq "find" && $na == 1} {
                return "({ const void *_h = memmem(($obj).data, (size_t)($obj).len, ($a0).data, (size_t)($a0).len); _h ? (int32_t)((const char *)_h - ($obj).data) : -1; })"
            }
            if {$method eq "slice" && $na == 2} {
                return "(PakStr){ .data = ($obj).data + ($a0), .len = ($a1) }"
            }
            if {$method eq "starts_with" && $na == 1} {
                return "(($obj).len >= ($a0).len && memcmp(($obj).data, ($a0).data, (size_t)($a0).len) == 0)"
            }
            if {$method eq "ends_with" && $na == 1} {
                return "(($obj).len >= ($a0).len && memcmp(($obj).data + ($obj).len - ($a0).len, ($a0).data, (size_t)($a0).len) == 0)"
            }
            if {$method eq "copy_to" && $na == 2} {
                return "(snprintf($a0, (size_t)($a1), \"%.*s\", (int)($obj).len, ($obj).data), $a0)"
            }
        }
        return ""
    }

    # Resolve a call's arguments against a known function's parameter list,
    # placing NamedArg values by name rather than position and filling in
    # defaults for omitted params. Returns the ordered C argument strings.
    method apply_named_args_and_defaults {params arg_nodes} {
        set has_named 0
        foreach a $arg_nodes {
            if {[pak::kindof $a] eq "NamedArg"} { set has_named 1; break }
        }
        if {!$has_named && [llength $arg_nodes] >= [llength $params]} {
            set out {}
            foreach a $arg_nodes { lappend out [my gen_expr $a] }
            return $out
        }

        set n [llength $params]
        set result {}
        for {set i 0} {$i < $n} {incr i} { lappend result "" }
        set positional_idx 0

        foreach arg_node $arg_nodes {
            if {[pak::kindof $arg_node] eq "NamedArg"} {
                set want [pak::fval $arg_node name]
                for {set pi 0} {$pi < $n} {incr pi} {
                    if {[pak::fval [lindex $params $pi] name] eq $want} {
                        lset result $pi [my gen_expr [pak::nfield $arg_node value]]
                        break
                    }
                }
            } else {
                # Skip slots a named argument already claimed.
                while {$positional_idx < $n && [lindex $result $positional_idx] ne ""} {
                    incr positional_idx
                }
                if {$positional_idx < $n} {
                    lset result $positional_idx [my gen_expr $arg_node]
                    incr positional_idx
                }
            }
        }

        for {set i 0} {$i < $n} {incr i} {
            if {[lindex $result $i] ne ""} continue
            set dv [pak::nfield [lindex $params $i] default_value]
            if {![pak::isnil $dv]} { lset result $i [my gen_expr $dv] }
        }

        set out {}
        foreach r $result { if {$r ne ""} { lappend out $r } }
        return $out
    }

    # A variant case is a value, not a function: Shape.circle(5.0) is
    # (Shape){ .tag = Shape_tag_circle, .data.circle = { .field0 = 5.0f } }.
    # The payload struct is named Shape_circle, so there is no name left to
    # call -- emitting Shape_circle(5.0f) named the type and could never
    # compile. Returns "" when {tname case} is not a variant case.
    method gen_variant_ctor {tname case ctor_args} {
        if {![dict exists $variant_types $tname]} { return "" }
        if {![dict exists $enum_variants $case] || [dict get $enum_variants $case] ne $tname} { return "" }
        set tag "${tname}_tag_${case}"
        if {[llength $ctor_args] == 0} { return "(${tname}){ .tag = ${tag} }" }
        set field_names {}
        if {[dict exists $variant_case_fields $tname $case]} {
            set field_names [dict get $variant_case_fields $tname $case]
        }
        set parts {}
        set i 0
        foreach a $ctor_args {
            set fn [lindex $field_names $i]
            if {$fn eq ""} { set fn "field$i" }
            lappend parts ".$fn = $a"
            incr i
        }
        return "(${tname}){ .tag = ${tag}, .data.${case} = { [join $parts {, }] } }"
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
            if {$fnm eq "heap_allocator"} {
                set allocator_used 1
                return "pak_heap_allocator()"
            }
            if {$fnm eq "arena_allocator"} {
                set allocator_used 1
                set arg [expr {[llength $args] > 0 ? [lindex $args 0] : "0"}]
                return "Allocator_from_Arena($arg)"
            }
        }
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set type_name [pak::fval [pak::nfield $func obj] name]
            set method [pak::fval $func field]
            set r [my gen_variant_ctor $type_name $method $args]
            if {$r ne ""} { return $r }
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
            if {$tname ne "" && ![dict exists $method_registry $tname] && [dict exists $mono_struct_origin $tname]} {
                my monomorphize_impl_methods $tname
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
                # Named-arg reordering / default fill over the non-self params.
                set user_params [expr {[llength $params] > 0 ? [lrange $params 1 end] : {}}]
                set user_args [my apply_named_args_and_defaults $user_params \
                    [pak::items [pak::nfield $e args]]]
                set all_args [concat [list $self_arg] $user_args]
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
            if {[dict exists $use_aliases $mod]} { set mod [dict get $use_aliases $mod] }
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
        # Named-arg reordering / default fill for calls to a known function.
        if {[pak::kindof $func] eq "Ident"} {
            set fname [pak::fval $func name]
            if {[dict exists $fn_decls $fname]} {
                set params [pak::items [pak::nfield [dict get $fn_decls $fname] params]]
                set arg_nodes [pak::items [pak::nfield $e args]]
                set needs 0
                foreach a $arg_nodes {
                    if {[pak::kindof $a] eq "NamedArg"} { set needs 1; break }
                }
                if {[llength $arg_nodes] < [llength $params]} { set needs 1 }
                if {[llength $params] > 0 && $needs} {
                    set args [my apply_named_args_and_defaults $params $arg_nodes]
                }
            }
        }
        return "[my gen_expr $func]([join $args {, }])"
    }

    # ── statements ────────────────────────────────────────────────────────────
    # Wrapper: emit any capturing closures used by this statement as GCC
    # nested-function definitions in the enclosing block, just before the
    # statement that references them, so lexical capture is in scope.
    method gen_stmt {stmt indent} {
        set saved_pending $pending_nested
        set saved_in $_in_stmt
        set pending_nested {}
        set _in_stmt 1
        set body [my gen_stmt_body $stmt $indent]
        set hoisted $pending_nested
        set pending_nested $saved_pending
        set _in_stmt $saved_in
        if {[llength $hoisted] > 0} {
            set defs [my emit_nested_closures $indent $hoisted]
            set pad [string repeat "    " $indent]
            return "[join $defs \n]\n[expr {$body ne "" ? $body : "${pad};"}]"
        }
        return $body
    }

    method gen_stmt_body {stmt indent} {
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
            Break    {
                set bv [pak::nfield $stmt value]
                if {![pak::isnil $bv] && [llength $loop_result_var] > 0} {
                    set rv [lindex $loop_result_var end]
                    return "${pad}$rv = [my gen_expr $bv];\n${pad}break;"
                }
                return "${pad}break;"
            }
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
            ComptimeIf {
                set cond [my gen_expr [pak::nfield $stmt condition]]
                set then_lines {}
                foreach s [pak::items [pak::nfield [pak::nfield $stmt then] stmts]] {
                    set r [my gen_stmt $s $indent]
                    if {$r ne ""} { lappend then_lines $r }
                }
                set result "#if $cond\n[join $then_lines \n]"
                set else_br [pak::nfield $stmt else_branch]
                if {![pak::isnil $else_br]} {
                    set else_lines {}
                    foreach s [pak::items [pak::nfield $else_br stmts]] {
                        set r [my gen_stmt $s $indent]
                        if {$r ne ""} { lappend else_lines $r }
                    }
                    append result "\n#else\n[join $else_lines \n]"
                }
                append result "\n#endif"
                return $result
            }
            default     { pak::cg_unported "stmt:[pak::kindof $stmt]" }
        }
    }

    method gen_let_stmt {s pad} {
        set anns [pak::annlist_or $s]
        set typ [pak::nfield $s type]
        set name [pak::fval $s name]
        # `let _ = expr` discards the value. Emitting a real declaration named
        # `_` would collide with every other discard in the same scope, so the
        # value is evaluated and cast to void instead.
        if {$name eq "_"} {
            set v [pak::nfield $s value]
            if {[pak::isnil $v]} { return "" }
            return "${pad}(void)([my gen_expr $v]);"
        }
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
            # `let p: Pair<i32>` declares Pair_int32_t in C, but storing the
            # generic type here left the scope saying "Pair" -- a name with no
            # method registry and no monomorph entry, so p.sum_i32() fell all
            # the way through to member access on the struct. Record the
            # monomorphized name the declaration actually uses.
            if {[pak::kindof $typ] eq "TypeGeneric" && [dict exists $generic_structs [pak::fval $typ name]]} {
                my scope_set $name [pak::N TypeName name [my gen_type $typ]]
            } else {
                my scope_set $name $typ
            }
        } else {
            set decl "__auto_type $name"
            if {[pak::kindof [pak::nfield $s value]] eq "AddrOf"} {
                my scope_set $name [pak::N TypePointer inner [pak::N TypeName name auto] nullable 0 mutable 0]
            } elseif {[pak::kindof [pak::nfield $s value]] eq "StructLit"} {
                my scope_set $name [pak::N TypeName name [my struct_lit_c_name [pak::nfield $s value]]]
            }
        }
        set val [pak::nfield $s value]
        if {![pak::isnil $val] && [pak::kindof $val] ne "UndefinedLit"} {
            if {[pak::kindof $val] eq "CatchExpr"} { return [my gen_catch_let $s $val $pad $prefix $decl] }
            # loop-as-expression: let x = loop { ... break v ... }
            if {[pak::kindof $val] in {LoopStmt WhileStmt}} {
                incr loop_res_counter
                set rv "_loop_res_${loop_res_counter}"
                set c_type [expr {![pak::isnil $typ] ? [my gen_type $typ] : "int32_t"}]
                lappend loop_result_var $rv
                if {[pak::kindof $val] eq "LoopStmt"} {
                    set loop_body [my gen_loop $val $pad 1]
                } else {
                    set loop_body [my gen_while $val $pad 1]
                }
                set loop_result_var [lrange $loop_result_var 0 end-1]
                return "${pad}${c_type} ${rv} = (${c_type})0;\n${loop_body}\n${pad}${prefix}${decl} = ${rv};"
            }
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
        set prefix ""
        foreach ann $anns {
            if {[string match "*@aligned*" $ann]} {
                regexp {\((\d+)\)} $ann -> n
                set prefix "__attribute__((aligned($n))) $prefix"
            } elseif {$ann eq "@uncached"} {
                set prefix "__attribute__((aligned(16))) $prefix"
            }
        }
        set typ [pak::nfield $s type]
        if {![pak::isnil $typ]} { set decl [my gen_array_decl [pak::fval $s name] $typ] } \
        else { set decl "__auto_type [pak::fval $s name]" }
        set val [pak::nfield $s value]
        if {![pak::isnil $val] && [pak::kindof $val] ne "UndefinedLit"} {
            return "${pad}${prefix}static $decl = [my gen_expr $val];"
        }
        return "${pad}${prefix}static $decl;"
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
        set binding [pak::fval $s binding]
        set inner_pad  [string repeat "    " [expr {$indent+1}]]
        set inner2_pad [string repeat "    " [expr {$indent+2}]]
        set lines [list "${pad}\{"]
        lappend lines "${inner_pad}__auto_type $binding = ([my gen_expr [pak::nfield $s expr]]);"
        lappend lines "${inner_pad}if ($binding != NULL) \{"
        my scope_push
        my scope_set $binding [pak::N TypePointer inner [pak::N TypeName name auto] nullable 0 mutable 0]
        foreach st [pak::items [pak::nfield [pak::nfield $s then] stmts]] { lappend lines [my gen_stmt $st [expr {$indent+2}]] }
        foreach d [my emit_defers_for_scope [expr {$indent+2}]] { lappend lines $d }
        my scope_pop
        lappend lines "${inner_pad}\}"
        set eb [pak::nfield $s else_branch]
        if {![pak::isnil $eb]} {
            lappend lines "${inner_pad}else \{"
            my scope_push
            foreach st [pak::items [pak::nfield $eb stmts]] { lappend lines [my gen_stmt $st [expr {$indent+2}]] }
            foreach d [my emit_defers_for_scope [expr {$indent+2}]] { lappend lines $d }
            my scope_pop
            lappend lines "${inner_pad}\}"
        }
        lappend lines "${pad}\}"
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
            if {[pak::kindof $coll_type] eq "TypeSlice" || [my container_kind $coll_type] in {Vec FixedList Pool RingBuffer}} {
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

    # When the matched expression has no declared type (let e = Event.quit, so
    # the C is __auto_type), fall back to the arms: every case name resolves to
    # exactly one variant or enum. Without this the switch is on the struct
    # rather than its tag, which no compiler accepts.
    method match_type_from_arms {arms} {
        foreach arm $arms {
            set pat [pak::nfield $arm pattern]
            set pn ""
            switch -- [pak::kindof $pat] {
                EnumVariantAccess { set pn [pak::fval $pat name] }
                DotAccess         { set pn [pak::fval $pat field] }
                Call {
                    set fn [pak::nfield $pat func]
                    switch -- [pak::kindof $fn] {
                        EnumVariantAccess { set pn [pak::fval $fn name] }
                        DotAccess         { set pn [pak::fval $fn field] }
                    }
                }
            }
            if {$pn ne "" && [dict exists $enum_variants $pn]} {
                return [dict get $enum_variants $pn]
            }
        }
        return ""
    }

    method pattern_cond {pat expr_var is_variant match_type} {
        switch -- [pak::kindof $pat] {
            Ident { return "1" }
            Call {
                set fn [pak::nfield $pat func]
                if {[pak::kindof $fn] eq "EnumVariantAccess"} {
                    set pn [pak::fval $fn name]
                    set tn [expr {[dict exists $enum_variants $pn] ? [dict get $enum_variants $pn] : ""}]
                    if {[dict exists $variant_types $tn]} { return "${expr_var}.tag == ${tn}_tag_${pn}" }
                    if {$tn ne ""} { return "${expr_var} == ${tn}_${pn}" }
                    return "${expr_var} == ${pn}"
                }
                return "1"
            }
            EnumVariantAccess {
                set pn [pak::fval $pat name]
                set tn [expr {[dict exists $enum_variants $pn] ? [dict get $enum_variants $pn] : ""}]
                if {[dict exists $variant_types $tn]} { return "${expr_var}.tag == ${tn}_tag_${pn}" }
                if {$tn ne ""} { return "${expr_var} == ${tn}_${pn}" }
                return "${expr_var} == ${pn}"
            }
            DotAccess {
                set obj_name [my gen_expr [pak::nfield $pat obj]]
                if {[dict exists $variant_types $obj_name]} {
                    return "${expr_var}.tag == ${obj_name}_tag_[pak::fval $pat field]"
                }
                return "${expr_var} == ${obj_name}_[pak::fval $pat field]"
            }
            IntLit  { return "${expr_var} == [pak::fval $pat value]" }
            BoolLit { return "${expr_var} == [expr {[pak::fval $pat value] ? 1 : 0}]" }
        }
        return "1"
    }

    method pattern_bindings {pat expr_var} {
        switch -- [pak::kindof $pat] {
            Call { return [my call_arm_bindings $pat $expr_var] }
            DotAccess {
                if {[pak::isnil [pak::nfield $pat binding]]} { return {} }
                set obj_name [my gen_expr [pak::nfield $pat obj]]
                if {![dict exists $variant_types $obj_name]} { return {} }
                return [list [list [pak::sval [pak::nfield $pat binding]] "${expr_var}.data.[string tolower [pak::fval $pat field]]"]]
            }
        }
        return {}
    }

    # Bindings for `.Case(x, y)` and `.Case { field: name }` match arms.
    # C always names payload slots field0, field1, … in declaration order;
    # NamedArg looks the field up so `.Rect { h: hh, w: ww }` still binds right.
    method call_arm_bindings {pat expr_c} {
        set fn [pak::nfield $pat func]
        if {[pak::kindof $fn] ne "EnumVariantAccess"} { return {} }
        set case_name [pak::fval $fn name]
        set tn [expr {[dict exists $enum_variants $case_name] ? [dict get $enum_variants $case_name] : ""}]
        if {![dict exists $variant_types $tn]} { return {} }
        set field_names {}
        if {[dict exists $variant_case_fields $tn $case_name]} {
            set field_names [dict get $variant_case_fields $tn $case_name]
        }
        set result {}
        set i 0
        foreach arg [pak::items [pak::nfield $pat args]] {
            set bind_name ""
            set fi $i
            set cfield ""
            if {[pak::kindof $arg] eq "NamedArg"} {
                set bind_node [pak::nfield $arg value]
                if {[pak::kindof $bind_node] eq "Ident"} {
                    set bind_name [pak::fval $bind_node name]
                }
                set want [pak::fval $arg name]
                set found [lsearch -exact $field_names $want]
                if {$found >= 0} { set fi $found }
                set cfield $want
            } elseif {[pak::kindof $arg] eq "Ident"} {
                set bind_name [pak::fval $arg name]
                if {$i < [llength $field_names] && [lindex $field_names $i] ne ""} {
                    set cfield [lindex $field_names $i]
                }
            }
            if {$bind_name ne "" && $bind_name ne "_"} {
                if {$cfield ne ""} {
                    lappend result [list $bind_name "${expr_c}.data.${case_name}.${cfield}"]
                } else {
                    lappend result [list $bind_name "${expr_c}.data.${case_name}.field${fi}"]
                }
            }
            incr i
        }
        return $result
    }

    method gen_match_guarded {s pad indent} {
        incr tmp_counter
        set expr_var "_pak_match_${tmp_counter}"
        set inner_pad [string repeat "    " [expr {$indent+1}]]
        set inner2_pad [string repeat "    " [expr {$indent+2}]]
        set match_type [my match_type_name [pak::nfield $s expr]]
        set is_variant [dict exists $variant_types $match_type]
        set lines [list "${pad}\{"]
        lappend lines "${inner_pad}__auto_type ${expr_var} = [my gen_expr [pak::nfield $s expr]];"
        set first 1
        foreach arm [pak::items [pak::nfield $s arms]] {
            set pat [pak::nfield $arm pattern]
            set guard [pak::nfield $arm guard]
            set is_wildcard [expr {[pak::kindof $pat] eq "Ident" && [pak::fval $pat name] eq "_"}]
            set cond [my pattern_cond $pat $expr_var $is_variant $match_type]
            set bindings [my pattern_bindings $pat $expr_var]
            set guard_str ""
            if {![pak::isnil $guard]} {
                set gc [my gen_expr $guard]
                # The guard runs before the binding declarations exist, so each
                # binding name is replaced by the field access it stands for.
                # Tcl regexps spell the word boundary \y -- \b is a backspace.
                foreach binding $bindings {
                    set vname [lindex $binding 0]
                    set facc  [lindex $binding 1]
                    regsub -all "\\y${vname}\\y" $gc [string map {\\ \\\\ & \\&} $facc] gc
                }
                set guard_str " && ($gc)"
            }
            if {$is_wildcard && [pak::isnil $guard]} {
                lappend lines "${inner_pad}else \{"
            } else {
                set kw [expr {$first ? "if" : "else if"}]
                lappend lines "${inner_pad}${kw} (${cond}${guard_str}) \{"
            }
            my scope_push
            foreach binding $bindings {
                set vname [lindex $binding 0]
                set facc  [lindex $binding 1]
                lappend lines "${inner2_pad}__auto_type $vname = $facc;"
                my scope_set $vname [pak::N TypeName name auto]
            }
            set body [pak::nfield $arm body]
            if {[pak::kindof $body] eq "Block"} {
                foreach st [pak::items [pak::nfield $body stmts]] { lappend lines [my gen_stmt $st [expr {$indent+2}]] }
            } else {
                lappend lines "${inner2_pad}[my gen_expr $body];"
            }
            foreach d [my emit_defers_for_scope [expr {$indent+2}]] { lappend lines $d }
            my scope_pop
            lappend lines "${inner_pad}\}"
            set first 0
        }
        lappend lines "${pad}\}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    # The case name an arm selects on: .ok(v) / .ok / Result.ok all name "ok".
    method arm_case_name {arm} {
        set pat [pak::nfield $arm pattern]
        switch -- [pak::kindof $pat] {
            EnumVariantAccess { return [pak::fval $pat name] }
            DotAccess         { return [pak::fval $pat field] }
            Call {
                set fn [pak::nfield $pat func]
                switch -- [pak::kindof $fn] {
                    EnumVariantAccess { return [pak::fval $fn name] }
                    DotAccess         { return [pak::fval $fn field] }
                }
            }
        }
        return ""
    }

    # The single binding an arm introduces, if any: .ok(v) binds v.
    method arm_binding_name {arm} {
        set pat [pak::nfield $arm pattern]
        if {[pak::kindof $pat] eq "DotAccess" && ![pak::isnil [pak::nfield $pat binding]]} {
            return [pak::sval [pak::nfield $pat binding]]
        }
        if {[pak::kindof $pat] eq "Call"} {
            set a [pak::items [pak::nfield $pat args]]
            if {[llength $a] == 1 && [pak::kindof [lindex $a 0]] eq "Ident"} {
                return [pak::fval [lindex $a 0] name]
            }
        }
        return ""
    }

    # A Result is a struct with a bool, not a tagged enum: `match r { .ok(v) =>
    # ... .err(e) => ... }` has no integer to switch on and no ok/err constants
    # to name. It lowers to if/else on .is_ok, binding the matching union arm.
    method gen_match_result {s pad indent arms} {
        set expr [my gen_expr [pak::nfield $s expr]]
        set inner_pad [string repeat "    " [expr {$indent+1}]]
        set ok_arm ""
        set err_arm ""
        foreach arm $arms {
            switch -- [my arm_case_name $arm] {
                ok  { set ok_arm $arm }
                err { set err_arm $arm }
            }
        }
        if {$ok_arm eq "" || $err_arm eq ""} { return "" }

        set lines {}
        lappend lines "${pad}if (${expr}.is_ok) \{"
        foreach spec [list [list $ok_arm value] [list $err_arm error]] {
            lassign $spec arm field
            my scope_push
            set bind [my arm_binding_name $arm]
            if {$bind ne ""} {
                lappend lines "${inner_pad}__auto_type $bind = ${expr}.data.${field};"
                my scope_set $bind [pak::N TypeName name auto]
            }
            set body [pak::nfield $arm body]
            if {[pak::kindof $body] eq "Block"} {
                foreach st [pak::items [pak::nfield $body stmts]] {
                    lappend lines [my gen_stmt $st [expr {$indent+1}]]
                }
            } else {
                lappend lines "${inner_pad}[my gen_expr $body];"
            }
            foreach d [my emit_defers_for_scope [expr {$indent+1}]] { lappend lines $d }
            my scope_pop
            if {$field eq "value"} { lappend lines "${pad}\} else \{" }
        }
        lappend lines "${pad}\}"
        return [join [lmap l $lines {expr {$l eq "" ? [continue] : $l}}] \n]
    }

    method gen_match {s pad indent} {
        set arms [pak::items [pak::nfield $s arms]]
        foreach arm $arms {
            if {![pak::isnil [pak::nfield $arm guard]]} {
                return [my gen_match_guarded $s $pad $indent]
            }
        }
        # ok/err are not variant cases -- they are the two halves of PakResult.
        set names {}
        foreach arm $arms { lappend names [my arm_case_name $arm] }
        if {[lsort -unique $names] eq {err ok}} {
            set r [my gen_match_result $s $pad $indent $arms]
            if {$r ne ""} { return $r }
        }
        set expr [my gen_expr [pak::nfield $s expr]]
        set inner_pad [string repeat "    " [expr {$indent+1}]]
        set inner2_pad [string repeat "    " [expr {$indent+2}]]
        set match_type [my match_type_name [pak::nfield $s expr]]
        if {$match_type eq ""} { set match_type [my match_type_from_arms $arms] }
        set is_variant [dict exists $variant_types $match_type]
        set switch_expr [expr {$is_variant ? "${expr}.tag" : $expr}]
        set lines [list "${pad}switch ($switch_expr) {"]
        foreach arm $arms {
            set pat [pak::nfield $arm pattern]
            switch -- [pak::kindof $pat] {
                Ident {
                    if {[pak::fval $pat name] eq "_"} {
                        lappend lines "${inner_pad}default:"
                    } else {
                        pak::cg_unported "match-pat:Ident-binding:[pak::fval $pat name]"
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
                Call {
                    set fn [pak::nfield $pat func]
                    if {[pak::kindof $fn] ne "EnumVariantAccess"} { pak::cg_unported "match-pat:Call-non-variant" }
                    set case_name [pak::fval $fn name]
                    set tn [expr {[dict exists $enum_variants $case_name] ? [dict get $enum_variants $case_name] : ""}]
                    if {[dict exists $variant_types $tn]} {
                        lappend lines "${inner_pad}case ${tn}_tag_${case_name}:"
                    } elseif {$tn ne ""} {
                        lappend lines "${inner_pad}case ${tn}_${case_name}:"
                    } else {
                        lappend lines "${inner_pad}case ${case_name}:"
                    }
                }
                IntLit  { lappend lines "${inner_pad}case [pak::fval $pat value]:" }
                BoolLit { lappend lines "${inner_pad}case [expr {[pak::fval $pat value] ? 1 : 0}]:" }
                default { pak::cg_unported "match-pat:[pak::kindof $pat]" }
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
            } elseif {[pak::kindof $pat] eq "Call"} {
                foreach binding [my call_arm_bindings $pat $expr] {
                    set vname [lindex $binding 0]
                    set facc  [lindex $binding 1]
                    lappend lines "${inner2_pad}__auto_type $vname = $facc;"
                    my scope_set $vname [pak::N TypeName name auto]
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
            StructDecl {
                if {[llength [pak::items [pak::nfield $decl type_params]]] > 0} { return "" }
                return [my gen_struct $decl]
            }
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
            ComptimeIf {
                set cond [my gen_expr [pak::nfield $decl condition]]
                set then_lines {}
                foreach d [pak::items [pak::nfield [pak::nfield $decl then] stmts]] {
                    set r [my gen_decl $d]
                    if {$r ne ""} { lappend then_lines $r }
                }
                set result "#if $cond\n[join $then_lines \n]"
                set else_br [pak::nfield $decl else_branch]
                if {![pak::isnil $else_br]} {
                    set else_lines {}
                    foreach d [pak::items [pak::nfield $else_br stmts]] {
                        set r [my gen_decl $d]
                        if {$r ne ""} { lappend else_lines $r }
                    }
                    append result "\n#else\n[join $else_lines \n]"
                }
                append result "\n#endif"
                return $result
            }
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
        # Tagged, not anonymous: a struct that names itself (?*Node) or another
        # struct declared later needs a tag to forward-declare. The matching
        # `typedef struct Name Name;` is emitted in the forward block.
        set name [pak::fval $s name]
        set lines [list "struct $name {"]
        foreach field [pak::items [pak::nfield $s fields]] {
            set bw [pak::nfield $field bit_width]
            if {![pak::isnil $bw]} {
                lappend lines "    [my gen_type [pak::nfield $field type]] [pak::fval $field name] : [pak::sval $bw];"
            } else {
                lappend lines "    [my gen_array_decl [pak::fval $field name] [pak::nfield $field type]];"
            }
        }
        set suffix [expr {$attr_str ne "" ? " $attr_str" : ""}]
        lappend lines "}${suffix};"
        return [join $lines \n]
    }

    method gen_union {u} {
        set name [pak::fval $u name]
        set lines [list "union $name {"]
        foreach field [pak::items [pak::nfield $u fields]] {
            lappend lines "    [my gen_array_decl [pak::fval $field name] [pak::nfield $field type]];"
        }
        lappend lines "};"
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
        if {[llength [pak::items [pak::nfield $impl type_params]]] > 0} { return "" }
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

    # Specialize a trait default method for a concrete impl type: rebuild it
    # with its `self` param retyped to *tname (mirrors _trait_default_method).
    method trait_default_method {tm tname} {
        set new_params {}
        foreach p [pak::items [pak::nfield $tm params]] {
            if {[pak::fval $p name] eq "self"} {
                set p [pak::N Param name self \
                    type [pak::N TypePointer inner [pak::N TypeName name $tname] nullable 0 mutable 1] \
                    mutable 0 default_value [pak::Nil]]
            }
            lappend new_params $p
        }
        return [pak::N FnDecl name [pak::fval $tm name] params $new_params \
            ret_type [pak::nfield $tm ret_type] body [pak::nfield $tm body] \
            type_params {} annotations {} is_method 1 self_type [pak::N TypeName name $tname] variadic 0]
    }

    method gen_impl_trait {impl} {
        set tname [pak::fval $impl type_name]
        set trait [pak::fval $impl trait_name]
        set lines [list "/* impl $tname for $trait */"]
        # Full method set = impl methods + non-overridden trait defaults.
        set impl_names {}
        foreach m [pak::items [pak::nfield $impl methods]] { lappend impl_names [pak::fval $m name] }
        set methods [pak::items [pak::nfield $impl methods]]
        if {[dict exists $trait_decls $trait]} {
            set tdecl [dict get $trait_decls $trait]
            foreach tm [pak::items [pak::nfield $tdecl methods]] {
                if {[pak::fval $tm name] ni $impl_names && ![pak::isnil [pak::nfield $tm body]]} {
                    lappend methods [my trait_default_method $tm $tname]
                }
            }
        }
        foreach m $methods {
            dict set method_registry $tname [pak::fval $m name] $m
        }
        # Emit the concrete method bodies: TypeName_method(...)
        foreach m $methods {
            lappend lines [my gen_fn $m $tname]
            lappend lines ""
        }
        foreach m $methods {
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
        foreach m $methods {
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
            # A fixed-point const is an integer scaled by 2^shift, not a float.
            # `const GRAVITY: fix16.16 = 0.4` was emitting the float literal
            # into `enum { GRAVITY = 0.4f };` -- not an integer constant, and
            # every later >> on it operated on a float.
            set shift [pak::cg_fixshift $typ]
            if {$shift != 0 && [pak::kindof [pak::nfield $c value]] eq "FloatLit"} {
                set raw [pak::fval [pak::nfield $c value] value]
                set scaled [expr {entier(double($raw) * (1 << $shift))}]
                return "enum { [pak::fval $c name] = $scaled };"
            }
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
        set name [pak::fval $s name]
        set typ  [pak::nfield $s type]
        if {"@uncached" in $anns} {
            # @uncached: cached backing buffer + uncached pointer alias (mirrors Python)
            set raw_name "_pak_raw_$name"
            set align_n [my aligned_n $anns]
            set align_attr [expr {$align_n ne "" ? "__attribute__((aligned($align_n)))" : "__attribute__((aligned(16)))"}]
            if {![pak::isnil $typ]} {
                set raw_decl [my gen_array_decl $raw_name $typ]
                if {[pak::kindof $typ] eq "TypeArray"} {
                    set ptr_type [my gen_type [pak::nfield $typ inner]]
                } else {
                    set ptr_type [my gen_type $typ]
                }
            } else {
                set raw_decl "uint8_t ${raw_name}\[0\]"
                set ptr_type "uint8_t"
            }
            return "static $align_attr $raw_decl;\nstatic $ptr_type * const $name = ($ptr_type *)UncachedAddr($raw_name);"
        }
        if {![pak::isnil $typ]} { set decl [my gen_array_decl $name $typ] } \
        else { set decl "__auto_type $name" }
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
        set saved_self $current_self_type
        if {$prefix ne ""} { set current_self_type $prefix }
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
            set current_self_type $saved_self
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
        set current_self_type $saved_self
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
                UseDecl {
                    lappend uses [pak::fval $decl path]
                    # `use n64.display as disp` — record disp → display so
                    # calls through the alias still resolve to the module API.
                    set al [pak::nfield $decl alias]
                    if {![pak::isnil $al]} {
                        set segs [split [pak::fval $decl path] .]
                        dict set use_aliases [pak::sval $al] [lindex $segs end]
                    }
                }
                AssetDecl { lappend assets $decl }
                ModuleDecl { set module_name [pak::fval $decl path] }
                FnDecl {
                    lappend fn_names [pak::fval $decl name]
                    dict set fn_decls [pak::fval $decl name] $decl
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
                        set names {}
                        foreach f [pak::items [pak::nfield $c fields]] {
                            if {[lindex $f 0] eq "seq"} {
                                lappend names [pak::sval [lindex [pak::items $f] 0]]
                            } else {
                                lappend names ""
                            }
                        }
                        dict set variant_case_fields [pak::fval $decl name] [pak::fval $c name] $names
                    }
                }
                ImplBlock - ImplTraitBlock {
                    set tname [pak::fval $decl type_name]
                    if {[pak::kindof $decl] eq "ImplBlock" && [llength [pak::items [pak::nfield $decl type_params]]] > 0} {
                        dict set generic_impls $tname $decl
                    } else {
                        foreach m [pak::items [pak::nfield $decl methods]] {
                            dict set method_registry $tname [pak::fval $m name] $m
                        }
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
                                set names {}
                                foreach f [pak::items [pak::nfield $c fields]] {
                                    if {[lindex $f 0] eq "seq"} {
                                        lappend names [pak::sval [lindex [pak::items $f] 0]]
                                    } else {
                                        lappend names ""
                                    }
                                }
                                dict set variant_case_fields [pak::fval $inner name] [pak::fval $c name] $names
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

        # An asset name is a handle usable anywhere in the file (LANGUAGE.md
        # section 14), not just a path string: `rdpq.sprite_blit(bg, ...)`
        # passes the loaded asset. Emitting only <name>_path left every use of
        # the bare name undeclared. Typed assets with a known loader get a
        # lazily-loaded handle -- lazy because the filesystem is not mounted
        # until the entry block runs, so loading at static-init time is too
        # early. Untyped assets keep the path alone; there is nothing to load
        # them with.
        set asset_loaders [dict create Sprite [list {sprite_t *} sprite_load]]
        foreach asset $assets {
            set aname [pak::fval $asset name]
            set apath [pak::fval $asset path]
            set atype [pak::nfield $asset asset_type]
            set tname ""
            if {![pak::isnil $atype]} {
                set tname [expr {[pak::kindof $atype] eq "TypeName" ? [pak::fval $atype name] : [pak::sval $atype]}]
            }
            lappend out "/* asset: $aname from \"$apath\" */"
            lappend out "static const char *${aname}_path = \"pak:/${apath}\";"
            if {[dict exists $asset_loaders $tname]} {
                lassign [dict get $asset_loaders $tname] ctype loader
                lappend out "static $ctype _pak_asset_${aname} = 0;"
                lappend out "static inline $ctype _pak_asset_get_${aname}(void) \{"
                lappend out "    if (!_pak_asset_${aname}) _pak_asset_${aname} = ${loader}(${aname}_path);"
                lappend out "    return _pak_asset_${aname};"
                lappend out "\}"
                lappend out "#define $aname (_pak_asset_get_${aname}())"
            }
        }
        if {[llength $assets] > 0} { lappend out "" }

        # body (generated before preamble runtime types are appended, matching Python)
        #
        # User type declarations are split out and emitted ahead of the Result /
        # slice / tuple / container typedefs below. Those typedefs embed user
        # types by value (a Result carries a LoadError, a fixed list carries
        # Star data[64]), so a user type declared after them is an unknown type
        # name at the point that matters.
        set type_decls {}
        set body {}
        foreach decl $decls {
            if {[pak::kindof $decl] in {UseDecl AssetDecl ModuleDecl}} continue
            set r [my gen_decl $decl]
            if {$r eq ""} continue
            if {[pak::kindof $decl] in {StructDecl EnumDecl VariantDecl UnionDecl}} {
                lappend type_decls $r; lappend type_decls ""
            } else {
                lappend body $r; lappend body ""
            }
        }

        # Forward typedefs, so a struct can name itself or a sibling declared
        # later without depending on declaration order at all.
        set fwd {}
        foreach decl $decls {
            switch -- [pak::kindof $decl] {
                StructDecl { lappend fwd "typedef struct [pak::fval $decl name] [pak::fval $decl name];" }
                UnionDecl  { lappend fwd "typedef union [pak::fval $decl name] [pak::fval $decl name];" }
            }
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

        if {[llength $fwd] > 0} {
            lappend out ""
            lappend out "/* -- User type forward declarations -- */"
            foreach l $fwd { lappend out $l }
        }
        if {[llength $type_decls] > 0} {
            lappend out ""
            lappend out "/* -- User types -- */"
            foreach l $type_decls { lappend out $l }
        }

        if {$allocator_used} {
            lappend out ""
            lappend out "/* -- Allocator trait (vtable-based custom allocator interface) -- */"
            lappend out "typedef struct { void *(*alloc_bytes)(void *, size_t); void (*dealloc_bytes)(void *, void *); } Allocator_vtable;"
            lappend out "typedef struct { void *self; const Allocator_vtable *vtable; } Allocator;"
            lappend out "/* PakArena as Allocator */"
            lappend out "static void *_pak_alloc_bytes_Arena(void *_s, size_t sz) { return pak_arena_alloc((PakArena *)_s, sz); }"
            lappend out "static void _pak_dealloc_bytes_Arena(void *_s, void *p) { (void)_s; (void)p; }"
            lappend out "static const Allocator_vtable _pak_vtable_Arena = { _pak_alloc_bytes_Arena, _pak_dealloc_bytes_Arena };"
            lappend out "static inline Allocator Allocator_from_Arena(PakArena *p) { return (Allocator){ .self=(void *)p, .vtable=&_pak_vtable_Arena }; }"
            lappend out "/* Heap (malloc/free) as Allocator */"
            lappend out "static void *_pak_alloc_bytes_Heap(void *_s, size_t sz) { (void)_s; return malloc(sz); }"
            lappend out "static void _pak_dealloc_bytes_Heap(void *_s, void *p) { (void)_s; free(p); }"
            lappend out "static const Allocator_vtable _pak_vtable_Heap = { _pak_alloc_bytes_Heap, _pak_dealloc_bytes_Heap };"
            lappend out "static inline Allocator pak_heap_allocator(void) { return (Allocator){ .self=NULL, .vtable=&_pak_vtable_Heap }; }"
        }

        # Result typedefs (collected as a side effect of body generation above).
        if {[llength $result_typedefs] > 0} {
            lappend out ""
            foreach td $result_typedefs {
                lassign $td tdname c_ok c_err
                lappend out "typedef struct { bool is_ok; union { $c_ok value; $c_err error; } data; } ${tdname};"
            }
        }

        # Slice (fat-pointer) typedefs.
        if {[llength $slice_typedefs] > 0} {
            lappend out ""
            foreach td $slice_typedefs {
                lassign $td tdname c_inner
                lappend out "typedef struct { $c_inner *data; int32_t len; } ${tdname};"
            }
        }

        # Tuple typedefs.
        if {[llength $tuple_typedefs] > 0} {
            lappend out ""
            lappend out "/* -- Tuple types -- */"
            foreach td $tuple_typedefs {
                lassign $td tdname ctypes
                lappend out "typedef struct {"
                set i 0
                foreach ct $ctypes { lappend out "    $ct f$i;"; incr i }
                lappend out "} ${tdname};"
            }
        }

        # Vec(T) dynamic vector typedefs + _PAK_VEC_PUSH macro.
        if {$vec_used} {
            lappend out ""
            lappend out "/* -- Vec(T) dynamic vector -- */"
            lappend out "#include <stdlib.h>"
            lappend out "#define _PAK_VEC_PUSH(v, item) do { \\"
            lappend out "    if ((v)->len >= (v)->cap) { \\"
            lappend out "        (v)->cap = (v)->cap ? (v)->cap * 2 : 8; \\"
            lappend out "        (v)->data = realloc((v)->data, (size_t)(v)->cap * sizeof(*(v)->data)); \\"
            lappend out "    } \\"
            lappend out "    (v)->data\[(v)->len++\] = (item); \\"
            lappend out "} while(0)"
            foreach td $vec_typedefs {
                lassign $td tdname elem_c_type
                lappend out "typedef struct {"
                lappend out "    $elem_c_type *data;"
                lappend out "    int32_t len;"
                lappend out "    int32_t cap;"
                lappend out "} ${tdname};"
            }
        }

        # Container typedefs (FixedList, RingBuffer, FixedMap, Pool).
        if {[llength $container_typedefs] > 0} {
            lappend out ""
            lappend out "/* -- Container types -- */"
            foreach entry $container_typedefs {
                lassign $entry tname kind et1 et2 cap
                switch -- $kind {
                    FixedMap {
                        lappend out "typedef struct {"
                        lappend out "    $et1 keys\[$cap\];"
                        lappend out "    $et2 values\[$cap\];"
                        lappend out "    bool occupied\[$cap\];"
                        lappend out "    int32_t len;"
                        lappend out "} ${tname};"
                        lappend out ""
                    }
                    RingBuffer {
                        lappend out "typedef struct {"
                        lappend out "    $et1 data\[$cap\];"
                        lappend out "    int32_t head, tail, len;"
                        lappend out "} ${tname};"
                        lappend out ""
                    }
                    default {
                        lappend out "typedef struct {"
                        lappend out "    $et1 data\[$cap\];"
                        lappend out "    int32_t len;"
                        lappend out "} ${tname};"
                        lappend out ""
                    }
                }
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

        # Emit monomorphized generic specializations generated during body codegen.
        # These must precede body so that specialized struct typedefs and function
        # definitions are visible where main/other code uses them.
        if {[llength $pending_mono] > 0} {
            lappend out ""
            lappend out "/* -- Generic specializations -- */"
            set i 0
            while {$i < [llength $pending_mono]} {
                set decl [lindex $pending_mono $i]
                if {[llength $decl] == 3 && [lindex $decl 0] eq "impl_method"} {
                    lassign $decl _ spec_struct spec_m
                    lappend out [my gen_fn $spec_m $spec_struct]
                } else {
                    switch -- [pak::kindof $decl] {
                        FnDecl     { lappend out [my gen_fn $decl ""] }
                        StructDecl {
                            # Monomorphs are not in $decls, so the forward block
                            # above never saw them: pair the typedef here.
                            lappend out "typedef struct [pak::fval $decl name] [pak::fval $decl name];"
                            lappend out [my gen_struct $decl]
                        }
                    }
                }
                lappend out ""
                incr i
            }
            set pending_mono {}
        }

        foreach b $body { lappend out $b }

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
# Argument `i` if the call supplied it, else the module API's documented default.
proc pak::cg_arg_or {arglist i default} {
    if {[llength $arglist] > $i} { return [lindex $arglist $i] }
    return $default
}

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
        "arena alloc"    { return "pak_arena_alloc([pak::cg_addr $arglist 0], [expr {[llength $arglist] > 1 ? [lindex $arglist 1] : 0}])" }
        "arena reset"    { return "pak_arena_reset([pak::cg_addr $arglist 0])" }
        "joypad is_connected" {
            set port [expr {[llength $arglist] > 0 ? [lindex $arglist 0] : 0}]
            return "(joypad_get_status($port).style != JOYPAD_STYLE_NONE)"
        }
        "str from_cstr"    { return "pak_str_from_cstr([lindex $arglist 0])" }
        "str len"          { return "([lindex $arglist 0]).len" }
        "str eq"           { return "pak_str_eq([lindex $arglist 0], [lindex $arglist 1])" }
        "str concat"       {
            if {[llength $arglist] >= 4} {
                lassign $arglist a b buf cap
                return "(snprintf($buf, (size_t)($cap), \"%.*s%.*s\",\
 (int)($a).len, ($a).data,\
 (int)($b).len, ($b).data),\
 (PakStr)\{.data=$buf, .len=(int32_t)strlen($buf)\})"
            }
            return "pak_str_from_cstr(([lindex $arglist 0]).data)"
        }
        "str data"         { return "([lindex $arglist 0]).data" }
        "str print"        {
            set a [lindex $arglist 0]
            return "debugf(\"%.*s\", ($a).len, ($a).data)"
        }
        "mem alloc"         { return "malloc([lindex $arglist 0])" }
        "mem alloc_aligned" { return "memalign([lindex $arglist 1], [lindex $arglist 0])" }
        "mem free"          { return "free([lindex $arglist 0])" }
        "mem realloc"       { return "realloc([lindex $arglist 0], [lindex $arglist 1])" }
        "mem copy"          { return "memcpy([lindex $arglist 0], [lindex $arglist 1], [lindex $arglist 2])" }
        "mem move"          { return "memmove([lindex $arglist 0], [lindex $arglist 1], [lindex $arglist 2])" }
        "mem zero"          { return "memset([lindex $arglist 0], 0, [lindex $arglist 1])" }
        "system has_expansion" { return "(get_memory_size() > 0x400000)" }
        "system ticks"         { return "TICKS_READ()" }
        "system ticks_to_ms"   { return "TICKS_TO_MS([lindex $arglist 0])" }
        "system reset"         { return "n64sys_reset()" }
        "system tv_type"       { return "sys_tv_type()" }
        "vi get_width"      { return "display_get_width()" }
        "vi get_height"     { return "display_get_height()" }
        "vi wait_vblank"    { return "vi_wait_vblank()" }
        "rtc is_running"    { return "!rtc_is_stopped()" }
        "rumble is_plugged" {
            return "(joypad_get_accessory_type([pak::cg_arg_or $arglist 0 0]) ==\
 JOYPAD_ACCESSORY_TYPE_RUMBLE_PAK)"
        }
        "mouse get_buttons" { return "joypad_get_buttons_pressed([pak::cg_arg_or $arglist 0 0])" }
        "mouse get_delta_x" { return "joypad_get_axis_pressed([pak::cg_arg_or $arglist 0 0], JOYPAD_AXIS_STICK_X)" }
        "mouse get_delta_y" { return "joypad_get_axis_pressed([pak::cg_arg_or $arglist 0 0], JOYPAD_AXIS_STICK_Y)" }
        "rdpq_mode antialias"  { return "rdpq_mode_antialias([pak::cg_arg_or $arglist 0 AA_STANDARD])" }
        "rdpq_mode blending"   { return "rdpq_mode_blending([pak::cg_arg_or $arglist 0 RDPQ_BLENDING_MULTIPLY])" }
        "rdpq_mode dithering"  { return "rdpq_mode_dithering([pak::cg_arg_or $arglist 0 DITHER_SQUARE_SQUARE])" }
        "rdpq_mode filter"     { return "rdpq_mode_filter([pak::cg_arg_or $arglist 0 FILTER_BILINEAR])" }
        "rdpq_mode persp_norm" { return "rdpq_mode_persp_norm([pak::cg_arg_or $arglist 0 true])" }
        "rdpq_mode tlut"       { return "rdpq_mode_tlut([pak::cg_arg_or $arglist 0 TLUT_RGBA16])" }
        "rdpq_mode zbuf"       { return "rdpq_mode_zbuf(true, [pak::cg_arg_or $arglist 0 true])" }
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
