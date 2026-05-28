"""C declaration → Pak declaration string mapper (Phase 1).

Converts normalized CDecl objects (structs, enums, unions, function signatures,
global variables) to Pak source text.

Also handles impl block emission for method-grouped functions (Phase 3).
"""

from __future__ import annotations
import re
from typing import List, Dict, Optional, Tuple

from .c_ast import (
    CDecl, CTypeDef, CStructDecl, CUnionDecl, CEnumDecl,
    CFuncDecl, CFuncDef, CVarDecl,
    CParam, CFuncSignature, CField, CType,
    CPrimitive, CPointer, CArray, CStruct, CUnion, CEnum, CFuncPtr, CTypeRef,
    CFile,
)
from .type_mapper import TypeMapper
from .expr_mapper import ExprMapper
from .stmt_mapper import StmtMapper


def method_pak_name(c_name: str, struct_name: str) -> str:
    """Pak method name for a C function emitted into ``impl struct_name``.

    Strips the conventional ``{struct}_`` prefix (case-insensitive), e.g.
    ``player_init`` → ``init``. The single source of truth for this mapping so
    impl definitions and rewritten call sites always agree.
    """
    prefix = struct_name.lower() + '_'
    if c_name.lower().startswith(prefix):
        return c_name[len(prefix):]
    return c_name


