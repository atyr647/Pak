# tcl/typechecker.tcl — semantic analysis + type checker, Tcl port of
# pak/typechecker.py.
#
# Two passes over the AST:
#   1. pak::TypeEnv collects top-level declarations.
#   2. pak::TypeChecker walks bodies, emitting E0xx/E2xx/E3xx/E4xx/E5xx/E6xx
#      errors and W00x/W201 warnings — identical codes/messages to the Python
#      oracle, in the same accumulation order (a single list, not split by
#      severity). No message embeds a source line, so — unlike the checker's
#      E107 — nothing here needs position normalization in the parity harness.
#
# Concision idioms match parser/checker: pak::kindof dispatch, pak::nfield /
# pak::fval reads, pak::items for seq fields.

set _tchere [file dirname [file normalize [info script]]]
source [file join $_tchere ast.tcl]
source [file join $_tchere ast_visit.tcl]
source [file join $_tchere tc_tables.tcl]

namespace eval pak {}

# Include guard (reachable via multiple consumers; see ast.tcl).
if {[info exists ::pak::_typechecker_loaded]} { return }
set ::pak::_typechecker_loaded 1

# ── naming-convention helpers ──────────────────────────────────────────────────
proc pak::is_pascal {s} { return [regexp {^[A-Z][a-zA-Z0-9]*$} $s] }
proc pak::is_snake  {s} { return [regexp {^[a-z_][a-z0-9_]*$} $s] }
proc pak::is_upper  {s} { return [regexp {^[A-Z][A-Z0-9_]*$} $s] }

proc pak::to_snake {name} {
    regsub -all {([A-Z]+)([A-Z][a-z])} $name {\1_\2} s
    regsub -all {([a-z\d])([A-Z])} $s {\1_\2} s
    return [string tolower $s]
}
proc pak::to_pascal {name} {
    set name [string map {- _} $name]
    set out ""
    foreach p [split $name _] {
        if {$p eq ""} continue
        append out [string toupper [string index $p 0]][string tolower [string range $p 1 end]]
    }
    return $out
}
proc pak::to_upper_snake {name} { return [string toupper [pak::to_snake $name]] }

# ── annotation helpers ─────────────────────────────────────────────────────────
# Annotation strings on a node, or {} if the node has no annotations field
# (mirrors Python's getattr(node, 'annotations', []) — Param has none).
proc pak::annlist {node} {
    set k [pak::kindof $node]
    if {$k eq "" || [lsearch -exact [dict get $::pak::SCHEMA $k] annotations] < 0} {
        return {}
    }
    set out {}
    foreach a [pak::items [pak::nfield $node annotations]] { lappend out [pak::sval $a] }
    return $out
}
proc pak::has_annotation {node ann} { return [expr {$ann in [pak::annlist $node]}] }

# ── type-to-string (used in E012 hints) ────────────────────────────────────────
proc pak::type_str {typ} {
    switch -- [pak::kindof $typ] {
        TypeName    { return [pak::fval $typ name] }
        TypePointer {
            set prefix [expr {[pak::fval $typ nullable] ? "?*" : "*"}]
            return "$prefix[pak::type_str [pak::nfield $typ inner]]"
        }
        TypeSlice   { return "\[\][pak::type_str [pak::nfield $typ inner]]" }
        TypeArray   { return "\[N\][pak::type_str [pak::nfield $typ inner]]" }
        default     { return "?" }
    }
}

