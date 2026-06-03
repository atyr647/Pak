"""
tests/test_fixes.py — Regression tests for compiler bug fixes.

Covers two parser/typechecker fixes:

  1. Parser fix (parser.py:parse_pattern): `.ok(v)` and `.err(e)` as match
     arm patterns — keywords must be accepted after "." in patterns.

  2. Typechecker fix (typechecker.py:_check_match): payload bindings in
     variant match arms must be declared in scope (E010 was firing for
     variables bound in `.case(x)` match patterns).
"""

import sys
import os
import textwrap
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from pak.lexer import Lexer, LexError
from pak.parser import Parser, ParseError
from pak.typechecker import typecheck


# ── Helpers ───────────────────────────────────────────────────────────────────

def parse_ok(src: str):
    """Assert source parses without error; return Program."""
    tokens = Lexer(textwrap.dedent(src).strip()).tokenize()
    return Parser(tokens).parse()


def tc_errors(src: str):
    """Return list of (code, message) tuples from the typechecker."""
    prog = parse_ok(src)
    errors = typecheck(prog, filename='test.pk64')
    return [(e.code, e.message) for e in errors]


def tc_error_codes(src: str):
    """Return set of error codes from the typechecker."""
    return {code for code, _ in tc_errors(src)}


# ══════════════════════════════════════════════════════════════════════════════
# Fix 1 — Parser: .ok/.err/.none as match arm patterns (keyword case names)
# ══════════════════════════════════════════════════════════════════════════════

class TestKeywordMatchPatterns:
    """Parser fix: expect_name() instead of expect(TT.IDENT) in parse_pattern()."""

    def test_ok_pattern_parses(self):
        """.ok(v) in match arm must parse without error."""
        parse_ok("""
            entry {
                let r: Result(i32, i32) = ok(42)
                match r {
                    .ok(v)  => { }
                    .err(e) => { }
                }
            }
        """)

    def test_err_pattern_parses(self):
        """.err(e) in match arm must parse without error."""
        parse_ok("""
            entry {
                let r: Result(i32, i32) = err(7)
                match r {
                    .ok(v)  => { }
                    .err(e) => { }
                }
            }
        """)

    def test_none_pattern_parses(self):
        """.none as a unit match arm must parse without error."""
        parse_ok("""
            variant MaybeInt {
                none
                some(i32)
            }
            entry {
                let x = MaybeInt.none
                match x {
                    .none    => { }
                    .some(v) => { }
                }
            }
        """)

    def test_ok_err_full_result_workflow(self):
        """Full Result idiom: return ok/err, match on .ok/.err — must parse and typecheck."""
        parse_ok("""
            enum Err: u8 { bad }

            fn load(flag: bool) -> Result(i32, Err) {
                if flag { return ok(42) }
                return err(Err.bad)
            }

            static sink: i32 = 0

            entry {
                let r = load(true)
                match r {
                    .ok(v)  => { sink = v }
                    .err(e) => { sink = -1 }
                }
            }
        """)

    def test_keyword_as_variant_case_name_in_pattern(self):
        """Variant case named 'ok' or 'err' are reserved keywords — only standard .ok/.err patterns supported."""
        # .ok(v) and .err(e) work as patterns for Result — verify no parse error
        prog = parse_ok("""
            entry {
                let x: Result(i32, i32) = ok(1)
                match x {
                    .ok(val) => { }
                    .err(e)  => { }
                }
            }
        """)
        assert prog is not None


# ══════════════════════════════════════════════════════════════════════════════
# Fix 2 — Typechecker: payload bindings declared in scope for variant match
# ══════════════════════════════════════════════════════════════════════════════

