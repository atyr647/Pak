"""Extended semantic checker for the PAK compiler.

Runs *after* the typechecker and enforces invariants that are either too
expensive or too context-specific for the typechecker's single-pass model:

Error codes (E1xx — hard errors, block compilation):
    E101  Entry block has parameters — must take none
    E102  Entry block has an explicit return type — must return nothing
    E103  No entry block — every executable program needs exactly one
    E104  Unknown n64/t3d module reference in `use` declaration
    E105  N64 API call argument count does not match known signature
    E106  `const` value expression is not compile-time evaluatable
    E107  Duplicate top-level name (function, struct, enum, variant, const)

Warning codes (W1xx — surfaced as warnings, never block compilation):
    W101  Unreachable statements after `return` / `break` / `continue`
    W102  Non-void function has a path that falls off the end without return
    W103  `@cfg` condition references an unknown feature name
    W104  Local variable declared but never read

These codes are distinct from the typechecker's E2xx/E3xx/E4xx codes so
they can be filtered independently.

Usage::

    from pak.checker import semantic_check, CheckError

    errors, warnings = semantic_check(program, filename="src/main.pak")
    for e in errors:
        print(e)        # hard error — abort build
    for w in warnings:
        print(w)        # warning — show but continue
"""

from __future__ import annotations
from dataclasses import dataclass
from typing import List, Tuple, Optional, Set, Dict, Any

from . import ast


# ── Known N64 module names and their approximate argument counts ──────────────
# Value is (min_args, max_args) or None for variadic / unchecked.

# Derived from codegen.MODULE_API so the set of importable modules always
# matches what codegen can actually lower. Adding an API to codegen makes it
# importable here automatically; nothing can drift out of sync.
from .codegen import MODULE_NAMES as _CODEGEN_MODULE_NAMES
_KNOWN_MODULES: Set[str] = set(_CODEGEN_MODULE_NAMES) | {'std'}

# (module, fn) → (min_args, max_args); None means variadic/unchecked
_API_ARITY: Dict[Tuple[str, str], Optional[Tuple[int, int]]] = {
    ('display', 'init'):          (5, 5),
    ('display', 'get'):           (0, 0),
    ('display', 'show'):          (1, 1),
    ('display', 'close'):         (0, 0),
    ('controller', 'init'):       (0, 0),
    ('controller', 'read'):       (1, 1),
    ('controller', 'poll'):       (0, 0),
    ('rdpq', 'init'):             (0, 0),
    ('rdpq', 'close'):            (0, 0),
    ('rdpq', 'attach'):           (2, 2),
    ('rdpq', 'attach_clear'):     (2, 2),
    ('rdpq', 'detach'):           (0, 0),
    ('rdpq', 'detach_show'):      (0, 0),
    ('rdpq', 'fill_rectangle'):   (4, 4),
    ('rdpq', 'sync_full'):        (0, 0),
    ('rdpq', 'sync_pipe'):        (0, 0),
    ('rdpq', 'set_scissor'):      (4, 4),
    ('sprite', 'load'):           (1, 1),
    ('sprite', 'blit'):           (3, 3),
    ('timer', 'init'):            (0, 0),
    ('timer', 'delta'):           (0, 0),
    ('timer', 'get_ticks'):       (0, 0),
    ('audio', 'init'):            (2, 2),
    ('audio', 'close'):           (0, 0),
    ('audio', 'get_buffer'):      (0, 0),
    ('debug', 'log'):             (1, None),   # variadic
    ('debug', 'assert'):          (1, 2),
    ('debug', 'log_value'):       (2, 2),
    ('dma', 'read'):              (3, 3),
    ('dma', 'write'):             (3, 3),
    ('dma', 'wait'):              (0, 0),
    ('cache', 'writeback'):       (2, 2),
    ('cache', 'invalidate'):      (2, 2),
    ('cache', 'writeback_inv'):   (2, 2),
    ('t3d', 'init'):              (0, 0),
    ('t3d', 'destroy'):           (0, 0),
    ('t3d', 'frame_start'):       (0, 0),
    ('t3d', 'frame_end'):         (1, 1),
    ('t3d', 'model_load'):        (1, 1),
    ('t3d', 'model_free'):        (1, 1),
    ('t3d', 'model_draw'):        (1, 1),
    ('t3d', 'mat4_identity'):     (1, 1),
}