# ── pass 1: declaration environment ────────────────────────────────────────────
oo::class create pak::TypeEnv {
    variable structs enums variants fns traits trait_impls enum_cases variant_cases

    constructor {} {
        set structs [dict create]
        set enums [dict create]
        set variants [dict create]
        set fns [dict create]
        set traits [dict create]
        set trait_impls [dict create]
        set enum_cases [dict create]
        set variant_cases [dict create]
    }

    method collect {decls} { foreach d $decls { my collect_one $d } }

    method collect_one {decl} {
        switch -- [pak::kindof $decl] {
            StructDecl - UnionDecl { dict set structs [pak::fval $decl name] $decl }
            EnumDecl {
                dict set enums [pak::fval $decl name] $decl
                foreach v [pak::items [pak::nfield $decl variants]] {
                    dict set enum_cases [pak::fval $v name] [pak::fval $decl name]
                }
            }
            VariantDecl {
                dict set variants [pak::fval $decl name] $decl
                foreach c [pak::items [pak::nfield $decl cases]] {
                    dict set variant_cases [pak::fval $c name] [pak::fval $decl name]
                }
            }
            FnDecl { dict set fns [pak::fval $decl name] $decl }
            ImplBlock {
                set tn [pak::fval $decl type_name]
                foreach m [pak::items [pak::nfield $decl methods]] {
                    dict set fns "${tn}_[pak::fval $m name]" $m
                }
            }
            ImplTraitBlock {
                set tn [pak::fval $decl type_name]
                dict set trait_impls [list $tn [pak::fval $decl trait_name]] $decl
                foreach m [pak::items [pak::nfield $decl methods]] {
                    dict set fns "${tn}_[pak::fval $m name]" $m
                }
            }
            TraitDecl { dict set traits [pak::fval $decl name] $decl }
            CfgBlock { my collect_one [pak::nfield $decl decl] }
        }
    }

    # accessors
    method has_struct {name}  { return [dict exists $structs $name] }
    method get_struct {name}  { return [dict get $structs $name] }
    method has_enum {name}    { return [dict exists $enums $name] }
    method has_variant {name} { return [dict exists $variants $name] }
    method has_trait {name}   { return [dict exists $traits $name] }
    method has_fn {name}      { return [dict exists $fns $name] }
    method get_fn {name}      { return [dict get $fns $name] }
    method get_trait {name}   { return [dict get $traits $name] }
    method enum_case_of {name} {
        if {[dict exists $enum_cases $name]} { return [dict get $enum_cases $name] }
        return ""
    }

    # {fname -> ftypeTV} ordered dict for a struct, or "" if unknown.
    method struct_fields {name} {
        if {![dict exists $structs $name]} { return "" }
        set s [dict get $structs $name]
        set out [dict create]
        foreach f [pak::items [pak::nfield $s fields]] {
            dict set out [pak::fval $f name] [pak::nfield $f type]
        }
        return $out
    }

    # list of Param nodes for a fn, or "" if unknown.
    method fn_params {name} {
        if {![dict exists $fns $name]} { return "" }
        return [pak::items [pak::nfield [dict get $fns $name] params]]
    }

    # variadic flag for a known fn (0 if unknown).
    method fn_variadic {name} {
        if {![dict exists $fns $name]} { return 0 }
        return [pak::fval [dict get $fns $name] variadic]
    }

    # full case-name list for an enum or variant, or "" if neither.
    method all_cases {type_name} {
        if {[dict exists $enums $type_name]} {
            set out {}
            foreach v [pak::items [pak::nfield [dict get $enums $type_name] variants]] {
                lappend out [pak::fval $v name]
            }
            return $out
        }
        if {[dict exists $variants $type_name]} {
            set out {}
            foreach c [pak::items [pak::nfield [dict get $variants $type_name] cases]] {
                lappend out [pak::fval $c name]
            }
            return $out
        }
        return ""
    }
}

# ── lexical scope stack with move tracking ─────────────────────────────────────
oo::class create pak::Scope {
    variable stack moved

    constructor {} {
        set stack [list [dict create]]
        set moved [dict create]
    }
    method push {} { lappend stack [dict create] }
    method pop {} {
        foreach n [dict keys [lindex $stack end]] { dict unset moved $n }
        set stack [lrange $stack 0 end-1]
    }
    method declare {name typ} {
        set frame [lindex $stack end]
        dict set frame $name $typ
        lset stack end $frame
        dict unset moved $name
    }
    # returns the stored type tagged-value, or "" if the name is not in scope.
    method lookup {name} {
        for {set i [expr {[llength $stack] - 1}]} {$i >= 0} {incr i -1} {
            set frame [lindex $stack $i]
            if {[dict exists $frame $name]} { return [dict get $frame $name] }
        }
        return ""
    }
    method mark_moved {name} { dict set moved $name 1 }
    method is_moved {name}   { return [dict exists $moved $name] }
    method is_declared {name} { return [expr {[my lookup $name] ne ""}] }
}

