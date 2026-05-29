# tcl/ast_visit.tcl — exhaustiveness support for AST walkers.
#
# The checker, typechecker, and codegen each dispatch over the 89 AST node
# kinds. A forgotten case (silent fall-through) or a typo'd kind name is the
# easiest way to produce wrong output. pak::assert_exhaustive turns both into
# immediate, located errors, driven by the same schema as pak::N / pak::nfield.
#
# Requires ast.tcl (for ::pak::SCHEMA) to be sourced first.

namespace eval pak {}

# Include guard (reachable via multiple consumers; see ast.tcl).
if {[info exists ::pak::_ast_visit_loaded]} { return }
set ::pak::_ast_visit_loaded 1

# All node kinds (sorted) — handy for building dispatch tables.
proc pak::all_kinds {} {
    if {![info exists ::pak::SCHEMA]} {
        return -code error "pak::all_kinds: source ast.tcl first"
    }
    return [lsort [dict keys $::pak::SCHEMA]]
}

# Verify every kind in `kinds` is a real AST kind — a typo guard for subset
# dispatchers (like the checker) that intentionally handle only some kinds and
# so can't use the full-coverage assert_exhaustive. Catches "IfStatement" for
# "IfStmt" at source time rather than as a silent never-taken switch arm.
proc pak::assert_kinds {label kinds} {
    set all [pak::all_kinds]
    set bad {}
    foreach k $kinds { if {$k ni $all} { lappend bad $k } }
    if {[llength $bad]} {
        return -code error "$label: unknown AST kind(s): [lsort -unique $bad]"
    }
}

# Verify a walker covers the AST. `handled` is the list of kinds it dispatches
# on; `ignore` lists kinds it intentionally skips. Errors on any kind that is
# unknown (typo) or neither handled nor ignored (forgotten).
proc pak::assert_exhaustive {label handled {ignore {}}} {
    set all [pak::all_kinds]
    set unknown {}
    foreach k [concat $handled $ignore] {
        if {$k ni $all} { lappend unknown $k }
    }
    if {[llength $unknown]} {
        return -code error "$label: unknown AST kind(s): [lsort -unique $unknown]"
    }
    set covered [concat $handled $ignore]
    set missing {}
    foreach k $all {
        if {$k ni $covered} { lappend missing $k }
    }
    if {[llength $missing]} {
        return -code error "$label: unhandled AST kind(s): [lsort $missing]"
    }
    return
}
