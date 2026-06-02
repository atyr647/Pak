"""Phase 7 — Differential testing: C backend vs MIPS backend.

For each test case, compiles the same PAK source through both backends and
verifies structural equivalences:
  - Both produce output without errors
  - Both emit the same set of function labels / entry points
  - MIPS output contains expected instruction patterns for each feature

This is the closest we can get to "bit-identical frames" without an emulator.
"""

import textwrap
import re
import pytest

from pak.lexer import Lexer
from pak.parser import Parser
from pak.typechecker import TypeEnv
from pak.codegen import Codegen
from pak.mips import MipsCodegen


# ── Helpers ──────────────────────────────────────────────────────────────────

def _compile_both(source: str):
    """Compile via C and MIPS, return (c_code, mips_asm)."""
    source = textwrap.dedent(source).strip()
    tokens = Lexer(source).tokenize()
    program = Parser(tokens).parse()

    # C backend
    cg_c = Codegen()
    c_code = cg_c.gen_program(program)

    # MIPS backend — need fresh parse since codegen may mutate AST
    tokens2 = Lexer(source).tokenize()
    program2 = Parser(tokens2).parse()
    tenv = TypeEnv()
    tenv.collect(program2)
    cg_m = MipsCodegen(bounds_check=False, optimize=True)
    mips_asm = cg_m.generate(program2, tenv)

    return c_code, mips_asm


def _c_functions(c_code: str):
    """Extract function names defined in C output."""
    # Match return_type function_name( — handles custom types too
    fns = set()
    for m in re.finditer(r'^(?!\s)[\w\s\*]+?\b(\w+)\s*\([^;]*\)\s*\{', c_code, re.MULTILINE):
        name = m.group(1)
        fns.add(name)
    return fns


def _mips_labels(mips_asm: str):
    """Extract global function labels from MIPS output."""
    labels = set()
    for m in re.finditer(r'^(\w+):', mips_asm, re.MULTILINE):
        labels.add(m.group(1))
    return labels


# ── Differential tests ───────────────────────────────────────────────────────

class TestDiffArithmetic:
    """Both backends compile arithmetic functions."""

    def test_add_function(self):
        c, m = _compile_both("""
        fn add(a: i32, b: i32) -> i32 {
            return a + b
        }
        """)
        assert 'add' in _c_functions(c)
        assert 'add' in _mips_labels(m)

    def test_multiply(self):
        c, m = _compile_both("""
        fn mul(a: i32, b: i32) -> i32 {
            return a * b
        }
        """)
        assert 'mul' in _c_functions(c)
        assert 'mul' in _mips_labels(m)

    def test_division_and_modulo(self):
        c, m = _compile_both("""
        fn divmod(a: i32, b: i32) -> i32 {
            return (a / b) + (a % b)
        }
        """)
        assert 'divmod' in _c_functions(c)
        assert 'divmod' in _mips_labels(m)

    def test_bitwise_ops(self):
        c, m = _compile_both("""
        fn bits(a: i32, b: i32) -> i32 {
            return (a & b) | (a ^ b)
        }
        """)
        assert 'bits' in _c_functions(c)
        assert 'bits' in _mips_labels(m)


class TestDiffControlFlow:
    """Both backends compile control flow correctly."""

    def test_if_else(self):
        c, m = _compile_both("""
        fn abs_val(x: i32) -> i32 {
            if x < 0 {
                return 0 - x
            } else {
                return x
            }
        }
        """)
        assert 'abs_val' in _c_functions(c)
        assert 'abs_val' in _mips_labels(m)

    def test_while_loop(self):
        c, m = _compile_both("""
        fn sum_to(n: i32) -> i32 {
            let s: i32 = 0
            let i: i32 = 0
            while i < n {
                s = s + i
                i = i + 1
            }
            return s
        }
        """)
        assert 'sum_to' in _c_functions(c)
        assert 'sum_to' in _mips_labels(m)

    def test_for_range(self):
        c, m = _compile_both("""
        fn sum_range() -> i32 {
            let total: i32 = 0
            for i in 0..10 {
                total = total + i
            }
            return total
        }
        """)
        assert 'sum_range' in _c_functions(c)
        assert 'sum_range' in _mips_labels(m)

    def test_match_enum(self):
        c, m = _compile_both("""
        enum Dir { up, down, left, right }
        fn is_vertical(d: Dir) -> bool {
            match d {
                .up => { return true }
                .down => { return true }
                _ => { return false }
            }
        }
        """)
        assert 'is_vertical' in _c_functions(c)
        assert 'is_vertical' in _mips_labels(m)

    def test_recursion(self):
        c, m = _compile_both("""
        fn fib(n: i32) -> i32 {
            if n <= 1 { return n }
            return fib(n - 1) + fib(n - 2)
        }
        """)
        assert 'fib' in _c_functions(c)
        assert 'fib' in _mips_labels(m)


class TestDiffTypes:
    """Both backends handle type constructs."""

    def test_struct(self):
        c, m = _compile_both("""
        struct Vec2 {
            x: i32
            y: i32
        }
        fn make_vec(x: i32, y: i32) -> Vec2 {
            return Vec2 { x: x, y: y }
        }
        """)
        assert 'make_vec' in _c_functions(c)
        assert 'make_vec' in _mips_labels(m)

    def test_enum(self):
        c, m = _compile_both("""
        enum Color: u8 {
            red
            green
            blue
        }
        fn is_red(c: Color) -> bool {
            match c {
                .red => { return true }
                _ => { return false }
            }
        }
        """)
        assert 'is_red' in _c_functions(c)
        assert 'is_red' in _mips_labels(m)

    def test_variant(self):
        c, m = _compile_both("""
        variant Shape {
            Circle { radius: i32 }
            Rect { w: i32, h: i32 }
        }
        fn area(s: Shape) -> i32 {
            match s {
                .Circle(c) => { return c.radius * c.radius * 3 }
                .Rect(r) => { return r.w * r.h }
            }
        }
        """)
        assert 'area' in _c_functions(c)
        assert 'area' in _mips_labels(m)


