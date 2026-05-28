"""
tests/test_not_supported.py — Programmatic enforcement of NOT_SUPPORTED.md.

Each section of NOT_SUPPORTED.md documents a pattern that Pak does not support.
This module verifies that the compiler actually rejects each documented anti-pattern.

WHY: Without this test, a wrong example in NOT_SUPPORTED.md could silently
become accepted by a future compiler change, making the documentation lie.
These tests ensure the documentation stays accurate.

STRUCTURE: One test class per NOT_SUPPORTED.md section, named after the section.
Each class has:
  - test_wrong_*: the documented bad pattern must fail (exit non-zero)
  - test_correct_*: the documented correct alternative must compile
"""

import subprocess
import textwrap
import tempfile
from pathlib import Path
import pytest

# Drives the installed `pak` CLI; skipped cleanly if it is not on PATH.
pytestmark = pytest.mark.requires_pak


# ── Helpers ───────────────────────────────────────────────────────────────────

def _check(source: str) -> tuple[int, str]:
    """Run pak check on a source string. Returns (exit_code, combined_output)."""
    with tempfile.NamedTemporaryFile(suffix=".pak", mode="w",
                                     encoding="utf-8", delete=False) as f:
        f.write(source)
        tmp = Path(f.name)
    try:
        r = subprocess.run(["pak", "check", str(tmp)], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr
    finally:
        tmp.unlink(missing_ok=True)


def assert_fails(source: str, reason: str = ""):
    code, output = _check(source)
    assert code != 0, (
        f"Expected FAIL ({reason}) but compiler accepted it.\nSource:\n{source}"
    )


def assert_passes(source: str, reason: str = ""):
    code, output = _check(source)
    assert code == 0, (
        f"Expected PASS ({reason}) but compiler rejected it.\n"
        f"Output:\n{output}\nSource:\n{source}"
    )


# ══════════════════════════════════════════════════════════════════════════════
# No `fn main()` — entry point is `entry { }`
# ══════════════════════════════════════════════════════════════════════════════

class TestNoFnMain:
    def test_wrong_fn_main_without_entry_fails(self):
        """fn main() with no entry block → E103."""
        assert_fails("fn main() { }", "fn main with no entry")

    def test_correct_entry_block_passes(self):
        assert_passes("entry { }", "entry block")


# ══════════════════════════════════════════════════════════════════════════════
# No `null` keyword — use `none`
# ══════════════════════════════════════════════════════════════════════════════

class TestNoNull:
    def test_wrong_null_keyword_fails(self):
        """`null` is not a keyword → E010 unknown name."""
        assert_fails(textwrap.dedent("""
            entry {
                let x: i32 = null
            }
        """).strip(), "null is not defined")

    def test_correct_none_passes(self):
        assert_passes(textwrap.dedent("""
            entry {
                let x: ?*i32 = none
            }
        """).strip(), "none is valid")


# ══════════════════════════════════════════════════════════════════════════════
# No `if let` / `while let`
# ══════════════════════════════════════════════════════════════════════════════

class TestNoIfLet:
    def test_wrong_if_let_fails(self):
        """`if let` is Rust syntax → E002 parse error."""
        assert_fails(textwrap.dedent("""
            entry {
                let x: i32 = 5
                if let y = x { }
            }
        """).strip(), "if let not supported")

    def test_correct_match_passes(self):
        """Use match instead of if let."""
        assert_passes(textwrap.dedent("""
            variant MaybeInt { some(i32), none }
            entry {
                let v = MaybeInt.some(5)
                match v {
                    .some(x) => { }
                    .none    => { }
                }
            }
        """).strip(), "match is correct alternative")


# ══════════════════════════════════════════════════════════════════════════════
# No `let _` — underscore is not a valid identifier
# ══════════════════════════════════════════════════════════════════════════════

class TestNoLetUnderscore:
    def test_wrong_let_underscore_fails(self):
        """`let _ = expr` is a parse error — _ is a keyword token."""
        assert_fails(textwrap.dedent("""
            entry {
                let _: i32 = 42
            }
        """).strip(), "let _ is not valid")

    def test_correct_named_sink_passes(self):
        """Use a named variable or static sink instead."""
        assert_passes(textwrap.dedent("""
            static sink: i32 = 0
            entry {
                sink = 42
            }
        """).strip(), "named sink is valid")


# ══════════════════════════════════════════════════════════════════════════════
# No Range Patterns in Match
# ══════════════════════════════════════════════════════════════════════════════

class TestNoRangePatterns:
    def test_wrong_range_pattern_fails(self):
        """Match on range `1..10` → E002 parse error."""
        assert_fails(textwrap.dedent("""
            entry {
                let x: i32 = 5
                match x {
                    1..10 => { }
                    _ => { }
                }
            }
        """).strip(), "range patterns not supported")


# ══════════════════════════════════════════════════════════════════════════════
# Integer Pattern Matching — Supported (NOT_SUPPORTED.md was wrong)
# ══════════════════════════════════════════════════════════════════════════════

class TestIntegerMatch:
    def test_integer_match_is_accepted(self):
        """Integer literal match arms ARE accepted by the compiler.
        NOT_SUPPORTED.md was updated to reflect this reality."""
        assert_passes(textwrap.dedent("""
            entry {
                let x: i32 = 5
                match x {
                    1 => { }
                    2 => { }
                    _ => { }
                }
            }
        """).strip(), "integer match with wildcard")

    def test_range_patterns_still_fail(self):
        """Range patterns (0..10) are NOT accepted — parse error."""
        assert_fails(textwrap.dedent("""
            entry {
                let x: i32 = 5
                match x {
                    0..10 => { }
                    _ => { }
                }
            }
        """).strip(), "range patterns not supported")


# ══════════════════════════════════════════════════════════════════════════════
# No `new` / `delete` — use mem.alloc / mem.free
# ══════════════════════════════════════════════════════════════════════════════

class TestNoNewDelete:
    def test_wrong_new_keyword_fails(self):
        """`new` keyword doesn't exist → E002 or E010."""
        assert_fails(textwrap.dedent("""
            struct Foo { x: i32 }
            entry {
                let p = new Foo
            }
        """).strip(), "new keyword not supported")


# ══════════════════════════════════════════════════════════════════════════════
# No Struct Destructuring in `let`
# ══════════════════════════════════════════════════════════════════════════════

class TestNoStructDestructuring:
    def test_wrong_destructuring_fails(self):
        """Rust/JS-style destructuring in let → E002 parse error."""
        assert_fails(textwrap.dedent("""
            struct Point { x: i32, y: i32 }
            entry {
                let p = Point { x: 1, y: 2 }
                let { x, y } = p
            }
        """).strip(), "struct destructuring not supported")

    def test_correct_field_access_passes(self):
        """Access fields with dot notation instead."""
        assert_passes(textwrap.dedent("""
            struct Point { x: i32, y: i32 }
            static sx: i32 = 0
            static sy: i32 = 0
            entry {
                let p = Point { x: 1, y: 2 }
                sx = p.x
                sy = p.y
            }
        """).strip(), "field access is valid")


# ══════════════════════════════════════════════════════════════════════════════
# No Rust-Style `?` Propagation Operator
# ══════════════════════════════════════════════════════════════════════════════

class TestNoQuestionMarkPropagation:
    def test_wrong_question_mark_fails(self):
        """Using `?` for error propagation → E002 parse error."""
        assert_fails(textwrap.dedent("""
            fn load() -> Result(i32, i32) {
                let r: Result(i32, i32) = ok(5)
                let v = r?
                return ok(v)
            }
            entry { }
        """).strip(), "? operator not supported")

    def test_correct_match_propagation_passes(self):
        """Use match to propagate errors manually."""
        assert_passes(textwrap.dedent("""
            enum ErrCode: u8 { bad }
            static sink: i32 = 0

            fn load() -> Result(i32, ErrCode) {
                return ok(42)
            }

            entry {
                let r = load()
                match r {
                    .ok(v)  => { sink = v }
                    .err(e) => { sink = -1 }
                }
            }
        """).strip(), "match propagation is valid")


# ══════════════════════════════════════════════════════════════════════════════
# No Non-Exhaustive Enum Match
# ══════════════════════════════════════════════════════════════════════════════

class TestExhaustiveMatch:
    def test_non_exhaustive_enum_match_fails(self):
        """Missing match arm for an enum case → E301."""
        assert_fails(textwrap.dedent("""
            enum Color { red, green, blue }
            static sink: i32 = 0
            fn f(c: Color) -> i32 {
                match c {
                    .red   => { return 0 }
                    .green => { return 1 }
                    -- missing .blue
                }
                return -1
            }
            entry { }
        """).strip(), "non-exhaustive match must fail")

    def test_exhaustive_with_wildcard_passes(self):
        """Adding _ wildcard makes match exhaustive."""
        assert_passes(textwrap.dedent("""
            enum Color { red, green, blue }
            static sink: i32 = 0
            fn f(c: Color) -> i32 {
                match c {
                    .red   => { return 0 }
                    .green => { return 1 }
                    _ => { return 2 }
                }
                return -1
            }
            entry { }
        """).strip(), "wildcard makes match exhaustive")

    def test_exhaustive_all_cases_passes(self):
        """Covering all cases explicitly is also valid."""
        assert_passes(textwrap.dedent("""
            enum Color { red, green, blue }
            fn f(c: Color) -> i32 {
                match c {
                    .red   => { return 0 }
                    .green => { return 1 }
                    .blue  => { return 2 }
                }
                return -1
            }
            entry { }
        """).strip(), "all cases covered")


# ══════════════════════════════════════════════════════════════════════════════
# No `impl Trait` Return Types
# ══════════════════════════════════════════════════════════════════════════════

class TestNoImplTraitReturn:
    def test_wrong_impl_trait_return_fails(self):
        """`-> impl Trait` return type syntax fails."""
        assert_fails(textwrap.dedent("""
            trait Drawable { fn draw(self: *Self) }
            fn make_thing() -> impl Drawable { }
            entry { }
        """).strip(), "impl Trait return type not supported")
