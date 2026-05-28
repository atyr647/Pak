"""C statement → Pak statement string mapper (Phase 2).

Converts normalized CStmt objects to Pak source text.

Key transformations:
  - if/else if → if/elif/else (parentheses stripped)
  - while → while (parentheses stripped)
  - do-while → loop { ... if !cond { break } }
  - for (int i = 0; i < N; i++) → for i in 0..N
  - for with pointer walk → while loop
  - for (;;) → loop
  - switch/case on enum → match with dot-prefixed cases
  - switch/case on int → match with value patterns
  - goto/label → goto/label (Pak supports these directly)
  - x++ / x-- as statements → x += 1 / x -= 1
  - Assignment in condition: extracted to separate let
"""

from __future__ import annotations
from typing import List, Optional, Tuple

from .c_ast import (
    CStmt, CCompound, CExprStmt, CIf, CWhile, CDoWhile, CFor,
    CSwitch, CCase, CReturn, CBreak, CContinue, CGoto, CLabel, CEmpty,
    CVarDecl,
    CExpr, CConst, CId, CBinOp, CUnaryOp, CAssign, CCall,
    CArrayRef, CStructRef, CCast, CTernary, CComma, CSizeof, CInitList,
    CType, CPointer, CArray, CPrimitive, CTypeRef, CStruct,
)
from .type_mapper import TypeMapper
from .expr_mapper import ExprMapper
from .n64_api import C_TO_PAK_API


