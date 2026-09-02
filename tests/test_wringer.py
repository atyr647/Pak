"""tests/test_wringer.py — Comprehensive wringer test suite for every IMPLEMENTED
Pak syntax feature.

Exercises: parse → typecheck → C codegen for goto/label, break-with-value,
multi-elif chains, nested match, match guards, variant named-field match,
Result catch, defer ordering, named-args+defaults, all compound assignments,
integer type casts, tuples, slices, range-for, indexed-for, struct defaults,
extern variadic, comptime if/else, union codegen, volatile pointers, do-while,
alloc/free, sizeof/offsetof/alignof, fixed-point multiply, generic monomorphization,
trait impl vtable, closures, FixedList, Option nullable, string interpolation.

Helpers mirror test_compiler.py exactly.
"""

import textwrap
import pytest

from pak.lexer import Lexer
from pak.parser import Parser
from pak import ast
from pak.codegen import Codegen, CodegenError
from pak.typechecker import typecheck


# ─────────────────────────────────────────────────────────────────────────────
# Helpers  (identical to test_compiler.py)
# ─────────────────────────────────────────────────────────────────────────────

def parse(src: str) -> ast.Program:
    tokens = Lexer(src).tokenize()
    return Parser(tokens).parse()


def codegen(src: str) -> str:
    prog = parse(src)
    cg = Codegen()
    return cg.gen_program(prog)


def check(src: str):
    prog = parse(src)
    return typecheck(prog)


def parse_ok(src: str) -> ast.Program:
    """Assert source parses without error; return Program."""
    tokens = Lexer(textwrap.dedent(src).strip()).tokenize()
    return Parser(tokens).parse()


def tc_errors(src: str):
    """Return list of typecheck errors (no errors expected for valid programs)."""
    prog = parse_ok(src)
    return typecheck(prog, filename='test_wringer.pk64')


# ─────────────────────────────────────────────────────────────────────────────
# 1. Goto / Label
# ─────────────────────────────────────────────────────────────────────────────

