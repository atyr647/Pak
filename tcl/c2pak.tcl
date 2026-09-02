# tcl/c2pak.tcl — C → Pak transpiler (Tcl port of pak/c2pak/).
#
# Entry point: pak::c2pak_transpile {source filename} -> .pk64 text
#
# This is a self-contained port. It implements its own C lexer/parser producing
# a normalized C AST (dict-based) equivalent to pak.c2pak.c_ast, then mirrors the
# mapping/emission logic of pak/c2pak/{type,expr,stmt,decl}_mapper, idiom_detector,
# pak_emitter, c_preprocess, n64_api. Only the emitted .pk64 text must match.

namespace eval pak {}
namespace eval pak::c2pak {}

# ─────────────────────────────────────────────────────────────────────────────
# Preprocessor: strip comments, gcc extensions, collect #defines, strip directives
# ─────────────────────────────────────────────────────────────────────────────

proc pak::c2pak::strip_comments {src} {
    set out ""
    set n [string length $src]
    set i 0
    while {$i < $n} {
        set c [string index $src $i]
        set c2 [string index $src [expr {$i+1}]]
        if {$c eq "/" && $c2 eq "*"} {
            incr i 2
            while {$i < $n} {
                if {[string index $src $i] eq "*" && [string index $src [expr {$i+1}]] eq "/"} {
                    incr i 2
                    append out " "
                    break
                } elseif {[string index $src $i] eq "\n"} {
                    append out "\n"
                }
                incr i
            }
        } elseif {$c eq "/" && $c2 eq "/"} {
            incr i 2
            while {$i < $n && [string index $src $i] ne "\n"} { incr i }
        } elseif {$c eq "\""} {
            append out $c; incr i
            while {$i < $n} {
                set d [string index $src $i]
                if {$d eq "\\" && $i+1 < $n} {
                    append out $d [string index $src [expr {$i+1}]]; incr i 2
                } elseif {$d eq "\""} {
                    append out $d; incr i; break
                } else { append out $d; incr i }
            }
        } elseif {$c eq "'"} {
            append out $c; incr i
            while {$i < $n} {
                set d [string index $src $i]
                if {$d eq "\\" && $i+1 < $n} {
                    append out $d [string index $src [expr {$i+1}]]; incr i 2
                } elseif {$d eq "'"} {
                    append out $d; incr i; break
                } else { append out $d; incr i }
            }
        } else {
            append out $c; incr i
        }
    }
    return $out
}

# Returns dict: macros (ordered list of {name value}) and cleaned source.
proc pak::c2pak::preprocess {src} {
    # join line continuations
    regsub -all {\\\n} $src { } src
    set src [strip_comments $src]
    # process line directives
    set macros {}   ;# ordered list name->value (simple only)
    set macroNames {}
    set funcNames {}
    set ifdefStack {}
    set outLines {}
    foreach line [split $src "\n"] {
        set stripped [string trimleft $line]
        if {[string index $stripped 0] eq "#"} {
            set content [string trimleft [string range $stripped 1 end]]
            if {$content ne ""} {
                set parts [regexp -inline {^(\S+)\s*(.*)$} $content]
                set kw [lindex $parts 1]
                set rest [string trim [lindex $parts 2]]
                switch -- $kw {
                    define { ppDefine $rest macros macroNames funcNames }
                    ifdef - ifndef {
                        set name ""
                        if {[string trim $rest] ne ""} { set name [lindex [split [string trim $rest]] 0] }
                        set defined [expr {[lsearch -exact $macroNames $name] >= 0 || [lsearch -exact $funcNames $name] >= 0}]
                        if {$kw eq "ifdef"} {
                            lappend ifdefStack [expr {[ppActive $ifdefStack] && $defined}]
                        } else {
                            lappend ifdefStack [expr {[ppActive $ifdefStack] && !$defined}]
                        }
                    }
                    if {
                        set val [string trim $rest]
                        lappend ifdefStack [expr {[ppActive $ifdefStack] && $val ne "0"}]
                    }
                    elif {
                        if {[llength $ifdefStack] > 0} {
                            set prev [lindex $ifdefStack end]
                            set ifdefStack [lrange $ifdefStack 0 end-1]
                            set val [string trim $rest]
                            lappend ifdefStack [expr {!$prev && $val ne "0"}]
                        }
                    }
                    else {
                        if {[llength $ifdefStack] > 0} {
                            lset ifdefStack end [expr {![lindex $ifdefStack end]}]
                        }
                    }
                    endif {
                        if {[llength $ifdefStack] > 0} { set ifdefStack [lrange $ifdefStack 0 end-1] }
                    }
                }
            }
            lappend outLines ""
        } else {
            if {[ppActive $ifdefStack]} {
                lappend outLines $line
            } else {
                lappend outLines ""
            }
        }
    }
    return [list [join $outLines "\n"] $macros]
}

