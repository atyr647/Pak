# tcl/lexer.tcl — Pak lexer, Tcl port of pak/lexer.py
#
# Produces a token stream identical to the Python lexer. Each token is a dict:
#   {type <TYPENAME> value <string> line <int> col <int>}
# Token type names match the Python TT enum names exactly (INT, FN, LBRACE, ...).

namespace eval pak {}

# keyword text → token type name (mirrors pak/lexer.py KEYWORDS)
set ::pak::KEYWORDS {
    use USE        asset ASSET     from FROM       entry ENTRY
    struct STRUCT  enum ENUM       variant VARIANT fn FN
    let LET        static STATIC   loop LOOP       while WHILE
    for FOR        in IN           if IF           else ELSE
    match MATCH    defer DEFER     return RETURN   break BREAK
    continue CONTINUE  extern EXTERN  module MODULE  true TRUE
    false FALSE    undefined UNDEFINED  none NONE   mut MUT
    and AND        or OR           not NOT         catch CATCH
    as AS          impl IMPL       self SELF       ok OK
    err ERR        sizeof SIZEOF   size_of SIZEOF  elif ELIF
    volatile VOLATILE  const CONST  asm ASM        offsetof OFFSETOF
    align_of ALIGNOF   alignof ALIGNOF  trait TRAIT  dyn DYN
    alloc ALLOC    free FREE       goto GOTO       do DO
    union UNION    comptime COMPTIME  _ UNDERSCORE
}

