"""Pak AST node definitions."""

from dataclasses import dataclass, field
from typing import List, Optional, Any


# ── Types ────────────────────────────────────────────────────────────────────

@dataclass
class TypeName:
    name: str
    line: int = 0
    col: int = 0

@dataclass
class TypeParam:
    """A generic type parameter placeholder, e.g. T in fn foo<T>(...)"""
    name: str
    line: int = 0
    col: int = 0

@dataclass
class TypeGeneric:
    """A parameterized type, e.g. List<i32> or Map<Str, i32>"""
    name: str
    args: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class TypePointer:
    inner: Any
    nullable: bool = False
    mutable: bool = False
    line: int = 0
    col: int = 0

@dataclass
class TypeSlice:
    inner: Any
    mutable: bool = False
    line: int = 0
    col: int = 0

@dataclass
class TypeArray:
    size: Any
    inner: Any
    line: int = 0
    col: int = 0

@dataclass
class TypeResult:
    ok: Any
    err: Any
    line: int = 0
    col: int = 0

@dataclass
class TypeOption:
    inner: Any
    line: int = 0
    col: int = 0

@dataclass
class TypeFn:
    params: List[Any]
    ret: Optional[Any]
    line: int = 0
    col: int = 0

@dataclass
class TypeVolatile:
    """volatile T — volatile-qualified pointer/type."""
    inner: Any
    line: int = 0
    col: int = 0

@dataclass
class TypeTuple:
    """Tuple type: (T1, T2, T3)"""
    elements: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class TypeDynTrait:
    """Trait-object type: dyn TraitName  (used as *dyn TraitName or standalone)."""
    name: str
    line: int = 0
    col: int = 0


# ── Expressions ──────────────────────────────────────────────────────────────

@dataclass
class IntLit:
    value: int
    raw: str = ''
    line: int = 0
    col: int = 0

@dataclass
class FloatLit:
    value: float
    raw: str = ''
    line: int = 0
    col: int = 0

@dataclass
class BoolLit:
    value: bool
    line: int = 0
    col: int = 0

@dataclass
class StringLit:
    value: str
    line: int = 0
    col: int = 0

@dataclass
class NoneLit:
    line: int = 0
    col: int = 0

@dataclass
class UndefinedLit:
    line: int = 0
    col: int = 0

@dataclass
class Ident:
    name: str
    line: int = 0
    col: int = 0
    # Turbofish type arguments, e.g. foo::<i32>() — populated by parser, read by codegen
    type_args: List[Any] = field(default_factory=list)

@dataclass
class DotAccess:
    obj: Any
    field: str
    line: int = 0
    col: int = 0
    # For variant match patterns: Variant.case(binding) — holds the bound variable name
    binding: Optional[str] = None

@dataclass
class IndexAccess:
    obj: Any
    index: Any
    line: int = 0
    col: int = 0

@dataclass
class SliceExpr:
    obj: Any
    start: Optional[Any]
    end: Optional[Any]
    line: int = 0
    col: int = 0

@dataclass
class Call:
    func: Any
    args: List[Any]
    type_args: List[Any] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class StructLit:
    type_name: str
    fields: List[Any]   # list of (name, expr) tuples
    line: int = 0
    col: int = 0

@dataclass
class ArrayLit:
    elements: List[Any]
    repeat: Optional[Any] = None
    line: int = 0
    col: int = 0

@dataclass
class UnaryOp:
    op: str
    operand: Any
    line: int = 0
    col: int = 0

@dataclass
class BinaryOp:
    op: str
    left: Any
    right: Any
    line: int = 0
    col: int = 0

@dataclass
class Assign:
    target: Any
    value: Any
    op: str = '='
    line: int = 0
    col: int = 0

@dataclass
class AddrOf:
    expr: Any
    mutable: bool = False
    line: int = 0
    col: int = 0

@dataclass
class Deref:
    expr: Any
    line: int = 0
    col: int = 0

@dataclass
class Cast:
    expr: Any
    type: Any
    line: int = 0
    col: int = 0

@dataclass
class RangeExpr:
    start: Any
    end: Optional[Any]
    line: int = 0
    col: int = 0

@dataclass
class EnumVariantAccess:
    name: str
    line: int = 0
    col: int = 0

@dataclass
class NamedArg:
    name: str
    value: Any
    line: int = 0
    col: int = 0

