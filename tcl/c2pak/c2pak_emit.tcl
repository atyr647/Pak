# tcl/c2pak/c2pak_emit.tcl — mappers + emitter for the c2pak Tcl port.
# Sourced by tcl/c2pak.tcl. Operates on the dict-based C AST it produces.

namespace eval pak::c2pak {}

# ─────────────────────────────────────────────────────────────────────────────
# Type mapper
# ─────────────────────────────────────────────────────────────────────────────

namespace eval pak::c2pak {
    variable PRIMMAP
    array set PRIMMAP {
        void void  bool bool  _Bool bool
        char i8  {signed char} i8  s8 i8  int8_t i8
        {unsigned char} u8  u8 u8  uint8_t u8  byte u8
        short i16  {short int} i16  {signed short} i16  {signed short int} i16  s16 i16  int16_t i16
        {unsigned short} u16  {unsigned short int} u16  u16 u16  uint16_t u16
        int i32  signed i32  {signed int} i32  long i32  {long int} i32  {signed long} i32  {signed long int} i32  s32 i32  int32_t i32  ptrdiff_t i32
        unsigned u32  {unsigned int} u32  {unsigned long} u32  {unsigned long int} u32  u32 u32  uint32_t u32  size_t u32
        {long long} i64  {long long int} i64  {signed long long} i64  {signed long long int} i64  s64 i64  int64_t i64
        {unsigned long long} u64  {unsigned long long int} u64  u64 u64  uint64_t u64
        float f32  f32 f32
        double f64  {long double} f64  f64 f64
        fix16 fix16.16  fixed16 fix16.16  s16_16 fix16.16  q16 fix16.16
        fix1_15 fix1.15  s1_15 fix1.15  q1_15 fix1.15
        fix10_5 fix10.5  s10_5 fix10.5
        i8 i8  i16 i16  i32 i32  i64 i64  fix16.16 fix16.16  fix1.15 fix1.15  fix10.5 fix10.5
    }
    # typedef table for the emitter (name -> type dict). Set during emit init.
    variable TD
    set TD [dict create]
    # struct field names: name -> list
    variable SF
    set SF [dict create]
}

proc pak::c2pak::tm_map_primitive {name} {
    variable PRIMMAP
    set norm [join [regexp -all -inline {\S+} $name] " "]
    if {[info exists PRIMMAP($norm)]} { return $PRIMMAP($norm) }
    return $norm
}

proc pak::c2pak::tm_map {typ {mutHint 0}} {
    set k [dict get $typ k]
    switch -- $k {
        prim { return [tm_map_primitive [dict get $typ name]] }
        typeref { return [tm_map_typeref [dict get $typ name]] }
        ptr { return [tm_map_pointer $typ] }
        array { return [tm_map_array $typ] }
        struct { set n [dict get $typ name]; return [expr {$n ne "" ? $n : "_AnonStruct"}] }
        union { set n [dict get $typ name]; return [expr {$n ne "" ? $n : "_AnonUnion"}] }
        enum { set n [dict get $typ name]; return [expr {$n ne "" ? $n : "_AnonEnum"}] }
        funcptr { return [tm_map_funcptr $typ] }
    }
    return "/* unknown */"
}

proc pak::c2pak::tm_map_typeref {name} {
    variable TD; variable PRIMMAP
    if {[dict exists $TD $name]} {
        set resolved [dict get $TD $name]
        set rk [dict get $resolved k]
        if {$rk eq "prim"} { return [tm_map_primitive [dict get $resolved name]] }
        if {$rk in {struct union enum}} {
            set rn [dict get $resolved name]
            return [expr {$rn ne "" ? $rn : $name}]
        }
    }
    if {[info exists PRIMMAP($name)]} { return $PRIMMAP($name) }
    return $name
}

proc pak::c2pak::tm_map_pointer {typ} {
    set inner [tm_map [dict get $typ inner] 0]
    if {$inner eq "void"} { set inner "u8" }
    if {[dict get $typ const]} {
        return "*$inner"
    }
    return "*mut $inner"
}

proc pak::c2pak::tm_map_array {typ} {
    set inner [tm_map [dict get $typ inner]]
    set sz [dict get $typ size]
    if {$sz ne ""} { return "\[$sz\]$inner" }
    return "\[\]$inner"
}

proc pak::c2pak::tm_map_funcptr {typ} {
    set ret [tm_map [dict get $typ ret]]
    set parts {}
    foreach p [dict get $typ params] { lappend parts [tm_map $p] }
    set params [join $parts ", "]
    if {$ret eq "void"} { return "fn($params)" }
    return "fn($params) -> $ret"
}

proc pak::c2pak::tm_is_void {typ} {
    return [expr {[string trim [tm_map $typ]] eq "void"}]
}

proc pak::c2pak::tm_is_pointer_to {typ name} {
    if {[dict get $typ k] eq "ptr"} {
        set inner [dict get $typ inner]
        set ik [dict get $inner k]
        if {$ik eq "typeref"} { return [expr {[dict get $inner name] eq $name}] }
        if {$ik eq "struct"} { return [expr {[dict get $inner name] eq $name}] }
    }
    return 0
}

proc pak::c2pak::tm_field_type {field} { return [tm_map [dict get $field typ]] }