proc pak::c2pak::ppActive {stack} {
    foreach v $stack { if {!$v} { return 0 } }
    return 1
}

proc pak::c2pak::ppDefine {rest macrosv mnv fnv} {
    upvar $macrosv macros $mnv macroNames $fnv funcNames
    if {$rest eq ""} return
    # function-like: NAME(params) body
    if {[regexp {^(\w+)\(([^)]*)\)\s*(.*)$} $rest -> name _params _body]} {
        lappend funcNames $name
        return
    }
    # simple: NAME value
    if {[regexp {^(\S+)\s*(.*)$} $rest -> name value]} {
        set value [string trim $value]
        if {$value eq ""} { set value "1" }
        lappend macros [list $name $value]
        lappend macroNames $name
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Lexer
# ─────────────────────────────────────────────────────────────────────────────

# Token = {type value}. types: id, num, fnum, char, str, punc, kw
namespace eval pak::c2pak {
    variable KEYWORDS {
        void char short int long float double signed unsigned _Bool
        struct union enum typedef static extern const volatile inline
        return if else while do for switch case default break continue goto sizeof
        register auto
    }
}

proc pak::c2pak::lex {src} {
    variable KEYWORDS
    set toks {}
    set n [string length $src]
    set i 0
    while {$i < $n} {
        set c [string index $src $i]
        # whitespace
        if {[string is space $c]} { incr i; continue }
        # identifier / keyword
        if {[string match {[A-Za-z_]} $c]} {
            set j $i
            while {$j < $n && [string match {[A-Za-z0-9_]} [string index $src $j]]} { incr j }
            set word [string range $src $i $j-1]
            if {[lsearch -exact $KEYWORDS $word] >= 0} {
                lappend toks [list kw $word]
            } else {
                lappend toks [list id $word]
            }
            set i $j
            continue
        }
        # number
        if {[string match {[0-9]} $c] || ($c eq "." && [string match {[0-9]} [string index $src [expr {$i+1}]]])} {
            set j $i
            set isfloat 0
            if {[string match {0[xX]} [string range $src $i $i+1]]} {
                set j [expr {$i+2}]
                while {$j < $n && [string match {[0-9a-fA-F]} [string index $src $j]]} { incr j }
            } else {
                while {$j < $n && [string match {[0-9]} [string index $src $j]]} { incr j }
                if {$j < $n && [string index $src $j] eq "."} {
                    set isfloat 1; incr j
                    while {$j < $n && [string match {[0-9]} [string index $src $j]]} { incr j }
                }
                if {$j < $n && [string match {[eE]} [string index $src $j]]} {
                    set isfloat 1; incr j
                    if {$j < $n && [string match {[+-]} [string index $src $j]]} { incr j }
                    while {$j < $n && [string match {[0-9]} [string index $src $j]]} { incr j }
                }
            }
            # suffixes
            while {$j < $n && [string match {[uUlLfF]} [string index $src $j]]} {
                if {[string match {[fF]} [string index $src $j]]} { set isfloat 1 }
                incr j
            }
            set val [string range $src $i $j-1]
            if {$isfloat} { lappend toks [list fnum $val] } else { lappend toks [list num $val] }
            set i $j
            continue
        }
        # char literal
        if {$c eq "'"} {
            set j [expr {$i+1}]
            while {$j < $n} {
                if {[string index $src $j] eq "\\"} { incr j 2; continue }
                if {[string index $src $j] eq "'"} { incr j; break }
                incr j
            }
            lappend toks [list char [string range $src $i $j-1]]
            set i $j
            continue
        }
        # string literal
        if {$c eq "\""} {
            set j [expr {$i+1}]
            while {$j < $n} {
                if {[string index $src $j] eq "\\"} { incr j 2; continue }
                if {[string index $src $j] eq "\""} { incr j; break }
                incr j
            }
            lappend toks [list str [string range $src $i $j-1]]
            set i $j
            continue
        }
        # punctuation: try multi-char
        set three [string range $src $i $i+2]
        set two [string range $src $i $i+1]
        if {$three in {<<= >>= ...}} {
            lappend toks [list punc $three]; incr i 3; continue
        }
        if {$two in {-> ++ -- << >> <= >= == != && || += -= *= /= %= &= |= ^=}} {
            lappend toks [list punc $two]; incr i 2; continue
        }
        lappend toks [list punc $c]
        incr i
    }
    lappend toks [list eof ""]
    return $toks
}

# ─────────────────────────────────────────────────────────────────────────────
# Parser
# ─────────────────────────────────────────────────────────────────────────────
#
# State: toks list, pos index, typedef name set, anon counter.

namespace eval pak::c2pak {
    variable P_toks {}
    variable P_pos 0
    variable P_typedefs {}   ;# set of typedef/tag names known
    variable P_anon 0
}

proc pak::c2pak::p_peek {{ahead 0}} {
    variable P_toks; variable P_pos
    return [lindex $P_toks [expr {$P_pos+$ahead}]]
}
proc pak::c2pak::p_type {{ahead 0}} { return [lindex [p_peek $ahead] 0] }
proc pak::c2pak::p_val {{ahead 0}} { return [lindex [p_peek $ahead] 1] }
proc pak::c2pak::p_next {} {
    variable P_toks; variable P_pos
    set t [lindex $P_toks $P_pos]; incr P_pos; return $t
}
proc pak::c2pak::p_expect {ptype {pval ""}} {
    set t [p_next]
    if {[lindex $t 0] ne $ptype || ($pval ne "" && [lindex $t 1] ne $pval)} {
        return -code error "C2PAKUNPORTED\tparse: expected $ptype $pval got $t"
    }
    return $t
}
proc pak::c2pak::p_is {ptype {pval ""}} {
    set t [p_peek]
    if {[lindex $t 0] ne $ptype} { return 0 }
    if {$pval ne "" && [lindex $t 1] ne $pval} { return 0 }
    return 1
}
proc pak::c2pak::nextAnon {} { variable P_anon; incr P_anon; return $P_anon }

proc pak::c2pak::isKnownType {name} {
    variable P_typedefs
    return [expr {[dict exists $P_typedefs $name]}]
}

# Is the upcoming token a type specifier start?
proc pak::c2pak::atTypeStart {} {
    set t [p_peek]
    set ty [lindex $t 0]; set v [lindex $t 1]
    if {$ty eq "kw"} {
        return [expr {$v in {void char short int long float double signed unsigned _Bool struct union enum const volatile static extern typedef inline register auto}}]
    }
    if {$ty eq "id"} { return [isKnownType $v] }
    return 0
}

# ── Parse a full translation unit ──
proc pak::c2pak::parse {toks macros} {
    variable P_toks; variable P_pos; variable P_typedefs; variable P_anon
    set P_toks $toks; set P_pos 0; set P_typedefs {}; set P_anon 0
    # prelude typedefs, seeding user-typedef resolution
    foreach n {s8 u8 s16 u16 s32 u32 s64 u64 f32 f64 int8_t uint8_t int16_t uint16_t
               int32_t uint32_t int64_t uint64_t size_t ptrdiff_t __builtin_va_list
               bool FILE surface_t wchar_t uintptr_t intptr_t} {
        dict set P_typedefs $n 1
    }
    set decls {}
    while {![p_is eof]} {
        set d [p_topdecl]
        foreach x $d { lappend decls $x }
    }
    return [dict create decls $decls macros $macros]
}

# Returns a list of decls (may be empty).
proc pak::c2pak::p_topdecl {} {
    # gather storage/qualifiers
    set storage {}
    while {[p_is kw]} {
        set v [p_val]
        if {$v in {static extern typedef const volatile inline register auto}} {
            lappend storage $v; p_next
        } else { break }
    }
    set isTypedef [expr {"typedef" in $storage}]
    set isStatic [expr {"static" in $storage}]
    set isExtern [expr {"extern" in $storage}]
    set isConst [expr {"const" in $storage}]

    # base type
    set base [p_basetype]
    # If just a tag declaration with semicolon: e.g. `struct Foo { };`
    if {[p_is punc ";"] && !$isTypedef} {
        p_next
        return [p_tagDeclFromBase $base {}]
    }

    set results {}
    # one or more declarators
    while {1} {
        lassign [p_declarator $base] name typ
        if {[p_is punc "("] } {
            # function: declarator already consumed name; now params
            # handled inside declarator? We handle function specially below.
        }
        # Check for function declarator: typ is funcsig marker
        if {[dict get $typ k] eq "funcsig"} {
            set sig [dict create name $name ret [dict get $typ ret] params [dict get $typ params] \
                         is_static $isStatic is_extern $isExtern is_variadic [dict get $typ variadic] \
                         is_inline [expr {"inline" in $storage}]]
            if {$isTypedef} {
                # typedef of function pointer handled elsewhere; treat as funcptr typedef
                dict set ::pak::c2pak::P_typedefs $name 1
                lappend results [dict create k typedef name $name typ \
                    [dict create k funcptr ret [dict get $typ ret] params [p_paramTypes [dict get $typ params]]]]
            } elseif {[p_is punc "\{"]} {
                set body [p_compound]
                lappend results [dict create k funcdef sig $sig body $body]
            } else {
                p_expect punc ";"
                lappend results [dict create k funcdecl sig $sig]
            }
            if {[p_is punc ";"]} { p_next }
            return $results
        }
        # variable / typedef
        if {$isTypedef} {
            dict set ::pak::c2pak::P_typedefs $name 1
            lappend results [dict create k typedef name $name typ $typ]
        } else {
            set init ""
            if {[p_is punc "="]} {
                p_next
                set init [p_initializer]
            }
            lappend results [dict create k var name $name typ $typ init $init \
                is_static $isStatic is_extern $isExtern is_const $isConst]
        }
        if {[p_is punc ","]} { p_next; continue }
        break
    }
    p_expect punc ";"
    # also emit standalone tag decls if base introduced a struct/enum/union with a name
    set tagdecls [p_maybeTagDecl $base $results $isTypedef]
    return [concat $tagdecls $results]
}

# When `typedef struct {..} Name;` we produce a single CTypeDef whose
# typ is the CStruct. We already store typ as the struct. No extra tag decl.
# When `struct Name {..} var;` produces both the struct decl... but corpus doesn't.
proc pak::c2pak::p_maybeTagDecl {base results isTypedef} {
    return {}
}

proc pak::c2pak::p_tagDeclFromBase {base storage} {
    set k [dict get $base k]
    if {$k eq "struct"} {
        if {[dict get $base fields] eq "FWD"} { return {} }
        return [list [dict create k structdecl name [dict get $base name] fields [dict get $base fields] attrs {}]]
    } elseif {$k eq "union"} {
        if {[dict get $base fields] eq "FWD"} { return {} }
        return [list [dict create k uniondecl name [dict get $base name] fields [dict get $base fields] attrs {}]]
    } elseif {$k eq "enum"} {
        if {[dict get $base values] eq "FWD"} { return {} }
        return [list [dict create k enumdecl name [dict get $base name] values [dict get $base values]]]
    }
    return {}
}

# Parse base type specifier into a CType dict.
proc pak::c2pak::p_basetype {} {
    set words {}
    # leading const/volatile
    while {[p_is kw const] || [p_is kw volatile]} { p_next }
    if {[p_is kw struct] || [p_is kw union] || [p_is kw enum]} {
        return [p_aggregate]
    }
    # primitive words and typedef names
    set isFirst 1
    while {1} {
        set t [p_peek]
        set ty [lindex $t 0]; set v [lindex $t 1]
        if {$ty eq "kw" && $v in {void char short int long float double signed unsigned _Bool}} {
            lappend words $v; p_next; set isFirst 0; continue
        }
        if {$ty eq "id" && $isFirst && [isKnownType $v]} {
            lappend words $v; p_next; set isFirst 0
            break
        }
        break
    }
    while {[p_is kw const] || [p_is kw volatile]} { p_next }
    set name [join $words " "]
    # decide typeref vs primitive
    if {[llength $words] == 1 && [isUserTypedefName $name]} {
        return [dict create k typeref name $name]
    }
    return [dict create k prim name $name]
}

# mirror c_parser._is_user_typedef
proc pak::c2pak::isUserTypedefName {name} {
    if {[string first " " $name] >= 0} { return 0 }
    set kws {void char short int long float double signed unsigned bool _Bool
             int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t
             s8 s16 s32 s64 u8 u16 u32 u64 f32 f64 size_t ptrdiff_t}
    if {$name in $kws} { return 0 }
    if {[isKnownType $name]} { return 1 }
    set c0 [string index $name 0]
    if {[string is upper $c0] || [string match "__*" $name]} { return 1 }
    return 0
}

proc pak::c2pak::p_aggregate {} {
    set kind [p_val]; p_next  ;# struct/union/enum
    set name ""
    if {[p_is id]} { set name [p_val]; p_next }
    if {$kind eq "enum"} {
        if {[p_is punc "\{"]} {
            set values [p_enumBody]
            return [dict create k enum name $name values $values]
        } else {
            # by-name / forward reference → CTypeRef
            if {$name eq ""} { set name "_AnonEnum[nextAnon]" }
            return [dict create k typeref name $name]
        }
    } else {
        if {[p_is punc "\{"]} {
            set fields [p_structBody]
            return [dict create k $kind name $name fields $fields]
        } else {
            # by-name / forward reference → CTypeRef
            if {$name eq ""} { set name "_Anon[nextAnon]" }
            return [dict create k typeref name $name]
        }
    }
}

proc pak::c2pak::p_enumBody {} {
    p_expect punc "\{"
    set values {}
    set next 0
    while {![p_is punc "\}"]} {
        set ename [p_val]; p_next
        set v ""
        if {[p_is punc "="]} {
            p_next
            set v [p_evalConstInt]
            set next [expr {$v+1}]
        } else {
            set next [expr {$next+1}]
        }
        lappend values [list $ename $v]
        if {[p_is punc ","]} { p_next }
    }
    p_expect punc "\}"
    return $values
}

# evaluate a constant integer expression for enum values / array dims
proc pak::c2pak::p_evalConstInt {} {
    # parse a simple expression and evaluate
    set e [p_assignExpr]
    return [evalConstInt $e]
}
proc pak::c2pak::evalConstInt {e} {
    set k [dict get $e k]
    switch -- $k {
        const {
            set v [dict get $e value]
            return [parseIntLit $v]
        }
        unary {
            if {[dict get $e op] eq "-"} { return [expr {-[evalConstInt [dict get $e expr]]}] }
        }
        binop {
            set l [evalConstInt [dict get $e left]]
            set r [evalConstInt [dict get $e right]]
            set op [dict get $e op]
            return [expr "$l $op $r"]
        }
    }
    return 0
}
proc pak::c2pak::parseIntLit {v} {
    set v [string trimright $v "uUlL"]
    if {[string match "0\[xX\]*" $v]} { return [expr {[scan $v %x]}] }
    return [expr {$v + 0}]
}

proc pak::c2pak::p_structBody {} {
    p_expect punc "\{"
    set fields {}
    while {![p_is punc "\}"]} {
        # member declaration
        set base [p_basetype]
        # anonymous struct/union member with no declarator e.g. `union { ... };`
        if {[p_is punc ";"]} {
            p_next
            set fname "_f[nextAnon]"
            lappend fields [dict create name $fname typ $base bitsize ""]
            continue
        }
        while {1} {
            lassign [p_declarator $base] name typ
            set bitsize ""
            if {[p_is punc ":"]} {
                p_next
                set bitsize [p_evalConstInt]
            }
            if {$name eq ""} { set name "_f[nextAnon]" }
            lappend fields [dict create name $name typ $typ bitsize $bitsize]
            if {[p_is punc ","]} { p_next; continue }
            break
        }
        p_expect punc ";"
    }
    p_expect punc "\}"
    return $fields
}

# Parse a declarator given a base type. Returns {name type}.
# Handles pointers, the identifier, arrays, function params.
proc pak::c2pak::p_declarator {base} {
    set typ $base
    # leading pointers
    while {[p_is punc "*"]} {
        p_next
        set isConst 0; set isVol 0
        while {[p_is kw const] || [p_is kw volatile]} {
            if {[p_is kw const]} { set isConst 1 }
            if {[p_is kw volatile]} { set isVol 1 }
            p_next
        }
        set typ [dict create k ptr inner $typ const $isConst vol $isVol]
    }
    # name (optional)
    set name ""
    if {[p_is id]} { set name [p_val]; p_next }

    # suffixes: arrays / function params
    set typ [p_declSuffix $typ]
    return [list $name $typ]
}

proc pak::c2pak::p_declSuffix {typ} {
    while {1} {
        if {[p_is punc "\["]} {
            p_next
            set size ""
            if {![p_is punc "\]"]} {
                set size [p_evalConstInt]
            }
            p_expect punc "\]"
            set typ [dict create k array inner $typ size $size]
        } elseif {[p_is punc "("]} {
            # function declarator
            p_next
            set params {}
            set variadic 0
            if {![p_is punc ")"]} {
                while {1} {
                    if {[p_is punc "..."]} { p_next; set variadic 1; break }
                    set pbase [p_basetype]
                    lassign [p_declarator $pbase] pname ptyp
                    lappend params [dict create name $pname typ $ptyp]
                    if {[p_is punc ","]} { p_next; continue }
                    break
                }
            }
            p_expect punc ")"
            set typ [dict create k funcsig ret $typ params $params variadic $variadic]
        } else {
            break
        }
    }
    return $typ
}

proc pak::c2pak::p_paramTypes {params} {
    set out {}
    foreach p $params { lappend out [dict get $p typ] }
    return $out
}

# ── Initializers ──
proc pak::c2pak::p_initializer {} {
    if {[p_is punc "\{"]} {
        return [p_initList]
    }
    return [p_assignExpr]
}
proc pak::c2pak::p_initList {} {
    p_expect punc "\{"
    set items {}
    while {![p_is punc "\}"]} {
        if {[p_is punc "."]} {
            p_next
            set fname [p_val]; p_next
            p_expect punc "="
            set val [p_initializer]
            lappend items [list named $fname $val]
        } else {
            lappend items [list pos [p_initializer]]
        }
        if {[p_is punc ","]} { p_next; continue }
        break
    }
    p_expect punc "\}"
    return [dict create k initlist items $items]
}

# ─────────────────────────────────────────────────────────────────────────────
# Expression parser (precedence climbing) → CExpr dicts
# ─────────────────────────────────────────────────────────────────────────────

proc pak::c2pak::p_assignExpr {} {
    set left [p_ternary]
    set t [p_peek]
    if {[lindex $t 0] eq "punc"} {
        set op [lindex $t 1]
        if {$op in {= += -= *= /= %= &= |= ^= <<= >>=}} {
            p_next
            set right [p_assignExpr]
            return [dict create k assign op $op target $left value $right]
        }
    }
    return $left
}

proc pak::c2pak::p_expr {} {
    # comma expression
    set e [p_assignExpr]
    if {[p_is punc ","]} {
        set exprs [list $e]
        while {[p_is punc ","]} {
            p_next
            lappend exprs [p_assignExpr]
        }
        return [dict create k comma exprs $exprs]
    }
    return $e
}

proc pak::c2pak::p_ternary {} {
    set cond [p_binary 0]
    if {[p_is punc "?"]} {
        p_next
        set then [p_assignExpr]
        p_expect punc ":"
        set other [p_assignExpr]
        return [dict create k ternary cond $cond then $then otherwise $other]
    }
    return $cond
}

# binary operator precedence table
namespace eval pak::c2pak {
    variable BINPREC
    array set BINPREC {
        || 1 && 2 | 3 ^ 4 & 5 == 6 != 6 < 7 > 7 <= 7 >= 7 << 8 >> 8 + 9 - 9 * 10 / 10 % 10
    }
}

proc pak::c2pak::p_binary {minprec} {
    variable BINPREC
    set left [p_unary]
    while {1} {
        set t [p_peek]
        if {[lindex $t 0] ne "punc"} break
        set op [lindex $t 1]
        if {![info exists BINPREC($op)]} break
        set prec $BINPREC($op)
        if {$prec < $minprec} break
        p_next
        set right [p_binary [expr {$prec+1}]]
        set left [dict create k binop op $op left $left right $right]
    }
    return $left
}

proc pak::c2pak::p_unary {} {
    set t [p_peek]
    set ty [lindex $t 0]; set v [lindex $t 1]
    if {$ty eq "punc" && $v in {- + ! ~ * &}} {
        p_next
        set e [p_unary]
        return [dict create k unary op $v expr $e postfix 0]
    }
    if {$ty eq "punc" && $v in {++ --}} {
        p_next
        set e [p_unary]
        return [dict create k unary op $v expr $e postfix 0]
    }
    if {$ty eq "kw" && $v eq "sizeof"} {
        p_next
        if {[p_is punc "("] && [p_isTypeAhead]} {
            p_next
            set tt [p_typeName]
            p_expect punc ")"
            return [dict create k sizeof target $tt istype 1]
        } else {
            set e [p_unary]
            return [dict create k sizeof target $e istype 0]
        }
    }
    # cast: ( type ) unary
    if {$ty eq "punc" && $v eq "(" && [p_isTypeAhead]} {
        p_next
        set tt [p_typeName]
        p_expect punc ")"
        set e [p_unary]
        return [dict create k cast typ $tt expr $e]
    }
    return [p_postfix]
}

# Is the token after '(' a type? (for cast/sizeof detection)
proc pak::c2pak::p_isTypeAhead {} {
    set t [p_peek 1]
    set ty [lindex $t 0]; set v [lindex $t 1]
    if {$ty eq "kw"} {
        return [expr {$v in {void char short int long float double signed unsigned _Bool struct union enum const volatile}}]
    }
    if {$ty eq "id"} { return [isKnownType $v] }
    return 0
}

# Parse a type-name (abstract declarator) inside cast/sizeof.
proc pak::c2pak::p_typeName {} {
    set base [p_basetype]
    # abstract pointers
    while {[p_is punc "*"]} {
        p_next
        set isConst 0; set isVol 0
        while {[p_is kw const] || [p_is kw volatile]} {
            if {[p_is kw const]} { set isConst 1 }
            p_next
        }
        set base [dict create k ptr inner $base const $isConst vol $isVol]
    }
    # abstract arrays
    while {[p_is punc "\["]} {
        p_next
        set size ""
        if {![p_is punc "\]"]} { set size [p_evalConstInt] }
        p_expect punc "\]"
        set base [dict create k array inner $base size $size]
    }
    return $base
}

proc pak::c2pak::p_postfix {} {
    set e [p_primary]
    while {1} {
        set t [p_peek]
        set ty [lindex $t 0]; set v [lindex $t 1]
        if {$ty eq "punc" && $v eq "("} {
            p_next
            set args {}
            if {![p_is punc ")"]} {
                while {1} {
                    lappend args [p_assignExpr]
                    if {[p_is punc ","]} { p_next; continue }
                    break
                }
            }
            p_expect punc ")"
            set e [dict create k call func $e args $args]
        } elseif {$ty eq "punc" && $v eq "\["} {
            p_next
            set idx [p_expr]
            p_expect punc "\]"
            set e [dict create k arrayref base $e index $idx]
        } elseif {$ty eq "punc" && $v eq "."} {
            p_next
            set m [p_val]; p_next
            set e [dict create k structref base $e member $m arrow 0]
        } elseif {$ty eq "punc" && $v eq "->"} {
            p_next
            set m [p_val]; p_next
            set e [dict create k structref base $e member $m arrow 1]
        } elseif {$ty eq "punc" && $v in {++ --}} {
            p_next
            set e [dict create k unary op $v expr $e postfix 1]
        } else break
    }
    return $e
}

proc pak::c2pak::p_primary {} {
    set t [p_peek]
    set ty [lindex $t 0]; set v [lindex $t 1]
    if {$ty eq "num"} { p_next; return [dict create k const value $v kind int] }
    if {$ty eq "fnum"} { p_next; return [dict create k const value $v kind float] }
    if {$ty eq "char"} { p_next; return [dict create k const value $v kind char] }
    if {$ty eq "str"} { p_next; return [dict create k const value $v kind string] }
    if {$ty eq "id"} { p_next; return [dict create k id name $v] }
    if {$ty eq "punc" && $v eq "("} {
        p_next
        set e [p_expr]
        p_expect punc ")"
        return $e
    }
    return -code error "C2PAKUNPORTED\tprimary: unexpected token $t"
}

# ─────────────────────────────────────────────────────────────────────────────
# Statement parser
# ─────────────────────────────────────────────────────────────────────────────

proc pak::c2pak::p_compound {} {
    p_expect punc "\{"
    set items {}
    while {![p_is punc "\}"]} {
        set st [p_blockItem]
        foreach s $st { lappend items $s }
    }
    p_expect punc "\}"
    return [dict create k compound items $items]
}

# Returns list of items (decls may produce several).
proc pak::c2pak::p_blockItem {} {
    if {[atTypeStart]} {
        return [p_localDecl]
    }
    return [list [p_statement]]
}

proc pak::c2pak::p_localDecl {} {
    set storage {}
    while {[p_is kw]} {
        set v [p_val]
        if {$v in {static extern const volatile register auto}} { lappend storage $v; p_next } else break
    }
    set isStatic [expr {"static" in $storage}]
    set isConst [expr {"const" in $storage}]
    set base [p_basetype]
    set results {}
    while {1} {
        lassign [p_declarator $base] name typ
        set init ""
        if {[p_is punc "="]} { p_next; set init [p_initializer] }
        lappend results [dict create k var name $name typ $typ init $init \
            is_static $isStatic is_const $isConst is_extern 0]
        if {[p_is punc ","]} { p_next; continue }
        break
    }
    p_expect punc ";"
    return $results
}

proc pak::c2pak::p_statement {} {
    set t [p_peek]
    set ty [lindex $t 0]; set v [lindex $t 1]
    if {$ty eq "punc" && $v eq "\{"} { return [p_compound] }
    if {$ty eq "punc" && $v eq ";"} { p_next; return [dict create k empty] }
    if {$ty eq "kw"} {
        switch -- $v {
            if      { return [p_if] }
            while   { return [p_while] }
            do      { return [p_dowhile] }
            for     { return [p_for] }
            switch  { return [p_switch] }
            return  {
                p_next
                set val ""
                if {![p_is punc ";"]} { set val [p_expr] }
                p_expect punc ";"
                return [dict create k return value $val]
            }
            break    { p_next; p_expect punc ";"; return [dict create k break] }
            continue { p_next; p_expect punc ";"; return [dict create k continue] }
            goto     { p_next; set lbl [p_val]; p_next; p_expect punc ";"; return [dict create k goto label $lbl] }
        }
    }
    # label: identifier ':'
    if {$ty eq "id" && [lindex [p_peek 1] 0] eq "punc" && [lindex [p_peek 1] 1] eq ":"} {
        set lbl $v; p_next; p_next
        # label may be followed by a statement; in our block model we emit label then
        # subsequent statements are separate block items, with stmt attached.
        # pycparser: Label has a stmt. We attach the following statement.
        if {[p_is punc "\}"]} {
            return [dict create k label name $lbl stmt ""]
        }
        set st [p_statement]
        return [dict create k label name $lbl stmt $st]
    }
    # expression statement
    set e [p_expr]
    p_expect punc ";"
    return [dict create k exprstmt expr $e]
}

proc pak::c2pak::p_if {} {
    p_next; p_expect punc "("
    set cond [p_expr]
    p_expect punc ")"
    set then [p_statement]
    set other ""
    if {[p_is kw else]} {
        p_next
        set other [p_statement]
    }
    return [dict create k if cond $cond then $then otherwise $other]
}

proc pak::c2pak::p_while {} {
    p_next; p_expect punc "("
    set cond [p_expr]
    p_expect punc ")"
    set body [p_statement]
    return [dict create k while cond $cond body $body]
}

proc pak::c2pak::p_dowhile {} {
    p_next
    set body [p_statement]
    p_expect kw while
    p_expect punc "("
    set cond [p_expr]
    p_expect punc ")"
    p_expect punc ";"
    return [dict create k dowhile cond $cond body $body]
}

proc pak::c2pak::p_for {} {
    p_next; p_expect punc "("
    set init ""
    if {[p_is punc ";"]} {
        p_next
    } elseif {[atTypeStart]} {
        set init [p_localDecl]  ;# list of var decls, consumes ';'
    } else {
        set e [p_expr]
        p_expect punc ";"
        set init [dict create k exprstmt expr $e]
    }
    set cond ""
    if {![p_is punc ";"]} { set cond [p_expr] }
    p_expect punc ";"
    set step ""
    if {![p_is punc ")"]} { set step [p_expr] }
    p_expect punc ")"
    set body [p_statement]
    return [dict create k for init $init cond $cond step $step body $body]
}

proc pak::c2pak::p_switch {} {
    p_next; p_expect punc "("
    set cond [p_expr]
    p_expect punc ")"
    p_expect punc "\{"
    set cases {}
    set cur ""
    while {![p_is punc "\}"]} {
        if {[p_is kw case]} {
            p_next
            set val [p_assignExpr]
            p_expect punc ":"
            set cur [dict create k case value $val stmts {} has_break 0]
            lappend cases $cur
            set curIdx [expr {[llength $cases]-1}]
        } elseif {[p_is kw default]} {
            p_next
            p_expect punc ":"
            set cur [dict create k case value "" stmts {} has_break 0]
            lappend cases $cur
            set curIdx [expr {[llength $cases]-1}]
        } else {
            # statement belonging to current case
            if {[p_is kw break]} {
                p_next; p_expect punc ";"
                if {$cur ne ""} {
                    set c [lindex $cases $curIdx]
                    dict set c has_break 1
                    lset cases $curIdx $c
                }
            } else {
                set stmts [p_blockItem]
                if {$cur ne ""} {
                    set c [lindex $cases $curIdx]
                    set sl [dict get $c stmts]
                    foreach s $stmts { lappend sl $s }
                    dict set c stmts $sl
                    lset cases $curIdx $c
                }
            }
        }
    }
    p_expect punc "\}"
    return [dict create k switch cond $cond cases $cases]
}

# Continue in next file section (sourced helpers for mappers).
source [file join [file dirname [info script]] c2pak c2pak_emit.tcl]

# ─────────────────────────────────────────────────────────────────────────────
# Public entry
# ─────────────────────────────────────────────────────────────────────────────
proc pak::c2pak_transpile {source filename} {
    lassign [pak::c2pak::preprocess $source] cleaned macros
    set toks [pak::c2pak::lex $cleaned]
    set cfile [pak::c2pak::parse $toks $macros]
    return [pak::c2pak::emit $cfile]
}
