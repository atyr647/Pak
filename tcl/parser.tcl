# tcl/parser.tcl — Pak parser, Tcl port of pak/parser.py (incremental).
#
# Builds the tagged-value AST from tcl/ast.tcl. Validated for structural parity
# against the Python parser via tcl/tools/ast_parity.sh. Constructs not yet
# ported raise a parse error (the harness then reports that file as unported).

set _here [file dirname [file normalize [info script]]]
source [file join $_here lexer.tcl]
source [file join $_here ast.tcl]

namespace eval pak {}

oo::class create pak::Parser {
    variable toks pos

    constructor {tokens} {
        set toks $tokens
        set pos 0
    }

    # ── token helpers ─────────────────────────────────────────────────────────
    method peek {{off 0}} {
        set i [expr {$pos + $off}]
        if {$i < [llength $toks]} { return [lindex $toks $i] }
        return [lindex $toks end]
    }
    method ptype {{off 0}} { return [dict get [my peek $off] type] }
    method pval  {{off 0}} { return [dict get [my peek $off] value] }
    method advance {} {
        set t [lindex $toks $pos]
        if {$pos < [llength $toks] - 1} { incr pos }
        return $t
    }
    method check {args} { return [expr {[my ptype] in $args}] }
    method match {args} {
        if {[my check {*}$args]} { return [my advance] }
        return ""
    }
    method expect {tt} {
        if {[my check $tt]} { return [my advance] }
        set t [my peek]
        return -code error "PARSEERROR\t[dict get $t line]\t[dict get $t col]\tExpected $tt (got [dict get $t type])"
    }

    # ── entry ─────────────────────────────────────────────────────────────────
    method parse {} {
        set decls {}
        while {![my check EOF]} {
            while {[my match SEMICOLON] ne ""} {}
            if {[my check EOF]} break
            lappend decls [my parse_top_level]
        }
        return [pak::N Program decls [pak::Seq $decls]]
    }

    method parse_top_level {} {
        set anns {}
        set cfg ""
        while {[my check ANNOTATION]} {
            set a [dict get [my advance] value]
            if {[string match "@cfg(*" $a]} { set cfg $a } else { lappend anns $a }
        }
        set t [my ptype]
        switch -- $t {
            USE     { set decl [my parse_use] }
            ASSET   { set decl [my parse_asset] }
            MODULE  { set decl [my parse_module] }
            STRUCT  { set decl [my parse_struct $anns] }
            ENUM    { set decl [my parse_enum $anns] }
            VARIANT { set decl [my parse_variant $anns] }
            FN      { set decl [my parse_fn $anns] }
            ENTRY   { set decl [my parse_entry] }
            EXTERN  { set decl [my parse_extern] }
            STATIC  { set decl [my parse_static $anns] }
            LET     { set decl [my parse_let $anns] }
            IMPL    { set decl [my parse_impl] }
            CONST   { set decl [my parse_const] }
            TRAIT   { set decl [my parse_trait $anns] }
            UNION   { set decl [my parse_union $anns] }
            COMPTIME {
                my advance; my expect IF; my expect LPAREN
                set cond [my parse_expr]; my expect RPAREN
                set then [my parse_decl_block]
                set elseb [pak::Nil]
                if {[my match ELSE] ne ""} { set elseb [my parse_decl_block] }
                set decl [pak::N ComptimeIf condition $cond then $then else_branch $elseb]
            }
            default {
                set tk [my peek]
                return -code error "PARSEERROR\t[dict get $tk line]\t[dict get $tk col]\tUnported/unexpected top-level (got $t)"
            }
        }
        if {$cfg ne "" && $decl ne ""} {
            set fs [string trim [string range $cfg 5 end-1]]
            set neg 0
            if {[string match "not(*" $fs]} { set neg 1; set fs [string trim [string range $fs 4 end-1]] }
            set decl [pak::N CfgBlock feature [pak::Lit $fs] negated [pak::Bool $neg] decl $decl]
        }
        return $decl
    }

    method parse_generic_params {} {
        # Returns a Tcl list of plain param-name strings, or {} if not generics.
        if {![my check LT]} { return {} }
        set i [expr {$pos + 1}]
        set ok 0
        while {$i < [llength $toks]} {
            set tt [dict get [lindex $toks $i] type]
            if {$tt eq "IDENT"} { incr i } \
            elseif {$tt eq "COMMA"} { incr i } \
            elseif {$tt eq "GT"} { set ok 1; break } \
            else { return {} }
        }
        if {!$ok} { return {} }
        my advance
        set res {}
        while {![my check GT] && ![my check EOF]} {
            lappend res [dict get [my expect IDENT] value]
            my match COMMA
        }
        my expect GT
        return $res
    }

    method parse_use {} {
        my expect USE
        set path [my parse_dotted_name]
        set alias [pak::Nil]
        if {[my match AS] ne ""} { set alias [pak::Lit [dict get [my expect IDENT] value]] }
        return [pak::N UseDecl path [pak::Lit $path] alias $alias]
    }
    method parse_dotted_name {} {
        set parts [list [dict get [my expect IDENT] value]]
        while {[my check DOT]} {
            my advance
            lappend parts [dict get [my expect IDENT] value]
        }
        return [join $parts "."]
    }

    method parse_const {} {
        my expect CONST
        set name [dict get [my expect IDENT] value]
        set typ [pak::Nil]
        if {[my match COLON] ne ""} { set typ [my parse_type] }
        my expect EQ
        set val [my parse_expr]
        my match SEMICOLON
        return [pak::N ConstDecl name [pak::Lit $name] type $typ value $val]
    }
    method parse_static {anns} {
        my expect STATIC
        set name [dict get [my expect IDENT] value]
        set typ [pak::Nil]
        if {[my match COLON] ne ""} { set typ [my parse_type] }
        set val [pak::Nil]
        if {[my match EQ] ne ""} { set val [my parse_expr] }
        return [pak::N StaticDecl annotations [my ann_seq $anns] name [pak::Lit $name] type $typ value $val]
    }
    method parse_let {anns} {
        my expect LET
        set mutable [pak::Nil]
        if {[my match MUT] ne ""} { set mutable [pak::Lit mut] }
        set name [dict get [my expect IDENT] value]
        set typ [pak::Nil]
        if {[my match COLON] ne ""} { set typ [my parse_type] }
        set val [pak::Nil]
        if {[my match EQ] ne ""} { set val [my parse_expr] }
        return [pak::N LetDecl name [pak::Lit $name] type $typ value $val mutable $mutable annotations [my ann_seq $anns]]
    }

    method ann_seq {anns} {
        set items {}
        foreach a $anns { lappend items [pak::Lit $a] }
        return [pak::Seq $items]
    }

    method parse_fn {anns} {
        my expect FN
        set name [dict get [my expect IDENT] value]
        set tparams [my parse_generic_params]
        my expect LPAREN
        set params {}
        set variadic 0
        while {![my check RPAREN] && ![my check EOF]} {
            if {[my match ELLIPSIS] ne ""} { set variadic 1; break }
            set mut 0
            if {[my match MUT] ne ""} { set mut 1 }
            if {[my check SELF]} { set pname [dict get [my advance] value] } else { set pname [dict get [my expect IDENT] value] }
            my expect COLON
            set ptype [my parse_type]
            set dv [pak::Nil]
            if {[my match EQ] ne ""} { set dv [my parse_expr] }
            lappend params [pak::N Param name [pak::Lit $pname] type $ptype mutable [pak::Bool $mut] default_value $dv]
            my match COMMA
        }
        my expect RPAREN
        set ret [pak::Nil]
        if {[my match ARROW] ne ""} { set ret [my parse_type] }
        set body [pak::Nil]
        if {[my check LBRACE]} { set body [my parse_block] }
        set is_method 0
        set self_type [pak::Nil]
        if {[llength $params] > 0} {
            set p0f [lindex [lindex $params 0] 2]
            if {[lindex [dict get $p0f name] 1] eq "self"} {
                set is_method 1
                set pt [dict get $p0f type]
                if {[lindex $pt 0] eq "node"} {
                    set k [lindex $pt 1]
                    if {$k eq "TypePointer"} {
                        set innr [dict get [lindex $pt 2] inner]
                        if {[lindex $innr 0] eq "node" && [lindex $innr 1] eq "TypeName"} {
                            set self_type [dict get [lindex $innr 2] name]
                        }
                    } elseif {$k eq "TypeName"} {
                        set self_type [dict get [lindex $pt 2] name]
                    }
                }
            }
        }
        set tpseq {}
        foreach tp $tparams { lappend tpseq [pak::Lit $tp] }
        return [pak::N FnDecl name [pak::Lit $name] params [pak::Seq $params] ret_type $ret \
            body $body type_params [pak::Seq $tpseq] annotations [my ann_seq $anns] \
            is_method [pak::Bool $is_method] self_type $self_type variadic [pak::Bool $variadic]]
    }

    method parse_entry {} {
        my expect ENTRY
        return [pak::N EntryBlock body [my parse_block]]
    }

    method parse_extern {} {
        my expect EXTERN
        if {[my check CONST]} {
            my advance
            set name [dict get [my expect IDENT] value]
            my expect COLON
            set typ [my parse_type]
            my match SEMICOLON
            return [pak::N ExternConst name [pak::Lit $name] type $typ]
        }
        set abi [dict get [my expect STRING] value]
        my expect LBRACE
        set decls {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann {}
            while {[my check ANNOTATION]} { lappend ann [dict get [my advance] value] }
            if {[my check FN]} {
                lappend decls [my parse_fn $ann]
            } elseif {[my check STATIC]} {
                lappend decls [my parse_static $ann]
            } else {
                my advance
            }
        }
        my expect RBRACE
        return [pak::N ExternBlock abi [pak::Lit $abi] decls [pak::Seq $decls]]
    }

    method parse_decl_block {} {
        my expect LBRACE
        set decls {}
        while {![my check RBRACE] && ![my check EOF]} {
            while {[my match SEMICOLON] ne ""} {}
            if {[my check RBRACE] || [my check EOF]} break
            lappend decls [my parse_top_level]
        }
        my expect RBRACE
        return [pak::N Block stmts [pak::Seq $decls]]
    }

    method parse_asset {} {
        my expect ASSET
        set name [dict get [my expect IDENT] value]
        set atype [pak::Nil]
        if {[my match COLON] ne ""} { set atype [pak::Lit [dict get [my expect IDENT] value]] }
        my expect FROM
        set path [dict get [my expect STRING] value]
        return [pak::N AssetDecl name [pak::Lit $name] asset_type $atype path [pak::Lit $path]]
    }
    method parse_module {} {
        my expect MODULE
        return [pak::N ModuleDecl path [pak::Lit [my parse_dotted_name]]]
    }

    method parse_struct {anns} {
        my expect STRUCT
        set name [dict get [my expect IDENT] value]
        set tparams [my parse_generic_params]
        my expect LBRACE
        set fields {}
        while {![my check RBRACE] && ![my check EOF]} {
            set fann {}
            while {[my check ANNOTATION]} { lappend fann [dict get [my advance] value] }
            set fname [dict get [my expect IDENT] value]
            my expect COLON
            set ftype [my parse_type]
            set bw [pak::Nil]
            if {[my check COLON]} {
                set save $pos
                my advance
                if {[my check INT]} { set bw [pak::Lit [pak::intval [dict get [my advance] value]]] } else { set pos $save }
            }
            set dv [pak::Nil]
            if {[my match EQ] ne ""} { set dv [my parse_expr] }
            my match COMMA
            lappend fields [pak::N StructField name [pak::Lit $fname] type $ftype \
                annotations [my ann_seq $fann] default_value $dv bit_width $bw]
        }
        my expect RBRACE
        return [pak::N StructDecl name [pak::Lit $name] fields [pak::Seq $fields] \
            type_params [my tp_seq $tparams] annotations [my ann_seq $anns]]
    }

    method parse_enum {anns} {
        my expect ENUM
        set name [dict get [my expect IDENT] value]
        set base [pak::Nil]
        if {[my match COLON] ne ""} { set base [pak::Lit [dict get [my expect IDENT] value]] }
        my expect LBRACE
        set variants {}
        while {![my check RBRACE] && ![my check EOF]} {
            set vname [dict get [my expect_name] value]
            set val [pak::Nil]
            if {[my match EQ] ne ""} { set val [my parse_expr] }
            my match COMMA
            lappend variants [pak::N EnumVariant name [pak::Lit $vname] value $val]
        }
        my expect RBRACE
        return [pak::N EnumDecl name [pak::Lit $name] base_type $base variants [pak::Seq $variants] annotations [my ann_seq $anns]]
    }

    method parse_variant {anns} {
        my expect VARIANT
        set name [dict get [my expect IDENT] value]
        my expect LBRACE
        set cases {}
        while {![my check RBRACE] && ![my check EOF]} {
            set cname [dict get [my expect_name] value]
            set cfields {}
            if {[my match LPAREN] ne ""} {
                while {![my check RPAREN] && ![my check EOF]} {
                    lappend cfields [my parse_type]
                    my match COMMA
                }
                my expect RPAREN
            } elseif {[my check LBRACE]} {
                my advance
                while {![my check RBRACE] && ![my check EOF]} {
                    set fn [dict get [my expect IDENT] value]
                    my expect COLON
                    set ft [my parse_type]
                    my match COMMA
                    lappend cfields [pak::Seq [list [pak::Lit $fn] $ft]]
                }
                my expect RBRACE
            }
            my match COMMA
            lappend cases [pak::N VariantCase name [pak::Lit $cname] fields [pak::Seq $cfields]]
        }
        my expect RBRACE
        return [pak::N VariantDecl name [pak::Lit $name] cases [pak::Seq $cases] annotations [my ann_seq $anns]]
    }

    method method_fixup {m type_name} {
        # set is_method=#t and default self_type to the impl type
        set mf [lindex $m 2]
        dict set mf is_method [pak::Bool 1]
        if {[lindex [dict get $mf self_type] 0] eq "nil"} { dict set mf self_type [pak::Lit $type_name] }
        return [list node FnDecl $mf]
    }

    method parse_impl {} {
        my expect IMPL
        set type_name [dict get [my expect IDENT] value]
        set tparams [my parse_generic_params]
        if {[my match FOR] ne ""} {
            set trait [dict get [my expect IDENT] value]
            my expect LBRACE
            set methods {}
            while {![my check RBRACE] && ![my check EOF]} {
                set ann {}
                while {[my check ANNOTATION]} { lappend ann [dict get [my advance] value] }
                if {[my check FN]} { lappend methods [my method_fixup [my parse_fn $ann] $type_name] } else { my advance }
            }
            my expect RBRACE
            return [pak::N ImplTraitBlock type_name [pak::Lit $type_name] trait_name [pak::Lit $trait] \
                methods [pak::Seq $methods] type_params [my tp_seq $tparams]]
        }
        my expect LBRACE
        set methods {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann {}
            while {[my check ANNOTATION]} { lappend ann [dict get [my advance] value] }
            if {[my check FN]} { lappend methods [my method_fixup [my parse_fn $ann] $type_name] } else { my advance }
        }
        my expect RBRACE
        return [pak::N ImplBlock type_name [pak::Lit $type_name] type_params [my tp_seq $tparams] methods [pak::Seq $methods]]
    }

    method parse_trait {anns} {
        my expect TRAIT
        set name [dict get [my expect IDENT] value]
        my expect LBRACE
        set methods {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann {}
            while {[my check ANNOTATION]} { lappend ann [dict get [my advance] value] }
            if {[my check FN]} { lappend methods [my parse_fn $ann] } else { my advance }
        }
        my expect RBRACE
        return [pak::N TraitDecl name [pak::Lit $name] methods [pak::Seq $methods] annotations [my ann_seq $anns]]
    }

    method parse_union {anns} {
        my expect UNION
        set name [dict get [my expect IDENT] value]
        my expect LBRACE
        set fields {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann {}
            while {[my check ANNOTATION]} { lappend ann [dict get [my advance] value] }
            if {[my check FN]} break
            if {[my check IDENT]} {
                set fn [dict get [my advance] value]
                my expect COLON
                set ft [my parse_type]
                lappend fields [pak::N StructField name [pak::Lit $fn] type $ft \
                    annotations [my ann_seq $ann] default_value [pak::Nil] bit_width [pak::Nil]]
            }
            if {[my match COMMA] eq ""} { my match SEMICOLON }
        }
        my expect RBRACE
        return [pak::N UnionDecl name [pak::Lit $name] fields [pak::Seq $fields] annotations [my ann_seq $anns]]
    }

    method tp_seq {tparams} {
        set items {}
        foreach tp $tparams { lappend items [pak::Lit $tp] }
        return [pak::Seq $items]
    }

    # ── types ─────────────────────────────────────────────────────────────────
    method parse_type {} {
        if {[my check LPAREN]} {
            my advance
            if {[my check RPAREN]} { my advance; return [pak::N TypeTuple elements [pak::Seq {}]] }
            set first [my parse_type]
            if {[my check COMMA]} {
                set els [list $first]
                while {[my match COMMA] ne ""} {
                    if {[my check RPAREN]} break
                    lappend els [my parse_type]
                }
                my expect RPAREN
                return [pak::N TypeTuple elements [pak::Seq $els]]
            }
            my expect RPAREN
            return $first
        }
        if {[my check DYN]} {
            my advance
            return [pak::N TypeDynTrait name [pak::Lit [dict get [my expect IDENT] value]]]
        }
        if {[my match QUESTION] ne ""} {
            if {[my check STAR]} {
                my advance
                return [pak::N TypePointer inner [my parse_type] nullable [pak::Bool 1] mutable [pak::Bool 0]]
            }
            return [pak::N TypeOption inner [my parse_type]]
        }
        if {[my check VOLATILE]} {
            my advance
            return [pak::N TypeVolatile inner [my parse_type]]
        }
        if {[my match STAR] ne ""} {
            set vol 0; if {[my match VOLATILE] ne ""} { set vol 1 }
            set mut 0; if {[my match MUT] ne ""} { set mut 1 }
            set ptr [pak::N TypePointer inner [my parse_type] nullable [pak::Bool 0] mutable [pak::Bool $mut]]
            if {$vol} { return [pak::N TypeVolatile inner $ptr] }
            return $ptr
        }
        if {[my check LBRACKET]} {
            my advance
            if {[my check RBRACKET]} {
                my advance
                set mut 0; if {[my match MUT] ne ""} { set mut 1 }
                return [pak::N TypeSlice inner [my parse_type] mutable [pak::Bool $mut]]
            }
            set save $pos
            if {![catch {
                set inner [my parse_type]
                if {[my check SEMICOLON]} {
                    my advance
                    set size [my parse_expr]
                    my expect RBRACKET
                    set rust_arr [pak::N TypeArray size $size inner $inner]
                } else { set pos $save; set rust_arr "" }
            }] && $rust_arr ne ""} { return $rust_arr }
            set pos $save
            set size [my parse_expr]
            my expect RBRACKET
            return [pak::N TypeArray size $size inner [my parse_type]]
        }
        if {[my check FN]} {
            my advance
            my expect LPAREN
            set params {}
            while {![my check RPAREN] && ![my check EOF]} {
                lappend params [my parse_type]
                my match COMMA
            }
            my expect RPAREN
            set ret [pak::Nil]
            if {[my match ARROW] ne ""} { set ret [my parse_type] }
            return [pak::N TypeFn params [pak::Seq $params] ret $ret]
        }
        set name [dict get [my expect IDENT] value]
        while {[my check DOT]} { my advance; append name "." [dict get [my expect IDENT] value] }
        if {$name eq "Result" && [my check LPAREN]} {
            my advance
            set ok [my parse_type]; my expect COMMA; set err [my parse_type]; my expect RPAREN
            return [pak::N TypeResult ok $ok err $err]
        }
        if {$name eq "Option" && [my check LPAREN]} {
            my advance; set inner [my parse_type]; my expect RPAREN
            return [pak::N TypeOption inner $inner]
        }
        if {$name in {FixedList RingBuffer FixedMap Pool Vec} && [my check LPAREN]} {
            my advance
            set args {}
            while {![my check RPAREN] && ![my check EOF]} {
                if {[my check INT]} {
                    set r [dict get [my advance] value]
                    lappend args [pak::N IntLit value [pak::Lit [pak::intval $r]] raw [pak::Lit $r]]
                } else {
                    lappend args [my parse_type]
                }
                my match COMMA
            }
            my expect RPAREN
            return [pak::N TypeGeneric name [pak::Lit $name] args [pak::Seq $args]]
        }
        if {[my check LT]} {
            set targs [my try_type_args]
            if {$targs ne "NONE"} {
                return [pak::N TypeGeneric name [pak::Lit $name] args [pak::Seq $targs]]
            }
        }
        return [pak::N TypeName name [pak::Lit $name]]
    }

    method try_type_args {} {
        # Returns a Tcl list of type tagged-values, or the sentinel "NONE".
        set i [expr {$pos + 1}]
        set depth 1
        while {$i < [llength $toks] && $depth > 0} {
            set tt [dict get [lindex $toks $i] type]
            if {$tt eq "LT"} { incr depth } \
            elseif {$tt eq "GT"} { incr depth -1 } \
            elseif {$tt in {LBRACE RBRACE SEMICOLON EOF}} { return "NONE" }
            incr i
        }
        if {$depth != 0} { return "NONE" }
        set save $pos
        my advance
        set args {}
        if {[catch {
            while {![my check GT] && ![my check EOF]} {
                lappend args [my parse_type]
                my match COMMA
            }
            my expect GT
        }]} { set pos $save; return "NONE" }
        return $args
    }
    method expect_name {} {
        set t [my peek]
        if {[dict get $t type] eq "IDENT"} { return [my advance] }
        # allow keywords as names
        if {[dict exists $::pak::KEYWORDS [dict get $t value]]} { return [my advance] }
        return -code error "PARSEERROR\t[dict get $t line]\t[dict get $t col]\tExpected identifier (got [dict get $t type])"
    }

    # ── statements ──────────────────────────────────────────────────────────────
    method parse_block {} {
        my expect LBRACE
        set stmts {}
        while {![my check RBRACE] && ![my check EOF]} {
            while {[my match SEMICOLON] ne ""} {}
            if {[my check RBRACE] || [my check EOF]} break
            lappend stmts [my parse_stmt]
        }
        my expect RBRACE
        return [pak::N Block stmts [pak::Seq $stmts]]
    }

    method parse_stmt {} {
        set anns {}
        while {[my check ANNOTATION]} { lappend anns [dict get [my advance] value] }
        set t [my ptype]
        switch -- $t {
            LET     { return [my parse_let $anns] }
            STATIC  { return [my parse_static $anns] }
            CONST   { return [my parse_const] }
            RETURN  {
                my advance
                set v [pak::Nil]
                if {![my check RBRACE] && ![my check EOF]} { set v [my parse_expr] }
                return [pak::N Return value $v]
            }
            BREAK    { my advance; return [pak::N Break value [pak::Nil]] }
            CONTINUE { my advance; return [pak::N Continue] }
            IF       { return [my parse_if] }
            LOOP     { my advance; return [pak::N LoopStmt body [my parse_block]] }
            WHILE    { my advance; set c [my parse_expr]; return [pak::N WhileStmt condition $c body [my parse_block]] }
            DEFER    { my advance; return [pak::N DeferStmt body [my parse_block]] }
            FOR      { return [my parse_for] }
            MATCH    { return [my parse_match] }
            STRUCT   { return [my parse_struct $anns] }
            ENUM     { return [my parse_enum $anns] }
            VARIANT  { return [my parse_variant $anns] }
            ASM      { return [my parse_asm_stmt] }
            GOTO     { my advance; return [pak::N GotoStmt label [pak::Lit [dict get [my expect IDENT] value]]] }
            DO {
                my advance
                set body [my parse_block]
                my expect WHILE
                set c [my parse_expr]
                return [pak::N DoWhileStmt body $body condition $c]
            }
            COMPTIME {
                my advance; my expect IF; my expect LPAREN
                set cond [my parse_expr]; my expect RPAREN
                set then [my parse_block]
                set elseb [pak::Nil]
                if {[my match ELSE] ne ""} { set elseb [my parse_block] }
                return [pak::N ComptimeIf condition $cond then $then else_branch $elseb]
            }
            default {
                if {$t eq "IDENT" && [my ptype 1] eq "COLON" && [my ptype 2] ne "COLON"} {
                    set ln [dict get [my advance] value]
                    my advance
                    return [pak::N LabelStmt name [pak::Lit $ln]]
                }
                return [pak::N ExprStmt expr [my parse_expr]]
            }
        }
    }

    method parse_if {} {
        my expect IF
        set cond [my parse_expr]
        if {[my match ARROW] ne ""} {
            set binding [dict get [my expect IDENT] value]
            set then [my parse_block]
            set elseb [pak::Nil]
            if {[my match ELSE] ne ""} { set elseb [my parse_block] }
            return [pak::N NullCheckStmt expr $cond binding [pak::Lit $binding] then $then else_branch $elseb]
        }
        set then [my parse_block]
        set elifs {}
        set elseb [pak::Nil]
        while {[my check ELSE] || [my check ELIF]} {
            if {[my check ELIF]} {
                my advance
                set ec [my parse_expr]; set eb [my parse_block]
                lappend elifs [pak::Seq [list $ec $eb]]
            } else {
                my advance
                if {[my check IF]} {
                    my advance
                    set ec [my parse_expr]; set eb [my parse_block]
                    lappend elifs [pak::Seq [list $ec $eb]]
                } elseif {[my check ELIF]} {
                    my advance
                    set ec [my parse_expr]; set eb [my parse_block]
                    lappend elifs [pak::Seq [list $ec $eb]]
                } else {
                    set elseb [my parse_block]
                    break
                }
            }
        }
        return [pak::N IfStmt condition $cond then $then elif_branches [pak::Seq $elifs] else_branch $elseb]
    }

    method parse_for {} {
        my expect FOR
        set first [dict get [my expect IDENT] value]
        set index [pak::Nil]
        set binding $first
        if {[my match COMMA] ne ""} {
            set index [pak::Lit $first]
            set binding [dict get [my expect IDENT] value]
        }
        my expect IN
        set iter [my parse_expr]
        set body [my parse_block]
        return [pak::N ForStmt index $index binding [pak::Lit $binding] iterable $iter body $body]
    }

    method parse_match {} {
        my expect MATCH
        set expr [my parse_expr]
        my expect LBRACE
        set arms {}
        while {![my check RBRACE] && ![my check EOF]} {
            lappend arms [my parse_match_arm]
            my match COMMA
        }
        my expect RBRACE
        return [pak::N MatchStmt expr $expr arms [pak::Seq $arms]]
    }

    method parse_match_arm {} {
        set pat [my parse_pattern]
        my expect FAT_ARROW
        if {[my check LBRACE]} {
            set body [my parse_block]
        } else {
            set body [pak::N Block stmts [pak::Seq [list [my parse_stmt]]]]
        }
        return [pak::N MatchArm pattern $pat guard [pak::Nil] body $body]
    }

    method parse_pattern {} {
        if {[my check DOT]} {
            my advance
            set name [dict get [my expect_name] value]
            if {[my check LPAREN]} {
                my advance
                set args {}
                while {![my check RPAREN]} {
                    if {[my check IDENT]} {
                        lappend args [pak::N Ident name [pak::Lit [dict get [my advance] value]] type_args [pak::Seq {}]]
                    } elseif {[my check UNDERSCORE]} {
                        my advance
                        lappend args [pak::N Ident name [pak::Lit "_"] type_args [pak::Seq {}]]
                    }
                    if {[my check COMMA]} { my advance }
                }
                my expect RPAREN
                return [pak::N Call func [pak::N EnumVariantAccess name [pak::Lit $name]] args [pak::Seq $args] type_args [pak::Seq {}]]
            }
            return [pak::N EnumVariantAccess name [pak::Lit $name]]
        } elseif {[my check UNDERSCORE]} {
            my advance
            return [pak::N Ident name [pak::Lit "_"] type_args [pak::Seq {}]]
        } elseif {[my check INT]} {
            set r [dict get [my advance] value]
            return [pak::N IntLit value [pak::Lit [pak::intval $r]] raw [pak::Lit $r]]
        } elseif {[my check STRING]} {
            return [pak::N StringLit value [pak::Lit [dict get [my advance] value]]]
        } elseif {[my check IDENT]} {
            set name [dict get [my advance] value]
            if {[my check DOT]} {
                my advance
                set variant [dict get [my expect IDENT] value]
                set binding [pak::Nil]
                if {[my check LPAREN]} {
                    my advance
                    if {![my check RPAREN]} { set binding [pak::Lit [dict get [my expect IDENT] value]] }
                    my expect RPAREN
                }
                return [pak::N DotAccess obj [pak::N Ident name [pak::Lit $name] type_args [pak::Seq {}]] field [pak::Lit $variant] binding $binding]
            }
            return [pak::N Ident name [pak::Lit $name] type_args [pak::Seq {}]]
        } elseif {[my check TRUE]} {
            my advance; return [pak::N BoolLit value [pak::Bool 1]]
        } elseif {[my check FALSE]} {
            my advance; return [pak::N BoolLit value [pak::Bool 0]]
        } else {
            return [my parse_expr]
        }
    }

    method parse_asm_stmt {} {
        my expect ASM
        set vol 0; if {[my match VOLATILE] ne ""} { set vol 1 }
        my expect LBRACE
        set lines {}
        while {![my check RBRACE] && ![my check EOF]} {
            if {[my check STRING]} {
                lappend lines [pak::Lit [dict get [my advance] value]]
            } elseif {[my check SEMICOLON]} {
                my advance
            } else {
                my advance
            }
        }
        my expect RBRACE
        return [pak::N AsmStmt lines [pak::Seq $lines] volatile [pak::Bool $vol]]
    }

    # ── expressions (precedence) ─────────────────────────────────────────────────
    method parse_expr {} { return [my parse_assign] }

    method parse_assign {} {
        set left [my parse_catch]
        if {[my check EQ]} {
            my advance
            set right [my parse_assign]
            return [pak::N Assign target $left value $right op [pak::Lit "="]]
        }
        foreach {tt opstr} {PLUS_EQ += MINUS_EQ -= STAR_EQ *= SLASH_EQ /= PERCENT_EQ %= SHL_EQ <<= SHR_EQ >>= AMP_EQ &= PIPE_EQ |= CARET_EQ ^=} {
            if {[my match $tt] ne ""} {
                set right [my parse_assign]
                return [pak::N Assign target $left value $right op [pak::Lit $opstr]]
            }
        }
        return $left
    }

    method parse_catch {} {
        set expr [my parse_or]
        if {[my match CATCH] ne ""} {
            set binding [pak::Nil]
            if {[my check PIPE]} {
                my advance
                set binding [pak::Lit [dict get [my expect IDENT] value]]
                my expect PIPE
            } elseif {[my check IDENT] && [my ptype 1] eq "LBRACE"} {
                set binding [pak::Lit [dict get [my advance] value]]
            }
            set handler [my parse_block]
            return [pak::N CatchExpr expr $expr binding $binding handler $handler]
        }
        return $expr
    }

    method binop_chain {next types} {
        set left [my $next]
        while {[my check {*}[dict keys $types]]} {
            set op [dict get $types [my ptype]]
            my advance
            set right [my $next]
            set left [pak::N BinaryOp op [pak::Lit $op] left $left right $right]
        }
        return $left
    }

    method parse_or  {} { return [my binop_chain parse_and    {OR ||}] }
    method parse_and {} { return [my binop_chain parse_bitor  {AND &&}] }
    method parse_bitor  {} { return [my binop_chain parse_bitxor {PIPE |}] }
    method parse_bitxor {} { return [my binop_chain parse_bitand {CARET ^}] }
    method parse_bitand {} { return [my binop_chain parse_eq    {AMP &}] }
    method parse_eq  {} { return [my binop_chain parse_cmp   {EQEQ == NEQ !=}] }
    method parse_cmp {} { return [my binop_chain parse_shift {LT < GT > LTE <= GTE >=}] }
    method parse_shift {} { return [my binop_chain parse_add {SHL << SHR >>}] }
    method parse_add {} { return [my binop_chain parse_mul {PLUS + MINUS -}] }
    method parse_mul {} { return [my binop_chain parse_unary {STAR * SLASH / PERCENT %}] }

    method parse_unary {} {
        if {[my match BANG] ne "" || ([my check NOT] && [my advance] ne "")} {
            return [pak::N UnaryOp op [pak::Lit "!"] operand [my parse_unary]]
        }
        if {[my match MINUS] ne ""} { return [pak::N UnaryOp op [pak::Lit "-"] operand [my parse_unary]] }
        if {[my match AMP] ne ""} {
            set mut 0
            if {[my match MUT] ne ""} { set mut 1 }
            return [pak::N AddrOf expr [my parse_unary] mutable [pak::Bool $mut]]
        }
        if {[my match STAR] ne ""} { return [pak::N Deref expr [my parse_unary]] }
        return [my parse_cast]
    }

    method parse_cast {} {
        set expr [my parse_postfix]
        if {[my match AS] ne ""} {
            return [pak::N Cast expr $expr type [my parse_type]]
        }
        return $expr
    }

    method parse_postfix {} {
        set expr [my parse_primary]
        while {1} {
            if {[my check DOT]} {
                if {[my ptype 1] eq "IDENT" && [my ptype 2] eq "FAT_ARROW"} break
                my advance
                if {[my check INT]} {
                    set idx [dict get [my advance] value]
                    set expr [pak::N TupleAccess obj $expr index [pak::Lit [pak::intval $idx]]]
                } else {
                    set fld [dict get [my expect_name] value]
                    set expr [pak::N DotAccess obj $expr field [pak::Lit $fld] binding [pak::Nil]]
                }
            } elseif {[my check LPAREN]} {
                my advance
                set args {}
                while {![my check RPAREN] && ![my check EOF]} {
                    if {[my check IDENT] && [my ptype 1] eq "COLON"} {
                        set an [dict get [my advance] value]
                        my advance
                        set av [my parse_expr]
                        lappend args [pak::N NamedArg name [pak::Lit $an] value $av]
                    } else {
                        lappend args [my parse_expr]
                    }
                    my match COMMA
                }
                my expect RPAREN
                set targs [pak::Seq {}]
                if {[lindex $expr 0] eq "node" && [lindex $expr 1] eq "Ident"} {
                    set targs [dict get [lindex $expr 2] type_args]
                    # consume: rebuild ident with empty type_args
                    set f [lindex $expr 2]
                    dict set f type_args [pak::Seq {}]
                    set expr [list node Ident $f]
                }
                set expr [pak::N Call func $expr args [pak::Seq $args] type_args $targs]
            } elseif {[my check LBRACKET]} {
                my advance
                set idx [my parse_expr]
                if {[lindex $idx 0] eq "node" && [lindex $idx 1] eq "RangeExpr"} {
                    my expect RBRACKET
                    set f [lindex $idx 2]
                    set expr [pak::N SliceExpr obj $expr start [dict get $f start] end [dict get $f end]]
                } elseif {[my check DOTDOT]} {
                    my advance
                    set end [pak::Nil]
                    if {![my check RBRACKET]} { set end [my parse_expr] }
                    my expect RBRACKET
                    set expr [pak::N SliceExpr obj $expr start $idx end $end]
                } else {
                    my expect RBRACKET
                    set expr [pak::N IndexAccess obj $expr index $idx]
                }
            } else break
        }
        return $expr
    }

    method parse_primary {} {
        set t [my ptype]
        switch -- $t {
            INT {
                set raw [dict get [my advance] value]
                set lit [pak::N IntLit value [pak::Lit [pak::intval $raw]] raw [pak::Lit $raw]]
                if {[my check DOTDOT]} {
                    my advance
                    set end [pak::Nil]
                    if {![my check RBRACE] && ![my check COMMA] && ![my check RPAREN] && ![my check RBRACKET]} { set end [my parse_primary] }
                    return [pak::N RangeExpr start $lit end $end]
                }
                return $lit
            }
            FLOAT {
                set raw [dict get [my advance] value]
                return [pak::N FloatLit value [pak::Fnum $raw] raw [pak::Lit ""]]
            }
            STRING {
                set v [dict get [my advance] value]
                return [my string_or_fmt $v]
            }
            TRUE  { my advance; return [pak::N BoolLit value [pak::Bool 1]] }
            FALSE { my advance; return [pak::N BoolLit value [pak::Bool 0]] }
            NONE  { my advance; return [pak::N NoneLit] }
            UNDEFINED { my advance; return [pak::N UndefinedLit] }
            UNDERSCORE { my advance; return [pak::N Ident name [pak::Lit "_"] type_args [pak::Seq {}]] }
            SELF  { my advance; return [pak::N Ident name [pak::Lit "self"] type_args [pak::Seq {}]] }
            OK    { my advance; my expect LPAREN; set v [my parse_expr]; my expect RPAREN; return [pak::N OkExpr value $v] }
            ERR   { my advance; my expect LPAREN; set v [my parse_expr]; my expect RPAREN; return [pak::N ErrExpr value $v] }
            ALIGNOF {
                my advance; my expect LPAREN
                set save $pos
                if {[catch { set op [my parse_type]; if {![my check RPAREN]} { error x } }]} { set pos $save; set op [my parse_expr] }
                my expect RPAREN
                return [pak::N AlignOf operand $op]
            }
            SIZEOF {
                my advance; my expect LPAREN
                set save $pos
                if {[catch { set op [my parse_type]; if {![my check RPAREN]} { error x } }]} { set pos $save; set op [my parse_expr] }
                my expect RPAREN
                return [pak::N SizeOf operand $op]
            }
            OFFSETOF {
                my advance; my expect LPAREN
                set tn [dict get [my expect IDENT] value]
                my expect COMMA
                set fn [dict get [my expect IDENT] value]
                my expect RPAREN
                return [pak::N OffsetOf type_name [pak::Lit $tn] field [pak::Lit $fn]]
            }
            ALLOC {
                my advance; my expect LPAREN
                set tn [my parse_type]
                set count [pak::Nil]; set alc [pak::Nil]
                if {[my match COMMA] ne ""} {
                    if {!([my check IDENT] && [my pval] eq "using")} { set count [my parse_expr] }
                }
                if {[my check IDENT] && [my pval] eq "using"} { my advance; set alc [my parse_expr] }
                my expect RPAREN
                return [pak::N AllocExpr type_node $tn count $count allocator $alc]
            }
            FREE {
                my advance; my expect LPAREN
                set ptr [my parse_expr]
                set alc [pak::Nil]
                if {[my check IDENT] && [my pval] eq "using"} { my advance; set alc [my parse_expr] }
                my expect RPAREN
                return [pak::N FreeExpr ptr $ptr allocator $alc]
            }
            FN {
                my advance; my expect LPAREN
                set params {}
                while {![my check RPAREN] && ![my check EOF]} {
                    set mut 0; if {[my match MUT] ne ""} { set mut 1 }
                    set pname [dict get [my advance] value]
                    my expect COLON
                    set ptype [my parse_type]
                    lappend params [pak::N Param name [pak::Lit $pname] type $ptype mutable [pak::Bool $mut] default_value [pak::Nil]]
                    my match COMMA
                }
                my expect RPAREN
                set ret [pak::Nil]
                if {[my match ARROW] ne ""} { set ret [my parse_type] }
                set body [my parse_block]
                return [pak::N Closure params [pak::Seq $params] ret_type $ret body $body]
            }
            ASM {
                my advance; my expect LPAREN
                set tmpl [dict get [my expect STRING] value]
                set outs {}; set ins {}; set clob {}
                if {[my match COLON] ne ""} {
                    while {[my check STRING]} {
                        set con [dict get [my advance] value]
                        my expect LPAREN; set e [my parse_expr]; my expect RPAREN
                        lappend outs [pak::Seq [list [pak::Lit $con] $e]]
                        my match COMMA
                    }
                }
                if {[my match COLON] ne ""} {
                    while {[my check STRING]} {
                        set con [dict get [my advance] value]
                        my expect LPAREN; set e [my parse_expr]; my expect RPAREN
                        lappend ins [pak::Seq [list [pak::Lit $con] $e]]
                        my match COMMA
                    }
                }
                if {[my match COLON] ne ""} {
                    while {[my check STRING]} { lappend clob [pak::Lit [dict get [my advance] value]]; my match COMMA }
                }
                my expect RPAREN
                return [pak::N AsmExpr template [pak::Lit $tmpl] outputs [pak::Seq $outs] inputs [pak::Seq $ins] clobbers [pak::Seq $clob] volatile [pak::Bool 1]]
            }
            DOT   { my advance; return [pak::N EnumVariantAccess name [pak::Lit [dict get [my expect IDENT] value]]] }
            LPAREN {
                my advance
                if {[my check RPAREN]} { my advance; return [pak::N TupleLit elements [pak::Seq {}]] }
                set first [my parse_expr]
                if {[my check COMMA]} {
                    set els [list $first]
                    while {[my match COMMA] ne ""} {
                        if {[my check RPAREN]} break
                        lappend els [my parse_expr]
                    }
                    my expect RPAREN
                    return [pak::N TupleLit elements [pak::Seq $els]]
                }
                my expect RPAREN
                return $first
            }
            LBRACKET {
                my advance
                if {[my check RBRACKET]} { my advance; return [pak::N ArrayLit elements [pak::Seq {}] repeat [pak::Nil]] }
                set first [my parse_expr]
                if {[my match SEMICOLON] ne ""} {
                    set cnt [my parse_expr]
                    my expect RBRACKET
                    return [pak::N ArrayLit elements [pak::Seq [list $first]] repeat $cnt]
                }
                set els [list $first]
                while {[my match COMMA] ne ""} {
                    if {[my check RBRACKET]} break
                    lappend els [my parse_expr]
                }
                my expect RBRACKET
                return [pak::N ArrayLit elements [pak::Seq $els] repeat [pak::Nil]]
            }
            IDENT {
                set name [dict get [my advance] value]
                set targs {}
                if {[my check LT]} {
                    set save $pos
                    set targs [my parse_generic_params]
                }
                if {[my check LBRACE] && [my is_struct_lit_ctx]} {
                    my advance
                    set fields {}
                    while {![my check RBRACE] && ![my check EOF]} {
                        set fn [dict get [my expect IDENT] value]
                        my expect COLON
                        set fv [my parse_expr]
                        lappend fields [pak::Seq [list [pak::Lit $fn] $fv]]
                        my match COMMA
                    }
                    my expect RBRACE
                    return [pak::N StructLit type_name [pak::Lit $name] fields [pak::Seq $fields]]
                }
                if {[my check DOTDOT] && [llength $targs] == 0} {
                    my advance
                    set end [pak::Nil]
                    if {![my check RBRACE] && ![my check COMMA] && ![my check RPAREN]} { set end [my parse_primary] }
                    return [pak::N RangeExpr start [pak::N Ident name [pak::Lit $name] type_args [pak::Seq {}]] end $end]
                }
                set taseq [pak::Seq {}]
                if {[llength $targs] > 0 && [my check LPAREN]} {
                    set items {}
                    foreach tp $targs { lappend items [pak::Lit $tp] }
                    set taseq [pak::Seq $items]
                }
                return [pak::N Ident name [pak::Lit $name] type_args $taseq]
            }
            default {
                set tk [my peek]
                return -code error "PARSEERROR\t[dict get $tk line]\t[dict get $tk col]\tUnexpected token in expression (got $t)"
            }
        }
    }

    method is_struct_lit_ctx {} {
        set i $pos
        if {$i >= [llength $toks] || [dict get [lindex $toks $i] type] ne "LBRACE"} { return 0 }
        incr i
        if {$i >= [llength $toks]} { return 0 }
        if {[dict get [lindex $toks $i] type] eq "RBRACE"} { return 0 }
        if {[dict get [lindex $toks $i] type] eq "IDENT" && $i + 1 < [llength $toks] \
                && [dict get [lindex $toks [expr {$i+1}]] type] eq "COLON"} { return 1 }
        return 0
    }

    method string_or_fmt {raw} {
        # Plain string fast-path (matches pak/parser._parse_string_or_fmtstr when no braces).
        if {[string first "\{" $raw] < 0 && [string first "\}" $raw] < 0} {
            return [pak::N StringLit value [pak::Lit $raw]]
        }
        # Escaped-only braces -> plain string with {{->{ }}->}
        set escaped [string map [list "\{\{" "" "\}\}" ""] $raw]
        if {[string first "\{" $escaped] < 0} {
            return [pak::N StringLit value [pak::Lit [string map [list "\{\{" "\{" "\}\}" "\}"] $raw]]]
        }
        # Interpolation (FmtStr) not yet ported.
        return -code error "PARSEERROR\t0\t0\tFmtStr interpolation not yet ported"
    }
}

proc pak::parse_tokens {tokens} {
    set p [pak::Parser new $tokens]
    return [$p parse]
}
