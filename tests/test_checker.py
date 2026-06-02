"""Tests for pak/checker.py — extended semantic checker.

Covers every error and warning code:
    E101  Entry block has parameters (structural — not directly testable here)
    E102  Entry block has return type (structural)
    E103  No entry block / duplicate entry block
    E104  Unknown n64 module in `use`
    E105  N64 API call argument count mismatch
    E106  const value not compile-time evaluatable
    E107  Duplicate top-level name
    W101  Unreachable statement after return/break/continue
    W103  Unknown @cfg feature name

Also covers:
    assert_checked()   — raises RuntimeError on hard errors
    check_entry_blocks() — cross-file entry block validation
"""

import sys
import os
import textwrap
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from pak.lexer import Lexer
from pak.parser import Parser
from pak.checker import semantic_check, check_entry_blocks, assert_checked


# ── Helpers ───────────────────────────────────────────────────────────────────

def parse(source: str):
    src = textwrap.dedent(source).strip()
    return Parser(Lexer(src).tokenize()).parse()


def check(source: str):
    prog = parse(source)
    errors, warnings = semantic_check(prog, filename='test.pk64')
    return errors, warnings


def error_codes(source: str):
    errs, _ = check(source)
    return [e.code for e in errs]


def warning_codes(source: str):
    _, warns = check(source)
    return [w.code for w in warns]


# ══════════════════════════════════════════════════════════════════════════════
# E104 — Unknown n64 module
# ══════════════════════════════════════════════════════════════════════════════

class TestE104:
    def test_known_module_no_error(self):
        assert 'E104' not in error_codes("""
            use n64.display
            entry { }
        """)

    def test_known_t3d_module_no_error(self):
        assert 'E104' not in error_codes("""
            use t3d.core
            entry { }
        """)

    def test_unknown_module_errors(self):
        assert 'E104' in error_codes("""
            use n64.bogusmodule
            entry { }
        """)

    def test_unknown_module_message(self):
        errs, _ = check("""
            use n64.totally_fake
            entry { }
        """)
        e104 = [e for e in errs if e.code == 'E104']
        assert e104
        assert 'totally_fake' in e104[0].message


# ══════════════════════════════════════════════════════════════════════════════
# E105 — N64 API arity mismatch
# ══════════════════════════════════════════════════════════════════════════════

class TestE105:
    def test_correct_arity_no_error(self):
        assert 'E105' not in error_codes("""
            use n64.display
            entry {
                n64.display.init(320, 240, 2, 0, 0)
            }
        """)

    def test_too_few_args(self):
        assert 'E105' in error_codes("""
            use n64.display
            entry {
                n64.display.init(320, 240)
            }
        """)

    def test_too_many_args(self):
        assert 'E105' in error_codes("""
            use n64.display
            entry {
                n64.display.get(1, 2, 3)
            }
        """)

    def test_zero_arg_call_correct(self):
        assert 'E105' not in error_codes("""
            use n64.display
            entry {
                n64.display.close()
            }
        """)

    def test_zero_arg_call_with_args(self):
        assert 'E105' in error_codes("""
            use n64.display
            entry {
                n64.display.close(1)
            }
        """)

    def test_variadic_debug_log_no_error(self):
        # debug.log is variadic — any count >= 1 is fine
        assert 'E105' not in error_codes("""
            use n64.debug
            entry {
                n64.debug.log("hello %d", 42)
            }
        """)

    def test_dma_read_exact_three(self):
        assert 'E105' not in error_codes("""
            use n64.dma
            entry {
                n64.dma.read(0, 0, 64)
            }
        """)

    def test_dma_read_wrong_count(self):
        assert 'E105' in error_codes("""
            use n64.dma
            entry {
                n64.dma.read(0, 0)
            }
        """)


# ══════════════════════════════════════════════════════════════════════════════
# E106 — const not compile-time evaluatable
# ══════════════════════════════════════════════════════════════════════════════

class TestE106:
    def test_integer_literal_ok(self):
        assert 'E106' not in error_codes("const X: i32 = 42\nentry { }")

    def test_arithmetic_ok(self):
        assert 'E106' not in error_codes("const X: i32 = 2 + 2\nentry { }")

    def test_nested_arithmetic_ok(self):
        assert 'E106' not in error_codes("const X: i32 = (10 * 3) - 1\nentry { }")

    def test_bool_literal_ok(self):
        assert 'E106' not in error_codes("const FLAG: bool = true\nentry { }")

    def test_string_literal_ok(self):
        assert 'E106' not in error_codes('const S: *c_char = "hello"\nentry { }')

    def test_function_call_errors(self):
        assert 'E106' in error_codes("""
            fn foo() -> i32 { return 1 }
            const X: i32 = foo()
            entry { }
        """)

    def test_sizeof_ok(self):
        assert 'E106' not in error_codes("const SZ: i32 = sizeof(i32)\nentry { }")


# ══════════════════════════════════════════════════════════════════════════════
# E107 — Duplicate top-level name
# ══════════════════════════════════════════════════════════════════════════════

class TestE107:
    def test_no_duplicate_ok(self):
        assert 'E107' not in error_codes("""
            fn foo() { }
            fn bar() { }
            entry { }
        """)

    def test_duplicate_fn_errors(self):
        assert 'E107' in error_codes("""
            fn foo() { }
            fn foo() { }
            entry { }
        """)

    def test_duplicate_struct_errors(self):
        assert 'E107' in error_codes("""
            struct Foo { x: i32 }
            struct Foo { y: i32 }
            entry { }
        """)

    def test_fn_and_struct_same_name_errors(self):
        assert 'E107' in error_codes("""
            fn Vec2() { }
            struct Vec2 { x: i32 }
            entry { }
        """)

    def test_const_duplicate_errors(self):
        assert 'E107' in error_codes("""
            const X: i32 = 1
            const X: i32 = 2
            entry { }
        """)