class StmtMapper:
    """Converts CStmt and CVarDecl nodes to Pak source lines."""

    def __init__(self, type_mapper: TypeMapper, expr_mapper: ExprMapper):
        self.tm = type_mapper
        self.em = expr_mapper
        self._indent = 0
        self._tmp_counter = 0
        # Track which variable names are known enum types for match dot-prefixing
        self._enum_vars: dict[str, str] = {}  # var_name → enum_type_name
        # self-rename: old first param name → 'self' in method bodies
        self._self_rename: Optional[str] = None
        # N64 module tracking (set passed in from emitter)
        self._n64_modules: Optional[set] = None

    # ── Public API ────────────────────────────────────────────────────────────

    def emit_body(self, compound: CCompound) -> str:
        """Emit a function body (CCompound) as an indented block."""
        lines = []
        self._emit_compound_items(compound.items, lines)
        return '\n'.join(lines)

    def emit_stmt(self, stmt: CStmt, indent: int = 0) -> List[str]:
        """Emit a single statement, returning a list of lines."""
        self._indent = indent
        lines: List[str] = []
        self._emit_stmt(stmt, lines)
        return lines

    # ── Internal dispatch ─────────────────────────────────────────────────────

    def _emit_stmt(self, stmt, lines: List[str]):
        if isinstance(stmt, CEmpty):
            pass
        elif isinstance(stmt, CVarDecl):
            self._emit_local_decl(stmt, lines)
        elif isinstance(stmt, CCompound):
            self._emit_compound(stmt, lines)
        elif isinstance(stmt, CExprStmt):
            self._emit_expr_stmt(stmt, lines)
        elif isinstance(stmt, CIf):
            self._emit_if(stmt, lines)
        elif isinstance(stmt, CWhile):
            self._emit_while(stmt, lines)
        elif isinstance(stmt, CDoWhile):
            self._emit_dowhile(stmt, lines)
        elif isinstance(stmt, CFor):
            self._emit_for(stmt, lines)
        elif isinstance(stmt, CSwitch):
            self._emit_switch(stmt, lines)
        elif isinstance(stmt, CReturn):
            self._emit_return(stmt, lines)
        elif isinstance(stmt, CBreak):
            lines.append(self._pad('break'))
        elif isinstance(stmt, CContinue):
            lines.append(self._pad('continue'))
        elif isinstance(stmt, CGoto):
            lines.append(self._pad(f'goto {stmt.label}'))
        elif isinstance(stmt, CLabel):
            # Labels in Pak use 'label' keyword
            lines.append(self._pad(f'label {stmt.name}'))
            if stmt.stmt:
                self._emit_stmt(stmt.stmt, lines)
        elif isinstance(stmt, _DeferBlock):
            lines.append(self._pad('defer {'))
            self._with_indent(lambda s=stmt: [
                self._emit_stmt(st, lines) for st in s.stmts
            ])
            lines.append(self._pad('}'))
        else:
            lines.append(self._pad(f'-- unhandled stmt: {type(stmt).__name__}'))

    def _emit_compound_items(self, items, lines: List[str]):
        # Try to detect and transform goto-cleanup patterns
        items = _transform_goto_defer(items)
        for item in items:
            self._emit_stmt(item, lines)

    def _emit_compound(self, stmt: CCompound, lines: List[str]):
        """Emit a compound block inline (used for nested blocks)."""
        self._emit_compound_items(stmt.items, lines)

    def _emit_expr(self, expr: CExpr) -> str:
        """Emit an expression with self-rename and N64 API transformations."""
        # Check for N64 API call
        if isinstance(expr, CCall) and isinstance(expr.func, CId):
            func_name = expr.func.name
            mapping = C_TO_PAK_API.get(func_name)
            if mapping:
                module, method = mapping
                if self._n64_modules is not None:
                    self._n64_modules.add(module)
                args = ', '.join(self._emit_expr(a) for a in expr.args)
                return f'{module}.{method}({args})'
        raw = self.em.emit(expr)
        # Apply self-rename
        if self._self_rename and self._self_rename in raw:
            raw = _apply_self_rename(raw, self._self_rename)
        return raw

    def _emit_expr_as_bool(self, expr: CExpr) -> str:
        """Emit expression as bool condition with transformations."""
        raw = self.em.emit_as_bool(expr)
        if self._self_rename and self._self_rename in raw:
            raw = _apply_self_rename(raw, self._self_rename)
        return raw

    # ── Local variable declarations ───────────────────────────────────────────

    def _emit_local_decl(self, decl: CVarDecl, lines: List[str]):
        pak_type = self.tm.map_type(decl.typ)
        keyword = 'let'
        if decl.is_static:
            keyword = 'static'
        if decl.is_const:
            keyword = 'const'

        if isinstance(decl.init, CTernary) and keyword != 'const':
            # `T x = c ? a : b` → declare with the else value, then `if c { x = a }`
            t = decl.init
            cond = self._emit_expr_as_bool(t.cond)
            lines.append(self._pad(
                f'{keyword} {decl.name}: {pak_type} = {self._emit_expr(t.otherwise)}'))
            lines.append(self._pad(
                f'if {cond} {{ {decl.name} = {self._emit_expr(t.then)} }}'))
        elif decl.init is not None:
            init_str = self._emit_init(decl.init, decl.typ)
            # Apply self-rename if needed
            if self._self_rename and self._self_rename in init_str:
                init_str = _apply_self_rename(init_str, self._self_rename)
            lines.append(self._pad(f'{keyword} {decl.name}: {pak_type} = {init_str}'))
        else:
            # Uninitialized — use 'undefined' for non-primitive types, 0 for primitives
            zero = _zero_value(pak_type)
            lines.append(self._pad(f'{keyword} {decl.name}: {pak_type} = {zero}'))

    def _emit_init(self, expr: CExpr, typ: CType) -> str:
        """Emit an initializer expression, aware of the target type."""
        if isinstance(expr, CInitList):
            return self._emit_struct_init(expr, typ)
        return self._emit_expr(expr)

    def _emit_struct_init(self, init: CInitList, typ: CType) -> str:
        """Emit a CInitList as a Pak struct or array literal."""
        type_name = self._type_name(typ)
        # Named initializer: { .x = 1.0, .y = 2.0 }
        named = all(isinstance(item, tuple) for item in init.items)
        if named and type_name:
            fields = ', '.join(
                f'{k}: {self.em.emit(v)}' for k, v in init.items
            )
            return f'{type_name} {{ {fields} }}'
        # Positional array initializer: { 0, 0, 0 }
        if not init.items:
            # Empty or zero initializer
            if isinstance(typ, CArray):
                inner = self.tm.map_type(typ.inner)
                sz = typ.size or 0
                return f'[0; {sz}]'
            return '{}'
        # Try to use named fields if we know the struct's field names
        if type_name and not isinstance(typ, CArray):
            field_names = self.tm.get_struct_fields(type_name)
            if field_names and len(field_names) >= len(init.items):
                # All positional → annotate with field names
                named_parts = []
                for i, item in enumerate(init.items):
                    if isinstance(item, tuple):
                        named_parts.append(f'{item[0]}: {self.em.emit(item[1])}')
                    else:
                        named_parts.append(f'{field_names[i]}: {self.em.emit(item)}')
                return f'{type_name} {{ {", ".join(named_parts)} }}'

        items_str = ', '.join(self.em.emit(i) if not isinstance(i, tuple)
                              else f'{i[0]}: {self.em.emit(i[1])}' for i in init.items)
        if type_name and not isinstance(typ, CArray):
            return f'{type_name} {{ {items_str} }}'
        return f'{{ {items_str} }}'

    def _type_name(self, typ: CType) -> Optional[str]:
        """Extract a usable type name for struct literals."""
        if isinstance(typ, CTypeRef):
            return typ.name
        if isinstance(typ, CStruct):
            return typ.name
        pak = self.tm.map_type(typ)
        if pak and not pak.startswith('[') and not pak.startswith('*'):
            return pak
        return None

    # ── Expression statements ─────────────────────────────────────────────────

    def _emit_expr_stmt(self, stmt: CExprStmt, lines: List[str]):
        expr = stmt.expr
        # Check for pre/post increment/decrement → convert to += / -=
        if isinstance(expr, CUnaryOp) and expr.op in ('++', '--'):
            target = self._emit_expr(expr.expr)
            op = '+=' if expr.op == '++' else '-='
            lines.append(self._pad(f'{target} {op} 1'))
            return

        # Assignment of a ternary: `x = c ? a : b` → `if c { x = a } else { x = b }`.
        # An if/else statement (not a pre-assign) keeps the condition evaluated
        # before the target is touched — important when c or a reference x.
        if isinstance(expr, CAssign) and expr.op == '=' and isinstance(expr.value, CTernary):
            t = expr.value
            target = self._emit_expr(expr.target)
            cond = self._emit_expr_as_bool(t.cond)
            then_v = self._emit_expr(t.then)
            else_v = self._emit_expr(t.otherwise)
            lines.append(self._pad(f'if {cond} {{ {target} = {then_v} }} else {{ {target} = {else_v} }}'))
            return

        # Check for assignment
        if isinstance(expr, CAssign):
            # Split chained assignments: a = b = c → b = c; a = b
            chained = self._flatten_chain_assign(expr)
            for t, v in chained:
                t_str = self._emit_expr(t)
                v_str = self._emit_expr(v)
                lines.append(self._pad(f'{t_str} {expr.op} {v_str}'))
            return

        # Check for comma expression used as statement — flatten
        if isinstance(expr, CComma):
            for sub in expr.exprs:
                self._emit_stmt(CExprStmt(expr=sub), lines)
            return

        # General expression statement
        # Check for increment/decrement sub-expressions that need extraction
        extracted, clean_expr = self._extract_increments(expr)
        for line in extracted:
            lines.append(self._pad(line))
        lines.append(self._pad(self._emit_expr(clean_expr)))

    def _flatten_chain_assign(self, expr: CAssign) -> List[Tuple[CExpr, CExpr]]:
        """Flatten chained assignments like a = b = c → [(b, c), (a, b)]."""
        result = []
        cur = expr
        while isinstance(cur.value, CAssign) and cur.op == '=':
            inner = cur.value
            result.append((inner.target, inner.value))
            cur = CAssign(op=cur.op, target=cur.target, value=inner.target)
        result.append((cur.target, cur.value))
        result.reverse()
        return result

    def _extract_increments(self, expr: CExpr) -> Tuple[List[str], CExpr]:
        """Extract pre/post increment/decrement from sub-expressions.

        Returns (list_of_pre_statements, cleaned_expr).
        This is a best-effort extraction for common patterns like arr[i++].
        """
        # For now, handle the most common case: array index with post-increment
        if isinstance(expr, CArrayRef):
            idx = expr.index
            if isinstance(idx, CUnaryOp) and idx.op in ('++', '--') and idx.postfix:
                tmp = f'_tmp{self._next_tmp()}'
                target = self.em.emit(idx.expr)
                op = '+= 1' if idx.op == '++' else '-= 1'
                pre = [f'let {tmp}: i32 = {target}', f'{target} {op}']
                clean = CArrayRef(base=expr.base, index=CId(tmp))
                return pre, clean
        return [], expr

    def _next_tmp(self) -> int:
        self._tmp_counter += 1
        return self._tmp_counter

    # ── If / elif / else ──────────────────────────────────────────────────────

    def _emit_if(self, stmt: CIf, lines: List[str]):
        cond = self._emit_expr_as_bool(stmt.cond)
        lines.append(self._pad(f'if {cond} {{'))
        self._with_indent(lambda: self._emit_body_block(stmt.then, lines))
        self._emit_else(stmt.otherwise, lines)

    def _emit_else(self, otherwise, lines: List[str]):
        if otherwise is None:
            lines.append(self._pad('}'))
        elif isinstance(otherwise, CIf):
            # else if → } elif ... {
            cond = self._emit_expr_as_bool(otherwise.cond)
            lines.append(self._pad(f'}} elif {cond} {{'))
            self._with_indent(lambda: self._emit_body_block(otherwise.then, lines))
            self._emit_else(otherwise.otherwise, lines)
        else:
            lines.append(self._pad('} else {'))
            self._with_indent(lambda: self._emit_body_block(otherwise, lines))
            lines.append(self._pad('}'))

    def _emit_body_block(self, stmt: CStmt, lines: List[str]):
        """Emit the body of a control structure (handling both compound and single stmts)."""
        if isinstance(stmt, CCompound):
            self._emit_compound_items(stmt.items, lines)
        else:
            self._emit_stmt(stmt, lines)

    # ── While ─────────────────────────────────────────────────────────────────

    def _emit_while(self, stmt: CWhile, lines: List[str]):
        # Special case: while(1) or while(true) → loop
        if _is_always_true(stmt.cond):
            lines.append(self._pad('loop {'))
            self._with_indent(lambda: self._emit_body_block(stmt.body, lines))
            lines.append(self._pad('}'))
            return

        # Detect assignment-in-condition: while ((c = getchar()) != EOF)
        # Transform to: loop { let c = getchar(); if c == EOF { break }; ... }
        assign_info = _extract_assign_in_cond(stmt.cond)
        if assign_info:
            var_name, rhs_expr, cmp_op, cmp_rhs = assign_info
            lines.append(self._pad('loop {'))

            def emit_assign_loop():
                rhs_str = self._emit_expr(rhs_expr)
                lines.append(self._pad(f'let {var_name} = {rhs_str}'))
                cmp_rhs_str = self._emit_expr(cmp_rhs)
                # Invert the condition (we break when the condition becomes false)
                break_cond = _invert_cmp(cmp_op)
                lines.append(self._pad(f'if {var_name} {break_cond} {cmp_rhs_str} {{ break }}'))
                self._emit_body_block(stmt.body, lines)

            self._with_indent(emit_assign_loop)
            lines.append(self._pad('}'))
            return

        cond = self._emit_expr_as_bool(stmt.cond)
        lines.append(self._pad(f'while {cond} {{'))
        self._with_indent(lambda: self._emit_body_block(stmt.body, lines))
        lines.append(self._pad('}'))

    # ── Do-While ──────────────────────────────────────────────────────────────

    def _emit_dowhile(self, stmt: CDoWhile, lines: List[str]):
        # do { body } while (cond) → loop { body; if !cond { break } }
        lines.append(self._pad('loop {'))
        self._with_indent(lambda: self._emit_body_block(stmt.body, lines))
        cond = self._emit_expr_as_bool(stmt.cond)
        self._with_indent(lambda: lines.append(self._pad(f'if !({cond}) {{ break }}')))
        lines.append(self._pad('}'))

    # ── For loops ─────────────────────────────────────────────────────────────

    def _emit_for(self, stmt: CFor, lines: List[str]):
        # Detect common patterns
        if stmt.cond is None and stmt.init is None and stmt.step is None:
            # for(;;) → loop
            lines.append(self._pad('loop {'))
            self._with_indent(lambda: self._emit_body_block(stmt.body, lines))
            lines.append(self._pad('}'))
            return

        range_result = self._detect_range_for(stmt)
        if range_result:
            var, start, end, step_val, end_needs_parens = range_result
            # Wrap end in parens if it's a binary expression (precedence)
            end_str = f'({end})' if end_needs_parens else end
            if step_val == 1:
                lines.append(self._pad(f'for {var} in {start}..{end_str} {{'))
            else:
                # Non-unit step: emit as while loop
                lines.append(self._pad(f'let {var}: i32 = {start}'))
                lines.append(self._pad(f'while {var} < {end_str} {{'))
                self._with_indent(lambda: self._emit_body_block(stmt.body, lines))
                self._with_indent(lambda: lines.append(
                    self._pad(f'{var} += {step_val}')))
                lines.append(self._pad('}'))
                return
            self._with_indent(lambda: self._emit_body_block(stmt.body, lines))
            lines.append(self._pad('}'))
            return

        # General for loop → init; while cond { body; step }
        if stmt.init is not None:
            if isinstance(stmt.init, list):
                for decl in stmt.init:
                    self._emit_stmt(decl, lines)
            elif isinstance(stmt.init, CExprStmt):
                self._emit_expr_stmt(stmt.init, lines)

        if stmt.cond is not None:
            cond = self._emit_expr_as_bool(stmt.cond)
            lines.append(self._pad(f'while {cond} {{'))
        else:
            lines.append(self._pad('loop {'))

        def emit_body_and_step():
            self._emit_body_block(stmt.body, lines)
            if stmt.step is not None:
                self._emit_stmt(CExprStmt(expr=stmt.step), lines)

        self._with_indent(emit_body_and_step)
        lines.append(self._pad('}'))

    def _detect_range_for(self, stmt: CFor):
        """Try to detect 'for (int i = start; i < N; i++)' → range pattern.

        Returns (var, start_str, end_str, step, end_needs_parens) or None.
        """
        # Must have: init declares a variable, cond is comparison, step is increment
        if stmt.init is None or stmt.cond is None or stmt.step is None:
            return None
        if not isinstance(stmt.init, list) or len(stmt.init) != 1:
            return None
        decl = stmt.init[0]
        if not isinstance(decl, CVarDecl) or decl.init is None:
            return None
        var = decl.name
        start = self.em.emit(decl.init)

        # Condition: var < N, var <= N
        cond = stmt.cond
        if not isinstance(cond, CBinOp):
            return None
        if not isinstance(cond.left, CId) or cond.left.name != var:
            return None

        end_needs_parens = False
        if cond.op == '<':
            end_expr = cond.right
            end = self.em.emit(end_expr)
            # If end is a binary expression, it needs parens for correct range semantics
            if isinstance(end_expr, CBinOp):
                end_needs_parens = True
        elif cond.op == '<=':
            # i <= N → i in 0..N+1
            end_expr = cond.right
            if isinstance(end_expr, CConst) and end_expr.kind == 'int':
                try:
                    end = str(int(end_expr.value.rstrip('uUlL')) + 1)
                except ValueError:
                    end = f'{self.em.emit(end_expr)} + 1'
                    end_needs_parens = True
            else:
                end = f'{self.em.emit(end_expr)} + 1'
                end_needs_parens = True
        else:
            return None

        # Step: i++ or i += 1 or ++i
        step = stmt.step
        step_val = 1
        if isinstance(step, CUnaryOp) and step.op in ('++', '--'):
            if not (isinstance(step.expr, CId) and step.expr.name == var):
                return None
            step_val = 1 if step.op == '++' else -1
        elif isinstance(step, CAssign) and step.op == '+=':
            if not (isinstance(step.target, CId) and step.target.name == var):
                return None
            if isinstance(step.value, CConst):
                try:
                    step_val = int(step.value.value.rstrip('uUlL'))
                except ValueError:
                    return None
            else:
                return None
        else:
            return None

        if step_val <= 0:
            return None
        return var, start, end, step_val, end_needs_parens

    # ── Switch / match ────────────────────────────────────────────────────────

    def _emit_switch(self, stmt: CSwitch, lines: List[str]):
        cond = self.em.emit(stmt.cond)

        # Detect if we're switching on an enum variable (for dot-prefixed match)
        is_enum_switch = self._is_enum_switch(stmt.cond)

        lines.append(self._pad(f'match {cond} {{'))
        self._with_indent(lambda: self._emit_cases(stmt.cases, is_enum_switch, lines))
        lines.append(self._pad('}'))

    def _is_enum_switch(self, cond: CExpr) -> bool:
        """Heuristic: if the switch condition refers to a known enum variable."""
        # We check if any case value looks like an enum constant (UPPER_CASE or known prefix)
        return True  # Default to enum-style; the emitter strips enum prefixes

    def _emit_cases(self, cases: List[CCase], is_enum: bool, lines: List[str]):
        for i, case in enumerate(cases):
            if case.value is None:
                # default → _ wildcard
                arm = '_'
            else:
                arm = self._emit_case_value(case.value, is_enum)

            # Collect case body (excluding break)
            body_stmts = [s for s in case.stmts if not isinstance(s, CBreak)]

            if not body_stmts:
                lines.append(self._pad(f'{arm} => {{}}'))
            elif len(body_stmts) == 1 and isinstance(body_stmts[0], CExprStmt):
                stmt_line = self.em.emit(body_stmts[0].expr)
                lines.append(self._pad(f'{arm} => {{ {stmt_line} }}'))
            else:
                lines.append(self._pad(f'{arm} => {{'))
                self._with_indent(lambda stmts=body_stmts: [
                    self._emit_stmt(s, lines) for s in stmts
                ])
                lines.append(self._pad('}'))

    def _emit_case_value(self, value: CExpr, is_enum: bool) -> str:
        """Emit a case value, converting enum constants to dot-prefixed form."""
        raw = self.em.emit(value)
        if is_enum and isinstance(value, CId):
            # Strip common enum prefixes (ACTOR_PLAYER → .player)
            cleaned = _strip_enum_prefix(raw)
            return f'.{cleaned}'
        return raw

    # ── Return ────────────────────────────────────────────────────────────────

    def _emit_return(self, stmt: CReturn, lines: List[str]):
        if stmt.value is None:
            lines.append(self._pad('return'))
        elif isinstance(stmt.value, CTernary):
            # Pak has no ternary/if-expression, so split into statements.
            t = stmt.value
            cond = self._emit_expr_as_bool(t.cond)
            lines.append(self._pad(f'if {cond} {{ return {self._emit_expr(t.then)} }}'))
            lines.append(self._pad(f'return {self._emit_expr(t.otherwise)}'))
        else:
            val = self._emit_expr(stmt.value)
            lines.append(self._pad(f'return {val}'))

    # ── Indentation helpers ───────────────────────────────────────────────────

    def _pad(self, line: str) -> str:
        return '    ' * self._indent + line

    def _with_indent(self, fn):
        self._indent += 1
        fn()
        self._indent -= 1


