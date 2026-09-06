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
# serialize produces the canonical AST dump format (see tools/ast_dump.tcl).

namespace eval pak {}

# Include guard: ast.tcl is reachable via both parser.tcl and checker.tcl, and
# re-sourcing would re-run `struct::record define` (which errors on redefine).
if {[info exists ::pak::_ast_loaded]} { return }
set ::pak::_ast_loaded 1

# Node schema lives in ast_schema.tcl. struct::record holds the field
# set per kind; pak::N validates construction and pak::nfield validates reads,
# turning stringly-typed field-name slips into immediate, located errors.
package require struct::record
source [file join [file dirname [info script]] ast_schema.tcl]
set ::pak::SCHEMA [dict create]
foreach _r [struct::record show records] {
    dict set ::pak::SCHEMA [string trimleft $_r :] [lsort [struct::record show members $_r]]
}
unset -nocomplain _r

# ── source positions ─────────────────────────────────────────────────────────
# Nodes carry their position out of band, as a fourth element of the node value:
#   {node Kind {field val ...} {line col}}
# Keeping it out of the field dict means the schema, pak::nfield and the AST
# dump format are all untouched, so a node's structure stays exactly what it
# was while diagnostics gain a real location.
#
# The parser pushes the position of the token starting each rule onto this
# stack; pak::N stamps whatever is innermost. Nodes synthesized outside parsing
# (by the checker, typechecker or codegen) get 0 0, which formats as no
# location rather than a wrong one.
set ::pak::POS_STACK {}

proc pak::pos_push {line col} { lappend ::pak::POS_STACK [list $line $col] }
proc pak::pos_pop  {} { set ::pak::POS_STACK [lrange $::pak::POS_STACK 0 end-1] }
proc pak::pos_reset {} { set ::pak::POS_STACK {} }
proc pak::pos_cur {} {
    if {[llength $::pak::POS_STACK] == 0} { return {0 0} }
    return [lindex $::pak::POS_STACK end]
}

# Position of a node as a {line col} pair; {0 0} when unknown.
proc pak::nodepos {node} {
    if {[lindex $node 0] ne "node" || [llength $node] < 4} { return {0 0} }
    return [lindex $node 3]
}
proc pak::nodeline {node} { return [lindex [pak::nodepos $node] 0] }
proc pak::nodecol  {node} { return [lindex [pak::nodepos $node] 1] }

# Construct an AST node. Scalar field values are auto-wrapped per the field's
# kind in ::pak::FKIND, so call sites read like ordinary attribute access
# (`name $x` rather than `name [pak::Lit $x]`). Fields of kind `n` are passed
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
    return [list node $kind $fields [pak::pos_cur]]
}

# Wrap a raw field value according to its kind (see ast_schema.tcl header).
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
# `pak build` converts an asset before packing it -- mksprite turns a .png
# into a .sprite, audioconv64 a .wav into a .wav64 -- and `pak pack` names the
# archive entry after the CONVERTED file. A program declares the source it
# authored (`from "sprites/bg.png"`), so the name it asks for at runtime has to
# be put through the same mapping or it can never match. Both backends use
# this, so both ask for the same name.
set ::pak::ASSET_PACKED_EXT [dict create \
    .png .sprite \
    .wav .wav64 \
    .xm  .xm64 \
    .ym  .ym64 \
    .gltf .t3dm \
    .glb  .t3dm]

proc pak::asset_packed_path {path} {
    set ext [string tolower [file extension $path]]
    if {![dict exists $::pak::ASSET_PACKED_EXT $ext]} { return $path }
    return "[file rootname $path][dict get $::pak::ASSET_PACKED_EXT $ext]"
}

proc pak::Seq {items}    { return [list seq $items] }
proc pak::Lit {s}        { return [list lit $s] }
proc pak::Fnum {x}       { return [list fnum $x] }
proc pak::Bool {b}       { return [list bool [expr {$b ? 1 : 0}]] }
proc pak::Nil {}         { return [list nil] }

# ── Tagged-value accessors for AST consumers (checker, typechecker, codegen) ──
# These unwrap the tagged representation so walkers read like Python attribute
# access. kindof returns "" for non-nodes (nil/lit/...), which makes a node-kind
# switch fall through cleanly the same way Python's isinstance chain does.
proc pak::kindof {tv} { expr {[lindex $tv 0] eq "node" ? [lindex $tv 1] : ""} }
proc pak::sval   {tv} { return [lindex $tv 1] }   ;# {lit X}/{bool X}/{fnum X} -> X
proc pak::items  {tv} { return [lindex $tv 1] }   ;# {seq L} -> L (Tcl list of tvs)
proc pak::isnil  {tv} { expr {[lindex $tv 0] eq "nil"} }
# Field read returning the unwrapped scalar / list, for the common cases.
proc pak::fval  {node field} { return [lindex [pak::nfield $node $field] 1] }
proc pak::flist {node field} { return [lindex [pak::nfield $node $field] 1] }

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
