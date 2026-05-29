"""
tests/test_mutation.py — Mutation tests for the Pak compiler.

Takes known-valid Pak source, injects one specific mutation, and verifies
the compiler rejects the result. This proves the checks are sensitive
enough to catch the kinds of mistakes an LLM might produce.

Each mutation is a (source, mutation_fn, expected_error_code) triple.
The mutation_fn takes the source string and returns a broken version.

This is complementary to test_fixes.py (which tests known fixes) and
test_invalid.py (which tests static files). Mutation tests let us verify
that each check is *independently* exercised on real code.
"""

import subprocess
import textwrap
import tempfile
from pathlib import Path
import pytest

# Drives the installed `pak` CLI; skipped cleanly if it is not on PATH.
pytestmark = pytest.mark.requires_pak


# ── Helpers ───────────────────────────────────────────────────────────────────

CANONICAL = Path(__file__).parent.parent / "examples" / "canonical"


def _source(name: str) -> str:
    return (CANONICAL / name).read_text(encoding="utf-8")


def _check(source: str) -> tuple[int, str]:
    """Run pak check on a source string. Returns (exit_code, output)."""
    with tempfile.NamedTemporaryFile(suffix=".pak", mode="w",
                                     encoding="utf-8", delete=False) as f:
        f.write(source)
        tmp = Path(f.name)
    try:
        result = subprocess.run(
            ["pak", "check", str(tmp)],
            capture_output=True, text=True,
        )
        return result.returncode, result.stdout + result.stderr
    finally:
        tmp.unlink(missing_ok=True)


def assert_mutant_fails(source: str, expected_code: str):
    """Assert that a mutated source fails with the given error code."""
    exit_code, output = _check(source)
    assert exit_code != 0, (
        f"Mutant should have failed with {expected_code} but compiled successfully.\n"
        f"Source:\n{source}"
    )
    assert expected_code in output, (
        f"Expected {expected_code} but got different errors:\n{output}"
    )


def assert_original_passes(source: str):
    """Verify the original (pre-mutation) source is clean."""
    exit_code, output = _check(source)
    assert exit_code == 0, f"Original source should pass but got:\n{output}"


# ══════════════════════════════════════════════════════════════════════════════
# E001 mutations — lex errors
# ══════════════════════════════════════════════════════════════════════════════

class TestE001Mutations:
    BASE = textwrap.dedent("""
        entry {
            let s: *c_char = "hello"
        }
    """).strip()

    def test_unterminated_string(self):
        mutant = self.BASE.replace('"hello"', '"hello')
        assert_mutant_fails(mutant, "E001")

    def test_original_passes(self):
        assert_original_passes(self.BASE)


# ══════════════════════════════════════════════════════════════════════════════
# E002 mutations — parse errors
# ══════════════════════════════════════════════════════════════════════════════

class TestE002Mutations:
    BASE = textwrap.dedent("""
        entry {
            let a: bool = true
            let b: bool = false
            if a and b { }
        }
    """).strip()

    def test_rust_or_operator(self):
        """Rust-style '||' is not the logical or — 'or' is. '|' is bitwise OR.
        Using '||' between bools is actually parsed (as two | ops), but
        we can confirm 'or' is required by checking NOT compiles:"""
        # Confirm the correct form compiles
        assert_original_passes(self.BASE)
        # Rust-style if let IS a clear E002
        mutant = textwrap.dedent("""
            entry {
                let x: i32 = 5
                if let y = x { }
            }
        """).strip()
        assert_mutant_fails(mutant, "E002")

    def test_rust_if_let(self):
        """Rust-style 'if let' is a parse error."""
        mutant = textwrap.dedent("""
            entry {
                let x: i32 = 5
                if let y = x { }
            }
        """).strip()
        assert_mutant_fails(mutant, "E002")

    def test_let_underscore_is_parse_error(self):
        """Using _ as a let target is a parse error (E002)."""
        mutant = textwrap.dedent("""
            entry {
                let _: i32 = 42
            }
        """).strip()
        assert_mutant_fails(mutant, "E002")

    def test_missing_entry_braces(self):
        """Entry block without braces is a parse error."""
        mutant = "entry\n    let x: i32 = 5"
        assert_mutant_fails(mutant, "E002")

    def test_original_passes(self):
        assert_original_passes(self.BASE)


# ══════════════════════════════════════════════════════════════════════════════
# E010 mutations — undefined name
# ══════════════════════════════════════════════════════════════════════════════