# ── Helpers ───────────────────────────────────────────────────────────────────

def _is_always_true(expr: CExpr) -> bool:
    """Return True if this expression is a compile-time truthy constant."""
    if isinstance(expr, CConst):
        if expr.kind == 'int':
            try:
                return int(expr.value.rstrip('uUlL')) != 0
            except ValueError:
                pass
    if isinstance(expr, CId) and expr.name in ('true', '1'):
        return True
    return False


def _zero_value(pak_type: str) -> str:
    """Return a zero/default value for a Pak type."""
    if pak_type in ('i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64'):
        return '0'
    if pak_type in ('f32', 'f64'):
        return '0.0'
    if pak_type == 'bool':
        return 'false'
    if pak_type.startswith('*'):
        return 'none'
    if pak_type.startswith('['):
        return '[]'
    # For struct/named types: use 'undefined' since they have no default zero value
    if pak_type[0].isupper() or (pak_type and pak_type[0] == '_'):
        return 'undefined'
    return '0'


class _DeferBlock:
    """Synthetic statement: defer { stmts }"""
    def __init__(self, stmts):
        self.stmts = stmts


def _collect_label_stmts(items, label_name: str) -> list:
    """Collect statements that belong to a cleanup label.

    Returns all statements from the label position to the end (or next label/return).
    """
    result = []
    in_label = False
    for item in items:
        if isinstance(item, CLabel) and item.name == label_name:
            in_label = True
            if item.stmt:
                result.append(item.stmt)
        elif in_label:
            # Stop at return or another label
            if isinstance(item, (CReturn, CLabel)):
                break
            result.append(item)
    return result


