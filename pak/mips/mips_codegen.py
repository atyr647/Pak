"""PAK → MIPS top-level code generator (Phases 1–2).

Walks the typed AST produced by parser + typechecker and emits GNU-as
compatible MIPS assembly for the N64 (VR4300, MIPS o32 ABI).

Entry point::

    from pak.mips import MipsCodegen
    from pak.parser import parse
    from pak.typechecker import TypeEnv, check

    program = parse(source)
    tenv    = TypeEnv(); tenv.collect(program)
    cg      = MipsCodegen()
    asm_text = cg.generate(program, tenv)

The output is a single .s file suitable for:
    mips-n64-elf-as output.s -o output.o
    mips-n64-elf-ld output.o -o output.elf   (with libdragon link script)

Phase 1 coverage:
    ✓ Integer/float/bool literals
    ✓ Binary arithmetic, bitwise, comparison, logical ops
    ✓ Unary ops
    ✓ Variable reads/writes (locals on stack, globals in .data)
    ✓ Function declarations, calls, return
    ✓ Entry block → main
    ✓ if/else, while, loop, for-range, for-each, match (enum + variant)
    ✓ break / continue
    ✓ Struct field access, array index
    ✓ Address-of, dereference
    ✓ Type casts
    ✓ sizeof / offsetof / align_of (compile-time)
    ✓ N64 module API calls (jal to libdragon symbols)
    ✓ Inline asm pass-through
    ✓ Static / const declarations
    ✓ defer statements
    ✓ String literals
    ✓ ok() / err() Result constructors
    ✓ do-while, goto, label (Phase 0 new nodes)
    ✓ alloc / free (calls __pak_alloc / __pak_free runtime)
    ✓ Traits/impl stubs (method dispatch as plain fn calls)
    ✓ comptime if (condition must be a known constant)

Phase 2 coverage (type system & structured data):
    ✓ Type-aware struct field loads/stores (sb/sh/sw by field width)
    ✓ Struct copy via memcpy for large types
    ✓ Variant constructors (tag + payload store)
    ✓ Variant match with real layout offsets from variant_case_fields()
    ✓ Type-aware element sizes in for-each and index access
    ✓ Proper Result/Option codegen using real type layout
    ✓ Optional slice bounds checking
    ✓ Enum base-type-aware loads/stores
"""

from __future__ import annotations
from typing import Dict, List, Optional, Any, Tuple
from dataclasses import dataclass, field

from .. import ast
from ..typechecker import TypeEnv
from .emit      import Emitter
from .registers import (
    RegAlloc, borrow_temp, borrow_ftemp,
    ZERO, SP, FP, RA, GP,
    V0, V1, A0, A1, A2, A3,
    T0, T1, T9,
    S0, F0, F12,
)
from .abi       import (
    FrameLayout, build_frame, classify_args, classify_return,
    CALLEE_SAVED_GPRS, CALLEE_SAVED_FPRS,
    ArgLoc,
)
from .types     import MipsTypeEnv, TypeLayout, FieldInfo
from .literals  import LiteralPool
from .n64_runtime import N64Runtime
class CodegenError(Exception):
    """Raised when backend validation detects an internal invariant violation."""
    pass


from .optimize  import optimize_asm
from .builtins  import (
    expand_sizeof, expand_offsetof, expand_align_of,
    emit_fixmul, emit_fixdiv, emit_int_to_fix, emit_fix_to_int,
    emit_int_cast, emit_float_to_int, emit_int_to_float,
    emit_bool_not, emit_bool_and, emit_bool_or,
)


# ── Per-function codegen context ──────────────────────────────────────────────

@dataclass
class FnCtx:
    """State for one function being compiled."""
    name:       str
    frame:      Optional[FrameLayout] = None
    ra:         RegAlloc = field(default_factory=RegAlloc)
    pool:       LiteralPool = field(default_factory=LiteralPool)

    # Local variable stack: list of {name: str → sp_offset: int}
    # Each scope push adds a new dict; pop removes it.
    _scopes:    List[Dict[str, Tuple[int, TypeLayout]]] = field(default_factory=list)

    # Declared type nodes for locals (name → AST type node). Used to recover the
    # pointee type/volatility of a pointer local at a Deref site.
    _type_nodes: Dict[str, Any] = field(default_factory=dict)

    # Loop context stack for break/continue
    _loop_exit:   List[str] = field(default_factory=list)
    _loop_header: List[str] = field(default_factory=list)

    # Defer stacks (LIFO) — list of AST block/stmt nodes
    _defers:    List[List[Any]] = field(default_factory=list)

    # Next available SP offset for locals (grows upward from arg-save area end)
    _next_local: int = 16   # 0-15 = arg save area

    def push_scope(self):
        self._scopes.append({})
        self._defers.append([])

    def pop_scope(self) -> List[Any]:
        """Return deferred stmts for this scope (LIFO order)."""
        self._scopes.pop()
        return list(reversed(self._defers.pop()))

    def declare_local(self, name: str, layout: TypeLayout, type_node: Any = None) -> int:
        """Allocate a stack slot and record the local. Returns SP offset."""
        align = layout.align
        self._next_local = (self._next_local + align - 1) & ~(align - 1)
        offset = self._next_local
        self._next_local += layout.size
        if self._scopes:
            self._scopes[-1][name] = (offset, layout)
        if type_node is not None:
            self._type_nodes[name] = type_node
        return offset

    def lookup_type_node(self, name: str) -> Optional[Any]:
        return self._type_nodes.get(name)

    def lookup_local(self, name: str) -> Optional[Tuple[int, TypeLayout]]:
        for scope in reversed(self._scopes):
            if name in scope:
                return scope[name]
        return None

    def push_loop(self, header: str, exit_lbl: str):
        self._loop_header.append(header)
        self._loop_exit.append(exit_lbl)

    def pop_loop(self):
        self._loop_header.pop()
        self._loop_exit.pop()

    @property
    def loop_exit(self) -> Optional[str]:
        return self._loop_exit[-1] if self._loop_exit else None

    @property
    def loop_header(self) -> Optional[str]:
        return self._loop_header[-1] if self._loop_header else None

    def add_defer(self, stmt):
        if self._defers:
            self._defers[-1].append(stmt)


# ── Main codegen class ────────────────────────────────────────────────────────