@dataclass
class CatchExpr:
    expr: Any
    binding: Optional[str]
    handler: Any
    line: int = 0
    col: int = 0

@dataclass
class NullCheck:
    expr: Any
    binding: Optional[str]
    line: int = 0
    col: int = 0

@dataclass
class SizeOf:
    """sizeof(T) or sizeof(expr)"""
    operand: Any
    line: int = 0
    col: int = 0

@dataclass
class OkExpr:
    """ok(value) — construct a Result in the Ok state"""
    value: Any
    line: int = 0
    col: int = 0

@dataclass
class ErrExpr:
    """err(value) — construct a Result in the Err state"""
    value: Any
    line: int = 0
    col: int = 0

@dataclass
class OffsetOf:
    """offsetof(Type, field)"""
    type_name: str
    field: str
    line: int = 0
    col: int = 0

@dataclass
class Closure:
    """fn(params) -> ret { body } or fn(params) -> ret = expr — fn literal / lambda"""
    params: List[Any]      # List[Param]
    ret_type: Optional[Any]
    body: Any              # Block or single expr
    line: int = 0
    col: int = 0

@dataclass
class TupleLit:
    """Tuple literal expression: (e1, e2, e3)"""
    elements: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class TupleAccess:
    """Tuple element access: t.0, t.1 ..."""
    obj: Any
    index: int
    line: int = 0
    col: int = 0

@dataclass
class AllocExpr:
    """alloc(T) or alloc(T, n) — heap allocation primitive."""
    type_node: Any          # type to allocate
    count: Optional[Any]    # element count; None means single item
    allocator: Optional[Any] = None   # NEW: custom allocator expression
    line: int = 0
    col: int = 0

@dataclass
class FreeExpr:
    """free(ptr) — heap deallocation primitive."""
    ptr: Any
    allocator: Optional[Any] = None   # NEW: custom allocator expression
    line: int = 0
    col: int = 0

@dataclass
class AsmExpr:
    """asm("template" : outputs : inputs : clobbers) — inline assembly"""
    template: str
    outputs: List[Any] = field(default_factory=list)   # list of (constraint, expr)
    inputs: List[Any] = field(default_factory=list)    # list of (constraint, expr)
    clobbers: List[str] = field(default_factory=list)
    volatile: bool = True
    line: int = 0
    col: int = 0


# ── Statements ───────────────────────────────────────────────────────────────

@dataclass
class Block:
    stmts: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class LetDecl:
    name: str
    type: Optional[Any]
    value: Optional[Any]
    mutable: bool = True
    annotations: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class StaticDecl:
    name: str
    type: Optional[Any]
    value: Optional[Any]
    annotations: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class Return:
    value: Optional[Any]
    line: int = 0
    col: int = 0

@dataclass
class Break:
    value: Optional[Any] = None
    line: int = 0
    col: int = 0

@dataclass
class Continue:
    line: int = 0
    col: int = 0

@dataclass
class IfStmt:
    condition: Any
    then: Any
    elif_branches: List[Any]
    else_branch: Optional[Any]
    line: int = 0
    col: int = 0

@dataclass
class NullCheckStmt:
    expr: Any
    binding: str
    then: Any
    else_branch: Optional[Any]
    line: int = 0
    col: int = 0

@dataclass
class LoopStmt:
    body: Any
    line: int = 0
    col: int = 0

@dataclass
class WhileStmt:
    condition: Any
    body: Any
    line: int = 0
    col: int = 0

@dataclass
class DoWhileStmt:
    """do { body } while cond — execute body first, then check condition."""
    body: Any
    condition: Any
    line: int = 0
    col: int = 0

@dataclass
class ComptimeIf:
    """comptime if (expr) { ... } else { ... } — emits #if / #else / #endif."""
    condition: Any       # expression that maps to a C preprocessor condition
    then: Any            # Block
    else_branch: Optional[Any] = None   # Block or None
    line: int = 0
    col: int = 0

@dataclass
class ForStmt:
    index: Optional[str]
    binding: str
    iterable: Any
    body: Any
    line: int = 0
    col: int = 0

@dataclass
class MatchArm:
    pattern: Any
    guard: Optional[Any]
    body: Any
    line: int = 0
    col: int = 0

@dataclass
class MatchStmt:
    expr: Any
    arms: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class DeferStmt:
    body: Any
    line: int = 0
    col: int = 0

@dataclass
class ExprStmt:
    expr: Any
    line: int = 0
    col: int = 0