def _scan_gotos(items, result: dict):
    """Recursively scan items for goto targets."""
    from .c_ast import CGoto, CLabel, CIf, CWhile, CDoWhile, CFor, CCompound
    for item in items:
        if isinstance(item, CGoto):
            result[item.label] = result.get(item.label, 0) + 1
        elif isinstance(item, CCompound):
            _scan_gotos(item.items, result)
        elif isinstance(item, CIf):
            if isinstance(item.then, CCompound):
                _scan_gotos(item.then.items, result)
            elif item.then:
                _scan_gotos([item.then], result)
            if item.otherwise:
                if isinstance(item.otherwise, CCompound):
                    _scan_gotos(item.otherwise.items, result)
                else:
                    _scan_gotos([item.otherwise], result)
        elif isinstance(item, (CWhile, CDoWhile)):
            if isinstance(item.body, CCompound):
                _scan_gotos(item.body.items, result)
        elif isinstance(item, CFor):
            if isinstance(item.body, CCompound):
                _scan_gotos(item.body.items, result)


def _replace_gotos_recursive(items: list, cleanup_labels: set) -> list:
    """Recursively replace goto stmts to cleanup labels with CEmpty."""
    from .c_ast import CGoto, CLabel, CIf, CWhile, CDoWhile, CFor, CCompound, CEmpty
    result = []
    for item in items:
        if isinstance(item, CGoto) and item.label in cleanup_labels:
            result.append(CEmpty())  # Remove the goto
        elif isinstance(item, CIf):
            new_then = item.then
            new_otherwise = item.otherwise
            if isinstance(item.then, CCompound):
                new_then = CCompound(items=_replace_gotos_recursive(item.then.items, cleanup_labels))
            elif isinstance(item.then, CGoto) and item.then.label in cleanup_labels:
                new_then = CEmpty()
            if isinstance(item.otherwise, CCompound):
                new_otherwise = CCompound(items=_replace_gotos_recursive(item.otherwise.items, cleanup_labels))
            elif isinstance(item.otherwise, CGoto) and hasattr(item.otherwise, 'label') and item.otherwise.label in cleanup_labels:
                new_otherwise = CEmpty()
            result.append(CIf(cond=item.cond, then=new_then, otherwise=new_otherwise))
        else:
            result.append(item)
    return result