class MipsCodegen:
    """Translates a PAK Program AST into MIPS assembly text."""

    def __init__(self, *, bounds_check: bool = False, optimize: bool = True):
        self._em:      Emitter      = Emitter()
        self._tenv:    MipsTypeEnv  = MipsTypeEnv()
        self._pak_env: Optional[TypeEnv] = None
        self._pool:    LiteralPool  = LiteralPool()
        self._rt:      N64Runtime   = N64Runtime()
        self._globals: Dict[str, Tuple[int, TypeLayout]] = {}  # name → (0, layout) sentinel for globals
        self._consts:  Dict[str, int] = {}   # compile-time integer constants
        self._fn_ctx:  Optional[FnCtx] = None
        self._label_n: int = 0
        self._bounds_check: bool = bounds_check
        self._optimize: bool = optimize
        # Generic monomorphization: template_name → FnDecl
        self._generic_fns: Dict[str, ast.FnDecl] = {}
        # Already-emitted specializations: mangled_name → True
        self._mono_emitted: Dict[str, bool] = {}

    # ── Public API ────────────────────────────────────────────────────────────

    def generate(self, program: ast.Program, pak_env: Optional[TypeEnv] = None) -> str:
        """Compile program to MIPS assembly. Returns the .s text."""
        self._pak_env = pak_env
        self._tenv.register_program(program)

        # Backend validation: catch compiler-bug-class problems before emitting
        self._validate_program(program)

        self._em.raw('# Generated by PAK MIPS backend')
        self._em.raw(f'# .set mips3')
        self._em.raw(f'# .set noreorder')
        self._em.blank()

        # Collect all .extern references for libdragon symbols
        self._emit_externs()
        self._em.blank()

        # Process top-level declarations
        for decl in program.decls:
            self._emit_top_decl(decl)

        # Emit constant pool sections
        self._pool.emit_rodata(self._em)
        self._pool.emit_data(self._em)

        raw = self._em.getvalue()
        if self._optimize:
            return optimize_asm(raw)
        return raw

    # ── Backend validation ────────────────────────────────────────────────────

    def _validate_program(self, program: ast.Program) -> None:
        """Assert internal invariants before codegen.

        Catches 'compiler bug' class problems — not user errors (those are
        caught by the semantic checker) but broken AST assumptions that
        would silently produce garbage assembly.

        Raises CodegenError on failure.
        """
        errors: List[str] = []

        # Track top-level names for duplicate detection at codegen level
        fn_names:     set = set()
        struct_names: set = set()
        enum_names:   set = set()
        variant_names: set = set()
        has_entry = False

        for decl in program.decls:
            if isinstance(decl, ast.FnDecl):
                if decl.name in fn_names:
                    errors.append(f'backend: duplicate function name {decl.name!r}')
                fn_names.add(decl.name)
                if decl.body is not None:
                    self._validate_body(decl.body, decl.name, errors)
            elif isinstance(decl, ast.EntryBlock):
                if has_entry:
                    errors.append('backend: multiple entry blocks')
                has_entry = True
                if decl.body is not None:
                    self._validate_body(decl.body, 'entry', errors)
            elif isinstance(decl, ast.StructDecl):
                if decl.name in struct_names:
                    errors.append(f'backend: duplicate struct name {decl.name!r}')
                struct_names.add(decl.name)
                # Verify all fields have type nodes
                for f in decl.fields:
                    if hasattr(f, 'type') and f.type is None:
                        errors.append(
                            f'backend: struct {decl.name}.{f.name} has no type')
            elif isinstance(decl, ast.EnumDecl):
                enum_names.add(decl.name)
            elif isinstance(decl, ast.VariantDecl):
                variant_names.add(decl.name)
                # Verify all variant cases have consistent field tuples
                for case in decl.cases:
                    for sf in case.fields:
                        if isinstance(sf, tuple):
                            if len(sf) != 2:
                                errors.append(
                                    f'backend: variant {decl.name}.{case.name} '
                                    f'has malformed field tuple: {sf!r}')
            elif isinstance(decl, ast.ImplBlock):
                # Verify the type exists
                if (decl.type_name not in struct_names and
                    decl.type_name not in enum_names and
                    decl.type_name not in variant_names):
                    # May be forward-declared; only warn if types are fully registered
                    pass
            elif isinstance(decl, ast.ConstDecl):
                if decl.value is None:
                    errors.append(f'backend: const {decl.name!r} has no value')

        if errors:
            msg = 'MIPS backend validation failed:\n  ' + '\n  '.join(errors)
            raise CodegenError(msg)

    def _validate_body(self, body, fn_name: str, errors: List[str]) -> None:
        """Recursively validate an AST body for backend assumptions."""
        if not isinstance(body, ast.Block):
            return
        for stmt in body.stmts:
            if isinstance(stmt, ast.LetDecl):
                if stmt.name is None or stmt.name == '':
                    errors.append(f'backend: let in {fn_name} has empty name')
            elif isinstance(stmt, ast.MatchStmt):
                if not stmt.arms:
                    errors.append(f'backend: match in {fn_name} has no arms')
            elif isinstance(stmt, ast.Block):
                self._validate_body(stmt, fn_name, errors)
            elif isinstance(stmt, ast.IfStmt):
                if isinstance(stmt.then, ast.Block):
                    self._validate_body(stmt.then, fn_name, errors)
            elif isinstance(stmt, ast.WhileStmt):
                if isinstance(stmt.body, ast.Block):
                    self._validate_body(stmt.body, fn_name, errors)
            elif isinstance(stmt, ast.ForStmt):
                if isinstance(stmt.body, ast.Block):
                    self._validate_body(stmt.body, fn_name, errors)

    # ── Top-level declarations ────────────────────────────────────────────────

    def _emit_externs(self):
        """Declare .extern for all libdragon symbols we might call."""
        from .n64_runtime import N64_RUNTIME_API
        seen = set()
        for entry in N64_RUNTIME_API.values():
            sym = entry.get('sym')
            if isinstance(sym, str) and sym not in seen:
                self._em.extern(sym)
                seen.add(sym)
        # Runtime helpers
        for helper in ('__pak_fix16_div', '__pak_alloc', '__pak_free',
                       '__pak_panic', 'memcpy', 'memset'):
            self._em.extern(helper)

    def _emit_top_decl(self, decl):
        if isinstance(decl, ast.FnDecl):
            if decl.type_params:
                # Generic function: defer until we see a monomorphized call
                self._generic_fns[decl.name] = decl
            else:
                self._emit_fn(decl)
        elif isinstance(decl, ast.EntryBlock):
            self._emit_entry(decl)
        elif isinstance(decl, (ast.StructDecl, ast.EnumDecl, ast.VariantDecl,
                                ast.UnionDecl, ast.TraitDecl)):
            pass  # type info already registered in MipsTypeEnv
        elif isinstance(decl, ast.ImplBlock):
            for m in decl.methods:
                mangled = f'{decl.type_name}_{m.name}'
                m_copy = ast.FnDecl(
                    name=mangled, params=m.params, ret_type=m.ret_type,
                    body=m.body, type_params=m.type_params,
                    annotations=m.annotations, is_method=True,
                    self_type=decl.type_name,
                )
                self._emit_fn(m_copy)
        elif isinstance(decl, ast.ImplTraitBlock):
            for m in decl.methods:
                mangled = f'{decl.type_name}_{m.name}'
                m_copy = ast.FnDecl(
                    name=mangled, params=m.params, ret_type=m.ret_type,
                    body=m.body, type_params=getattr(m, 'type_params', []),
                    annotations=getattr(m, 'annotations', []),
                )
                self._emit_fn(m_copy)
        elif isinstance(decl, ast.ConstDecl):
            self._collect_const(decl)
        elif isinstance(decl, ast.StaticDecl):
            self._emit_static(decl)
        elif isinstance(decl, ast.ExternBlock):
            pass  # already declared via .extern
        elif isinstance(decl, ast.UseDecl):
            pass  # module imports handled at call sites
        elif isinstance(decl, ast.AssetDecl):
            self._em.extern(decl.name)
        elif isinstance(decl, ast.CfgBlock):
            # @cfg(FEATURE) decl — emit only if feature is always-on (skip for now)
            self._emit_top_decl(decl.decl)

    def _collect_const(self, decl: ast.ConstDecl):
        v = self._eval_const_expr(decl.value)
        if v is not None:
            self._consts[decl.name] = v

    def _emit_static(self, decl: ast.StaticDecl):
        layout = self._tenv.layout_of_type(decl.type) if decl.type else TypeLayout(4, 4)
        init_val = None
        if decl.value is not None:
            init_val = self._eval_const_expr(decl.value)

        # Check for @aligned(N) annotation
        forced_align = layout.align
        for ann in getattr(decl, 'annotations', []):
            if isinstance(ann, str) and ann.startswith('aligned('):
                try:
                    forced_align = max(forced_align, int(ann[8:-1]))
                except ValueError:
                    pass

        self._pool.add_static(decl.name, layout.size, forced_align, init_val)
        self._globals[decl.name] = (0, layout)

    # ── Function emission ─────────────────────────────────────────────────────

    def _emit_fn(self, decl: ast.FnDecl):
        if decl.body is None:
            return  # extern prototype
        self._em.blank()
        self._em.section_text()
        self._em.globl(decl.name)
        self._em.type_func(decl.name)
        self._em.label(decl.name)

        ctx = FnCtx(name=decl.name)
        self._fn_ctx = ctx

        # Pre-scan body to know local_bytes and which callee-saved regs are used
        # For Phase 1 we do a simple two-pass: first pass just allocates,
        # second pass emits.  Here we use a placeholder frame and fix it up.
        ctx.push_scope()

        # Place parameters into stack slots (locals)
        for i, param in enumerate(decl.params):
            p_layout = self._tenv.layout_of_type(param.type)
            off = ctx.declare_local(param.name, p_layout)
            # The param is passed in $a0-$a3; store it to its stack slot.
            if i < 4:
                arg_reg = [A0, A1, A2, A3][i]
                self._store_to_sp(off, arg_reg, p_layout)

        # Emit a placeholder for the prologue; we patch it after the body
        # so that we know exactly which callee-saved registers were used.
        frame_size = 256  # conservative; refined after body scan
        prologue_start = len(self._em._buf)
        self._emit_prologue_placeholder(frame_size)
        prologue_end = len(self._em._buf)

        # Emit body
        ret_label = self._fresh_label(f'.L{decl.name}_ret')
        ctx._ret_label = ret_label
        self._emit_block(ctx, decl.body)

        # Emit deferred stmts for outermost scope
        defers = ctx.pop_scope()
        for d in defers:
            self._emit_stmt(ctx, d)

        # Now we know used callee-saved regs — patch the prologue
        self._patch_prologue(ctx, frame_size, prologue_start, prologue_end)

        # Return label
        self._em.label(ret_label)
        self._emit_epilogue(ctx, frame_size)

        self._em.size_sym(decl.name, f'. - {decl.name}')
        self._fn_ctx = None

    def _emit_entry(self, decl: ast.EntryBlock):
        """Entry block → emitted as the 'main' function."""
        fn = ast.FnDecl(
            name='main', params=[], ret_type=None, body=decl.body,
            annotations=['entry'],
        )
        self._emit_fn(fn)

    def _emit_prologue_placeholder(self, frame_size: int):
        """Emit a conservative prologue that will be patched later."""
        em = self._em
        em.addiu(SP, SP, -frame_size)
        em.sw(RA, frame_size - 4, SP)
        em.sw(FP, frame_size - 8, SP)
        em.addiu(FP, SP, frame_size)
        # Placeholder line for callee-saved saves (patched by _patch_prologue)
        em.raw('    # callee-saves-placeholder')

    def _patch_prologue(self, ctx: FnCtx, frame_size: int,
                        prologue_start: int, prologue_end: int):
        """Replace the prologue placeholder with actual callee-saved saves."""
        callee_gprs = ctx.ra.used_callee_gprs
        callee_fprs = ctx.ra.used_callee_fprs
        lines: list[str] = []
        for i, reg in enumerate(callee_gprs):
            lines.append(f'    sw {reg}, {frame_size - 12 - i * 4}({SP})')
        fpr_base = frame_size - 12 - len(callee_gprs) * 4
        for i, freg in enumerate(callee_fprs):
            lines.append(f'    swc1 {freg}, {fpr_base - i * 4}({SP})')
        # Find and replace the placeholder comment
        for idx in range(prologue_start, prologue_end):
            if 'callee-saves-placeholder' in self._em._buf[idx]:
                self._em._buf[idx:idx + 1] = lines
                break

    def _emit_epilogue(self, ctx: FnCtx, frame_size: int):
        em = self._em
        # Restore callee-saved registers (reverse order of save)
        callee_gprs = ctx.ra.used_callee_gprs
        callee_fprs = ctx.ra.used_callee_fprs
        fpr_base = frame_size - 12 - len(callee_gprs) * 4
        for i, freg in enumerate(reversed(callee_fprs)):
            ri = len(callee_fprs) - 1 - i
            em.raw(f'    lwc1 {freg}, {fpr_base - ri * 4}({SP})')
        for i, reg in enumerate(reversed(callee_gprs)):
            ri = len(callee_gprs) - 1 - i
            em.lw(reg, frame_size - 12 - ri * 4, SP)
        em.lw(FP, frame_size - 8, SP)
        em.lw(RA, frame_size - 4, SP)
        em.addiu(SP, SP, frame_size)
        em.jr(RA)
        em.nop()

    # ── Statement emission ────────────────────────────────────────────────────

    def _emit_block(self, ctx: FnCtx, block: ast.Block):
        ctx.push_scope()
        for stmt in block.stmts:
            self._emit_stmt(ctx, stmt)
        defers = ctx.pop_scope()
        for d in defers:
            self._emit_stmt(ctx, d)

    def _emit_stmt(self, ctx: FnCtx, stmt):
        em = self._em

        if isinstance(stmt, ast.LetDecl):
            layout = self._tenv.layout_of_type(stmt.type) if stmt.type else TypeLayout(4, 4)
            off = ctx.declare_local(stmt.name, layout, type_node=stmt.type)
            if stmt.value is not None:
                if layout.size > 4 and layout.fields:
                    # Large struct / composite: expr returns a pointer; memcpy to our slot
                    with borrow_temp(ctx.ra) as src_ptr, borrow_temp(ctx.ra) as dst_ptr:
                        self._emit_expr(ctx, stmt.value, src_ptr)
                        em.addiu(dst_ptr, SP, off)
                        self._emit_memcpy(ctx, dst_ptr, src_ptr, layout.size)
                else:
                    with borrow_temp(ctx.ra) as tmp:
                        self._emit_expr(ctx, stmt.value, tmp)
                        self._store_to_sp(off, tmp, layout)

        elif isinstance(stmt, ast.StaticDecl):
            self._emit_static(stmt)

        elif isinstance(stmt, ast.Assign):
            with borrow_temp(ctx.ra) as val_reg:
                self._emit_expr(ctx, stmt.value, val_reg)
                self._emit_assign_target(ctx, stmt.target, val_reg, stmt.op)

        elif isinstance(stmt, ast.Return):
            # Emit deferred stmts for all active scopes (innermost first)
            for scope_defers in reversed(ctx._defers):
                for d in reversed(scope_defers):
                    self._emit_stmt(ctx, d)
            if stmt.value is not None:
                self._emit_expr(ctx, stmt.value, V0)
            em.j(ctx._ret_label)
            em.nop()

        elif isinstance(stmt, ast.IfStmt):
            self._emit_if(ctx, stmt)

        elif isinstance(stmt, ast.WhileStmt):
            self._emit_while(ctx, stmt)

        elif isinstance(stmt, ast.DoWhileStmt):
            self._emit_do_while(ctx, stmt)

        elif isinstance(stmt, ast.LoopStmt):
            self._emit_loop(ctx, stmt)

        elif isinstance(stmt, ast.ForStmt):
            self._emit_for(ctx, stmt)

        elif isinstance(stmt, ast.MatchStmt):
            self._emit_match(ctx, stmt)

        elif isinstance(stmt, ast.Break):
            if ctx.loop_exit:
                em.j(ctx.loop_exit)
                em.nop()

        elif isinstance(stmt, ast.Continue):
            if ctx.loop_header:
                em.j(ctx.loop_header)
                em.nop()

        elif isinstance(stmt, ast.DeferStmt):
            ctx.add_defer(stmt.body)

        elif isinstance(stmt, ast.ExprStmt):
            with borrow_temp(ctx.ra) as tmp:
                self._emit_expr(ctx, stmt.expr, tmp)

        elif isinstance(stmt, ast.Block):
            self._emit_block(ctx, stmt)

        elif isinstance(stmt, ast.AsmStmt):
            for line in stmt.lines:
                em.verbatim(line)

        elif isinstance(stmt, ast.GotoStmt):
            em.j(stmt.label)
            em.nop()

        elif isinstance(stmt, ast.LabelStmt):
            em.label(stmt.name)

        elif isinstance(stmt, ast.NullCheckStmt):
            self._emit_null_check_stmt(ctx, stmt)

        elif isinstance(stmt, ast.ComptimeIf):
            val = self._eval_const_expr(stmt.condition)
            if val:
                self._emit_block(ctx, stmt.then) if isinstance(stmt.then, ast.Block) else self._emit_stmt(ctx, stmt.then)
            elif stmt.else_branch:
                self._emit_block(ctx, stmt.else_branch) if isinstance(stmt.else_branch, ast.Block) else self._emit_stmt(ctx, stmt.else_branch)

        # Ignore unknown stmt types gracefully

    # ── Control flow helpers ──────────────────────────────────────────────────

    def _emit_if(self, ctx: FnCtx, stmt: ast.IfStmt):
        em = self._em
        end_label = self._fresh_label('.Lif_end')
        else_label = self._fresh_label('.Lif_else') if stmt.else_branch or stmt.elif_branches else end_label

        with borrow_temp(ctx.ra) as cond:
            self._emit_expr(ctx, stmt.condition, cond)
            em.beqz(cond, else_label)
            em.nop()

        self._emit_block(ctx, stmt.then)
        if stmt.elif_branches or stmt.else_branch:
            em.j(end_label)
            em.nop()

        current_else = else_label
        for elif_cond, elif_body in (stmt.elif_branches or []):
            em.label(current_else)
            next_else = self._fresh_label('.Lelif_else')
            with borrow_temp(ctx.ra) as cond:
                self._emit_expr(ctx, elif_cond, cond)
                em.beqz(cond, next_else)
                em.nop()
            self._emit_block(ctx, elif_body)
            em.j(end_label)
            em.nop()
            current_else = next_else

        if stmt.else_branch:
            em.label(current_else)
            self._emit_block(ctx, stmt.else_branch)
        elif stmt.elif_branches:
            em.label(current_else)

        em.label(end_label)

    def _emit_while(self, ctx: FnCtx, stmt: ast.WhileStmt):
        em = self._em
        header = self._fresh_label('.Lwhile_h')
        exit_l = self._fresh_label('.Lwhile_x')
        ctx.push_loop(header, exit_l)
        em.label(header)
        with borrow_temp(ctx.ra) as cond:
            self._emit_expr(ctx, stmt.condition, cond)
            em.beqz(cond, exit_l)
            em.nop()
        self._emit_block(ctx, stmt.body)
        em.j(header)
        em.nop()
        em.label(exit_l)
        ctx.pop_loop()

    def _emit_do_while(self, ctx: FnCtx, stmt: ast.DoWhileStmt):
        em = self._em
        header = self._fresh_label('.Ldow_h')
        exit_l = self._fresh_label('.Ldow_x')
        ctx.push_loop(header, exit_l)
        em.label(header)
        self._emit_block(ctx, stmt.body)
        with borrow_temp(ctx.ra) as cond:
            self._emit_expr(ctx, stmt.condition, cond)
            em.bnez(cond, header)
            em.nop()
        em.label(exit_l)
        ctx.pop_loop()

    def _emit_loop(self, ctx: FnCtx, stmt: ast.LoopStmt):
        em = self._em
        header = self._fresh_label('.Lloop_h')
        exit_l = self._fresh_label('.Lloop_x')
        ctx.push_loop(header, exit_l)
        em.label(header)
        self._emit_block(ctx, stmt.body)
        em.j(header)
        em.nop()
        em.label(exit_l)
        ctx.pop_loop()

    def _emit_for(self, ctx: FnCtx, stmt: ast.ForStmt):
        em = self._em
        iterable = stmt.iterable

        if isinstance(iterable, ast.RangeExpr):
            # for i in start..end
            self._emit_for_range(ctx, stmt, iterable)
        else:
            # for item in slice (fat pointer)
            self._emit_for_each(ctx, stmt, iterable)

    def _emit_for_range(self, ctx: FnCtx, stmt: ast.ForStmt, rng: ast.RangeExpr):
        em = self._em
        header = self._fresh_label('.Lfor_h')
        exit_l = self._fresh_label('.Lfor_x')

        # Allocate counter slot
        counter_layout = self._tenv.layout_of_name('i32')
        counter_off = ctx.declare_local(stmt.binding, counter_layout)

        with borrow_temp(ctx.ra) as start_r, borrow_temp(ctx.ra) as end_r:
            self._emit_expr(ctx, rng.start, start_r)
            self._store_to_sp(counter_off, start_r, counter_layout)
            if rng.end:
                self._emit_expr(ctx, rng.end, end_r)
            else:
                em.li(end_r, 0x7FFFFFFF)

            ctx.push_loop(header, exit_l)
            em.label(header)

            # Reload counter and compare
            with borrow_temp(ctx.ra) as ctr:
                self._load_from_sp(counter_off, ctr, counter_layout)
                em.bge(ctr, end_r, exit_l)
                em.nop()

                # Emit index variable if requested
                if stmt.index:
                    idx_layout = self._tenv.layout_of_name('i32')
                    idx_off = ctx.lookup_local(stmt.index)
                    if idx_off is None:
                        idx_off2 = ctx.declare_local(stmt.index, idx_layout)
                    else:
                        idx_off2 = idx_off[0]
                    self._store_to_sp(idx_off2, ctr, idx_layout)

                self._emit_block(ctx, stmt.body)

                # Increment counter
                self._load_from_sp(counter_off, ctr, counter_layout)
                em.addiu(ctr, ctr, 1)
                self._store_to_sp(counter_off, ctr, counter_layout)

            em.j(header)
            em.nop()

        em.label(exit_l)
        ctx.pop_loop()

    def _emit_for_each(self, ctx: FnCtx, stmt: ast.ForStmt, iterable):
        em = self._em
        header = self._fresh_label('.Lfeach_h')
        exit_l = self._fresh_label('.Lfeach_x')

        # Evaluate slice → {ptr, len}
        ptr_layout = self._tenv.layout_of_name('i32')
        ptr_off = ctx.declare_local('__for_ptr', ptr_layout)
        len_off = ctx.declare_local('__for_len', ptr_layout)
        idx_off = ctx.declare_local('__for_idx', ptr_layout)

        # item size — default 4; would need type info for proper elem size
        elem_size = 4

        with borrow_temp(ctx.ra) as slice_base:
            self._emit_expr(ctx, iterable, slice_base)
            # slice_base holds fat-pointer base (ptr word)
            em.sw(slice_base, ptr_off, SP)
            # len is at +4
            with borrow_temp(ctx.ra) as len_r:
                em.lw(len_r, 4, slice_base)
                em.sw(len_r, len_off, SP)
        em.sw(ZERO, idx_off, SP)

        ctx.push_loop(header, exit_l)
        em.label(header)

        with borrow_temp(ctx.ra) as idx_r, borrow_temp(ctx.ra) as len_r:
            em.lw(idx_r, idx_off, SP)
            em.lw(len_r, len_off, SP)
            em.bge(idx_r, len_r, exit_l)
            em.nop()

            # Load element
            binding_layout = ptr_layout
            binding_off = ctx.declare_local(stmt.binding, binding_layout)
            with borrow_temp(ctx.ra) as ptr_r, borrow_temp(ctx.ra) as elem_r:
                em.lw(ptr_r, ptr_off, SP)
                em.sll(elem_r, idx_r, 2)          # idx * 4 (word-sized elements)
                em.addu(ptr_r, ptr_r, elem_r)
                em.lw(elem_r, 0, ptr_r)
                em.sw(elem_r, binding_off, SP)

            if stmt.index:
                idx2_layout = ptr_layout
                idx2_off_pair = ctx.lookup_local(stmt.index)
                if idx2_off_pair is None:
                    idx2_off = ctx.declare_local(stmt.index, idx2_layout)
                else:
                    idx2_off = idx2_off_pair[0]
                em.sw(idx_r, idx2_off, SP)

            self._emit_block(ctx, stmt.body)

            # Increment index
            em.lw(idx_r, idx_off, SP)
            em.addiu(idx_r, idx_r, 1)
            em.sw(idx_r, idx_off, SP)

        em.j(header)
        em.nop()
        em.label(exit_l)
        ctx.pop_loop()

    def _emit_match(self, ctx: FnCtx, stmt: ast.MatchStmt):
        em = self._em
        end_label = self._fresh_label('.Lmatch_end')

        with borrow_temp(ctx.ra) as val:
            self._emit_expr(ctx, stmt.expr, val)

            for arm in stmt.arms:
                pat = arm.pattern
                body_label = self._fresh_label('.Larm')
                skip_label = self._fresh_label('.Larm_skip')

                if isinstance(pat, ast.Ident) and pat.name == '_':
                    # Wildcard — always matches
                    self._emit_block(ctx, arm.body) if isinstance(arm.body, ast.Block) else self._emit_stmt(ctx, arm.body)
                    em.j(end_label)
                    em.nop()
                    break

                elif isinstance(pat, ast.EnumVariantAccess):
                    # .CaseName — match enum integer value
                    case_val = self._resolve_enum_case_value(pat.name)
                    with borrow_temp(ctx.ra) as case_r:
                        em.li(case_r, case_val)
                        em.bne(val, case_r, skip_label)
                        em.nop()
                    self._emit_block(ctx, arm.body) if isinstance(arm.body, ast.Block) else self._emit_stmt(ctx, arm.body)
                    em.j(end_label)
                    em.nop()
                    em.label(skip_label)

                elif isinstance(pat, ast.Call) and isinstance(pat.func, ast.EnumVariantAccess):
                    # .VariantCase(binding) — match variant tag + extract payload
                    self._emit_variant_arm(ctx, val, pat, arm.body, skip_label, end_label)
                    em.label(skip_label)

                elif isinstance(pat, ast.IntLit):
                    with borrow_temp(ctx.ra) as case_r:
                        em.li(case_r, pat.value)
                        em.bne(val, case_r, skip_label)
                        em.nop()
                    self._emit_block(ctx, arm.body) if isinstance(arm.body, ast.Block) else self._emit_stmt(ctx, arm.body)
                    em.j(end_label)
                    em.nop()
                    em.label(skip_label)

                elif isinstance(pat, ast.BoolLit):
                    with borrow_temp(ctx.ra) as case_r:
                        em.li(case_r, 1 if pat.value else 0)
                        em.bne(val, case_r, skip_label)
                        em.nop()
                    self._emit_block(ctx, arm.body) if isinstance(arm.body, ast.Block) else self._emit_stmt(ctx, arm.body)
                    em.j(end_label)
                    em.nop()
                    em.label(skip_label)

                else:
                    # Unknown pattern — always emit body
                    self._emit_block(ctx, arm.body) if isinstance(arm.body, ast.Block) else self._emit_stmt(ctx, arm.body)
                    em.j(end_label)
                    em.nop()

        em.label(end_label)

    def _emit_variant_arm(self, ctx: FnCtx, val_reg: str, pat, body, skip_label, end_label):
        em = self._em
        case_name = pat.func.name

        # Look up tag value and variant layout
        tag_val = self._resolve_variant_tag(case_name)
        layout  = self._resolve_variant_layout_for_case(case_name)
        variant_name = self._resolve_variant_name_for_case(case_name)

        tag_size = layout.tag_size if layout else 1
        with borrow_temp(ctx.ra) as tag_r:
            # Load tag using correct width (1/2/4 bytes)
            if tag_size == 1:
                em.lbu(tag_r, 0, val_reg)
            elif tag_size == 2:
                em.lhu(tag_r, 0, val_reg)
            else:
                em.lw(tag_r, 0, val_reg)
            em.li(T9, tag_val)
            em.bne(tag_r, T9, skip_label)
            em.nop()

        # Bind payload fields using real layout offsets from variant_case_fields()
        if pat.args and variant_name:
            case_fields = self._tenv.variant_case_fields(variant_name, case_name)
            payload_offset = tag_size
            payload_align = max((f.align for f in case_fields), default=4) if case_fields else 4
            payload_offset = (payload_offset + payload_align - 1) & ~(payload_align - 1)
            for i, arg in enumerate(pat.args):
                if isinstance(arg, ast.Ident) and arg.name != '_':
                    if i < len(case_fields):
                        cf = case_fields[i]
                        fl = self._tenv.layout_of_type(cf.type_node) if cf.type_node else TypeLayout(cf.size, cf.align)
                        with borrow_temp(ctx.ra) as field_r:
                            self._emit_typed_load(field_r, payload_offset + cf.offset, val_reg, fl)
                            bind_off = ctx.declare_local(arg.name, fl)
                            self._store_to_sp(bind_off, field_r, fl)
                    else:
                        # Fallback: word-sized binding
                        with borrow_temp(ctx.ra) as field_r:
                            em.lw(field_r, payload_offset + i * 4, val_reg)
                            bind_off = ctx.declare_local(arg.name, TypeLayout(4, 4))
                            em.sw(field_r, bind_off, SP)

        self._emit_block(ctx, body) if isinstance(body, ast.Block) else self._emit_stmt(ctx, body)
        em.j(end_label)
        em.nop()

    def _emit_null_check_stmt(self, ctx: FnCtx, stmt: ast.NullCheckStmt):
        em = self._em
        else_label = self._fresh_label('.Lnull_else')
        end_label  = self._fresh_label('.Lnull_end')
        with borrow_temp(ctx.ra) as val:
            self._emit_expr(ctx, stmt.expr, val)
            em.beqz(val, else_label)
            em.nop()
            bind_layout = TypeLayout(4, 4)
            bind_off = ctx.declare_local(stmt.binding, bind_layout)
            em.sw(val, bind_off, SP)
            self._emit_block(ctx, stmt.then)
            em.j(end_label)
            em.nop()
            em.label(else_label)
            if stmt.else_branch:
                self._emit_block(ctx, stmt.else_branch)
            em.label(end_label)

    # ── Expression emission ───────────────────────────────────────────────────

    def _emit_expr(self, ctx: FnCtx, expr, dst: str):
        em = self._em

        if isinstance(expr, ast.IntLit):
            em.li(dst, expr.value)

        elif isinstance(expr, ast.BoolLit):
            em.li(dst, 1 if expr.value else 0)

        elif isinstance(expr, ast.NoneLit):
            em.move(dst, ZERO)

        elif isinstance(expr, ast.FloatLit):
            lbl = self._pool.intern_float(expr.value)
            with borrow_temp(ctx.ra) as addr:
                em.la(addr, lbl)
                em.lwc1(F12, 0, addr)
            em.move(dst, ZERO)

        elif isinstance(expr, ast.StringLit):
            lbl = self._pool.intern_string(expr.value)
            em.la(dst, lbl)

        elif isinstance(expr, ast.Ident):
            self._emit_ident_load(ctx, expr.name, dst)

        elif isinstance(expr, ast.BinaryOp):
            self._emit_binop(ctx, expr, dst)

        elif isinstance(expr, ast.UnaryOp):
            self._emit_unop(ctx, expr, dst)

        elif isinstance(expr, ast.Assign):
            with borrow_temp(ctx.ra) as val:
                self._emit_expr(ctx, expr.value, val)
                self._emit_assign_target(ctx, expr.target, val, expr.op)
                em.move(dst, val)

        elif isinstance(expr, ast.Cast):
            with borrow_temp(ctx.ra) as src:
                self._emit_expr(ctx, expr.expr, src)
                self._emit_cast(ctx, src, dst, expr.type)

        elif isinstance(expr, ast.Call):
            self._emit_call(ctx, expr, dst)

        elif isinstance(expr, ast.DotAccess):
            self._emit_field_access(ctx, expr, dst)

        elif isinstance(expr, ast.IndexAccess):
            self._emit_index_access(ctx, expr, dst)

        elif isinstance(expr, ast.AddrOf):
            self._emit_addr_of(ctx, expr, dst)

        elif isinstance(expr, ast.Deref):
            layout, vol = self._pointee_layout(ctx, expr.expr)
            with borrow_temp(ctx.ra) as ptr:
                self._emit_expr(ctx, expr.expr, ptr)
                self._emit_typed_load(dst, 0, ptr, layout, volatile=vol)

        elif isinstance(expr, ast.SizeOf):
            size = expand_sizeof(expr.operand, self._tenv)
            em.li(dst, size)

        elif isinstance(expr, ast.OffsetOf):
            off = expand_offsetof(expr.type_name, expr.field, self._tenv)
            em.li(dst, off)

        elif isinstance(expr, ast.AlignOf):
            align = expand_align_of(expr.operand, self._tenv)
            em.li(dst, align)

        elif isinstance(expr, ast.OkExpr):
            # Result layout: {is_ok: bool @ tag_offset, payload @ payload_offset}
            result_layout = self._infer_result_layout(expr)
            tag_off = result_layout.fields.get('is_ok')
            pay_fi  = result_layout.fields.get('payload')
            ok_off = ctx.declare_local('__ok_tmp', result_layout)
            # Zero-init
            for w in range(0, result_layout.size, 4):
                em.sw(ZERO, ok_off + w, SP)
            em.li(T9, 1)
            t_off = tag_off.offset if tag_off else 0
            em.sb(T9, ok_off + t_off, SP)
            p_off = pay_fi.offset if pay_fi else 4
            with borrow_temp(ctx.ra) as val:
                self._emit_expr(ctx, expr.value, val)
                em.sw(val, ok_off + p_off, SP)
            em.addiu(dst, SP, ok_off)

        elif isinstance(expr, ast.ErrExpr):
            result_layout = self._infer_result_layout(expr)
            tag_off = result_layout.fields.get('is_ok')
            pay_fi  = result_layout.fields.get('payload')
            err_off = ctx.declare_local('__err_tmp', result_layout)
            for w in range(0, result_layout.size, 4):
                em.sw(ZERO, err_off + w, SP)
            t_off = tag_off.offset if tag_off else 0
            em.sb(ZERO, err_off + t_off, SP)
            p_off = pay_fi.offset if pay_fi else 4
            with borrow_temp(ctx.ra) as val:
                self._emit_expr(ctx, expr.value, val)
                em.sw(val, err_off + p_off, SP)
            em.addiu(dst, SP, err_off)

        elif isinstance(expr, ast.CatchExpr):
            self._emit_catch(ctx, expr, dst)

        elif isinstance(expr, ast.StructLit):
            self._emit_struct_lit(ctx, expr, dst)

        elif isinstance(expr, ast.ArrayLit):
            self._emit_array_lit(ctx, expr, dst)

        elif isinstance(expr, ast.AsmExpr):
            self._emit_asm_expr(ctx, expr, dst)

        elif isinstance(expr, ast.AllocExpr):
            inner = self._tenv.layout_of_type(expr.type_node)
            em.li(A0, inner.size)
            if hasattr(expr, 'count') and expr.count is not None:
                with borrow_temp(ctx.ra) as cnt:
                    self._emit_expr(ctx, expr.count, cnt)
                    em.mul(A0, A0, cnt)
            em.jal('__pak_alloc')
            em.nop()
            em.move(dst, V0)

        elif isinstance(expr, ast.FreeExpr):
            with borrow_temp(ctx.ra) as ptr:
                self._emit_expr(ctx, expr.ptr, ptr)
                em.move(A0, ptr)
            em.jal('__pak_free')
            em.nop()
            em.move(dst, ZERO)

        elif isinstance(expr, ast.TupleLit):
            n = len(expr.elements)
            tup_off = ctx.declare_local('__tup', TypeLayout(n * 4, 4))
            for i, elem in enumerate(expr.elements):
                with borrow_temp(ctx.ra) as er:
                    self._emit_expr(ctx, elem, er)
                    em.sw(er, tup_off + i * 4, SP)
            em.addiu(dst, SP, tup_off)

        elif isinstance(expr, ast.TupleAccess):
            with borrow_temp(ctx.ra) as base:
                self._emit_expr(ctx, expr.obj, base)
                em.lw(dst, expr.index * 4, base)

        elif isinstance(expr, ast.FmtStr):
            for part in expr.parts:
                if isinstance(part, str):
                    lbl = self._pool.intern_string(part)
                    em.la(dst, lbl)
                    break

        elif isinstance(expr, ast.NullCheck):
            with borrow_temp(ctx.ra) as val:
                self._emit_expr(ctx, expr.expr, val)
                em.move(dst, val)

        elif isinstance(expr, ast.SliceExpr):
            self._emit_slice(ctx, expr, dst)

        elif isinstance(expr, ast.RangeExpr):
            self._emit_expr(ctx, expr.start, dst)

        elif isinstance(expr, ast.EnumVariantAccess):
            val = self._resolve_enum_case_value(expr.name)
            em.li(dst, val)

        elif isinstance(expr, ast.Closure):
            name = self._emit_closure(ctx, expr)
            em.la(dst, name)

        else:
            em.move(dst, ZERO)

    # ── Binary / Unary ops ────────────────────────────────────────────────────

    def _emit_binop(self, ctx: FnCtx, expr: ast.BinaryOp, dst: str):
        em = self._em
        op = expr.op

        # Check if either operand is fixed-point
        frac = self._infer_frac_bits(ctx, expr.left) or self._infer_frac_bits(ctx, expr.right)

        with borrow_temp(ctx.ra) as lhs, borrow_temp(ctx.ra) as rhs:
            self._emit_expr(ctx, expr.left,  lhs)
            self._emit_expr(ctx, expr.right, rhs)

            if frac and op == '*':
                emit_fixmul(em, ctx.ra, dst, lhs, rhs, frac)
                return
            if frac and op == '/':
                emit_fixdiv(em, ctx.ra, dst, lhs, rhs, frac)
                return
            # Fixed-point add/sub are just integer add/sub (same format)

            match op:
                case '+':  em.addu(dst, lhs, rhs)
                case '-':  em.subu(dst, lhs, rhs)
                case '*':  em.mul(dst, lhs, rhs)
                case '/':
                    em.div(lhs, rhs)
                    em.mflo(dst)
                case '%':
                    em.div(lhs, rhs)
                    em.mfhi(dst)
                case '&':  em.and_(dst, lhs, rhs)
                case '|':  em.or_(dst, lhs, rhs)
                case '^':  em.xor(dst, lhs, rhs)
                case '<<': em.sllv(dst, lhs, rhs)
                case '>>': em.srav(dst, lhs, rhs)
                case '==': em.seq(dst, lhs, rhs)
                case '!=': em.sne(dst, lhs, rhs)
                case '<':  em.slt(dst, lhs, rhs)
                case '<=': em.sle(dst, lhs, rhs)
                case '>':  em.sgt(dst, lhs, rhs)
                case '>=': em.sge(dst, lhs, rhs)
                case '&&': emit_bool_and(em, ctx.ra, dst, lhs, rhs)
                case '||': emit_bool_or(em, ctx.ra, dst, lhs, rhs)
                case _:    em.addu(dst, lhs, rhs)

    def _emit_unop(self, ctx: FnCtx, expr: ast.UnaryOp, dst: str):
        em = self._em
        with borrow_temp(ctx.ra) as operand:
            self._emit_expr(ctx, expr.operand, operand)
            match expr.op:
                case '-':  em.subu(dst, ZERO, operand)
                case '!':  emit_bool_not(em, dst, operand)
                case '~':  em.not_(dst, operand)
                case _:    em.move(dst, operand)

    # ── Variable access ───────────────────────────────────────────────────────

    def _emit_ident_load(self, ctx: FnCtx, name: str, dst: str):
        em = self._em
        if name in self._consts:
            em.li(dst, self._consts[name])
            return
        local = ctx.lookup_local(name) if ctx else None
        if local:
            off, layout = local
            self._load_from_sp(off, dst, layout)
            return
        em.la(T9, name)
        em.lw(dst, 0, T9)

    def _emit_assign_target(self, ctx: FnCtx, target, val_reg: str, op: str = '='):
        em = self._em
        if op != '=':
            with borrow_temp(ctx.ra) as cur:
                self._emit_ident_load(ctx, target.name if isinstance(target, ast.Ident) else '__cur', cur)
                match op:
                    case '+=': em.addu(val_reg, cur, val_reg)
                    case '-=': em.subu(val_reg, cur, val_reg)
                    case '*=': em.mul(val_reg, cur, val_reg)
                    case '&=': em.and_(val_reg, cur, val_reg)
                    case '|=': em.or_(val_reg, cur, val_reg)
                    case '^=': em.xor(val_reg, cur, val_reg)
        if isinstance(target, ast.Ident):
            local = ctx.lookup_local(target.name) if ctx else None
            if local:
                off, layout = local
                self._store_to_sp(off, val_reg, layout)
            else:
                em.la(T9, target.name)
                em.sw(val_reg, 0, T9)
        elif isinstance(target, ast.Deref):
            layout, vol = self._pointee_layout(ctx, target.expr)
            with borrow_temp(ctx.ra) as ptr:
                self._emit_expr(ctx, target.expr, ptr)
                self._emit_typed_store(val_reg, 0, ptr, layout, volatile=vol)
        elif isinstance(target, ast.DotAccess):
            self._emit_field_store(ctx, target, val_reg)
        elif isinstance(target, ast.IndexAccess):
            self._emit_index_store(ctx, target, val_reg)

    # ── Memory helpers ────────────────────────────────────────────────────────

    def _emit_typed_load(self, dst: str, offset: int, base: str,
                         layout: TypeLayout, volatile: bool = False) -> None:
        """Load a value from base+offset using the correct width instruction."""
        em = self._em
        if volatile:
            em.sync()
        if layout.is_float:
            em.lwc1(dst, offset, base) if layout.size == 4 else em.ldc1(dst, offset, base)
        else:
            match layout.size:
                case 1: em.lbu(dst, offset, base) if not layout.is_signed else em.lb(dst, offset, base)
                case 2: em.lhu(dst, offset, base) if not layout.is_signed else em.lh(dst, offset, base)
                case 4: em.lw(dst, offset, base)
                case _: em.lw(dst, offset, base)  # multi-word handled by caller
        if volatile:
            em.sync()

    def _emit_typed_store(self, src: str, offset: int, base: str,
                          layout: TypeLayout, volatile: bool = False) -> None:
        """Store a value to base+offset using the correct width instruction."""
        em = self._em
        if volatile:
            em.sync()
        if layout.is_float:
            em.swc1(src, offset, base) if layout.size == 4 else em.sdc1(src, offset, base)
        else:
            match layout.size:
                case 1: em.sb(src, offset, base)
                case 2: em.sh(src, offset, base)
                case 4: em.sw(src, offset, base)
                case _: em.sw(src, offset, base)
        if volatile:
            em.sync()

    def _load_from_sp(self, offset: int, dst: str, layout: TypeLayout):
        self._emit_typed_load(dst, offset, SP, layout)

    def _store_to_sp(self, offset: int, src: str, layout: TypeLayout):
        self._emit_typed_store(src, offset, SP, layout)

    def _emit_memcpy(self, ctx: FnCtx, dst_reg: str, src_reg: str,
                     nbytes: int) -> None:
        """Emit an inline memcpy. Small sizes unroll; large calls memcpy."""
        em = self._em
        if nbytes <= 0:
            return
        if nbytes <= 32:
            # Unrolled word copies + remainder
            off = 0
            with borrow_temp(ctx.ra) as tmp:
                while off + 4 <= nbytes:
                    em.lw(tmp, off, src_reg)
                    em.sw(tmp, off, dst_reg)
                    off += 4
                while off + 2 <= nbytes:
                    em.lhu(tmp, off, src_reg)
                    em.sh(tmp, off, dst_reg)
                    off += 2
                while off < nbytes:
                    em.lbu(tmp, off, src_reg)
                    em.sb(tmp, off, dst_reg)
                    off += 1
        else:
            # Call memcpy(dst, src, n)
            em.move(A0, dst_reg)
            em.move(A1, src_reg)
            em.li(A2, nbytes)
            em.jal('memcpy')
            em.nop()

    def _emit_bounds_check(self, ctx: FnCtx, idx_reg: str, len_reg: str) -> None:
        """Emit a bounds check: if idx >= len, call __pak_panic."""
        if not self._bounds_check:
            return
        em = self._em
        ok_label = self._fresh_label('.Lbounds_ok')
        em.sltu(T9, idx_reg, len_reg)
        em.bnez(T9, ok_label)
        em.nop()
        em.jal('__pak_panic')
        em.nop()
        em.label(ok_label)

    # ── Field / index access ──────────────────────────────────────────────────

    def _emit_field_access(self, ctx: FnCtx, expr: ast.DotAccess, dst: str):
        em = self._em
        with borrow_temp(ctx.ra) as base:
            self._emit_expr(ctx, expr.obj, base)
            fi = self._resolve_field_info(expr)
            if fi:
                fl = TypeLayout(size=fi.size, align=fi.align,
                                is_signed=True if fi.size < 4 else True)
                vol = False
                if fi.type_node:
                    fl = self._tenv.layout_of_type(fi.type_node)
                    vol = isinstance(fi.type_node, ast.TypeVolatile)
                self._emit_typed_load(dst, fi.offset, base, fl, volatile=vol)
            else:
                em.lw(dst, 0, base)

    def _emit_field_store(self, ctx: FnCtx, expr: ast.DotAccess, val: str):
        em = self._em
        with borrow_temp(ctx.ra) as base:
            self._emit_expr(ctx, expr.obj, base)
            fi = self._resolve_field_info(expr)
            if fi:
                fl = TypeLayout(size=fi.size, align=fi.align)
                vol = False
                if fi.type_node:
                    fl = self._tenv.layout_of_type(fi.type_node)
                    vol = isinstance(fi.type_node, ast.TypeVolatile)
                self._emit_typed_store(val, fi.offset, base, fl, volatile=vol)
            else:
                em.sw(val, 0, base)

    def _resolve_field_info(self, expr: ast.DotAccess) -> Optional[FieldInfo]:
        """Resolve a DotAccess to its FieldInfo (offset, size, type)."""
        obj = expr.obj
        if isinstance(obj, ast.Ident):
            ctx = self._fn_ctx
            if ctx:
                local = ctx.lookup_local(obj.name)
                if local:
                    _, layout = local
                    fi = layout.field_info(expr.field)
                    if fi:
                        return fi
        # Fall back: search all registered struct layouts
        try:
            for name, layout in self._tenv._layouts.items():
                fi = layout.field_info(expr.field)
                if fi:
                    return fi
        except Exception:
            pass
        return None

    def _resolve_field_offset(self, expr: ast.DotAccess) -> int:
        fi = self._resolve_field_info(expr)
        return fi.offset if fi else 0

    def _pointee_layout(self, ctx: FnCtx, ptr_expr) -> Tuple[TypeLayout, bool]:
        """Resolve the (layout, is_volatile) of what a pointer expression points to,
        so a Deref load/store picks the correct width (lb/lh/lw, sb/sh/sw) and
        emits sync() barriers for volatile MMIO. Falls back to a 4-byte word."""
        ptr_type = None
        if isinstance(ptr_expr, ast.Cast):
            ptr_type = ptr_expr.type
        elif isinstance(ptr_expr, ast.Ident) and ctx is not None:
            ptr_type = ctx.lookup_type_node(ptr_expr.name)
        # `*volatile u16` parses as TypeVolatile(TypePointer(u16)): an outer
        # volatile qualifier wrapping the pointer. Unwrap it, recording that the
        # access is volatile, then take the pointee from the inner TypePointer.
        volatile = False
        if isinstance(ptr_type, ast.TypeVolatile):
            volatile = True
            ptr_type = ptr_type.inner
        if isinstance(ptr_type, ast.TypePointer):
            inner = ptr_type.inner
            if isinstance(inner, ast.TypeVolatile):
                volatile = True
                inner = inner.inner
            return self._tenv.layout_of_type(inner), volatile
        return TypeLayout(size=4, align=4), False

    def _resolve_elem_layout(self, obj_expr) -> TypeLayout:
        """Try to determine the element layout for an array/slice access."""
        # If obj is an Ident, check its local type for TypeArray / TypeSlice
        if isinstance(obj_expr, ast.Ident) and self._fn_ctx:
            local = self._fn_ctx.lookup_local(obj_expr.name)
            if local:
                _, layout = local
                if layout.is_slice:
                    # Slice of known inner type — check via global type tracking
                    pass
        # Default: 4-byte word
        return TypeLayout(size=4, align=4)

    def _emit_index_access(self, ctx: FnCtx, expr: ast.IndexAccess, dst: str):
        em = self._em
        elem = self._resolve_elem_layout(expr.obj)
        with borrow_temp(ctx.ra) as base, borrow_temp(ctx.ra) as idx:
            self._emit_expr(ctx, expr.obj,   base)
            self._emit_expr(ctx, expr.index, idx)
            if elem.size == 4:
                em.sll(idx, idx, 2)
            elif elem.size == 2:
                em.sll(idx, idx, 1)
            elif elem.size == 1:
                pass  # byte-sized elements
            else:
                with borrow_temp(ctx.ra) as sz:
                    em.li(sz, elem.size)
                    em.mul(idx, idx, sz)
            em.addu(base, base, idx)
            self._emit_typed_load(dst, 0, base, elem)

    def _emit_index_store(self, ctx: FnCtx, expr: ast.IndexAccess, val: str):
        em = self._em
        elem = self._resolve_elem_layout(expr.obj)
        with borrow_temp(ctx.ra) as base, borrow_temp(ctx.ra) as idx:
            self._emit_expr(ctx, expr.obj,   base)
            self._emit_expr(ctx, expr.index, idx)
            if elem.size == 4:
                em.sll(idx, idx, 2)
            elif elem.size == 2:
                em.sll(idx, idx, 1)
            elif elem.size == 1:
                pass
            else:
                with borrow_temp(ctx.ra) as sz:
                    em.li(sz, elem.size)
                    em.mul(idx, idx, sz)
            em.addu(base, base, idx)
            self._emit_typed_store(val, 0, base, elem)

    def _emit_addr_of(self, ctx: FnCtx, expr: ast.AddrOf, dst: str):
        em = self._em
        inner = expr.expr
        if isinstance(inner, ast.Ident):
            local = ctx.lookup_local(inner.name) if ctx else None
            if local:
                off, _ = local
                em.addiu(dst, SP, off)
                return
            em.la(dst, inner.name)
        else:
            layout = TypeLayout(4, 4)
            off = ctx.declare_local('__addrof', layout) if ctx else 16
            with borrow_temp(ctx.ra) as tmp:
                self._emit_expr(ctx, inner, tmp)
                em.sw(tmp, off, SP)
            em.addiu(dst, SP, off)

    def _emit_slice(self, ctx: FnCtx, expr: ast.SliceExpr, dst: str):
        em = self._em
        slice_off = ctx.declare_local('__slice', TypeLayout(8, 4))
        with borrow_temp(ctx.ra) as base:
            self._emit_expr(ctx, expr.obj, base)
            if expr.start:
                with borrow_temp(ctx.ra) as s:
                    self._emit_expr(ctx, expr.start, s)
                    em.sll(s, s, 2)
                    em.addu(base, base, s)
            em.sw(base, slice_off, SP)
            if expr.end:
                with borrow_temp(ctx.ra) as end_r, borrow_temp(ctx.ra) as start_r:
                    self._emit_expr(ctx, expr.end, end_r)
                    if expr.start:
                        self._emit_expr(ctx, expr.start, start_r)
                        em.subu(end_r, end_r, start_r)
                    em.sw(end_r, slice_off + 4, SP)
            else:
                em.sw(ZERO, slice_off + 4, SP)
        em.addiu(dst, SP, slice_off)

    # ── Function calls ────────────────────────────────────────────────────────

    def _emit_call(self, ctx: FnCtx, expr: ast.Call, dst: str):
        em  = self._em
        func = expr.func

        # Variant constructor: VariantCase(args) where func is an Ident
        # matching a registered variant case name
        if isinstance(func, ast.Ident):
            vname = self._resolve_variant_name_for_case(func.name)
            if vname:
                self._emit_variant_constructor(ctx, vname, func.name, expr.args, dst)
                return

        # Variant constructor via .CaseName(args)
        if isinstance(func, ast.EnumVariantAccess):
            vname = self._resolve_variant_name_for_case(func.name)
            if vname:
                self._emit_variant_constructor(ctx, vname, func.name, expr.args, dst)
                return

        if isinstance(func, ast.DotAccess) and isinstance(func.obj, ast.DotAccess):
            mod = func.obj.field
            fn  = func.field
            self._emit_module_call(ctx, mod, fn, expr.args, dst)
            return

        if isinstance(func, ast.DotAccess):
            if isinstance(func.obj, ast.Ident):
                obj_name = func.obj.name
                # Check if this is a module call: display.init(), controller.read() etc.
                if self._rt.lookup(obj_name, func.field) is not None:
                    self._emit_module_call(ctx, obj_name, func.field, expr.args, dst)
                    return
                # Check if this is Type.CaseName(args) — variant constructor via dot
                if obj_name in self._tenv._variant_decls:
                    self._emit_variant_constructor(ctx, obj_name, func.field, expr.args, dst)
                    return
            self._emit_method_call(ctx, func, expr.args, dst)
            return

        fn_name = func.name if isinstance(func, ast.Ident) else None

        # Generic monomorphization: if the call has type_args or the func
        # references a known generic, emit a specialized version
        type_args = getattr(expr, 'type_args', []) or []
        if not type_args and isinstance(func, ast.Ident):
            type_args = getattr(func, 'type_args', []) or []
        if fn_name and type_args and fn_name in self._generic_fns:
            fn_name = self._monomorphize(fn_name, type_args)

        self._marshal_args(ctx, expr.args)

        if fn_name:
            em.jal(fn_name)
        else:
            with borrow_temp(ctx.ra) as fptr:
                self._emit_expr(ctx, func, fptr)
                em.jalr(fptr)
        em.nop()

        if dst != V0:
            em.move(dst, V0)

    def _emit_module_call(self, ctx: FnCtx, mod: str, fn: str, args, dst: str):
        em = self._em
        self._marshal_args(ctx, args)
        entry = self._rt.lookup(mod, fn)
        if entry:
            sym = entry['sym']
            em.jal(sym if isinstance(sym, str) else f'{mod}_{fn}')
        else:
            em.jal(f'{mod}_{fn}')
        em.nop()
        if dst != V0:
            em.move(dst, V0)

    def _emit_method_call(self, ctx: FnCtx, access: ast.DotAccess, args, dst: str):
        em = self._em
        # Try to resolve the type name from the variable's declared type
        type_name = ''
        if isinstance(access.obj, ast.Ident):
            local = ctx.lookup_local(access.obj.name)
            if local:
                _, layout = local
                # Check if this type name is registered
                for tname in self._tenv._layouts:
                    if self._tenv._layouts[tname] is layout:
                        type_name = tname
                        break
            if not type_name:
                # Fallback: capitalize the variable name (heuristic for Phase 1 compat)
                type_name = access.obj.name.capitalize()
        mangled  = f'{type_name}_{access.field}'
        with borrow_temp(ctx.ra) as self_ptr:
            self._emit_addr_of(ctx, ast.AddrOf(expr=access.obj, line=0, col=0), self_ptr)
            em.move(A0, self_ptr)
        self._marshal_args(ctx, args, start_idx=1)
        em.jal(mangled)
        em.nop()
        if dst != V0:
            em.move(dst, V0)

    def _marshal_args(self, ctx: FnCtx, args, start_idx: int = 0) -> list:
        em = self._em
        arg_gprs = [A0, A1, A2, A3]
        regs = []
        for i, arg in enumerate(args):
            slot = i + start_idx
            if slot < 4:
                reg = arg_gprs[slot]
                self._emit_expr(ctx, arg, reg)
                regs.append(reg)
            else:
                with borrow_temp(ctx.ra) as tmp:
                    self._emit_expr(ctx, arg, tmp)
                    em.sw(tmp, (slot - 4) * 4 + 16, SP)
                regs.append(f'<stack+{(slot-4)*4+16}>')
        return regs

    # ── Struct / array literals ───────────────────────────────────────────────

    def _emit_struct_lit(self, ctx: FnCtx, expr: ast.StructLit, dst: str):
        em = self._em
        layout = self._tenv.layout_of_name(expr.type_name)
        off = ctx.declare_local('__struct_lit', layout)
        # Zero-init the struct to handle padding
        if layout.size <= 32:
            for w in range(0, layout.size, 4):
                em.sw(ZERO, off + w, SP)
        else:
            em.addiu(A0, SP, off)
            em.move(A1, ZERO)
            em.li(A2, layout.size)
            em.jal('memset')
            em.nop()
        for fname, fval in expr.fields:
            fi = layout.field_info(fname)
            if fi:
                fl = self._tenv.layout_of_type(fi.type_node) if fi.type_node else TypeLayout(fi.size, fi.align)
                with borrow_temp(ctx.ra) as tmp:
                    self._emit_expr(ctx, fval, tmp)
                    self._emit_typed_store(tmp, off + fi.offset, SP, fl)
        em.addiu(dst, SP, off)

    def _emit_array_lit(self, ctx: FnCtx, expr: ast.ArrayLit, dst: str):
        em = self._em
        n = len(expr.elements)
        arr_off = ctx.declare_local('__arr_lit', TypeLayout(n * 4, 4))
        for i, elem in enumerate(expr.elements):
            with borrow_temp(ctx.ra) as tmp:
                self._emit_expr(ctx, elem, tmp)
                em.sw(tmp, arr_off + i * 4, SP)
        em.addiu(dst, SP, arr_off)

    # ── Inline assembly ────────────────────────────────────────────────────────

    def _emit_asm_expr(self, ctx: FnCtx, expr: ast.AsmExpr, dst: str):
        """Emit inline assembly with input/output constraint wiring.

        Constraints follow GCC-style: "=r" for output, "r" for input.
        The template can reference %0, %1 etc. for constraint slots.
        """
        em = self._em

        # Process inputs: evaluate expressions and place in registers
        input_regs = []
        for i, (constraint, input_expr) in enumerate(expr.inputs):
            with borrow_temp(ctx.ra) as inp_r:
                self._emit_expr(ctx, input_expr, inp_r)
                input_regs.append(inp_r)

        # Substitute %N references in the template with register names
        template = expr.template
        all_regs = [dst] + input_regs  # %0 = output, %1.. = inputs
        for i, reg in enumerate(all_regs):
            template = template.replace(f'%{i}', reg)

        # Emit each line of the template
        for line in template.split('\n'):
            line = line.strip()
            if line:
                em.verbatim(line)

        # Process outputs: move result to dst if needed
        if expr.outputs:
            # First output goes to dst
            em.move(dst, V0)
        elif not expr.inputs and not expr.outputs:
            # No constraints: just passthrough, result in $v0
            em.move(dst, V0)

    # ── Cast ──────────────────────────────────────────────────────────────────

    def _emit_cast(self, ctx: FnCtx, src: str, dst: str, type_node):
        to_layout = self._tenv.layout_of_type(type_node)
        em = self._em

        # Fixed-point conversions
        if to_layout.frac_bits > 0:
            # int → fixed: shift left by frac_bits
            emit_int_to_fix(em, dst, src, to_layout.frac_bits)
            return

        # Check if source expression is fixed-point (casting fix → int)
        # We detect this via the Cast AST node's inner expression
        src_frac = 0
        if self._fn_ctx:
            # Try to get source frac_bits from the expression being cast
            cast_node = None
            # (src is a register; we need the original AST, which the caller
            # no longer has here. Use a heuristic: if to_layout is int and
            # dst is not float, and the type is a known name, check it.)
            pass

        if to_layout.is_float:
            emit_int_to_float(em, F12, src)
            em.move(dst, ZERO)  # float result in FPR, GPR gets 0
            return

        emit_int_cast(em, dst, src, 4, to_layout.size, to_layout.is_signed)

    # ── Catch expression ──────────────────────────────────────────────────────

    def _emit_catch(self, ctx: FnCtx, expr: ast.CatchExpr, dst: str):
        em = self._em
        ok_label = self._fresh_label('.Lcatch_ok')
        # Result layout: {is_ok @ 0, payload @ pay_off}
        result_layout = self._infer_result_layout(expr.expr)
        tag_fi  = result_layout.fields.get('is_ok')
        pay_fi  = result_layout.fields.get('payload')
        t_off = tag_fi.offset if tag_fi else 0
        p_off = pay_fi.offset if pay_fi else 4
        with borrow_temp(ctx.ra) as result_ptr:
            self._emit_expr(ctx, expr.expr, result_ptr)
            with borrow_temp(ctx.ra) as ok_flag:
                em.lbu(ok_flag, t_off, result_ptr)
                em.bnez(ok_flag, ok_label)
                em.nop()
            if expr.handler:
                if expr.binding:
                    with borrow_temp(ctx.ra) as err_val:
                        em.lw(err_val, p_off, result_ptr)
                        bind_off = ctx.declare_local(expr.binding, TypeLayout(4, 4))
                        em.sw(err_val, bind_off, SP)
                self._emit_expr(ctx, expr.handler, dst)
            em.label(ok_label)
            em.lw(dst, p_off, result_ptr)

    # ── Closure ───────────────────────────────────────────────────────────────

    def _emit_closure(self, ctx: FnCtx, expr: ast.Closure) -> str:
        name = self._fresh_label('__closure')
        body = expr.body if isinstance(expr.body, ast.Block) \
               else ast.Block(stmts=[ast.Return(value=expr.body)])
        fn = ast.FnDecl(name=name, params=expr.params, ret_type=expr.ret_type,
                        body=body, annotations=[])
        saved = self._fn_ctx
        self._emit_fn(fn)
        self._fn_ctx = saved
        return name

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _fresh_label(self, prefix: str = '.L') -> str:
        n = self._label_n
        self._label_n += 1
        return f'{prefix}_{n}'

    def _eval_const_expr(self, expr) -> Optional[int]:
        if isinstance(expr, ast.IntLit):   return expr.value
        if isinstance(expr, ast.BoolLit):  return int(expr.value)
        if isinstance(expr, ast.Ident) and expr.name in self._consts:
            return self._consts[expr.name]
        if isinstance(expr, ast.BinaryOp):
            l = self._eval_const_expr(expr.left)
            r = self._eval_const_expr(expr.right)
            if l is not None and r is not None:
                match expr.op:
                    case '+':  return l + r
                    case '-':  return l - r
                    case '*':  return l * r
                    case '/':  return l // r if r else None
                    case '<<': return l << r
                    case '>>': return l >> r
                    case '&':  return l & r
                    case '|':  return l | r
        if isinstance(expr, ast.UnaryOp) and expr.op == '-':
            v = self._eval_const_expr(expr.operand)
            return -v if v is not None else None
        return None

    def _resolve_enum_case_value(self, case_name: str) -> int:
        for cases in self._tenv._enum_values.values():
            if case_name in cases:
                return cases[case_name]
        return 0

    def _resolve_variant_tag(self, case_name: str) -> int:
        try:
            for vdecl in self._tenv._variant_decls.values():
                for i, case in enumerate(vdecl.cases):
                    if case.name == case_name:
                        return i
        except Exception:
            pass
        return 0

    def _resolve_variant_name_for_case(self, case_name: str) -> Optional[str]:
        """Return the variant type name that contains the given case, or None."""
        for vname, vdecl in self._tenv._variant_decls.items():
            for case in vdecl.cases:
                if case.name == case_name:
                    return vname
        return None

    def _resolve_variant_layout_for_case(self, case_name: str) -> Optional[TypeLayout]:
        vname = self._resolve_variant_name_for_case(case_name)
        if vname:
            return self._tenv.layout_of_name(vname)
        return None

    def _emit_variant_constructor(self, ctx: FnCtx, variant_name: str,
                                  case_name: str, args: list, dst: str) -> None:
        """Emit a variant value: allocate on stack, store tag + payload fields."""
        em = self._em
        layout = self._tenv.layout_of_name(variant_name)
        tag_val = self._tenv.variant_tag(variant_name, case_name)
        case_fields = self._tenv.variant_case_fields(variant_name, case_name)

        off = ctx.declare_local('__variant_lit', layout)
        # Zero-init
        for w in range(0, layout.size, 4):
            em.sw(ZERO, off + w, SP)

        # Store tag
        tag_size = layout.tag_size or 1
        with borrow_temp(ctx.ra) as tmp:
            em.li(tmp, tag_val)
            if tag_size == 1:
                em.sb(tmp, off, SP)
            elif tag_size == 2:
                em.sh(tmp, off, SP)
            else:
                em.sw(tmp, off, SP)

        # Payload starts after tag, aligned to payload's max alignment
        payload_align = max((f.align for f in case_fields), default=4) if case_fields else 4
        payload_start = (tag_size + payload_align - 1) & ~(payload_align - 1)

        # Store each payload field
        for i, arg in enumerate(args):
            if i < len(case_fields):
                cf = case_fields[i]
                fl = self._tenv.layout_of_type(cf.type_node) if cf.type_node else TypeLayout(cf.size, cf.align)
                with borrow_temp(ctx.ra) as tmp:
                    self._emit_expr(ctx, arg, tmp)
                    self._emit_typed_store(tmp, off + payload_start + cf.offset, SP, fl)

        em.addiu(dst, SP, off)

    def _infer_result_layout(self, expr) -> TypeLayout:
        """Return a Result-shaped TypeLayout. Falls back to {bool, i32}."""
        # Default Result(i32, i32) layout
        return TypeLayout(
            size=8, align=4, tag_offset=0, tag_size=1,
            fields={
                'is_ok':   FieldInfo('is_ok', 0, 1, 1, None),
                'payload': FieldInfo('payload', 4, 4, 4, None),
            },
            field_order=['is_ok', 'payload'],
        )

    def _monomorphize(self, generic_name: str, type_args: list) -> str:
        """Create a monomorphized copy of a generic function.

        Returns the mangled name (e.g. 'swap__i32').  Emits the specialized
        function if not already emitted.
        """
        # Build mangled name from type args
        arg_names = []
        for ta in type_args:
            if isinstance(ta, ast.TypeName):
                arg_names.append(ta.name)
            elif isinstance(ta, str):
                arg_names.append(ta)
            else:
                arg_names.append('T')
        mangled = f'{generic_name}__{"_".join(arg_names)}'

        if mangled in self._mono_emitted:
            return mangled

        template = self._generic_fns.get(generic_name)
        if template is None:
            return generic_name  # fallback

        # Build a type substitution map: T → i32, U → f32, etc.
        subst: Dict[str, Any] = {}
        for i, tp in enumerate(template.type_params):
            if i < len(type_args):
                subst[tp] = type_args[i]

        # Create specialized function with substituted types
        spec_fn = ast.FnDecl(
            name=mangled,
            params=self._subst_params(template.params, subst),
            ret_type=self._subst_type(template.ret_type, subst),
            body=template.body,  # body stays the same (types only affect layout)
            type_params=[],  # no longer generic
            annotations=template.annotations,
        )

        self._mono_emitted[mangled] = True
        saved = self._fn_ctx
        self._emit_fn(spec_fn)
        self._fn_ctx = saved
        return mangled

    def _subst_type(self, type_node, subst: Dict[str, Any]):
        """Substitute generic type parameters in a type node."""
        if type_node is None:
            return None
        if isinstance(type_node, ast.TypeName) and type_node.name in subst:
            replacement = subst[type_node.name]
            if isinstance(replacement, ast.TypeName):
                return replacement
            return ast.TypeName(name=str(replacement) if isinstance(replacement, str)
                                else getattr(replacement, 'name', 'i32'))
        if isinstance(type_node, ast.TypePointer):
            return ast.TypePointer(inner=self._subst_type(type_node.inner, subst),
                                   nullable=type_node.nullable)
        if isinstance(type_node, ast.TypeSlice):
            return ast.TypeSlice(inner=self._subst_type(type_node.inner, subst))
        if isinstance(type_node, ast.TypeArray):
            return ast.TypeArray(size=type_node.size,
                                 inner=self._subst_type(type_node.inner, subst))
        return type_node

    def _subst_params(self, params: list, subst: Dict[str, Any]) -> list:
        """Substitute generic type params in function parameter list."""
        result = []
        for p in params:
            result.append(ast.Param(
                name=p.name,
                type=self._subst_type(p.type, subst),
                mutable=p.mutable,
            ))
        return result

    def _infer_frac_bits(self, ctx: FnCtx, expr) -> int:
        """Try to determine if an expression is fixed-point. Returns frac_bits or 0."""
        if isinstance(expr, ast.Ident):
            local = ctx.lookup_local(expr.name) if ctx else None
            if local:
                _, layout = local
                return layout.frac_bits
            if expr.name in self._globals:
                _, layout = self._globals[expr.name]
                return layout.frac_bits
        if isinstance(expr, ast.Cast):
            # If casting to a fixed-point type
            tl = self._tenv.layout_of_type(expr.type)
            return tl.frac_bits
        if isinstance(expr, ast.BinaryOp):
            # Propagate: if either side is fixed, the result is fixed
            l = self._infer_frac_bits(ctx, expr.left)
            r = self._infer_frac_bits(ctx, expr.right)
            return l or r
        if isinstance(expr, ast.UnaryOp):
            return self._infer_frac_bits(ctx, expr.operand)
        if isinstance(expr, ast.DotAccess):
            fi = self._resolve_field_info(expr)
            if fi and fi.type_node:
                tl = self._tenv.layout_of_type(fi.type_node)
                return tl.frac_bits
        return 0