@dataclass
class AsmStmt:
    """Bare asm { "line1" "line2" } statement block."""
    lines: List[str]
    volatile: bool = True
    line: int = 0
    col: int = 0

@dataclass
class GotoStmt:
    """goto label_name;"""
    label: str
    line: int = 0
    col: int = 0

@dataclass
class LabelStmt:
    """label_name: — a C label, used as goto target."""
    name: str
    line: int = 0
    col: int = 0

@dataclass
class FmtStr:
    """Interpolated string: "hello {name} score {score}".
    parts is a flat list alternating str and expression nodes.
    """
    parts: List[Any]   # [str, expr, str, expr, ..., str]
    line: int = 0
    col: int = 0

@dataclass
class AlignOf:
    """align_of(T) — returns the alignment requirement of a type."""
    operand: Any       # type node or expr
    line: int = 0
    col: int = 0


# ── Top-level declarations ────────────────────────────────────────────────────

@dataclass
class UseDecl:
    path: str
    alias: Optional[str] = None
    line: int = 0
    col: int = 0

@dataclass
class AssetDecl:
    name: str
    asset_type: Optional[str]
    path: str
    line: int = 0
    col: int = 0

@dataclass
class StructField:
    name: str
    type: Any
    annotations: List[str] = field(default_factory=list)
    default_value: Optional[Any] = None
    bit_width: Optional[int] = None   # C bit-field width, e.g.  flags: u32 : 4
    line: int = 0
    col: int = 0

@dataclass
class StructDecl:
    name: str
    fields: List[Any]
    type_params: List[str] = field(default_factory=list)
    annotations: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class UnionDecl:
    """union Name { field: Type; ... } — untagged C union for type-punning."""
    name: str
    fields: List[Any]            # same StructField nodes as StructDecl
    annotations: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class EnumVariant:
    name: str
    value: Optional[Any] = None
    line: int = 0
    col: int = 0

@dataclass
class EnumDecl:
    name: str
    base_type: Optional[str]
    variants: List[Any]
    annotations: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class VariantCase:
    name: str
    fields: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class VariantDecl:
    name: str
    cases: List[Any]
    annotations: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class Param:
    name: str
    type: Any
    mutable: bool = False
    default_value: Optional[Any] = None
    line: int = 0
    col: int = 0

@dataclass
class FnDecl:
    name: str
    params: List[Any]
    ret_type: Optional[Any]
    body: Optional[Any]
    type_params: List[str] = field(default_factory=list)
    annotations: List[str] = field(default_factory=list)
    is_method: bool = False
    self_type: Optional[str] = None
    variadic: bool = False   # trailing `...` (C-style variadic; extern only)
    line: int = 0
    col: int = 0

@dataclass
class ImplBlock:
    """impl TypeName<T> { fn method(self: *Self, ...) { ... } }"""
    type_name: str
    type_params: List[str]
    methods: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class ExternBlock:
    abi: str
    decls: List[Any]
    line: int = 0
    col: int = 0

@dataclass
class ModuleDecl:
    path: str
    line: int = 0
    col: int = 0

@dataclass
class EntryBlock:
    body: Any
    line: int = 0
    col: int = 0

@dataclass
class ConstDecl:
    """const NAME: T = expr — compile-time constant, maps to #define or static const."""
    name: str
    type: Optional[Any]
    value: Any
    line: int = 0
    col: int = 0

@dataclass
class ExternConst:
    """extern const NAME: T — declares a C macro / extern constant."""
    name: str
    type: Any
    line: int = 0
    col: int = 0

@dataclass
class TraitDecl:
    """trait Name { fn method_sig(self: *Self) -> T; }"""
    name: str
    methods: List[Any]       # List[FnDecl] — signatures (bodies may be absent)
    annotations: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class ImplTraitBlock:
    """impl TypeName for TraitName { fn method(self: *TypeName) { ... } }"""
    type_name: str
    trait_name: str
    methods: List[Any]
    type_params: List[str] = field(default_factory=list)
    line: int = 0
    col: int = 0

@dataclass
class CfgBlock:
    """@cfg(FEATURE) decl — conditional compilation wrapper."""
    feature: str
    negated: bool        # True for @cfg(not(FEATURE)) → #ifndef
    decl: Any            # the wrapped top-level declaration
    line: int = 0
    col: int = 0

@dataclass
class Program:
    decls: List[Any]
    line: int = 0
    col: int = 0