class DeclMapper:
    """Converts C declaration AST nodes to Pak source strings."""

    def __init__(self, type_mapper: TypeMapper, expr_mapper: ExprMapper,
                 stmt_mapper: StmtMapper, enable_slice_transform: bool = True):
        self.tm = type_mapper
        self.em = expr_mapper
        self.sm = stmt_mapper
        self.enable_slice_transform = enable_slice_transform

    # ── Struct declarations ───────────────────────────────────────────────────

    def emit_struct(self, decl: CStructDecl) -> List[str]:
        """Emit a struct declaration."""
        lines = []
        # Annotations
        for attr in decl.attrs:
            if 'aligned' in attr:
                m = re.search(r'aligned\s*\((\d+)\)', attr)
                if m:
                    lines.append(f'@aligned({m.group(1)})')
            elif 'packed' in attr:
                lines.append('@packed')

        # Emit struct fields
        if not decl.fields:
            lines.append(f'struct {decl.name} {{}}')
            return lines

        # Single-line for small structs (≤3 fields, no complex types)
        if len(decl.fields) <= 3 and all(
            not isinstance(f.typ, (CStruct, CUnion)) for f in decl.fields
        ):
            fields_str = self._emit_fields_inline(decl.fields)
            lines.append(f'struct {decl.name} {{ {fields_str} }}')
        else:
            lines.append(f'struct {decl.name} {{')
            for f in decl.fields:
                lines.extend(self._emit_field(f))
            lines.append('}')
        return lines

    def _emit_fields_inline(self, fields: List[CField]) -> str:
        parts = []
        for f in fields:
            parts.append(f'{f.name}: {self._field_type(f)}')
        return ', '.join(parts)

    def _emit_field(self, field: CField) -> List[str]:
        typ_str = self._field_type(field)
        if field.bitsize is not None:
            # PAK has no bit-fields — widen to the next integer type and comment
            return [f'    {field.name}: {typ_str},  -- c2pak: bit-field {field.bitsize} bits']
        return [f'    {field.name}: {typ_str},']

    def _field_type(self, field: CField) -> str:
        return self.tm.field_type(field)

    # ── Union declarations ────────────────────────────────────────────────────

    def emit_union(self, decl: CUnionDecl) -> List[str]:
        """Emit a raw union declaration (non-tagged)."""
        lines = [f'union {decl.name} {{']
        for f in decl.fields:
            typ_str = self._field_type(f)
            lines.append(f'    {f.name}: {typ_str},')
        lines.append('}')
        return lines

    # ── Enum declarations ─────────────────────────────────────────────────────

    def emit_enum(self, decl: CEnumDecl) -> List[str]:
        """Emit an enum declaration with prefix stripping."""
        prefix = _detect_enum_prefix(decl.values)
        variants = []
        for name, val in decl.values:
            pak_name = _strip_prefix(name, prefix)
            if val is not None and not _is_sequential(val, variants):
                variants.append((pak_name, val))
            else:
                variants.append((pak_name, None))

        # Detect bitflags pattern (values are powers of 2)
        is_bitflag = _is_bitflag_enum(decl.values)
        lines = []
        if is_bitflag:
            lines.append(f'-- c2pak: bitflag enum')

        # Emit base type annotation if present
        base = decl.base_type
        if base:
            pak_base = self.tm._map_primitive(base)
            lines.append(f'enum {decl.name}: {pak_base} {{')
        else:
            lines.append(f'enum {decl.name} {{')

        for pak_name, val in variants:
            if val is not None:
                lines.append(f'    {pak_name} = {val},')
            else:
                lines.append(f'    {pak_name},')

        lines.append('}')
        return lines

    # ── Variant declarations (tagged unions — produced by idiom_detector) ─────

    def emit_variant(self, name: str, cases: List[Tuple[str, List[CField]]]) -> List[str]:
        """Emit a variant (tagged union) declaration."""
        lines = [f'variant {name} {{']
        for case_name, fields in cases:
            if not fields:
                lines.append(f'    {case_name},')
            elif len(fields) == 1:
                ftype = self.tm.field_type(fields[0])
                lines.append(f'    {case_name}({ftype}),')
            else:
                fstr = ', '.join(f'{f.name}: {self.tm.field_type(f)}' for f in fields)
                lines.append(f'    {case_name} {{ {fstr} }},')
        lines.append('}')
        return lines

    # ── Function declarations and definitions ─────────────────────────────────

    def emit_func_decl(self, decl: CFuncDecl) -> List[str]:
        """Emit a forward function declaration."""
        sig = self._emit_sig(decl.sig)
        return [sig]

    def emit_func_def(self, defn: CFuncDef, method_of: str = None) -> List[str]:
        """Emit a function definition (with body).

        method_of: if set, strip the struct prefix from the function name and
                   use 'self' as the first parameter name.
        """
        lines = []
        sig_str = self._emit_sig(defn.sig, method_of=method_of)
        lines.append(sig_str + ' {')
        # Emit body with 1 indent
        sm = StmtMapper(self.tm, self.em)
        sm._indent = 1
        body_lines: List[str] = []
        sm._emit_compound_items(defn.sig_body_items(defn.body), body_lines)
        lines.extend(body_lines)
        lines.append('}')
        return lines

    def emit_func_def_full(self, defn: CFuncDef, method_of: str = None,
                           n64_modules: set = None) -> List[str]:
        """Emit a complete function definition."""
        lines = []
        sig_str = self._emit_sig(defn.sig, method_of=method_of)
        lines.append(sig_str + ' {')
        sm = StmtMapper(self.tm, self.em)
        sm._indent = 1
        # Set up self-rename if this is a method
        if method_of and defn.sig.params:
            first_param = defn.sig.params[0]
            if first_param.name and self.tm.is_pointer_to(first_param.typ, method_of):
                sm._self_rename = first_param.name  # old param name → self
        if n64_modules is not None:
            sm._n64_modules = n64_modules
        body_lines: List[str] = []
        sm._emit_compound_items(defn.body.items, body_lines)
        lines.extend(body_lines)
        lines.append('}')
        return lines

    def _emit_sig(self, sig: CFuncSignature, method_of: str = None) -> str:
        """Emit a function signature line (fn name(params) -> ret)."""
        name = sig.name
        if method_of:
            name = method_pak_name(name, method_of)

        if self.enable_slice_transform:
            params = self._emit_params_with_slices(sig.params, method_of=method_of)
        else:
            params = self._emit_params(sig.params, method_of=method_of)
        ret = self.tm.map_type(sig.ret)

        # No pub by default — only explicitly exported functions get pub
        # (static functions definitely don't get pub)
        if self.tm.is_void(sig.ret):
            return f'fn {name}({params})'
        return f'fn {name}({params}) -> {ret}'

    def _emit_params(self, params: List[CParam], method_of: str = None,
                    skip_indices: set = None) -> str:
        parts = []
        skip_indices = skip_indices or set()
        for i, p in enumerate(params):
            if i in skip_indices:
                continue
            if p.is_variadic:
                parts.append('...')
                continue
            # Strip C's (void) parameter — a single void param means no params
            typ = self.tm.map_type(p.typ)
            if typ == 'void':
                continue  # skip void params
            name = p.name or f'_p{i}'
            # First param that's a pointer to method_of struct → rename to self
            if method_of and i == 0 and self.tm.is_pointer_to(p.typ, method_of):
                if isinstance(p.typ, CPointer) and not p.typ.is_const:
                    parts.append(f'self: *mut {method_of}')
                else:
                    parts.append(f'self: *{method_of}')
                continue
            parts.append(f'{name}: {typ}')
        return ', '.join(parts)

    def _emit_params_with_slices(self, params: List[CParam], method_of: str = None) -> str:
        """Emit parameters, converting (ptr, len) pairs to slice params."""
        from .c_ast import CPointer, CPrimitive
        from .type_mapper import _PRIMITIVE_MAP

        # Detect (ptr, len) pairs
        skip_indices: set = set()
        slice_params: dict = {}  # ptr_idx → (ptr_name, inner_type, len_name)

        for i, p in enumerate(params):
            if not isinstance(p.typ, CPointer):
                continue
            inner = self.tm.map_type(p.typ.inner if hasattr(p.typ, 'inner') else p.typ)
            for j in range(i + 1, min(i + 3, len(params))):
                q = params[j]
                q_typ = self.tm.map_type(q.typ)
                if q_typ not in ('i32', 'u32', 'i64', 'u64', 'i16', 'u16'):
                    continue
                q_name = q.name or ''
                if any(s in q_name.lower() for s in ('len', 'count', 'size', 'n', 'num', 'cnt')):
                    # Found a (ptr, len) pair
                    ptr_name = p.name or f'_p{i}'
                    inner_type = self.tm.map_type(p.typ.inner) if hasattr(p.typ, 'inner') else '*u8'
                    mut_str = 'mut ' if not p.typ.is_const else ''
                    slice_params[i] = (ptr_name, f'[]{mut_str}{inner_type}')
                    skip_indices.add(j)
                    break

        parts = []
        for i, p in enumerate(params):
            if i in skip_indices:
                continue
            if p.is_variadic:
                parts.append('...')
                continue
            typ = self.tm.map_type(p.typ)
            if typ == 'void':
                continue
            name = p.name or f'_p{i}'
            if method_of and i == 0 and self.tm.is_pointer_to(p.typ, method_of):
                if isinstance(p.typ, CPointer) and not p.typ.is_const:
                    parts.append(f'self: *mut {method_of}')
                else:
                    parts.append(f'self: *{method_of}')
                continue
            if i in slice_params:
                _, slice_type = slice_params[i]
                parts.append(f'{name}: {slice_type}')
            else:
                parts.append(f'{name}: {typ}')
        return ', '.join(parts)

    # ── Global variable declarations ──────────────────────────────────────────

    def emit_global_var(self, decl: CVarDecl) -> List[str]:
        pak_type = self.tm.map_type(decl.typ)
        if decl.is_extern:
            return [f'extern static {decl.name}: {pak_type}']
        if decl.is_const:
            kw = 'const'
        elif decl.is_static:
            kw = 'static'
        else:
            kw = 'static mut'

        if decl.init is not None:
            init_str = self.em.emit(decl.init)
            return [f'{kw} {decl.name}: {pak_type} = {init_str}']
        else:
            zero = _zero_for_type(pak_type)
            return [f'{kw} {decl.name}: {pak_type} = {zero}']

    # ── impl blocks ───────────────────────────────────────────────────────────

    def emit_impl_block(self, struct_name: str,
                        methods: List[CFuncDef],
                        n64_modules: set = None) -> List[str]:
        """Emit an impl block grouping methods for a struct."""
        lines = [f'impl {struct_name} {{']
        for i, method in enumerate(methods):
            if i > 0:
                lines.append('')
            method_lines = self.emit_func_def_full(
                method, method_of=struct_name, n64_modules=n64_modules)
            for ml in method_lines:
                lines.append('    ' + ml)
        lines.append('}')
        return lines