# ── pass 2: the type checker ───────────────────────────────────────────────────
oo::class create pak::TypeChecker {
    variable env filename no_style errors scope current_fn aligned_vars cache_written

    constructor {env_ {fname ""} {nostyle 0}} {
        set env $env_
        set filename $fname
        set no_style $nostyle
        set errors {}
        set scope [pak::Scope new]
        set current_fn ""
        set aligned_vars [dict create]
        set cache_written [dict create]
    }
    destructor { $scope destroy }

    method err {code msg node {hint ""}} {
        lappend errors [dict create code $code message $msg hint $hint \
            line 0 col 0 filename $filename severity error]
    }
    method warn {code msg node {hint ""}} {
        if {$no_style} return
        lappend errors [dict create code $code message $msg hint $hint \
            line 0 col 0 filename $filename severity warning]
    }

    method check {decls} {
        foreach decl $decls {
            my check_naming $decl
            my check_top $decl
        }
        return $errors
    }

    # ── naming conventions (W001–W003) ────────────────────────────────────────
    method check_naming {decl} {
        switch -- [pak::kindof $decl] {
            StructDecl - EnumDecl - VariantDecl {
                set name [pak::fval $decl name]
                if {![pak::is_pascal $name]} {
                    my warn W001 "type '$name' should be PascalCase" $decl \
                        "Rename to '[pak::to_pascal $name]'"
                }
            }
            FnDecl {
                set name [pak::fval $decl name]
                if {$name ne "main" && ![pak::is_snake $name]} {
                    my warn W002 "function '$name' should be snake_case" $decl \
                        "Rename to '[pak::to_snake $name]'"
                }
            }
            ConstDecl {
                set name [pak::fval $decl name]
                if {![pak::is_upper $name]} {
                    my warn W003 "constant '$name' should be UPPER_SNAKE_CASE" $decl \
                        "Rename to '[pak::to_upper_snake $name]'"
                }
            }
            StaticDecl {
                set name [pak::fval $decl name]
                if {![pak::is_snake $name]} {
                    my warn W002 "static variable '$name' should be snake_case" $decl \
                        "Rename to '[pak::to_snake $name]'"
                }
            }
            LetDecl {
                set name [pak::fval $decl name]
                if {$name ne "_" && ![pak::is_snake $name]} {
                    my warn W002 "variable '$name' should be snake_case" $decl \
                        "Rename to '[pak::to_snake $name]'"
                }
            }
            ImplBlock {
                foreach m [pak::items [pak::nfield $decl methods]] { my check_naming $m }
            }
        }
    }

    method check_top {decl} {
        switch -- [pak::kindof $decl] {
            FnDecl     { my check_fn $decl }
            EntryBlock { my check_block [pak::nfield $decl body] }
            StaticDecl { my check_static $decl }
            LetDecl    { my check_let $decl }
            ImplBlock {
                foreach m [pak::items [pak::nfield $decl methods]] { my check_fn $m }
            }
            ImplTraitBlock {
                set trait_name [pak::fval $decl trait_name]
                if {[$env has_trait $trait_name]} {
                    set tnames [dict create]
                    foreach tm [pak::items [pak::nfield [$env get_trait $trait_name] methods]] {
                        dict set tnames [pak::fval $tm name] 1
                    }
                    foreach m [pak::items [pak::nfield $decl methods]] {
                        set mn [pak::fval $m name]
                        if {![dict exists $tnames $mn]} {
                            my err E601 "method '$mn' is not declared in trait '$trait_name'" $m \
                                "Remove this method or add it to trait '$trait_name'"
                        }
                    }
                    # A trait method must be implemented here or have a default
                    # body in the trait. Flag any required (body-less) method
                    # the impl omits.
                    set impl_names [dict create]
                    foreach m [pak::items [pak::nfield $decl methods]] {
                        dict set impl_names [pak::fval $m name] 1
                    }
                    set tyname [pak::fval $decl type_name]
                    foreach tm [pak::items [pak::nfield [$env get_trait $trait_name] methods]] {
                        set tmn [pak::fval $tm name]
                        if {![dict exists $impl_names $tmn] && [pak::isnil [pak::nfield $tm body]]} {
                            my err E602 "impl of trait '$trait_name' for '$tyname' is missing method '$tmn'" $decl \
                                "Implement '$tmn', or give it a default body in trait '$trait_name'"
                        }
                    }
                }
                foreach m [pak::items [pak::nfield $decl methods]] { my check_fn $m }
            }
            TraitDecl - UnionDecl {}
            CfgBlock {
                set inner [pak::nfield $decl decl]
                my check_naming $inner
                my check_top $inner
            }
            ConstDecl {
                set v [pak::nfield $decl value]
                if {![pak::isnil $v]} { my check_expr $v }
                set t [pak::nfield $decl type]
                if {[pak::isnil $t]} { set t [pak::N TypeName name auto] }
                $scope declare [pak::fval $decl name] $t
            }
            ExternConst { $scope declare [pak::fval $decl name] [pak::nfield $decl type] }
            AssetDecl   { $scope declare [pak::fval $decl name] [pak::N TypeName name auto] }
        }
    }

    method check_fn {fn} {
        if {[pak::isnil [pak::nfield $fn body]]} return
        set old $current_fn
        set current_fn $fn
        $scope push
        foreach p [pak::items [pak::nfield $fn params]] {
            $scope declare [pak::fval $p name] [pak::nfield $p type]
            if {[pak::has_annotation $p "@dma_safe"] || [pak::has_annotation $p "@aligned(16)"]} {
                dict set aligned_vars [pak::fval $p name] 1
            }
        }
        set body [pak::nfield $fn body]
        my check_block_stmts [pak::items [pak::nfield $body stmts]]
        $scope pop
        if {"@no_alloc" in [pak::annlist $fn]} { my check_no_alloc_body $body $fn }
        my check_fn_returns $fn
        set current_fn $old
    }

    method check_fn_returns {fn} {
        set ret [pak::nfield $fn ret_type]
        if {[pak::isnil $ret]} return
        if {[pak::kindof $ret] eq "TypeName" && [pak::fval $ret name] in {void never}} return
        set name [pak::fval $fn name]
        set body [pak::nfield $fn body]
        if {[pak::isnil $body] || [llength [pak::items [pak::nfield $body stmts]]] == 0} {
            my warn W201 "non-void function '$name' has no return statement" $fn \
                "Add a return statement or change the return type to void"
            return
        }
        if {![my block_has_return $body]} {
            my warn W201 "non-void function '$name' may not return a value on all paths" $fn \
                "Ensure all code paths return a value"
        }
    }

    method block_has_return {block} {
        if {[pak::isnil $block]} { return 0 }
        set stmts [pak::items [pak::nfield $block stmts]]
        if {[llength $stmts] == 0} { return 0 }
        set last [lindex $stmts end]
        switch -- [pak::kindof $last] {
            Return { return 1 }
            IfStmt {
                set eb [pak::nfield $last else_branch]
                if {![pak::isnil $eb] && [my block_has_return [pak::nfield $last then]] \
                        && [my block_has_return $eb]} { return 1 }
            }
            LoopStmt { return 1 }
        }
        return 0
    }

    # ── @no_alloc body walk (E501) ────────────────────────────────────────────
    method check_no_alloc_body {block fn} {
        foreach stmt [pak::items [pak::nfield $block stmts]] { my no_alloc_stmt $stmt $fn }
    }
    method no_alloc_stmt {stmt fn} {
        switch -- [pak::kindof $stmt] {
            ExprStmt { my no_alloc_expr [pak::nfield $stmt expr] $fn }
            LetDecl {
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my no_alloc_expr $v $fn }
            }
            Return {
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my no_alloc_expr $v $fn }
            }
            IfStmt {
                foreach st [pak::items [pak::nfield [pak::nfield $stmt then] stmts]] { my no_alloc_stmt $st $fn }
                foreach pair [pak::items [pak::nfield $stmt elif_branches]] {
                    set eb [lindex [pak::items $pair] 1]
                    foreach st [pak::items [pak::nfield $eb stmts]] { my no_alloc_stmt $st $fn }
                }
                set eb [pak::nfield $stmt else_branch]
                if {![pak::isnil $eb]} {
                    foreach st [pak::items [pak::nfield $eb stmts]] { my no_alloc_stmt $st $fn }
                }
            }
            WhileStmt - LoopStmt - ForStmt {
                foreach st [pak::items [pak::nfield [pak::nfield $stmt body] stmts]] { my no_alloc_stmt $st $fn }
            }
        }
    }
    method no_alloc_expr {expr fn} {
        switch -- [pak::kindof $expr] {
            Call {
                set func [pak::nfield $expr func]
                if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
                    set mod [pak::fval [pak::nfield $func obj] name]
                    set f [pak::fval $func field]
                    if {[dict exists $::pak::ALLOC_CALLS [list $mod $f]]} {
                        my err E501 "'[pak::fval $fn name]' is marked @no_alloc but calls '$mod.$f' which allocates heap memory" $expr \
                            "Remove the allocation or remove the @no_alloc annotation"
                    }
                }
                foreach a [pak::items [pak::nfield $expr args]] { my no_alloc_expr $a $fn }
            }
            BinaryOp {
                my no_alloc_expr [pak::nfield $expr left] $fn
                my no_alloc_expr [pak::nfield $expr right] $fn
            }
        }
    }

    # ── blocks / statements ───────────────────────────────────────────────────
    method check_block {block} {
        $scope push
        my check_block_stmts [pak::items [pak::nfield $block stmts]]
        $scope pop
    }
    method check_block_stmts {stmts} { foreach stmt $stmts { my check_stmt $stmt } }

    method check_stmt {stmt} {
        switch -- [pak::kindof $stmt] {
            LetDecl    { my check_let $stmt }
            StaticDecl { my check_static $stmt }
            ExprStmt {
                my check_expr [pak::nfield $stmt expr]
                my check_dma_call [pak::nfield $stmt expr]
            }
            Return {
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my check_expr $v }
            }
            IfStmt {
                my check_expr [pak::nfield $stmt condition]
                my check_block [pak::nfield $stmt then]
                foreach pair [pak::items [pak::nfield $stmt elif_branches]] {
                    set p [pak::items $pair]
                    my check_expr [lindex $p 0]
                    my check_block [lindex $p 1]
                }
                set eb [pak::nfield $stmt else_branch]
                if {![pak::isnil $eb]} { my check_block $eb }
            }
            NullCheckStmt {
                my check_expr [pak::nfield $stmt expr]
                $scope push
                $scope declare [pak::fval $stmt binding] [pak::N TypeName name auto]
                my check_block_stmts [pak::items [pak::nfield [pak::nfield $stmt then] stmts]]
                $scope pop
                set eb [pak::nfield $stmt else_branch]
                if {![pak::isnil $eb]} { my check_block $eb }
            }
            LoopStmt  { my check_block [pak::nfield $stmt body] }
            WhileStmt {
                my check_expr [pak::nfield $stmt condition]
                my check_block [pak::nfield $stmt body]
            }
            ForStmt {
                my check_expr [pak::nfield $stmt iterable]
                $scope push
                $scope declare [pak::fval $stmt binding] [pak::N TypeName name auto]
                set idx [pak::nfield $stmt index]
                if {![pak::isnil $idx]} { $scope declare [pak::sval $idx] [pak::N TypeName name i32] }
                my check_block_stmts [pak::items [pak::nfield [pak::nfield $stmt body] stmts]]
                $scope pop
            }
            MatchStmt { my check_match $stmt }
            DeferStmt { my check_block [pak::nfield $stmt body] }
            Break - Continue {}
            Block { my check_block $stmt }
            ConstDecl {
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my check_expr $v }
                set t [pak::nfield $stmt type]
                if {[pak::isnil $t]} { set t [pak::N TypeName name auto] }
                $scope declare [pak::fval $stmt name] $t
            }
            AsmStmt {}
            GotoStmt - LabelStmt {}
            DoWhileStmt {
                my check_block [pak::nfield $stmt body]
                my check_expr [pak::nfield $stmt condition]
            }
            ComptimeIf {
                my check_expr [pak::nfield $stmt condition]
                my check_block [pak::nfield $stmt then]
                set eb [pak::nfield $stmt else_branch]
                if {![pak::isnil $eb]} { my check_block $eb }
            }
        }
    }

    method check_let {s} {
        set val [pak::nfield $s value]
        if {![pak::isnil $val]} { my check_expr $val }
        set typ [pak::nfield $s type]
        if {[pak::isnil $typ] && ![pak::isnil $val]} { set typ [my infer_type $val] }
        if {[pak::isnil $typ]} { set typ [pak::N TypeName name auto] }
        set name [pak::fval $s name]
        $scope declare $name $typ
        foreach a [pak::annlist $s] {
            if {[dict exists $::pak::DMA_SAFE_ANNS $a] || [string match "@aligned*" $a]} {
                dict set aligned_vars $name 1
            }
        }
        if {[pak::kindof $val] eq "Ident"} {
            set src [$scope lookup [pak::fval $val name]]
            if {[pak::kindof $src] eq "TypePointer"} { $scope mark_moved [pak::fval $val name] }
        }
    }

    method check_static {s} {
        set val [pak::nfield $s value]
        if {![pak::isnil $val]} { my check_expr $val }
        set typ [pak::nfield $s type]
        if {[pak::isnil $typ]} { set typ [pak::N TypeName name auto] }
        set name [pak::fval $s name]
        $scope declare $name $typ
        foreach a [pak::annlist $s] {
            if {[dict exists $::pak::DMA_SAFE_ANNS $a] || [string match "@aligned*" $a]} {
                dict set aligned_vars $name 1
            }
        }
    }

    # ── expressions ───────────────────────────────────────────────────────────
    method check_expr {expr} {
        if {[pak::isnil $expr]} return
        switch -- [pak::kindof $expr] {
            Ident {
                set name [pak::fval $expr name]
                if {$name eq "_"} return
                if {[dict exists $::pak::MODULE_NAMESPACES $name]} return
                if {![$scope is_declared $name]} {
                    if {[$env has_enum $name] || [$env has_variant $name] || [$env has_struct $name]} return
                    if {[$env has_trait $name]} return
                    if {[$env has_fn $name]} return
                    my err E010 "unknown name '$name'" $expr "declare it with 'let $name = ...'"
                    return
                }
                if {[$scope is_moved $name]} {
                    my err E401 "use of '$name' after it was moved" $expr \
                        "If you need to use '$name' after passing it, pass a pointer: &$name"
                }
            }
            DotAccess {
                set obj [pak::nfield $expr obj]
                my check_expr $obj
                if {[pak::kindof $obj] eq "Ident"} {
                    my check_field_access $obj [pak::fval $expr field] $expr
                }
            }
            Call {
                foreach a [pak::items [pak::nfield $expr args]] { my check_expr $a }
                my check_call_arity $expr
                set func [pak::nfield $expr func]
                if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
                    set mod [pak::fval [pak::nfield $func obj] name]
                    set fn [pak::fval $func field]
                    if {[list $mod $fn] in {{cache writeback} {cache writeback_inv}}} {
                        set args [pak::items [pak::nfield $expr args]]
                        if {[llength $args] > 0} {
                            set nm [my expr_base_name [lindex $args 0]]
                            if {$nm ne ""} { dict set cache_written $nm 1 }
                        }
                    }
                }
            }
            BinaryOp {
                my check_expr [pak::nfield $expr left]
                my check_expr [pak::nfield $expr right]
            }
            UnaryOp { my check_expr [pak::nfield $expr operand] }
            Assign {
                my check_expr [pak::nfield $expr target]
                my check_expr [pak::nfield $expr value]
            }
            AddrOf { my check_expr [pak::nfield $expr expr] }
            Deref  { my check_expr [pak::nfield $expr expr] }
            IndexAccess {
                my check_expr [pak::nfield $expr obj]
                my check_expr [pak::nfield $expr index]
            }
            SliceExpr {
                my check_expr [pak::nfield $expr obj]
                set st [pak::nfield $expr start]
                if {![pak::isnil $st]} { my check_expr $st }
                set en [pak::nfield $expr end]
                if {![pak::isnil $en]} { my check_expr $en }
            }
            Cast { my check_expr [pak::nfield $expr expr] }
            StructLit {
                my check_struct_lit $expr
                foreach pair [pak::items [pak::nfield $expr fields]] {
                    my check_expr [lindex [pak::items $pair] 1]
                }
            }
            ArrayLit {
                foreach el [pak::items [pak::nfield $expr elements]] { my check_expr $el }
                set r [pak::nfield $expr repeat]
                if {![pak::isnil $r]} { my check_expr $r }
            }
            CatchExpr {
                my check_expr [pak::nfield $expr expr]
                $scope push
                set b [pak::nfield $expr binding]
                if {![pak::isnil $b]} { $scope declare [pak::sval $b] [pak::N TypeName name auto] }
                my check_block_stmts [pak::items [pak::nfield [pak::nfield $expr handler] stmts]]
                $scope pop
            }
            NamedArg { my check_expr [pak::nfield $expr value] }
            RangeExpr {
                my check_expr [pak::nfield $expr start]
                set en [pak::nfield $expr end]
                if {![pak::isnil $en]} { my check_expr $en }
            }
            OkExpr  { my check_expr [pak::nfield $expr value] }
            ErrExpr { my check_expr [pak::nfield $expr value] }
            SizeOf {}
            AlignOf {}
            OffsetOf {}
            FmtStr {
                foreach part [pak::items [pak::nfield $expr parts]] {
                    if {[pak::kindof $part] ne ""} { my check_expr $part }
                }
            }
            AsmExpr {
                foreach o [pak::items [pak::nfield $expr outputs]] { my check_expr [lindex [pak::items $o] 1] }
                foreach i [pak::items [pak::nfield $expr inputs]]  { my check_expr [lindex [pak::items $i] 1] }
            }
            Closure {
                $scope push
                foreach p [pak::items [pak::nfield $expr params]] {
                    $scope declare [pak::fval $p name] [pak::nfield $p type]
                }
                my check_block_stmts [pak::items [pak::nfield [pak::nfield $expr body] stmts]]
                $scope pop
            }
            TupleLit {
                foreach el [pak::items [pak::nfield $expr elements]] { my check_expr $el }
            }
            TupleAccess { my check_expr [pak::nfield $expr obj] }
            AllocExpr {
                set c [pak::nfield $expr count]
                if {![pak::isnil $c]} { my check_expr $c }
            }
            FreeExpr { my check_expr [pak::nfield $expr ptr] }
        }
    }

    # ── field access (E011) ───────────────────────────────────────────────────
    method check_field_access {obj_ident field node} {
        set typ [$scope lookup [pak::fval $obj_ident name]]
        set struct_name [my unwrap_type_name $typ]
        if {$struct_name ne "" && [$env has_struct $struct_name]} {
            set fields [$env struct_fields $struct_name]
            if {$fields ne "" && ![dict exists $fields $field]} {
                my err E011 "struct '$struct_name' has no field '$field'" $node \
                    "Available fields: [join [dict keys $fields] {, }]"
            }
        }
    }

    # ── call arity (E012) ─────────────────────────────────────────────────────
    method check_call_arity {call} {
        set func [pak::nfield $call func]
        if {[pak::kindof $func] ne "Ident"} return
        set name [pak::fval $func name]
        set params [$env fn_params $name]
        if {$params eq ""} return
        set n_args [llength [pak::items [pak::nfield $call args]]]
        set n_params [llength $params]
        set plist {}
        foreach p $params { lappend plist "[pak::fval $p name]: [pak::type_str [pak::nfield $p type]]" }
        set psig [join $plist {, }]
        if {[$env fn_variadic $name]} {
            if {$n_args < $n_params} {
                my err E012 "function '$name' takes at least $n_params argument(s), got $n_args" $call \
                    "Expected: ${name}($psig, ...)"
            }
            return
        }
        if {$n_args != $n_params} {
            my err E012 "function '$name' takes $n_params argument(s), got $n_args" $call \
                "Expected: ${name}($psig)"
        }
    }

    # ── struct literal (E013/E014) ────────────────────────────────────────────
    method check_struct_lit {lit} {
        set tn [pak::fval $lit type_name]
        if {![$env has_struct $tn]} return
        set decl [$env get_struct $tn]
        set known {}
        set knownset [dict create]
        foreach f [pak::items [pak::nfield $decl fields]] {
            set fn [pak::fval $f name]
            lappend known $fn
            dict set knownset $fn 1
        }
        set givenset [dict create]
        foreach pair [pak::items [pak::nfield $lit fields]] {
            dict set givenset [pak::sval [lindex [pak::items $pair] 0]] 1
        }
        set unknown {}
        foreach g [dict keys $givenset] { if {![dict exists $knownset $g]} { lappend unknown $g } }
        foreach u [lsort $unknown] {
            my err E013 "struct '$tn' has no field '$u'" $lit \
                "Valid fields: [join [lsort $known] {, }]"
        }
        set missing {}
        foreach k $known { if {![dict exists $givenset $k]} { lappend missing $k } }
        if {[llength $missing] > 0} {
            my err E014 "struct '$tn' missing fields: [join [lsort $missing] {, }]" $lit \
                "Add the missing fields or initialise them to a default value"
        }
    }

    # ── exhaustive match (E301) ───────────────────────────────────────────────
    method check_match {stmt} {
        my check_expr [pak::nfield $stmt expr]
        set has_wildcard 0
        set covered [dict create]
        foreach arm [pak::items [pak::nfield $stmt arms]] {
            $scope push
            set pat [pak::nfield $arm pattern]
            switch -- [pak::kindof $pat] {
                Ident {
                    if {[pak::fval $pat name] eq "_"} { set has_wildcard 1 }
                }
                EnumVariantAccess { dict set covered [pak::fval $pat name] 1 }
                DotAccess {
                    if {[pak::kindof [pak::nfield $pat obj]] eq "Ident"} {
                        dict set covered [pak::fval $pat field] 1
                    }
                }
                Call {
                    if {[pak::kindof [pak::nfield $pat func]] eq "EnumVariantAccess"} {
                        dict set covered [pak::fval [pak::nfield $pat func] name] 1
                        foreach arg [pak::items [pak::nfield $pat args]] {
                            if {[pak::kindof $arg] eq "Ident" && [pak::fval $arg name] ne "_"} {
                                $scope declare [pak::fval $arg name] [pak::N TypeName name auto]
                            }
                        }
                    }
                }
            }
            set body [pak::nfield $arm body]
            if {[pak::kindof $body] eq "Block"} {
                my check_block_stmts [pak::items [pak::nfield $body stmts]]
            }
            $scope pop
        }
        if {$has_wildcard} return
        set match_type [my infer_match_type [pak::nfield $stmt expr]]
        if {$match_type eq ""} return
        set all_cases [$env all_cases $match_type]
        if {$all_cases eq ""} return
        set missing {}
        foreach c $all_cases { if {![dict exists $covered $c]} { lappend missing $c } }
        if {[llength $missing] > 0} {
            set dotted {}
            foreach m $missing { lappend dotted ".$m" }
            my err E301 "non-exhaustive match on '$match_type'" $stmt \
                "Add missing cases: [join $dotted {, }], or add a default: _ => {}"
        }
    }

    method infer_match_type {expr} {
        switch -- [pak::kindof $expr] {
            Ident { return [my unwrap_type_name [$scope lookup [pak::fval $expr name]]] }
            DotAccess {
                set obj [pak::nfield $expr obj]
                if {[pak::kindof $obj] eq "Ident"} {
                    set struct_name [my unwrap_type_name [$scope lookup [pak::fval $obj name]]]
                    if {$struct_name ne ""} {
                        set fields [$env struct_fields $struct_name]
                        set fld [pak::fval $expr field]
                        if {$fields ne "" && [dict exists $fields $fld]} {
                            return [my unwrap_type_name [dict get $fields $fld]]
                        }
                    }
                }
            }
        }
        return ""
    }

    # ── DMA safety (E201/E202) ────────────────────────────────────────────────
    method check_dma_call {expr} {
        if {[pak::kindof $expr] ne "Call"} return
        set func [pak::nfield $expr func]
        if {[pak::kindof $func] ne "DotAccess"} return
        if {[pak::kindof [pak::nfield $func obj]] ne "Ident"} return
        set mod [pak::fval [pak::nfield $func obj] name]
        set fn [pak::fval $func field]
        if {![dict exists $::pak::DMA_FNS [list $mod $fn]]} return
        set args [pak::items [pak::nfield $expr args]]
        if {[llength $args] == 0} return
        set name [my expr_base_name [lindex $args 0]]
        if {$name eq ""} return
        if {![dict exists $cache_written $name] && ![dict exists $aligned_vars $name]} {
            my err E201 "possible stale cache before DMA transfer of '$name'" $expr \
                "Add before the transfer: cache.writeback(&$name)"
        }
        if {![dict exists $aligned_vars $name]} {
            my err E202 "buffer '$name' may not be 16-byte aligned for DMA" $expr \
                "Declare it with @aligned(16): @aligned(16) let $name: ..."
        }
    }

    # ── helpers ───────────────────────────────────────────────────────────────
    method infer_type {expr} {
        switch -- [pak::kindof $expr] {
            IntLit    { return [pak::N TypeName name i32] }
            FloatLit  { return [pak::N TypeName name f32] }
            BoolLit   { return [pak::N TypeName name bool] }
            StringLit { return [pak::N TypeName name Str] }
            Ident {
                set t [$scope lookup [pak::fval $expr name]]
                if {$t eq ""} { return [pak::Nil] }
                return $t
            }
            AddrOf {
                set inner [my infer_type [pak::nfield $expr expr]]
                if {![pak::isnil $inner]} {
                    return [pak::N TypePointer inner $inner nullable 0 mutable [pak::fval $expr mutable]]
                }
            }
            StructLit { return [pak::N TypeName name [pak::fval $expr type_name]] }
            EnumVariantAccess {
                set en [$env enum_case_of [pak::fval $expr name]]
                if {$en ne ""} { return [pak::N TypeName name $en] }
            }
        }
        return [pak::Nil]
    }

    method unwrap_type_name {typ} {
        switch -- [pak::kindof $typ] {
            TypeName    { return [pak::fval $typ name] }
            TypePointer { return [my unwrap_type_name [pak::nfield $typ inner]] }
        }
        return ""
    }

    method expr_base_name {expr} {
        switch -- [pak::kindof $expr] {
            Ident       { return [pak::fval $expr name] }
            AddrOf      { return [my expr_base_name [pak::nfield $expr expr]] }
            DotAccess   { return [my expr_base_name [pak::nfield $expr obj]] }
            IndexAccess { return [my expr_base_name [pak::nfield $expr obj]] }
        }
        return ""
    }
}