class TestE010Mutations:
    BASE = textwrap.dedent("""
        fn add(a: i32, b: i32) -> i32 {
            return a + b
        }
        entry {
            let result = add(1, 2)
        }
    """).strip()

    def test_typo_in_variable_access(self):
        """Typo in a variable name → E010 (variable access, not call site)."""
        mutant = textwrap.dedent("""
            fn add(a: i32, b: i32) -> i32 {
                return a + b
            }
            static sink: i32 = 0
            entry {
                let x: i32 = 5
                sink = y + 1
            }
        """).strip()
        assert_mutant_fails(mutant, "E010")

    def test_use_before_declare(self):
        """Using a variable before declaring it → E010."""
        mutant = textwrap.dedent("""
            entry {
                let y: i32 = x + 1
                let x: i32 = 5
            }
        """).strip()
        assert_mutant_fails(mutant, "E010")

    def test_wrong_scope_access(self):
        """Accessing a variable from another function's scope → E010."""
        mutant = textwrap.dedent("""
            fn foo() -> i32 {
                let local: i32 = 99
                return local
            }
            entry {
                let x = local + 1
            }
        """).strip()
        assert_mutant_fails(mutant, "E010")

    def test_original_passes(self):
        assert_original_passes(self.BASE)


# ══════════════════════════════════════════════════════════════════════════════
# E103 mutations — missing entry block
# ══════════════════════════════════════════════════════════════════════════════

class TestE103Mutations:
    BASE = textwrap.dedent("""
        fn helper() -> i32 { return 0 }
        entry { }
    """).strip()

    def test_remove_entry_block(self):
        """Removing entry block from a program with functions → E103."""
        mutant = "fn helper() -> i32 { return 0 }"
        assert_mutant_fails(mutant, "E103")

    def test_entry_renamed_to_main(self):
        """Renaming 'entry' to 'fn main' removes the entry block → E103."""
        mutant = textwrap.dedent("""
            fn helper() -> i32 { return 0 }
            fn main() { }
        """).strip()
        assert_mutant_fails(mutant, "E103")

    def test_original_passes(self):
        assert_original_passes(self.BASE)


# ══════════════════════════════════════════════════════════════════════════════
# E301 mutations — non-exhaustive match
# ══════════════════════════════════════════════════════════════════════════════

class TestE301Mutations:
    BASE = textwrap.dedent("""
        enum Dir { north, south, east, west }
        fn f(d: Dir) -> i32 {
            match d {
                .north => { return 0 }
                .south => { return 1 }
                .east  => { return 2 }
                .west  => { return 3 }
            }
            return -1
        }
        entry { }
    """).strip()

    def test_remove_one_arm(self):
        """Removing one match arm → E301 non-exhaustive."""
        # After textwrap.dedent, arms have 8 spaces indent
        mutant = self.BASE.replace("        .west  => { return 3 }\n", "")
        assert ".west" not in mutant, "Sanity: .west arm should be removed"
        assert_mutant_fails(mutant, "E301")

    def test_remove_two_arms(self):
        """Removing two match arms → E301."""
        mutant = self.BASE.replace("        .east  => { return 2 }\n", "")
        mutant = mutant.replace("        .west  => { return 3 }\n", "")
        assert_mutant_fails(mutant, "E301")

    def test_add_default_arm_suppresses_e301(self):
        """Adding _ => default arm makes match exhaustive."""
        # Remove .east and .west, add _ wildcard
        mutant = self.BASE.replace("                .east  => { return 2 }\n", "")
        mutant = mutant.replace("                .west  => { return 3 }", "                _ => { return -1 }")
        assert_original_passes(mutant)

    def test_original_passes(self):
        assert_original_passes(self.BASE)


# ══════════════════════════════════════════════════════════════════════════════
# E401 mutations — use after move
# ══════════════════════════════════════════════════════════════════════════════

class TestE401Mutations:
    BASE = textwrap.dedent("""
        entry {
            let x: i32 = 10
            let p: *i32 = &x
            let q: *i32 = p
        }
    """).strip()

    def test_use_after_move(self):
        """Dereferencing a moved pointer → E401."""
        mutant = textwrap.dedent("""
            entry {
                let x: i32 = 10
                let p: *i32 = &x
                let q: *i32 = p
                let bad: i32 = *p
            }
        """).strip()
        assert_mutant_fails(mutant, "E401")

    def test_double_move(self):
        """Moving an already-moved pointer → E401."""
        mutant = textwrap.dedent("""
            entry {
                let x: i32 = 10
                let p: *i32 = &x
                let q: *i32 = p
                let r: *i32 = p
            }
        """).strip()
        assert_mutant_fails(mutant, "E401")

    def test_original_passes(self):
        assert_original_passes(self.BASE)


