# tcl/checker.tcl — extended semantic checker, Tcl port of pak/checker.py.
#
# Runs after parsing and enforces the E1xx/W1xx invariants the typechecker
# doesn't: entry/duplicate-name rules, n64 module + API-arity validation,
# const-expression evaluability, @cfg feature names, reachability warnings.
#
# Diagnostics are produced in the same walk order as the Python checker and
# carry identical code/severity/message/hint text, so check_parity.sh can diff
# them against the oracle. Source positions are not yet tracked in the Tcl AST
# (see the parser-parity staging note); the E107 "first defined at line N" hint
# is therefore position-bearing and normalized away in the parity harness.

set _ckhere [file dirname [file normalize [info script]]]
source [file join $_ckhere ast.tcl]
source [file join $_ckhere ast_visit.tcl]
source [file join $_ckhere check_tables.tcl]

namespace eval pak {}

# Include guard (reachable via multiple consumers; see ast.tcl). Placed after the
# leaf sources above so they still load; prevents redefining pak::Checker.
if {[info exists ::pak::_checker_loaded]} { return }
set ::pak::_checker_loaded 1

oo::class create pak::Checker {
    variable filename diags top_names used_modules

    constructor {{fname ""}} {
        set filename $fname
        set diags {}
        set top_names [dict create]
        set used_modules [dict create]
    }

    method diags {} { return $diags }

    # ── diagnostic helpers ────────────────────────────────────────────────────
    method err {code msg hint node} {
        lappend diags [dict create code $code severity error \
            message $msg hint $hint line 0 col 0 filename $filename]
    }
    method warn {code msg hint node} {
        lappend diags [dict create code $code severity warning \
            message $msg hint $hint line 0 col 0 filename $filename]
    }

    # ── top-level program walk ────────────────────────────────────────────────
    method check_program {decls} {
        foreach decl $decls {
            switch -- [pak::kindof $decl] {
                UseDecl { my check_use $decl }
                EntryBlock {
                    my check_entry $decl
                    set body [pak::nfield $decl body]
                    my check_block_calls $body
                    my check_block_reachability $body $decl
                }
                FnDecl {
                    my register_name [pak::fval $decl name] $decl
                    if {![pak::isnil [pak::nfield $decl body]]} { my check_fn_body $decl }
                }
                ImplBlock - ImplTraitBlock {
                    set tn [pak::fval $decl type_name]
                    foreach m [pak::items [pak::nfield $decl methods]] {
                        my register_name "${tn}_[pak::fval $m name]" $m
                        if {![pak::isnil [pak::nfield $m body]]} { my check_fn_body $m }
                    }
                }
                StructDecl - EnumDecl - VariantDecl - UnionDecl - TraitDecl {
                    my register_name [pak::fval $decl name] $decl
                }
                ConstDecl {
                    my register_name [pak::fval $decl name] $decl
                    my check_const $decl
                }
                CfgBlock {
                    my check_cfg $decl
                    my check_program [list [pak::nfield $decl decl]]
                }
            }
        }
    }

    method register_name {name node} {
        if {[dict exists $top_names $name]} {
            my err E107 "Duplicate top-level name '$name'" \
                "First defined at line [dict get $top_names $name]" $node
        } else {
            dict set top_names $name 0
        }
    }

    # ── use declarations ──────────────────────────────────────────────────────
    method check_use {decl} {
        set parts [split [pak::fval $decl path] .]
        if {[llength $parts] < 2} return
        set prefix [lindex $parts 0]
        if {$prefix eq "n64"} {
            set mod [lindex $parts 1]
            if {![dict exists $::pak::KNOWN_MODULES $mod]} {
                set known {}
                foreach k [lsort [dict keys $::pak::KNOWN_MODULES]] {
                    if {$k ne "t3d"} { lappend known $k }
                }
                my err E104 "Unknown module '[pak::fval $decl path]'" \
                    "Known n64 modules: [join $known {, }]" $decl
            } else {
                dict set used_modules $mod 1
            }
        } elseif {$prefix eq "t3d"} {
            dict set used_modules t3d 1
        }
    }

    # ── entry block (structural — parser enforces no params/return) ────────────
    method check_entry {decl} {}

    # ── function body checks ──────────────────────────────────────────────────
    method check_fn_body {decl} {
        set body [pak::nfield $decl body]
        if {[pak::isnil $body]} return
        my check_block_reachability $body $decl
        my check_block_calls $body
    }

    method check_block_reachability {block parent} {
        set terminated 0
        foreach stmt [pak::items [pak::nfield $block stmts]] {
            if {$terminated} {
                my warn W101 "Unreachable statement" \
                    "This code can never execute — it follows a return, break, or continue" $stmt
                break
            }
            switch -- [pak::kindof $stmt] {
                Return - Break - Continue - GotoStmt { set terminated 1 }
                IfStmt {
                    set then_term [my check_block_reachability [pak::nfield $stmt then] $parent]
                    set else_term 0
                    set eb [pak::nfield $stmt else_branch]
                    if {![pak::isnil $eb]} { set else_term [my check_block_reachability $eb $parent] }
                    set elifs [pak::items [pak::nfield $stmt elif_branches]]
                    if {$then_term && $else_term && [llength $elifs] == 0} { set terminated 1 }
                }
                WhileStmt - LoopStmt - ForStmt - DoWhileStmt {
                    my check_block_reachability [pak::nfield $stmt body] $parent
                }
                Block {
                    if {[my check_block_reachability $stmt $parent]} { set terminated 1 }
                }
            }
        }
        return $terminated
    }

    method check_block_calls {block} {
        foreach stmt [pak::items [pak::nfield $block stmts]] { my check_stmt_calls $stmt }
    }

    method check_stmt_calls {stmt} {
        switch -- [pak::kindof $stmt] {
            ExprStmt { my check_expr_calls [pak::nfield $stmt expr] }
            LetDecl {
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my check_expr_calls $v }
            }
            Assign  { my check_expr_calls [pak::nfield $stmt value] }
            Return  {
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my check_expr_calls $v }
            }
            IfStmt {
                my check_expr_calls [pak::nfield $stmt condition]
                my check_block_calls [pak::nfield $stmt then]
                foreach pair [pak::items [pak::nfield $stmt elif_branches]] {
                    my check_block_calls [lindex [pak::items $pair] 1]
                }
                set eb [pak::nfield $stmt else_branch]
                if {![pak::isnil $eb]} { my check_block_calls $eb }
            }
            WhileStmt {
                my check_expr_calls [pak::nfield $stmt condition]
                my check_block_calls [pak::nfield $stmt body]
            }
            DoWhileStmt {
                my check_block_calls [pak::nfield $stmt body]
                my check_expr_calls [pak::nfield $stmt condition]
            }
            ForStmt  { my check_block_calls [pak::nfield $stmt body] }
            LoopStmt { my check_block_calls [pak::nfield $stmt body] }
            Block    { my check_block_calls $stmt }
            DeferStmt { my check_stmt_calls [pak::nfield $stmt body] }
            MatchStmt {
                my check_expr_calls [pak::nfield $stmt expr]
                foreach arm [pak::items [pak::nfield $stmt arms]] {
                    set b [pak::nfield $arm body]
                    if {[pak::kindof $b] eq "Block"} {
                        my check_block_calls $b
                    } else {
                        my check_stmt_calls $b
                    }
                }
            }
        }
    }

    method check_expr_calls {expr} {
        if {[pak::isnil $expr]} return
        switch -- [pak::kindof $expr] {
            Call {
                my check_call_arity $expr
                foreach arg [pak::items [pak::nfield $expr args]] { my check_expr_calls $arg }
            }
            BinaryOp {
                my check_expr_calls [pak::nfield $expr left]
                my check_expr_calls [pak::nfield $expr right]
            }
            UnaryOp     { my check_expr_calls [pak::nfield $expr operand] }
            DotAccess   { my check_expr_calls [pak::nfield $expr obj] }
            IndexAccess {
                my check_expr_calls [pak::nfield $expr obj]
                my check_expr_calls [pak::nfield $expr index]
            }
            Assign    { my check_expr_calls [pak::nfield $expr value] }
            Cast      { my check_expr_calls [pak::nfield $expr expr] }
            AddrOf    { my check_expr_calls [pak::nfield $expr expr] }
            Deref     { my check_expr_calls [pak::nfield $expr expr] }
            CatchExpr { my check_expr_calls [pak::nfield $expr expr] }
            OkExpr    { my check_expr_calls [pak::nfield $expr value] }
            ErrExpr   { my check_expr_calls [pak::nfield $expr value] }
        }
    }

    method check_call_arity {call} {
        set func [pak::nfield $call func]
        if {[pak::kindof $func] ne "DotAccess"} return
        set obj [pak::nfield $func obj]
        if {[pak::kindof $obj] ne "DotAccess"} return
        set mod [pak::fval $obj field]
        set fn  [pak::fval $func field]
        set key [list $mod $fn]
        if {![dict exists $::pak::API_ARITY $key]} return
        set arity [dict get $::pak::API_ARITY $key]
        set min_a [lindex $arity 0]
        set max_a [lindex $arity 1]
        set n [llength [pak::items [pak::nfield $call args]]]
        if {$max_a eq ""} {
            if {$n < $min_a} {
                my err E105 "n64.$mod.${fn}() requires at least $min_a argument(s), got $n" \
                    "Check the libdragon docs for the correct signature" $call
            }
        } elseif {!($min_a <= $n && $n <= $max_a)} {
            if {$min_a == $max_a} { set expected $min_a } else { set expected "${min_a}–${max_a}" }
            my err E105 "n64.$mod.${fn}() expects $expected argument(s), got $n" \
                "Check the libdragon docs for the correct signature" $call
        }
    }

    # ── const expression evaluability ─────────────────────────────────────────
    method check_const {decl} {
        if {![pak::is_const_expr [pak::nfield $decl value]]} {
            my err E106 "const '[pak::fval $decl name]': value is not a compile-time constant" \
                "Only literals, other consts, and arithmetic on consts are allowed" $decl
        }
    }

    # ── @cfg feature names ────────────────────────────────────────────────────
    method check_cfg {decl} {
        set feature [pak::fval $decl feature]
        if {$feature ne "" && ![dict exists $::pak::KNOWN_CFG $feature]} {
            my warn W103 "Unknown @cfg feature '$feature'" \
                "Known features: [join [lsort [dict keys $::pak::KNOWN_CFG]] {, }]" $decl
        }
    }
}

