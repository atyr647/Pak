# tcl/ast.tcl — AST value representation + canonical serializer for the Tcl port.
#
# Every AST value is a tagged Tcl list so the serializer can disambiguate
# (Tcl is "everything is a string"):
#   {node KIND {field tv field tv ...}}   a node; field values are tagged
#   {seq {tv tv ...}}                      an ordered list of values
#   {lit STR}                              a scalar serialized as a quoted string
#   {fnum X}                               a float literal value (formatted %.17g)
#   {bool 0|1}                             a boolean
#   {nil}                                  None
#
# serialize produces output identical to tcl/tools/ast_dump.py.

namespace eval pak {}

# Node schema mirrors pak/ast.py (generated). struct::record holds the field
# set per kind; pak::N validates construction and pak::nfield validates reads,
# turning stringly-typed field-name slips into immediate, located errors.
package require struct::record
source [file join [file dirname [info script]] ast_schema.tcl]
set ::pak::SCHEMA [dict create]
foreach _r [struct::record show records] {
    dict set ::pak::SCHEMA [string trimleft $_r :] [lsort [struct::record show members $_r]]
}
unset -nocomplain _r

# Construct an AST node. Scalar field values are auto-wrapped per the field's
# kind in ::pak::FKIND, so call sites read like the Python parser
# (`name $x` rather than `name [pak::Lit $x]`). Kinds with kind `n` are passed
# through unchanged and must already be tagged values (a node, seq, lit, or nil).
proc pak::N {kind args} {
    if {![dict exists $::pak::SCHEMA $kind]} {
        return -code error "pak::N: unknown AST kind '$kind'"
    }
    set got [lsort [dict keys $args]]
    set want [dict get $::pak::SCHEMA $kind]
    if {$got ne $want} {
        return -code error "pak::N $kind: fields {$got} != schema {$want}"
    }
    set kinds [dict get $::pak::FKIND $kind]
    set fields [dict create]
    foreach {f v} $args {
        dict set fields $f [pak::wrap [dict get $kinds $f] $v]
    }
    return [list node $kind $fields]
}

# Wrap a raw field value according to its kind (see gen_schema.py header).
proc pak::wrap {k v} {
    switch -- $k {
        s - i   { return [list lit $v] }
        f       { return [list fnum $v] }
        b       { return [list bool [expr {$v ? 1 : 0}]] }
        L       { return [list seq $v] }
        Ls      { set o {}; foreach e $v { lappend o [list lit $e] }; return [list seq $o] }
        n       { return $v }
        default { return -code error "pak::wrap: bad kind '$k'" }
    }
}

# Schema-checked field read for nodes (use instead of raw dict get in walkers).
proc pak::nfield {node field} {
    set kind [lindex $node 1]
    if {[lindex $node 0] ne "node" || ![dict exists $::pak::SCHEMA $kind]} {
        return -code error "pak::nfield: not an AST node"
    }
    if {[lsearch -exact [dict get $::pak::SCHEMA $kind] $field] < 0} {
        return -code error "pak::nfield: $kind has no field '$field'"
    }
    return [dict get [lindex $node 2] $field]
}
proc pak::Seq {items}    { return [list seq $items] }
proc pak::Lit {s}        { return [list lit $s] }
proc pak::Fnum {x}       { return [list fnum $x] }
proc pak::Bool {b}       { return [list bool [expr {$b ? 1 : 0}]] }
proc pak::Nil {}         { return [list nil] }

# int literal value: decimal text matching Python int(raw[,16]) -> str.
proc pak::intval {raw} {
    if {[string match -nocase "0x*" $raw]} {
        return [expr {[string tolower $raw]}]   ;# Tcl 8.5+ bignum: arbitrary precision
    }
    scan $raw %d v
    return $v
}

proc pak::esc {s} {
    set m [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\t" "\\t" "\r" "\\r"]
    return "\"[string map $m $s]\""
}

proc pak::serialize {tv} {
    switch -- [lindex $tv 0] {
        nil  { return "nil" }
        bool { return [expr {[lindex $tv 1] ? "#t" : "#f"}] }
        lit  { return [pak::esc [lindex $tv 1]] }
        fnum { return [pak::esc [format %.17g [expr {double([lindex $tv 1])}]]] }
        seq {
            set parts {}
            foreach it [lindex $tv 1] { lappend parts [pak::serialize $it] }
            return "\[ [join $parts { }] \]"
        }
        node {
            set kind [lindex $tv 1]
            set fields [lindex $tv 2]
            set parts {}
            foreach nm [lsort [dict keys $fields]] {
                lappend parts "($nm [pak::serialize [dict get $fields $nm]])"
            }
            return "($kind [join $parts { }])"
        }
        default { error "bad tagged value: $tv" }
    }
}