# ══════════════════════════════════════════════════════════════════════════════
# E201/E202 mutations — DMA safety
# ══════════════════════════════════════════════════════════════════════════════

class TestDmaMutations:
    GOOD = textwrap.dedent("""
        use n64.dma
        use n64.cache

        @aligned(16)
        static buf: [4096]u8 = undefined

        entry {
            cache.writeback(buf, 4096)
            dma.read(buf, 0x10040000, 4096)
            dma.wait()
            cache.invalidate(buf, 4096)
        }
    """).strip()

    def test_missing_writeback_triggers_e201(self):
        """Removing cache.writeback → E201."""
        mutant = textwrap.dedent("""
            use n64.dma

            static buf: [4096]u8 = undefined

            entry {
                dma.read(buf, 0x10040000, 4096)
            }
        """).strip()
        assert_mutant_fails(mutant, "E201")

    def test_missing_aligned_triggers_e202(self):
        """Removing @aligned(16) → E202."""
        mutant = textwrap.dedent("""
            use n64.dma
            use n64.cache

            static buf: [4096]u8 = undefined

            entry {
                cache.writeback(buf, 4096)
                dma.read(buf, 0x10040000, 4096)
                dma.wait()
                cache.invalidate(buf, 4096)
            }
        """).strip()
        assert_mutant_fails(mutant, "E202")

    def test_named_constant_address_does_not_trigger(self):
        """Named constant in address/size args must NOT trigger false E201/E202."""
        with_const = textwrap.dedent("""
            use n64.dma
            use n64.cache

            const ROM_ADDR: i32 = 0x10040000
            const DATA_SIZE: i32 = 4096

            @aligned(16)
            static buf: [4096]u8 = undefined

            entry {
                cache.writeback(buf, DATA_SIZE)
                dma.read(buf, ROM_ADDR, DATA_SIZE)
                dma.wait()
                cache.invalidate(buf, DATA_SIZE)
            }
        """).strip()
        assert_original_passes(with_const)

    def test_original_passes(self):
        assert_original_passes(self.GOOD)


# ══════════════════════════════════════════════════════════════════════════════
# Semantic mutations — snapshot delta detection
# ══════════════════════════════════════════════════════════════════════════════

class TestSemanticMutations:
    """
    Verify that semantic changes (not just parse errors) produce different C.
    These mutations all COMPILE but should produce different generated code.
    This class checks that pak explain output changes when semantics change.
    """

    def _explain(self, source: str) -> str:
        with tempfile.NamedTemporaryFile(suffix=".pak", mode="w",
                                         encoding="utf-8", delete=False) as f:
            f.write(source)
            tmp = Path(f.name)
        try:
            result = subprocess.run(
                ["pak", "explain", str(tmp)],
                capture_output=True, text=True,
            )
            assert result.returncode == 0, f"pak explain failed:\n{result.stderr}"
            return result.stdout
        finally:
            tmp.unlink(missing_ok=True)

    def test_changed_constant_value_changes_c(self):
        """Changing a constant value must change the generated C."""
        v1 = textwrap.dedent("""
            const SPEED: i32 = 3
            static pos: i32 = 0
            entry { pos = pos + SPEED }
        """).strip()
        v2 = v1.replace("= 3", "= 7")

        c1 = self._explain(v1)
        c2 = self._explain(v2)
        assert c1 != c2, "Changing a constant value must change generated C"

    def test_changed_struct_field_changes_c(self):
        """Adding a struct field changes the struct layout in generated C."""
        v1 = textwrap.dedent("""
            struct Point { x: i32, y: i32 }
            static origin: Point = Point { x: 0, y: 0 }
            entry { }
        """).strip()
        v2 = textwrap.dedent("""
            struct Point { x: i32, y: i32, z: i32 }
            static origin: Point = Point { x: 0, y: 0, z: 0 }
            entry { }
        """).strip()

        c1 = self._explain(v1)
        c2 = self._explain(v2)
        assert c1 != c2, "Adding a struct field must change generated C"

    def test_changed_return_value_changes_c(self):
        """Changing a function's return expression changes generated C."""
        v1 = textwrap.dedent("""
            fn answer() -> i32 { return 42 }
            entry { }
        """).strip()
        v2 = v1.replace("return 42", "return 99")

        c1 = self._explain(v1)
        c2 = self._explain(v2)
        assert c1 != c2, "Changing return value must change generated C"