# ── compile-time expression check ─────────────────────────────────────────────
proc pak::is_const_expr {expr} {
    if {[pak::isnil $expr]} { return 1 }
    switch -- [pak::kindof $expr] {
        IntLit - FloatLit - BoolLit - StringLit - NoneLit { return 1 }
        Ident { return 1 }
        UnaryOp { return [pak::is_const_expr [pak::nfield $expr operand]] }
        BinaryOp {
            return [expr {[pak::is_const_expr [pak::nfield $expr left]] &&
                          [pak::is_const_expr [pak::nfield $expr right]]}]
        }
        Cast { return [pak::is_const_expr [pak::nfield $expr expr]] }
        SizeOf - OffsetOf - AlignOf { return 1 }
        default { return 0 }
    }
}

# ── public entry: run all checks on a parsed Program node ──────────────────────
proc pak::semantic_check {program {filename ""}} {
    set chk [pak::Checker new $filename]
    $chk check_program [pak::items [pak::nfield $program decls]]
    set out [$chk diags]
    $chk destroy
    return $out
}

# ── typo-guard: every kind named in a dispatch must be a real AST kind ─────────
pak::assert_kinds "checker top-level" {
    UseDecl EntryBlock FnDecl ImplBlock ImplTraitBlock StructDecl EnumDecl
    VariantDecl UnionDecl TraitDecl ConstDecl CfgBlock
}
pak::assert_kinds "checker reachability" {
    Return Break Continue GotoStmt IfStmt WhileStmt LoopStmt ForStmt DoWhileStmt Block
}
pak::assert_kinds "checker stmt-calls" {
    ExprStmt LetDecl Assign Return IfStmt WhileStmt DoWhileStmt ForStmt LoopStmt
    Block DeferStmt MatchStmt
}
pak::assert_kinds "checker expr-calls" {
    Call BinaryOp UnaryOp DotAccess IndexAccess Assign Cast AddrOf Deref
    CatchExpr OkExpr ErrExpr
}
pak::assert_kinds "checker const-expr" {
    IntLit FloatLit BoolLit StringLit NoneLit Ident UnaryOp BinaryOp Cast
    SizeOf OffsetOf AlignOf
}