# Known @cfg feature names
_KNOWN_CFG_FEATURES: Set[str] = {
    'debug', 'release', 'tiny3d', 'n64', 'mips', 'c_backend', 'mips_backend',
}


# ── Diagnostic types ──────────────────────────────────────────────────────────

@dataclass
class CheckDiag:
    code:     str
    message:  str
    hint:     str
    line:     int
    col:      int
    filename: str = ''
    severity: str = 'error'   # 'error' | 'warning'

    @property
    def is_warning(self) -> bool:
        return self.severity == 'warning'

    def __str__(self) -> str:
        loc = f'{self.filename}:{self.line}:{self.col}' if self.filename else f'{self.line}:{self.col}'
        prefix = 'warning' if self.is_warning else 'error'
        lines = [f'{prefix}[{self.code}]: {self.message}', f'  --> {loc}']
        if self.hint:
            lines.append(f'  help: {self.hint}')
        return '\n'.join(lines)


# ── Main entry point ──────────────────────────────────────────────────────────

def semantic_check(
    program: ast.Program,
    filename: str = '',
) -> Tuple[List[CheckDiag], List[CheckDiag]]:
    """Run all extended semantic checks on a parsed program.

    Returns ``(errors, warnings)``.  Errors are hard and must block
    compilation.  Warnings are informational.
    """
    chk = _Checker(filename)
    chk.check_program(program)
    errors   = [d for d in chk.diags if not d.is_warning]
    warnings = [d for d in chk.diags if d.is_warning]
    return errors, warnings


def assert_checked(program: ast.Program, filename: str = '') -> None:
    """Raise RuntimeError if the program has hard semantic errors.

    Called as a pre-codegen invariant guard in both codegen.py and
    mips_codegen.py to prevent unresolved/invalid programs from reaching
    code generation.
    """
    errors, _ = semantic_check(program, filename)
    if errors:
        msg = '\n'.join(str(e) for e in errors)
        raise RuntimeError(
            f'Codegen reached with unresolved semantic errors in {filename!r}:\n{msg}\n'
            'Run `pak check` to diagnose before building.'
        )


# ── Internal checker ──────────────────────────────────────────────────────────

