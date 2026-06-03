"""PAK emitter: top-level orchestrator that converts a CFile to .pk64 source.

Pipeline:
  1. Register typedefs with TypeMapper.
  2. Run IdiomDetector to find tagged unions, method groups, fixed-point types.
  3. Emit declarations in order, skipping those consumed by idiom transformations.
  4. Emit impl blocks for detected method groups.
  5. Emit macro-derived const declarations.

Options (passed via EmitOptions):
  - preserve_comments: bool  — carry over C comments (not yet implemented)
  - no_idioms: bool          — skip idiom detection, emit literal translation
  - decomp: bool             — enable decomp-specific patterns
  - style: str               — 'default' | 'compact'
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple

from .c_ast import (
    CFile, CDecl,
    CTypeDef, CStructDecl, CUnionDecl, CEnumDecl,
    CFuncDecl, CFuncDef, CVarDecl,
    CField, CType,
    CPrimitive, CPointer, CArray, CStruct, CUnion, CEnum, CFuncPtr, CTypeRef,
    CFuncSignature, CParam,
)
from .type_mapper import TypeMapper
from .expr_mapper import ExprMapper
from .stmt_mapper import StmtMapper
from .decl_mapper import DeclMapper, _strip_prefix, _detect_enum_prefix, method_pak_name
from .idiom_detector import IdiomDetector, TaggedUnionInfo, MethodGroup
from .c_preprocess import SimpleMacro
from .n64_api import C_TO_PAK_API, get_use_statements


# Names from the parser prelude that should be suppressed in output
_PRELUDE_TYPEDEF_NAMES = frozenset({
    's8', 'u8', 's16', 'u16', 's32', 'u32', 's64', 'u64',
    'f32', 'f64',
    'int8_t', 'uint8_t', 'int16_t', 'uint16_t',
    'int32_t', 'uint32_t', 'int64_t', 'uint64_t',
    'size_t', 'ptrdiff_t', '__builtin_va_list', 'bool', 'FILE',
    'surface_t', 'wchar_t', 'uintptr_t', 'intptr_t',
})


@dataclass
class EmitOptions:
    preserve_comments: bool = False
    no_idioms: bool = False
    decomp: bool = False
    style: str = 'default'
    # Extra types from header resolver (name → type string)
    extra_types: Dict[str, str] = field(default_factory=dict)
    # Captured comments (line_num, text)
    comments: List[Tuple[int, str]] = field(default_factory=list)


class PakEmitter:
    """Converts a CFile AST to a .pk64 source string."""

    def __init__(self, options: EmitOptions = None):
        self.options = options or EmitOptions()
        self.tm = TypeMapper()
        self.em = ExprMapper(self.tm)
        self.sm = StmtMapper(self.tm, self.em)
        self.dm = DeclMapper(self.tm, self.em, self.sm)
        # Track which N64 modules are used
        self._used_n64_modules: Set[str] = set()

    def emit(self, c_file: CFile) -> str:
        """Convert *c_file* to a Pak source string."""
        lines: List[str] = []

        # Phase 1: Register all typedefs for type resolution
        self.tm.register_typedefs_from_decls(c_file.decls)

        # Register struct field names for named initializer support
        self.tm.register_struct_fields_from_decls(c_file.decls)

        # Phase 2: Run idiom detector
        detector = IdiomDetector(c_file)
        tagged_unions: List[TaggedUnionInfo] = []
        method_groups: List[MethodGroup] = []
        fixed_point_types: Dict[str, str] = {}

        if not self.options.no_idioms:
            tagged_unions = detector.detect_tagged_unions()
            method_groups = detector.detect_method_groups()
            fixed_point_types = detector.detect_fixed_point_typedefs()
            # Register fixed-point typedef overrides
            for td_name, fp_type in fixed_point_types.items():
                self.tm.register_typedef(td_name, CPrimitive(fp_type))

        # Build sets of names consumed by idiom transformations
        tagged_struct_names: Set[str] = {tu.struct_name for tu in tagged_unions}
        tagged_enum_names: Set[str] = {tu.tag_enum for tu in tagged_unions}

        method_func_names: Set[str] = set()
        for mg in method_groups:
            for m in mg.methods:
                method_func_names.add(m.sig.name)
                # Teach the expr mapper to rewrite calls to these functions
                # into method syntax, so call sites resolve to the impl symbol.
                self.em.method_map[m.sig.name] = (
                    mg.struct_name, method_pak_name(m.sig.name, mg.struct_name))

        # Phase 3: Emit macro-derived constants
        macro_lines = self._emit_macro_consts(c_file.macros)
        if macro_lines:
            lines.extend(macro_lines)
            lines.append('')

        # Phase 4: Emit variant declarations for tagged unions
        for tu in tagged_unions:
            lines.extend(self.dm.emit_variant(tu.struct_name, tu.cases))
            lines.append('')

        # Phase 5: Walk declarations and emit each one
        for decl in c_file.decls:
            emitted = self._emit_decl(decl, tagged_struct_names, tagged_enum_names,
                                      method_func_names, fixed_point_types)
            if emitted:
                lines.extend(emitted)
                lines.append('')

        # Phase 6: Emit impl blocks for method groups
        for mg in method_groups:
            impl_lines = self.dm.emit_impl_block(
                mg.struct_name, mg.methods, n64_modules=self._used_n64_modules)
            lines.extend(impl_lines)
            lines.append('')

        # Build final output: header + use declarations + body
        final_lines: List[str] = []
        final_lines.append('-- Transpiled from C by pak convert')
        final_lines.append('')

        # Phase 6: Insert top-level file comments if preserve_comments=True
        if self.options.preserve_comments and self.options.comments:
            for _lineno, comment_text in self.options.comments:
                final_lines.append(comment_text)
            final_lines.append('')

        # Add N64 use declarations
        if self._used_n64_modules:
            for use_line in get_use_statements(self._used_n64_modules):
                final_lines.append(use_line)
            final_lines.append('')

        final_lines.extend(lines)

        # Clean up trailing blank lines
        while final_lines and final_lines[-1] == '':
            final_lines.pop()
        final_lines.append('')  # final newline

        return '\n'.join(final_lines)

    # ── Declaration emission ──────────────────────────────────────────────────

    def _emit_decl(
            self, decl: CDecl,
            skip_structs: Set[str],
            skip_enums: Set[str],
            skip_funcs: Set[str],
            fixed_point_types: Dict[str, str],
    ) -> Optional[List[str]]:
        """Emit a single declaration. Returns None to skip."""

        if isinstance(decl, CTypeDef):
            return self._emit_typedef(decl, fixed_point_types)

        elif isinstance(decl, CStructDecl):
            if decl.name in skip_structs:
                return None
            return self.dm.emit_struct(decl)

        elif isinstance(decl, CUnionDecl):
            # Raw union (not consumed by a tagged union variant)
            return self.dm.emit_union(decl)

        elif isinstance(decl, CEnumDecl):
            if decl.name in skip_enums:
                return None  # enum replaced by a variant
            return self.dm.emit_enum(decl)

        elif isinstance(decl, CFuncDecl):
            if decl.sig.name in skip_funcs:
                return None
            # Extern forward declarations
            if decl.sig.is_extern:
                lines = []
                if decl.sig.is_variadic:
                    lines.append('-- c2pak: variadic function (trailing args not expressible in Pak)')
                lines.append(f'extern {self._sig_line(decl.sig)}')
                return lines
            # Skip non-extern forward decls (body will be emitted)
            return None

        elif isinstance(decl, CFuncDef):
            if decl.sig.name in skip_funcs:
                return None
            # Special case: main() → entry block
            if decl.sig.name == 'main':
                return self._emit_entry_block(decl)
            return self.dm.emit_func_def_full(decl, n64_modules=self._used_n64_modules)

        elif isinstance(decl, CVarDecl):
            return self.dm.emit_global_var(decl)

        return None

    def _emit_entry_block(self, defn: CFuncDef) -> List[str]:
        """Emit the C main() function as a Pak entry block."""
        from .stmt_mapper import StmtMapper
        lines = ['entry {']
        sm = StmtMapper(self.tm, self.em)
        sm._indent = 1
        sm._n64_modules = self._used_n64_modules
        body_lines: List[str] = []
        sm._emit_compound_items(defn.body.items, body_lines)
        lines.extend(body_lines)
        lines.append('}')
        return lines

    def _emit_typedef(self, decl: CTypeDef,
                      fixed_point_types: Dict[str, str]) -> Optional[List[str]]:
        """Emit a typedef as a Pak type alias or skip it."""
        name = decl.name
        typ = decl.typ

        # Suppress prelude-derived typedefs — they're just noise
        if name in _PRELUDE_TYPEDEF_NAMES:
            return None

        # Fixed-point types are registered but not emitted (they're replaced inline)
        if name in fixed_point_types:
            return [f'-- c2pak: typedef {name} → {fixed_point_types[name]}']

        # typedef struct { ... } Name; → struct Name { ... }
        if isinstance(typ, CStruct):
            if typ.fields:
                sd = CStructDecl(name=name, fields=typ.fields)
                return self.dm.emit_struct(sd)
            return None

        # typedef union { ... } Name; → union Name { ... }
        if isinstance(typ, CUnion):
            if typ.fields:
                ud = CUnionDecl(name=name, fields=typ.fields)
                return self.dm.emit_union(ud)
            return None

        # typedef enum { ... } Name;
        if isinstance(typ, CEnum):
            if typ.values:
                ed = CEnumDecl(name=name, values=typ.values)
                return self.dm.emit_enum(ed)
            return None

        # typedef T Name; → for primitive aliases, just skip (they're inlined)
        if isinstance(typ, CPrimitive):
            pak = self.tm._map_primitive(typ.name)
            if pak != name:
                return None  # Silently drop — the type is resolved inline
            return None

        # typedef T* Name; or typedef fn(...) Name;
        if isinstance(typ, CPointer):
            pak_type = self.tm.map_type(typ)
            # Suppress prelude-like pointer typedefs
            if name in _PRELUDE_TYPEDEF_NAMES:
                return None
            return [f'-- c2pak: type {name} = {pak_type}']

        if isinstance(typ, CFuncPtr):
            pak_type = self.tm.map_type(typ)
            return [f'type {name} = {pak_type}']

        # Otherwise just comment it out
        pak_type = self.tm.map_type(typ)
        return [f'-- c2pak: typedef {name} = {pak_type}']

    def _sig_line(self, sig: CFuncSignature) -> str:
        """Emit a function signature line."""
        params = ', '.join(
            f'{(p.name or "_p" + str(i))}: {self.tm.map_type(p.typ)}'
            for i, p in enumerate(sig.params)
            if not p.is_variadic
        )
        ret = self.tm.map_type(sig.ret)
        if self.tm.is_void(sig.ret):
            return f'fn {sig.name}({params})'
        return f'fn {sig.name}({params}) -> {ret}'

    # ── Macro constants ───────────────────────────────────────────────────────

    def _emit_macro_consts(self, macros: Dict[str, SimpleMacro]) -> List[str]:
        """Emit #define NAME value macros as Pak const declarations."""
        lines = []
        for name, macro in macros.items():
            if hasattr(macro, 'params'):
                # Function-like macro — skip for now
                lines.append(f'-- c2pak: macro {name}({", ".join(macro.params)}) = {macro.body}')
                continue
            # Simple constant: try to infer type
            val = macro.value
            pak_type, pak_val = self._infer_const_type(val)
            if pak_type:
                lines.append(f'const {name}: {pak_type} = {pak_val}')
            else:
                lines.append(f'-- c2pak: #define {name} {val}')
        return lines

    def _infer_const_type(self, val: str) -> Tuple[Optional[str], str]:
        """Infer the Pak type of a macro constant value.

        Returns (pak_type, pak_value) or (None, val) if unsure.
        """
        val = val.strip()
        # Integer hex
        if re.match(r'^0[xX][0-9a-fA-F]+[uUlL]*$', val):
            return 'u32', val.rstrip('uUlL')
        # Integer
        if re.match(r'^-?\d+[uUlL]*$', val):
            return 'i32', val.rstrip('uUlL')
        # Float
        if re.match(r'^-?\d+\.\d*[fFlL]?$', val):
            return 'f32', val.rstrip('fFlL')
        if re.match(r'^-?\d+[eE][+-]?\d+[fFlL]?$', val):
            return 'f32', val.rstrip('fFlL')
        # Boolean
        if val in ('1', 'true'):
            return 'bool', 'true'
        if val in ('0', 'false'):
            return 'bool', 'false'
        # NULL → none (skip)
        if val in ('NULL', '((void*)0)', '0'):
            return None, val
        return None, val


import re


def transpile(source: str, filename: str = '<input>',
              options: EmitOptions = None) -> str:
    """High-level entry point: C source string → Pak source string.

    Args:
        source: C source code text
        filename: file name for error messages
        options: emission options

    Returns:
        Pak source text

    Raises:
        ImportError: if pycparser is not installed
        ValueError: if C parsing fails
    """
    from .c_parser import parse_c_source
    c_file = parse_c_source(source, filename)
    emitter = PakEmitter(options)
    return emitter.emit(c_file)


def transpile_file(path, options: EmitOptions = None) -> str:
    """Transpile a C file to Pak source."""
    from pathlib import Path
    from .c_parser import parse_c_file
    p = Path(path)
    c_file = parse_c_file(p)
    emitter = PakEmitter(options)
    return emitter.emit(c_file)