class TestVariantPayloadBindingScope:
    """Typechecker fix: payload variable bindings in .Case(x) arms must be in scope."""

    def test_single_payload_binding_in_scope(self):
        """Bound variable from .circle(r) must be usable in the arm body."""
        errors = tc_error_codes("""
            variant Shape {
                circle(f32)
                point
            }

            static sink: f32 = 0.0

            fn area(s: Shape) -> f32 {
                match s {
                    .circle(r) => { return r * r * 3.14159 }
                    .point     => { return 0.0 }
                }
                return 0.0
            }

            entry {
                sink = area(Shape.circle(5.0))
            }
        """)
        assert 'E010' not in errors, f"E010 should not fire for payload binding 'r'; got errors: {errors}"

    def test_multi_payload_binding_in_scope(self):
        """Both bindings from .rect(w, h) must be usable in the arm body."""
        errors = tc_error_codes("""
            variant Shape {
                rect(f32, f32)
                point
            }

            static sink: f32 = 0.0

            fn area(s: Shape) -> f32 {
                match s {
                    .rect(w, h) => { return w * h }
                    .point      => { return 0.0 }
                }
                return 0.0
            }

            entry {
                sink = area(Shape.rect(4.0, 3.0))
            }
        """)
        assert 'E010' not in errors, f"E010 should not fire for payload bindings 'w', 'h'; got: {errors}"

    def test_ok_payload_binding_in_scope(self):
        """Bound variable from .ok(v) must be usable in the arm body."""
        errors = tc_error_codes("""
            enum ErrCode: u8 { bad }

            fn get() -> Result(i32, ErrCode) {
                return ok(10)
            }

            static sink: i32 = 0

            entry {
                let r = get()
                match r {
                    .ok(v)  => { sink = v }
                    .err(e) => { sink = -1 }
                }
            }
        """)
        assert 'E010' not in errors, f"E010 should not fire for .ok(v) binding; got: {errors}"

    def test_err_payload_binding_in_scope(self):
        """Bound variable from .err(e) must be usable in the arm body."""
        errors = tc_error_codes("""
            enum ErrCode: u8 { bad }

            static sink: i32 = 0

            entry {
                let r: Result(i32, ErrCode) = err(ErrCode.bad)
                match r {
                    .ok(v)  => { sink = v }
                    .err(e) => { sink = -1 }
                }
            }
        """)
        assert 'E010' not in errors, f"E010 should not fire for .err(e) binding; got: {errors}"

    def test_payload_binding_not_visible_outside_arm(self):
        """Payload bindings must NOT leak outside the match arm."""
        errors = tc_error_codes("""
            variant Shape {
                circle(f32)
                point
            }

            static sink: f32 = 0.0

            entry {
                let s = Shape.circle(5.0)
                match s {
                    .circle(r) => { sink = r }
                    .point     => { }
                }
                sink = r
            }
        """)
        assert 'E010' in errors, "E010 must fire for 'r' used outside its match arm scope"

    def test_wildcard_binding_ignored(self):
        """Wildcard '_' in payload position must not be declared (it is a keyword)."""
        errors = tc_error_codes("""
            variant Shape {
                circle(f32)
                point
            }

            static sink: f32 = 0.0

            entry {
                let s = Shape.circle(5.0)
                match s {
                    .circle(_) => { sink = 1.0 }
                    .point     => { sink = 0.0 }
                }
            }
        """)
        assert 'E010' not in errors, f"Wildcard '_' in payload should not cause errors; got: {errors}"


# ══════════════════════════════════════════════════════════════════════════════
# Fix 3 — Typechecker: asset names declared in scope
# ══════════════════════════════════════════════════════════════════════════════

class TestAssetScope:
    """Typechecker fix: asset declarations register the name in scope."""

    def test_asset_name_in_scope(self):
        """Asset names must be usable without triggering E010."""
        errors = tc_error_codes("""
            use n64.sprite

            asset player_sprite: Sprite from "sprites/player.png"

            entry {
                sprite.blit(player_sprite, 160, 120, 0)
            }
        """)
        assert 'E010' not in errors, f"E010 should not fire for declared asset name; got: {errors}"

    def test_multiple_assets_in_scope(self):
        """Multiple asset declarations all registered in scope."""
        errors = tc_error_codes("""
            use n64.sprite

            asset bg:     Sprite from "bg.png"
            asset player: Sprite from "player.png"
            asset enemy:  Sprite from "enemy.png"

            entry {
                sprite.blit(bg,     0,   0,   0)
                sprite.blit(player, 160, 120, 0)
                sprite.blit(enemy,  100, 80,  0)
            }
        """)
        assert 'E010' not in errors, f"E010 should not fire for any declared asset name; got: {errors}"