# ── Enum utility functions ────────────────────────────────────────────────────

def _detect_enum_prefix(values: List[Tuple[str, Optional[int]]]) -> str:
    """Detect a common prefix shared by all enum value names.

    E.g. ['DIR_UP', 'DIR_DOWN', 'DIR_LEFT', 'DIR_RIGHT'] → 'DIR_'
    """
    if not values:
        return ''
    names = [v[0] for v in values]
    if len(names) == 1:
        # single-value enum — don't strip
        return ''
    # Find common prefix up to and including the last '_'
    prefix = _common_prefix(names)
    # Trim to the last underscore
    idx = prefix.rfind('_')
    if idx >= 0:
        return prefix[:idx + 1]
    return ''


def _common_prefix(strings: List[str]) -> str:
    if not strings:
        return ''
    s = strings[0]
    for other in strings[1:]:
        while not other.startswith(s):
            s = s[:-1]
            if not s:
                return ''
    return s


def _strip_prefix(name: str, prefix: str) -> str:
    """Strip *prefix* from *name* and convert to lowercase snake_case."""
    if prefix and name.startswith(prefix):
        name = name[len(prefix):]
    return name.lower()


def _is_sequential(val: int, seen: List[Tuple[str, Optional[int]]]) -> bool:
    """Return True if *val* equals the expected sequential value (0, 1, 2...)."""
    return val == len(seen)


def _is_bitflag_enum(values: List[Tuple[str, Optional[int]]]) -> bool:
    """Return True if all explicit values are distinct powers of 2."""
    explicit = [v for _, v in values if v is not None]
    if len(explicit) < 2:
        return False
    return all(v > 0 and (v & (v - 1)) == 0 for v in explicit)


def _zero_for_type(pak_type: str) -> str:
    """Return a zero/default value for a Pak type."""
    if pak_type in ('i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64'):
        return '0'
    if pak_type in ('f32', 'f64'):
        return '0.0'
    if pak_type == 'bool':
        return 'false'
    if pak_type.startswith('*'):
        return 'none'
    return '0'
