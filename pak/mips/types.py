"""Type layout engine for the MIPS backend.

Computes the size, alignment, and field offsets of every PAK type as they
would appear in memory on the N64 (MIPS o32 / 32-bit ABI), matching the
layout that GCC would use for the equivalent C struct.

Rules (standard C natural-alignment):
    - Each field is aligned to the smaller of its natural alignment and the
      platform's maximum alignment (8 bytes on MIPS o32).
    - Struct total size is padded to its largest field alignment.
    - Bit-fields: packed into a host unit of the declared width; a new host
      unit begins whenever the next bit-field does not fit.
    - @aligned(N) annotation overrides a struct's alignment to max(N, natural).
    - @c_layout annotation forces the same layout as a C struct (default here).
    - Slices ([]T) are fat pointers: {ptr: *T (4 bytes), len: i32 (4 bytes)} → 8 bytes.
    - Result(T, E): {is_ok: bool (1 byte, padded), union { T, E }}.
    - Option(?T): nullable pointer when T is a pointer type, else {has_val: bool, T}.

Usage::

    from pak.mips.types import TypeLayout, TypeEnv as MipsTypeEnv
    tenv = MipsTypeEnv()
    tenv.register_structs(program)          # walk AST, build layouts
    layout = tenv.layout_of_name('Player')  # → TypeLayout
    print(layout.size, layout.fields['x'])  # 4, FieldInfo(offset=0, size=4, ...)
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any


# ── Primitive type table ──────────────────────────────────────────────────────

# name → (size_bytes, align_bytes, is_float, is_signed)
_PRIMITIVES: Dict[str, tuple] = {
    'void':     (0, 1,  False, False),
    'bool':     (1, 1,  False, False),
    'byte':     (1, 1,  False, False),
    'c_char':   (1, 1,  False, True),
    'i8':       (1, 1,  False, True),
    'u8':       (1, 1,  False, False),
    'i16':      (2, 2,  False, True),
    'u16':      (2, 2,  False, False),
    'i32':      (4, 4,  False, True),
    'u32':      (4, 4,  False, False),
    'i64':      (8, 8,  False, True),
    'u64':      (8, 8,  False, False),
    'f32':      (4, 4,  True,  True),
    'f64':      (8, 8,  True,  True),
    # Fixed-point types: stored as their backing integer
    'fix16.16': (4, 4,  False, True),   # Q16.16 → i32
    'fix10.5':  (2, 2,  False, True),   # Q10.5  → i16
    'fix1.15':  (2, 2,  False, True),   # Q1.15  → i16
    # Pointers (32-bit MIPS)
    'ptr':      (4, 4,  False, False),
    '*T':       (4, 4,  False, False),
}

# Fixed-point fractional bits
FRAC_BITS: Dict[str, int] = {
    'fix16.16': 16,
    'fix10.5':  5,
    'fix1.15':  15,
}


# ── Core layout types ─────────────────────────────────────────────────────────

@dataclass
class FieldInfo:
    name:   str
    offset: int     # byte offset from start of struct
    size:   int     # size in bytes
    align:  int     # natural alignment in bytes
    type_node: Any  # original AST type node (for recursive use)


@dataclass
class TypeLayout:
    """Memory layout of a PAK type."""
    size:      int
    align:     int
    is_float:  bool = False
    is_signed: bool = True
    is_ptr:    bool = False
    is_slice:  bool = False

    # Non-empty for structs and variant payloads
    fields:    Dict[str, FieldInfo] = field(default_factory=dict)
    field_order: List[str]          = field(default_factory=list)

    # Variant tag info
    tag_offset: int  = 0
    tag_size:   int  = 0

    # Fixed-point fractional bits (0 = not fixed-point)
    frac_bits:  int  = 0

    # Load/store width helpers
    @property
    def load_instr(self) -> str:
        """MIPS load instruction for this type (GPR-based)."""
        if self.is_float:
            return 'lwc1' if self.size == 4 else 'ldc1'
        match self.size:
            case 4: return 'lw'
            case 2: return 'lhu' if not self.is_signed else 'lh'
            case 1: return 'lbu' if not self.is_signed else 'lb'
            case _: return 'lw'  # caller handles multi-word

    @property
    def store_instr(self) -> str:
        if self.is_float:
            return 'swc1' if self.size == 4 else 'sdc1'
        match self.size:
            case 4: return 'sw'
            case 2: return 'sh'
            case 1: return 'sb'
            case _: return 'sw'

    @property
    def is_fixed_point(self) -> bool:
        return self.frac_bits > 0

    def field_info(self, name: str) -> Optional[FieldInfo]:
        return self.fields.get(name)


# ── Layout computation ────────────────────────────────────────────────────────

class MipsTypeEnv:
    """Registry of all type layouts for a compilation unit."""

    def __init__(self):
        self._layouts: Dict[str, TypeLayout] = {}
        self._enum_values: Dict[str, Dict[str, int]] = {}  # enum_name → {case → int}
        self._variant_decls = {}

    # ── External (library) types ─────────────────────────────────────────────

    # Well-known types from tiny3d and libdragon that PAK programs commonly
    # import via ``use t3d.math`` etc.  These are not in the AST so we
    # pre-register them so that ``layout_of_name`` can resolve them.
    _EXTERNAL_TYPES: Dict[str, TypeLayout] = {
        # tiny3d math types
        'Vec3':        TypeLayout(size=12,  align=4,  is_float=True),
        'Mat4':        TypeLayout(size=64,  align=4,  is_float=True),
        'Quat':        TypeLayout(size=16,  align=4,  is_float=True),
        'Color':       TypeLayout(size=4,   align=4),
        'T3DMat4FP':   TypeLayout(size=128, align=16, is_float=False),
        'T3DViewport': TypeLayout(size=128, align=16),
    }

    def _register_external_types(self) -> None:
        """Pre-register well-known external types (tiny3d, libdragon)."""
        for name, layout in self._EXTERNAL_TYPES.items():
            if name not in self._layouts:
                self._layouts[name] = layout

    # ── Registration ─────────────────────────────────────────────────────────

    def register_program(self, program) -> None:
        """Walk a parsed Program AST and register all struct/enum/variant layouts."""
        from .. import ast

        # Register well-known external types first so that user structs
        # containing e.g. Vec3 fields can resolve them.
        self._register_external_types()

        # First pass: register primitives so recursive structs can use them
        # Second pass: enums, third pass: structs, fourth pass: variants
        enums    = []
        structs  = []
        variants = []

        for decl in program.decls:
            if isinstance(decl, ast.EnumDecl):
                enums.append(decl)
            elif isinstance(decl, ast.StructDecl):
                structs.append(decl)
            elif isinstance(decl, ast.VariantDecl):
                variants.append(decl)

        for e in enums:
            self._register_enum(e)
        for s in structs:
            self._register_struct(s)
        for v in variants:
            self._register_variant(v)
            self._variant_decls[v.name] = v

    def _register_enum(self, decl) -> None:
        base = getattr(decl, 'base_type', None) or 'i32'
        prim = _PRIMITIVES.get(base, _PRIMITIVES['i32'])
        layout = TypeLayout(size=prim[0], align=prim[1], is_signed=prim[3])
        self._layouts[decl.name] = layout

        val = 0
        case_map: Dict[str, int] = {}
        for v in decl.variants:
            if v.value is not None:
                from .. import ast as _ast
                if isinstance(v.value, _ast.IntLit):
                    val = v.value.value
            case_map[v.name] = val
            val += 1
        self._enum_values[decl.name] = case_map

    def _register_struct(self, decl) -> None:
        # Check @aligned annotation
        forced_align = None
        for ann in getattr(decl, 'annotations', []):
            if isinstance(ann, str) and ann.startswith('aligned('):
                try:
                    forced_align = int(ann[8:-1])
                except ValueError:
                    pass

        fields: Dict[str, FieldInfo] = {}
        order: List[str] = []
        offset = 0
        max_align = 1

        for sf in decl.fields:
            fl = self.layout_of_type(sf.type)
            a = fl.align
            max_align = max(max_align, a)
            # Pad to alignment
            offset = (offset + a - 1) & ~(a - 1)
            fi = FieldInfo(name=sf.name, offset=offset, size=fl.size,
                           align=a, type_node=sf.type)
            fields[sf.name] = fi
            order.append(sf.name)
            offset += fl.size

        if forced_align:
            max_align = max(max_align, forced_align)

        # Pad struct to alignment
        total = (offset + max_align - 1) & ~(max_align - 1)
        if total == 0:
            total = max_align if max_align > 0 else 1

        layout = TypeLayout(size=total, align=max_align, fields=fields,
                            field_order=order)
        self._layouts[decl.name] = layout

    def _register_variant(self, decl) -> None:
        """Variant (tagged union): tag field + union of all case payloads."""
        max_payload_size  = 0
        max_payload_align = 1
        n_cases = len(decl.cases)

        # Determine tag type (smallest int that fits all cases)
        if n_cases <= 0x100:
            tag_size, tag_align = 1, 1
        elif n_cases <= 0x10000:
            tag_size, tag_align = 2, 2
        else:
            tag_size, tag_align = 4, 4

        for case in decl.cases:
            case_size  = 0
            case_align = 1
            for sf in case.fields:
                # fields may be StructField objects, (name, type) tuples,
                # or bare type nodes (positional fields)
                if isinstance(sf, tuple):
                    ftype = sf[1]
                elif hasattr(sf, 'type'):
                    ftype = sf.type
                else:
                    ftype = sf  # positional field: sf IS the type node
                fl = self.layout_of_type(ftype)
                case_align = max(case_align, fl.align)
                # Align within case
                case_size  = (case_size + fl.align - 1) & ~(fl.align - 1)
                case_size += fl.size
            max_payload_size  = max(max_payload_size, case_size)
            max_payload_align = max(max_payload_align, case_align)

        # Layout: [tag | padding | payload_union]
        payload_offset = (tag_size + max_payload_align - 1) & ~(max_payload_align - 1)
        total_align    = max(tag_align, max_payload_align)
        total_size     = (payload_offset + max_payload_size + total_align - 1) & ~(total_align - 1)
        if total_size == 0:
            total_size = total_align

        layout = TypeLayout(
            size=total_size, align=total_align,
            tag_offset=0, tag_size=tag_size,
        )
        self._layouts[decl.name] = layout

    # ── Layout resolution ─────────────────────────────────────────────────────

    def layout_of_name(self, name: str) -> TypeLayout:
        if name in self._layouts:
            return self._layouts[name]
        if name in _PRIMITIVES:
            s, a, fl, sg = _PRIMITIVES[name]
            fb = FRAC_BITS.get(name, 0)
            return TypeLayout(size=s, align=a, is_float=fl, is_signed=sg, frac_bits=fb)
        raise KeyError(f"Unknown type: {name!r}")

    def layout_of_type(self, type_node) -> TypeLayout:
        """Resolve a PAK AST type node to a TypeLayout."""
        from .. import ast

        if type_node is None:
            return TypeLayout(size=0, align=1)  # void

        if isinstance(type_node, ast.TypeName):
            return self.layout_of_name(type_node.name)

        if isinstance(type_node, ast.TypePointer):
            return TypeLayout(size=4, align=4, is_ptr=True, is_signed=False)

        if isinstance(type_node, ast.TypeSlice):
            # Fat pointer: {ptr, len}
            return TypeLayout(size=8, align=4, is_slice=True,
                              fields={
                                  'ptr': FieldInfo('ptr', 0, 4, 4, None),
                                  'len': FieldInfo('len', 4, 4, 4, None),
                              },
                              field_order=['ptr', 'len'])

        if isinstance(type_node, ast.TypeArray):
            inner = self.layout_of_type(type_node.inner)
            # Resolve size (must be a compile-time integer literal)
            from .. import ast as _ast
            if isinstance(type_node.size, _ast.IntLit):
                n = type_node.size.value
            elif isinstance(type_node.size, int):
                n = type_node.size
            else:
                n = 0  # unknown at layout time; caller must handle
            total = inner.size * n
            return TypeLayout(size=total, align=inner.align)

        if isinstance(type_node, ast.TypeResult):
            ok_l  = self.layout_of_type(type_node.ok)
            err_l = self.layout_of_type(type_node.err)
            payload_size  = max(ok_l.size, err_l.size)
            payload_align = max(ok_l.align, err_l.align)
            # {is_ok: bool (1 byte + padding), payload}
            pay_off = (1 + payload_align - 1) & ~(payload_align - 1)
            total_align = max(1, payload_align)
            total_size  = (pay_off + payload_size + total_align - 1) & ~(total_align - 1)
            return TypeLayout(size=max(total_size, total_align), align=total_align,
                              tag_offset=0, tag_size=1,
                              fields={
                                  'is_ok':   FieldInfo('is_ok', 0, 1, 1, None),
                                  'payload': FieldInfo('payload', pay_off,
                                                       payload_size, payload_align, None),
                              },
                              field_order=['is_ok', 'payload'])

        if isinstance(type_node, ast.TypeOption):
            inner = self.layout_of_type(type_node.inner)
            if inner.is_ptr:
                # Nullable pointer: None == 0
                return TypeLayout(size=4, align=4, is_ptr=True, is_signed=False)
            # {has_val: bool, T}
            pay_off = (1 + inner.align - 1) & ~(inner.align - 1)
            total_align = max(1, inner.align)
            total_size = (pay_off + inner.size + total_align - 1) & ~(total_align - 1)
            return TypeLayout(size=max(total_size, total_align), align=total_align)

        if isinstance(type_node, ast.TypeGeneric):
            # e.g. Result(T, E) or a user generic — look up by name if registered
            return self.layout_of_name(type_node.name)

        if isinstance(type_node, ast.TypeVolatile):
            return self.layout_of_type(type_node.inner)

        if isinstance(type_node, ast.TypeFn):
            # Function pointer is just a 32-bit pointer
            return TypeLayout(size=4, align=4, is_ptr=True, is_signed=False)

        # Fallback: treat as 4-byte word
        return TypeLayout(size=4, align=4)

    def enum_value(self, enum_name: str, case_name: str) -> int:
        return self._enum_values[enum_name][case_name]

    def variant_tag(self, variant_name: str, case_name: str) -> int:
        decl = self._variant_decls.get(variant_name)
        if decl is None:
            raise KeyError(f"Unknown variant: {variant_name!r}")
        for i, c in enumerate(decl.cases):
            if c.name == case_name:
                return i
        raise KeyError(f"Unknown variant case: {case_name!r} in {variant_name!r}")

    def variant_case_fields(self, variant_name: str, case_name: str) -> List[FieldInfo]:
        """Return field layout for one variant case's payload."""
        decl = self._variant_decls.get(variant_name)
        if decl is None:
            return []
        for case in decl.cases:
            if case.name == case_name:
                fields = []
                offset = 0
                for sf in case.fields:
                    # fields may be StructField objects, (name, type) tuples,
                    # or bare type nodes (positional fields)
                    if isinstance(sf, tuple):
                        fname, ftype = sf
                    elif hasattr(sf, 'type'):
                        fname, ftype = sf.name, sf.type
                    else:
                        fname = f'_field{len(fields)}'
                        ftype = sf  # positional field: sf IS the type node
                    fl = self.layout_of_type(ftype)
                    offset = (offset + fl.align - 1) & ~(fl.align - 1)
                    fields.append(FieldInfo(fname, offset, fl.size, fl.align, ftype))
                    offset += fl.size
                return fields
        return []