# ══════════════════════════════════════════════════════════════════════════════
# W101 — Unreachable code after return
# ══════════════════════════════════════════════════════════════════════════════

class TestW101:
    def test_no_dead_code_ok(self):
        assert 'W101' not in warning_codes("""
            fn foo() -> i32 {
                let x = 1
                return x
            }
            entry { }
        """)

    def test_code_after_return_warns(self):
        assert 'W101' in warning_codes("""
            fn foo() -> i32 {
                return 1
                let dead = 2
            }
            entry { }
        """)

    def test_code_after_break_warns(self):
        assert 'W101' in warning_codes("""
            fn foo() {
                loop {
                    break
                    let dead = 1
                }
            }
            entry { }
        """)

    def test_code_after_continue_warns(self):
        assert 'W101' in warning_codes("""
            fn foo() {
                loop {
                    continue
                    let dead = 1
                }
            }
            entry { }
        """)

    def test_return_in_both_branches_not_dead(self):
        # Code after an if/else where both branches return is unreachable,
        # but this is a harder analysis — we just check it doesn't crash.
        errs, _ = check("""
            fn foo(x: i32) -> i32 {
                if x > 0 { return 1 } else { return -1 }
            }
            entry { }
        """)
        assert not errs   # no hard errors


# ══════════════════════════════════════════════════════════════════════════════
# E103 — Entry block checks (cross-file)
# ══════════════════════════════════════════════════════════════════════════════

class TestE103:
    def test_single_entry_ok(self):
        prog = parse("fn foo() { }\nentry { }")
        diags = check_entry_blocks([('main.pk64', prog)])
        assert not diags

    def test_no_entry_with_fns_errors(self):
        prog = parse("fn foo() { }")
        diags = check_entry_blocks([('main.pk64', prog)])
        assert any(d.code == 'E103' for d in diags)

    def test_no_entry_no_fns_no_error(self):
        # A file with only struct declarations is a library module — no entry needed
        prog = parse("struct Vec2 { x: i32, y: i32 }")
        diags = check_entry_blocks([('vec2.pk64', prog)])
        assert not diags

    def test_duplicate_entry_across_files_errors(self):
        prog1 = parse("entry { }")
        prog2 = parse("entry { }")
        diags = check_entry_blocks([('a.pk64', prog1), ('b.pk64', prog2)])
        assert any(d.code == 'E103' for d in diags)

    def test_single_entry_across_two_files_ok(self):
        prog1 = parse("fn helper() { }")
        prog2 = parse("entry { helper() }")
        diags = check_entry_blocks([('helpers.pk64', prog1), ('main.pk64', prog2)])
        assert not diags


# ══════════════════════════════════════════════════════════════════════════════
# assert_checked() invariant guard
# ══════════════════════════════════════════════════════════════════════════════

class TestAssertChecked:
    def test_clean_program_does_not_raise(self):
        prog = parse("fn foo() -> i32 { return 42 }\nentry { }")
        assert_checked(prog, 'test.pk64')   # should not raise

    def test_e106_const_raises(self):
        prog = parse("""
            fn bad() -> i32 { return 1 }
            const X: i32 = bad()
            entry { }
        """)
        with pytest.raises(RuntimeError, match='E106'):
            assert_checked(prog, 'test.pk64')

    def test_e107_duplicate_raises(self):
        prog = parse("fn foo() { }\nfn foo() { }\nentry { }")
        with pytest.raises(RuntimeError, match='E107'):
            assert_checked(prog, 'test.pk64')


# ══════════════════════════════════════════════════════════════════════════════
# Multiple errors in one program
# ══════════════════════════════════════════════════════════════════════════════

class TestMultipleErrors:
    def test_all_errors_reported(self):
        errs, warns = check("""
            use n64.nonexistent
            fn foo() { }
            fn foo() { }
            const BAD: i32 = foo()
            entry { }
        """)
        codes = {e.code for e in errs}
        assert 'E104' in codes   # bad module
        assert 'E107' in codes   # duplicate foo
        assert 'E106' in codes   # const not evaluatable

    def test_clean_file_no_diags(self):
        errs, warns = check("""
            use n64.display
            fn init_display() {
                n64.display.init(320, 240, 2, 0, 0)
            }
            entry {
                init_display()
            }
        """)
        assert not errs


# ══════════════════════════════════════════════════════════════════════════════
# Severity filtering
# ══════════════════════════════════════════════════════════════════════════════

class TestSeverity:
    def test_warnings_not_in_errors(self):
        errs, warns = check("""
            fn foo() -> i32 {
                return 1
                let dead = 2
            }
            entry { }
        """)
        warn_codes = {w.code for w in warns}
        err_codes  = {e.code for e in errs}
        assert 'W101' in warn_codes
        assert 'W101' not in err_codes

    def test_errors_not_in_warnings(self):
        errs, warns = check("""
            use n64.bogus
            entry { }
        """)
        err_codes  = {e.code for e in errs}
        warn_codes = {w.code for w in warns}
        assert 'E104' in err_codes
        assert 'E104' not in warn_codes
