"""Pak language lexer."""

import re
from enum import Enum, auto
from dataclasses import dataclass
from typing import List, Optional


class TT(Enum):
    """Token types."""
    # Literals
    INT = auto()
    FLOAT = auto()
    STRING = auto()
    BOOL = auto()
    IDENT = auto()

    # Keywords
    USE = auto()
    ASSET = auto()
    FROM = auto()
    ENTRY = auto()
    STRUCT = auto()
    ENUM = auto()
    VARIANT = auto()
    FN = auto()
    LET = auto()
    STATIC = auto()
    LOOP = auto()
    WHILE = auto()
    FOR = auto()
    IN = auto()
    IF = auto()
    ELSE = auto()
    MATCH = auto()
    DEFER = auto()
    RETURN = auto()
    BREAK = auto()
    CONTINUE = auto()
    EXTERN = auto()
    MODULE = auto()
    TRUE = auto()
    FALSE = auto()
    UNDEFINED = auto()
    NONE = auto()
    MUT = auto()
    AND = auto()
    OR = auto()
    NOT = auto()
    CATCH = auto()
    AS = auto()
    IMPL = auto()
    SELF = auto()
    OK = auto()
    ERR = auto()
    SIZEOF = auto()
    ELIF = auto()
    VOLATILE = auto()
    CONST = auto()
    ASM = auto()
    OFFSETOF = auto()
    ALIGNOF = auto()
    TRAIT = auto()
    DYN = auto()
    ALLOC = auto()
    FREE = auto()
    GOTO = auto()
    DO = auto()
    UNION = auto()
    COMPTIME = auto()

    # Annotations
    ANNOTATION = auto()  # @something

    # Symbols
    LBRACE = auto()    # {
    RBRACE = auto()    # }
    LPAREN = auto()    # (
    RPAREN = auto()    # )
    LBRACKET = auto()  # [
    RBRACKET = auto()  # ]
    COMMA = auto()     # ,
    COLON = auto()     # :
    SEMICOLON = auto() # ;
    DOT = auto()       # .
    DOTDOT = auto()    # ..
    ELLIPSIS = auto()  # ...
    ARROW = auto()     # ->
    FAT_ARROW = auto() # =>
    EQ = auto()        # =
    EQEQ = auto()      # ==
    NEQ = auto()       # !=
    LT = auto()        # <
    GT = auto()        # >
    LTE = auto()       # <=
    GTE = auto()       # >=
    PLUS = auto()      # +
    MINUS = auto()     # -
    STAR = auto()      # *
    SLASH = auto()     # /
    PERCENT = auto()   # %
    PERCENT_EQ = auto() # %=
    AMP = auto()       # &
    PIPE = auto()      # |
    CARET = auto()     # ^
    BANG = auto()      # !
    QUESTION = auto()  # ?
    TILDE = auto()     # ~
    PLUS_EQ = auto()   # +=
    MINUS_EQ = auto()  # -=
    STAR_EQ = auto()   # *=
    SLASH_EQ = auto()  # /=
    SHL = auto()       # <<
    SHR = auto()       # >>
    SHL_EQ = auto()    # <<=
    SHR_EQ = auto()    # >>=
    AMP_EQ = auto()    # &=
    PIPE_EQ = auto()   # |=
    CARET_EQ = auto()  # ^=
    UNDERSCORE = auto() # _

    EOF = auto()


KEYWORDS = {
    'use': TT.USE,
    'asset': TT.ASSET,
    'from': TT.FROM,
    'entry': TT.ENTRY,
    'struct': TT.STRUCT,
    'enum': TT.ENUM,
    'variant': TT.VARIANT,
    'fn': TT.FN,
    'let': TT.LET,
    'static': TT.STATIC,
    'loop': TT.LOOP,
    'while': TT.WHILE,
    'for': TT.FOR,
    'in': TT.IN,
    'if': TT.IF,
    'else': TT.ELSE,
    'match': TT.MATCH,
    'defer': TT.DEFER,
    'return': TT.RETURN,
    'break': TT.BREAK,
    'continue': TT.CONTINUE,
    'extern': TT.EXTERN,
    'module': TT.MODULE,
    'true': TT.TRUE,
    'false': TT.FALSE,
    'undefined': TT.UNDEFINED,
    'none': TT.NONE,
    'mut': TT.MUT,
    'and': TT.AND,
    'or': TT.OR,
    'not': TT.NOT,
    'catch': TT.CATCH,
    'as': TT.AS,
    'impl': TT.IMPL,
    'self': TT.SELF,
    'ok': TT.OK,
    'err': TT.ERR,
    'sizeof':  TT.SIZEOF,
    'elif': TT.ELIF,
    'volatile': TT.VOLATILE,
    'const': TT.CONST,
    'asm': TT.ASM,
    'offsetof': TT.OFFSETOF,
    'alignof': TT.ALIGNOF,
    'trait': TT.TRAIT,
    'dyn': TT.DYN,
    'alloc': TT.ALLOC,
    'free': TT.FREE,
    'goto': TT.GOTO,
    'do': TT.DO,
    'union': TT.UNION,
    'comptime': TT.COMPTIME,
    '_': TT.UNDERSCORE,
}


