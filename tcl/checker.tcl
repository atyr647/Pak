# tcl/checker.tcl — extended semantic checker (module resolution, arity,
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
source [file join $_ckhere module_api.tcl]

namespace eval pak {}

# Include guard (reachable via multiple consumers; see ast.tcl). Placed after the
# leaf sources above so they still load; prevents redefining pak::Checker.
if {[info exists ::pak::_checker_loaded]} { return }
set ::pak::_checker_loaded 1

oo::class create pak::Checker {
    variable filename diags top_names used_modules backend pathonly_assets

    constructor {{fname ""} {be "c"}} {
        set filename $fname
        set backend $be
        set diags {}
        set top_names [dict create]
        set used_modules [dict create]
        set pathonly_assets [dict create]
    }

    method diags {} { return $diags }

    # ── diagnostic helpers ────────────────────────────────────────────────────
    # `node` supplies the location: pak::nodepos returns the position of the
    # token the construct started on, or {0 0} for a synthesized node, which the
    # CLI renders as no location rather than a wrong one.
    method err {code msg hint node} {
        lassign [pak::nodepos $node] line col
        lappend diags [dict create code $code severity error \
            message $msg hint $hint line $line col $col filename $filename]
    }
    method warn {code msg hint node} {
        lassign [pak::nodepos $node] line col
        lappend diags [dict create code $code severity warning \
            message $msg hint $hint line $line col $col filename $filename]
    }

    # A Pak `fn` lowers to a C function of the same name, so a name libdragon
    # already defines collides -- and the compiler reports it against
    # libdragon's header rather than the user's line. Warn in Pak terms, with
    # the replacement libdragon itself points at.
    method check_libdragon_collision {decl} {
        if {$backend ne "c"} return
        set name [pak::fval $decl name]
        if {[dict exists $::pak::LIBDRAGON_RESERVED $name]} {
            my warn W004 "'$name' is already defined by libdragon" \
                "libdragon's headers declare '$name' (a deprecated shim), so the\
                 generated C will not compile. Rename the function." $decl
            return
        }
        if {[dict exists $::pak::LIBC_RESERVED $name]} {
            my warn W004 "'$name' is already defined by the C standard library" \
                "newlib declares '$name', and libdragon.h pulls it in. It may\
                 appear to work on a host compiler and conflict when\
                 cross-compiled, because i32 is `long` on mips64-elf and `int`\
                 on a 64-bit host. Rename the function." $decl
        }
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
                    my check_libdragon_collision $decl
                    my check_fn_signature_types $decl
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
                AssetDecl {
                    # Only `: Sprite` has a loader on the standalone backend.
                    # The codegen refuses the rest at the use site, which is
                    # too late: `pak check --backend mips` had already said
                    # the program was a valid standalone program.
                    if {$backend eq "mips"} { my check_asset $decl }
                    # An asset with no loader is a path and nothing else --
                    # nothing gives the name a handle (LANGUAGE.md 14:
                    # `asset level_data from "levels/level1.bin"` is the blob
                    # you DMA yourself). Reading the bare name lowered to an
                    # identifier the generated C never declares. Remember the
                    # name so the use site can say so.
                    if {![my asset_has_loader $decl]} {
                        dict set pathonly_assets [pak::fval $decl name] $decl
                    }
                }
                ExternConst {
                    # An extern symbol resolves on the standalone backend only
                    # if the HAL itself defines it -- boot.S and runtime.pk64
                    # are all that gets linked. An extern const is usually a
                    # libdragon macro, which is nothing the linker can find:
                    # the codegen emitted the reference and the link failed on
                    # an undefined symbol. Say so here, where it can be read.
                    if {$backend eq "mips" && ![pak::mips_hal_symbol [pak::fval $decl name]]} {
                        my err E010 "extern const '[pak::fval $decl name]' is not defined on the standalone backend" \
                            "Only boot.S and runtime/standalone/runtime.pk64 are linked, so an extern symbol they do not define cannot resolve. Use the libdragon backend, or give it a value with `const`." \
                            $decl
                    }
                }
                ExternBlock {
                    if {$backend eq "mips"} {
                        foreach ed [pak::items [pak::nfield $decl decls]] {
                            if {[pak::mips_hal_symbol [pak::fval $ed name]]} continue
                            my err E010 "extern fn '[pak::fval $ed name]' is not defined on the standalone backend" \
                                "Only boot.S and runtime/standalone/runtime.pk64 are linked, so an extern symbol they do not define cannot resolve. Use the libdragon backend, or implement it in the HAL." \
                                $ed
                        }
                    }
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
            dict set top_names $name [pak::nodeline $node]
        }
    }

    # ── assets ────────────────────────────────────────────────────────────────
    # Does this asset declaration produce a loaded handle, or only a path?
    method asset_has_loader {decl} {
        set t [pak::nfield $decl asset_type]
        if {[pak::isnil $t]} { return 0 }
        set tname [expr {[pak::kindof $t] eq "TypeName"
                         ? [pak::fval $t name] : [pak::sval $t]}]
        return [dict exists $::pak::CG_ASSET_LOADERS $tname]
    }

    method check_asset {decl} {
        set t [pak::nfield $decl asset_type]
        set tname ""
        if {![pak::isnil $t]} {
            set tname [expr {[pak::kindof $t] eq "TypeName"
                             ? [pak::fval $t name] : [pak::sval $t]}]
        }
        if {$tname eq "Sprite"} return
        set what [expr {$tname eq "" ? "no type" : "type '$tname'"}]
        my err E010 "asset '[pak::fval $decl name]' has $what, and only Sprite\
                     assets can be loaded on the standalone backend" \
            "runtime/standalone/runtime.pk64 reads .sprite files out of the ROM\
             and nothing else. Declare it `: Sprite`, or use the libdragon\
             backend." \
            $decl
    }

    # ── use declarations ──────────────────────────────────────────────────────
    method check_use {decl} {
        set parts [split [pak::fval $decl path] .]
        # `use t3d` is the spelling the Tiny3D demos actually use, and it has
        # one part, so it fell out here before registering anything -- which
        # silently disabled every check on `t3d.*` calls, E010 included. A
        # gate a user can bypass by how they spell an import is not a gate.
        if {[llength $parts] == 1} {
            if {[lindex $parts 0] eq "t3d"} { dict set used_modules t3d t3d }
            return
        }
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
                # name -> canonical module. Aliases (`use n64.display as disp`)
                # resolve to `display` so MODULE_API lookup is by real module.
                dict set used_modules $mod $mod
                set alias [pak::nfield $decl alias]
                if {![pak::isnil $alias]} {
                    dict set used_modules [pak::fval $decl alias] $mod
                }
            }
        } elseif {$prefix eq "t3d"} {
            dict set used_modules t3d t3d
        }
    }

    # ── entry block (structural — parser enforces no params/return) ────────────
    method check_entry {decl} {}

    # ── function body checks ──────────────────────────────────────────────────
    method check_fn_signature_types {decl} {
        foreach prm [pak::items [pak::nfield $decl params]] {
            my check_backend_type [pak::nfield $prm type]
        }
        my check_backend_type [pak::nfield $decl ret_type]
    }

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

    # Nothing left to refuse. This walked every declared type looking for
    # constructs the MIPS backend could not lower -- FixedMap, Pool, and
    # `dyn Trait`. All three now lower, so the hook stays as the place to
    # report the next one against its declaration rather than at link time.
    method check_backend_type {t} {
        if {$backend ne "mips"} return
        if {[pak::isnil $t] || [llength $t] < 2 || [lindex $t 0] ne "node"} return
        dict for {k v} [lindex $t 2] {
            switch -- [lindex $v 0] {
                node { my check_backend_type $v }
                seq  { foreach it [pak::items $v] { my check_backend_type $it } }
            }
        }
    }

    method check_block_calls {block} {
        foreach stmt [pak::items [pak::nfield $block stmts]] { my check_stmt_calls $stmt }
    }

    method check_stmt_calls {stmt} {
        switch -- [pak::kindof $stmt] {
            ExprStmt { my check_expr_calls [pak::nfield $stmt expr] }
            LetDecl {
                my check_backend_type [pak::nfield $stmt type]
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

    # `&`, `|` and `^` bind looser than the comparisons, as in C. So
    # `status & BUSY == 0` parses as `status & (BUSY == 0)`, which is
    # `status & 0`, which is always 0 -- a wait loop written that way never
    # exits. The shape is detectable: a comparison directly under a bitwise
    # operator only arises when the parentheses are missing (or, written
    # deliberately, means masking with a 0/1, which is worth flagging anyway).
    method check_bitwise_precedence {expr} {
        set op [pak::fval $expr op]
        if {$op ni {& | ^}} return
        foreach side {left right} {
            set child [pak::nfield $expr $side]
            if {[pak::kindof $child] ne "BinaryOp"} continue
            set cop [pak::fval $child op]
            if {$cop ni {== != < <= > >=}} continue
            my warn W104 "Comparison '$cop' binds tighter than '$op'" \
                "This parses as `a $op (b $cop c)`; write `(a $op b) $cop c` if that is what you meant" \
                $expr
        }
    }
    method check_expr_calls {expr} {
        if {[pak::isnil $expr]} return
        switch -- [pak::kindof $expr] {
            Call {
                my check_module_call $expr
                foreach arg [pak::items [pak::nfield $expr args]] { my check_expr_calls $arg }
            }
            BinaryOp {
                my check_bitwise_precedence $expr
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
            Ident {
                set nm [pak::fval $expr name]
                if {[dict exists $pathonly_assets $nm]} {
                    my err E010 "asset '$nm' has no loader, so it has no handle to read" \
                        "Only [join [lsort [dict keys $::pak::CG_ASSET_LOADERS]] { and }]\
                         assets are loaded for you. Give it one of those types\
                         (`asset $nm: Sprite from ...`), or read `${nm}_path`\
                         and load it yourself." \
                        $expr
                }
            }
            CatchExpr { my check_expr_calls [pak::nfield $expr expr] }
            OkExpr    { my check_expr_calls [pak::nfield $expr value] }
            ErrExpr   { my check_expr_calls [pak::nfield $expr value] }
        }
    }

    # Resolve n64.mod.fn / t3d.fn / used-module.fn. Empty list if this Call is
    # not a module API invocation (method call, user function, etc.).
    method module_call_of {call} {
        set func [pak::nfield $call func]
        if {[pak::kindof $func] ne "DotAccess"} { return {} }
        set obj [pak::nfield $func obj]
        set fn  [pak::fval $func field]
        if {[pak::kindof $obj] eq "DotAccess"} {
            set inner [pak::nfield $obj obj]
            set mod [pak::fval $obj field]
            if {[pak::kindof $inner] eq "Ident"} {
                set prefix [pak::fval $inner name]
                if {$prefix in {n64 t3d}} {
                    return [list $mod $fn]
                }
            }
        }
        if {[pak::kindof $obj] eq "Ident"} {
            set name [pak::fval $obj name]
            if {[dict exists $used_modules $name]} {
                return [list [dict get $used_modules $name] $fn]
            }
            # A module called without a `use`. The C backend lowers it anyway
            # -- its dispatch does not consult the imports -- so requiring the
            # `use` here meant such a call escaped the HAL check entirely:
            # `arena.alloc(a, 4)` with no `use n64.arena` passed
            # `pak check --backend mips` and then had no symbol to call.
            # Both halves are required, so a local variable that merely shares
            # a module's name is not mistaken for one.
            if {[dict exists $::pak::KNOWN_MODULES $name]
                && [pak::module_api_has $name $fn]} {
                return [list $name $fn]
            }
        }
        return {}
    }

    method check_module_call {call} {
        set pair [my module_call_of $call]
        if {[llength $pair] != 2} { return }
        lassign $pair mod fn
        set key [list $mod $fn]
        if {![pak::module_api_has $mod $fn]} {
            my err E010 "unknown method '$mod.$fn'" \
                "Not in MODULE_API. See STDLIB.md; unknown methods are never lowered." \
                $call
            return
        }
        if {$backend eq "mips" && ![pak::mips_hal_has $mod $fn]} {
            my err E010 "unknown method '$mod.$fn' on the standalone backend" \
                "Not defined in runtime/standalone/runtime.pk64. Use the libdragon backend, or implement it in the HAL." \
                $call
            return
        }
        if {$backend eq "c"} {
            switch -- [pak::libdragon_class $mod $fn] {
                missing {
                    my warn W005 "'$mod.$fn' is not implemented on the libdragon backend" \
                        "Pak names it but neither libdragon nor Tiny3D defines it, so the\
                         generated C will not compile. It exists on the standalone HAL:\
                         build with --backend mips. See STDLIB.md." $call
                }
                tiny3d {
                    my warn W006 "'$mod.$fn' needs Tiny3D" \
                        "Set `tiny3d = true` under \[dependencies\] in pak.toml and point\
                         TINY3D_INST at your Tiny3D installation." $call
                }
            }
        }
        my check_rdp_cached_addr $call $mod $fn
        # Arity (E105) stays on the fully-qualified `n64.mod.fn(...)` form the
        # goldens already cover. `mod.fn(...)` after `use` is existence + HAL
        # only — several libdragon APIs are called with fewer args than the
        # conservative table (rdpq.attach_clear with one argument, etc.).
        set func [pak::nfield $call func]
        if {[pak::kindof $func] ne "DotAccess"} return
        if {[pak::kindof [pak::nfield $func obj]] ne "DotAccess"} return
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

    # Cached (KSEG0) addresses handed to the DP sample dcache, not RDRAM.
    # rdpq.set_texture_image writebacks a conservative range at runtime; a
    # literal in 0x80000000–0x9FFFFFFF is still the programmer naming a
    # cached buffer, so it is E203. KSEG1 (0xA0000000+) is fine.
    method check_rdp_cached_addr {call mod fn} {
        if {$mod ne "rdpq"} return
        if {$fn ni {set_texture_image set_color_image set_z_image}} return
        set args [pak::items [pak::nfield $call args]]
        if {[llength $args] == 0} return
        set addr [lindex $args 0]
        while {[pak::kindof $addr] eq "Cast"} {
            set addr [pak::nfield $addr expr]
        }
        if {[pak::kindof $addr] ne "IntLit"} return
        set v [pak::fval $addr value]
        if {![string is integer -strict $v]} return
        # Tcl wide ints; compare unsigned 32-bit.
        set u [expr {$v & 0xFFFFFFFF}]
        if {$u >= 0x80000000 && $u < 0xA0000000} {
            my err E203 "cached KSEG0 address handed to rdpq.$fn" \
                "The DP reads RDRAM, not dcache. Use a KSEG1 address (0xA0000000+) or a buffer that rdpq.set_texture_image can writeback." \
                $call
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
proc pak::semantic_check {program {filename ""} {backend "c"}} {
    set chk [pak::Checker new $filename $backend]
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
