"""C expression → Pak expression string mapper (Phase 2).

Converts normalized CExpr objects to Pak source text strings.

Key transformations:
  - C operators map directly to Pak operators (most are identical)
  - NULL → none
  - ptr->field → ptr.field  (Pak auto-derefs)
  - (T)expr → expr as T
  - a ? b : c → if a { b } else { c }
  - sizeof(T) → sizeof(T)
  - Increment/decrement in sub-expressions requires extraction (handled by stmt_mapper)
"""

from __future__ import annotations
from typing import List, Tuple

from .c_ast import (
    CExpr, CConst, CId, CBinOp, CUnaryOp, CAssign, CCall,
    CArrayRef, CStructRef, CCast, CTernary, CComma, CSizeof, COffsetof,
    CInitList, CType,
    CPrimitive, CPointer, CArray, CStruct, CUnion, CEnum, CFuncPtr, CTypeRef,
)
from .type_mapper import TypeMapper


class ExprMapper:
    """Converts CExpr nodes to Pak source strings."""

    def __init__(self, type_mapper: TypeMapper):
        self.tm = type_mapper
        # C function name → (struct_name, pak_method_name) for functions that
        # are emitted as impl methods. Call sites to these must use method
        # syntax so the symbol matches the impl definition ({Struct}_{method}).
        self.method_map: dict = {}

    def emit(self, expr: CExpr, parens: bool = False) -> str:
        """Convert *expr* to a Pak source string.

        parens=True wraps the result in parentheses if needed for precedence.
        """
        result = self._emit(expr)
        if parens and self._needs_parens(expr):
            return f'({result})'
        return result

    # ── Dispatch ──────────────────────────────────────────────────────────────

    def _emit(self, expr: CExpr) -> str:
        if isinstance(expr, CConst):
            return self._emit_const(expr)
        elif isinstance(expr, CId):
            return self._emit_id(expr)
        elif isinstance(expr, CBinOp):
            return self._emit_binop(expr)
        elif isinstance(expr, CUnaryOp):
            return self._emit_unary(expr)
        elif isinstance(expr, CAssign):
            return self._emit_assign(expr)
        elif isinstance(expr, CCall):
            return self._emit_call(expr)
        elif isinstance(expr, CArrayRef):
            return self._emit_array_ref(expr)
        elif isinstance(expr, CStructRef):
            return self._emit_struct_ref(expr)
        elif isinstance(expr, CCast):
            return self._emit_cast(expr)
        elif isinstance(expr, CTernary):
            return self._emit_ternary(expr)
        elif isinstance(expr, CComma):
            # Comma in expression context: return last value (side effects lost here)
            # The stmt_mapper handles extraction of side effects from comma sequences
            if expr.exprs:
                return self._emit(expr.exprs[-1])
            return '()'
        elif isinstance(expr, CSizeof):
            return self._emit_sizeof(expr)
        elif isinstance(expr, COffsetof):
            return self._emit_offsetof(expr)
        elif isinstance(expr, CInitList):
            return self._emit_init_list(expr)
        else:
            return f'/* expr:{type(expr).__name__} */'

    # ── Constants ─────────────────────────────────────────────────────────────

    def _emit_const(self, expr: CConst) -> str:
        v = expr.value
        # NULL → none
        if v == 'NULL' or v == '((void*)0)':
            return 'none'
        # Remove C-specific suffixes: 1.5f → 1.5, 42u → 42, 42UL → 42
        if expr.kind in ('float', 'double'):
            v = v.rstrip('fFlL')
            # Ensure there's a decimal point
            if '.' not in v and 'e' not in v.lower():
                v = v + '.0'
            return v
        if expr.kind == 'int':
            v = v.rstrip('uUlL')
            return v
        if expr.kind in ('string', 'char'):
            return v  # keep as-is (C string literals work in Pak)
        return v

    # ── Identifiers ───────────────────────────────────────────────────────────

    def _emit_id(self, expr: CId) -> str:
        name = expr.name
        # Common C identifiers that have Pak equivalents
        if name == 'NULL':
            return 'none'
        if name == 'true':
            return 'true'
        if name == 'false':
            return 'false'
        if name == 'EOF':
            return 'EOF'
        return name

    # ── Binary operators ──────────────────────────────────────────────────────

    # C → Pak operator mapping (most are identical)
    _BINOP_MAP = {
        '+': '+', '-': '-', '*': '*', '/': '/', '%': '%',
        '&': '&', '|': '|', '^': '^', '<<': '<<', '>>': '>>',
        '==': '==', '!=': '!=',
        '<': '<', '>': '>', '<=': '<=', '>=': '>=',
        '&&': '&&', '||': '||',
        # Comma is handled above
    }

    def _emit_binop(self, expr: CBinOp) -> str:
        op = self._BINOP_MAP.get(expr.op, expr.op)
        left = self._emit_child(expr, expr.left, 'left')
        right = self._emit_child(expr, expr.right, 'right')
        return f'{left} {op} {right}'

    def _emit_child(self, parent: CBinOp, child: CExpr, side: str) -> str:
        """Emit a child expression, wrapping in parens if needed for precedence."""
        needs = False
        if isinstance(child, CBinOp):
            needs = _binop_needs_parens(parent.op, child.op, side == 'right')
        elif isinstance(child, CTernary):
            needs = True
        s = self._emit(child)
        return f'({s})' if needs else s

    # ── Unary operators ───────────────────────────────────────────────────────

    def _emit_unary(self, expr: CUnaryOp) -> str:
        op = expr.op
        inner = self._emit(expr.expr)
        if expr.postfix:
            # x++ / x-- — in expression context emit as x (side effect stripped)
            # The stmt_mapper extracts pre/post increments to separate statements
            if op == '++':
                return inner  # value is expr, side effect extracted by stmt_mapper
            elif op == '--':
                return inner
        else:
            if op == '++':
                return inner   # ++x same value as x after increment
            elif op == '--':
                return inner
            elif op == '-':
                if isinstance(expr.expr, (CConst, CId)):
                    return f'-{inner}'
                return f'-({inner})'
            elif op == '~':
                return f'~{inner}'
            elif op == '!':
                return f'!{inner}'
            elif op == '&':
                # Take address: &x → &x or &mut x
                # Use &mut by default (most C code takes mutable addresses)
                return f'&mut {inner}'
            elif op == '*':
                # Dereference: *ptr → *ptr
                return f'*{inner}'
            elif op == 'sizeof':
                return f'sizeof({inner})'
        return f'{op}{inner}'

    # ── Assignment ────────────────────────────────────────────────────────────

    # Pak supports all C compound assignment operators directly
    _ASSIGN_OPS = {'=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>='}

    def _emit_assign(self, expr: CAssign) -> str:
        op = expr.op
        target = self._emit(expr.target)
        value = self._emit(expr.value)
        return f'{target} {op} {value}'

    # ── Function calls ────────────────────────────────────────────────────────

    def _emit_call(self, expr: CCall) -> str:
        # Functions detected as methods are emitted inside an impl block, so a
        # C call `vec2_init(&v, a, b)` must become `v.init(a, b)` — otherwise it
        # references a free `vec2_init` symbol that the impl never defines.
        if isinstance(expr.func, CId) and expr.func.name in self.method_map and expr.args:
            _struct, method = self.method_map[expr.func.name]
            recv = self._emit(expr.args[0])
            # Pak method calls take the receiver's address implicitly, so drop a
            # leading address-of (`&v` or `&mut v`) produced for the C pointer arg.
            for pre in ('&mut ', '&'):
                if recv.startswith(pre):
                    recv = recv[len(pre):]
                    break
            rest = ', '.join(self._emit(a) for a in expr.args[1:])
            return f'{recv}.{method}({rest})'
        func = self._emit(expr.func)
        args = ', '.join(self._emit(a) for a in expr.args)
        return f'{func}({args})'

    # ── Array / struct access ─────────────────────────────────────────────────

    def _emit_array_ref(self, expr: CArrayRef) -> str:
        base = self._emit(expr.base)
        idx = self._emit(expr.index)
        return f'{base}[{idx}]'

    def _emit_struct_ref(self, expr: CStructRef) -> str:
        base = self._emit(expr.base)
        # Pak auto-derefs pointers with dot access, so ptr->field == ptr.field
        return f'{base}.{expr.member}'

    # ── Casts ─────────────────────────────────────────────────────────────────

    def _emit_cast(self, expr: CCast) -> str:
        pak_type = self.tm.map_type(expr.typ)
        inner = self._emit(expr.expr)
        # (void)expr → just emit expr (discard cast)
        if pak_type == 'void':
            return inner
        # Pointer cast: (T *)expr → expr as *T
        # Value cast: (int)f → f as i32
        if isinstance(expr.expr, (CId, CConst, CArrayRef, CStructRef, CCall)):
            return f'{inner} as {pak_type}'
        return f'({inner}) as {pak_type}'

    # ── Ternary ───────────────────────────────────────────────────────────────

    def _emit_ternary(self, expr: CTernary) -> str:
        cond = self._emit(expr.cond)
        then = self._emit(expr.then)
        otherwise = self._emit(expr.otherwise)
        return f'if {cond} {{ {then} }} else {{ {otherwise} }}'

    # ── sizeof / offsetof ─────────────────────────────────────────────────────

    def _emit_sizeof(self, expr: CSizeof) -> str:
        if isinstance(expr.target, CType):
            pak_type = self.tm.map_type(expr.target)
            return f'sizeof({pak_type})'
        else:
            inner = self._emit(expr.target)
            return f'sizeof({inner})'

    def _emit_offsetof(self, expr: COffsetof) -> str:
        pak_type = self.tm.map_type(expr.struct_type)
        return f'offsetof({pak_type}, {expr.member})'

    # ── Initializer lists ─────────────────────────────────────────────────────

    def _emit_init_list(self, expr: CInitList) -> str:
        """Emit a C initializer list as a Pak initializer."""
        # This is incomplete without knowing the target type.
        # The decl_mapper provides better context when emitting let bindings.
        items = []
        for item in expr.items:
            if isinstance(item, tuple):
                field_name, val = item
                items.append(f'{field_name}: {self._emit(val)}')
            else:
                items.append(self._emit(item))
        return '{ ' + ', '.join(items) + ' }' if items else '{}'

    # ── Truthiness conversion ─────────────────────────────────────────────────

    def emit_as_bool(self, expr: CExpr) -> str:
        """Emit *expr* as a boolean condition (Pak-style).

        In C, any non-zero value is truthy. In Pak:
          - Pointers: ptr != none
          - Integers: n != 0
          - Already a bool comparison: pass through
        """
        # If it's already a comparison/logical op, pass through
        if isinstance(expr, CBinOp) and expr.op in (
                '==', '!=', '<', '>', '<=', '>=', '&&', '||'):
            return self._emit_binop(expr)
        if isinstance(expr, CUnaryOp) and expr.op == '!':
            inner = self.emit_as_bool(expr.expr)
            return f'!({inner})' if ' ' in inner else f'!{inner}'
        # Otherwise wrap
        inner = self._emit(expr)
        return inner

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _needs_parens(self, expr: CExpr) -> bool:
        return isinstance(expr, (CBinOp, CTernary, CAssign, CComma))

    def needs_increment_extraction(self, expr: CExpr) -> bool:
        """Return True if this expression contains a pre/post increment/decrement
        that must be extracted to a separate statement by the stmt_mapper."""
        return _has_side_effect_unary(expr)