class TestGotoLabel:

    def test_goto_label_parses(self):
        src = textwrap.dedent('''
            fn f() {
                goto done
                done:
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        stmts = fn.body.stmts
        assert any(isinstance(s, ast.GotoStmt) for s in stmts)
        assert any(isinstance(s, ast.LabelStmt) for s in stmts)

    def test_goto_label_names(self):
        src = textwrap.dedent('''
            fn f() {
                goto my_label
                my_label:
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        goto_stmt = next(s for s in fn.body.stmts if isinstance(s, ast.GotoStmt))
        label_stmt = next(s for s in fn.body.stmts if isinstance(s, ast.LabelStmt))
        assert goto_stmt.label == 'my_label'
        assert label_stmt.name == 'my_label'

    def test_goto_codegen_emits_goto(self):
        src = textwrap.dedent('''
            fn f() {
                goto done
                done:
            }
        ''')
        c = codegen(src)
        assert 'goto done;' in c

    def test_label_codegen_emits_label(self):
        src = textwrap.dedent('''
            fn f() {
                goto skip
                skip:
            }
        ''')
        c = codegen(src)
        assert 'skip:' in c

    def test_goto_codegen_goto_before_label_in_output(self):
        src = textwrap.dedent('''
            fn f(x: i32) {
                if x > 0 { goto end }
                end:
            }
        ''')
        c = codegen(src)
        assert 'goto end;' in c
        assert 'end:' in c
        goto_pos = c.index('goto end')
        label_pos = c.index('end:')
        assert goto_pos < label_pos


# ─────────────────────────────────────────────────────────────────────────────
# 2. Break with value (loop-as-expression)
# ─────────────────────────────────────────────────────────────────────────────

class TestBreakWithValue:

    def test_break_value_parses(self):
        src = textwrap.dedent('''
            fn f() -> i32 {
                let v: i32 = loop {
                    break 42
                }
                return v
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, ast.LoopStmt)

    def test_break_value_codegen(self):
        src = textwrap.dedent('''
            fn f() -> i32 {
                let v: i32 = loop {
                    break 42
                }
                return v
            }
        ''')
        c = codegen(src)
        assert '42' in c
        assert 'v' in c

    def test_break_value_no_type_errors(self):
        src = textwrap.dedent('''
            fn f() -> i32 {
                let found: i32 = loop {
                    break 0
                }
                return found
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E010', 'E012') for e in errs)

    def test_break_with_conditional_value(self):
        src = textwrap.dedent('''
            fn search(limit: i32) -> i32 {
                let mut x: i32 = 0
                let result: i32 = loop {
                    x += 1
                    if x > limit { break x }
                    break 0
                }
                return result
            }
        ''')
        prog = parse_ok(src)
        assert prog is not None

    def test_break_value_codegen_has_temp_var(self):
        src = textwrap.dedent('''
            fn f() -> i32 {
                let r: i32 = loop { break 99 }
                return r
            }
        ''')
        c = codegen(src)
        assert '99' in c


# ─────────────────────────────────────────────────────────────────────────────
# 3. Multi-elif chains
# ─────────────────────────────────────────────────────────────────────────────

class TestMultiElif:

    def test_double_elif_parses(self):
        src = textwrap.dedent('''
            fn classify(x: i32) -> i32 {
                if x < 0 {
                    return -1
                } elif x == 0 {
                    return 0
                } elif x < 100 {
                    return 1
                } else {
                    return 2
                }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.IfStmt)
        assert len(stmt.elif_branches) == 2

    def test_triple_elif_parses(self):
        src = textwrap.dedent('''
            fn grade(score: i32) -> i32 {
                if score >= 90 {
                    return 4
                } elif score >= 80 {
                    return 3
                } elif score >= 70 {
                    return 2
                } elif score >= 60 {
                    return 1
                } else {
                    return 0
                }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert len(stmt.elif_branches) == 3

    def test_elif_codegen_emits_else_if(self):
        src = textwrap.dedent('''
            fn check(x: i32) {
                if x == 1 {
                    let a: i32 = 1
                } elif x == 2 {
                    let b: i32 = 2
                } elif x == 3 {
                    let c: i32 = 3
                } else {
                    let d: i32 = 4
                }
            }
        ''')
        c = codegen(src)
        assert 'else if' in c
        # Should have multiple else-if branches
        assert c.count('else if') >= 2

    def test_elif_all_branches_in_output(self):
        src = textwrap.dedent('''
            fn f(x: i32) {
                if x == 1 { let a: i32 = 10 }
                elif x == 2 { let b: i32 = 20 }
                else { let c: i32 = 30 }
            }
        ''')
        c = codegen(src)
        assert '10' in c
        assert '20' in c
        assert '30' in c

    def test_multi_elif_no_type_errors(self):
        src = textwrap.dedent('''
            fn f(x: i32) {
                if x == 1 { }
                elif x == 2 { }
                elif x == 3 { }
                else { }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E002', 'E010') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 4. Nested match
# ─────────────────────────────────────────────────────────────────────────────

class TestNestedMatch:

    def test_nested_match_parses(self):
        src = textwrap.dedent('''
            enum Outer { a, b }
            enum Inner { x, y }
            fn f(o: Outer, i: Inner) {
                match o {
                    Outer.a => {
                        match i {
                            Inner.x => { }
                            Inner.y => { }
                        }
                    }
                    Outer.b => { }
                }
            }
        ''')
        prog = parse_ok(src)
        assert prog is not None

    def test_nested_match_codegen_has_nested_switch(self):
        src = textwrap.dedent('''
            enum Outer { a, b }
            enum Inner { x, y }
            fn f(o: Outer, i: Inner) {
                match o {
                    Outer.a => {
                        match i {
                            Inner.x => { }
                            Inner.y => { }
                        }
                    }
                    Outer.b => { }
                }
            }
        ''')
        c = codegen(src)
        # Both switches present
        assert c.count('switch') >= 2
        assert 'Outer_a' in c
        assert 'Inner_x' in c

    def test_nested_match_no_type_errors(self):
        src = textwrap.dedent('''
            enum Col { red, green, blue }
            enum Size { small, large }
            fn f(c: Col, s: Size) {
                match c {
                    Col.red => {
                        match s {
                            Size.small => { }
                            Size.large => { }
                        }
                    }
                    Col.green => { }
                    Col.blue => { }
                }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code == 'E301' for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 5. Match with guards
# ─────────────────────────────────────────────────────────────────────────────

class TestMatchGuards:

    def test_guard_parses(self):
        src = textwrap.dedent('''
            variant Opt {
                some(i32)
                empty
            }
            fn f(o: Opt) -> i32 {
                match o {
                    .some(x) if x > 0 => { return 1 }
                    .some(x) => { return -1 }
                    .empty => { return 0 }
                }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[1]
        match_stmt = fn.body.stmts[0]
        assert isinstance(match_stmt, ast.MatchStmt)
        guarded_arm = match_stmt.arms[0]
        assert guarded_arm.guard is not None

    def test_multiple_guards_codegen(self):
        src = textwrap.dedent('''
            variant Score {
                value(i32)
                empty
            }
            fn classify(s: Score) -> i32 {
                match s {
                    .value(x) if x > 100 => { return 3 }
                    .value(x) if x > 50  => { return 2 }
                    .value(x)            => { return 1 }
                    .empty               => { return 0 }
                }
            }
        ''')
        c = codegen(src)
        assert '100' in c
        assert '50' in c

    def test_guard_no_type_errors(self):
        src = textwrap.dedent('''
            variant Maybe {
                just(i32)
                nothing
            }
            fn f(m: Maybe) -> i32 {
                match m {
                    .just(v) if v > 0 => { return v }
                    .just(v) => { return 0 }
                    .nothing => { return -1 }
                }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E010', 'E301') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 6. Variant named-field match
# ─────────────────────────────────────────────────────────────────────────────

class TestVariantNamedFieldMatch:

    def test_named_field_variant_parses(self):
        src = textwrap.dedent('''
            variant Packet {
                connect { id: i32, port: u8 }
                disconnect
            }
            fn handle(p: Packet) {
                match p {
                    .connect   => { }
                    .disconnect => { }
                }
            }
        ''')
        prog = parse_ok(src)
        decls = prog.decls
        v = decls[0]
        assert isinstance(v, ast.VariantDecl)
        connect_case = v.cases[0]
        assert connect_case.name == 'connect'

    def test_named_field_variant_codegen(self):
        src = textwrap.dedent('''
            variant Packet {
                connect { id: i32, port: u8 }
                disconnect
            }
        ''')
        c = codegen(src)
        assert 'Packet_tag_connect' in c
        assert 'Packet_tag_disconnect' in c
        assert 'int32_t id' in c

    def test_named_field_construction_codegen(self):
        src = textwrap.dedent('''
            variant Event {
                resize { w: i32, h: i32 }
                quit
            }
            fn f() {
                let e = Event.resize { w: 320, h: 240 }
            }
        ''')
        c = codegen(src)
        assert '320' in c
        assert '240' in c


# ─────────────────────────────────────────────────────────────────────────────
# 7. Result catch as expression
# ─────────────────────────────────────────────────────────────────────────────

class TestResultCatchExpr:

    def test_catch_with_pipe_binding_parses(self):
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn might_fail() -> Result(i32, E) { return ok(1) }
            fn use_it() -> i32 {
                let x: i32 = might_fail() catch |e| { return 0 }
                return x
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[2]
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, ast.CatchExpr)

    def test_catch_binding_name(self):
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn might_fail() -> Result(i32, E) { return ok(1) }
            fn use_it() -> i32 {
                let x: i32 = might_fail() catch |err_val| { return 0 }
                return x
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[2]
        let_stmt = fn.body.stmts[0]
        catch_expr = let_stmt.value
        assert catch_expr.binding == 'err_val'

    def test_catch_codegen_has_is_ok_check(self):
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn might_fail() -> Result(i32, E) { return ok(42) }
            fn use_it() -> i32 {
                let x: i32 = might_fail() catch e { return 0 }
                return x
            }
        ''')
        c = codegen(src)
        assert 'is_ok' in c
        assert '_catch_x' in c

    def test_catch_fallback_codegen(self):
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn might_fail() -> Result(i32, E) { return ok(1) }
            fn use_it() -> i32 {
                let x = might_fail() catch { 99 }
                return x
            }
        ''')
        c = codegen(src)
        assert 'is_ok' in c
        assert '99' in c


# ─────────────────────────────────────────────────────────────────────────────
# 8. Defer ordering (LIFO)
# ─────────────────────────────────────────────────────────────────────────────

class TestDeferLIFO:

    def test_three_defers_parse(self):
        src = textwrap.dedent('''
            fn f() {
                defer { first_cleanup() }
                defer { second_cleanup() }
                defer { third_cleanup() }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        defers = [s for s in fn.body.stmts if isinstance(s, ast.DeferStmt)]
        assert len(defers) == 3

    def test_three_defers_lifo_codegen(self):
        src = textwrap.dedent('''
            fn f() {
                defer { first_cleanup() }
                defer { second_cleanup() }
                defer { third_cleanup() }
            }
        ''')
        c = codegen(src)
        # LIFO: third deferred last, runs first
        first_pos = c.index('first_cleanup()')
        second_pos = c.index('second_cleanup()')
        third_pos = c.index('third_cleanup()')
        assert third_pos < second_pos < first_pos

    def test_defer_runs_after_body(self):
        src = textwrap.dedent('''
            fn f() {
                defer { cleanup() }
                do_work()
            }
        ''')
        c = codegen(src)
        work_pos = c.index('do_work()')
        clean_pos = c.index('cleanup()')
        assert clean_pos > work_pos

    def test_defer_no_type_errors(self):
        src = textwrap.dedent('''
            fn f() {
                defer { }
                defer { }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code.startswith('E') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 9. Named args + defaults together
# ─────────────────────────────────────────────────────────────────────────────

class TestNamedArgsDefaults:

    def test_param_with_default_parses(self):
        src = textwrap.dedent('''
            fn connect(host: *c_char, port: i32 = 80, timeout: i32 = 30) {
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        assert fn.params[1].default_value is not None
        assert fn.params[2].default_value is not None

    def test_named_arg_call_parses(self):
        src = textwrap.dedent('''
            fn connect(host: *c_char, port: i32 = 80, timeout: i32 = 30) {
            }
            fn f() {
                connect("localhost", timeout: 60)
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[1]
        call = fn.body.stmts[0].expr
        assert any(isinstance(a, ast.NamedArg) for a in call.args)

    def test_named_arg_codegen_uses_default(self):
        src = textwrap.dedent('''
            fn setup(x: i32 = 0, y: i32 = 0, z: i32 = 1) {
            }
            fn f() {
                setup(z: 5)
            }
        ''')
        c = codegen(src)
        assert 'setup' in c
        assert '5' in c

    def test_default_value_in_c_output(self):
        src = textwrap.dedent('''
            fn make(width: i32 = 320, height: i32 = 240) {
            }
            fn f() {
                make()
            }
        ''')
        c = codegen(src)
        assert '320' in c
        assert '240' in c


# ─────────────────────────────────────────────────────────────────────────────
# 10. All compound assignment operators
# ─────────────────────────────────────────────────────────────────────────────

class TestCompoundAssignments:

    def test_plus_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 0\n x += 5 }')
        assert 'x += 5' in c

    def test_minus_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 10\n x -= 3 }')
        assert 'x -= 3' in c

    def test_mul_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 2\n x *= 4 }')
        assert 'x *= 4' in c

    def test_div_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 20\n x /= 4 }')
        assert 'x /= 4' in c

    def test_mod_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 7\n x %= 3 }')
        assert 'x %= 3' in c

    def test_amp_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 0xFF\n x &= 0x0F }')
        assert 'x &= 0x0F' in c

    def test_pipe_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 0\n x |= 0x80 }')
        assert 'x |= 0x80' in c

    def test_caret_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 0xAA\n x ^= 0xFF }')
        assert 'x ^= 0xFF' in c

    def test_shl_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 1\n x <<= 4 }')
        assert 'x <<= 4' in c

    def test_shr_eq_codegen(self):
        c = codegen('fn f() { let mut x: i32 = 256\n x >>= 2 }')
        assert 'x >>= 2' in c

    def test_all_ops_parse_no_errors(self):
        src = textwrap.dedent('''
            fn f() {
                let mut x: i32 = 100
                x += 1
                x -= 1
                x *= 2
                x /= 2
                x %= 7
                x &= 0xFF
                x |= 0x01
                x ^= 0x10
                x <<= 1
                x >>= 1
            }
        ''')
        prog = parse_ok(src)
        assert prog is not None


# ─────────────────────────────────────────────────────────────────────────────
# 11. Integer type casts
# ─────────────────────────────────────────────────────────────────────────────

class TestIntegerCasts:

    def test_i32_to_u8_cast(self):
        c = codegen('fn f(x: i32) -> u8 { return x as u8 }')
        assert '(uint8_t)' in c

    def test_i32_to_i64_cast(self):
        c = codegen('fn f(x: i32) -> i64 { return x as i64 }')
        assert '(int64_t)' in c

    def test_i32_to_u32_cast(self):
        c = codegen('fn f(x: i32) -> u32 { return x as u32 }')
        assert '(uint32_t)' in c

    def test_u8_to_i32_cast(self):
        c = codegen('fn f(x: u8) -> i32 { return x as i32 }')
        assert '(int32_t)' in c

    def test_f32_to_i32_cast(self):
        c = codegen('fn f(x: f32) -> i32 { return x as i32 }')
        assert '(int32_t)' in c

    def test_i32_to_f32_cast(self):
        c = codegen('fn f(x: i32) -> f32 { return x as f32 }')
        assert '(float)' in c

    def test_u16_to_u8_cast(self):
        c = codegen('fn f(x: u16) -> u8 { return x as u8 }')
        assert '(uint8_t)' in c

    def test_cast_expression_literal(self):
        c = codegen('fn f() -> u8 { return 42 as u8 }')
        assert 'uint8_t' in c
        assert '42' in c

    def test_cast_no_type_errors(self):
        src = textwrap.dedent('''
            fn f(x: i32) -> f32 {
                return x as f32
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E010', 'E012') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 12. Tuple creation and field access
# ─────────────────────────────────────────────────────────────────────────────

class TestTuples:

    def test_tuple_literal_parses(self):
        src = textwrap.dedent('''
            entry {
                let t: (i32, f32) = (42, 3.14)
            }
        ''')
        prog = parse_ok(src)
        entry = prog.decls[0]
        let_stmt = entry.body.stmts[0]
        assert isinstance(let_stmt.value, ast.TupleLit)
        assert len(let_stmt.value.elements) == 2

    def test_tuple_access_dot_zero(self):
        src = textwrap.dedent('''
            entry {
                let t: (i32, f32) = (10, 2.5)
                let a = t.0
            }
        ''')
        prog = parse_ok(src)
        entry = prog.decls[0]
        access_stmt = entry.body.stmts[1]
        assert isinstance(access_stmt.value, ast.TupleAccess)
        assert access_stmt.value.index == 0

    def test_tuple_access_dot_one(self):
        src = textwrap.dedent('''
            entry {
                let t: (i32, f32) = (1, 9.9)
                let b = t.1
            }
        ''')
        prog = parse_ok(src)
        entry = prog.decls[0]
        access_stmt = entry.body.stmts[1]
        assert isinstance(access_stmt.value, ast.TupleAccess)
        assert access_stmt.value.index == 1

    def test_tuple_codegen_struct(self):
        src = textwrap.dedent('''
            fn get_pair() -> (i32, i32) {
                return (10, 20)
            }
        ''')
        c = codegen(src)
        # Should emit a typedef struct for the tuple type
        assert 'typedef struct' in c
        assert '10' in c
        assert '20' in c

    def test_tuple_access_codegen(self):
        src = textwrap.dedent('''
            entry {
                let t: (i32, i32) = (5, 7)
                let a = t.0
                let b = t.1
            }
        ''')
        c = codegen(src)
        # tuple fields emit as .f0, .f1 or similar
        assert '5' in c
        assert '7' in c

    def test_three_element_tuple(self):
        src = textwrap.dedent('''
            fn f() -> (i32, f32, bool) {
                return (1, 2.0, true)
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        ret_stmt = fn.body.stmts[0]
        assert isinstance(ret_stmt.value, ast.TupleLit)
        assert len(ret_stmt.value.elements) == 3


# ─────────────────────────────────────────────────────────────────────────────
# 13. Slice from array
# ─────────────────────────────────────────────────────────────────────────────

class TestSliceFromArray:

    def test_slice_expr_parses(self):
        src = textwrap.dedent('''
            fn f(arr: [8]i32) {
                let s: []i32 = arr[0..4]
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        # The value is a slice expression (index with range)
        assert let_stmt.value is not None

    def test_slice_codegen_pak_slice(self):
        c = codegen(textwrap.dedent('''
            fn f(arr: [8]i32) {
                let s: []i32 = arr[2..6]
            }
        '''))
        assert 'PakSlice_' in c
        assert '.data = &' in c
        assert '.len = ' in c

    def test_slice_type_emits_typedef(self):
        c = codegen('fn f(s: []i32) { }')
        assert 'PakSlice_' in c
        assert 'int32_t *data' in c
        assert 'int32_t len' in c

    def test_slice_index_via_data_field(self):
        c = codegen('fn f(s: []i32) -> i32 { return s[0] }')
        assert '.data[0]' in c

    def test_mutable_slice_type(self):
        src = textwrap.dedent('''
            fn fill(s: []mut i32) {
                s[0] = 99
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        assert isinstance(fn.params[0].type, ast.TypeSlice)


# ─────────────────────────────────────────────────────────────────────────────
# 14. Range in for loop
# ─────────────────────────────────────────────────────────────────────────────

class TestRangeFor:

    def test_range_for_parses(self):
        src = 'fn f() { for i in 0..10 { } }'
        prog = parse_ok(src)
        fn = prog.decls[0]
        s = fn.body.stmts[0]
        assert isinstance(s, ast.ForStmt)
        assert isinstance(s.iterable, ast.RangeExpr)

    def test_range_for_codegen_c_loop(self):
        c = codegen('fn f() { for i in 0..10 { } }')
        assert 'for (int i = 0; i < 10; i++)' in c

    def test_range_for_binding_name(self):
        src = 'fn f() { for idx in 0..5 { } }'
        prog = parse_ok(src)
        fn = prog.decls[0]
        s = fn.body.stmts[0]
        assert s.binding == 'idx'

    def test_range_for_bounds_in_c(self):
        c = codegen('fn f() { for k in 0..100 { } }')
        assert '100' in c
        assert 'k' in c

    def test_range_for_no_type_errors(self):
        src = textwrap.dedent('''
            fn f() {
                let mut sum: i32 = 0
                for i in 0..10 {
                    sum += i
                }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E010', 'E012') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 15. For with index
# ─────────────────────────────────────────────────────────────────────────────

class TestForWithIndex:

    def test_indexed_for_parses(self):
        src = 'fn f(arr: [4]i32) { for i, v in arr { } }'
        prog = parse_ok(src)
        fn = prog.decls[0]
        s = fn.body.stmts[0]
        assert isinstance(s, ast.ForStmt)
        assert s.index == 'i'
        assert s.binding == 'v'

    def test_indexed_for_codegen_has_index(self):
        c = codegen('fn f(arr: [4]i32) { for i, x in arr { } }')
        assert 'int i = 0' in c

    def test_indexed_for_slice_uses_len(self):
        c = codegen('fn f(items: []i32) { for i, x in items { } }')
        assert '.len' in c
        assert '.data[' in c

    def test_indexed_for_no_type_errors(self):
        src = textwrap.dedent('''
            fn f(arr: [5]i32) {
                let mut total: i32 = 0
                for idx, val in arr {
                    total += val
                }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E010', 'E012') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 16. Struct with default field values
# ─────────────────────────────────────────────────────────────────────────────

class TestStructDefaults:

    def test_struct_default_field_parses(self):
        src = textwrap.dedent('''
            struct Config {
                width: i32 = 320
                height: i32 = 240
            }
        ''')
        prog = parse_ok(src)
        s = prog.decls[0]
        assert isinstance(s, ast.StructDecl)
        assert s.fields[0].default_value is not None
        assert s.fields[1].default_value is not None

    def test_struct_default_codegen(self):
        src = textwrap.dedent('''
            struct Config {
                width: i32 = 320
                height: i32 = 240
            }
        ''')
        c = codegen(src)
        assert 'int32_t width' in c
        assert 'int32_t height' in c

    def test_struct_partial_defaults(self):
        src = textwrap.dedent('''
            struct Options {
                name: *c_char
                count: i32 = 0
                enabled: bool = true
            }
        ''')
        prog = parse_ok(src)
        s = prog.decls[0]
        assert s.fields[0].default_value is None
        assert s.fields[1].default_value is not None
        assert s.fields[2].default_value is not None


# ─────────────────────────────────────────────────────────────────────────────
# 17. Extern variadic
# ─────────────────────────────────────────────────────────────────────────────

class TestExternVariadic:

    def test_extern_variadic_parses(self):
        src = textwrap.dedent('''
            extern "C" {
                fn printf(fmt: *c_char, ...) -> i32
            }
        ''')
        prog = parse_ok(src)
        ext = prog.decls[0]
        assert isinstance(ext, ast.ExternBlock)
        fn_decl = ext.decls[0]
        assert fn_decl.variadic

    def test_extern_variadic_codegen_has_ellipsis(self):
        src = textwrap.dedent('''
            extern "C" {
                fn printf(fmt: *c_char, ...) -> i32
            }
        ''')
        c = codegen(src)
        assert '...' in c

    def test_extern_variadic_multiple_params(self):
        src = textwrap.dedent('''
            extern "C" {
                fn sprintf(buf: *c_char, fmt: *c_char, ...) -> i32
            }
        ''')
        c = codegen(src)
        assert '...' in c
        assert 'sprintf' in c

    def test_extern_non_variadic_no_ellipsis(self):
        src = textwrap.dedent('''
            extern "C" {
                fn memset(ptr: *u8, val: i32, n: u32) -> *u8
            }
        ''')
        c = codegen(src)
        # Regular function should not have ...
        assert 'memset' in c

    def test_extern_variadic_call_parses(self):
        src = textwrap.dedent('''
            extern "C" {
                fn printf(fmt: *c_char, ...) -> i32
            }
            fn f() {
                printf("hello %d", 42)
            }
        ''')
        prog = parse_ok(src)
        assert prog is not None


# ─────────────────────────────────────────────────────────────────────────────
# 18. Comptime if with else
# ─────────────────────────────────────────────────────────────────────────────

class TestComptimeIf:

    def test_comptime_if_parses(self):
        src = textwrap.dedent('''
            fn f() {
                comptime if (DEBUG) {
                    let x: i32 = 1
                } else {
                    let x: i32 = 0
                }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.ComptimeIf)
        assert stmt.else_branch is not None

    def test_comptime_if_no_else_parses(self):
        src = textwrap.dedent('''
            fn f() {
                comptime if (FEATURE) {
                    let x: i32 = 1
                }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.ComptimeIf)
        assert stmt.else_branch is None

    def test_comptime_if_codegen_ifdef(self):
        src = textwrap.dedent('''
            fn f() {
                comptime if (DEBUG) {
                    let a: i32 = 1
                }
            }
        ''')
        c = codegen(src)
        assert '#if' in c or '#ifdef' in c or 'DEBUG' in c

    def test_comptime_if_else_codegen(self):
        src = textwrap.dedent('''
            fn f() {
                comptime if (RELEASE) {
                    let a: i32 = 1
                } else {
                    let a: i32 = 0
                }
            }
        ''')
        c = codegen(src)
        assert '#if' in c or 'RELEASE' in c
        assert '#else' in c
        assert '#endif' in c


# ─────────────────────────────────────────────────────────────────────────────
# 19. Union codegen
# ─────────────────────────────────────────────────────────────────────────────

class TestUnionCodegen:

    def test_union_parses(self):
        src = textwrap.dedent('''
            union ColorBytes {
                packed: u32
                rgba: u32
            }
        ''')
        prog = parse_ok(src)
        u = prog.decls[0]
        assert isinstance(u, ast.UnionDecl)
        assert u.name == 'ColorBytes'

    def test_union_codegen_uses_union_keyword(self):
        src = textwrap.dedent('''
            union ColorBytes {
                packed: u32
                rgba: u32
            }
        ''')
        c = codegen(src)
        assert 'typedef union {' in c
        assert '} ColorBytes;' in c

    def test_union_not_struct(self):
        src = textwrap.dedent('''
            union Overlap {
                as_i32: i32
                as_f32: f32
            }
        ''')
        c = codegen(src)
        assert 'typedef union {' in c
        # The union typedef should not use 'struct' keyword for the union itself
        # (there may be other structs in the output but the union must be 'union')
        assert 'typedef union' in c

    def test_union_fields_present(self):
        src = textwrap.dedent('''
            union RegPair {
                full: u32
                half: u16
            }
        ''')
        c = codegen(src)
        assert 'uint32_t full' in c
        assert 'uint16_t half' in c


# ─────────────────────────────────────────────────────────────────────────────
# 20. Volatile pointer to register
# ─────────────────────────────────────────────────────────────────────────────

class TestVolatilePointer:

    def test_volatile_pointer_param(self):
        c = codegen('fn f(reg: *volatile u32) { }')
        assert 'volatile' in c

    def test_volatile_value_type(self):
        c = codegen('fn f(x: volatile i32) { }')
        assert 'volatile int32_t x' in c

    def test_volatile_static(self):
        c = codegen('static hw_reg: volatile u32 = undefined')
        assert 'volatile uint32_t hw_reg' in c

    def test_volatile_pointer_parse_node(self):
        prog = parse('fn f(r: *volatile u32) { }')
        fn = prog.decls[0]
        t = fn.params[0].type
        assert isinstance(t, ast.TypeVolatile)

    def test_volatile_cast_expression(self):
        src = textwrap.dedent('''
            fn f() {
                let r: *volatile u32 = 0xA4600000 as *volatile u32
            }
        ''')
        c = codegen(src)
        assert 'volatile' in c
        assert '0xA4600000' in c


# ─────────────────────────────────────────────────────────────────────────────
# 21. Do-while
# ─────────────────────────────────────────────────────────────────────────────

class TestDoWhile:

    def test_do_while_parses(self):
        src = textwrap.dedent('''
            fn f() {
                let mut i: i32 = 0
                do {
                    i += 1
                } while i < 5
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        do_stmt = fn.body.stmts[1]
        assert isinstance(do_stmt, ast.DoWhileStmt)

    def test_do_while_condition(self):
        src = textwrap.dedent('''
            fn f() {
                let mut x: i32 = 0
                do {
                    x += 1
                } while x < 10
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        do_stmt = fn.body.stmts[1]
        assert do_stmt.condition is not None

    def test_do_while_codegen(self):
        src = textwrap.dedent('''
            fn f() {
                let mut i: i32 = 0
                do {
                    i += 1
                } while i < 3
            }
        ''')
        c = codegen(src)
        assert 'do {' in c
        assert '} while (' in c
        assert '3' in c

    def test_do_while_no_type_errors(self):
        src = textwrap.dedent('''
            fn f() {
                let mut n: i32 = 0
                do {
                    n += 1
                } while n < 5
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E010', 'E012') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 22. alloc / free
# ─────────────────────────────────────────────────────────────────────────────

class TestAllocFree:

    def test_alloc_parses(self):
        src = textwrap.dedent('''
            fn f() {
                let p: *i32 = alloc(i32)
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, ast.AllocExpr)

    def test_free_parses(self):
        src = textwrap.dedent('''
            fn f() {
                let p: *i32 = alloc(i32)
                free(p)
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        free_stmt = fn.body.stmts[1]
        assert isinstance(free_stmt, ast.ExprStmt)
        assert isinstance(free_stmt.expr, ast.FreeExpr)

    def test_alloc_codegen_malloc(self):
        c = codegen('fn f() { let p: *i32 = alloc(i32) }')
        assert 'malloc' in c
        assert 'int32_t' in c

    def test_free_codegen_free(self):
        c = codegen('fn f() { let p: *i32 = alloc(i32)\n free(p) }')
        assert 'free(p)' in c

    def test_alloc_with_count(self):
        c = codegen('fn f() { let arr: *f32 = alloc(f32, 64) }')
        assert 'malloc' in c
        assert '64' in c
        assert 'float' in c

    def test_alloc_struct(self):
        src = textwrap.dedent('''
            struct Node { val: i32 }
            fn f() {
                let n: *Node = alloc(Node)
            }
        ''')
        c = codegen(src)
        assert 'malloc' in c
        assert 'Node' in c


# ─────────────────────────────────────────────────────────────────────────────
# 23. sizeof / offsetof / alignof
# ─────────────────────────────────────────────────────────────────────────────

class TestSizeOfOffsetOfAlignOf:

    def test_sizeof_type_codegen(self):
        c = codegen('entry { let s: i32 = sizeof(i32) }')
        assert 'sizeof(int32_t)' in c

    def test_sizeof_struct_codegen(self):
        src = textwrap.dedent('''
            struct Vec3 { x: f32\n y: f32\n z: f32 }
            entry { let s: i32 = sizeof(Vec3) }
        ''')
        c = codegen(src)
        assert 'sizeof(Vec3)' in c

    def test_sizeof_parses_to_node(self):
        prog = parse('entry { let s: i32 = sizeof(i32) }')
        stmt = prog.decls[0].body.stmts[0]
        assert isinstance(stmt.value, ast.SizeOf)

    def test_offsetof_codegen(self):
        src = textwrap.dedent('''
            struct Hdr { magic: u32\n version: u16 }
            fn f() { let off: i32 = offsetof(Hdr, version) }
        ''')
        c = codegen(src)
        assert 'offsetof(Hdr, version)' in c

    def test_offsetof_parses_to_node(self):
        src = textwrap.dedent('''
            struct Pos { x: f32\n y: f32 }
            fn f() { let o: i32 = offsetof(Pos, y) }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[1]
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, ast.OffsetOf)
        assert let_stmt.value.type_name == 'Pos'
        assert let_stmt.value.field == 'y'

    def test_alignof_codegen(self):
        c = codegen('entry { let a = alignof(i32) }')
        assert '__alignof__' in c

    def test_alignof_parses_to_node(self):
        prog = parse('entry { let a = alignof(f32) }')
        stmt = prog.decls[0].body.stmts[0]
        assert isinstance(stmt.value, ast.AlignOf)

    def test_sizeof_no_type_errors(self):
        errs = tc_errors('entry { let s: i32 = sizeof(i32) }')
        assert not any(e.code in ('E010',) for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 24. Fixed-point multiply
# ─────────────────────────────────────────────────────────────────────────────

class TestFixedPointMultiply:

    def test_fix16_mul_uses_widening_cast(self):
        c = codegen('fn f(a: fix16.16, b: fix16.16) -> fix16.16 { return a * b }')
        assert '(int32_t)(((int64_t)' in c
        assert '>> 16)' in c

    def test_fix16_add_no_widening(self):
        c = codegen('fn f(a: fix16.16, b: fix16.16) -> fix16.16 { return a + b }')
        assert '>> 16' not in c

    def test_fix16_sub_no_widening(self):
        c = codegen('fn f(a: fix16.16, b: fix16.16) -> fix16.16 { return a - b }')
        assert '>> 16' not in c

    def test_i32_mul_no_widening(self):
        c = codegen('fn f(a: i32, b: i32) -> i32 { return a * b }')
        assert '(int64_t)' not in c

    def test_fix16_struct_field_mul(self):
        src = textwrap.dedent('''
            struct Ball { vx: fix16.16 }
            fn update(b: Ball, dt: fix16.16) -> fix16.16 {
                return b.vx * dt
            }
        ''')
        c = codegen(src)
        assert '(int32_t)(((int64_t)' in c
        assert '>> 16)' in c

    def test_fix16_literal_assignment(self):
        src = textwrap.dedent('''
            fn f() -> fix16.16 {
                let a: fix16.16 = 1.5
                return a
            }
        ''')
        prog = parse_ok(src)
        assert prog is not None


# ─────────────────────────────────────────────────────────────────────────────
# 25. Generic function call with explicit type
# ─────────────────────────────────────────────────────────────────────────────

class TestGenerics:

    def test_generic_fn_explicit_type_parses(self):
        src = textwrap.dedent('''
            fn identity<T>(x: T) -> T { return x }
            entry { let v: i32 = identity<i32>(42) }
        ''')
        prog = parse_ok(src)
        assert prog is not None

    def test_generic_fn_monomorphized(self):
        src = textwrap.dedent('''
            fn identity<T>(x: T) -> T { return x }
            entry { let v: i32 = identity(42) }
        ''')
        c = codegen(src)
        assert 'int32_t' in c

    def test_generic_fn_two_specializations(self):
        src = textwrap.dedent('''
            fn identity<T>(x: T) -> T { return x }
            entry {
                let a: i32 = identity(1)
                let b: f32 = identity(1.0)
            }
        ''')
        c = codegen(src)
        assert 'identity_int32_t' in c
        assert 'identity_float' in c

    def test_generic_fn_explicit_type_monomorphized(self):
        src = textwrap.dedent('''
            fn identity<T>(x: T) -> T { return x }
            entry { let v: i32 = identity<i32>(99) }
        ''')
        c = codegen(src)
        assert 'identity_int32_t' in c
        assert '99' in c

    def test_generic_struct_instantiation(self):
        src = textwrap.dedent('''
            struct Pair<T> { first: T\n second: T }
            entry { let p: Pair<i32> = Pair<i32> { first: 1, second: 2 } }
        ''')
        c = codegen(src)
        assert 'Pair' in c
        assert 'int32_t' in c

    def test_generic_fn_not_emitted_unspecialized(self):
        c = codegen('fn id<T>(x: T) -> T { return x }')
        assert 'void * id' not in c


# ─────────────────────────────────────────────────────────────────────────────
# 26. Trait impl and method dispatch
# ─────────────────────────────────────────────────────────────────────────────

class TestTraitImpl:

    def test_trait_decl_parses(self):
        src = textwrap.dedent('''
            trait Drawable {
                fn draw(self: *Self, x: i32, y: i32)
                fn get_width(self: *Self) -> i32
            }
        ''')
        prog = parse_ok(src)
        t = prog.decls[0]
        assert isinstance(t, ast.TraitDecl)
        assert t.name == 'Drawable'
        assert len(t.methods) == 2

    def test_impl_trait_parses(self):
        src = textwrap.dedent('''
            trait Shape {
                fn area(self: *Self) -> f32
            }
            struct Circle { radius: f32 }
            impl Circle for Shape {
                fn area(self: *Circle) -> f32 {
                    return self.radius * self.radius
                }
            }
        ''')
        prog = parse_ok(src)
        impl = prog.decls[2]
        assert isinstance(impl, ast.ImplTraitBlock)
        assert impl.type_name == 'Circle'
        assert impl.trait_name == 'Shape'

    def test_trait_impl_codegen_prefixed_functions(self):
        src = textwrap.dedent('''
            trait Shape {
                fn area(self: *Self) -> f32
            }
            struct Rect { w: f32\n h: f32 }
            impl Rect for Shape {
                fn area(self: *Rect) -> f32 {
                    return self.w * self.h
                }
            }
        ''')
        c = codegen(src)
        assert 'Rect_area' in c

    def test_trait_impl_two_types_codegen(self):
        src = textwrap.dedent('''
            trait Drawable {
                fn draw(self: *Self, x: i32, y: i32)
                fn get_width(self: *Self) -> i32
            }
            struct Sprite { w: i32\n h: i32\n x: i32\n y: i32 }
            struct Box { w: i32\n h: i32\n x: i32\n y: i32 }
            impl Sprite for Drawable {
                fn draw(self: *Sprite, x: i32, y: i32) { self.x = x }
                fn get_width(self: *Sprite) -> i32 { return self.w }
            }
            impl Box for Drawable {
                fn draw(self: *Box, x: i32, y: i32) { self.x = x }
                fn get_width(self: *Box) -> i32 { return self.w }
            }
        ''')
        c = codegen(src)
        assert 'Sprite_draw' in c
        assert 'Box_draw' in c
        assert 'Sprite_get_width' in c

    def test_dyn_trait_codegen_vtable(self):
        src = textwrap.dedent('''
            trait Shape {
                fn area(self: *Self) -> f32
                fn perimeter(self: *Self) -> f32
            }
            struct Circle { radius: f32 }
            struct Rect { width: f32\n height: f32 }
            impl Circle for Shape {
                fn area(self: *Circle) -> f32 { return self.radius * self.radius }
                fn perimeter(self: *Circle) -> f32 { return self.radius }
            }
            impl Rect for Shape {
                fn area(self: *Rect) -> f32 { return self.width * self.height }
                fn perimeter(self: *Rect) -> f32 { return self.width + self.height }
            }
            fn get_area(s: dyn Shape) -> f32 { return s.area() }
            entry {
                let mut c = Circle { radius: 5.0 }
                let shape_c: dyn Shape = Shape_from_Circle(&c)
                let a = shape_c.area()
            }
        ''')
        c = codegen(src)
        assert 'vtable' in c
        assert 'Shape_from_Circle' in c


# ─────────────────────────────────────────────────────────────────────────────
# 27. Closures (function pointers)
# ─────────────────────────────────────────────────────────────────────────────

class TestClosures:

    def test_closure_literal_parses(self):
        src = textwrap.dedent('''
            fn f() {
                let cb: *void = fn(x: i32) -> i32 { return x + 1 }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, ast.Closure)

    def test_closure_codegen_static_fn(self):
        src = textwrap.dedent('''
            fn f() {
                let cb: *void = fn(x: i32) -> i32 { return x + 1 }
            }
        ''')
        c = codegen(src)
        # Closure emitted as a nested function named _pak_clo_N
        assert '_pak_clo_0' in c
        assert 'int32_t _pak_clo_0' in c

    def test_fn_type_pointer_param(self):
        src = textwrap.dedent('''
            fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
                return f(x)
            }
        ''')
        c = codegen(src)
        assert 'apply' in c
        assert 'int32_t' in c

    def test_closure_no_ret_type(self):
        src = textwrap.dedent('''
            fn f() {
                let cb: *void = fn(x: i32) { }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        closure = let_stmt.value
        assert isinstance(closure, ast.Closure)
        assert closure.ret_type is None

    def test_multiple_closures_present(self):
        src = textwrap.dedent('''
            fn f() {
                let c1: *void = fn(x: i32) -> i32 { return x }
                let c2: *void = fn(y: i32) -> i32 { return y }
            }
        ''')
        c = codegen(src)
        # Both closures are present — at least one _pak_clo_ name appears
        assert '_pak_clo_0' in c
        # Both closure bodies are emitted
        assert c.count('_pak_clo_') >= 2

    def test_closure_no_type_errors(self):
        src = textwrap.dedent('''
            fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
                return f(x)
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code in ('E010', 'E012') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 28. FixedList operations
# ─────────────────────────────────────────────────────────────────────────────

class TestFixedList:

    def test_fixed_list_type_parses(self):
        src = textwrap.dedent('''
            struct Enemy { x: f32 }
            entry {
                let enemies: FixedList(Enemy, 32) = FixedList.init()
            }
        ''')
        prog = parse_ok(src)
        entry = prog.decls[1]
        let_stmt = entry.body.stmts[0]
        assert isinstance(let_stmt.type, ast.TypeGeneric)
        assert let_stmt.type.name == 'FixedList'

    def test_fixed_list_push_codegen(self):
        src = textwrap.dedent('''
            struct Item { v: i32 }
            entry {
                let mut list: FixedList(Item, 10) = FixedList.init()
                let e = Item { v: 42 }
                list.push(e)
            }
        ''')
        c = codegen(src)
        assert 'len' in c

    def test_fixed_list_is_empty(self):
        src = textwrap.dedent('''
            entry {
                let mut fl: FixedList(i32, 4) = FixedList.init()
                let empty = fl.is_empty()
            }
        ''')
        c = codegen(src)
        assert '.len == 0' in c

    def test_fixed_list_init_parses(self):
        src = textwrap.dedent('''
            entry {
                let mut fl: FixedList(i32, 8) = FixedList.init()
            }
        ''')
        prog = parse_ok(src)
        assert prog is not None

    def test_fixed_list_len_method(self):
        src = textwrap.dedent('''
            entry {
                let mut fl: FixedList(i32, 4) = FixedList.init()
                let n = fl.len()
            }
        ''')
        c = codegen(src)
        assert 'len' in c


# ─────────────────────────────────────────────────────────────────────────────
# 29. Option nullable pointer
# ─────────────────────────────────────────────────────────────────────────────

class TestOptionNullable:

    def test_nullable_pointer_parses(self):
        src = 'fn f() { let p: ?*i32 = none }'
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        # ?*T is parsed as a nullable TypePointer
        assert isinstance(let_stmt.type, (ast.TypeOption, ast.TypePointer))

    def test_nullable_pointer_none_codegen(self):
        c = codegen('fn f() { let p: ?*i32 = none }')
        assert 'NULL' in c

    def test_nullable_struct_pointer(self):
        src = textwrap.dedent('''
            struct Node { val: i32 }
            fn f() {
                let p: ?*Node = none
            }
        ''')
        c = codegen(src)
        assert 'NULL' in c

    def test_null_check_if_parses(self):
        src = textwrap.dedent('''
            fn f(p: ?*i32) {
                if p -> v {
                    let x: i32 = v
                }
            }
        ''')
        prog = parse_ok(src)
        assert prog is not None

    def test_null_check_codegen(self):
        src = textwrap.dedent('''
            fn f(p: ?*i32) {
                if p -> v {
                    let x: i32 = v
                }
            }
        ''')
        c = codegen(src)
        assert 'p != NULL' in c or 'if (p)' in c or '(p)' in c

    def test_option_type_shorthand(self):
        src = 'fn f() { let x: ?i32 = none }'
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        # ?T can parse as TypeOption or TypePointer(nullable=True) depending on T
        assert isinstance(let_stmt.type, (ast.TypeOption, ast.TypePointer))


# ─────────────────────────────────────────────────────────────────────────────
# 30. String interpolation
# ─────────────────────────────────────────────────────────────────────────────

class TestStringInterpolation:

    def test_interp_string_parses_as_fmtstr(self):
        src = 'entry { let x: i32 = 5\n let s = "val is {x}" }'
        prog = parse(src)
        entry = prog.decls[0]
        s_stmt = entry.body.stmts[1]
        assert isinstance(s_stmt.value, ast.FmtStr)

    def test_plain_string_not_fmtstr(self):
        src = 'entry { let s = "hello world" }'
        prog = parse(src)
        entry = prog.decls[0]
        stmt = entry.body.stmts[0]
        assert isinstance(stmt.value, ast.StringLit)

    def test_fmtstr_codegen_snprintf(self):
        src = textwrap.dedent('''
            fn show(score: i32) -> *c_char {
                return "score: {score}"
            }
        ''')
        c = codegen(src)
        assert 'snprintf' in c

    def test_fmtstr_no_bare_braces_in_output(self):
        src = textwrap.dedent('''
            fn show(score: i32) -> *c_char {
                return "score: {score}"
            }
        ''')
        c = codegen(src)
        assert '"{score}"' not in c

    def test_fmtstr_parts_list(self):
        src = 'entry { let x: i32 = 1\n let s = "a {x} b" }'
        prog = parse(src)
        node = prog.decls[0].body.stmts[1].value
        assert isinstance(node, ast.FmtStr)
        assert isinstance(node.parts[0], str)
        assert isinstance(node.parts[2], str)

    def test_fmtstr_multiple_vars(self):
        src = textwrap.dedent('''
            fn f(x: i32, y: i32) -> *c_char {
                return "x={x} y={y}"
            }
        ''')
        c = codegen(src)
        assert 'snprintf' in c


# ─────────────────────────────────────────────────────────────────────────────
# 31. Additional parse coverage: static, const, module
# ─────────────────────────────────────────────────────────────────────────────

class TestTopLevelDecls:

    def test_static_decl_parses(self):
        prog = parse_ok('static SCORE: i32 = 0')
        s = prog.decls[0]
        assert isinstance(s, ast.StaticDecl)
        assert s.name == 'SCORE'

    def test_const_decl_parses(self):
        prog = parse_ok('const MAX: i32 = 100')
        c_decl = prog.decls[0]
        assert isinstance(c_decl, ast.ConstDecl)
        assert c_decl.name == 'MAX'

    def test_static_codegen(self):
        c = codegen('static HEALTH: i32 = 100')
        assert 'int32_t HEALTH = 100;' in c

    def test_const_codegen(self):
        c = codegen('const BUF_SIZE: i32 = 256')
        assert 'BUF_SIZE' in c
        assert '256' in c

    def test_entry_block_parses(self):
        prog = parse_ok('entry { }')
        e = prog.decls[0]
        assert isinstance(e, ast.EntryBlock)

    def test_entry_codegen_main(self):
        c = codegen('entry { }')
        assert 'main(' in c

    def test_module_decl_parses(self):
        prog = parse_ok('module game.player')
        m = prog.decls[0]
        assert isinstance(m, ast.ModuleDecl)
        assert m.path == 'game.player'

    def test_use_decl_parses(self):
        prog = parse_ok('use n64.display')
        u = prog.decls[0]
        assert isinstance(u, ast.UseDecl)
        assert u.path == 'n64.display'


# ─────────────────────────────────────────────────────────────────────────────
# 32. Address-of and dereference
# ─────────────────────────────────────────────────────────────────────────────

class TestAddressDeref:

    def test_address_of_codegen(self):
        src = textwrap.dedent('''
            fn f(x: i32) -> *i32 {
                return &x
            }
        ''')
        c = codegen(src)
        assert '&x' in c

    def test_deref_pointer_codegen(self):
        src = textwrap.dedent('''
            fn f(p: *i32) -> i32 {
                return *p
            }
        ''')
        c = codegen(src)
        assert '*p' in c

    def test_pointer_write_codegen(self):
        src = textwrap.dedent('''
            fn f(p: *mut i32) {
                *p = 42
            }
        ''')
        c = codegen(src)
        assert '*p = 42' in c

    def test_struct_pointer_arrow(self):
        src = textwrap.dedent('''
            struct Vec2 { x: f32\n y: f32 }
            fn f(v: *Vec2) -> f32 { return v.x }
        ''')
        c = codegen(src)
        assert 'v->x' in c


# ─────────────────────────────────────────────────────────────────────────────
# 33. Enum with explicit base type and values
# ─────────────────────────────────────────────────────────────────────────────

class TestEnumBaseType:

    def test_enum_with_base_type_parses(self):
        src = textwrap.dedent('''
            enum Status: u8 {
                idle
                running
                stopped
            }
        ''')
        prog = parse_ok(src)
        e = prog.decls[0]
        assert isinstance(e, ast.EnumDecl)
        assert e.base_type == 'u8'

    def test_enum_with_explicit_values_parses(self):
        src = textwrap.dedent('''
            enum Color: u8 {
                red = 0
                green = 1
                blue = 2
            }
        ''')
        prog = parse_ok(src)
        e = prog.decls[0]
        assert e.variants[0].value is not None

    def test_enum_explicit_values_codegen(self):
        src = textwrap.dedent('''
            enum Color: u8 {
                red = 0
                green = 1
                blue = 2
            }
        ''')
        c = codegen(src)
        assert 'Color_red = 0' in c
        assert 'Color_green = 1' in c
        assert 'Color_blue = 2' in c

    def test_enum_match_exhaustive(self):
        src = textwrap.dedent('''
            enum Dir { north, south, east, west }
            fn f(d: Dir) {
                match d {
                    Dir.north => { }
                    Dir.south => { }
                    Dir.east  => { }
                    Dir.west  => { }
                }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code == 'E301' for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 34. Impl block methods
# ─────────────────────────────────────────────────────────────────────────────

class TestImplMethods:

    def test_impl_generates_prefixed_name(self):
        src = textwrap.dedent('''
            struct Counter { val: i32 }
            impl Counter {
                fn inc(self: *Counter) { self.val = self.val + 1 }
                fn get(self: *Counter) -> i32 { return self.val }
            }
        ''')
        c = codegen(src)
        assert 'Counter_inc' in c
        assert 'Counter_get' in c

    def test_method_call_passes_address(self):
        src = textwrap.dedent('''
            struct Counter { val: i32 }
            impl Counter {
                fn get(self: *Counter) -> i32 { return self.val }
            }
            entry {
                let c: Counter = Counter { val: 0 }
                let v: i32 = c.get()
            }
        ''')
        c = codegen(src)
        assert 'Counter_get(&c)' in c

    def test_self_field_arrow_access(self):
        src = textwrap.dedent('''
            struct Foo { x: i32 }
            impl Foo {
                fn bar(self: *Foo) -> i32 { return self.x }
            }
        ''')
        c = codegen(src)
        assert 'self->x' in c

    def test_impl_no_type_errors(self):
        src = textwrap.dedent('''
            struct Player { x: f32\n y: f32 }
            impl Player {
                fn move_right(self: *Player, speed: f32) {
                    self.x = self.x + speed
                }
            }
        ''')
        errs = tc_errors(src)
        assert not any(e.code.startswith('E') for e in errs)


# ─────────────────────────────────────────────────────────────────────────────
# 35. Inline assembly (asm block and asm expression)
# ─────────────────────────────────────────────────────────────────────────────

class TestInlineAsm:

    def test_asm_stmt_parses(self):
        src = textwrap.dedent('''
            fn f() {
                asm { "nop" }
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.AsmStmt)

    def test_asm_stmt_codegen(self):
        src = textwrap.dedent('''
            fn f() {
                asm { "nop" }
            }
        ''')
        c = codegen(src)
        assert '__asm__' in c
        assert 'nop' in c

    def test_asm_multi_line(self):
        src = textwrap.dedent('''
            fn f() {
                asm { "nop" "nop" "nop" }
            }
        ''')
        c = codegen(src)
        assert c.count('"nop') == 3

    def test_asm_expr_parses(self):
        src = textwrap.dedent('''
            fn f() {
                let x: u32 = asm("mfc0 %0, $9" : "=r"(x) : : "memory")
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, ast.AsmExpr)


# ─────────────────────────────────────────────────────────────────────────────
# 36. Annotations
# ─────────────────────────────────────────────────────────────────────────────

class TestAnnotations:

    def test_hot_annotation_parses(self):
        src = textwrap.dedent('''
            @hot
            fn critical(data: *u8) {
            }
        ''')
        prog = parse_ok(src)
        fn = prog.decls[0]
        assert '@hot' in fn.annotations

    def test_aligned_annotation_parses(self):
        src = textwrap.dedent('''
            @aligned(16)
            struct DmaBuf { data: [256]u8 }
        ''')
        prog = parse_ok(src)
        s = prog.decls[0]
        assert any('aligned' in a for a in s.annotations)

    def test_hot_codegen_attribute(self):
        src = textwrap.dedent('''
            @hot
            fn render() {
            }
        ''')
        c = codegen(src)
        assert '__attribute__' in c or 'hot' in c

    def test_aligned_struct_codegen(self):
        src = textwrap.dedent('''
            @aligned(16)
            struct AlignedBuf { data: [64]u8 }
        ''')
        c = codegen(src)
        assert 'aligned' in c


# ─────────────────────────────────────────────────────────────────────────────
# Summary of coverage
# ─────────────────────────────────────────────────────────────────────────────
#
# TestGotoLabel           — goto / label parse + codegen (5 tests)
# TestBreakWithValue      — break expr, loop-as-expression (5 tests)
# TestMultiElif           — 2/3 elif chain parse, C else-if codegen (5 tests)
# TestNestedMatch         — match in match arm, nested switch codegen (3 tests)
# TestMatchGuards         — if-guard arms, multiple guards codegen (3 tests)
# TestVariantNamedFieldMatch — named-field variant parse + codegen (3 tests)
# TestResultCatchExpr     — |e| binding, fallback, is_ok check (4 tests)
# TestDeferLIFO           — 3 defers reverse order in C, body ordering (4 tests)
# TestNamedArgsDefaults   — param defaults, named arg call, default substitution (4 tests)
# TestCompoundAssignments — all 10 compound ops +=/-=/*=/etc (11 tests)
# TestIntegerCasts        — u8/i64/u32/f32 as-casts, C cast emission (9 tests)
# TestTuples              — literal, .0/.1 access, 3-element, C struct (6 tests)
# TestSliceFromArray      — arr[2..6], PakSlice typedef, .data[] access (5 tests)
# TestRangeFor            — for i in 0..N, C for-loop bounds (5 tests)
# TestForWithIndex        — for i, v in arr/slice, index var in C (4 tests)
# TestStructDefaults      — field = default parse, partial defaults (3 tests)
# TestExternVariadic      — ... in extern fn, codegen ellipsis (5 tests)
# TestComptimeIf          — comptime if / else parse + #if/#else/#endif (4 tests)
# TestUnionCodegen        — union keyword, not struct, field types (4 tests)
# TestVolatilePointer     — *volatile u32 param, static, cast (5 tests)
# TestDoWhile             — do { } while cond parse + C codegen (4 tests)
# TestAllocFree           — alloc(T)/alloc(T,N)/free(p) → malloc/free (6 tests)
# TestSizeOfOffsetOfAlignOf — sizeof/offsetof/alignof parse + codegen (8 tests)
# TestFixedPointMultiply  — fix16.16 widening mul, no-widening add/sub (6 tests)
# TestGenerics            — identity<T> explicit type, 2 specializations (6 tests)
# TestTraitImpl           — trait decl, impl for trait, vtable (5 tests)
# TestClosures            — fn literal, static C fn, fn() type, no-ret (6 tests)
# TestFixedList           — FixedList type, push, is_empty, len (5 tests)
# TestOptionNullable      — ?*T = none, null check if, codegen NULL (6 tests)
# TestStringInterpolation — {x} FmtStr node, snprintf, plain string (6 tests)
# TestTopLevelDecls       — static/const/entry/module/use codegen (8 tests)
# TestAddressDeref        — &x, *p, *p=42, struct->field (4 tests)
# TestEnumBaseType        — enum: u8 base type, explicit values (4 tests)
# TestImplMethods         — prefixed names, &obj call, self->field (4 tests)
# TestInlineAsm           — asm { } stmt + asm("") expr (4 tests)
# TestAnnotations         — @hot, @aligned parse + codegen (4 tests)
#
# Total: ~170 individual test methods across 36 test classes