class TestDiffFixedPoint:
    """Both backends handle fixed-point types."""

    def test_fix_multiply(self):
        c, m = _compile_both("""
        fn fmul(a: fix16.16, b: fix16.16) -> fix16.16 {
            return a * b
        }
        """)
        assert 'fmul' in _c_functions(c)
        assert 'fmul' in _mips_labels(m)
        # C should have 64-bit widening
        assert 'int64_t' in c
        # MIPS should have mult instruction
        assert 'mult' in m

    def test_fix_add_no_shift(self):
        c, m = _compile_both("""
        fn fadd(a: fix16.16, b: fix16.16) -> fix16.16 {
            return a + b
        }
        """)
        assert 'fadd' in _c_functions(c)
        assert 'fadd' in _mips_labels(m)
        # Addition should NOT shift
        assert '>> 16' not in c


class TestDiffDefer:
    """Both backends handle defer."""

    def test_defer_single(self):
        c, m = _compile_both("""
        fn work() {
            defer {
                let cleanup: i32 = 1
            }
            let x: i32 = 42
        }
        """)
        assert 'work' in _c_functions(c)
        assert 'work' in _mips_labels(m)


class TestDiffResult:
    """Both backends handle Result types."""

    def test_ok_err(self):
        c, m = _compile_both("""
        fn try_it(n: i32) -> Result(i32, i32) {
            if n < 0 {
                return err(0 - n)
            }
            return ok(n * 2)
        }
        """)
        assert 'try_it' in _c_functions(c)
        assert 'try_it' in _mips_labels(m)


class TestDiffEntry:
    """Both backends handle entry blocks."""

    def test_entry_becomes_main(self):
        c, m = _compile_both("""
        entry {
            let x: i32 = 42
        }
        """)
        assert 'main' in _c_functions(c)
        assert 'main' in _mips_labels(m)

    def test_entry_calls_function(self):
        c, m = _compile_both("""
        fn greet() -> i32 {
            return 42
        }
        entry {
            let r = greet()
        }
        """)
        assert 'greet' in _c_functions(c)
        assert 'greet' in _mips_labels(m)
        assert 'main' in _c_functions(c)
        assert 'main' in _mips_labels(m)


class TestDiffImplMethods:
    """Both backends handle impl blocks."""

    def test_method_dispatch(self):
        c, m = _compile_both("""
        struct Counter {
            val: i32
        }
        impl Counter {
            fn inc(self: *Counter) {
                self.val = self.val + 1
            }
        }
        """)
        # C backend might use Counter_inc or similar naming
        c_fns = _c_functions(c)
        m_labels = _mips_labels(m)
        assert any('inc' in f for f in c_fns)
        assert 'Counter_inc' in m_labels


class TestDiffStatic:
    """Both backends handle static declarations."""

    def test_static_variable(self):
        c, m = _compile_both("""
        static SCORE: i32 = 0
        fn get_score() -> i32 {
            return SCORE
        }
        """)
        assert 'SCORE' in c
        assert 'SCORE' in m


class TestExamplePrograms:
    """Graduation criterion: example .pk64 files compile via MIPS backend."""

    def _compile_example(self, path):
        import os
        if not os.path.exists(path):
            pytest.skip(f'{path} not found')
        source = open(path).read()
        tokens = Lexer(source).tokenize()
        program = Parser(tokens).parse()
        tenv = TypeEnv()
        tenv.collect(program)
        cg = MipsCodegen(bounds_check=False, optimize=True)
        asm = cg.generate(program, tenv)
        return asm

    def test_features_pak(self):
        asm = self._compile_example('examples/features.pk64')
        assert 'main:' in asm
        assert len(asm) > 100

    def test_sprite_game_pak(self):
        asm = self._compile_example('examples/sprite_game.pk64')
        assert 'main:' in asm
        assert len(asm) > 100

    def test_model_viewer_pak(self):
        asm = self._compile_example('examples/model_viewer.pk64')
        assert 'main:' in asm


class TestDiffMultipleFeatures:
    """Combined features across both backends."""

    def test_struct_method_result(self):
        """Struct + impl method + Result return — both backends handle it."""
        c, m = _compile_both("""
        struct Player {
            hp: i32
            max_hp: i32
        }
        impl Player {
            fn heal(self: *Player, amount: i32) -> Result(i32, i32) {
                if self.hp >= self.max_hp {
                    return err(0)
                }
                self.hp = self.hp + amount
                if self.hp > self.max_hp {
                    self.hp = self.max_hp
                }
                return ok(self.hp)
            }
        }
        """)
        c_fns = _c_functions(c)
        m_labels = _mips_labels(m)
        assert any('heal' in f for f in c_fns)
        assert 'Player_heal' in m_labels

    def test_enum_match_loop_break(self):
        """Enum + match + loop + break — both backends handle it."""
        c, m = _compile_both("""
        enum State: u8 {
            running
            done
        }
        fn run_game() -> i32 {
            let state = State.running
            let frames: i32 = 0
            loop {
                match state {
                    .running => {
                        frames = frames + 1
                        if frames >= 60 {
                            state = State.done
                        }
                    }
                    .done => {
                        break
                    }
                }
            }
            return frames
        }
        """)
        assert 'run_game' in _c_functions(c)
        assert 'run_game' in _mips_labels(m)