@dataclass
class Token:
    type: TT
    value: str
    line: int
    col: int

    def __repr__(self):
        return f'Token({self.type.name}, {self.value!r}, {self.line}:{self.col})'


class LexError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f'{line}:{col}: {msg}')
        self.line = line
        self.col = col


class Lexer:
    def __init__(self, source: str, filename: str = '<unknown>'):
        self.source = source
        self.filename = filename
        self.pos = 0
        self.line = 1
        self.col = 1
        self.tokens: List[Token] = []

    def error(self, msg):
        raise LexError(msg, self.line, self.col)

    def peek(self, offset=0) -> str:
        i = self.pos + offset
        if i < len(self.source):
            return self.source[i]
        return ''

    def advance(self) -> str:
        ch = self.source[self.pos]
        self.pos += 1
        if ch == '\n':
            self.line += 1
            self.col = 1
        else:
            self.col += 1
        return ch

    def match(self, ch: str) -> bool:
        if self.pos < len(self.source) and self.source[self.pos] == ch:
            self.advance()
            return True
        return False

    def skip_whitespace_and_comments(self):
        while self.pos < len(self.source):
            ch = self.peek()
            if ch in ' \t\r\n':
                self.advance()
            elif ch == '-' and self.peek(1) == '-':
                # -- comment
                while self.pos < len(self.source) and self.peek() != '\n':
                    self.advance()
            elif ch == '/' and self.peek(1) == '/':
                # // comment
                while self.pos < len(self.source) and self.peek() != '\n':
                    self.advance()
            else:
                break

    def read_string(self) -> str:
        result = []
        while self.pos < len(self.source):
            ch = self.peek()
            if ch == '"':
                self.advance()
                return ''.join(result)
            elif ch == '\\':
                self.advance()
                esc = self.advance()
                escapes = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', '"': '"', '0': '\0'}
                result.append(escapes.get(esc, esc))
            elif ch == '\n':
                self.error('Unterminated string literal')
            else:
                result.append(self.advance())
        self.error('Unterminated string literal')

    def tokenize(self) -> List[Token]:
        tokens = []

        while True:
            self.skip_whitespace_and_comments()
            if self.pos >= len(self.source):
                tokens.append(Token(TT.EOF, '', self.line, self.col))
                break

            line, col = self.line, self.col
            ch = self.advance()

            def tok(tt, val=None):
                tokens.append(Token(tt, val if val is not None else ch, line, col))

            # Annotations @something or @something(args)
            if ch == '@':
                name = ['@']
                while self.pos < len(self.source) and (self.peek().isalnum() or self.peek() == '_'):
                    name.append(self.advance())
                # Capture parenthesized arguments: @aligned(16)
                if self.pos < len(self.source) and self.peek() == '(':
                    name.append(self.advance())  # (
                    depth = 1
                    while self.pos < len(self.source) and depth > 0:
                        c = self.advance()
                        name.append(c)
                        if c == '(':
                            depth += 1
                        elif c == ')':
                            depth -= 1
                tok(TT.ANNOTATION, ''.join(name))

            # String literal
            elif ch == '"':
                s = self.read_string()
                tok(TT.STRING, s)

            # Numbers
            elif ch.isdigit() or (ch == '.' and self.peek().isdigit()):
                # If '.' follows an expression-ending token (identifier, closing bracket,
                # etc.) it is a field-access dot, not the start of a float literal.
                # e.g. t.0 should be DOT + INT(0), not FLOAT('.')
                if ch == '.' and tokens and tokens[-1].type in (
                        TT.IDENT, TT.INT, TT.FLOAT, TT.RPAREN, TT.RBRACKET,
                        TT.RBRACE, TT.TRUE, TT.FALSE, TT.SELF):
                    tok(TT.DOT)
                    continue
                num = [ch]
                is_float = (ch == '.')
                is_hex = False
                # Hex literal: 0x...
                if ch == '0' and self.pos < len(self.source) and self.peek().lower() == 'x':
                    num.append(self.advance())  # x
                    is_hex = True
                    hex_digits = 0
                    while self.pos < len(self.source) and (self.peek() in '0123456789abcdefABCDEF_'):
                        c = self.advance()
                        if c != '_':
                            num.append(c)
                            hex_digits += 1
                    if hex_digits == 0:
                        self.error(f"Malformed hex literal '{''.join(num)}': expected at least one hex digit after '0x'")
                elif not is_float:
                    while self.pos < len(self.source) and (self.peek().isdigit() or self.peek() == '.'):
                        c = self.peek()
                        if c == '.':
                            if is_float:
                                break
                            # Lookahead: don't consume if next after . is not a digit (e.g. range ..)
                            if self.pos + 1 < len(self.source) and not self.source[self.pos + 1].isdigit():
                                break
                            is_float = True
                        num.append(self.advance())
                # optional f suffix
                if self.pos < len(self.source) and self.peek() == 'f':
                    self.advance()
                    is_float = True
                val = ''.join(num)
                if is_float:
                    tok(TT.FLOAT, val)
                else:
                    # Consume optional integer type suffix: u8/u16/u32/u64/i8/i16/i32/i64
                    _INT_SUFFIXES = {'u8', 'u16', 'u32', 'u64', 'i8', 'i16', 'i32', 'i64'}
                    if self.pos < len(self.source) and self.peek() in ('u', 'i', 'U', 'I'):
                        save = self.pos
                        suf = []
                        while self.pos < len(self.source) and (self.peek().isalnum() or self.peek() == '_'):
                            suf.append(self.advance())
                        if ''.join(suf) not in _INT_SUFFIXES:
                            self.pos = save  # not a recognised suffix, put it back
                    tok(TT.INT, val)

            # Identifiers and keywords
            elif ch.isalpha() or ch == '_':
                name = [ch]
                while self.pos < len(self.source) and (self.peek().isalnum() or self.peek() == '_'):
                    name.append(self.advance())
                word = ''.join(name)
                # Fixed-point types: fixNN.MM (e.g. fix16.16, fix10.5, fix1.15).
                # The digit part is consumed into `word` by the isalnum() loop,
                # so we end up with e.g. word='fix16'. Check if followed by '.NN'.
                if re.match(r'^fix\d+$', word):
                    if (self.pos < len(self.source) and self.source[self.pos] == '.'
                            and self.pos + 1 < len(self.source)
                            and self.source[self.pos + 1].isdigit()):
                        self.advance()  # consume '.'
                        frac = []
                        while self.pos < len(self.source) and self.peek().isdigit():
                            frac.append(self.advance())
                        word = f'{word}.{"".join(frac)}'
                if word in KEYWORDS:
                    tok(KEYWORDS[word], word)
                else:
                    tok(TT.IDENT, word)

            # Operators and punctuation
            elif ch == '{': tok(TT.LBRACE)
            elif ch == '}': tok(TT.RBRACE)
            elif ch == '(': tok(TT.LPAREN)
            elif ch == ')': tok(TT.RPAREN)
            elif ch == '[': tok(TT.LBRACKET)
            elif ch == ']': tok(TT.RBRACKET)
            elif ch == ',': tok(TT.COMMA)
            elif ch == ';': tok(TT.SEMICOLON)
            elif ch == '~': tok(TT.TILDE)
            elif ch == ':': tok(TT.COLON)
            elif ch == '?': tok(TT.QUESTION)
            elif ch == '&':
                if self.match('='):
                    tok(TT.AMP_EQ, '&=')
                else:
                    tok(TT.AMP)
            elif ch == '|':
                if self.match('='):
                    tok(TT.PIPE_EQ, '|=')
                else:
                    tok(TT.PIPE)
            elif ch == '^':
                if self.match('='):
                    tok(TT.CARET_EQ, '^=')
                else:
                    tok(TT.CARET)
            elif ch == '%':
                if self.match('='):
                    tok(TT.PERCENT_EQ, '%=')
                else:
                    tok(TT.PERCENT)
            elif ch == '.':
                if self.match('.'):
                    if self.match('.'):
                        tok(TT.ELLIPSIS, '...')
                    else:
                        tok(TT.DOTDOT, '..')
                else:
                    tok(TT.DOT)
            elif ch == '=':
                if self.match('='):
                    tok(TT.EQEQ, '==')
                elif self.match('>'):
                    tok(TT.FAT_ARROW, '=>')
                else:
                    tok(TT.EQ)
            elif ch == '!':
                if self.match('='):
                    tok(TT.NEQ, '!=')
                else:
                    tok(TT.BANG)
            elif ch == '<':
                if self.match('<'):
                    if self.match('='):
                        tok(TT.SHL_EQ, '<<=')
                    else:
                        tok(TT.SHL, '<<')
                elif self.match('='):
                    tok(TT.LTE, '<=')
                else:
                    tok(TT.LT)
            elif ch == '>':
                if self.match('>'):
                    if self.match('='):
                        tok(TT.SHR_EQ, '>>=')
                    else:
                        tok(TT.SHR, '>>')
                elif self.match('='):
                    tok(TT.GTE, '>=')
                else:
                    tok(TT.GT)
            elif ch == '+':
                if self.match('='):
                    tok(TT.PLUS_EQ, '+=')
                else:
                    tok(TT.PLUS)
            elif ch == '-':
                if self.match('>'):
                    tok(TT.ARROW, '->')
                elif self.match('='):
                    tok(TT.MINUS_EQ, '-=')
                else:
                    tok(TT.MINUS)
            elif ch == '*':
                if self.match('='):
                    tok(TT.STAR_EQ, '*=')
                else:
                    tok(TT.STAR)
            elif ch == '/':
                if self.match('='):
                    tok(TT.SLASH_EQ, '/=')
                else:
                    tok(TT.SLASH)
            else:
                self.error(f'Unexpected character: {ch!r}')

        return tokens