def _transform_goto_defer(items: list) -> list:
    """Transform goto-cleanup patterns to defer blocks.

    Detects patterns like:
      if (!x) goto cleanup_X;
      ...
      cleanup_X:
        free(buf);

    Transforms to:
      defer { free(buf) }
      if (!x) {} (goto removed)
      ...
      (label and cleanup removed)
    """
    from .c_ast import CGoto, CLabel, CReturn

    # Scan for all goto targets (including nested)
    goto_targets: dict = {}
    _scan_gotos(items, goto_targets)

    labels: dict = {}  # label_name → index in items
    for i, item in enumerate(items):
        if isinstance(item, CLabel):
            labels[item.name] = i

    if not goto_targets or not labels:
        return list(items)

    # Find cleanup labels: labels at top level that are goto targets
    # Only transform if the label looks like a cleanup label
    cleanup_labels: dict = {}  # label_name → cleanup_stmts
    for label_name, label_idx in labels.items():
        if label_name not in goto_targets:
            continue

        # Only transform cleanup-looking labels (name contains cleanup/exit/error/done/fail)
        label_lower = label_name.lower()
        is_cleanup_label = any(s in label_lower for s in
                               ('cleanup', 'clean_up', 'error', 'fail', 'free'))
        if not is_cleanup_label:
            continue

        # Collect cleanup statements from label position
        cleanup_stmts = _collect_label_stmts(items, label_name)
        cleanup_labels[label_name] = cleanup_stmts

    if not cleanup_labels:
        return list(items)

    # Build transformed list:
    # 1. Emit defer blocks at the start (after initial declarations)
    # 2. Remove goto stmts to cleanup labels (at all levels)
    # 3. Remove label and its cleanup code from end
    skip_indices = set()
    for label_name in cleanup_labels:
        label_idx = labels[label_name]
        skip_indices.add(label_idx)
        for j in range(label_idx + 1, len(items)):
            item = items[j]
            if isinstance(item, (CReturn, CLabel)):
                break
            skip_indices.add(j)

    # Replace gotos recursively (builds new items list)
    new_items = _replace_gotos_recursive(
        [item for i, item in enumerate(items) if i not in skip_indices],
        set(cleanup_labels.keys())
    )

    # Insert defer blocks after declarations at the top
    result = []
    insert_pos = 0
    for i, item in enumerate(new_items):
        from .c_ast import CVarDecl
        if isinstance(item, CVarDecl):
            insert_pos = i + 1
        else:
            break

    for i, item in enumerate(new_items):
        result.append(item)
        if i == insert_pos - 1:
            # Emit defer blocks after the last declaration
            for label_name, cleanup_stmts in cleanup_labels.items():
                result.append(_DeferBlock(cleanup_stmts))

    # If no declarations, insert defer at the beginning
    if insert_pos == 0:
        defers = [_DeferBlock(stmts) for stmts in cleanup_labels.values()]
        result = defers + result

    return result


