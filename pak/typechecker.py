"""Pak semantic analysis and type checker.

Performs two passes over the AST:
  1. Collect all top-level declarations into a TypeEnv.
  2. Walk every function/entry body checking:
       - Variable existence and type
       - Struct field existence
       - Function call arity
       - Exhaustive match (E301)
       - Use-after-move (E401)
       - DMA without cache writeback (E201)
       - Unaligned buffers passed to DMA (E202)

Errors are accumulated (not thrown) so the user sees all problems at once.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any, Set
from . import ast


# ── Error / Warning codes ─────────────────────────────────────────────────────

@dataclass
class PakError:
    code: str
    message: str
    hint: str
    line: int
    col: int
    filename: str = ''
    severity: str = 'error'   # 'error' | 'warning'

    @property
    def is_warning(self) -> bool:
        return self.severity == 'warning'

    def __str__(self):
        loc = f'{self.filename}:{self.line}:{self.col}' if self.filename else f'{self.line}:{self.col}'
        prefix = 'warning' if self.is_warning else 'error'
        lines = [f'{prefix}[{self.code}]: {self.message}', f'  --> {loc}']
        if self.hint:
            lines.append(f'  help: {self.hint}')
        return '\n'.join(lines)


# ── Type environment ──────────────────────────────────────────────────────────

class TypeEnv:
    """Global declarations collected in pass 1."""

    def __init__(self):
        self.structs:  Dict[str, ast.StructDecl]  = {}
        self.enums:    Dict[str, ast.EnumDecl]     = {}
        self.variants: Dict[str, ast.VariantDecl]  = {}
        self.fns:      Dict[str, ast.FnDecl]       = {}
        self.traits:   Dict[str, ast.TraitDecl]    = {}
        # trait_impls: (type_name, trait_name) → ImplTraitBlock
        self.trait_impls: Dict[tuple, ast.ImplTraitBlock] = {}
        # variant_name → enum/variant name (for exhaustive-match lookup)
        self.enum_cases:    Dict[str, str] = {}  # case → EnumDecl name
        self.variant_cases: Dict[str, str] = {}  # case → VariantDecl name

    def collect(self, program: ast.Program):
        for decl in program.decls:
            self._collect_one(decl)

    def _collect_one(self, decl):
        if isinstance(decl, (ast.StructDecl, ast.UnionDecl)):
            self.structs[decl.name] = decl
        elif isinstance(decl, ast.EnumDecl):
            self.enums[decl.name] = decl
            for v in decl.variants:
                self.enum_cases[v.name] = decl.name
        elif isinstance(decl, ast.VariantDecl):
            self.variants[decl.name] = decl
            for c in decl.cases:
                self.variant_cases[c.name] = decl.name
        elif isinstance(decl, ast.FnDecl):
            self.fns[decl.name] = decl
        elif isinstance(decl, ast.ImplBlock):
            for m in decl.methods:
                prefixed = f'{decl.type_name}_{m.name}'
                self.fns[prefixed] = m
        elif isinstance(decl, ast.ImplTraitBlock):
            self.trait_impls[(decl.type_name, decl.trait_name)] = decl
            for m in decl.methods:
                prefixed = f'{decl.type_name}_{m.name}'
                self.fns[prefixed] = m
        elif isinstance(decl, ast.TraitDecl):
            self.traits[decl.name] = decl
        elif isinstance(decl, ast.CfgBlock):
            self._collect_one(decl.decl)
        elif isinstance(decl, (ast.ConstDecl, ast.ExternConst)):
            pass  # names registered in _check_top

    def struct_fields(self, name: str) -> Optional[Dict[str, Any]]:
        """Return {field_name: type} for a struct, or None."""
        s = self.structs.get(name)
        if not s:
            return None
        return {f.name: f.type for f in s.fields}

    def fn_params(self, name: str) -> Optional[List[ast.Param]]:
        fn = self.fns.get(name)
        return fn.params if fn else None

    def all_cases(self, type_name: str) -> Optional[List[str]]:
        """Return the full case list for an enum or variant."""
        if type_name in self.enums:
            return [v.name for v in self.enums[type_name].variants]
        if type_name in self.variants:
            return [c.name for c in self.variants[type_name].cases]
        return None


# ── Scope stack ───────────────────────────────────────────────────────────────

class Scope:
    def __init__(self):
        self._stack: List[Dict[str, Any]] = [{}]  # {name: type_node}
        self._moved: Set[str] = set()

    def push(self):
        self._stack.append({})

    def pop(self):
        # Remove moved names that were declared in this scope
        local_names = set(self._stack[-1].keys())
        self._moved -= local_names
        self._stack.pop()

    def declare(self, name: str, typ):
        self._stack[-1][name] = typ
        self._moved.discard(name)

    def lookup(self, name: str) -> Optional[Any]:
        for frame in reversed(self._stack):
            if name in frame:
                return frame[name]
        return None

    def mark_moved(self, name: str):
        self._moved.add(name)

    def is_moved(self, name: str) -> bool:
        return name in self._moved

    def is_declared(self, name: str) -> bool:
        return self.lookup(name) is not None


# ── Fixed-point type helpers ──────────────────────────────────────────────────

FIXPOINT_SHIFTS = {
    'fix16.16': 16,
    'fix10.5':   5,
    'fix1.15':  15,
}


def is_fixpoint(typ) -> bool:
    return isinstance(typ, ast.TypeName) and typ.name in FIXPOINT_SHIFTS


def fixpoint_shift(typ) -> int:
    if isinstance(typ, ast.TypeName):
        return FIXPOINT_SHIFTS.get(typ.name, 0)
    return 0


# ── Type checker ──────────────────────────────────────────────────────────────

# Module names that are not variables (don't trigger "unknown variable" errors).
# Derived from codegen.MODULE_API (via MODULE_NAMES) plus the generic 'n64'
# prefix, so this can never drift out of sync with what codegen can lower.
from .codegen import MODULE_NAMES as _CODEGEN_MODULE_NAMES
MODULE_NAMESPACES = set(_CODEGEN_MODULE_NAMES) | {'n64'}

# C types that are always available (from includes)
BUILTIN_TYPES = {
    'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64',
    'f32', 'f64', 'bool', 'byte', 'fix16.16', 'fix10.5', 'fix1.15',
    'Vec2', 'Vec3', 'Vec4', 'Mat4', 'Str', 'CStr', 'PakStr', 'PakArena',
    'Arena', 'void', 'c_char', 'T3DVec2', 'T3DVec3', 'T3DVec4', 'T3DMat4',
}

# Annotations that imply 16-byte alignment
DMA_SAFE_ANNS = {'@dma_safe', '@aligned(16)'}

# libdragon DMA function names
DMA_FNS = {
    ('dma', 'read'), ('dma', 'write'),
    ('cache', 'writeback'), ('cache', 'invalidate'), ('cache', 'writeback_inv'),
}


class TypeChecker:
    def __init__(self, env: TypeEnv, filename: str = '', no_style_warnings: bool = False):
        self.env = env
        self.filename = filename
        self.no_style_warnings = no_style_warnings
        self.errors: List[PakError] = []
        self.scope = Scope()
        self._current_fn: Optional[ast.FnDecl] = None
        # Track dma-safe variables (have @dma_safe or @aligned(16))
        self._aligned_vars: Set[str] = set()
        # Track variables that had cache.writeback called on them
        self._cache_written: Set[str] = set()

    def err(self, code: str, msg: str, node, hint: str = ''):
        self.errors.append(PakError(
            code=code, message=msg, hint=hint,
            line=getattr(node, 'line', 0),
            col=getattr(node, 'col', 0),
            filename=self.filename,
            severity='error',
        ))

    def warn(self, code: str, msg: str, node, hint: str = ''):
        """Emit a style warning (suppressed by --no-style-warnings)."""
        if self.no_style_warnings:
            return
        self.errors.append(PakError(
            code=code, message=msg, hint=hint,
            line=getattr(node, 'line', 0),
            col=getattr(node, 'col', 0),
            filename=self.filename,
            severity='warning',
        ))

    # ── Pass 2: check bodies ─────────────────────────────────────────────────

    def check(self, program: ast.Program) -> List[PakError]:
        for decl in program.decls:
            self._check_naming(decl)
            self._check_top(decl)
        return self.errors

    # ── Naming convention checks (W001–W003) ──────────────────────────────────

    # Compiled once at class level for performance
    import re as _re
    _PASCAL = _re.compile(r'^[A-Z][a-zA-Z0-9]*$')
    _SNAKE  = _re.compile(r'^[a-z_][a-z0-9_]*$')
    _UPPER  = _re.compile(r'^[A-Z][A-Z0-9_]*$')

    def _check_naming(self, decl):
        """Emit W001/W002/W003 warnings for naming-convention violations."""
        if isinstance(decl, (ast.StructDecl, ast.EnumDecl, ast.VariantDecl)):
            name = decl.name
            if not self._PASCAL.match(name):
                self.warn('W001',
                          f"type '{name}' should be PascalCase",
                          decl,
                          hint=f"Rename to '{_to_pascal(name)}'")

        elif isinstance(decl, ast.FnDecl):
            name = decl.name
            # Allow 'main' and single-letter type params
            if name != 'main' and not self._SNAKE.match(name):
                self.warn('W002',
                          f"function '{name}' should be snake_case",
                          decl,
                          hint=f"Rename to '{_to_snake(name)}'")

        elif isinstance(decl, ast.ConstDecl):
            name = decl.name
            if not self._UPPER.match(name):
                self.warn('W003',
                          f"constant '{name}' should be UPPER_SNAKE_CASE",
                          decl,
                          hint=f"Rename to '{_to_upper_snake(name)}'")

        elif isinstance(decl, ast.StaticDecl):
            name = decl.name
            if not self._SNAKE.match(name):
                self.warn('W002',
                          f"static variable '{name}' should be snake_case",
                          decl,
                          hint=f"Rename to '{_to_snake(name)}'")

        elif isinstance(decl, ast.LetDecl):
            name = decl.name
            if name != '_' and not self._SNAKE.match(name):
                self.warn('W002',
                          f"variable '{name}' should be snake_case",
                          decl,
                          hint=f"Rename to '{_to_snake(name)}'")

        elif isinstance(decl, ast.ImplBlock):
            for m in decl.methods:
                self._check_naming(m)

    def _check_top(self, decl):
        if isinstance(decl, ast.FnDecl):
            self._check_fn(decl)
        elif isinstance(decl, ast.EntryBlock):
            self._check_block(decl.body)
        elif isinstance(decl, ast.StaticDecl):
            self._check_static(decl)
        elif isinstance(decl, ast.LetDecl):
            self._check_let(decl)
        elif isinstance(decl, ast.ImplBlock):
            for m in decl.methods:
                self._check_fn(m)
        elif isinstance(decl, ast.ImplTraitBlock):
            # Validate each method implementation against the trait signature
            trait = self.env.traits.get(decl.trait_name)
            if trait:
                trait_method_names = {m.name for m in trait.methods}
                for m in decl.methods:
                    if m.name not in trait_method_names:
                        self.err('E601',
                                 f"method '{m.name}' is not declared in trait '{decl.trait_name}'",
                                 m,
                                 hint=f"Remove this method or add it to trait '{decl.trait_name}'")
                # A trait method must either be implemented here or have a
                # default body in the trait. Flag any required (body-less)
                # trait method that the impl omits.
                impl_method_names = {m.name for m in decl.methods}
                for tm in trait.methods:
                    if tm.name not in impl_method_names and tm.body is None:
                        self.err('E602',
                                 f"impl of trait '{decl.trait_name}' for "
                                 f"'{decl.type_name}' is missing method '{tm.name}'",
                                 decl,
                                 hint=f"Implement '{tm.name}', or give it a "
                                      f"default body in trait '{decl.trait_name}'")
            for m in decl.methods:
                self._check_fn(m)
        elif isinstance(decl, (ast.TraitDecl, ast.UnionDecl)):
            pass  # trait/union bodies have no expressions to check
        elif isinstance(decl, ast.CfgBlock):
            self._check_naming(decl.decl)
            self._check_top(decl.decl)
        elif isinstance(decl, ast.ConstDecl):
            if decl.value:
                self._check_expr(decl.value)
            self.scope.declare(decl.name, decl.type or ast.TypeName(name='auto'))
        elif isinstance(decl, ast.ExternConst):
            self.scope.declare(decl.name, decl.type)
        elif isinstance(decl, ast.AssetDecl):
            self.scope.declare(decl.name, ast.TypeName(name='auto'))

    # Heap-allocating module functions that @no_alloc must not call
    _ALLOC_CALLS = {
        ('mem', 'alloc'), ('mem', 'alloc_aligned'), ('mem', 'realloc'),
        ('t3d', 'model_load'), ('t3d', 'skeleton_create'), ('t3d', 'anim_create'),
    }

    def _check_fn(self, fn: ast.FnDecl):
        if not fn.body:
            return
        old_fn = self._current_fn
        self._current_fn = fn
        self.scope.push()
        for p in fn.params:
            self.scope.declare(p.name, p.type)
            if _has_annotation(p, '@dma_safe') or _has_annotation(p, '@aligned(16)'):
                self._aligned_vars.add(p.name)
        self._check_block_stmts(fn.body.stmts)
        self.scope.pop()
        # @no_alloc: walk body for heap allocations
        if any(a == '@no_alloc' for a in (fn.annotations or [])):
            self._check_no_alloc_body(fn.body, fn)
        # Return type checking: non-void functions must have at least one return
        self._check_fn_returns(fn)
        self._current_fn = old_fn

    def _check_fn_returns(self, fn: ast.FnDecl):
        """Warn (W201) if a non-void function has no reachable return statement."""
        if fn.ret_type is None:
            return
        if isinstance(fn.ret_type, ast.TypeName) and fn.ret_type.name in ('void', 'never'):
            return
        if not fn.body or not fn.body.stmts:
            self.warn('W201', f"non-void function '{fn.name}' has no return statement", fn,
                      hint="Add a return statement or change the return type to void")
            return
        if not self._block_has_return(fn.body):
            self.warn('W201', f"non-void function '{fn.name}' may not return a value on all paths",
                      fn, hint="Ensure all code paths return a value")

    def _block_has_return(self, block) -> bool:
        """Return True if the block always ends with a return/break/continue."""
        if not block or not block.stmts:
            return False
        last = block.stmts[-1]
        if isinstance(last, ast.Return):
            return True
        if isinstance(last, ast.IfStmt):
            # Only guaranteed if both then and else branches return
            if last.else_branch and self._block_has_return(last.then) \
                    and self._block_has_return(last.else_branch):
                return True
        if isinstance(last, ast.LoopStmt):
            return True  # infinite loop — never falls through
        return False

    def _check_no_alloc_body(self, block: ast.Block, fn: ast.FnDecl):
        """Walk a function body and error on any heap-allocating calls."""
        for stmt in block.stmts:
            self._no_alloc_stmt(stmt, fn)

    def _no_alloc_stmt(self, stmt, fn):
        if isinstance(stmt, ast.ExprStmt):
            self._no_alloc_expr(stmt.expr, fn)
        elif isinstance(stmt, ast.LetDecl) and stmt.value:
            self._no_alloc_expr(stmt.value, fn)
        elif isinstance(stmt, ast.Return) and stmt.value:
            self._no_alloc_expr(stmt.value, fn)
        elif isinstance(stmt, ast.IfStmt):
            for st in stmt.then.stmts: self._no_alloc_stmt(st, fn)
            for _, eb in stmt.elif_branches:
                for st in eb.stmts: self._no_alloc_stmt(st, fn)
            if stmt.else_branch:
                for st in stmt.else_branch.stmts: self._no_alloc_stmt(st, fn)
        elif isinstance(stmt, (ast.WhileStmt, ast.LoopStmt, ast.ForStmt)):
            body = stmt.body if isinstance(stmt, (ast.WhileStmt, ast.ForStmt)) else stmt.body
            for st in body.stmts: self._no_alloc_stmt(st, fn)

    def _no_alloc_expr(self, expr, fn):
        if isinstance(expr, ast.Call):
            if isinstance(expr.func, ast.DotAccess) and isinstance(expr.func.obj, ast.Ident):
                key = (expr.func.obj.name, expr.func.field)
                if key in self._ALLOC_CALLS:
                    self.err('E501',
                             f"'{fn.name}' is marked @no_alloc but calls '{key[0]}.{key[1]}' which allocates heap memory",
                             expr,
                             hint="Remove the allocation or remove the @no_alloc annotation")
            for a in expr.args:
                self._no_alloc_expr(a, fn)
        elif isinstance(expr, ast.BinaryOp):
            self._no_alloc_expr(expr.left, fn)
            self._no_alloc_expr(expr.right, fn)

    def _check_block(self, block: ast.Block):
        self.scope.push()
        self._check_block_stmts(block.stmts)
        self.scope.pop()

    def _check_block_stmts(self, stmts):
        for stmt in stmts:
            self._check_stmt(stmt)

    def _check_stmt(self, stmt):
        if isinstance(stmt, ast.LetDecl):
            self._check_let(stmt)
        elif isinstance(stmt, ast.StaticDecl):
            self._check_static(stmt)
        elif isinstance(stmt, ast.ExprStmt):
            self._check_expr(stmt.expr)
            self._check_dma_call(stmt.expr)
        elif isinstance(stmt, ast.Return):
            if stmt.value:
                self._check_expr(stmt.value)
        elif isinstance(stmt, ast.IfStmt):
            self._check_expr(stmt.condition)
            self._check_block(stmt.then)
            for ec, eb in stmt.elif_branches:
                self._check_expr(ec)
                self._check_block(eb)
            if stmt.else_branch:
                self._check_block(stmt.else_branch)
        elif isinstance(stmt, ast.NullCheckStmt):
            self._check_expr(stmt.expr)
            self.scope.push()
            self.scope.declare(stmt.binding, ast.TypeName(name='auto'))
            self._check_block_stmts(stmt.then.stmts)
            self.scope.pop()
            if stmt.else_branch:
                self._check_block(stmt.else_branch)
        elif isinstance(stmt, ast.LoopStmt):
            self._check_block(stmt.body)
        elif isinstance(stmt, ast.WhileStmt):
            self._check_expr(stmt.condition)
            self._check_block(stmt.body)
        elif isinstance(stmt, ast.ForStmt):
            self._check_expr(stmt.iterable)
            self.scope.push()
            self.scope.declare(stmt.binding, ast.TypeName(name='auto'))
            if stmt.index:
                self.scope.declare(stmt.index, ast.TypeName(name='i32'))
            self._check_block_stmts(stmt.body.stmts)
            self.scope.pop()
        elif isinstance(stmt, ast.MatchStmt):
            self._check_match(stmt)
        elif isinstance(stmt, ast.DeferStmt):
            self._check_block(stmt.body)
        elif isinstance(stmt, (ast.Break, ast.Continue)):
            pass
        elif isinstance(stmt, ast.Block):
            self._check_block(stmt)
        elif isinstance(stmt, ast.ConstDecl):
            if stmt.value:
                self._check_expr(stmt.value)
            self.scope.declare(stmt.name, stmt.type or ast.TypeName(name='auto'))
        elif isinstance(stmt, ast.AsmStmt):
            pass  # raw asm — nothing to check
        elif isinstance(stmt, (ast.GotoStmt, ast.LabelStmt)):
            pass  # goto/labels don't introduce new bindings
        elif isinstance(stmt, ast.DoWhileStmt):
            self._check_block(stmt.body)
            self._check_expr(stmt.condition)
        elif isinstance(stmt, ast.ComptimeIf):
            self._check_expr(stmt.condition)
            self._check_block(stmt.then)
            if stmt.else_branch:
                self._check_block(stmt.else_branch)

    def _check_let(self, s: ast.LetDecl):
        if s.value:
            self._check_expr(s.value)
        typ = s.type
        if typ is None and s.value:
            typ = self._infer_type(s.value)
        self.scope.declare(s.name, typ or ast.TypeName(name='auto'))
        anns = s.annotations or []
        if any(a in DMA_SAFE_ANNS or a.startswith('@aligned') for a in anns):
            self._aligned_vars.add(s.name)
        # Move tracking: pointer-typed variables are moved when assigned to a new binding.
        # This implements Pak's simplified ownership rule: resource handles (pointer types)
        # are not copyable — assigning `let b = a` where a is *T moves ownership to b.
        if isinstance(s.value, ast.Ident):
            src_type = self.scope.lookup(s.value.name)
            if isinstance(src_type, ast.TypePointer):
                self.scope.mark_moved(s.value.name)

    def _check_static(self, s: ast.StaticDecl):
        if s.value:
            self._check_expr(s.value)
        self.scope.declare(s.name, s.type or ast.TypeName(name='auto'))
        anns = s.annotations or []
        if any(a in DMA_SAFE_ANNS or a.startswith('@aligned') for a in anns):
            self._aligned_vars.add(s.name)

    def _check_expr(self, expr):
        """Recursively validate an expression."""
        if expr is None:
            return
        if isinstance(expr, ast.Ident):
            name = expr.name
            if name == '_':
                return
            if name in MODULE_NAMESPACES:
                return
            if not self.scope.is_declared(name):
                # Could be an enum type name — allow it
                if name in self.env.enums or name in self.env.variants or name in self.env.structs:
                    return
                # Could be a trait name
                if name in self.env.traits:
                    return
                # Could be a function name
                if name in self.env.fns:
                    return
                self.err('E010', f"unknown name '{name}'", expr,
                         hint=f"declare it with 'let {name} = ...'")
                return
            if self.scope.is_moved(name):
                self.err('E401', f"use of '{name}' after it was moved", expr,
                         hint=f"If you need to use '{name}' after passing it, pass a pointer: &{name}")

        elif isinstance(expr, ast.DotAccess):
            self._check_expr(expr.obj)
            # Check struct field existence
            if isinstance(expr.obj, ast.Ident):
                self._check_field_access(expr.obj, expr.field, expr)

        elif isinstance(expr, ast.Call):
            for a in expr.args:
                self._check_expr(a)
            self._check_call_arity(expr)
            # Track cache operations
            if isinstance(expr.func, ast.DotAccess):
                if isinstance(expr.func.obj, ast.Ident):
                    mod, fn = expr.func.obj.name, expr.func.field
                    if (mod, fn) in {('cache', 'writeback'), ('cache', 'writeback_inv')}:
                        # Mark first arg as cache-written
                        if expr.args:
                            a = expr.args[0]
                            name = self._expr_base_name(a)
                            if name:
                                self._cache_written.add(name)

        elif isinstance(expr, ast.BinaryOp):
            self._check_expr(expr.left)
            self._check_expr(expr.right)

        elif isinstance(expr, ast.UnaryOp):
            self._check_expr(expr.operand)

        elif isinstance(expr, ast.Assign):
            self._check_expr(expr.target)
            self._check_expr(expr.value)

        elif isinstance(expr, ast.AddrOf):
            self._check_expr(expr.expr)

        elif isinstance(expr, ast.Deref):
            self._check_expr(expr.expr)

        elif isinstance(expr, ast.IndexAccess):
            self._check_expr(expr.obj)
            self._check_expr(expr.index)

        elif isinstance(expr, ast.SliceExpr):
            self._check_expr(expr.obj)
            if expr.start:
                self._check_expr(expr.start)
            if expr.end:
                self._check_expr(expr.end)

        elif isinstance(expr, ast.Cast):
            self._check_expr(expr.expr)

        elif isinstance(expr, ast.StructLit):
            self._check_struct_lit(expr)
            for _, v in expr.fields:
                self._check_expr(v)

        elif isinstance(expr, ast.ArrayLit):
            for el in expr.elements:
                self._check_expr(el)
            if expr.repeat:
                self._check_expr(expr.repeat)

        elif isinstance(expr, ast.CatchExpr):
            self._check_expr(expr.expr)
            self.scope.push()
            if expr.binding:
                self.scope.declare(expr.binding, ast.TypeName(name='auto'))
            self._check_block_stmts(expr.handler.stmts)
            self.scope.pop()

        elif isinstance(expr, ast.NamedArg):
            self._check_expr(expr.value)

        elif isinstance(expr, ast.RangeExpr):
            self._check_expr(expr.start)
            if expr.end:
                self._check_expr(expr.end)

        elif isinstance(expr, ast.OkExpr):
            self._check_expr(expr.value)

        elif isinstance(expr, ast.ErrExpr):
            self._check_expr(expr.value)

        elif isinstance(expr, ast.SizeOf):
            pass  # no sub-expressions to check

        elif isinstance(expr, ast.AlignOf):
            pass  # operand is a type or expr; no name-resolution needed here

        elif isinstance(expr, ast.OffsetOf):
            pass  # no sub-expressions to check

        elif isinstance(expr, ast.FmtStr):
            for part in expr.parts:
                if not isinstance(part, str):
                    self._check_expr(part)

        elif isinstance(expr, ast.AsmExpr):
            for _, e in expr.outputs:
                self._check_expr(e)
            for _, e in expr.inputs:
                self._check_expr(e)

        elif isinstance(expr, ast.Closure):
            self.scope.push()
            for p in expr.params:
                self.scope.declare(p.name, p.type)
            self._check_block_stmts(expr.body.stmts)
            self.scope.pop()

        elif isinstance(expr, ast.TupleLit):
            for el in expr.elements:
                self._check_expr(el)

        elif isinstance(expr, ast.TupleAccess):
            self._check_expr(expr.obj)

        elif isinstance(expr, ast.AllocExpr):
            if expr.count is not None:
                self._check_expr(expr.count)

        elif isinstance(expr, ast.FreeExpr):
            self._check_expr(expr.ptr)

    # ── Field access checking ─────────────────────────────────────────────────

    def _check_field_access(self, obj_ident: ast.Ident, field: str, node):
        """If we know the struct type of obj_ident, verify field exists."""
        typ = self.scope.lookup(obj_ident.name)
        struct_name = self._unwrap_type_name(typ)
        if struct_name and struct_name in self.env.structs:
            fields = self.env.struct_fields(struct_name)
            if fields is not None and field not in fields:
                self.err('E011',
                         f"struct '{struct_name}' has no field '{field}'",
                         node,
                         hint=f"Available fields: {', '.join(fields.keys())}")

    # ── Call arity checking ───────────────────────────────────────────────────

    def _check_call_arity(self, call: ast.Call):
        """Check that user-defined functions are called with the right number of args."""
        if not isinstance(call.func, ast.Ident):
            return
        name = call.func.name
        params = self.env.fn_params(name)
        if params is None:
            return  # external or unknown
        n_args = len(call.args)
        n_params = len(params)
        fn = self.env.fns.get(name)
        if fn is not None and getattr(fn, 'variadic', False):
            # Variadic function: the declared params are the minimum; extra
            # trailing args are passed through to C as varargs.
            if n_args < n_params:
                self.err('E012',
                         f"function '{name}' takes at least {n_params} argument(s), got {n_args}",
                         call,
                         hint=f"Expected: {name}({', '.join(p.name + ': ' + _type_str(p.type) for p in params)}, ...)")
            return
        if n_args != n_params:
            self.err('E012',
                     f"function '{name}' takes {n_params} argument(s), got {n_args}",
                     call,
                     hint=f"Expected: {name}({', '.join(p.name + ': ' + _type_str(p.type) for p in params)})")

    # ── Struct literal checking ───────────────────────────────────────────────

    def _check_struct_lit(self, lit: ast.StructLit):
        decl = self.env.structs.get(lit.type_name)
        if not decl:
            return  # might be a C struct — don't error
        known = {f.name for f in decl.fields}
        given = {name for name, _ in lit.fields}
        unknown = given - known
        for u in sorted(unknown):
            self.err('E013',
                     f"struct '{lit.type_name}' has no field '{u}'",
                     lit,
                     hint=f"Valid fields: {', '.join(sorted(known))}")
        missing = known - given
        if missing:
            self.err('E014',
                     f"struct '{lit.type_name}' missing fields: {', '.join(sorted(missing))}",
                     lit,
                     hint=f"Add the missing fields or initialise them to a default value")

    # ── Exhaustive match (E301) ───────────────────────────────────────────────

    def _check_match(self, stmt: ast.MatchStmt):
        self._check_expr(stmt.expr)
        # Collect covered patterns
        has_wildcard = False
        covered: Set[str] = set()
        for arm in stmt.arms:
            self.scope.push()
            pat = arm.pattern
            if isinstance(pat, ast.Ident) and pat.name == '_':
                has_wildcard = True
            elif isinstance(pat, ast.EnumVariantAccess):
                covered.add(pat.name)
            elif isinstance(pat, ast.DotAccess) and isinstance(pat.obj, ast.Ident):
                covered.add(pat.field)
            elif isinstance(pat, ast.Call) and isinstance(pat.func, ast.EnumVariantAccess):
                # .Case(binding, ...) — payload-bearing variant arm
                covered.add(pat.func.name)
                for arg in pat.args:
                    if isinstance(arg, ast.Ident) and arg.name != '_':
                        self.scope.declare(arg.name, ast.TypeName(name='auto'))
            if isinstance(arm.body, ast.Block):
                self._check_block_stmts(arm.body.stmts)
            self.scope.pop()

        if has_wildcard:
            return

        # Determine the matched type
        match_type = self._infer_match_type(stmt.expr)
        if match_type is None:
            return  # can't determine — skip exhaustiveness check
        all_cases = self.env.all_cases(match_type)
        if all_cases is None:
            return

        missing = [c for c in all_cases if c not in covered]
        if missing:
            self.err('E301',
                     f"non-exhaustive match on '{match_type}'",
                     stmt,
                     hint=f"Add missing cases: {', '.join('.' + m for m in missing)}"
                          f", or add a default: _ => {{}}")

    def _infer_match_type(self, expr) -> Optional[str]:
        """Best-effort: return the enum/variant type name being matched."""
        if isinstance(expr, ast.Ident):
            typ = self.scope.lookup(expr.name)
            return self._unwrap_type_name(typ)
        if isinstance(expr, ast.DotAccess):
            # e.g. self.state
            if isinstance(expr.obj, ast.Ident):
                typ = self.scope.lookup(expr.obj.name)
                struct_name = self._unwrap_type_name(typ)
                if struct_name:
                    fields = self.env.struct_fields(struct_name)
                    if fields and expr.field in fields:
                        return self._unwrap_type_name(fields[expr.field])
        return None

    # ── DMA safety checks (E201, E202) ───────────────────────────────────────

    def _check_dma_call(self, expr):
        """Check DMA calls for cache writeback (E201) and alignment (E202)."""
        if not isinstance(expr, ast.Call):
            return
        if not isinstance(expr.func, ast.DotAccess):
            return
        if not isinstance(expr.func.obj, ast.Ident):
            return
        mod, fn = expr.func.obj.name, expr.func.field
        if (mod, fn) not in DMA_FNS:
            return

        # Only check the first argument (the buffer/pointer).
        # Subsequent arguments (address, size, etc.) are integers — checking them
        # produces false-positive E201/E202 when they are named constants.
        if not expr.args:
            return
        name = self._expr_base_name(expr.args[0])
        if not name:
            return

        # E201: DMA without cache writeback
        if name not in self._cache_written and name not in self._aligned_vars:
            self.err('E201',
                     f"possible stale cache before DMA transfer of '{name}'",
                     expr,
                     hint=f"Add before the transfer: cache.writeback(&{name})")

        # E202: Unaligned buffer
        if name not in self._aligned_vars:
            self.err('E202',
                     f"buffer '{name}' may not be 16-byte aligned for DMA",
                     expr,
                     hint=f"Declare it with @aligned(16): @aligned(16) let {name}: ...")

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _infer_type(self, expr) -> Optional[Any]:
        """Best-effort type inference for an expression."""
        if isinstance(expr, ast.IntLit):
            return ast.TypeName(name='i32')
        if isinstance(expr, ast.FloatLit):
            return ast.TypeName(name='f32')
        if isinstance(expr, ast.BoolLit):
            return ast.TypeName(name='bool')
        if isinstance(expr, ast.StringLit):
            return ast.TypeName(name='Str')
        if isinstance(expr, ast.Ident):
            return self.scope.lookup(expr.name)
        if isinstance(expr, ast.AddrOf):
            inner = self._infer_type(expr.expr)
            if inner:
                return ast.TypePointer(inner=inner, mutable=expr.mutable)
        if isinstance(expr, ast.StructLit):
            return ast.TypeName(name=expr.type_name)
        if isinstance(expr, ast.EnumVariantAccess):
            enum_name = self.env.enum_cases.get(expr.name)
            if enum_name:
                return ast.TypeName(name=enum_name)
        return None

    def _unwrap_type_name(self, typ) -> Optional[str]:
        """Extract the base type name from a type node, unwrapping pointers."""
        if isinstance(typ, ast.TypeName):
            return typ.name
        if isinstance(typ, ast.TypePointer):
            return self._unwrap_type_name(typ.inner)
        return None

    def _expr_base_name(self, expr) -> Optional[str]:
        """Return the base variable name of an expression (for DMA tracking)."""
        if isinstance(expr, ast.Ident):
            return expr.name
        if isinstance(expr, ast.AddrOf):
            return self._expr_base_name(expr.expr)
        if isinstance(expr, ast.DotAccess):
            return self._expr_base_name(expr.obj)
        if isinstance(expr, ast.IndexAccess):
            return self._expr_base_name(expr.obj)
        return None


# ── Helpers ───────────────────────────────────────────────────────────────────

def _has_annotation(node, ann: str) -> bool:
    anns = getattr(node, 'annotations', []) or []
    return ann in anns


# ── Naming conversion helpers (used in warning hints) ─────────────────────────

def _to_snake(name: str) -> str:
    """Best-effort: convert a name to snake_case for use in warning hints."""
    import re
    s = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1_\2', name)
    s = re.sub(r'([a-z\d])([A-Z])', r'\1_\2', s)
    return s.lower()


def _to_pascal(name: str) -> str:
    """Best-effort: convert a name to PascalCase for use in warning hints."""
    parts = name.replace('-', '_').split('_')
    return ''.join(p.capitalize() for p in parts if p)


def _to_upper_snake(name: str) -> str:
    """Best-effort: convert a name to UPPER_SNAKE_CASE for use in warning hints."""
    return _to_snake(name).upper()


def _type_str(typ) -> str:
    if isinstance(typ, ast.TypeName):
        return typ.name
    if isinstance(typ, ast.TypePointer):
        prefix = '?*' if typ.nullable else '*'
        return prefix + _type_str(typ.inner)
    if isinstance(typ, ast.TypeSlice):
        return '[]' + _type_str(typ.inner)
    if isinstance(typ, ast.TypeArray):
        return f'[N]{_type_str(typ.inner)}'
    return '?'


# ── Public API ────────────────────────────────────────────────────────────────

def typecheck(program: ast.Program, filename: str = '',
              no_style_warnings: bool = False) -> List[PakError]:
    """Run the type checker on a parsed program. Returns list of errors/warnings."""
    env = TypeEnv()
    env.collect(program)
    checker = TypeChecker(env, filename, no_style_warnings=no_style_warnings)
    return checker.check(program)


def typecheck_multi(programs: List[tuple],
                    no_style_warnings: bool = False) -> Dict[str, List[PakError]]:
    """
    Type-check multiple programs sharing a common environment.
    programs: list of (filename, ast.Program)
    Returns {filename: [errors/warnings]}
    """
    env = TypeEnv()
    for _, prog in programs:
        env.collect(prog)

    results = {}
    for filename, prog in programs:
        checker = TypeChecker(env, filename, no_style_warnings=no_style_warnings)
        results[filename] = checker.check(prog)
    return results