def _has_side_effect_unary(expr: CExpr) -> bool:
    """Check recursively if any sub-expression has a ++ or -- operator."""
    if isinstance(expr, CUnaryOp) and expr.op in ('++', '--'):
        return True
    for child in _children(expr):
        if _has_side_effect_unary(child):
            return True
    return False


def _children(expr: CExpr):
    """Yield direct child expressions."""
    if isinstance(expr, CBinOp):
        yield expr.left
        yield expr.right
    elif isinstance(expr, CUnaryOp):
        yield expr.expr
    elif isinstance(expr, CAssign):
        yield expr.target
        yield expr.value
    elif isinstance(expr, CCall):
        yield expr.func
        yield from expr.args
    elif isinstance(expr, CArrayRef):
        yield expr.base
        yield expr.index
    elif isinstance(expr, CStructRef):
        yield expr.base
    elif isinstance(expr, CCast):
        yield expr.expr
    elif isinstance(expr, CTernary):
        yield expr.cond
        yield expr.then
        yield expr.otherwise
    elif isinstance(expr, CComma):
        yield from expr.exprs


# Operator precedence for parenthesization decisions
_PREC = {
    '||': 1, '&&': 2,
    '|': 3, '^': 4, '&': 5,
    '==': 6, '!=': 6,
    '<': 7, '>': 7, '<=': 7, '>=': 7,
    '<<': 8, '>>': 8,
    '+': 9, '-': 9,
    '*': 10, '/': 10, '%': 10,
}


def _binop_needs_parens(parent_op: str, child_op: str, is_right: bool) -> bool:
    """Return True if a child binary op needs parentheses inside parent op."""
    p_prec = _PREC.get(parent_op, 0)
    c_prec = _PREC.get(child_op, 0)
    if c_prec < p_prec:
        return True
    # Same precedence: left-associative operators don't need parens on the left,
    # but do on the right for non-commutative ops.
    if c_prec == p_prec and is_right and parent_op in ('-', '/', '%', '<<', '>>'):
        return True
    return False
