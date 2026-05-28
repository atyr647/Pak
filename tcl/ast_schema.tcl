# GENERATED from pak/ast.py by tcl/tools/gen_schema.py — DO NOT EDIT.
# Each AST node kind is a struct::record; members mirror the dataclass
# fields (excluding line/col). Regenerate: python3 tcl/tools/gen_schema.py
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
struct::record define StructLit {type_name fields}
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
struct::record define WhileStmt {condition body}