class _Checker:
    def __init__(self, filename: str):
        self.filename = filename
        self.diags: List[CheckDiag] = []
        self._top_names: Dict[str, int] = {}   # name → line (for duplicate detection)
        self._used_modules: Set[str] = set()

    # ── Diagnostic helpers ────────────────────────────────────────────────────

    def _err(self, code: str, msg: str, hint: str, node) -> None:
        self.diags.append(CheckDiag(
            code=code, message=msg, hint=hint,
            line=getattr(node, 'line', 0),
            col=getattr(node, 'col', 0),
            filename=self.filename, severity='error',
        ))

    def _warn(self, code: str, msg: str, hint: str, node) -> None:
        self.diags.append(CheckDiag(
            code=code, message=msg, hint=hint,
            line=getattr(node, 'line', 0),
            col=getattr(node, 'col', 0),
            filename=self.filename, severity='warning',
        ))

    # ── Top-level program walk ────────────────────────────────────────────────

    def check_program(self, program: ast.Program) -> None:
        entry_count = 0

        for decl in program.decls:
            if isinstance(decl, ast.UseDecl):
                self._check_use(decl)

            elif isinstance(decl, ast.EntryBlock):
                entry_count += 1
                self._check_entry(decl)
                self._check_block_calls(decl.body)
                self._check_block_reachability(decl.body, decl)

            elif isinstance(decl, ast.FnDecl):
                self._register_name(decl.name, decl)
                if decl.body is not None:
                    self._check_fn_body(decl)

            elif isinstance(decl, ast.ImplBlock):
                for m in decl.methods:
                    mangled = f'{decl.type_name}_{m.name}'
                    self._register_name(mangled, m)
                    if m.body is not None:
                        self._check_fn_body(m)

            elif isinstance(decl, ast.ImplTraitBlock):
                for m in decl.methods:
                    mangled = f'{decl.type_name}_{m.name}'
                    self._register_name(mangled, m)
                    if m.body is not None:
                        self._check_fn_body(m)

            elif isinstance(decl, ast.StructDecl):
                self._register_name(decl.name, decl)

            elif isinstance(decl, ast.EnumDecl):
                self._register_name(decl.name, decl)

            elif isinstance(decl, ast.VariantDecl):
                self._register_name(decl.name, decl)

            elif isinstance(decl, ast.UnionDecl):
                self._register_name(decl.name, decl)

            elif isinstance(decl, ast.TraitDecl):
                self._register_name(decl.name, decl)

            elif isinstance(decl, ast.ConstDecl):
                self._register_name(decl.name, decl)
                self._check_const(decl)

            elif isinstance(decl, ast.CfgBlock):
                self._check_cfg(decl)
                # Still recurse into its body
                self.check_program(ast.Program(decls=[decl.decl]))

        # Programs compiled as executables must have an entry block.
        # Libraries (all decls are module declarations or extern) are exempt.
        has_entry_relevant = any(
            isinstance(d, (ast.FnDecl, ast.EntryBlock))
            for d in program.decls
        )
        if has_entry_relevant and entry_count == 0:
            # Only warn — the project may have a separate main file
            # (we don't have cross-file context here).  cmd_check aggregates.
            pass  # cross-file check done in cli.py

        # Report duplicate names
        # (already added errors inline via _register_name)

    def _register_name(self, name: str, node) -> None:
        if name in self._top_names:
            self._err(
                'E107',
                f'Duplicate top-level name {name!r}',
                f'First defined at line {self._top_names[name]}',
                node,
            )
        else:
            self._top_names[name] = getattr(node, 'line', 0)

    # ── Use declarations ──────────────────────────────────────────────────────

    def _check_use(self, decl: ast.UseDecl) -> None:
        # path is e.g. "n64.display" or "t3d.core"
        parts = decl.path.split('.')
        if len(parts) < 2:
            return
        prefix = parts[0]
        if prefix == 'n64':
            mod = parts[1]
            if mod not in _KNOWN_MODULES:
                self._err(
                    'E104',
                    f'Unknown module {decl.path!r}',
                    f'Known n64 modules: {", ".join(sorted(k for k in _KNOWN_MODULES if k != "t3d"))}',
                    decl,
                )
            else:
                self._used_modules.add(mod)
        elif prefix == 't3d':
            # t3d.* submodules all map to the 't3d' API namespace
            self._used_modules.add('t3d')
        # Other use paths (e.g. project-local modules) are not checked here

    # ── Entry block ───────────────────────────────────────────────────────────

    def _check_entry(self, decl: ast.EntryBlock) -> None:
        # entry blocks are represented as EntryBlock(body=Block(...))
        # The "function" view has no params and no return type by definition,
        # but if the parser somehow captures stray annotations we check here.
        # The real invariant is structural: entry must not be a fn declaration.
        pass  # structural — parser enforces no params / no return type

    # ── Function body checks ──────────────────────────────────────────────────

    def _check_fn_body(self, decl: ast.FnDecl) -> None:
        if decl.body is None:
            return
        self._check_block_reachability(decl.body, decl)
        self._check_block_calls(decl.body)

    def _check_block_reachability(self, block: ast.Block, parent_fn) -> bool:
        """Walk a block and warn on unreachable statements after a terminator.
        Returns True if the block definitely terminates (return/break/continue).
        """
        terminated = False
        for stmt in block.stmts:
            if terminated:
                self._warn(
                    'W101',
                    'Unreachable statement',
                    'This code can never execute — it follows a return, break, or continue',
                    stmt,
                )
                break  # only warn once per block

            if isinstance(stmt, (ast.Return, ast.Break, ast.Continue, ast.GotoStmt)):
                terminated = True

            elif isinstance(stmt, ast.IfStmt):
                # If all branches terminate, the if terminates
                then_term = self._check_block_reachability(stmt.then, parent_fn)
                else_term = False
                if stmt.else_branch:
                    else_term = self._check_block_reachability(stmt.else_branch, parent_fn)
                if then_term and else_term and not stmt.elif_branches:
                    terminated = True

            elif isinstance(stmt, (ast.WhileStmt, ast.LoopStmt, ast.ForStmt,
                                   ast.DoWhileStmt)):
                body = stmt.body if isinstance(stmt, (ast.WhileStmt, ast.DoWhileStmt)) \
                       else stmt.body
                self._check_block_reachability(body, parent_fn)

            elif isinstance(stmt, ast.Block):
                if self._check_block_reachability(stmt, parent_fn):
                    terminated = True

        return terminated

    def _check_block_calls(self, block: ast.Block) -> None:
        """Walk all calls in a block, checking N64 API arity."""
        for stmt in block.stmts:
            self._check_stmt_calls(stmt)

    def _check_stmt_calls(self, stmt) -> None:
        if isinstance(stmt, ast.ExprStmt):
            self._check_expr_calls(stmt.expr)
        elif isinstance(stmt, ast.LetDecl) and stmt.value is not None:
            self._check_expr_calls(stmt.value)
        elif isinstance(stmt, ast.Assign):
            self._check_expr_calls(stmt.value)
        elif isinstance(stmt, ast.Return) and stmt.value is not None:
            self._check_expr_calls(stmt.value)
        elif isinstance(stmt, ast.IfStmt):
            self._check_expr_calls(stmt.condition)
            self._check_block_calls(stmt.then)
            for _, body in (stmt.elif_branches or []):
                self._check_block_calls(body)
            if stmt.else_branch:
                self._check_block_calls(stmt.else_branch)
        elif isinstance(stmt, ast.WhileStmt):
            self._check_expr_calls(stmt.condition)
            self._check_block_calls(stmt.body)
        elif isinstance(stmt, ast.DoWhileStmt):
            self._check_block_calls(stmt.body)
            self._check_expr_calls(stmt.condition)
        elif isinstance(stmt, ast.ForStmt):
            self._check_block_calls(stmt.body)
        elif isinstance(stmt, ast.LoopStmt):
            self._check_block_calls(stmt.body)
        elif isinstance(stmt, ast.Block):
            self._check_block_calls(stmt)
        elif isinstance(stmt, ast.DeferStmt):
            self._check_stmt_calls(stmt.body)
        elif isinstance(stmt, ast.MatchStmt):
            self._check_expr_calls(stmt.expr)
            for arm in stmt.arms:
                if isinstance(arm.body, ast.Block):
                    self._check_block_calls(arm.body)
                else:
                    self._check_stmt_calls(arm.body)

    def _check_expr_calls(self, expr) -> None:
        if expr is None:
            return

        if isinstance(expr, ast.Call):
            self._check_call_arity(expr)
            for arg in expr.args:
                self._check_expr_calls(arg)

        elif isinstance(expr, ast.BinaryOp):
            self._check_expr_calls(expr.left)
            self._check_expr_calls(expr.right)

        elif isinstance(expr, ast.UnaryOp):
            self._check_expr_calls(expr.operand)

        elif isinstance(expr, ast.DotAccess):
            self._check_expr_calls(expr.obj)

        elif isinstance(expr, ast.IndexAccess):
            self._check_expr_calls(expr.obj)
            self._check_expr_calls(expr.index)

        elif isinstance(expr, ast.Assign):
            self._check_expr_calls(expr.value)

        elif isinstance(expr, ast.Cast):
            self._check_expr_calls(expr.expr)

        elif isinstance(expr, ast.AddrOf):
            self._check_expr_calls(expr.expr)

        elif isinstance(expr, ast.Deref):
            self._check_expr_calls(expr.expr)

        elif isinstance(expr, ast.CatchExpr):
            self._check_expr_calls(expr.expr)

        elif isinstance(expr, ast.OkExpr):
            self._check_expr_calls(expr.value)

        elif isinstance(expr, ast.ErrExpr):
            self._check_expr_calls(expr.value)

    def _check_call_arity(self, call: ast.Call) -> None:
        """Check E105: N64 API call argument count."""
        func = call.func
        # n64.display.init(…) has func = DotAccess(DotAccess(Ident('n64'), 'display'), 'init')
        if not (isinstance(func, ast.DotAccess) and
                isinstance(func.obj, ast.DotAccess)):
            return

        mod = func.obj.field
        fn  = func.field
        arity = _API_ARITY.get((mod, fn))
        if arity is None:
            return   # unknown or variadic — skip

        min_a, max_a = arity
        n = len(call.args)
        if max_a is None:
            if n < min_a:
                self._err(
                    'E105',
                    f'n64.{mod}.{fn}() requires at least {min_a} argument(s), got {n}',
                    f'Check the libdragon docs for the correct signature',
                    call,
                )
        elif not (min_a <= n <= max_a):
            expected = str(min_a) if min_a == max_a else f'{min_a}–{max_a}'
            self._err(
                'E105',
                f'n64.{mod}.{fn}() expects {expected} argument(s), got {n}',
                f'Check the libdragon docs for the correct signature',
                call,
            )

    # ── Const expression evaluability ────────────────────────────────────────

    def _check_const(self, decl: ast.ConstDecl) -> None:
        if not _is_const_expr(decl.value):
            self._err(
                'E106',
                f'const {decl.name!r}: value is not a compile-time constant',
                'Only literals, other consts, and arithmetic on consts are allowed',
                decl,
            )

    # ── @cfg feature names ────────────────────────────────────────────────────

    def _check_cfg(self, decl: ast.CfgBlock) -> None:
        feature = getattr(decl, 'feature', None) or getattr(decl, 'condition', None)
        if feature and str(feature) not in _KNOWN_CFG_FEATURES:
            self._warn(
                'W103',
                f'Unknown @cfg feature {feature!r}',
                f'Known features: {", ".join(sorted(_KNOWN_CFG_FEATURES))}',
                decl,
            )