oo::class create pak::Lexer {
    variable src pos line col toks

    constructor {source} {
        set src $source
        set pos 0
        set line 1
        set col 1
        set toks {}
    }

    method lexerror {msg} {
        return -code error "LEXERROR\t$line\t$col\t$msg"
    }

    method peek {{off 0}} {
        set i [expr {$pos + $off}]
        if {$i < [string length $src]} { return [string index $src $i] }
        return ""
    }

    method advance {} {
        set ch [string index $src $pos]
        incr pos
        if {$ch eq "\n"} { set line [expr {$line + 1}]; set col 1 } else { incr col }
        return $ch
    }

    method takeif {ch} {
        if {$pos < [string length $src] && [string index $src $pos] eq $ch} {
            my advance
            return 1
        }
        return 0
    }

    method emit {l c type value} {
        lappend toks [dict create type $type value $value line $l col $c]
    }

    method isdigit {c} { expr {$c ne "" && [string is digit -strict $c]} }
    method isalpha {c} { expr {$c ne "" && [string is alpha -strict $c]} }
    method isalnum {c} { expr {$c ne "" && [string is alnum -strict $c]} }

    method skip_ws_comments {} {
        set n [string length $src]
        while {$pos < $n} {
            set ch [my peek]
            if {$ch eq " " || $ch eq "\t" || $ch eq "\r" || $ch eq "\n"} {
                my advance
            } elseif {$ch eq "-" && [my peek 1] eq "-"} {
                while {$pos < $n && [my peek] ne "\n"} { my advance }
            } elseif {$ch eq "/" && [my peek 1] eq "/"} {
                while {$pos < $n && [my peek] ne "\n"} { my advance }
            } else {
                break
            }
        }
    }

    method read_string {} {
        set n [string length $src]
        set result ""
        while {$pos < $n} {
            set ch [my peek]
            if {$ch eq "\""} {
                my advance
                return $result
            } elseif {$ch eq "\\"} {
                my advance
                set esc [my advance]
                switch -exact -- $esc {
                    n       { append result "\n" }
                    t       { append result "\t" }
                    r       { append result "\r" }
                    "\\"    { append result "\\" }
                    "\""    { append result "\"" }
                    0       { append result "\x00" }
                    default { append result $esc }
                }
            } elseif {$ch eq "\n"} {
                my lexerror "Unterminated string literal"
            } else {
                append result [my advance]
            }
        }
        my lexerror "Unterminated string literal"
    }

    method tokenize {} {
        set n [string length $src]
        while {1} {
            my skip_ws_comments
            if {$pos >= $n} {
                my emit $line $col EOF ""
                break
            }
            set sline $line
            set scol $col
            set ch [my advance]

            if {$ch eq "@"} {
                # Annotation: @name or @name(args)
                set name "@"
                while {$pos < $n && ([my isalnum [my peek]] || [my peek] eq "_")} {
                    append name [my advance]
                }
                if {$pos < $n && [my peek] eq "("} {
                    append name [my advance]
                    set depth 1
                    while {$pos < $n && $depth > 0} {
                        set c [my advance]
                        append name $c
                        if {$c eq "("} { incr depth } elseif {$c eq ")"} { incr depth -1 }
                    }
                }
                my emit $sline $scol ANNOTATION $name

            } elseif {$ch eq "\""} {
                my emit $sline $scol STRING [my read_string]

            } elseif {[my isdigit $ch] || ($ch eq "." && [my isdigit [my peek]])} {
                my lex_number $ch $sline $scol

            } elseif {[my isalpha $ch] || $ch eq "_"} {
                my lex_ident $ch $sline $scol

            } else {
                my lex_operator $ch $sline $scol
            }
        }
        return $toks
    }

    method lex_number {ch sline scol} {
        set n [string length $src]
        # A '.' right after an expression-ending token is field access, not a float.
        if {$ch eq "." && [llength $toks] > 0} {
            set pt [dict get [lindex $toks end] type]
            if {$pt in {IDENT INT FLOAT RPAREN RBRACKET RBRACE TRUE FALSE SELF}} {
                my emit $sline $scol DOT "."
                return
            }
        }
        set num $ch
        set is_float [expr {$ch eq "."}]
        if {$ch eq "0" && [string equal -nocase [my peek] "x"]} {
            append num [my advance]
            set hexd 0
            while {$pos < $n && [string match {[0-9a-fA-F_]} [my peek]]} {
                set c [my advance]
                if {$c ne "_"} { append num $c; incr hexd }
            }
            if {$hexd == 0} {
                my lexerror "Malformed hex literal '$num': expected at least one hex digit after '0x'"
            }
        } elseif {!$is_float} {
            while {$pos < $n && ([my isdigit [my peek]] || [my peek] eq ".")} {
                set c [my peek]
                if {$c eq "."} {
                    if {$is_float} break
                    if {$pos + 1 < $n && ![my isdigit [string index $src [expr {$pos + 1}]]]} break
                    set is_float 1
                }
                append num [my advance]
            }
        }
        if {[my peek] eq "f"} { my advance; set is_float 1 }
        if {$is_float} {
            my emit $sline $scol FLOAT $num
        } else {
            my emit $sline $scol INT $num
        }
    }

    method lex_ident {ch sline scol} {
        set n [string length $src]
        set word $ch
        while {$pos < $n && ([my isalnum [my peek]] || [my peek] eq "_")} {
            append word [my advance]
        }
        # Fixed-point types: fixNN.MM (e.g. fix16.16) — digit part already in word.
        if {[regexp {^fix[0-9]+$} $word]} {
            if {$pos < $n && [string index $src $pos] eq "." \
                    && $pos + 1 < $n && [my isdigit [string index $src [expr {$pos + 1}]]]} {
                my advance
                set frac ""
                while {$pos < $n && [my isdigit [my peek]]} { append frac [my advance] }
                set word "$word.$frac"
            }
        }
        if {[dict exists $::pak::KEYWORDS $word]} {
            my emit $sline $scol [dict get $::pak::KEYWORDS $word] $word
        } else {
            my emit $sline $scol IDENT $word
        }
    }

    method lex_operator {ch sline scol} {
        # Braces handled outside the switch (they are list-special in Tcl).
        if {$ch eq "\{"} {
            my emit $sline $scol LBRACE $ch
            return
        } elseif {$ch eq "\}"} {
            my emit $sline $scol RBRACE $ch
            return
        }
        switch -exact -- $ch {
            ( { my emit $sline $scol LPAREN $ch }
            ) { my emit $sline $scol RPAREN $ch }
            [ { my emit $sline $scol LBRACKET $ch }
            ] { my emit $sline $scol RBRACKET $ch }
            , { my emit $sline $scol COMMA $ch }
            ; { my emit $sline $scol SEMICOLON $ch }
            ~ { my emit $sline $scol TILDE $ch }
            : { my emit $sline $scol COLON $ch }
            ? { my emit $sline $scol QUESTION $ch }
            & { if {[my takeif =]} { my emit $sline $scol AMP_EQ "&=" } else { my emit $sline $scol AMP $ch } }
            | { if {[my takeif =]} { my emit $sline $scol PIPE_EQ "|=" } else { my emit $sline $scol PIPE $ch } }
            ^ { if {[my takeif =]} { my emit $sline $scol CARET_EQ "^=" } else { my emit $sline $scol CARET $ch } }
            % { if {[my takeif =]} { my emit $sline $scol PERCENT_EQ "%=" } else { my emit $sline $scol PERCENT $ch } }
            . {
                if {[my takeif .]} {
                    if {[my takeif .]} {
                        my emit $sline $scol ELLIPSIS "..."
                    } else {
                        my emit $sline $scol DOTDOT ".."
                    }
                } else {
                    my emit $sline $scol DOT $ch
                }
            }
            = {
                if {[my takeif =]} {
                    my emit $sline $scol EQEQ "=="
                } elseif {[my takeif >]} {
                    my emit $sline $scol FAT_ARROW "=>"
                } else {
                    my emit $sline $scol EQ $ch
                }
            }
            ! { if {[my takeif =]} { my emit $sline $scol NEQ "!=" } else { my emit $sline $scol BANG $ch } }
            < {
                if {[my takeif <]} {
                    if {[my takeif =]} { my emit $sline $scol SHL_EQ "<<=" } else { my emit $sline $scol SHL "<<" }
                } elseif {[my takeif =]} {
                    my emit $sline $scol LTE "<="
                } else {
                    my emit $sline $scol LT $ch
                }
            }
            > {
                if {[my takeif >]} {
                    if {[my takeif =]} { my emit $sline $scol SHR_EQ ">>=" } else { my emit $sline $scol SHR ">>" }
                } elseif {[my takeif =]} {
                    my emit $sline $scol GTE ">="
                } else {
                    my emit $sline $scol GT $ch
                }
            }
            + { if {[my takeif =]} { my emit $sline $scol PLUS_EQ "+=" } else { my emit $sline $scol PLUS $ch } }
            - {
                if {[my takeif >]} {
                    my emit $sline $scol ARROW "->"
                } elseif {[my takeif =]} {
                    my emit $sline $scol MINUS_EQ "-="
                } else {
                    my emit $sline $scol MINUS $ch
                }
            }
            * { if {[my takeif =]} { my emit $sline $scol STAR_EQ "*=" } else { my emit $sline $scol STAR $ch } }
            / { if {[my takeif =]} { my emit $sline $scol SLASH_EQ "/=" } else { my emit $sline $scol SLASH $ch } }
            default { my lexerror "Unexpected character: $ch" }
        }
    }
}
