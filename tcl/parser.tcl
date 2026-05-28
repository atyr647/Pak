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
            STRUCT  { set decl [my parse_struct $anns] }
            ENUM    { set decl [my parse_enum $anns] }
            FN      { set decl [my parse_fn $anns] }
            ENTRY   { set decl [my parse_entry] }
            EXTERN  { set decl [my parse_extern] }
            STATIC  { set decl [my parse_static $anns] }
            LET     { set decl [my parse_let $anns] }
            CONST   { set decl [my parse_const] }
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
            set p0 [lindex $params 0]
            if {[lindex [dict get [lindex $p0 2] name] 1] eq "self"} { set is_method 1 }
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
                    foreach tp $targs { lappend items [pak::N TypeName name [pak::Lit $tp]] }
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