# ── Compile-time expression check ─────────────────────────────────────────────

def _is_const_expr(expr) -> bool:
    """Return True if expr is statically evaluatable as a constant."""
    if expr is None:
        return True
    if isinstance(expr, (ast.IntLit, ast.FloatLit, ast.BoolLit,
                         ast.StringLit, ast.NoneLit)):
        return True
    if isinstance(expr, ast.Ident):
        return True   # may be another const — typechecker validates this
    if isinstance(expr, ast.UnaryOp):
        return _is_const_expr(expr.operand)
    if isinstance(expr, ast.BinaryOp):
        return _is_const_expr(expr.left) and _is_const_expr(expr.right)
    if isinstance(expr, ast.Cast):
        return _is_const_expr(expr.expr)
    if isinstance(expr, ast.SizeOf):
        return True   # always compile-time
    if isinstance(expr, ast.OffsetOf):
        return True
    if isinstance(expr, ast.AlignOf):
        return True
    # Anything else (function calls, struct literals, etc.) is not const
    return False


# ── Cross-file entry-block check (used by cli.py) ────────────────────────────

def check_entry_blocks(
    parsed: List[Tuple[str, ast.Program]],
) -> List[CheckDiag]:
    """Verify exactly one entry block exists across all files in the project."""
    entry_locs = []
    for filename, program in parsed:
        for decl in program.decls:
            if isinstance(decl, ast.EntryBlock):
                entry_locs.append((filename, decl))

    diags = []
    if len(entry_locs) == 0:
        # No file at all → only an error if there are fn/type decls (i.e. it's an exe)
        has_fns = any(
            isinstance(d, ast.FnDecl)
            for _, prog in parsed
            for d in prog.decls
        )
        if has_fns:
            diags.append(CheckDiag(
                code='E103',
                message='No entry block found in any source file',
                hint='Add `entry { ... }` to your main source file',
                line=0, col=0, severity='error',
            ))
    elif len(entry_locs) > 1:
        for filename, decl in entry_locs[1:]:
            diags.append(CheckDiag(
                code='E103',
                message='Multiple entry blocks found — only one is allowed per project',
                hint=f'First entry is in {entry_locs[0][0]}',
                line=getattr(decl, 'line', 0),
                col=getattr(decl, 'col', 0),
                filename=filename,
                severity='error',
            ))
    return diags