def _apply_self_rename(text: str, old_name: str) -> str:
    """Replace occurrences of old_name with 'self' in emitted text.

    Handles patterns like 'p.field', 'p->field' (already converted to 'p.field').
    Uses word-boundary-aware replacement.
    """
    import re
    # Replace 'old_name.X' with 'self.X' and standalone 'old_name' with 'self'
    # Use word boundaries to avoid replacing substrings
    result = re.sub(r'\b' + re.escape(old_name) + r'\b', 'self', text)
    return result


def _extract_assign_in_cond(cond: CExpr):
    """Detect assignment-in-condition pattern: (var = expr) != rhs.

    Returns (var_name, rhs_expr, cmp_op, cmp_rhs) if detected, else None.
    Handles:
      (c = getchar()) != EOF
      (c = f()) == EOF
    """
    if not isinstance(cond, CBinOp):
        return None
    cmp_op = cond.op
    if cmp_op not in ('!=', '==', '<', '>', '<=', '>='):
        return None

    left = cond.left
    right = cond.right

    # Check if left side is an assignment (possibly wrapped in parens/cast)
    assign_expr = None
    if isinstance(left, CAssign) and left.op == '=':
        assign_expr = left
    elif isinstance(left, CBinOp):
        # Might be wrapped
        pass

    if assign_expr is None:
        return None

    if not isinstance(assign_expr.target, CId):
        return None

    var_name = assign_expr.target.name
    rhs_expr = assign_expr.value
    return (var_name, rhs_expr, cmp_op, right)


def _invert_cmp(op: str) -> str:
    """Return the inverted comparison operator for break condition."""
    inversions = {'!=': '==', '==': '!=', '<': '>=', '>': '<=', '<=': '>', '>=': '<'}
    return inversions.get(op, op)


def _strip_enum_prefix(name: str) -> str:
    """Strip common UPPER_CASE_ enum prefixes and convert to snake_case.

    Examples:
      DIR_UP → up
      ACTOR_PLAYER → player
      STATE_IDLE → idle
      ENTITY_NONE → none
    """
    import re
    # Split at underscores, find common prefix pattern
    parts = name.split('_')
    if len(parts) >= 2:
        # Heuristic: the last part is the variant name, strip prefix
        variant = '_'.join(parts[1:]).lower()
        return variant
    return name.lower()