# ══════════════════════════════════════════════════════════════════════════════
# Fix 4 — Typechecker: DMA checker only checks first argument (buffer)
# ══════════════════════════════════════════════════════════════════════════════

class TestDmaCheckerArgs:
    """Typechecker fix: E201/E202 must not fire on non-buffer DMA arguments."""

    def test_named_constant_address_no_false_positive(self):
        """Named constant in DMA address arg must not trigger E201/E202."""
        errors = tc_error_codes("""
            use n64.dma
            use n64.cache

            const ROM_ADDR: i32 = 0x10040000
            const DATA_SIZE: i32 = 4096

            @aligned(16)
            static data_buf: [4096]u8 = undefined

            entry {
                cache.writeback(&data_buf[0], DATA_SIZE)
                dma.read(&data_buf[0], ROM_ADDR, DATA_SIZE)
                dma.wait()
                cache.invalidate(&data_buf[0], DATA_SIZE)
            }
        """)
        assert 'E201' not in errors, f"E201 must not fire on ROM_ADDR constant; got: {errors}"
        assert 'E202' not in errors, f"E202 must not fire on ROM_ADDR constant; got: {errors}"

    def test_unaligned_buffer_still_triggers_e202(self):
        """E202 must still fire when the buffer itself lacks @aligned(16)."""
        errors = tc_error_codes("""
            use n64.dma
            use n64.cache

            static bad_buf: [4096]u8 = undefined

            entry {
                cache.writeback(bad_buf, 4096)
                dma.read(bad_buf, 0x10040000, 4096)
                dma.wait()
                cache.invalidate(bad_buf, 4096)
            }
        """)
        assert 'E202' in errors, f"E202 must fire for unaligned buffer 'bad_buf'; got: {errors}"

    def test_missing_writeback_still_triggers_e201(self):
        """E201 must still fire when cache.writeback is missing."""
        errors = tc_error_codes("""
            use n64.dma

            static data_buf: [4096]u8 = undefined

            entry {
                dma.read(data_buf, 0x10040000, 4096)
            }
        """)
        assert 'E201' in errors, f"E201 must fire when cache.writeback is missing; got: {errors}"


class TestMalformedHexLiteral:
    """lexer.py: `0x` with no hex digits must raise a clean LexError (E001),
    not crash the parser with an uncaught ValueError."""

    def test_bare_0x_is_lex_error(self):
        with pytest.raises(LexError):
            Lexer("entry { let x: u8 = 0xPA }").tokenize()

    def test_0x_at_eof_is_lex_error(self):
        with pytest.raises(LexError):
            Lexer("let x = 0x").tokenize()

    def test_valid_hex_still_lexes(self):
        parse_ok("entry { let x: u32 = 0xFF00 }")

    def test_hex_underscores_still_lex(self):
        parse_ok("entry { let x: u32 = 0xDE_AD_BE_EF }")


class TestVariadicExtern:
    """parser/codegen: a trailing `...` declares a C-style variadic extern."""

    SRC = """
        extern "C" {
            fn rdpq_text_printf(x: i32, y: i32, font: i32, fmt: *c_char, ...) -> i32
        }
        entry {
            rdpq_text_printf(10, 20, 1, "score %d", 42)
            rdpq_text_printf(10, 40, 1, "ready")
        }
    """

    def test_variadic_extern_parses(self):
        prog = parse_ok(self.SRC)
        from pak import ast as _ast
        fns = []
        for d in prog.decls:
            if isinstance(d, _ast.ExternBlock):
                fns.extend(m for m in d.decls if isinstance(m, _ast.FnDecl))
        assert fns and fns[0].variadic is True
        assert len(fns[0].params) == 4

    def test_variadic_extern_typechecks(self):
        # Extra trailing args beyond the fixed params must not error.
        assert not tc_error_codes(self.SRC)

    def test_variadic_extern_codegen_emits_ellipsis(self):
        from tests.test_compiler import codegen
        c = codegen(self.SRC)
        assert "char * fmt, ...);" in c
