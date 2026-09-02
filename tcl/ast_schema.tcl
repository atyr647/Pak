# tcl/ast_schema.tcl — the AST node schema.
#
# Each node kind is a struct::record whose members are its fields. This file
# was generated while the compiler had a second implementation; it is now
# hand-maintained source. Adding a node kind means adding it here, to the
# kind→field-shape table at the bottom, and to the parser.
package require struct::record

struct::record define AddrOf {expr mutable}
struct::record define AlignOf {operand}
struct::record define AllocExpr {type_node count allocator}
struct::record define ArrayLit {elements repeat}
struct::record define AsmExpr {template outputs inputs clobbers volatile}
struct::record define AsmStmt {lines volatile}
struct::record define AssetDecl {name asset_type path}
struct::record define Assign {target value op}
struct::record define BinaryOp {op left right}
struct::record define Block {stmts}
struct::record define BoolLit {value}
struct::record define Break {value}
struct::record define Call {func args type_args}
struct::record define Cast {expr type}
struct::record define CatchExpr {expr binding handler}
struct::record define CfgBlock {feature negated decl}
struct::record define Closure {params ret_type body}
struct::record define ComptimeIf {condition then else_branch}
struct::record define ConstDecl {name type value}
struct::record define Continue {}
struct::record define DeferStmt {body}
struct::record define Deref {expr}
struct::record define DoWhileStmt {body condition}
struct::record define DotAccess {obj field binding}
struct::record define EntryBlock {body}
struct::record define EnumDecl {name base_type variants annotations}
struct::record define EnumVariant {name value}
struct::record define EnumVariantAccess {name}
struct::record define ErrExpr {value}
struct::record define ExprStmt {expr}
struct::record define ExternBlock {abi decls}
struct::record define ExternConst {name type}
struct::record define FloatLit {value raw}
struct::record define FmtStr {parts}
struct::record define FnDecl {name params ret_type body type_params annotations is_method self_type variadic}
struct::record define ForStmt {index binding iterable body}
struct::record define FreeExpr {ptr allocator}
struct::record define GotoStmt {label}
struct::record define Ident {name type_args}
struct::record define IfStmt {condition then elif_branches else_branch}
struct::record define ImplBlock {type_name type_params methods}
struct::record define ImplTraitBlock {type_name trait_name methods type_params}
struct::record define IndexAccess {obj index}
struct::record define IntLit {value raw}
struct::record define LabelStmt {name}
struct::record define LetDecl {name type value mutable annotations}
struct::record define LoopStmt {body}
struct::record define MatchArm {pattern guard body}
struct::record define MatchStmt {expr arms}
struct::record define ModuleDecl {path}
struct::record define NamedArg {name value}
struct::record define NoneLit {}
struct::record define NullCheck {expr binding}
struct::record define NullCheckStmt {expr binding then else_branch}
struct::record define OffsetOf {type_name field}
struct::record define OkExpr {value}
struct::record define Param {name type mutable default_value}
struct::record define Program {decls}
struct::record define RangeExpr {start end}
struct::record define Return {value}
struct::record define SizeOf {operand}
struct::record define SliceExpr {obj start end}
struct::record define StaticDecl {name type value annotations}
struct::record define StringLit {value}
struct::record define StructDecl {name fields type_params annotations}
struct::record define StructField {name type annotations default_value bit_width}
struct::record define StructLit {type_name fields type_args}
struct::record define TraitDecl {name methods annotations}
struct::record define TupleAccess {obj index}
struct::record define TupleLit {elements}
struct::record define TypeArray {size inner}
struct::record define TypeDynTrait {name}
struct::record define TypeFn {params ret}
struct::record define TypeGeneric {name args}
struct::record define TypeName {name}
struct::record define TypeOption {inner}
struct::record define TypeParam {name}
struct::record define TypePointer {inner nullable mutable}
struct::record define TypeResult {ok err}
struct::record define TypeSlice {inner mutable}
struct::record define TypeTuple {elements}
struct::record define TypeVolatile {inner}
struct::record define UnaryOp {op operand}
struct::record define UndefinedLit {}
struct::record define UnionDecl {name fields annotations}
struct::record define UseDecl {path alias}
struct::record define VariantCase {name fields}
struct::record define VariantDecl {name cases annotations}
struct::record define VariantLit {variant_type case_name fields}
struct::record define WhileStmt {condition body}

