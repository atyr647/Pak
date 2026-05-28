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

proc pak::N {kind args}  { return [list node $kind $args] }
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
