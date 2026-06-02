"""Pak language parser."""

from typing import List, Optional, Any
from .lexer import Token, TT, Lexer, KEYWORDS
from . import ast


class ParseError(Exception):
    def __init__(self, msg, token: Token):
        super().__init__(f'{token.line}:{token.col}: {msg} (got {token.type.name} {token.value!r})')
        self.token = token


class Parser:
    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0

    def peek(self, offset=0) -> Token:
        i = self.pos + offset
        if i < len(self.tokens):
            return self.tokens[i]
        return self.tokens[-1]  # EOF

    def advance(self) -> Token:
        tok = self.tokens[self.pos]
        if self.pos < len(self.tokens) - 1:
            self.pos += 1
        return tok

    def check(self, *types) -> bool:
        return self.peek().type in types

    def _newline_before(self) -> bool:
        """True if the current token begins on a later source line than the
        previous token. Pak is newline-delimited: a binary operator that is
        also a valid prefix/statement-starter (* deref, - negate, & address-of)
        must NOT continue the previous expression when it opens a new line —
        otherwise `let p = alloc(T)` / `*p = v` parses as `alloc(T) * p = v`."""
        if self.pos <= 0:
            return False
        return self.peek().line > self.tokens[self.pos - 1].line

    def match(self, *types) -> Optional[Token]:
        if self.check(*types):
            return self.advance()
        return None

    def expect_name(self) -> Token:
        """Accept IDENT or any keyword used as a name."""
        tok = self.peek()
        if tok.type == TT.IDENT or tok.type in KEYWORDS.values():
            return self.advance()
        raise ParseError('Expected identifier', tok)

    def expect(self, tt: TT, msg: str = None) -> Token:
        if self.check(tt):
            return self.advance()
        tok = self.peek()
        raise ParseError(msg or f'Expected {tt.name}', tok)

    def loc(self) -> tuple:
        t = self.peek()
        return t.line, t.col

    def node(self, cls, *args, **kwargs):
        line, col = self.loc()
        obj = cls(*args, **kwargs)
        obj.line = line
        obj.col = col
        return obj

    # ── Entry point ──────────────────────────────────────────────────────────

    def parse(self) -> ast.Program:
        decls = []
        while not self.check(TT.EOF):
            # Skip optional semicolons between top-level declarations
            while self.match(TT.SEMICOLON):
                pass
            if self.check(TT.EOF):
                break
            d = self.parse_top_level()
            if d is not None:
                decls.append(d)
        return ast.Program(decls=decls)

    def parse_top_level(self):
        # Collect annotations — separate @cfg(...) from regular ones
        annotations = []
        cfg_ann = None
        while self.check(TT.ANNOTATION):
            ann = self.advance().value
            if ann.startswith('@cfg('):
                cfg_ann = ann  # last @cfg wins
            else:
                annotations.append(ann)

        line, col = self.loc()
        tok = self.peek()

        if tok.type == TT.USE:
            decl = self.parse_use()
        elif tok.type == TT.ASSET:
            decl = self.parse_asset()
        elif tok.type == TT.MODULE:
            decl = self.parse_module()
        elif tok.type == TT.STRUCT:
            decl = self.parse_struct(annotations)
        elif tok.type == TT.ENUM:
            decl = self.parse_enum(annotations)
        elif tok.type == TT.VARIANT:
            decl = self.parse_variant(annotations)
        elif tok.type == TT.FN:
            decl = self.parse_fn(annotations)
        elif tok.type == TT.ENTRY:
            decl = self.parse_entry()
        elif tok.type == TT.EXTERN:
            decl = self.parse_extern()
        elif tok.type == TT.STATIC:
            decl = self.parse_static(annotations)
        elif tok.type == TT.LET:
            decl = self.parse_let(annotations)
        elif tok.type == TT.IMPL:
            decl = self.parse_impl()
        elif tok.type == TT.CONST:
            decl = self.parse_const()
        elif tok.type == TT.TRAIT:
            decl = self.parse_trait(annotations)
        elif tok.type == TT.UNION:
            decl = self.parse_union(annotations)
        elif tok.type == TT.COMPTIME:
            self.advance()
            self.expect(TT.IF)
            self.expect(TT.LPAREN)
            cond = self.parse_expr()
            self.expect(TT.RPAREN)
            then = self._parse_decl_block()
            else_b = None
            if self.match(TT.ELSE):
                else_b = self._parse_decl_block()
            decl = ast.ComptimeIf(condition=cond, then=then, else_branch=else_b,
                                  line=line, col=col)
        else:
            raise ParseError(f'Unexpected token at top level', tok)

        # Wrap in CfgBlock if a @cfg annotation was present
        if cfg_ann and decl is not None:
            feature_str = cfg_ann[5:-1].strip()  # strip '@cfg(' and ')'
            negated = feature_str.startswith('not(')
            if negated:
                feature = feature_str[4:-1].strip()
            else:
                feature = feature_str
            decl = ast.CfgBlock(feature=feature, negated=negated, decl=decl,
                                 line=line, col=col)
        return decl

    def _parse_decl_block(self):
        """Parse { decl* } where decls are top-level declarations, returning a Block."""
        line, col = self.loc()
        self.expect(TT.LBRACE)
        decls = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            while self.match(TT.SEMICOLON):
                pass
            if self.check(TT.RBRACE) or self.check(TT.EOF):
                break
            decls.append(self.parse_top_level())
        self.expect(TT.RBRACE)
        return ast.Block(stmts=decls, line=line, col=col)

    def _parse_generic_params(self) -> List[str]:
        """Parse optional <T, U, V> generic parameter list after a name."""
        if not self.check(TT.LT):
            return []
        # Lookahead: make sure this is <IDENT (,IDENT)* > not a comparison
        # Heuristic: all tokens until > should be idents or commas
        i = self.pos + 1
        params = []
        while i < len(self.tokens):
            t = self.tokens[i]
            if t.type == TT.IDENT:
                params.append(t.value)
                i += 1
            elif t.type == TT.COMMA:
                i += 1
            elif t.type == TT.GT:
                break
            else:
                return []  # not a generic param list
        else:
            return []
        # Commit: consume the < params >
        self.advance()  # <
        result = []
        while not self.check(TT.GT) and not self.check(TT.EOF):
            result.append(self.expect(TT.IDENT).value)
            self.match(TT.COMMA)
        self.expect(TT.GT)
        return result

    # ── Top-level declarations ────────────────────────────────────────────────

    def parse_use(self) -> ast.UseDecl:
        line, col = self.loc()
        self.expect(TT.USE)
        path = self.parse_dotted_name()
        alias = None
        if self.match(TT.AS):
            alias = self.expect(TT.IDENT).value
        return ast.UseDecl(path=path, alias=alias, line=line, col=col)

    def parse_dotted_name(self) -> str:
        parts = [self.expect(TT.IDENT).value]
        while self.check(TT.DOT):
            self.advance()
            parts.append(self.expect(TT.IDENT).value)
        return '.'.join(parts)

    def parse_asset(self) -> ast.AssetDecl:
        line, col = self.loc()
        self.expect(TT.ASSET)
        name = self.expect(TT.IDENT).value
        asset_type = None
        if self.match(TT.COLON):
            asset_type = self.expect(TT.IDENT).value
        self.expect(TT.FROM)
        path = self.expect(TT.STRING).value
        return ast.AssetDecl(name=name, asset_type=asset_type, path=path, line=line, col=col)

    def parse_module(self) -> ast.ModuleDecl:
        line, col = self.loc()
        self.expect(TT.MODULE)
        path = self.parse_dotted_name()
        return ast.ModuleDecl(path=path, line=line, col=col)

    def parse_struct(self, annotations=None) -> ast.StructDecl:
        line, col = self.loc()
        self.expect(TT.STRUCT)
        name = self.expect(TT.IDENT).value
        type_params = self._parse_generic_params()
        self.expect(TT.LBRACE)
        fields = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            f_annotations = []
            while self.check(TT.ANNOTATION):
                f_annotations.append(self.advance().value)
            fname = self.expect(TT.IDENT).value
            self.expect(TT.COLON)
            ftype = self.parse_type()
            bit_width = None
            # bit-field: field: u32 : 4
            if self.check(TT.COLON):
                save = self.pos
                self.advance()
                if self.check(TT.INT):
                    bit_width = int(self.advance().value)
                else:
                    self.pos = save  # not a bit-field — roll back
            default_val = None
            if self.match(TT.EQ):
                default_val = self.parse_expr()
            self.match(TT.COMMA)
            fields.append(ast.StructField(name=fname, type=ftype, annotations=f_annotations,
                                          default_value=default_val, bit_width=bit_width,
                                          line=line, col=col))
        self.expect(TT.RBRACE)
        return ast.StructDecl(name=name, fields=fields, type_params=type_params,
                              annotations=annotations or [], line=line, col=col)

    def parse_enum(self, annotations=None) -> ast.EnumDecl:
        line, col = self.loc()
        self.expect(TT.ENUM)
        name = self.expect(TT.IDENT).value
        base_type = None
        if self.match(TT.COLON):
            base_type = self.expect(TT.IDENT).value
        self.expect(TT.LBRACE)
        variants = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            vname = self.expect_name().value
            val = None
            if self.match(TT.EQ):
                val = self.parse_expr()
            self.match(TT.COMMA)
            variants.append(ast.EnumVariant(name=vname, value=val, line=line, col=col))
        self.expect(TT.RBRACE)
        return ast.EnumDecl(name=name, base_type=base_type, variants=variants,
                            annotations=annotations or [], line=line, col=col)

    def parse_variant(self, annotations=None) -> ast.VariantDecl:
        line, col = self.loc()
        self.expect(TT.VARIANT)
        name = self.expect(TT.IDENT).value
        self.expect(TT.LBRACE)
        cases = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            cname = self.expect_name().value
            fields = []
            if self.match(TT.LPAREN):
                while not self.check(TT.RPAREN) and not self.check(TT.EOF):
                    fields.append(self.parse_type())
                    self.match(TT.COMMA)
                self.expect(TT.RPAREN)
            elif self.check(TT.LBRACE):
                self.advance()
                while not self.check(TT.RBRACE) and not self.check(TT.EOF):
                    fname = self.expect(TT.IDENT).value
                    self.expect(TT.COLON)
                    ftype = self.parse_type()
                    self.match(TT.COMMA)
                    fields.append((fname, ftype))
                self.expect(TT.RBRACE)
            self.match(TT.COMMA)
            cases.append(ast.VariantCase(name=cname, fields=fields, line=line, col=col))
        self.expect(TT.RBRACE)
        return ast.VariantDecl(name=name, cases=cases, annotations=annotations or [], line=line, col=col)

    def parse_fn(self, annotations=None) -> ast.FnDecl:
        line, col = self.loc()
        self.expect(TT.FN)
        name = self.expect(TT.IDENT).value
        # Optional generic type params: fn foo<T, U>(...)
        type_params = self._parse_generic_params()
        self.expect(TT.LPAREN)
        params = []
        variadic = False
        while not self.check(TT.RPAREN) and not self.check(TT.EOF):
            # C-style variadic marker `...` — must be the final parameter.
            if self.match(TT.ELLIPSIS):
                variadic = True
                break
            mut = bool(self.match(TT.MUT))
            # Accept 'self' keyword or IDENT as param name
            if self.check(TT.SELF):
                pname = self.advance().value  # 'self'
            else:
                pname = self.expect(TT.IDENT).value
            self.expect(TT.COLON)
            ptype = self.parse_type()
            default_val = None
            if self.match(TT.EQ):
                default_val = self.parse_expr()
            params.append(ast.Param(name=pname, type=ptype, mutable=mut,
                                    default_value=default_val, line=line, col=col))
            self.match(TT.COMMA)
        self.expect(TT.RPAREN)
        ret_type = None
        if self.match(TT.ARROW):
            ret_type = self.parse_type()
        body = None
        if self.check(TT.LBRACE):
            body = self.parse_block()
        # Detect method: first param named 'self'
        is_method = False
        self_type = None
        if params and params[0].name == 'self':
            is_method = True
            ptype = params[0].type
            if isinstance(ptype, ast.TypePointer) and isinstance(ptype.inner, ast.TypeName):
                self_type = ptype.inner.name
            elif isinstance(ptype, ast.TypeName):
                self_type = ptype.name
        return ast.FnDecl(name=name, params=params, ret_type=ret_type, body=body,
                          type_params=type_params, annotations=annotations or [],
                          is_method=is_method, self_type=self_type, variadic=variadic,
                          line=line, col=col)

    def parse_entry(self) -> ast.EntryBlock:
        line, col = self.loc()
        self.expect(TT.ENTRY)
        body = self.parse_block()
        return ast.EntryBlock(body=body, line=line, col=col)

    def parse_impl(self):
        line, col = self.loc()
        self.expect(TT.IMPL)
        type_name = self.expect(TT.IDENT).value
        type_params = self._parse_generic_params()

        # impl TypeName for TraitName { ... }
        if self.match(TT.FOR):
            trait_name = self.expect(TT.IDENT).value
            self.expect(TT.LBRACE)
            methods = []
            while not self.check(TT.RBRACE) and not self.check(TT.EOF):
                ann = []
                while self.check(TT.ANNOTATION):
                    ann.append(self.advance().value)
                if self.check(TT.FN):
                    m = self.parse_fn(ann)
                    m.is_method = True
                    if not m.self_type:
                        m.self_type = type_name
                    methods.append(m)
                else:
                    self.advance()
            self.expect(TT.RBRACE)
            return ast.ImplTraitBlock(type_name=type_name, trait_name=trait_name,
                                      methods=methods, type_params=type_params,
                                      line=line, col=col)

        # Regular impl block: impl TypeName { ... }
        self.expect(TT.LBRACE)
        methods = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            ann = []
            while self.check(TT.ANNOTATION):
                ann.append(self.advance().value)
            if self.check(TT.FN):
                m = self.parse_fn(ann)
                # Mark as method belonging to this type
                m.is_method = True
                if not m.self_type:
                    m.self_type = type_name
                methods.append(m)
            else:
                self.advance()  # skip unknown tokens
        self.expect(TT.RBRACE)
        return ast.ImplBlock(type_name=type_name, type_params=type_params,
                             methods=methods, line=line, col=col)

    def parse_trait(self, annotations=None) -> ast.TraitDecl:
        line, col = self.loc()
        self.expect(TT.TRAIT)
        name = self.expect(TT.IDENT).value
        self.expect(TT.LBRACE)
        methods = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            ann = []
            while self.check(TT.ANNOTATION):
                ann.append(self.advance().value)
            if self.check(TT.FN):
                m = self.parse_fn(ann)
                methods.append(m)
            else:
                self.advance()  # skip stray tokens
        self.expect(TT.RBRACE)
        return ast.TraitDecl(name=name, methods=methods,
                             annotations=annotations or [], line=line, col=col)

    def parse_union(self, annotations=None) -> ast.UnionDecl:
        """union Name { field: Type; ... } — untagged C union."""
        line, col = self.loc()
        self.expect(TT.UNION)
        name = self.expect(TT.IDENT).value
        self.expect(TT.LBRACE)
        fields = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            ann = []
            while self.check(TT.ANNOTATION):
                ann.append(self.advance().value)
            if self.check(TT.FN):
                # Unions can have methods too (impl block preferred, but allow here)
                break
            if self.check(TT.IDENT):
                fname = self.advance().value
                self.expect(TT.COLON)
                ftype = self.parse_type()
                fields.append(ast.StructField(name=fname, type=ftype,
                                              annotations=ann, line=line, col=col))
            if not self.match(TT.COMMA):
                self.match(TT.SEMICOLON)
        self.expect(TT.RBRACE)
        return ast.UnionDecl(name=name, fields=fields,
                             annotations=annotations or [], line=line, col=col)

    def parse_const(self) -> ast.ConstDecl:
        line, col = self.loc()
        self.expect(TT.CONST)
        name = self.expect(TT.IDENT).value
        typ = None
        if self.match(TT.COLON):
            typ = self.parse_type()
        self.expect(TT.EQ)
        value = self.parse_expr()
        self.match(TT.SEMICOLON)
        return ast.ConstDecl(name=name, type=typ, value=value, line=line, col=col)

    def parse_extern(self):
        line, col = self.loc()
        self.expect(TT.EXTERN)
        # extern const NAME: T  — C macro/extern constant declaration
        if self.check(TT.CONST):
            self.advance()
            name = self.expect(TT.IDENT).value
            self.expect(TT.COLON)
            typ = self.parse_type()
            self.match(TT.SEMICOLON)
            return ast.ExternConst(name=name, type=typ, line=line, col=col)
        abi = self.expect(TT.STRING).value
        self.expect(TT.LBRACE)
        decls = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            ann = []
            while self.check(TT.ANNOTATION):
                ann.append(self.advance().value)
            if self.check(TT.FN):
                decls.append(self.parse_fn(ann))
            elif self.check(TT.STATIC):
                decls.append(self.parse_static(ann))
            else:
                self.advance()  # skip unknown
        self.expect(TT.RBRACE)
        return ast.ExternBlock(abi=abi, decls=decls, line=line, col=col)

    # ── Types ─────────────────────────────────────────────────────────────────

    def parse_type(self) -> Any:
        line, col = self.loc()
        tok = self.peek()

        # (T1, T2) — tuple type, or (T) — parenthesized type
        if self.check(TT.LPAREN):
            self.advance()
            if self.check(TT.RPAREN):
                self.advance()
                return ast.TypeTuple(elements=[], line=line, col=col)
            first = self.parse_type()
            if self.check(TT.COMMA):
                elements = [first]
                while self.match(TT.COMMA):
                    if self.check(TT.RPAREN):
                        break  # trailing comma allowed
                    elements.append(self.parse_type())
                self.expect(TT.RPAREN)
                return ast.TypeTuple(elements=elements, line=line, col=col)
            self.expect(TT.RPAREN)
            return first  # parenthesized type, not a tuple

        # dyn TraitName — trait-object type
        if self.check(TT.DYN):
            self.advance()
            name = self.expect(TT.IDENT).value
            return ast.TypeDynTrait(name=name, line=line, col=col)

        # ?*Type  or  ?Type
        if self.match(TT.QUESTION):
            if self.check(TT.STAR):
                self.advance()
                inner = self.parse_type()
                return ast.TypePointer(inner=inner, nullable=True, line=line, col=col)
            inner = self.parse_type()
            return ast.TypeOption(inner=inner, line=line, col=col)

        # volatile T
        if self.check(TT.VOLATILE):
            self.advance()
            inner = self.parse_type()
            return ast.TypeVolatile(inner=inner, line=line, col=col)

        # *Type or *mut Type or *volatile Type
        if self.match(TT.STAR):
            vol = bool(self.match(TT.VOLATILE))
            mut = bool(self.match(TT.MUT))
            inner = self.parse_type()
            ptr = ast.TypePointer(inner=inner, nullable=False, mutable=mut, line=line, col=col)
            if vol:
                return ast.TypeVolatile(inner=ptr, line=line, col=col)
            return ptr

        # []Type  or  [N]Type  or  [T; N]  (Rust-style)
        if self.check(TT.LBRACKET):
            self.advance()
            if self.check(TT.RBRACKET):
                self.advance()
                mut = bool(self.match(TT.MUT))
                inner = self.parse_type()
                return ast.TypeSlice(inner=inner, mutable=mut, line=line, col=col)
            # Peek ahead: if this is [T; N] (Rust style) the first expr will be a
            # type name followed by SEMICOLON.  We do a speculative type parse.
            save_pos = self.pos
            try:
                inner = self.parse_type()
                if self.check(TT.SEMICOLON):
                    self.advance()  # ;
                    size = self.parse_expr()
                    self.expect(TT.RBRACKET)
                    return ast.TypeArray(size=size, inner=inner, line=line, col=col)
                # Not [T; N] — roll back and fall through to [N]T
                self.pos = save_pos
            except Exception:
                self.pos = save_pos
            # [N]Type  (original syntax)
            size = self.parse_expr()
            self.expect(TT.RBRACKET)
            inner = self.parse_type()
            return ast.TypeArray(size=size, inner=inner, line=line, col=col)

        # fn(A, B) -> R
        if self.check(TT.FN):
            self.advance()
            self.expect(TT.LPAREN)
            params = []
            while not self.check(TT.RPAREN) and not self.check(TT.EOF):
                params.append(self.parse_type())
                self.match(TT.COMMA)
            self.expect(TT.RPAREN)
            ret = None
            if self.match(TT.ARROW):
                ret = self.parse_type()
            return ast.TypeFn(params=params, ret=ret, line=line, col=col)

        # Named type (possibly with generic args like Result(T, E))
        name = self.expect(TT.IDENT).value
        # Handle dotted type names
        while self.check(TT.DOT):
            self.advance()
            name += '.' + self.expect(TT.IDENT).value

        if name == 'Result' and self.check(TT.LPAREN):
            self.advance()
            ok = self.parse_type()
            self.expect(TT.COMMA)
            err = self.parse_type()
            self.expect(TT.RPAREN)
            return ast.TypeResult(ok=ok, err=err, line=line, col=col)
        if name == 'Option' and self.check(TT.LPAREN):
            self.advance()
            inner = self.parse_type()
            self.expect(TT.RPAREN)
            return ast.TypeOption(inner=inner, line=line, col=col)
        # FixedList(T, N) / RingBuffer(T, N) / FixedMap(K, V, N) / Pool(T, N) / Vec(T)
        # type args may be types OR integer literals
        if name in ('FixedList', 'RingBuffer', 'FixedMap', 'Pool', 'Vec') and self.check(TT.LPAREN):
            self.advance()
            args = []
            while not self.check(TT.RPAREN) and not self.check(TT.EOF):
                if self.check(TT.INT):
                    tok2 = self.advance()
                    args.append(ast.IntLit(value=int(tok2.value), raw=tok2.value, line=line, col=col))
                else:
                    args.append(self.parse_type())
                self.match(TT.COMMA)
            self.expect(TT.RPAREN)
            return ast.TypeGeneric(name=name, args=args, line=line, col=col)

        # Generic type: Name<T, U>
        if self.check(TT.LT):
            # Check if this looks like generic args rather than a comparison
            type_args = self._try_parse_type_args()
            if type_args is not None:
                return ast.TypeGeneric(name=name, args=type_args, line=line, col=col)

        return ast.TypeName(name=name, line=line, col=col)

    def _try_parse_type_args(self) -> Optional[List[Any]]:
        """Try to parse <T, U, V> as a list of type arguments.
        Returns the list on success, None if this is not a generic type arg list.
        """
        # Lookahead: scan for matching >
        i = self.pos + 1  # skip <
        depth = 1
        while i < len(self.tokens) and depth > 0:
            t = self.tokens[i]
            if t.type == TT.LT:
                depth += 1
            elif t.type == TT.GT:
                depth -= 1
            elif t.type in (TT.LBRACE, TT.RBRACE, TT.SEMICOLON, TT.EOF):
                return None  # definitely not type args
            i += 1
        if depth != 0:
            return None
        # Try to parse as type args
        save_pos = self.pos
        self.advance()  # consume <
        args = []
        try:
            while not self.check(TT.GT) and not self.check(TT.EOF):
                args.append(self.parse_type())
                self.match(TT.COMMA)
            self.expect(TT.GT)
            return args
        except Exception:
            self.pos = save_pos
            return None

    # ── Statements ────────────────────────────────────────────────────────────

    def parse_block(self) -> ast.Block:
        line, col = self.loc()
        self.expect(TT.LBRACE)
        stmts = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            # Skip optional semicolons between statements
            while self.match(TT.SEMICOLON):
                pass
            if self.check(TT.RBRACE) or self.check(TT.EOF):
                break
            s = self.parse_stmt()
            if s is not None:
                stmts.append(s)
        self.expect(TT.RBRACE)
        return ast.Block(stmts=stmts, line=line, col=col)

    def parse_stmt(self) -> Any:
        line, col = self.loc()
        annotations = []
        while self.check(TT.ANNOTATION):
            annotations.append(self.advance().value)

        tok = self.peek()

        if tok.type == TT.LET:
            return self.parse_let(annotations)
        elif tok.type == TT.STATIC:
            return self.parse_static(annotations)
        elif tok.type == TT.RETURN:
            self.advance()
            val = None
            if not self.check(TT.RBRACE) and not self.check(TT.EOF):
                val = self.parse_expr()
            return ast.Return(value=val, line=line, col=col)
        elif tok.type == TT.BREAK:
            self.advance()
            return ast.Break(line=line, col=col)
        elif tok.type == TT.CONTINUE:
            self.advance()
            return ast.Continue(line=line, col=col)
        elif tok.type == TT.IF:
            return self.parse_if()
        elif tok.type == TT.LOOP:
            self.advance()
            body = self.parse_block()
            return ast.LoopStmt(body=body, line=line, col=col)
        elif tok.type == TT.WHILE:
            self.advance()
            cond = self.parse_expr()
            body = self.parse_block()
            return ast.WhileStmt(condition=cond, body=body, line=line, col=col)
        elif tok.type == TT.FOR:
            return self.parse_for()
        elif tok.type == TT.MATCH:
            return self.parse_match()
        elif tok.type == TT.DEFER:
            self.advance()
            body = self.parse_block()
            return ast.DeferStmt(body=body, line=line, col=col)
        elif tok.type in (TT.STRUCT, TT.ENUM, TT.VARIANT):
            if tok.type == TT.STRUCT:
                return self.parse_struct(annotations)
            elif tok.type == TT.ENUM:
                return self.parse_enum(annotations)
            else:
                return self.parse_variant(annotations)
        elif tok.type == TT.CONST:
            return self.parse_const()
        elif tok.type == TT.ASM:
            return self.parse_asm_stmt()
        elif tok.type == TT.GOTO:
            self.advance()
            label = self.expect(TT.IDENT).value
            return ast.GotoStmt(label=label, line=line, col=col)
        elif tok.type == TT.DO:
            # do { body } while cond
            self.advance()
            body = self.parse_block()
            self.expect(TT.WHILE)
            cond = self.parse_expr()
            return ast.DoWhileStmt(body=body, condition=cond, line=line, col=col)
        elif tok.type == TT.COMPTIME:
            # comptime if (expr) { ... } else { ... }
            self.advance()
            self.expect(TT.IF)
            self.expect(TT.LPAREN)
            cond = self.parse_expr()
            self.expect(TT.RPAREN)
            then = self.parse_block()
            else_b = None
            if self.match(TT.ELSE):
                else_b = self.parse_block()
            return ast.ComptimeIf(condition=cond, then=then, else_branch=else_b,
                                  line=line, col=col)
        elif tok.type == TT.IDENT and self.peek(1).type == TT.COLON and self.peek(2).type != TT.COLON:
            # label_name: — label declaration (but not :: which is a path separator)
            label_name = self.advance().value
            self.advance()  # consume ':'
            return ast.LabelStmt(name=label_name, line=line, col=col)
        else:
            expr = self.parse_expr()
            return ast.ExprStmt(expr=expr, line=line, col=col)

    def parse_asm_stmt(self) -> ast.AsmStmt:
        """asm { "instruction" ... } or asm volatile { ... }"""
        line, col = self.loc()
        self.expect(TT.ASM)
        # Optional `volatile` qualifier
        vol = bool(self.match(TT.VOLATILE))
        self.expect(TT.LBRACE)
        lines_list = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            if self.check(TT.STRING):
                lines_list.append(self.advance().value)
            elif self.check(TT.SEMICOLON):
                self.advance()
            else:
                self.advance()  # skip stray tokens gracefully
        self.expect(TT.RBRACE)
        return ast.AsmStmt(lines=lines_list, volatile=vol, line=line, col=col)

    def parse_let(self, annotations=None) -> ast.LetDecl:
        line, col = self.loc()
        self.expect(TT.LET)
        mutable = self.match(TT.MUT)
        name = self.expect(TT.IDENT).value
        typ = None
        if self.match(TT.COLON):
            typ = self.parse_type()
        val = None
        if self.match(TT.EQ):
            val = self.parse_expr()
        return ast.LetDecl(name=name, type=typ, value=val, mutable=mutable, annotations=annotations or [], line=line, col=col)

    def parse_static(self, annotations=None) -> ast.StaticDecl:
        line, col = self.loc()
        self.expect(TT.STATIC)
        name = self.expect(TT.IDENT).value
        typ = None
        if self.match(TT.COLON):
            typ = self.parse_type()
        val = None
        if self.match(TT.EQ):
            val = self.parse_expr()
        return ast.StaticDecl(name=name, type=typ, value=val, annotations=annotations or [], line=line, col=col)

    def parse_if(self) -> Any:
        line, col = self.loc()
        self.expect(TT.IF)

        # Nullable check: if expr -> binding { }
        # We need to detect this: parse the expr, then check for ->
        # But -> after an ident could mean this
        cond = self.parse_expr()

        if self.match(TT.ARROW):
            binding = self.expect(TT.IDENT).value
            then = self.parse_block()
            else_b = None
            if self.match(TT.ELSE):
                else_b = self.parse_block()
            return ast.NullCheckStmt(expr=cond, binding=binding, then=then,
                                     else_branch=else_b, line=line, col=col)

        then = self.parse_block()
        elif_branches = []
        else_b = None
        while self.check(TT.ELSE) or self.check(TT.ELIF):
            if self.check(TT.ELIF):
                self.advance()
                ec = self.parse_expr()
                eb = self.parse_block()
                elif_branches.append((ec, eb))
            else:
                self.advance()  # else
                if self.check(TT.IF):
                    self.advance()
                    ec = self.parse_expr()
                    eb = self.parse_block()
                    elif_branches.append((ec, eb))
                elif self.check(TT.ELIF):
                    self.advance()
                    ec = self.parse_expr()
                    eb = self.parse_block()
                    elif_branches.append((ec, eb))
                else:
                    else_b = self.parse_block()
                    break
        return ast.IfStmt(condition=cond, then=then, elif_branches=elif_branches,
                          else_branch=else_b, line=line, col=col)

    def parse_for(self) -> ast.ForStmt:
        line, col = self.loc()
        self.expect(TT.FOR)
        # for i, item in ... or for item in ...
        first = self.expect(TT.IDENT).value
        index = None
        binding = first
        if self.match(TT.COMMA):
            index = first
            binding = self.expect(TT.IDENT).value
        self.expect(TT.IN)
        iterable = self.parse_expr()
        body = self.parse_block()
        return ast.ForStmt(index=index, binding=binding, iterable=iterable, body=body, line=line, col=col)

    def parse_match(self) -> ast.MatchStmt:
        line, col = self.loc()
        self.expect(TT.MATCH)
        expr = self.parse_expr()
        self.expect(TT.LBRACE)
        arms = []
        while not self.check(TT.RBRACE) and not self.check(TT.EOF):
            arm = self.parse_match_arm()
            arms.append(arm)
            self.match(TT.COMMA)
        self.expect(TT.RBRACE)
        return ast.MatchStmt(expr=expr, arms=arms, line=line, col=col)

    def parse_match_arm(self) -> ast.MatchArm:
        line, col = self.loc()
        pattern = self.parse_pattern()
        self.expect(TT.FAT_ARROW)
        if self.check(TT.LBRACE):
            body = self.parse_block()
        else:
            # Single-statement arm: => stmt (no braces)
            stmt = self.parse_stmt()
            body = ast.Block(stmts=[stmt], line=line, col=col)
        return ast.MatchArm(pattern=pattern, guard=None, body=body, line=line, col=col)

    def parse_pattern(self) -> Any:
        line, col = self.loc()
        # .variant or _ or literal or ident
        if self.check(TT.DOT):
            self.advance()
            name = self.expect_name().value   # accept keywords: .ok, .err, .none, etc.
            # .CaseName(binding, ...) — variant destructuring
            if self.check(TT.LPAREN):
                self.advance()
                args = []
                while not self.check(TT.RPAREN):
                    if self.check(TT.IDENT):
                        args.append(ast.Ident(name=self.advance().value, line=line, col=col))
                    elif self.check(TT.UNDERSCORE):
                        self.advance()
                        args.append(ast.Ident(name='_', line=line, col=col))
                    if self.check(TT.COMMA):
                        self.advance()
                self.expect(TT.RPAREN)
                return ast.Call(func=ast.EnumVariantAccess(name=name, line=line, col=col),
                                args=args, line=line, col=col)
            return ast.EnumVariantAccess(name=name, line=line, col=col)
        elif self.check(TT.UNDERSCORE):
            self.advance()
            return ast.Ident(name='_', line=line, col=col)
        elif self.check(TT.INT):
            t = self.advance()
            raw = t.value
            val = int(t.value, 16) if t.value.startswith('0x') or t.value.startswith('0X') else int(t.value)
            return ast.IntLit(value=val, raw=raw, line=line, col=col)
        elif self.check(TT.STRING):
            return ast.StringLit(value=self.advance().value, line=line, col=col)
        elif self.check(TT.IDENT):
            name = self.advance().value
            # Could be EnumName.variant or VariantName.Case(binding)
            if self.check(TT.DOT):
                self.advance()
                variant = self.expect(TT.IDENT).value
                # Optional destructure binding: Type.Case(binding)
                binding = None
                if self.check(TT.LPAREN):
                    self.advance()
                    if not self.check(TT.RPAREN):
                        binding = self.expect(TT.IDENT).value
                    self.expect(TT.RPAREN)
                pat = ast.DotAccess(obj=ast.Ident(name=name, line=line, col=col),
                                    field=variant, binding=binding or None,
                                    line=line, col=col)
                return pat
            return ast.Ident(name=name, line=line, col=col)
        elif self.check(TT.TRUE):
            self.advance()
            return ast.BoolLit(value=True, line=line, col=col)
        elif self.check(TT.FALSE):
            self.advance()
            return ast.BoolLit(value=False, line=line, col=col)
        else:
            return self.parse_expr()

    # ── Expressions ───────────────────────────────────────────────────────────

    def parse_expr(self) -> Any:
        return self.parse_assign()

    def parse_assign(self) -> Any:
        line, col = self.loc()
        left = self.parse_catch()
        if self.check(TT.EQ) and not self.check(TT.EQEQ):
            # Check if it's = not ==
            if self.peek().type == TT.EQ:
                op = self.advance().value
                right = self.parse_assign()
                return ast.Assign(target=left, value=right, op=op, line=line, col=col)
        for op_tt, op_str in [
            (TT.PLUS_EQ, '+='), (TT.MINUS_EQ, '-='),
            (TT.STAR_EQ, '*='), (TT.SLASH_EQ, '/='), (TT.PERCENT_EQ, '%='),
            (TT.SHL_EQ, '<<='), (TT.SHR_EQ, '>>='),
            (TT.AMP_EQ, '&='), (TT.PIPE_EQ, '|='), (TT.CARET_EQ, '^='),
        ]:
            if self.match(op_tt):
                right = self.parse_assign()
                return ast.Assign(target=left, value=right, op=op_str, line=line, col=col)
        return left

    def parse_catch(self) -> Any:
        line, col = self.loc()
        expr = self.parse_or()
        if self.match(TT.CATCH):
            binding = None
            # Accept: catch |e| { } or catch e { }
            if self.check(TT.PIPE):
                self.advance()
                binding = self.expect(TT.IDENT).value
                self.expect(TT.PIPE)
            elif self.check(TT.IDENT) and self.peek(1).type == TT.LBRACE:
                binding = self.advance().value
            handler = self.parse_block()
            return ast.CatchExpr(expr=expr, binding=binding, handler=handler, line=line, col=col)
        return expr

    def parse_or(self) -> Any:
        line, col = self.loc()
        left = self.parse_and()
        while self.check(TT.OR):
            self.advance()
            right = self.parse_and()
            left = ast.BinaryOp(op='||', left=left, right=right, line=line, col=col)
        return left

    def parse_and(self) -> Any:
        line, col = self.loc()
        left = self.parse_bitor()
        while self.check(TT.AND):
            self.advance()
            right = self.parse_bitor()
            left = ast.BinaryOp(op='&&', left=left, right=right, line=line, col=col)
        return left

    def parse_bitor(self) -> Any:
        line, col = self.loc()
        left = self.parse_bitxor()
        while self.check(TT.PIPE):
            self.advance()
            right = self.parse_bitxor()
            left = ast.BinaryOp(op='|', left=left, right=right, line=line, col=col)
        return left

    def parse_bitxor(self) -> Any:
        line, col = self.loc()
        left = self.parse_bitand()
        while self.check(TT.CARET):
            self.advance()
            right = self.parse_bitand()
            left = ast.BinaryOp(op='^', left=left, right=right, line=line, col=col)
        return left

    def parse_bitand(self) -> Any:
        line, col = self.loc()
        left = self.parse_eq()
        while self.check(TT.AMP):
            if self._newline_before():
                break  # leading '&' on a new line is address-of, a new statement
            self.advance()
            right = self.parse_eq()
            left = ast.BinaryOp(op='&', left=left, right=right, line=line, col=col)
        return left

    def parse_eq(self) -> Any:
        line, col = self.loc()
        left = self.parse_cmp()
        while self.check(TT.EQEQ, TT.NEQ):
            op = self.advance().value
            right = self.parse_cmp()
            left = ast.BinaryOp(op=op, left=left, right=right, line=line, col=col)
        return left

    def parse_cmp(self) -> Any:
        line, col = self.loc()
        left = self.parse_shift()
        while self.check(TT.LT, TT.GT, TT.LTE, TT.GTE):
            op = self.advance().value
            right = self.parse_shift()
            left = ast.BinaryOp(op=op, left=left, right=right, line=line, col=col)
        return left

    def parse_shift(self) -> Any:
        line, col = self.loc()
        left = self.parse_add()
        while self.check(TT.SHL, TT.SHR):
            op = self.advance().value
            right = self.parse_add()
            left = ast.BinaryOp(op=op, left=left, right=right, line=line, col=col)
        return left

    def parse_add(self) -> Any:
        line, col = self.loc()
        left = self.parse_mul()
        while self.check(TT.PLUS, TT.MINUS):
            if self.check(TT.MINUS) and self._newline_before():
                break  # leading '-' on a new line is unary, a new statement
            op = self.advance().value
            right = self.parse_mul()
            left = ast.BinaryOp(op=op, left=left, right=right, line=line, col=col)
        return left

    def parse_mul(self) -> Any:
        line, col = self.loc()
        left = self.parse_unary()
        while self.check(TT.STAR, TT.SLASH, TT.PERCENT):
            if self.check(TT.STAR) and self._newline_before():
                break  # leading '*' on a new line is a deref, a new statement
            op = self.advance().value
            right = self.parse_unary()
            left = ast.BinaryOp(op=op, left=left, right=right, line=line, col=col)
        return left

    def parse_unary(self) -> Any:
        line, col = self.loc()
        if self.match(TT.BANG) or (self.check(TT.NOT) and self.advance()):
            return ast.UnaryOp(op='!', operand=self.parse_unary(), line=line, col=col)
        if self.match(TT.MINUS):
            return ast.UnaryOp(op='-', operand=self.parse_unary(), line=line, col=col)
        if self.match(TT.AMP):
            mut = bool(self.match(TT.MUT))
            return ast.AddrOf(expr=self.parse_unary(), mutable=mut, line=line, col=col)
        if self.match(TT.STAR):
            return ast.Deref(expr=self.parse_unary(), line=line, col=col)
        return self.parse_cast()

    def parse_cast(self) -> Any:
        line, col = self.loc()
        expr = self.parse_postfix()
        if self.match(TT.AS):
            typ = self.parse_type()
            return ast.Cast(expr=expr, type=typ, line=line, col=col)
        return expr

    def parse_postfix(self) -> Any:
        line, col = self.loc()
        expr = self.parse_primary()
        while True:
            if self.check(TT.DOT):
                # Don't consume `.IDENT` if it looks like the next match arm pattern
                # e.g.  => return 1   \n  .down => ...   — the `.down` is a pattern not a field
                if self.peek(1).type == TT.IDENT and self.peek(2).type == TT.FAT_ARROW:
                    break
                self.advance()  # consume '.'
                if self.check(TT.INT):
                    # Tuple field access: t.0, t.1, ...
                    idx_tok = self.advance()
                    expr = ast.TupleAccess(obj=expr, index=int(idx_tok.value),
                                           line=line, col=col)
                else:
                    # After '.', any word token (IDENT or keyword) is a valid field name.
                    tok_field = self.peek()
                    if tok_field.value and tok_field.value[:1].isalpha() or (
                            tok_field.value and tok_field.value[:1] == '_'):
                        field = self.advance().value
                    else:
                        field = self.expect(TT.IDENT).value
                    expr = ast.DotAccess(obj=expr, field=field, line=line, col=col)
            elif self.check(TT.LPAREN):
                self.advance()
                args = []
                while not self.check(TT.RPAREN) and not self.check(TT.EOF):
                    # Named argument: name: value
                    if self.check(TT.IDENT) and self.peek(1).type == TT.COLON:
                        aname = self.advance().value
                        self.advance()  # consume :
                        aval = self.parse_expr()
                        args.append(ast.NamedArg(name=aname, value=aval, line=line, col=col))
                    else:
                        args.append(self.parse_expr())
                    self.match(TT.COMMA)
                self.expect(TT.RPAREN)
                # Pick up turbofish type args stored on the func ident (e.g. foo::<i32>())
                type_args = expr.type_args if isinstance(expr, ast.Ident) else []
                if isinstance(expr, ast.Ident) and expr.type_args:
                    expr.type_args = []   # consume; field exists so no deletion needed
                expr = ast.Call(func=expr, args=args, type_args=type_args, line=line, col=col)
            elif self.check(TT.LBRACKET):
                self.advance()
                idx = self.parse_expr()
                # Check for slice: expr[start..end]
                # parse_primary may have consumed the .. into a RangeExpr already
                if isinstance(idx, ast.RangeExpr):
                    self.expect(TT.RBRACKET)
                    expr = ast.SliceExpr(obj=expr, start=idx.start, end=idx.end, line=line, col=col)
                elif self.check(TT.DOTDOT):
                    self.advance()
                    end = None
                    if not self.check(TT.RBRACKET):
                        end = self.parse_expr()
                    self.expect(TT.RBRACKET)
                    expr = ast.SliceExpr(obj=expr, start=idx, end=end, line=line, col=col)
                else:
                    self.expect(TT.RBRACKET)
                    expr = ast.IndexAccess(obj=expr, index=idx, line=line, col=col)
            else:
                break
        return expr

    def parse_primary(self) -> Any:
        line, col = self.loc()
        tok = self.peek()

        if tok.type == TT.INT:
            self.advance()
            raw = tok.value
            val = int(tok.value, 16) if tok.value.startswith(('0x', '0X')) else int(tok.value)
            lit = ast.IntLit(value=val, raw=raw, line=line, col=col)
            if self.check(TT.DOTDOT):
                self.advance()
                end = None
                if not self.check(TT.RBRACE) and not self.check(TT.COMMA) and not self.check(TT.RPAREN) and not self.check(TT.RBRACKET):
                    end = self.parse_primary()
                return ast.RangeExpr(start=lit, end=end, line=line, col=col)
            return lit

        if tok.type == TT.FLOAT:
            self.advance()
            return ast.FloatLit(value=float(tok.value), line=line, col=col)

        if tok.type == TT.STRING:
            self.advance()
            return self._parse_string_or_fmtstr(tok.value, line, col)

        if tok.type == TT.TRUE:
            self.advance()
            return ast.BoolLit(value=True, line=line, col=col)

        if tok.type == TT.FALSE:
            self.advance()
            return ast.BoolLit(value=False, line=line, col=col)

        if tok.type == TT.NONE:
            self.advance()
            return ast.NoneLit(line=line, col=col)

        if tok.type == TT.UNDEFINED:
            self.advance()
            return ast.UndefinedLit(line=line, col=col)

        if tok.type == TT.UNDERSCORE:
            self.advance()
            return ast.Ident(name='_', line=line, col=col)

        # 'self' used as an expression (inside method bodies)
        if tok.type == TT.SELF:
            self.advance()
            return ast.Ident(name='self', line=line, col=col)

        # Grouped expression or tuple literal: (expr) vs (e1, e2, ...)
        if tok.type == TT.LPAREN:
            self.advance()
            if self.check(TT.RPAREN):
                self.advance()
                return ast.TupleLit(elements=[], line=line, col=col)
            first = self.parse_expr()
            if self.check(TT.COMMA):
                # Tuple literal
                elements = [first]
                while self.match(TT.COMMA):
                    if self.check(TT.RPAREN):
                        break  # trailing comma
                    elements.append(self.parse_expr())
                self.expect(TT.RPAREN)
                return ast.TupleLit(elements=elements, line=line, col=col)
            self.expect(TT.RPAREN)
            return first  # parenthesized expression

        # Array literal: [a, b, c] or [val; N]
        if tok.type == TT.LBRACKET:
            self.advance()
            if self.check(TT.RBRACKET):
                self.advance()
                return ast.ArrayLit(elements=[], line=line, col=col)
            first = self.parse_expr()
            if self.match(TT.SEMICOLON):
                count = self.parse_expr()
                self.expect(TT.RBRACKET)
                return ast.ArrayLit(elements=[first], repeat=count, line=line, col=col)
            elements = [first]
            while self.match(TT.COMMA):
                if self.check(TT.RBRACKET):
                    break
                elements.append(self.parse_expr())
            self.expect(TT.RBRACKET)
            return ast.ArrayLit(elements=elements, line=line, col=col)

        # ok(value) — Result Ok constructor
        if tok.type == TT.OK:
            self.advance()
            self.expect(TT.LPAREN)
            val = self.parse_expr()
            self.expect(TT.RPAREN)
            return ast.OkExpr(value=val, line=line, col=col)

        # err(value) — Result Err constructor
        if tok.type == TT.ERR:
            self.advance()
            self.expect(TT.LPAREN)
            val = self.parse_expr()
            self.expect(TT.RPAREN)
            return ast.ErrExpr(value=val, line=line, col=col)

        # alignof(T) — alignment of a type
        if tok.type == TT.ALIGNOF:
            self.advance()
            self.expect(TT.LPAREN)
            save = self.pos
            try:
                operand = self.parse_type()
                if not self.check(TT.RPAREN):
                    raise Exception()
            except Exception:
                self.pos = save
                operand = self.parse_expr()
            self.expect(TT.RPAREN)
            return ast.AlignOf(operand=operand, line=line, col=col)

        # sizeof(T) or sizeof(expr)
        if tok.type == TT.SIZEOF:
            self.advance()
            self.expect(TT.LPAREN)
            save = self.pos
            try:
                operand = self.parse_type()
                if not self.check(TT.RPAREN):
                    raise Exception()
            except Exception:
                self.pos = save
                operand = self.parse_expr()
            self.expect(TT.RPAREN)
            return ast.SizeOf(operand=operand, line=line, col=col)

        # offsetof(Type, field)
        if tok.type == TT.OFFSETOF:
            self.advance()
            self.expect(TT.LPAREN)
            type_name = self.expect(TT.IDENT).value
            self.expect(TT.COMMA)
            field_name = self.expect(TT.IDENT).value
            self.expect(TT.RPAREN)
            return ast.OffsetOf(type_name=type_name, field=field_name, line=line, col=col)

        # alloc(T) or alloc(T, n) or alloc(T using a) or alloc(T, n using a)
        if tok.type == TT.ALLOC:
            self.advance()
            self.expect(TT.LPAREN)
            type_node = self.parse_type()
            count = None
            allocator = None
            if self.match(TT.COMMA):
                # peek: if it's "using" keyword (ident), count remains None and we read allocator
                # otherwise parse count expression, then check for "using"
                if not (self.check(TT.IDENT) and self.peek().value == 'using'):
                    count = self.parse_expr()
            # check for "using allocator_expr"
            if self.check(TT.IDENT) and self.peek().value == 'using':
                self.advance()  # consume 'using'
                allocator = self.parse_expr()
            self.expect(TT.RPAREN)
            return ast.AllocExpr(type_node=type_node, count=count, allocator=allocator, line=line, col=col)

        # free(ptr) or free(ptr using a)
        if tok.type == TT.FREE:
            self.advance()
            self.expect(TT.LPAREN)
            ptr = self.parse_expr()
            allocator = None
            if self.check(TT.IDENT) and self.peek().value == 'using':
                self.advance()  # consume 'using'
                allocator = self.parse_expr()
            self.expect(TT.RPAREN)
            return ast.FreeExpr(ptr=ptr, allocator=allocator, line=line, col=col)

        # fn(...) -> T { body } — fn literal / closure
        if tok.type == TT.FN:
            self.advance()
            self.expect(TT.LPAREN)
            params = []
            while not self.check(TT.RPAREN) and not self.check(TT.EOF):
                mut = bool(self.match(TT.MUT))
                pname = self.advance().value  # IDENT or keyword
                self.expect(TT.COLON)
                ptype = self.parse_type()
                params.append(ast.Param(name=pname, type=ptype, mutable=mut, line=line, col=col))
                self.match(TT.COMMA)
            self.expect(TT.RPAREN)
            ret_type = None
            if self.match(TT.ARROW):
                ret_type = self.parse_type()
            body = self.parse_block()
            return ast.Closure(params=params, ret_type=ret_type, body=body, line=line, col=col)

        # asm("template") — inline asm expression
        if tok.type == TT.ASM:
            self.advance()
            self.expect(TT.LPAREN)
            template = self.expect(TT.STRING).value
            outputs, inputs, clobbers = [], [], []
            if self.match(TT.COLON):
                while self.check(TT.STRING):
                    constraint = self.advance().value
                    self.expect(TT.LPAREN)
                    expr = self.parse_expr()
                    self.expect(TT.RPAREN)
                    outputs.append((constraint, expr))
                    self.match(TT.COMMA)
            if self.match(TT.COLON):
                while self.check(TT.STRING):
                    constraint = self.advance().value
                    self.expect(TT.LPAREN)
                    expr = self.parse_expr()
                    self.expect(TT.RPAREN)
                    inputs.append((constraint, expr))
                    self.match(TT.COMMA)
            if self.match(TT.COLON):
                while self.check(TT.STRING):
                    clobbers.append(self.advance().value)
                    self.match(TT.COMMA)
            self.expect(TT.RPAREN)
            return ast.AsmExpr(template=template, outputs=outputs, inputs=inputs,
                               clobbers=clobbers, volatile=True, line=line, col=col)

        # .variant_name (enum dot access)
        if tok.type == TT.DOT:
            self.advance()
            name = self.expect(TT.IDENT).value
            return ast.EnumVariantAccess(name=name, line=line, col=col)

        # Range: 0..10
        # (Handled in binary ops above, but start..end as primary)

        # Identifier or struct literal or generic call
        if tok.type == TT.IDENT:
            name = self.advance().value

            # Generic struct literal: TypeName<T> { field: val, ... }
            type_args = []
            if self.check(TT.LT):
                saved = self.pos
                try:
                    type_args = self._parse_generic_params()
                except Exception:
                    self.pos = saved
                    type_args = []

            # Look ahead: Struct literal: TypeName { field: val, ... }
            if self.check(TT.LBRACE) and self._is_struct_literal_context():
                self.advance()
                fields = []
                while not self.check(TT.RBRACE) and not self.check(TT.EOF):
                    fname = self.expect(TT.IDENT).value
                    self.expect(TT.COLON)
                    fval = self.parse_expr()
                    fields.append((fname, fval))
                    self.match(TT.COMMA)
                self.expect(TT.RBRACE)
                return ast.StructLit(type_name=name, fields=fields, line=line, col=col)

            # Range: name..end
            if self.check(TT.DOTDOT) and not type_args:
                self.advance()
                end = None
                if not self.check(TT.RBRACE) and not self.check(TT.COMMA) and not self.check(TT.RPAREN):
                    end = self.parse_primary()
                return ast.RangeExpr(start=ast.Ident(name=name, line=line, col=col), end=end, line=line, col=col)

            ident = ast.Ident(name=name, line=line, col=col)
            # If we parsed type args but the next token isn't (, back off the type args
            # They'll be used if we see ( in parse_postfix
            if type_args and not self.check(TT.LPAREN):
                # Discard type args, they were probably a comparison
                pass
            elif type_args:
                ident.type_args = type_args
            return ident

        if tok.type == TT.INT:
            t = self.advance()
            raw = t.value
            ival = int(t.value, 16) if t.value.startswith(('0x', '0X')) else int(t.value)
            if self.check(TT.DOTDOT):
                self.advance()
                end = None
                if not self.check(TT.RBRACE) and not self.check(TT.COMMA) and not self.check(TT.RPAREN) and not self.check(TT.RBRACKET):
                    end = self.parse_primary()
                return ast.RangeExpr(start=ast.IntLit(value=ival, raw=raw, line=line, col=col), end=end, line=line, col=col)
            return ast.IntLit(value=ival, raw=raw, line=line, col=col)

        raise ParseError(f'Unexpected token in expression', tok)

    def _parse_string_or_fmtstr(self, raw: str, line: int, col: int):
        """Parse a string literal, detecting {expr} interpolation.
        Returns StringLit if no interpolation, FmtStr otherwise.

        {{ and }} are escape sequences for literal { and } characters.
        """
        import re
        # Quick exit: no braces at all
        if '{' not in raw and '}' not in raw:
            return ast.StringLit(value=raw, line=line, col=col)
        # If the only braces are escaped ({{ or }}) it's a plain string after substitution
        escaped_only = re.sub(r'\{\{|\}\}', '', raw)
        if '{' not in escaped_only:
            # Replace {{ → { and }} → } and return plain StringLit
            return ast.StringLit(value=raw.replace('{{', '{').replace('}}', '}'),
                                 line=line, col=col)
        # Match single { ... } for interpolation, but skip {{ and }}
        # Strategy: split the string on {{ / }} escapes first, then find {expr} in each piece.
        # We process character-by-character to correctly skip {{ and }}.
        parts: list = []
        i = 0
        seg: list = []   # accumulate literal characters

        while i < len(raw):
            ch = raw[i]
            if ch == '{':
                if i + 1 < len(raw) and raw[i + 1] == '{':
                    seg.append('{')
                    i += 2
                else:
                    # Start of interpolation
                    j = i + 1
                    depth = 1
                    while j < len(raw) and depth > 0:
                        if raw[j] == '{':
                            depth += 1
                        elif raw[j] == '}':
                            depth -= 1
                        j += 1
                    expr_src = raw[i + 1:j - 1].strip()
                    if seg:
                        parts.append(''.join(seg))
                        seg = []
                    try:
                        tokens = Lexer(expr_src).tokenize()
                        sub_expr = Parser(tokens).parse_expr()
                        parts.append(sub_expr)
                    except Exception:
                        parts.append('{' + expr_src + '}')
                    i = j
            elif ch == '}':
                if i + 1 < len(raw) and raw[i + 1] == '}':
                    seg.append('}')
                    i += 2
                else:
                    # Stray } — treat as literal
                    seg.append(ch)
                    i += 1
            else:
                seg.append(ch)
                i += 1

        if seg:
            parts.append(''.join(seg))

        if all(isinstance(p, str) for p in parts):
            return ast.StringLit(value=''.join(parts), line=line, col=col)
        return ast.FmtStr(parts=parts, line=line, col=col)

    def _is_struct_literal_context(self) -> bool:
        """Heuristic: look ahead to see if { ... } looks like a struct literal.
        We only treat it as a struct literal when it has at least one field (ident: val).
        Empty { } is treated as a block to avoid ambiguity with if/while/for bodies.
        """
        i = self.pos
        if i >= len(self.tokens) or self.tokens[i].type != TT.LBRACE:
            return False
        i += 1
        if i >= len(self.tokens):
            return False
        # Empty braces — treat as a block (not a struct literal) to avoid
        # misparse in `if x { }`, `while cond { }` etc.
        if self.tokens[i].type == TT.RBRACE:
            return False
        # If next after { is an ident followed by :, it's a struct literal
        if self.tokens[i].type == TT.IDENT and i + 1 < len(self.tokens) and self.tokens[i+1].type == TT.COLON:
            return True
        return False


def parse(source: str, filename: str = '<unknown>') -> ast.Program:
    lexer = Lexer(source, filename)
    tokens = lexer.tokenize()
    parser = Parser(tokens)
    return parser.parse()