# ── public entry ───────────────────────────────────────────────────────────────
proc pak::typecheck {program {filename ""} {no_style_warnings 0}} {
    set env [pak::TypeEnv new]
    set decls [pak::items [pak::nfield $program decls]]
    $env collect $decls
    set tc [pak::TypeChecker new $env $filename $no_style_warnings]
    set errs [$tc check $decls]
    $tc destroy
    $env destroy
    return $errs
}

# ── typo-guards: every kind named in a dispatch must be a real AST kind ─────────
pak::assert_kinds "tc collect" {
    StructDecl UnionDecl EnumDecl VariantDecl FnDecl ImplBlock ImplTraitBlock
    TraitDecl CfgBlock
}
pak::assert_kinds "tc naming" {
    StructDecl EnumDecl VariantDecl FnDecl ConstDecl StaticDecl LetDecl ImplBlock
}
pak::assert_kinds "tc top" {
    FnDecl EntryBlock StaticDecl LetDecl ImplBlock ImplTraitBlock TraitDecl
    UnionDecl CfgBlock ConstDecl ExternConst AssetDecl
}
pak::assert_kinds "tc stmt" {
    LetDecl StaticDecl ExprStmt Return IfStmt NullCheckStmt LoopStmt WhileStmt
    ForStmt MatchStmt DeferStmt Break Continue Block ConstDecl AsmStmt GotoStmt
    LabelStmt DoWhileStmt ComptimeIf
}
pak::assert_kinds "tc expr" {
    Ident DotAccess Call BinaryOp UnaryOp Assign AddrOf Deref IndexAccess
    SliceExpr Cast StructLit ArrayLit CatchExpr NamedArg RangeExpr OkExpr ErrExpr
    SizeOf AlignOf OffsetOf FmtStr AsmExpr Closure TupleLit TupleAccess AllocExpr
    FreeExpr
}