# Per-field wrap kinds consumed by pak::N (see header).
namespace eval pak {}
set ::pak::FKIND [dict create \
    AddrOf {expr n mutable b} \
    AlignOf {operand n} \
    AllocExpr {type_node n count n allocator n} \
    ArrayLit {elements L repeat n} \
    AsmExpr {template s outputs L inputs L clobbers Ls volatile b} \
    AsmStmt {lines Ls volatile b} \
    AssetDecl {name s asset_type n path s} \
    Assign {target n value n op s} \
    BinaryOp {op s left n right n} \
    Block {stmts L} \
    BoolLit {value b} \
    Break {value n} \
    Call {func n args L type_args L} \
    Cast {expr n type n} \
    CatchExpr {expr n binding n handler n} \
    CfgBlock {feature s negated b decl n} \
    Closure {params L ret_type n body n} \
    ComptimeIf {condition n then n else_branch n} \
    ConstDecl {name s type n value n} \
    Continue {} \
    DeferStmt {body n} \
    Deref {expr n} \
    DoWhileStmt {body n condition n} \
    DotAccess {obj n field s binding n} \
    EntryBlock {body n} \
    EnumDecl {name s base_type n variants L annotations Ls} \
    EnumVariant {name s value n} \
    EnumVariantAccess {name s} \
    ErrExpr {value n} \
    ExprStmt {expr n} \
    ExternBlock {abi s decls L} \
    ExternConst {name s type n} \
    FloatLit {value f raw s} \
    FmtStr {parts L} \
    FnDecl {name s params L ret_type n body n type_params Ls annotations Ls is_method b self_type n variadic b} \
    ForStmt {index n binding s iterable n body n} \
    FreeExpr {ptr n allocator n} \
    GotoStmt {label s} \
    Ident {name s type_args L} \
    IfStmt {condition n then n elif_branches L else_branch n} \
    ImplBlock {type_name s type_params Ls methods L} \
    ImplTraitBlock {type_name s trait_name s methods L type_params Ls} \
    IndexAccess {obj n index n} \
    IntLit {value i raw s} \
    LabelStmt {name s} \
    LetDecl {name s type n value n mutable n annotations Ls} \
    LoopStmt {body n} \
    MatchArm {pattern n guard n body n} \
    MatchStmt {expr n arms L} \
    ModuleDecl {path s} \
    NamedArg {name s value n} \
    NoneLit {} \
    NullCheck {expr n binding n} \
    NullCheckStmt {expr n binding s then n else_branch n} \
    OffsetOf {type_name s field s} \
    OkExpr {value n} \
    Param {name s type n mutable b default_value n} \
    Program {decls L} \
    RangeExpr {start n end n} \
    Return {value n} \
    SizeOf {operand n} \
    SliceExpr {obj n start n end n} \
    StaticDecl {name s type n value n annotations Ls} \
    StringLit {value s} \
    StructDecl {name s fields L type_params Ls annotations Ls} \
    StructField {name s type n annotations Ls default_value n bit_width n} \
    StructLit {type_name s fields L type_args L} \
    TraitDecl {name s methods L annotations Ls} \
    TupleAccess {obj n index i} \
    TupleLit {elements L} \
    TypeArray {size n inner n} \
    TypeDynTrait {name s} \
    TypeFn {params L ret n} \
    TypeGeneric {name s args L} \
    TypeName {name s} \
    TypeOption {inner n} \
    TypeParam {name s} \
    TypePointer {inner n nullable b mutable b} \
    TypeResult {ok n err n} \
    TypeSlice {inner n mutable b} \
    TypeTuple {elements L} \
    TypeVolatile {inner n} \
    UnaryOp {op s operand n} \
    UndefinedLit {} \
    UnionDecl {name s fields L annotations Ls} \
    UseDecl {path s alias n} \
    VariantCase {name s fields L} \
    VariantDecl {name s cases L annotations Ls} \
    VariantLit {variant_type s case_name s fields L} \
    WhileStmt {condition n body n} \
]
