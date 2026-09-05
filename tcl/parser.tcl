# tcl/parser.tcl — Pak parser: tokens → AST.
#
# Builds the tagged-value AST from tcl/ast.tcl. Validated for structural parity
# against the Python parser via tcl/tools/ast_parity.sh. Constructs not yet
# ported raise a parse error (the harness then reports that file as unported).
#
# Field values handed to pak::N are auto-wrapped per the AST schema, so the
# constructor calls read like the Python ones (`name $x`, not `name [pak::Lit
# $x]`). See tcl/ast.tcl / tcl/tools/gen_schema.py for the wrap kinds.

set _here [file dirname [file normalize [info script]]]
source [file join $_here lexer.tcl]
source [file join $_here ast.tcl]

namespace eval pak {}

# Include guard (reachable via multiple consumers; see ast.tcl). Placed after the
# leaf sources above so they still load; prevents redefining pak::Parser.
if {[info exists ::pak::_parser_loaded]} { return }
set ::pak::_parser_loaded 1

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
    # accept: consume the next token if it is one of $args; return 1/0. Replaces
    # the `[my match X] ne ""` idiom so call sites mirror Python's `if match(X):`.
    method accept {args} { return [expr {[my match {*}$args] ne ""}] }
    method expect {tt} {
        if {[my check $tt]} { return [my advance] }
        set t [my peek]
        return -code error "PARSEERROR\t[dict get $t line]\t[dict get $t col]\tExpected $tt (got [dict get $t type])"
    }
    # value-returning variants (mirror Python's `self.expect(...).value`)
    method advancev {}   { return [dict get [my advance] value] }
    method expectv {tt}  { return [dict get [my expect $tt] value] }
    method namev {}      { return [dict get [my expect_name] value] }
    # collect a run of leading annotations as a plain list of @-strings
    method anns {} {
        set a {}
        while {[my check ANNOTATION]} { lappend a [my advancev] }
        return $a
    }

    # ── entry ─────────────────────────────────────────────────────────────────
    method parse {} {
        set decls {}
        while {![my check EOF]} {
            while {[my accept SEMICOLON]} {}
            if {[my check EOF]} break
            lappend decls [my parse_top_level]
        }
        return [pak::N Program decls $decls]
    }

    # ── source positions ──────────────────────────────────────────────────────
    # The three rule levels below bracket their body with the position of the
    # token they start on, so pak::N stamps each node with the start of the
    # construct it belongs to rather than wherever the parse happened to end.
    method at_token {body} {
        set t [my peek]
        pak::pos_push [dict get $t line] [dict get $t col]
        set rc [catch {uplevel 1 $body} result options]
        pak::pos_pop
        return -options $options $result
    }

    method parse_top_level {} { return [my at_token {my parse_top_level_inner}] }
    method parse_stmt {}      { return [my at_token {my parse_stmt_inner}] }
    method parse_primary {}   { return [my at_token {my parse_primary_inner}] }

    method parse_top_level_inner {} {
        set anns {}
        set cfg ""
        while {[my check ANNOTATION]} {
            set a [my advancev]
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
                if {[my accept ELSE]} { set elseb [my parse_decl_block] }
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
            set decl [pak::N CfgBlock feature $fs negated $neg decl $decl]
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
            lappend res [my expectv IDENT]
            my match COMMA
        }
        my expect GT
        return $res
    }

    method parse_use {} {
        my expect USE
        set path [my parse_dotted_name]
        set alias [pak::Nil]
        if {[my accept AS]} { set alias [pak::Lit [my expectv IDENT]] }
        return [pak::N UseDecl path $path alias $alias]
    }
    method parse_dotted_name {} {
        set parts [list [my expectv IDENT]]
        while {[my check DOT]} {
            my advance
            lappend parts [my expectv IDENT]
        }
        return [join $parts "."]
    }

    method parse_const {} {
        my expect CONST
        set name [my expectv IDENT]
        set typ [pak::Nil]
        if {[my accept COLON]} { set typ [my parse_type] }
        my expect EQ
        set val [my parse_expr]
        my match SEMICOLON
        return [pak::N ConstDecl name $name type $typ value $val]
    }
    method parse_static {anns} {
        my expect STATIC
        set name [my expectv IDENT]
        set typ [pak::Nil]
        if {[my accept COLON]} { set typ [my parse_type] }
        set val [pak::Nil]
        if {[my accept EQ]} { set val [my parse_expr] }
        return [pak::N StaticDecl annotations $anns name $name type $typ value $val]
    }
    method parse_let {anns} {
        my expect LET
        set mutable [pak::Nil]
        if {[my accept MUT]} { set mutable [pak::Lit mut] }
        if {[my accept UNDERSCORE]} {
            set name "_"
        } else {
            set name [my expectv IDENT]
        }
        set typ [pak::Nil]
        if {[my accept COLON]} { set typ [my parse_type] }
        set val [pak::Nil]
        if {[my accept EQ]} { set val [my parse_expr] }
        return [pak::N LetDecl name $name type $typ value $val mutable $mutable annotations $anns]
    }

    method parse_fn {anns} {
        my expect FN
        set name [my expectv IDENT]
        set tparams [my parse_generic_params]
        my expect LPAREN
        set params {}
        set variadic 0
        while {![my check RPAREN] && ![my check EOF]} {
            if {[my accept ELLIPSIS]} { set variadic 1; break }
            set mut 0
            if {[my accept MUT]} { set mut 1 }
            if {[my check SELF]} {
                set pname [my advancev]
                if {[my accept COLON]} {
                    set ptype [my parse_type]
                } else {
                    # `self` without a type is `*Self`; impl fixup rewrites Self.
                    set ptype [pak::N TypePointer inner [pak::N TypeName name Self] nullable 0 mutable 0]
                }
            } else {
                set pname [my expectv IDENT]
                my expect COLON
                set ptype [my parse_type]
            }
            set dv [pak::Nil]
            if {[my accept EQ]} { set dv [my parse_expr] }
            lappend params [pak::N Param name $pname type $ptype mutable $mut default_value $dv]
            my match COMMA
        }
        my expect RPAREN
        set ret [pak::Nil]
        if {[my accept ARROW]} { set ret [my parse_type] }
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
        return [pak::N FnDecl name $name params $params ret_type $ret \
            body $body type_params $tparams annotations $anns \
            is_method $is_method self_type $self_type variadic $variadic]
    }

    method parse_entry {} {
        my expect ENTRY
        return [pak::N EntryBlock body [my parse_block]]
    }

    method parse_extern {} {
        my expect EXTERN
        if {[my check CONST]} {
            my advance
            set name [my expectv IDENT]
            my expect COLON
            set typ [my parse_type]
            my match SEMICOLON
            return [pak::N ExternConst name $name type $typ]
        }
        set abi [my expectv STRING]
        my expect LBRACE
        set decls {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann [my anns]
            if {[my check FN]} {
                lappend decls [my parse_fn $ann]
            } elseif {[my check STATIC]} {
                lappend decls [my parse_static $ann]
            } else {
                my advance
            }
        }
        my expect RBRACE
        return [pak::N ExternBlock abi $abi decls $decls]
    }

    method parse_decl_block {} {
        my expect LBRACE
        set decls {}
        while {![my check RBRACE] && ![my check EOF]} {
            while {[my accept SEMICOLON]} {}
            if {[my check RBRACE] || [my check EOF]} break
            lappend decls [my parse_top_level]
        }
        my expect RBRACE
        return [pak::N Block stmts $decls]
    }

    method parse_asset {} {
        my expect ASSET
        set name [my expectv IDENT]
        set atype [pak::Nil]
        if {[my accept COLON]} { set atype [pak::Lit [my expectv IDENT]] }
        my expect FROM
        set path [my expectv STRING]
        return [pak::N AssetDecl name $name asset_type $atype path $path]
    }
    method parse_module {} {
        my expect MODULE
        return [pak::N ModuleDecl path [my parse_dotted_name]]
    }

    method parse_struct {anns} {
        my expect STRUCT
        set name [my expectv IDENT]
        set tparams [my parse_generic_params]
        my expect LBRACE
        set fields {}
        while {![my check RBRACE] && ![my check EOF]} {
            set fann [my anns]
            set fname [my expectv IDENT]
            my expect COLON
            set ftype [my parse_type]
            set bw [pak::Nil]
            if {[my check COLON]} {
                set save $pos
                my advance
                if {[my check INT]} { set bw [pak::Lit [pak::intval [my advancev]]] } else { set pos $save }
            }
            set dv [pak::Nil]
            if {[my accept EQ]} { set dv [my parse_expr] }
            my match COMMA
            lappend fields [pak::N StructField name $fname type $ftype \
                annotations $fann default_value $dv bit_width $bw]
        }
        my expect RBRACE
        return [pak::N StructDecl name $name fields $fields \
            type_params $tparams annotations $anns]
    }

    method parse_enum {anns} {
        my expect ENUM
        set name [my expectv IDENT]
        set base [pak::Nil]
        if {[my accept COLON]} { set base [pak::Lit [my expectv IDENT]] }
        my expect LBRACE
        set variants {}
        while {![my check RBRACE] && ![my check EOF]} {
            set vname [my namev]
            set val [pak::Nil]
            if {[my accept EQ]} { set val [my parse_expr] }
            my match COMMA
            lappend variants [pak::N EnumVariant name $vname value $val]
        }
        my expect RBRACE
        return [pak::N EnumDecl name $name base_type $base variants $variants annotations $anns]
    }

    method parse_variant {anns} {
        my expect VARIANT
        set name [my expectv IDENT]
        my expect LBRACE
        set cases {}
        while {![my check RBRACE] && ![my check EOF]} {
            set cname [my namev]
            set cfields {}
            if {[my accept LPAREN]} {
                while {![my check RPAREN] && ![my check EOF]} {
                    lappend cfields [my parse_type]
                    my match COMMA
                }
                my expect RPAREN
            } elseif {[my check LBRACE]} {
                my advance
                while {![my check RBRACE] && ![my check EOF]} {
                    set fn [my expectv IDENT]
                    my expect COLON
                    set ft [my parse_type]
                    my match COMMA
                    lappend cfields [pak::Seq [list [pak::Lit $fn] $ft]]
                }
                my expect RBRACE
            }
            my match COMMA
            lappend cases [pak::N VariantCase name $cname fields $cfields]
        }
        my expect RBRACE
        return [pak::N VariantDecl name $name cases $cases annotations $anns]
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
        set type_name [my expectv IDENT]
        set tparams [my parse_generic_params]
        if {[my accept FOR]} {
            set trait [my expectv IDENT]
            my expect LBRACE
            set methods {}
            while {![my check RBRACE] && ![my check EOF]} {
                set ann [my anns]
                if {[my check FN]} { lappend methods [my method_fixup [my parse_fn $ann] $type_name] } else { my advance }
            }
            my expect RBRACE
            return [pak::N ImplTraitBlock type_name $type_name trait_name $trait \
                methods $methods type_params $tparams]
        }
        my expect LBRACE
        set methods {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann [my anns]
            if {[my check FN]} { lappend methods [my method_fixup [my parse_fn $ann] $type_name] } else { my advance }
        }
        my expect RBRACE
        return [pak::N ImplBlock type_name $type_name type_params $tparams methods $methods]
    }

    method parse_trait {anns} {
        my expect TRAIT
        set name [my expectv IDENT]
        my expect LBRACE
        set methods {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann [my anns]
            if {[my check FN]} { lappend methods [my parse_fn $ann] } else { my advance }
        }
        my expect RBRACE
        return [pak::N TraitDecl name $name methods $methods annotations $anns]
    }

    method parse_union {anns} {
        my expect UNION
        set name [my expectv IDENT]
        my expect LBRACE
        set fields {}
        while {![my check RBRACE] && ![my check EOF]} {
            set ann [my anns]
            if {[my check FN]} break
            if {[my check IDENT]} {
                set fn [my advancev]
                my expect COLON
                set ft [my parse_type]
                lappend fields [pak::N StructField name $fn type $ft \
                    annotations $ann default_value [pak::Nil] bit_width [pak::Nil]]
            }
            if {![my accept COMMA]} { my match SEMICOLON }
        }
        my expect RBRACE
        return [pak::N UnionDecl name $name fields $fields annotations $anns]
    }

    # ── types ─────────────────────────────────────────────────────────────────
    method parse_type {} {
        if {[my check LPAREN]} {
            my advance
            if {[my check RPAREN]} { my advance; return [pak::N TypeTuple elements {}] }
            set first [my parse_type]
            if {[my check COMMA]} {
                set els [list $first]
                while {[my accept COMMA]} {
                    if {[my check RPAREN]} break
                    lappend els [my parse_type]
                }
                my expect RPAREN
                return [pak::N TypeTuple elements $els]
            }
            my expect RPAREN
            return $first
        }
        if {[my check DYN]} {
            my advance
            return [pak::N TypeDynTrait name [my expectv IDENT]]
        }
        if {[my accept QUESTION]} {
            if {[my check STAR]} {
                my advance
                return [pak::N TypePointer inner [my parse_type] nullable 1 mutable 0]
            }
            return [pak::N TypeOption inner [my parse_type]]
        }
        if {[my check VOLATILE]} {
            my advance
            return [pak::N TypeVolatile inner [my parse_type]]
        }
        if {[my accept STAR]} {
            set vol 0; if {[my accept VOLATILE]} { set vol 1 }
            set mut 0; if {[my accept MUT]} { set mut 1 }
            set ptr [pak::N TypePointer inner [my parse_type] nullable 0 mutable $mut]
            if {$vol} { return [pak::N TypeVolatile inner $ptr] }
            return $ptr
        }
        if {[my check LBRACKET]} {
            my advance
            if {[my check RBRACKET]} {
                my advance
                set mut 0; if {[my accept MUT]} { set mut 1 }
                return [pak::N TypeSlice inner [my parse_type] mutable $mut]
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
            if {[my accept ARROW]} { set ret [my parse_type] }
            return [pak::N TypeFn params $params ret $ret]
        }
        set name [my expectv IDENT]
        while {[my check DOT]} { my advance; append name "." [my expectv IDENT] }
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
                    set r [my advancev]
                    lappend args [pak::N IntLit value [pak::intval $r] raw $r]
                } else {
                    lappend args [my parse_type]
                }
                my match COMMA
            }
            my expect RPAREN
            return [pak::N TypeGeneric name $name args $args]
        }
        if {[my check LT]} {
            set targs [my try_type_args]
            if {$targs ne "NONE"} {
                return [pak::N TypeGeneric name $name args $targs]
            }
        }
        return [pak::N TypeName name $name]
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
            while {[my accept SEMICOLON]} {}
            if {[my check RBRACE] || [my check EOF]} break
            lappend stmts [my parse_stmt]
        }
        my expect RBRACE
        return [pak::N Block stmts $stmts]
    }

    method parse_stmt_inner {} {
        set anns [my anns]
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
            BREAK    {
                my advance
                set bval [pak::Nil]
                # break value only if next token is on the same source line,
                # and `break;` is a bare break, not a break of `;`
                if {![my check RBRACE] && ![my check EOF] && ![my check SEMICOLON] \
                        && ![my _newline_before]} {
                    set bval [my parse_expr]
                }
                return [pak::N Break value $bval]
            }
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
            GOTO     { my advance; return [pak::N GotoStmt label [my expectv IDENT]] }
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
                if {[my accept ELSE]} { set elseb [my parse_block] }
                return [pak::N ComptimeIf condition $cond then $then else_branch $elseb]
            }
            default {
                if {$t eq "IDENT" && [my ptype 1] eq "COLON" && [my ptype 2] ne "COLON"} {
                    set ln [my advancev]
                    my advance
                    return [pak::N LabelStmt name $ln]
                }
                return [pak::N ExprStmt expr [my parse_expr]]
            }
        }
    }

    method parse_if {} {
        my expect IF
        set cond [my parse_expr]
        if {[my accept ARROW]} {
            set binding [my expectv IDENT]
            set then [my parse_block]
            set elseb [pak::Nil]
            if {[my accept ELSE]} { set elseb [my parse_block] }
            return [pak::N NullCheckStmt expr $cond binding $binding then $then else_branch $elseb]
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
        return [pak::N IfStmt condition $cond then $then elif_branches $elifs else_branch $elseb]
    }

    method parse_for {} {
        my expect FOR
        set first [my expectv IDENT]
        set index [pak::Nil]
        set binding $first
        if {[my accept COMMA]} {
            set index [pak::Lit $first]
            set binding [my expectv IDENT]
        }
        my expect IN
        set iter [my parse_expr]
        set body [my parse_block]
        return [pak::N ForStmt index $index binding $binding iterable $iter body $body]
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
        return [pak::N MatchStmt expr $expr arms $arms]
    }

    method parse_match_arm {} {
        set pat [my parse_pattern]
        set guard [pak::Nil]
        if {[my check IF]} {
            my advance
            set guard [my parse_expr]
        }
        my expect FAT_ARROW
        if {[my check LBRACE]} {
            set body [my parse_block]
        } else {
            set body [pak::N Block stmts [list [my parse_stmt]]]
        }
        return [pak::N MatchArm pattern $pat guard $guard body $body]
    }

    method parse_pattern {} {
        if {[my check DOT]} {
            my advance
            set name [my namev]
            if {[my check LPAREN]} {
                my advance
                set args {}
                # A variant pattern binds names: .ok(v), .rect(w, _). Anything
                # else has to be an error rather than a token this loop skips,
                # because nothing here consumes it -- `.ok(1)` used to spin the
                # parser forever, and so did an unterminated `.ok(` at EOF.
                while {![my check RPAREN] && ![my check EOF]} {
                    if {[my check IDENT]} {
                        lappend args [pak::N Ident name [my advancev] type_args {}]
                    } elseif {[my check UNDERSCORE]} {
                        my advance
                        lappend args [pak::N Ident name "_" type_args {}]
                    } else {
                        set t [my peek]
                        return -code error "PARSEERROR\t[dict get $t line]\t[dict get $t col]\tExpected a binding name or _ in a variant pattern (got [dict get $t type])"
                    }
                    if {[my check COMMA]} { my advance }
                }
                my expect RPAREN
                return [pak::N Call func [pak::N EnumVariantAccess name $name] args $args type_args {}]
            }
            if {[my check LBRACE]} {
                # Named-field variant match: .Rect { w: ww, h: hh }
                my advance
                set args {}
                while {![my check RBRACE] && ![my check EOF]} {
                    set fn [my expectv IDENT]
                    my expect COLON
                    if {[my check UNDERSCORE]} {
                        set bn [my advancev]
                    } else {
                        set bn [my expectv IDENT]
                    }
                    lappend args [pak::N NamedArg name $fn value [pak::N Ident name $bn type_args {}]]
                    my match COMMA
                }
                my expect RBRACE
                return [pak::N Call func [pak::N EnumVariantAccess name $name] args $args type_args {}]
            }
            return [pak::N EnumVariantAccess name $name]
        } elseif {[my check UNDERSCORE]} {
            my advance
            return [pak::N Ident name "_" type_args {}]
        } elseif {[my check INT]} {
            set r [my advancev]
            return [pak::N IntLit value [pak::intval $r] raw $r]
        } elseif {[my check STRING]} {
            return [pak::N StringLit value [my advancev]]
        } elseif {[my check IDENT]} {
            set name [my advancev]
            if {[my check DOT]} {
                my advance
                set variant [my expectv IDENT]
                set binding [pak::Nil]
                if {[my check LPAREN]} {
                    my advance
                    if {![my check RPAREN]} { set binding [pak::Lit [my expectv IDENT]] }
                    my expect RPAREN
                }
                return [pak::N DotAccess obj [pak::N Ident name $name type_args {}] field $variant binding $binding]
            }
            return [pak::N Ident name $name type_args {}]
        } elseif {[my check TRUE]} {
            my advance; return [pak::N BoolLit value 1]
        } elseif {[my check FALSE]} {
            my advance; return [pak::N BoolLit value 0]
        } else {
            return [my parse_expr]
        }
    }

    method parse_asm_stmt {} {
        my expect ASM
        set vol 0; if {[my accept VOLATILE]} { set vol 1 }
        my expect LBRACE
        set lines {}
        while {![my check RBRACE] && ![my check EOF]} {
            if {[my check STRING]} {
                lappend lines [my advancev]
            } elseif {[my check SEMICOLON]} {
                my advance
            } else {
                my advance
            }
        }
        my expect RBRACE
        return [pak::N AsmStmt lines $lines volatile $vol]
    }

    # ── expressions (precedence) ─────────────────────────────────────────────────
    method parse_expr {} { return [my parse_assign] }

    method parse_assign {} {
        set left [my parse_catch]
        if {[my check EQ]} {
            my advance
            set right [my parse_assign]
            return [pak::N Assign target $left value $right op "="]
        }
        foreach {tt opstr} {PLUS_EQ += MINUS_EQ -= STAR_EQ *= SLASH_EQ /= PERCENT_EQ %= SHL_EQ <<= SHR_EQ >>= AMP_EQ &= PIPE_EQ |= CARET_EQ ^=} {
            if {[my accept $tt]} {
                set right [my parse_assign]
                return [pak::N Assign target $left value $right op $opstr]
            }
        }
        return $left
    }

    method parse_catch {} {
        set expr [my parse_or]
        if {[my accept CATCH]} {
            set binding [pak::Nil]
            if {[my check PIPE]} {
                my advance
                set binding [pak::Lit [my expectv IDENT]]
                my expect PIPE
            } elseif {[my check IDENT] && [my ptype 1] eq "LBRACE"} {
                set binding [pak::Lit [my advancev]]
            }
            set handler [my parse_block]
            return [pak::N CatchExpr expr $expr binding $binding handler $handler]
        }
        return $expr
    }

    # True if the current token begins on a later source line than the previous
    # token. Pak is newline-delimited: a binary op that is also a valid prefix
    # (* deref, - negate, & address-of) must not continue the previous
    # expression when it opens a new line (mirrors Parser._newline_before).
    method _newline_before {} {
        if {$pos <= 0} { return 0 }
        return [expr {[dict get [my peek] line] > [dict get [lindex $toks [expr {$pos-1}]] line]}]
    }
    method binop_chain {next types} {
        set left [my $next]
        while {[my check {*}[dict keys $types]]} {
            if {[my ptype] in {STAR MINUS AMP} && [my _newline_before]} { break }
            set op [dict get $types [my ptype]]
            my advance
            set right [my $next]
            set left [pak::N BinaryOp op $op left $left right $right]
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
    method parse_mul {} { return [my binop_chain parse_cast {STAR * SLASH / PERCENT %}] }

    method parse_cast {} {
        set expr [my parse_unary]
        if {[my accept AS]} {
            return [pak::N Cast expr $expr type [my parse_type]]
        }
        return $expr
    }

    method parse_unary {} {
        if {[my accept BANG] || [my accept NOT]} {
            return [pak::N UnaryOp op "!" operand [my parse_unary]]
        }
        if {[my accept MINUS]} { return [pak::N UnaryOp op "-" operand [my parse_unary]] }
        if {[my accept AMP]} {
            set mut 0
            if {[my accept MUT]} { set mut 1 }
            return [pak::N AddrOf expr [my parse_unary] mutable $mut]
        }
        if {[my accept STAR]} { return [pak::N Deref expr [my parse_unary]] }
        return [my parse_postfix]
    }

    method parse_postfix {} {
        set expr [my parse_primary]
        while {1} {
            if {[my check DOT]} {
                if {[my ptype 1] eq "IDENT" && [my ptype 2] eq "FAT_ARROW"} break
                my advance
                if {[my check INT]} {
                    set idx [my advancev]
                    set expr [pak::N TupleAccess obj $expr index [pak::intval $idx]]
                } else {
                    set fld [my namev]
                    set expr [pak::N DotAccess obj $expr field $fld binding [pak::Nil]]
                }
            } elseif {[my check LPAREN]} {
                my advance
                set args {}
                while {![my check RPAREN] && ![my check EOF]} {
                    if {[my check IDENT] && [my ptype 1] eq "COLON"} {
                        set an [my advancev]
                        my advance
                        set av [my parse_expr]
                        lappend args [pak::N NamedArg name $an value $av]
                    } else {
                        lappend args [my parse_expr]
                    }
                    my match COMMA
                }
                my expect RPAREN
                set targs {}
                if {[lindex $expr 0] eq "node" && [lindex $expr 1] eq "Ident"} {
                    set targs [lindex [dict get [lindex $expr 2] type_args] 1]
                    # consume: rebuild ident with empty type_args
                    set f [lindex $expr 2]
                    dict set f type_args [pak::Seq {}]
                    set expr [list node Ident $f]
                }
                set expr [pak::N Call func $expr args $args type_args $targs]
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
            } elseif {[my check LBRACE] \
                      && [pak::kindof $expr] eq "DotAccess" \
                      && [pak::kindof [pak::nfield $expr obj]] eq "Ident" \
                      && [my is_struct_lit_ctx]} {
                # Named-field variant construction: TypeName.case_name { field: val }
                set vtype [pak::fval [pak::nfield $expr obj] name]
                set vcase [pak::fval $expr field]
                my advance
                set fields {}
                while {![my check RBRACE] && ![my check EOF]} {
                    set fn [my expectv IDENT]
                    my expect COLON
                    set fv [my parse_expr]
                    lappend fields [pak::Seq [list [pak::Lit $fn] $fv]]
                    my match COMMA
                }
                my expect RBRACE
                set expr [pak::N VariantLit variant_type $vtype case_name $vcase fields $fields]
            } elseif {[my check QUESTION]} {
                my advance
                set expr [pak::N UnaryOp op "?" operand $expr]
            } else break
        }
        return $expr
    }

    method parse_primary_inner {} {
        set t [my ptype]
        switch -- $t {
            INT {
                set raw [my advancev]
                set lit [pak::N IntLit value [pak::intval $raw] raw $raw]
                if {[my check DOTDOT]} {
                    my advance
                    set end [pak::Nil]
                    if {![my check RBRACE] && ![my check COMMA] && ![my check RPAREN] && ![my check RBRACKET]} { set end [my parse_postfix] }
                    return [pak::N RangeExpr start $lit end $end]
                }
                return $lit
            }
            FLOAT {
                set raw [my advancev]
                return [pak::N FloatLit value $raw raw ""]
            }
            STRING {
                set v [my advancev]
                return [my string_or_fmt $v]
            }
            TRUE  { my advance; return [pak::N BoolLit value 1] }
            FALSE { my advance; return [pak::N BoolLit value 0] }
            NONE  { my advance; return [pak::N NoneLit] }
            UNDEFINED { my advance; return [pak::N UndefinedLit] }
            UNDERSCORE { my advance; return [pak::N Ident name "_" type_args {}] }
            SELF  { my advance; return [pak::N Ident name "self" type_args {}] }
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
                set tn [my expectv IDENT]
                my expect COMMA
                set fn [my expectv IDENT]
                my expect RPAREN
                return [pak::N OffsetOf type_name $tn field $fn]
            }
            ALLOC {
                my advance; my expect LPAREN
                set tn [my parse_type]
                set count [pak::Nil]; set alc [pak::Nil]
                if {[my accept COMMA]} {
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
                    set mut 0; if {[my accept MUT]} { set mut 1 }
                    set pname [my advancev]
                    my expect COLON
                    set ptype [my parse_type]
                    lappend params [pak::N Param name $pname type $ptype mutable $mut default_value [pak::Nil]]
                    my match COMMA
                }
                my expect RPAREN
                set ret [pak::Nil]
                if {[my accept ARROW]} { set ret [my parse_type] }
                set body [my parse_block]
                return [pak::N Closure params $params ret_type $ret body $body]
            }
            ASM {
                my advance; my expect LPAREN
                set tmpl [my expectv STRING]
                set outs {}; set ins {}; set clob {}
                if {[my accept COLON]} {
                    while {[my check STRING]} {
                        set con [my advancev]
                        my expect LPAREN; set e [my parse_expr]; my expect RPAREN
                        lappend outs [pak::Seq [list [pak::Lit $con] $e]]
                        my match COMMA
                    }
                }
                if {[my accept COLON]} {
                    while {[my check STRING]} {
                        set con [my advancev]
                        my expect LPAREN; set e [my parse_expr]; my expect RPAREN
                        lappend ins [pak::Seq [list [pak::Lit $con] $e]]
                        my match COMMA
                    }
                }
                if {[my accept COLON]} {
                    while {[my check STRING]} { lappend clob [my advancev]; my match COMMA }
                }
                my expect RPAREN
                return [pak::N AsmExpr template $tmpl outputs $outs inputs $ins clobbers $clob volatile 1]
            }
            DOT   { my advance; return [pak::N EnumVariantAccess name [my expectv IDENT]] }
            LPAREN {
                my advance
                if {[my check RPAREN]} { my advance; return [pak::N TupleLit elements {}] }
                set first [my parse_expr]
                if {[my check COMMA]} {
                    set els [list $first]
                    while {[my accept COMMA]} {
                        if {[my check RPAREN]} break
                        lappend els [my parse_expr]
                    }
                    my expect RPAREN
                    return [pak::N TupleLit elements $els]
                }
                my expect RPAREN
                return $first
            }
            LBRACKET {
                my advance
                if {[my check RBRACKET]} { my advance; return [pak::N ArrayLit elements {} repeat [pak::Nil]] }
                set first [my parse_expr]
                if {[my accept SEMICOLON]} {
                    set cnt [my parse_expr]
                    my expect RBRACKET
                    return [pak::N ArrayLit elements [list $first] repeat $cnt]
                }
                set els [list $first]
                while {[my accept COMMA]} {
                    if {[my check RBRACKET]} break
                    lappend els [my parse_expr]
                }
                my expect RBRACKET
                return [pak::N ArrayLit elements $els repeat [pak::Nil]]
            }
            IDENT {
                set name [my advancev]
                # Parse call-site / struct-literal type arguments as real types
                # (mirror of Python _try_parse_type_args) so explicit args like
                # foo<i32>(x) and Box<i32>{ .. } carry AST type nodes.
                set targs {}
                set save $pos
                if {[my check LT]} {
                    set parsed [my try_type_args]
                    if {$parsed eq "NONE"} {
                        set pos $save
                        set targs {}
                    } else {
                        set targs $parsed
                    }
                }
                if {[my check LBRACE] && [my is_struct_lit_ctx]} {
                    my advance
                    set fields {}
                    while {![my check RBRACE] && ![my check EOF]} {
                        set fn [my expectv IDENT]
                        my expect COLON
                        set fv [my parse_expr]
                        lappend fields [pak::Seq [list [pak::Lit $fn] $fv]]
                        my match COMMA
                    }
                    my expect RBRACE
                    return [pak::N StructLit type_name $name fields $fields type_args $targs]
                }
                if {[my check DOTDOT] && [llength $targs] == 0} {
                    my advance
                    set end [pak::Nil]
                    if {![my check RBRACE] && ![my check COMMA] && ![my check RPAREN]} { set end [my parse_postfix] }
                    return [pak::N RangeExpr start [pak::N Ident name $name type_args {}] end $end]
                }
                # If type args weren't followed by a call/struct, the '<...>' was
                # a comparison — rewind so they re-parse as binary operators.
                if {[llength $targs] > 0 && !([my check LPAREN] || [my check LBRACE])} {
                    set pos $save
                    set targs {}
                }
                return [pak::N Ident name $name type_args $targs]
            }
            LOOP {
                # loop { ... } as expression (loop-as-expression / break-with-value)
                my advance
                return [pak::N LoopStmt body [my parse_block]]
            }
            WHILE {
                # while cond { ... } as expression
                my advance
                set c [my parse_expr]
                return [pak::N WhileStmt condition $c body [my parse_block]]
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
            return [pak::N StringLit value $raw]
        }
        # Escaped-only braces -> plain string with {{->{ }}->}
        set escaped [string map [list "\{\{" "" "\}\}" ""] $raw]
        if {[string first "\{" $escaped] < 0} {
            return [pak::N StringLit value [string map [list "\{\{" "\{" "\}\}" "\}"] $raw]]
        }
        # Interpolation: walk char-by-char, parsing {expr} segments, skipping
        # {{ and }} escapes. Mirrors pak/parser._parse_string_or_fmtstr.
        set parts {}
        set seg ""
        set n [string length $raw]
        set i 0
        while {$i < $n} {
            set ch [string index $raw $i]
            if {$ch eq "\{"} {
                if {$i + 1 < $n && [string index $raw [expr {$i+1}]] eq "\{"} {
                    append seg "\{"
                    incr i 2
                } else {
                    set j [expr {$i + 1}]
                    set depth 1
                    while {$j < $n && $depth > 0} {
                        set cj [string index $raw $j]
                        if {$cj eq "\{"} { incr depth } elseif {$cj eq "\}"} { incr depth -1 }
                        incr j
                    }
                    set expr_src [string trim [string range $raw [expr {$i+1}] [expr {$j-2}]]]
                    if {$seg ne ""} { lappend parts [pak::Lit $seg]; set seg "" }
                    if {[catch {
                        set sublex [pak::Lexer new $expr_src]
                        set subp [pak::Parser new [$sublex tokenize]]
                        set sub_expr [$subp parse_expr]
                    }]} {
                        lappend parts [pak::Lit "\{$expr_src\}"]
                    } else {
                        lappend parts $sub_expr
                    }
                    set i $j
                }
            } elseif {$ch eq "\}"} {
                if {$i + 1 < $n && [string index $raw [expr {$i+1}]] eq "\}"} {
                    append seg "\}"
                    incr i 2
                } else {
                    append seg $ch
                    incr i
                }
            } else {
                append seg $ch
                incr i
            }
        }
        if {$seg ne ""} { lappend parts [pak::Lit $seg] }
        # If every part is a plain string, collapse to a single StringLit.
        set all_str 1
        foreach p $parts { if {[lindex $p 0] ne "lit"} { set all_str 0; break } }
        if {$all_str} {
            set joined ""
            foreach p $parts { append joined [lindex $p 1] }
            return [pak::N StringLit value $joined]
        }
        return [pak::N FmtStr parts $parts]
    }
}

proc pak::parse_tokens {tokens} {
    pak::pos_reset
    set p [pak::Parser new $tokens]
    set rc [catch {$p parse} result options]
    pak::pos_reset
    return -options $options $result
}