proc pak::c2pak::tm_get_struct_fields {name} {
    variable SF
    if {[dict exists $SF $name]} { return [dict get $SF $name] }
    return {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Expression mapper
# ─────────────────────────────────────────────────────────────────────────────

namespace eval pak::c2pak {
    variable METHODMAP
    set METHODMAP [dict create]   ;# c func name -> {struct method}
    variable BINPRECE
    array set BINPRECE {
        || 1 && 2 | 3 ^ 4 & 5 == 6 != 6 < 7 > 7 <= 7 >= 7 << 8 >> 8 + 9 - 9 * 10 / 10 % 10
    }
}

proc pak::c2pak::em_emit {expr {parens 0}} {
    set result [em $expr]
    if {$parens && [em_needs_parens $expr]} { return "($result)" }
    return $result
}

proc pak::c2pak::em {expr} {
    set k [dict get $expr k]
    switch -- $k {
        const   { return [em_const $expr] }
        id      { return [em_id $expr] }
        binop   { return [em_binop $expr] }
        unary   { return [em_unary $expr] }
        assign  { return [em_assign $expr] }
        call    { return [em_call $expr] }
        arrayref { return [em_arrayref $expr] }
        structref { return [em_structref $expr] }
        cast    { return [em_cast $expr] }
        ternary { return [em_ternary $expr] }
        comma   {
            set exprs [dict get $expr exprs]
            if {[llength $exprs] > 0} { return [em [lindex $exprs end]] }
            return "()"
        }
        sizeof  { return [em_sizeof $expr] }
        initlist { return [em_initlist $expr] }
    }
    return "/* expr:$k */"
}

proc pak::c2pak::em_const {expr} {
    set v [dict get $expr value]
    if {$v eq "NULL" || $v eq "((void*)0)"} { return "none" }
    set kind [dict get $expr kind]
    if {$kind in {float double}} {
        set v [string trimright $v "fFlL"]
        if {[string first "." $v] < 0 && [string first "e" [string tolower $v]] < 0} {
            append v ".0"
        }
        return $v
    }
    if {$kind eq "int"} {
        return [string trimright $v "uUlL"]
    }
    return $v
}

proc pak::c2pak::em_id {expr} {
    set name [dict get $expr name]
    if {$name eq "NULL"} { return "none" }
    return $name
}

proc pak::c2pak::em_binop {expr} {
    set op [dict get $expr op]
    set left [em_child $expr [dict get $expr left] left]
    set right [em_child $expr [dict get $expr right] right]
    return "$left $op $right"
}

proc pak::c2pak::em_child {parent child side} {
    set needs 0
    set ck [dict get $child k]
    if {$ck eq "binop"} {
        set needs [binop_needs_parens [dict get $parent op] [dict get $child op] [expr {$side eq "right"}]]
    } elseif {$ck eq "ternary"} {
        set needs 1
    }
    set s [em $child]
    if {$needs} { return "($s)" }
    return $s
}

proc pak::c2pak::binop_needs_parens {parentOp childOp isRight} {
    variable BINPRECE
    set pp 0; set cp 0
    if {[info exists BINPRECE($parentOp)]} { set pp $BINPRECE($parentOp) }
    if {[info exists BINPRECE($childOp)]} { set cp $BINPRECE($childOp) }
    if {$cp < $pp} { return 1 }
    if {$cp == $pp && $isRight && $parentOp in {- / % << >>}} { return 1 }
    return 0
}

proc pak::c2pak::em_unary {expr} {
    set op [dict get $expr op]
    set inner [em [dict get $expr expr]]
    set postfix [dict get $expr postfix]
    if {$postfix} {
        if {$op eq "++" || $op eq "--"} { return $inner }
    } else {
        if {$op eq "++" || $op eq "--"} { return $inner }
        if {$op eq "-"} {
            set ek [dict get [dict get $expr expr] k]
            if {$ek eq "const" || $ek eq "id"} { return "-$inner" }
            return "-($inner)"
        }
        if {$op eq "~"} { return "~$inner" }
        if {$op eq "!"} { return "!$inner" }
        if {$op eq "&"} { return "&mut $inner" }
        if {$op eq "*"} { return "*$inner" }
    }
    return "$op$inner"
}

proc pak::c2pak::em_assign {expr} {
    set op [dict get $expr op]
    set target [em [dict get $expr target]]
    set value [em [dict get $expr value]]
    return "$target $op $value"
}

proc pak::c2pak::em_call {expr} {
    variable METHODMAP
    set func [dict get $expr func]
    set args [dict get $expr args]
    if {[dict get $func k] eq "id" && [dict exists $METHODMAP [dict get $func name]] && [llength $args] > 0} {
        lassign [dict get $METHODMAP [dict get $func name]] _struct method
        set recv [em [lindex $args 0]]
        foreach pre {"&mut " "&"} {
            if {[string first $pre $recv] == 0} {
                set recv [string range $recv [string length $pre] end]
                break
            }
        }
        set restparts {}
        foreach a [lrange $args 1 end] { lappend restparts [em $a] }
        set rest [join $restparts ", "]
        return "${recv}.${method}($rest)"
    }
    set f [em $func]
    set parts {}
    foreach a $args { lappend parts [em $a] }
    return "${f}([join $parts ", "])"
}

proc pak::c2pak::em_arrayref {expr} {
    set base [em [dict get $expr base]]
    set idx [em [dict get $expr index]]
    return "$base\[$idx\]"
}

proc pak::c2pak::em_structref {expr} {
    set base [em [dict get $expr base]]
    return "$base.[dict get $expr member]"
}

proc pak::c2pak::em_cast {expr} {
    set pak_type [tm_map [dict get $expr typ]]
    set inner [em [dict get $expr expr]]
    if {$pak_type eq "void"} { return $inner }
    set ek [dict get [dict get $expr expr] k]
    if {$ek in {id const arrayref structref call}} {
        return "$inner as $pak_type"
    }
    return "($inner) as $pak_type"
}

proc pak::c2pak::em_ternary {expr} {
    set cond [em [dict get $expr cond]]
    set then [em [dict get $expr then]]
    set other [em [dict get $expr otherwise]]
    return "if $cond \{ $then \} else \{ $other \}"
}

proc pak::c2pak::em_sizeof {expr} {
    if {[dict get $expr istype]} {
        return "sizeof([tm_map [dict get $expr target]])"
    }
    return "sizeof([em [dict get $expr target]])"
}

proc pak::c2pak::em_initlist {expr} {
    set items [dict get $expr items]
    set parts {}
    foreach item $items {
        if {[lindex $item 0] eq "named"} {
            lappend parts "[lindex $item 1]: [em [lindex $item 2]]"
        } else {
            lappend parts [em [lindex $item 1]]
        }
    }
    if {[llength $parts] == 0} { return "\{\}" }
    return "\{ [join $parts ", "] \}"
}

proc pak::c2pak::em_as_bool {expr} {
    set k [dict get $expr k]
    if {$k eq "binop" && [dict get $expr op] in {== != < > <= >= && ||}} {
        return [em_binop $expr]
    }
    if {$k eq "unary" && [dict get $expr op] eq "!"} {
        set inner [em_as_bool [dict get $expr expr]]
        if {[string first " " $inner] >= 0} { return "!($inner)" }
        return "!$inner"
    }
    return [em $expr]
}

proc pak::c2pak::em_needs_parens {expr} {
    return [expr {[dict get $expr k] in {binop ternary assign comma}}]
}

# ─────────────────────────────────────────────────────────────────────────────
# Statement mapper
# ─────────────────────────────────────────────────────────────────────────────
#
# State held in namespace vars (single-threaded). Reset per function body.

namespace eval pak::c2pak {
    variable S_indent 0
    variable S_tmp 0
    variable S_selfRename ""
    variable S_n64 ""        ;# name of a list var (by upvar) or "" if none
}

proc pak::c2pak::sm_reset {} {
    variable S_indent; variable S_tmp; variable S_selfRename; variable S_track_n64
    set S_indent 0; set S_tmp 0; set S_selfRename ""; set S_track_n64 0
}

proc pak::c2pak::pad {line} {
    variable S_indent
    set ind [string repeat {    } $S_indent]
    return "$ind$line"
}

# emit body of a function: returns list of lines. n64modVar is the name of a
# global accumulator list variable (caller-provided), or "".
proc pak::c2pak::sm_emit_compound_items {items linesVar} {
    upvar $linesVar lines
    set items [transform_goto_defer $items]
    foreach item $items {
        sm_emit_stmt $item lines
    }
}

proc pak::c2pak::sm_emit_stmt {stmt linesVar} {
    upvar $linesVar lines
    set k [dict get $stmt k]
    switch -- $k {
        empty {}
        var { sm_emit_local_decl $stmt lines }
        compound { sm_emit_compound_items [dict get $stmt items] lines }
        exprstmt { sm_emit_expr_stmt $stmt lines }
        if { sm_emit_if $stmt lines }
        while { sm_emit_while $stmt lines }
        dowhile { sm_emit_dowhile $stmt lines }
        for { sm_emit_for $stmt lines }
        switch { sm_emit_switch $stmt lines }
        return { sm_emit_return $stmt lines }
        break { lappend lines [pad "break"] }
        continue { lappend lines [pad "continue"] }
        goto { lappend lines [pad "goto [dict get $stmt label]"] }
        label {
            lappend lines [pad "label [dict get $stmt name]"]
            if {[dict get $stmt stmt] ne ""} { sm_emit_stmt [dict get $stmt stmt] lines }
        }
        defer {
            lappend lines [pad "defer \{"]
            sm_indent_in
            foreach st [dict get $stmt stmts] { sm_emit_stmt $st lines }
            sm_indent_out
            lappend lines [pad "\}"]
        }
        default { lappend lines [pad "-- unhandled stmt: $k"] }
    }
}

proc pak::c2pak::sm_indent_in {} { variable S_indent; incr S_indent }
proc pak::c2pak::sm_indent_out {} { variable S_indent; incr S_indent -1 }

# emit expression with N64 API + self-rename
proc pak::c2pak::sm_emit_expr {expr} {
    variable S_selfRename
    variable S_track_n64
    variable USED_N64
    if {[dict get $expr k] eq "call"} {
        set func [dict get $expr func]
        if {[dict get $func k] eq "id"} {
            set fn [dict get $func name]
            set mapping [n64_api $fn]
            if {$mapping ne ""} {
                lassign $mapping module method
                if {$S_track_n64} {
                    lappend USED_N64 $module
                }
                set parts {}
                foreach a [dict get $expr args] { lappend parts [sm_emit_expr $a] }
                return "${module}.${method}([join $parts ", "])"
            }
        }
    }
    set raw [em $expr]
    if {$S_selfRename ne "" && [string first $S_selfRename $raw] >= 0} {
        set raw [apply_self_rename $raw $S_selfRename]
    }
    return $raw
}

proc pak::c2pak::sm_emit_expr_as_bool {expr} {
    variable S_selfRename
    set raw [em_as_bool $expr]
    if {$S_selfRename ne "" && [string first $S_selfRename $raw] >= 0} {
        set raw [apply_self_rename $raw $S_selfRename]
    }
    return $raw
}

proc pak::c2pak::apply_self_rename {text oldName} {
    regsub -all "\\m[regexpEscape $oldName]\\M" $text "self" text
    return $text
}
proc pak::c2pak::regexpEscape {s} {
    return [string map {\\ \\\\ . \\. * \\* + \\+ ? \\? ( \\( ) \\) \[ \\\[ \] \\\] \{ \\\{ \} \\\} ^ \\^ $ \\$ | \\|} $s]
}

proc pak::c2pak::sm_emit_local_decl {decl linesVar} {
    upvar $linesVar lines
    variable S_selfRename
    set pak_type [tm_map [dict get $decl typ]]
    set keyword "let"
    if {[dict get $decl is_static]} { set keyword "static" }
    if {[dict get $decl is_const]} { set keyword "const" }
    set init [dict get $decl init]
    set name [dict get $decl name]
    if {$init ne "" && [dict get $init k] eq "ternary" && $keyword ne "const"} {
        set cond [sm_emit_expr_as_bool [dict get $init cond]]
        lappend lines [pad "$keyword $name: $pak_type = [sm_emit_expr [dict get $init otherwise]]"]
        lappend lines [pad "if $cond \{ $name = [sm_emit_expr [dict get $init then]] \}"]
    } elseif {$init ne ""} {
        set init_str [sm_emit_init $init [dict get $decl typ]]
        if {$S_selfRename ne "" && [string first $S_selfRename $init_str] >= 0} {
            set init_str [apply_self_rename $init_str $S_selfRename]
        }
        lappend lines [pad "$keyword $name: $pak_type = $init_str"]
    } else {
        set zero [zero_value $pak_type]
        lappend lines [pad "$keyword $name: $pak_type = $zero"]
    }
}

proc pak::c2pak::sm_emit_init {expr typ} {
    if {[dict get $expr k] eq "initlist"} {
        return [sm_emit_struct_init $expr $typ]
    }
    return [sm_emit_expr $expr]
}

proc pak::c2pak::sm_emit_struct_init {init typ} {
    set type_name [sm_type_name $typ]
    set items [dict get $init items]
    set allNamed 1
    foreach item $items { if {[lindex $item 0] ne "named"} { set allNamed 0; break } }
    if {[llength $items] > 0 && $allNamed && $type_name ne ""} {
        set parts {}
        foreach item $items {
            lappend parts "[lindex $item 1]: [em [lindex $item 2]]"
        }
        return "$type_name \{ [join $parts ", "] \}"
    }
    if {[llength $items] == 0} {
        if {[dict get $typ k] eq "array"} {
            set sz [dict get $typ size]
            if {$sz eq ""} { set sz 0 }
            return "\[0; $sz\]"
        }
        return "\{\}"
    }
    if {$type_name ne "" && [dict get $typ k] ne "array"} {
        set field_names [tm_get_struct_fields $type_name]
        if {[llength $field_names] > 0 && [llength $field_names] >= [llength $items]} {
            set parts {}
            set i 0
            foreach item $items {
                if {[lindex $item 0] eq "named"} {
                    lappend parts "[lindex $item 1]: [em [lindex $item 2]]"
                } else {
                    lappend parts "[lindex $field_names $i]: [em [lindex $item 1]]"
                }
                incr i
            }
            return "$type_name \{ [join $parts ", "] \}"
        }
    }
    set parts {}
    foreach item $items {
        if {[lindex $item 0] eq "named"} {
            lappend parts "[lindex $item 1]: [em [lindex $item 2]]"
        } else {
            lappend parts [em [lindex $item 1]]
        }
    }
    set items_str [join $parts ", "]
    if {$type_name ne "" && [dict get $typ k] ne "array"} {
        return "$type_name \{ $items_str \}"
    }
    return "\{ $items_str \}"
}

proc pak::c2pak::sm_type_name {typ} {
    set k [dict get $typ k]
    if {$k eq "typeref"} { return [dict get $typ name] }
    if {$k eq "struct"} { return [dict get $typ name] }
    set pak [tm_map $typ]
    if {$pak ne "" && [string index $pak 0] ne "\[" && [string index $pak 0] ne "*"} {
        return $pak
    }
    return ""
}

proc pak::c2pak::sm_emit_expr_stmt {stmt linesVar} {
    upvar $linesVar lines
    set expr [dict get $stmt expr]
    set k [dict get $expr k]
    if {$k eq "unary" && [dict get $expr op] in {++ --}} {
        set target [sm_emit_expr [dict get $expr expr]]
        set op [expr {[dict get $expr op] eq "++" ? "+=" : "-="}]
        lappend lines [pad "$target $op 1"]
        return
    }
    if {$k eq "assign" && [dict get $expr op] eq "=" && [dict get [dict get $expr value] k] eq "ternary"} {
        set t [dict get $expr value]
        set target [sm_emit_expr [dict get $expr target]]
        set cond [sm_emit_expr_as_bool [dict get $t cond]]
        set then_v [sm_emit_expr [dict get $t then]]
        set else_v [sm_emit_expr [dict get $t otherwise]]
        lappend lines [pad "if $cond \{ $target = $then_v \} else \{ $target = $else_v \}"]
        return
    }
    if {$k eq "assign"} {
        set chained [flatten_chain_assign $expr]
        set op [dict get $expr op]
        foreach pair $chained {
            lassign $pair t v
            lappend lines [pad "[sm_emit_expr $t] $op [sm_emit_expr $v]"]
        }
        return
    }
    if {$k eq "comma"} {
        foreach sub [dict get $expr exprs] {
            sm_emit_stmt [dict create k exprstmt expr $sub] lines
        }
        return
    }
    lassign [extract_increments $expr] extracted clean
    foreach line $extracted { lappend lines [pad $line] }
    lappend lines [pad [sm_emit_expr $clean]]
}

proc pak::c2pak::flatten_chain_assign {expr} {
    set result {}
    set cur $expr
    while {[dict get [dict get $cur value] k] eq "assign" && [dict get $cur op] eq "="} {
        set inner [dict get $cur value]
        lappend result [list [dict get $inner target] [dict get $inner value]]
        set cur [dict create k assign op [dict get $cur op] target [dict get $cur target] value [dict get $inner target]]
    }
    lappend result [list [dict get $cur target] [dict get $cur value]]
    return [lreverse $result]
}

proc pak::c2pak::extract_increments {expr} {
    variable S_tmp
    if {[dict get $expr k] eq "arrayref"} {
        set idx [dict get $expr index]
        if {[dict get $idx k] eq "unary" && [dict get $idx op] in {++ --} && [dict get $idx postfix]} {
            incr S_tmp
            set tmp "_tmp$S_tmp"
            set target [em [dict get $idx expr]]
            set op [expr {[dict get $idx op] eq "++" ? "+= 1" : "-= 1"}]
            set pre [list "let $tmp: i32 = $target" "$target $op"]
            set clean [dict create k arrayref base [dict get $expr base] index [dict create k id name $tmp]]
            return [list $pre $clean]
        }
    }
    return [list {} $expr]
}

proc pak::c2pak::sm_emit_if {stmt linesVar} {
    upvar $linesVar lines
    set cond [sm_emit_expr_as_bool [dict get $stmt cond]]
    lappend lines [pad "if $cond \{"]
    sm_indent_in
    sm_emit_body_block [dict get $stmt then] lines
    sm_indent_out
    sm_emit_else [dict get $stmt otherwise] lines
}

proc pak::c2pak::sm_emit_else {otherwise linesVar} {
    upvar $linesVar lines
    if {$otherwise eq ""} {
        lappend lines [pad "\}"]
    } elseif {[dict get $otherwise k] eq "if"} {
        set cond [sm_emit_expr_as_bool [dict get $otherwise cond]]
        lappend lines [pad "\} elif $cond \{"]
        sm_indent_in
        sm_emit_body_block [dict get $otherwise then] lines
        sm_indent_out
        sm_emit_else [dict get $otherwise otherwise] lines
    } else {
        lappend lines [pad "\} else \{"]
        sm_indent_in
        sm_emit_body_block $otherwise lines
        sm_indent_out
        lappend lines [pad "\}"]
    }
}

proc pak::c2pak::sm_emit_body_block {stmt linesVar} {
    upvar $linesVar lines
    if {[dict get $stmt k] eq "compound"} {
        sm_emit_compound_items [dict get $stmt items] lines
    } else {
        sm_emit_stmt $stmt lines
    }
}

proc pak::c2pak::sm_emit_while {stmt linesVar} {
    upvar $linesVar lines
    set cond [dict get $stmt cond]
    if {[is_always_true $cond]} {
        lappend lines [pad "loop \{"]
        sm_indent_in
        sm_emit_body_block [dict get $stmt body] lines
        sm_indent_out
        lappend lines [pad "\}"]
        return
    }
    set assign_info [extract_assign_in_cond $cond]
    if {$assign_info ne ""} {
        lassign $assign_info var_name rhs_expr cmp_op cmp_rhs
        lappend lines [pad "loop \{"]
        sm_indent_in
        set rhs_str [sm_emit_expr $rhs_expr]
        lappend lines [pad "let $var_name = $rhs_str"]
        set cmp_rhs_str [sm_emit_expr $cmp_rhs]
        set break_cond [invert_cmp $cmp_op]
        lappend lines [pad "if $var_name $break_cond $cmp_rhs_str \{ break \}"]
        sm_emit_body_block [dict get $stmt body] lines
        sm_indent_out
        lappend lines [pad "\}"]
        return
    }
    set c [sm_emit_expr_as_bool $cond]
    lappend lines [pad "while $c \{"]
    sm_indent_in
    sm_emit_body_block [dict get $stmt body] lines
    sm_indent_out
    lappend lines [pad "\}"]
}

proc pak::c2pak::sm_emit_dowhile {stmt linesVar} {
    upvar $linesVar lines
    lappend lines [pad "loop \{"]
    sm_indent_in
    sm_emit_body_block [dict get $stmt body] lines
    set cond [sm_emit_expr_as_bool [dict get $stmt cond]]
    lappend lines [pad "if !($cond) \{ break \}"]
    sm_indent_out
    lappend lines [pad "\}"]
}

proc pak::c2pak::sm_emit_for {stmt linesVar} {
    upvar $linesVar lines
    set init [dict get $stmt init]
    set cond [dict get $stmt cond]
    set step [dict get $stmt step]
    if {$cond eq "" && $init eq "" && $step eq ""} {
        lappend lines [pad "loop \{"]
        sm_indent_in
        sm_emit_body_block [dict get $stmt body] lines
        sm_indent_out
        lappend lines [pad "\}"]
        return
    }
    set range_result [detect_range_for $stmt]
    if {$range_result ne ""} {
        lassign $range_result var start end step_val end_needs_parens
        set end_str [expr {$end_needs_parens ? "($end)" : $end}]
        if {$step_val == 1} {
            lappend lines [pad "for $var in $start..$end_str \{"]
            sm_indent_in
            sm_emit_body_block [dict get $stmt body] lines
            sm_indent_out
            lappend lines [pad "\}"]
        } else {
            lappend lines [pad "let $var: i32 = $start"]
            lappend lines [pad "while $var < $end_str \{"]
            sm_indent_in
            sm_emit_body_block [dict get $stmt body] lines
            lappend lines [pad "$var += $step_val"]
            sm_indent_out
            lappend lines [pad "\}"]
        }
        return
    }
    # general
    if {$init ne ""} {
        if {[is_decl_list $init]} {
            foreach decl $init { sm_emit_stmt $decl lines }
        } elseif {[dict get $init k] eq "exprstmt"} {
            sm_emit_expr_stmt $init lines
        }
    }
    if {$cond ne ""} {
        set c [sm_emit_expr_as_bool $cond]
        lappend lines [pad "while $c \{"]
    } else {
        lappend lines [pad "loop \{"]
    }
    sm_indent_in
    sm_emit_body_block [dict get $stmt body] lines
    if {$step ne ""} {
        sm_emit_stmt [dict create k exprstmt expr $step] lines
    }
    sm_indent_out
    lappend lines [pad "\}"]
}

# init in our parser: for-decl is a list of var dicts. Detect via first element
# being a dict with k==var (list of decls) vs single exprstmt dict.
proc pak::c2pak::is_decl_list {init} {
    # A var-decl list is a Tcl list whose first element is a dict {k var ...}
    if {[catch {set first [lindex $init 0]}]} { return 0 }
    if {[catch {dict get $first k} fk]} { return 0 }
    return [expr {$fk eq "var"}]
}

proc pak::c2pak::detect_range_for {stmt} {
    set init [dict get $stmt init]
    set cond [dict get $stmt cond]
    set step [dict get $stmt step]
    if {$init eq "" || $cond eq "" || $step eq ""} { return "" }
    if {![is_decl_list $init] || [llength $init] != 1} { return "" }
    set decl [lindex $init 0]
    if {[dict get $decl k] ne "var" || [dict get $decl init] eq ""} { return "" }
    set var [dict get $decl name]
    set start [em [dict get $decl init]]
    if {[dict get $cond k] ne "binop"} { return "" }
    set cleft [dict get $cond left]
    if {[dict get $cleft k] ne "id" || [dict get $cleft name] ne $var} { return "" }
    set end_needs_parens 0
    set cop [dict get $cond op]
    if {$cop eq "<"} {
        set end_expr [dict get $cond right]
        set end [em $end_expr]
        if {[dict get $end_expr k] eq "binop"} { set end_needs_parens 1 }
    } elseif {$cop eq "<="} {
        set end_expr [dict get $cond right]
        if {[dict get $end_expr k] eq "const" && [dict get $end_expr kind] eq "int"} {
            set end [expr {[parseIntLit [dict get $end_expr value]] + 1}]
        } else {
            set end "[em $end_expr] + 1"
            set end_needs_parens 1
        }
    } else {
        return ""
    }
    # step
    set step_val 1
    if {[dict get $step k] eq "unary" && [dict get $step op] in {++ --}} {
        set se [dict get $step expr]
        if {[dict get $se k] ne "id" || [dict get $se name] ne $var} { return "" }
        set step_val [expr {[dict get $step op] eq "++" ? 1 : -1}]
    } elseif {[dict get $step k] eq "assign" && [dict get $step op] eq "+="} {
        set st [dict get $step target]
        if {[dict get $st k] ne "id" || [dict get $st name] ne $var} { return "" }
        set sv [dict get $step value]
        if {[dict get $sv k] eq "const"} {
            if {[catch {set step_val [parseIntLit [dict get $sv value]]}]} { return "" }
        } else { return "" }
    } else {
        return ""
    }
    if {$step_val <= 0} { return "" }
    return [list $var $start $end $step_val $end_needs_parens]
}

proc pak::c2pak::sm_emit_switch {stmt linesVar} {
    upvar $linesVar lines
    set cond [em [dict get $stmt cond]]
    lappend lines [pad "match $cond \{"]
    sm_indent_in
    sm_emit_cases [dict get $stmt cases] lines
    sm_indent_out
    lappend lines [pad "\}"]
}

proc pak::c2pak::sm_emit_cases {cases linesVar} {
    upvar $linesVar lines
    foreach case $cases {
        if {[dict get $case value] eq ""} {
            set arm "_"
        } else {
            set arm [sm_emit_case_value [dict get $case value]]
        }
        set body_stmts {}
        foreach s [dict get $case stmts] {
            if {[dict get $s k] ne "break"} { lappend body_stmts $s }
        }
        if {[llength $body_stmts] == 0} {
            lappend lines [pad "$arm => \{\}"]
        } elseif {[llength $body_stmts] == 1 && [dict get [lindex $body_stmts 0] k] eq "exprstmt"} {
            set stmt_line [em [dict get [lindex $body_stmts 0] expr]]
            lappend lines [pad "$arm => \{ $stmt_line \}"]
        } else {
            lappend lines [pad "$arm => \{"]
            sm_indent_in
            foreach s $body_stmts { sm_emit_stmt $s lines }
            sm_indent_out
            lappend lines [pad "\}"]
        }
    }
}

proc pak::c2pak::sm_emit_case_value {value} {
    set raw [em $value]
    if {[dict get $value k] eq "id"} {
        set cleaned [strip_enum_prefix $raw]
        return ".$cleaned"
    }
    return $raw
}

proc pak::c2pak::sm_emit_return {stmt linesVar} {
    upvar $linesVar lines
    set val [dict get $stmt value]
    if {$val eq ""} {
        lappend lines [pad "return"]
    } elseif {[dict get $val k] eq "ternary"} {
        set cond [sm_emit_expr_as_bool [dict get $val cond]]
        lappend lines [pad "if $cond \{ return [sm_emit_expr [dict get $val then]] \}"]
        lappend lines [pad "return [sm_emit_expr [dict get $val otherwise]]"]
    } else {
        lappend lines [pad "return [sm_emit_expr $val]"]
    }
}

# ── stmt helpers ──
proc pak::c2pak::is_always_true {expr} {
    if {[dict get $expr k] eq "const" && [dict get $expr kind] eq "int"} {
        if {![catch {set n [parseIntLit [dict get $expr value]]}]} { return [expr {$n != 0}] }
    }
    if {[dict get $expr k] eq "id" && [dict get $expr name] in {true 1}} { return 1 }
    return 0
}

proc pak::c2pak::zero_value {pak_type} {
    if {$pak_type in {i8 i16 i32 i64 u8 u16 u32 u64}} { return "0" }
    if {$pak_type in {f32 f64}} { return "0.0" }
    if {$pak_type eq "bool"} { return "false" }
    if {[string index $pak_type 0] eq "*"} { return "none" }
    if {[string index $pak_type 0] eq "\["} { return "\[\]" }
    set c0 [string index $pak_type 0]
    if {[string is upper $c0] || $c0 eq "_"} { return "undefined" }
    return "0"
}

proc pak::c2pak::extract_assign_in_cond {cond} {
    if {[dict get $cond k] ne "binop"} { return "" }
    set cmp_op [dict get $cond op]
    if {$cmp_op ni {!= == < > <= >=}} { return "" }
    set left [dict get $cond left]
    set right [dict get $cond right]
    if {[dict get $left k] ne "assign" || [dict get $left op] ne "="} { return "" }
    if {[dict get [dict get $left target] k] ne "id"} { return "" }
    set var_name [dict get [dict get $left target] name]
    set rhs_expr [dict get $left value]
    return [list $var_name $rhs_expr $cmp_op $right]
}

proc pak::c2pak::invert_cmp {op} {
    array set inv {!= == == != < >= > <= <= > >= <}
    if {[info exists inv($op)]} { return $inv($op) }
    return $op
}

proc pak::c2pak::strip_enum_prefix {name} {
    set parts [split $name "_"]
    if {[llength $parts] >= 2} {
        return [string tolower [join [lrange $parts 1 end] "_"]]
    }
    return [string tolower $name]
}

# ── goto/defer transform ──
proc pak::c2pak::scan_gotos {items resultVar} {
    upvar $resultVar result
    foreach item $items {
        set k [dict get $item k]
        if {$k eq "goto"} {
            set lbl [dict get $item label]
            dict incr result $lbl
        } elseif {$k eq "compound"} {
            scan_gotos [dict get $item items] result
        } elseif {$k eq "if"} {
            set then [dict get $item then]
            if {[dict get $then k] eq "compound"} { scan_gotos [dict get $then items] result } else { scan_gotos [list $then] result }
            set oth [dict get $item otherwise]
            if {$oth ne ""} {
                if {[dict get $oth k] eq "compound"} { scan_gotos [dict get $oth items] result } else { scan_gotos [list $oth] result }
            }
        } elseif {$k in {while dowhile for}} {
            set body [dict get $item body]
            if {[dict get $body k] eq "compound"} { scan_gotos [dict get $body items] result }
        }
    }
}

proc pak::c2pak::collect_label_stmts {items label_name} {
    set result {}
    set in_label 0
    foreach item $items {
        set k [dict get $item k]
        if {$k eq "label" && [dict get $item name] eq $label_name} {
            set in_label 1
            if {[dict get $item stmt] ne ""} { lappend result [dict get $item stmt] }
        } elseif {$in_label} {
            if {$k eq "return" || $k eq "label"} { break }
            lappend result $item
        }
    }
    return $result
}

proc pak::c2pak::replace_gotos_recursive {items cleanup_labels} {
    set result {}
    foreach item $items {
        set k [dict get $item k]
        if {$k eq "goto" && [dict get $item label] in $cleanup_labels} {
            lappend result [dict create k empty]
        } elseif {$k eq "if"} {
            set new_then [dict get $item then]
            set new_oth [dict get $item otherwise]
            if {[dict get $new_then k] eq "compound"} {
                set new_then [dict create k compound items [replace_gotos_recursive [dict get $new_then items] $cleanup_labels]]
            } elseif {[dict get $new_then k] eq "goto" && [dict get $new_then label] in $cleanup_labels} {
                set new_then [dict create k empty]
            }
            if {$new_oth ne "" && [dict get $new_oth k] eq "compound"} {
                set new_oth [dict create k compound items [replace_gotos_recursive [dict get $new_oth items] $cleanup_labels]]
            } elseif {$new_oth ne "" && [dict get $new_oth k] eq "goto" && [dict get $new_oth label] in $cleanup_labels} {
                set new_oth [dict create k empty]
            }
            lappend result [dict create k if cond [dict get $item cond] then $new_then otherwise $new_oth]
        } else {
            lappend result $item
        }
    }
    return $result
}

proc pak::c2pak::transform_goto_defer {items} {
    set goto_targets [dict create]
    scan_gotos $items goto_targets

    set labels [dict create]
    set idx 0
    foreach item $items {
        if {[dict get $item k] eq "label"} { dict set labels [dict get $item name] $idx }
        incr idx
    }
    if {[dict size $goto_targets] == 0 || [dict size $labels] == 0} { return $items }

    # cleanup labels (ordered like dict iteration of labels)
    set cleanup_order {}
    set cleanup_stmts [dict create]
    dict for {label_name label_idx} $labels {
        if {![dict exists $goto_targets $label_name]} { continue }
        set ll [string tolower $label_name]
        set is_cleanup 0
        foreach s {cleanup clean_up error fail free} {
            if {[string first $s $ll] >= 0} { set is_cleanup 1; break }
        }
        if {!$is_cleanup} { continue }
        lappend cleanup_order $label_name
        dict set cleanup_stmts $label_name [collect_label_stmts $items $label_name]
    }
    if {[llength $cleanup_order] == 0} { return $items }

    # skip indices
    set skip [dict create]
    foreach label_name $cleanup_order {
        set label_idx [dict get $labels $label_name]
        dict set skip $label_idx 1
        for {set j [expr {$label_idx+1}]} {$j < [llength $items]} {incr j} {
            set item [lindex $items $j]
            if {[dict get $item k] in {return label}} { break }
            dict set skip $j 1
        }
    }

    set filtered {}
    set i 0
    foreach item $items {
        if {![dict exists $skip $i]} { lappend filtered $item }
        incr i
    }
    set new_items [replace_gotos_recursive $filtered $cleanup_order]

    # insert defer after leading declarations
    set insert_pos 0
    set i 0
    foreach item $new_items {
        if {[dict get $item k] eq "var"} { set insert_pos [expr {$i+1}] } else break
        incr i
    }
    set result {}
    if {$insert_pos == 0} {
        foreach label_name $cleanup_order {
            lappend result [dict create k defer stmts [dict get $cleanup_stmts $label_name]]
        }
        foreach item $new_items { lappend result $item }
        return $result
    }
    set i 0
    foreach item $new_items {
        lappend result $item
        if {$i == [expr {$insert_pos-1}]} {
            foreach label_name $cleanup_order {
                lappend result [dict create k defer stmts [dict get $cleanup_stmts $label_name]]
            }
        }
        incr i
    }
    return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# N64 API map
# ─────────────────────────────────────────────────────────────────────────────
namespace eval pak::c2pak {
    variable N64API
    set N64API [dict create \
        display_init {display init} display_get {display get} display_show {display show} display_close {display close} \
        rdpq_init {rdpq init} rdpq_close {rdpq close} rdpq_attach {rdpq attach} rdpq_attach_clear {rdpq attach_clear} \
        rdpq_detach {rdpq detach} rdpq_detach_show {rdpq detach_show} rdpq_set_mode_standard {rdpq set_mode_standard} \
        rdpq_set_mode_copy {rdpq set_mode_copy} rdpq_set_mode_fill {rdpq set_mode_fill} rdpq_fill_rectangle {rdpq fill_rectangle} \
        rdpq_sync_full {rdpq sync_full} rdpq_sync_pipe {rdpq sync_pipe} rdpq_sync_tile {rdpq sync_tile} rdpq_sync_load {rdpq sync_load} \
        rdpq_set_scissor {rdpq set_scissor} rdpq_triangle {rdpq triangle} rdpq_texture_rectangle {rdpq texture_rectangle} \
        rdpq_texture_rectangle_scaled {rdpq texture_rectangle_scaled} rdpq_set_blend_color {rdpq set_blend_color} \
        rdpq_set_fog_color {rdpq set_fog_color} rdpq_set_fill_color {rdpq set_fill_color} rdpq_set_env_color {rdpq set_env_color} \
        rdpq_set_prim_color {rdpq set_prim_color} rdpq_set_z_image {rdpq set_z_image} rdpq_set_color_image {rdpq set_color_image} \
        rdpq_set_tile {rdpq set_tile} rdpq_set_tile_size {rdpq set_tile_size} rdpq_load_tile {rdpq load_tile} \
        rdpq_load_tlut {rdpq load_tlut} rdpq_set_combiner_raw {rdpq set_combiner_raw} rdpq_set_other_modes_raw {rdpq set_other_modes_raw} \
        rspq_flush {rdpq flush} rdpq_block_begin {rdpq block_begin} rdpq_block_end {rdpq block_end} rdpq_block_run {rdpq block_run} \
        rdpq_block_free {rdpq block_free} rdpq_call {rdpq call} \
        joypad_init {joypad init} joypad_poll {joypad poll} joypad_get_status {joypad get_status} joypad_get_buttons {joypad get_buttons} \
        joypad_get_buttons_pressed {joypad get_buttons_pressed} joypad_get_buttons_released {joypad get_buttons_released} \
        joypad_get_axis_held {joypad get_axis_held} joypad_get_axis_pressed {joypad get_axis_pressed} \
        joypad_get_accessory_type {joypad get_accessory_type} joypad_is_connected {joypad is_connected} \
        surface_alloc {surface alloc} surface_free {surface free} surface_make_sub {surface make_sub} display_get_surface {display get} \
        audio_init {audio init} audio_close {audio close} audio_push {audio push} audio_get_buffer {audio get_buffer} audio_write {audio write} \
    ]
}
proc pak::c2pak::n64_api {name} {
    variable N64API
    if {[dict exists $N64API $name]} { return [dict get $N64API $name] }
    return ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Decl mapper
# ─────────────────────────────────────────────────────────────────────────────

proc pak::c2pak::method_pak_name {c_name struct_name} {
    set prefix "[string tolower $struct_name]_"
    if {[string first $prefix [string tolower $c_name]] == 0} {
        return [string range $c_name [string length $prefix] end]
    }
    return $c_name
}

proc pak::c2pak::dm_emit_struct {decl} {
    set lines {}
    foreach attr [dict get $decl attrs] {
        if {[string first "aligned" $attr] >= 0} {
            if {[regexp {aligned\s*\((\d+)\)} $attr -> n]} { lappend lines "@aligned($n)" }
        } elseif {[string first "packed" $attr] >= 0} {
            lappend lines "@packed"
        }
    }
    set fields [dict get $decl fields]
    set name [dict get $decl name]
    if {[llength $fields] == 0} {
        lappend lines "struct $name \{\}"
        return $lines
    }
    set simple 1
    if {[llength $fields] > 3} { set simple 0 }
    foreach f $fields {
        set fk [dict get [dict get $f typ] k]
        if {$fk eq "struct" || $fk eq "union"} { set simple 0 }
    }
    if {$simple} {
        set parts {}
        foreach f $fields { lappend parts "[dict get $f name]: [tm_field_type $f]" }
        lappend lines "struct $name \{ [join $parts ", "] \}"
    } else {
        lappend lines "struct $name \{"
        foreach f $fields {
            foreach l [dm_emit_field $f] { lappend lines $l }
        }
        lappend lines "\}"
    }
    return $lines
}

proc pak::c2pak::dm_emit_field {field} {
    set typ_str [tm_field_type $field]
    if {[dict get $field bitsize] ne ""} {
        return [list "    [dict get $field name]: $typ_str,  -- c2pak: bit-field [dict get $field bitsize] bits"]
    }
    return [list "    [dict get $field name]: $typ_str,"]
}

proc pak::c2pak::dm_emit_union {decl} {
    set lines [list "union [dict get $decl name] \{"]
    foreach f [dict get $decl fields] {
        lappend lines "    [dict get $f name]: [tm_field_type $f],"
    }
    lappend lines "\}"
    return $lines
}

proc pak::c2pak::dm_emit_enum {decl} {
    set values [dict get $decl values]
    set prefix [detect_enum_prefix $values]
    set variants {}
    set seen 0
    foreach pair $values {
        lassign $pair name val
        set pak_name [strip_prefix $name $prefix]
        if {$val ne "" && !($val == $seen)} {
            lappend variants [list $pak_name $val]
        } else {
            lappend variants [list $pak_name ""]
        }
        incr seen
    }
    set is_bitflag [is_bitflag_enum $values]
    set lines {}
    if {$is_bitflag} { lappend lines "-- c2pak: bitflag enum" }
    lappend lines "enum [dict get $decl name] \{"
    foreach pair $variants {
        lassign $pair pak_name val
        if {$val ne ""} {
            lappend lines "    $pak_name = $val,"
        } else {
            lappend lines "    $pak_name,"
        }
    }
    lappend lines "\}"
    return $lines
}

proc pak::c2pak::dm_emit_variant {name cases} {
    set lines [list "variant $name \{"]
    foreach case $cases {
        lassign $case case_name fields
        if {[llength $fields] == 0} {
            lappend lines "    $case_name,"
        } elseif {[llength $fields] == 1} {
            set ftype [tm_field_type [lindex $fields 0]]
            lappend lines "    ${case_name}($ftype),"
        } else {
            set parts {}
            foreach f $fields { lappend parts "[dict get $f name]: [tm_field_type $f]" }
            lappend lines "    $case_name \{ [join $parts ", "] \},"
        }
    }
    lappend lines "\}"
    return $lines
}

proc pak::c2pak::dm_emit_sig {sig {method_of ""}} {
    set name [dict get $sig name]
    if {$method_of ne ""} { set name [method_pak_name $name $method_of] }
    set params [dm_emit_params_with_slices [dict get $sig params] $method_of]
    set ret [tm_map [dict get $sig ret]]
    if {[tm_is_void [dict get $sig ret]]} {
        return "fn ${name}($params)"
    }
    return "fn ${name}($params) -> $ret"
}

proc pak::c2pak::dm_emit_params_with_slices {params method_of} {
    set skip [dict create]
    set slice_params [dict create]
    set nparams [llength $params]
    for {set i 0} {$i < $nparams} {incr i} {
        set p [lindex $params $i]
        if {[dict get [dict get $p typ] k] ne "ptr"} { continue }
        set jmax [expr {min($i+3, $nparams)}]
        for {set j [expr {$i+1}]} {$j < $jmax} {incr j} {
            set q [lindex $params $j]
            set q_typ [tm_map [dict get $q typ]]
            if {$q_typ ni {i32 u32 i64 u64 i16 u16}} { continue }
            set q_name [dict get $q name]
            set ql [string tolower $q_name]
            set matched 0
            foreach s {len count size n num cnt} {
                if {[string first $s $ql] >= 0} { set matched 1; break }
            }
            if {$matched} {
                set ptr_name [dict get $p name]
                if {$ptr_name eq ""} { set ptr_name "_p$i" }
                set ptyp [dict get $p typ]
                set inner_type [tm_map [dict get $ptyp inner]]
                set mut_str [expr {[dict get $ptyp const] ? "" : "mut "}]
                dict set slice_params $i [list $ptr_name "\[\]$mut_str$inner_type"]
                dict set skip $j 1
                break
            }
        }
    }
    set parts {}
    for {set i 0} {$i < $nparams} {incr i} {
        if {[dict exists $skip $i]} { continue }
        set p [lindex $params $i]
        set typ [tm_map [dict get $p typ]]
        if {$typ eq "void"} { continue }
        set name [dict get $p name]
        if {$name eq ""} { set name "_p$i" }
        if {$method_of ne "" && $i == 0 && [tm_is_pointer_to [dict get $p typ] $method_of]} {
            set ptyp [dict get $p typ]
            if {[dict get $ptyp k] eq "ptr" && ![dict get $ptyp const]} {
                lappend parts "self: *mut $method_of"
            } else {
                lappend parts "self: *$method_of"
            }
            continue
        }
        if {[dict exists $slice_params $i]} {
            lassign [dict get $slice_params $i] _ slice_type
            lappend parts "$name: $slice_type"
        } else {
            lappend parts "$name: $typ"
        }
    }
    return [join $parts ", "]
}

proc pak::c2pak::dm_emit_global_var {decl} {
    set pak_type [tm_map [dict get $decl typ]]
    set name [dict get $decl name]
    if {[dict get $decl is_extern]} {
        return [list "extern static $name: $pak_type"]
    }
    if {[dict get $decl is_const]} {
        set kw "const"
    } elseif {[dict get $decl is_static]} {
        set kw "static"
    } else {
        set kw "static mut"
    }
    set init [dict get $decl init]
    if {$init ne ""} {
        return [list "$kw $name: $pak_type = [em $init]"]
    }
    return [list "$kw $name: $pak_type = [zero_for_type $pak_type]"]
}

proc pak::c2pak::zero_for_type {pak_type} {
    if {$pak_type in {i8 i16 i32 i64 u8 u16 u32 u64}} { return "0" }
    if {$pak_type in {f32 f64}} { return "0.0" }
    if {$pak_type eq "bool"} { return "false" }
    if {[string index $pak_type 0] eq "*"} { return "none" }
    return "0"
}

# emit a function def fully. n64accVar = name of accumulator list var or "".
proc pak::c2pak::dm_emit_func_def_full {defn {method_of ""} {track_n64 0}} {
    variable S_selfRename
    variable S_indent
    variable S_track_n64
    set lines {}
    set sig [dict get $defn sig]
    set sig_str [dm_emit_sig $sig $method_of]
    lappend lines "$sig_str \{"
    sm_reset
    set S_indent 1
    set S_track_n64 $track_n64
    if {$method_of ne "" && [llength [dict get $sig params]] > 0} {
        set fp [lindex [dict get $sig params] 0]
        if {[dict get $fp name] ne "" && [tm_is_pointer_to [dict get $fp typ] $method_of]} {
            set S_selfRename [dict get $fp name]
        }
    }
    set body_lines {}
    sm_emit_compound_items [dict get [dict get $defn body] items] body_lines
    foreach l $body_lines { lappend lines $l }
    lappend lines "\}"
    sm_reset
    return $lines
}

proc pak::c2pak::dm_emit_impl_block {struct_name methods {track_n64 0}} {
    set lines [list "impl $struct_name \{"]
    set i 0
    foreach method $methods {
        if {$i > 0} { lappend lines "" }
        set method_lines [dm_emit_func_def_full $method $struct_name $track_n64]
        foreach ml $method_lines { lappend lines "    $ml" }
        incr i
    }
    lappend lines "\}"
    return $lines
}

# ── enum utils ──
proc pak::c2pak::detect_enum_prefix {values} {
    if {[llength $values] == 0} { return "" }
    set names {}
    foreach v $values { lappend names [lindex $v 0] }
    if {[llength $names] == 1} { return "" }
    set prefix [common_prefix $names]
    set idx [string last "_" $prefix]
    if {$idx >= 0} { return [string range $prefix 0 $idx] }
    return ""
}
proc pak::c2pak::common_prefix {strings} {
    if {[llength $strings] == 0} { return "" }
    set s [lindex $strings 0]
    foreach other [lrange $strings 1 end] {
        while {[string first $s $other] != 0} {
            set s [string range $s 0 end-1]
            if {$s eq ""} { return "" }
        }
    }
    return $s
}
proc pak::c2pak::strip_prefix {name prefix} {
    if {$prefix ne "" && [string first $prefix $name] == 0} {
        set name [string range $name [string length $prefix] end]
    }
    return [string tolower $name]
}
proc pak::c2pak::is_bitflag_enum {values} {
    set explicit {}
    foreach v $values { if {[lindex $v 1] ne ""} { lappend explicit [lindex $v 1] } }
    if {[llength $explicit] < 2} { return 0 }
    foreach v $explicit {
        if {!($v > 0 && ($v & ($v-1)) == 0)} { return 0 }
    }
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Idiom detector
# ─────────────────────────────────────────────────────────────────────────────

namespace eval pak::c2pak {
    variable ID_structs
    variable ID_unions
    variable ID_enums
    variable ID_typedefs
    variable ID_funcdefs
}

proc pak::c2pak::id_index {cfile} {
    variable ID_structs; variable ID_unions; variable ID_enums; variable ID_typedefs; variable ID_funcdefs
    set ID_structs [dict create]
    set ID_unions [dict create]
    set ID_enums [dict create]
    set ID_typedefs [dict create]
    set ID_funcdefs {}
    foreach decl [dict get $cfile decls] {
        set k [dict get $decl k]
        switch -- $k {
            structdecl { dict set ID_structs [dict get $decl name] $decl }
            uniondecl { dict set ID_unions [dict get $decl name] $decl }
            enumdecl { dict set ID_enums [dict get $decl name] $decl }
            typedef {
                dict set ID_typedefs [dict get $decl name] [dict get $decl typ]
                id_index_typedef $decl
            }
            funcdef { lappend ID_funcdefs $decl }
        }
    }
}

proc pak::c2pak::id_index_typedef {decl} {
    variable ID_structs; variable ID_unions; variable ID_enums
    set name [dict get $decl name]
    set typ [dict get $decl typ]
    set tk [dict get $typ k]
    if {$tk eq "struct"} {
        dict set ID_structs $name [dict create k structdecl name $name fields [dict get $typ fields] attrs {}]
    } elseif {$tk eq "union"} {
        dict set ID_unions $name [dict create k uniondecl name $name fields [dict get $typ fields] attrs {}]
    } elseif {$tk eq "enum"} {
        dict set ID_enums $name [dict create k enumdecl name $name values [dict get $typ values]]
    }
}

proc pak::c2pak::id_resolve_type {typ} {
    variable ID_typedefs; variable ID_structs; variable ID_unions; variable ID_enums
    set visited {}
    while {[dict get $typ k] eq "typeref"} {
        set name [dict get $typ name]
        if {$name in $visited} break
        lappend visited $name
        if {[dict exists $ID_typedefs $name]} {
            set typ [dict get $ID_typedefs $name]
        } elseif {[dict exists $ID_structs $name]} {
            return [dict get $ID_structs $name]
        } elseif {[dict exists $ID_unions $name]} {
            set u [dict get $ID_unions $name]
            return [dict create k union name $name fields [dict get $u fields]]
        } elseif {[dict exists $ID_enums $name]} {
            set e [dict get $ID_enums $name]
            return [dict create k enum name $name values [dict get $e values]]
        } else break
    }
    return $typ
}

proc pak::c2pak::id_is_enum_type {typ} {
    set r [id_resolve_type $typ]
    return [expr {[dict get $r k] eq "enum"}]
}

# ── tagged unions ──
proc pak::c2pak::detect_tagged_unions {} {
    variable ID_structs
    set results {}
    dict for {name struct} $ID_structs {
        set info [check_tagged_union $name $struct]
        if {$info ne ""} { lappend results $info }
    }
    return $results
}

proc pak::c2pak::check_tagged_union {name struct} {
    variable ID_enums
    set tag_field ""
    set union_field ""
    set shared_fields {}
    foreach f [dict get $struct fields] {
        set ftype [id_resolve_type [dict get $f typ]]
        if {$tag_field eq "" && [id_is_enum_type $ftype]} {
            set tag_field $f
        } elseif {$union_field eq "" && [dict get $ftype k] eq "union"} {
            set union_field $f
        } elseif {$union_field eq "" && [dict get [dict get $f typ] k] eq "typeref"} {
            set resolved [id_resolve_type [dict get $f typ]]
            if {[dict get $resolved k] eq "union"} {
                set union_field [dict create name [dict get $f name] typ $resolved bitsize ""]
            } else {
                lappend shared_fields $f
            }
        } else {
            lappend shared_fields $f
        }
    }
    if {$tag_field eq "" || $union_field eq ""} { return "" }
    set tfk [dict get [dict get $tag_field typ] k]
    if {$tfk eq "typeref"} {
        set tag_enum_name [dict get [dict get $tag_field typ] name]
    } else {
        set rt [id_resolve_type [dict get $tag_field typ]]
        set tag_enum_name [id_get_type_name $rt]
    }
    if {$tag_enum_name eq ""} { return "" }
    set union_type [id_resolve_type [dict get $union_field typ]]
    if {[dict get $union_type k] ne "union"} { return "" }
    set enum_decl ""
    if {[dict exists $ID_enums $tag_enum_name]} { set enum_decl [dict get $ID_enums $tag_enum_name] }
    set cases [build_variant_cases $union_type $enum_decl $shared_fields]
    if {[llength $cases] == 0} { return "" }
    return [dict create struct_name $name tag_field [dict get $tag_field name] tag_enum $tag_enum_name cases $cases]
}

proc pak::c2pak::build_variant_cases {union_type enum_decl shared_fields} {
    set cases {}
    set enum_values {}
    if {$enum_decl ne ""} {
        set vals [dict get $enum_decl values]
        set prefix [detect_enum_prefix $vals]
        foreach pair $vals {
            lappend enum_values [list [strip_prefix [lindex $pair 0] $prefix] [lindex $pair 1]]
        }
    }
    foreach field [dict get $union_type fields] {
        set field_type [id_resolve_type [dict get $field typ]]
        set case_name [match_enum_case [dict get $field name] $enum_values]
        if {[dict get $field_type k] eq "struct"} {
            set case_fields [concat $shared_fields [dict get $field_type fields]]
        } else {
            set case_fields [concat $shared_fields [list $field]]
        }
        lappend cases [list $case_name $case_fields]
    }
    set union_names {}
    foreach field [dict get $union_type fields] {
        lappend union_names [match_enum_case [dict get $field name] $enum_values]
    }
    foreach pair $enum_values {
        set enum_name [lindex $pair 0]
        if {$enum_name ni $union_names} {
            lappend cases [list $enum_name $shared_fields]
        }
    }
    return $cases
}

proc pak::c2pak::match_enum_case {field_name enum_values} {
    foreach pair $enum_values {
        set ev_name [lindex $pair 0]
        if {$ev_name eq $field_name || $ev_name eq [string tolower $field_name]} { return $ev_name }
    }
    foreach pair $enum_values {
        set ev_name [lindex $pair 0]
        if {[string first $field_name $ev_name] >= 0 || [string first $ev_name $field_name] >= 0} { return $ev_name }
    }
    return [string tolower $field_name]
}

proc pak::c2pak::id_get_type_name {typ} {
    set k [dict get $typ k]
    if {$k in {enum struct union typeref}} { return [dict get $typ name] }
    return ""
}

# ── method groups ──
proc pak::c2pak::detect_method_groups {} {
    variable ID_funcdefs; variable ID_structs
    set known_structs [dict keys $ID_structs]
    set candidates [dict create]
    set order {}
    foreach func_def $ID_funcdefs {
        set sig [dict get $func_def sig]
        set struct_name [detect_method_struct $sig $known_structs]
        if {$struct_name ne ""} {
            if {![dict exists $candidates $struct_name]} {
                dict set candidates $struct_name {}
                lappend order $struct_name
            }
            dict lappend candidates $struct_name $func_def
        }
    }
    set groups {}
    foreach sn $order {
        lappend groups [dict create struct_name $sn methods [dict get $candidates $sn]]
    }
    return $groups
}

proc pak::c2pak::detect_method_struct {sig known_structs} {
    set name [dict get $sig name]
    set params [dict get $sig params]
    if {[llength $params] == 0} { return "" }
    set first_param [lindex $params 0]
    set param_struct [get_pointer_target_name [dict get $first_param typ]]
    if {$param_struct eq ""} { return "" }
    set name_lower [string tolower $name]
    set struct_lower [string tolower $param_struct]
    if {[string first "$\{struct_lower\}_" $name_lower] == 0} { return $param_struct }
    foreach struct_name $known_structs {
        if {[string first "[string tolower $struct_name]_" $name_lower] == 0} {
            if {[get_pointer_target_name [dict get $first_param typ]] eq $struct_name} { return $struct_name }
        }
    }
    return ""
}

proc pak::c2pak::get_pointer_target_name {typ} {
    if {[dict get $typ k] eq "ptr"} {
        set inner [dict get $typ inner]
        if {[dict get $inner k] eq "typeref"} { return [dict get $inner name] }
        set resolved [id_resolve_type $inner]
        if {[dict get $resolved k] eq "struct" && [dict get $resolved name] ne ""} {
            return [dict get $resolved name]
        }
    }
    return ""
}

# ── fixed point ──
proc pak::c2pak::detect_fixed_point_typedefs {} {
    variable ID_typedefs
    set result [dict create]
    dict for {name typ} $ID_typedefs {
        set fp [classify_fixedpoint $name $typ]
        if {$fp ne ""} { dict set result $name $fp }
    }
    return $result
}
proc pak::c2pak::classify_fixedpoint {name typ} {
    set up [string toupper $name]
    foreach s {FIX16 Q16_16 S16_16 FIXED16} { if {[string first $s $up] >= 0} { return "fix16.16" } }
    foreach s {FIX1_15 Q1_15 S1_15} { if {[string first $s $up] >= 0} { return "fix1.15" } }
    foreach s {FIX10_5 S10_5 Q10_5} { if {[string first $s $up] >= 0} { return "fix10.5" } }
    return ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Macro const inference
# ─────────────────────────────────────────────────────────────────────────────
proc pak::c2pak::infer_const_type {val} {
    set val [string trim $val]
    if {[regexp {^0[xX][0-9a-fA-F]+[uUlL]*$} $val]} {
        return [list u32 [string trimright $val "uUlL"]]
    }
    if {[regexp {^-?[0-9]+[uUlL]*$} $val]} {
        return [list i32 [string trimright $val "uUlL"]]
    }
    if {[regexp {^-?[0-9]+\.[0-9]*[fFlL]?$} $val]} {
        return [list f32 [string trimright $val "fFlL"]]
    }
    if {[regexp {^-?[0-9]+[eE][+-]?[0-9]+[fFlL]?$} $val]} {
        return [list f32 [string trimright $val "fFlL"]]
    }
    if {$val eq "1" || $val eq "true"} { return [list bool true] }
    if {$val eq "0" || $val eq "false"} { return [list bool false] }
    if {$val in {NULL ((void*)0) 0}} { return [list "" $val] }
    return [list "" $val]
}

# ─────────────────────────────────────────────────────────────────────────────
# Prelude typedef names to suppress
# ─────────────────────────────────────────────────────────────────────────────
namespace eval pak::c2pak {
    variable PRELUDE_TD {s8 u8 s16 u16 s32 u32 s64 u64 f32 f64 int8_t uint8_t int16_t uint16_t
        int32_t uint32_t int64_t uint64_t size_t ptrdiff_t __builtin_va_list bool FILE
        surface_t wchar_t uintptr_t intptr_t}
}

# ─────────────────────────────────────────────────────────────────────────────
# Emitter (pak_emitter port)
# ─────────────────────────────────────────────────────────────────────────────

proc pak::c2pak::emit {cfile} {
    variable TD; variable SF; variable METHODMAP
    variable USED_N64
    set TD [dict create]
    set SF [dict create]
    set METHODMAP [dict create]
    set USED_N64 {}

    set decls [dict get $cfile decls]

    # register typedefs
    foreach decl $decls {
        if {[dict get $decl k] eq "typedef"} { dict set TD [dict get $decl name] [dict get $decl typ] }
    }
    # register struct fields
    foreach decl $decls {
        set k [dict get $decl k]
        if {$k eq "structdecl" && [llength [dict get $decl fields]] > 0} {
            dict set SF [dict get $decl name] [structFieldNames [dict get $decl fields]]
        } elseif {$k eq "uniondecl" && [llength [dict get $decl fields]] > 0} {
            dict set SF [dict get $decl name] [structFieldNames [dict get $decl fields]]
        } elseif {$k eq "typedef"} {
            set typ [dict get $decl typ]
            if {[dict get $typ k] eq "struct" && [llength [dict get $typ fields]] > 0} {
                dict set SF [dict get $decl name] [structFieldNames [dict get $typ fields]]
            }
        }
    }

    # idiom detection
    id_index $cfile
    set tagged_unions [detect_tagged_unions]
    set method_groups [detect_method_groups]
    set fixed_point_types [detect_fixed_point_typedefs]
    dict for {td_name fp_type} $fixed_point_types {
        dict set TD $td_name [dict create k prim name $fp_type]
    }

    set tagged_struct_names {}
    set tagged_enum_names {}
    foreach tu $tagged_unions {
        lappend tagged_struct_names [dict get $tu struct_name]
        lappend tagged_enum_names [dict get $tu tag_enum]
    }

    set method_func_names {}
    foreach mg $method_groups {
        set sn [dict get $mg struct_name]
        foreach m [dict get $mg methods] {
            set fn [dict get [dict get $m sig] name]
            lappend method_func_names $fn
            dict set METHODMAP $fn [list $sn [method_pak_name $fn $sn]]
        }
    }

    set lines {}

    # macros
    set macro_lines [emit_macro_consts [dict get $cfile macros]]
    if {[llength $macro_lines] > 0} {
        foreach l $macro_lines { lappend lines $l }
        lappend lines ""
    }

    # variants
    foreach tu $tagged_unions {
        foreach l [dm_emit_variant [dict get $tu struct_name] [dict get $tu cases]] { lappend lines $l }
        lappend lines ""
    }

    # decls
    foreach decl $decls {
        set emitted [emit_decl $decl $tagged_struct_names $tagged_enum_names $method_func_names $fixed_point_types]
        if {$emitted ne "NONE"} {
            foreach l $emitted { lappend lines $l }
            lappend lines ""
        }
    }

    # impl blocks
    foreach mg $method_groups {
        set impl_lines [dm_emit_impl_block [dict get $mg struct_name] [dict get $mg methods] 1]
        foreach l $impl_lines { lappend lines $l }
        lappend lines ""
    }

    # final
    set final {}
    lappend final "-- Transpiled from C by pak convert"
    lappend final ""
    if {[llength $USED_N64] > 0} {
        foreach use [get_use_statements $USED_N64] { lappend final $use }
        lappend final ""
    }
    foreach l $lines { lappend final $l }
    while {[llength $final] > 0 && [lindex $final end] eq ""} {
        set final [lrange $final 0 end-1]
    }
    lappend final ""
    return [join $final "\n"]
}

proc pak::c2pak::structFieldNames {fields} {
    set out {}
    foreach f $fields { lappend out [dict get $f name] }
    return $out
}

proc pak::c2pak::get_use_statements {modules} {
    set uniq {}
    foreach m $modules { if {$m ni $uniq} { lappend uniq $m } }
    set sorted [lsort $uniq]
    set out {}
    foreach m $sorted { lappend out "use n64.$m" }
    return $out
}

proc pak::c2pak::emit_decl {decl skip_structs skip_enums skip_funcs fixed_point_types} {
    set k [dict get $decl k]
    switch -- $k {
        typedef { return [emit_typedef $decl $fixed_point_types] }
        structdecl {
            if {[dict get $decl name] in $skip_structs} { return "NONE" }
            return [dm_emit_struct $decl]
        }
        uniondecl { return [dm_emit_union $decl] }
        enumdecl {
            if {[dict get $decl name] in $skip_enums} { return "NONE" }
            return [dm_emit_enum $decl]
        }
        funcdecl {
            set sig [dict get $decl sig]
            if {[dict get $sig name] in $skip_funcs} { return "NONE" }
            if {[dict get $sig is_extern]} { return [list "extern [emit_sig_line $sig]"] }
            return "NONE"
        }
        funcdef {
            set sig [dict get $decl sig]
            if {[dict get $sig name] in $skip_funcs} { return "NONE" }
            if {[dict get $sig name] eq "main"} { return [emit_entry_block $decl] }
            return [dm_emit_func_def_full $decl "" 1]
        }
        var { return [dm_emit_global_var $decl] }
    }
    return "NONE"
}

proc pak::c2pak::emit_entry_block {defn} {
    variable S_indent; variable S_track_n64
    set lines [list "entry \{"]
    sm_reset
    set S_indent 1
    set S_track_n64 1
    set body_lines {}
    sm_emit_compound_items [dict get [dict get $defn body] items] body_lines
    foreach l $body_lines { lappend lines $l }
    lappend lines "\}"
    sm_reset
    return $lines
}

proc pak::c2pak::emit_typedef {decl fixed_point_types} {
    variable PRELUDE_TD
    set name [dict get $decl name]
    set typ [dict get $decl typ]
    if {$name in $PRELUDE_TD} { return "NONE" }
    if {[dict exists $fixed_point_types $name]} {
        return [list "-- c2pak: typedef $name → [dict get $fixed_point_types $name]"]
    }
    set tk [dict get $typ k]
    if {$tk eq "struct"} {
        if {[llength [dict get $typ fields]] > 0} {
            return [dm_emit_struct [dict create k structdecl name $name fields [dict get $typ fields] attrs {}]]
        }
        return "NONE"
    }
    if {$tk eq "union"} {
        if {[llength [dict get $typ fields]] > 0} {
            return [dm_emit_union [dict create k uniondecl name $name fields [dict get $typ fields]]]
        }
        return "NONE"
    }
    if {$tk eq "enum"} {
        if {[dict get $typ values] ne "FWD" && [llength [dict get $typ values]] > 0} {
            return [dm_emit_enum [dict create k enumdecl name $name values [dict get $typ values]]]
        }
        return "NONE"
    }
    if {$tk eq "prim"} {
        return "NONE"
    }
    if {$tk eq "ptr"} {
        set pak_type [tm_map $typ]
        if {$name in $PRELUDE_TD} { return "NONE" }
        return [list "-- c2pak: type $name = $pak_type"]
    }
    if {$tk eq "funcptr"} {
        return [list "type $name = [tm_map $typ]"]
    }
    return [list "-- c2pak: typedef $name = [tm_map $typ]"]
}

proc pak::c2pak::emit_sig_line {sig} {
    set parts {}
    set i 0
    foreach p [dict get $sig params] {
        set pn [dict get $p name]
        if {$pn eq ""} { set pn "_p$i" }
        lappend parts "$pn: [tm_map [dict get $p typ]]"
        incr i
    }
    set params [join $parts ", "]
    set ret [tm_map [dict get $sig ret]]
    if {[tm_is_void [dict get $sig ret]]} { return "fn [dict get $sig name]($params)" }
    return "fn [dict get $sig name]($params) -> $ret"
}

proc pak::c2pak::emit_macro_consts {macros} {
    set lines {}
    foreach pair $macros {
        lassign $pair name val
        lassign [infer_const_type $val] pak_type pak_val
        if {$pak_type ne ""} {
            lappend lines "const $name: $pak_type = $pak_val"
        } else {
            lappend lines "-- c2pak: #define $name $val"
        }
    }
    return $lines
}
