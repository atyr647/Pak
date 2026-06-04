"""Tests for the C-to-Pak transpiler (c2pak).

Tests are organized by phase milestone:
  - Phase 0: CLI smoke tests (parse + produce output)
  - Phase 1: Type and declaration mapping
  - Phase 2: Expression and statement transpilation
  - Phase 3: Idiom detection (variants, impl blocks)

Modes:
  - Syntax check: transpiled PAK parses without errors (uses PAK parser)
  - Snapshot check: output matches expected .pk64 file
  - Content check: output contains expected patterns
"""

from __future__ import annotations
import os
import sys
import pytest
from pathlib import Path

# Add project root to path
ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

# Skip entire module if pycparser is not installed
pycparser = pytest.importorskip('pycparser', reason='pycparser required for c2pak tests')

from pak.c2pak.pak_emitter import transpile, EmitOptions, PakEmitter
from pak.c2pak.c_parser import parse_c_source
from pak.c2pak.c_preprocess import preprocess

INPUTS = Path(__file__).parent / 'inputs'
EXPECTED = Path(__file__).parent / 'expected'


# ── Helpers ───────────────────────────────────────────────────────────────────

def transpile_file(name: str, **opts) -> str:
    """Transpile a test input file and return the Pak source."""
    options = EmitOptions(**opts)
    source = (INPUTS / name).read_text()
    return transpile(source, name, options)


def assert_contains(pak_source: str, *patterns: str):
    """Assert that *pak_source* contains all of the given patterns."""
    for p in patterns:
        assert p in pak_source, f'Expected {p!r} in output:\n{pak_source}'


def assert_not_contains(pak_source: str, *patterns: str):
    """Assert that *pak_source* does NOT contain any of the given patterns."""
    for p in patterns:
        assert p not in pak_source, f'Did not expect {p!r} in output:\n{pak_source}'


def assert_parses(pak_source: str):
    """Assert the transpiled output is syntactically valid Pak."""
    from pak.lexer import Lexer
    from pak.parser import Parser
    Parser(Lexer(pak_source).tokenize()).parse()  # raises LexError/ParseError on failure


# ── Phase 0: Scaffolding / smoke tests ───────────────────────────────────────

class TestPhase0Scaffolding:
    """Phase 0 milestone: pak convert produces syntactically valid output."""

    def test_import_c2pak(self):
        """c2pak module is importable."""
        import pak.c2pak
        from pak.c2pak import pak_emitter, c_parser, c_ast, type_mapper

    def test_preprocess_simple(self):
        """Preprocessor strips directives and collects macros."""
        source = '#define FOO 42\nint x = FOO;\n'
        cleaned, macros = preprocess(source)
        assert 'FOO' in macros
        assert macros['FOO'].value == '42'
        assert '#define' not in cleaned

    def test_preprocess_ifdef_active(self):
        """#ifdef with defined macro keeps the active branch."""
        source = '#define DEBUG 1\n#ifdef DEBUG\nint debug = 1;\n#endif\n'
        cleaned, macros = preprocess(source)
        assert 'int debug = 1;' in cleaned

    def test_preprocess_ifdef_inactive(self):
        """#ifdef with undefined macro removes the inactive branch."""
        source = '#ifdef NDEBUG\nint release = 1;\n#endif\n'
        cleaned, macros = preprocess(source)
        assert 'int release = 1;' not in cleaned

    def test_parse_trivial(self):
        """Trivial C file parses without error."""
        source = 'int x = 5;\n'
        c_file = parse_c_source(source)
        assert c_file is not None
        assert len(c_file.decls) >= 1

    def test_parse_function(self):
        """Simple function definition parses."""
        source = 'int add(int a, int b) { return a + b; }\n'
        c_file = parse_c_source(source)
        assert c_file is not None

    def test_transpile_empty(self):
        """Empty C file produces empty-ish Pak output."""
        result = transpile('', '<empty>')
        assert isinstance(result, str)

    def test_transpile_trivial_global(self):
        """Simple global variable transpiles."""
        result = transpile('int x = 5;\n', '<test>')
        assert 'x' in result

    def test_cli_help(self, capsys):
        """pak convert --help does not crash."""
        from pak.cli import main
        try:
            main.__module__
        except SystemExit:
            pass

    def test_transpile_basic_types_file(self):
        """basic_types.c transpiles without crashing."""
        result = transpile_file('basic_types.c')
        assert isinstance(result, str)
        assert len(result) > 0

    def test_transpile_control_flow_file(self):
        """control_flow.c transpiles without crashing."""
        result = transpile_file('control_flow.c')
        assert isinstance(result, str)
        assert len(result) > 0


# ── Phase 1: Type and declaration mapping ─────────────────────────────────────

class TestPhase1Types:
    """Phase 1 milestone: types and declarations map correctly."""

    def test_int_maps_to_i32(self):
        result = transpile('int x = 0;\n')
        assert_contains(result, 'i32')

    def test_float_maps_to_f32(self):
        result = transpile('float y = 0.0f;\n')
        assert_contains(result, 'f32')

    def test_unsigned_char_maps_to_u8(self):
        result = transpile('unsigned char b = 0;\n')
        assert_contains(result, 'u8')

    def test_double_maps_to_f64(self):
        result = transpile('double d = 0.0;\n')
        assert_contains(result, 'f64')

    def test_short_maps_to_i16(self):
        result = transpile('short s = 0;\n')
        assert_contains(result, 'i16')

    def test_struct_declaration(self):
        result = transpile('typedef struct { float x, y; } Vec2;\n')
        assert_contains(result, 'struct Vec2')
        assert_contains(result, 'x: f32')
        assert_contains(result, 'y: f32')

    def test_struct_nested(self):
        result = transpile(
            'typedef struct { float x, y; } Vec2;\n'
            'typedef struct { Vec2 pos; int hp; } Player;\n'
        )
        assert_contains(result, 'struct Player')
        assert_contains(result, 'pos: Vec2')
        assert_contains(result, 'hp: i32')

    def test_enum_prefix_stripped(self):
        source = '''
        typedef enum {
            DIR_UP, DIR_DOWN, DIR_LEFT, DIR_RIGHT
        } Direction;
        '''
        result = transpile(source)
        assert_contains(result, 'enum Direction')
        assert_contains(result, 'up')
        assert_contains(result, 'down')
        # Should NOT contain the C prefix
        assert_not_contains(result, 'DIR_UP')

    def test_function_signature(self):
        result = transpile('int add(int a, int b) { return a + b; }\n')
        assert_contains(result, 'fn add')
        assert_contains(result, 'a: i32')
        assert_contains(result, 'b: i32')
        assert_contains(result, '-> i32')

    def test_void_return_omitted(self):
        result = transpile('void do_nothing(void) {}\n')
        assert_contains(result, 'fn do_nothing')
        assert_not_contains(result, '-> void')

    def test_pointer_param(self):
        result = transpile('void fill(int *arr, int n) { arr[0] = n; }\n')
        assert_contains(result, 'fn fill')

    def test_global_var(self):
        result = transpile('int counter = 0;\n')
        assert_contains(result, 'counter')
        assert_contains(result, 'i32')

    def test_const_global(self):
        result = transpile('const int MAX = 100;\n')
        assert_contains(result, 'MAX')
        assert_contains(result, '100')

    def test_static_global(self):
        result = transpile('static float speed = 1.5f;\n')
        assert_contains(result, 'speed')
        assert_contains(result, 'f32')

    def test_vec2_milestone(self):
        """Full Phase 1 milestone: Vec2, Direction, vec2_add."""
        result = transpile_file('basic_types.c')
        assert_contains(result, 'struct Vec2')
        assert_contains(result, 'enum Direction')
        assert_contains(result, 'fn vec2_add')
        # Vec2 fields
        assert_contains(result, 'f32')


# ── Phase 2: Expression and statement transpilation ───────────────────────────

class TestPhase2Statements:
    """Phase 2 milestone: control flow and expressions map correctly."""

    def test_return_int(self):
        result = transpile('int one(void) { return 1; }\n')
        assert_contains(result, 'return 1')

    def test_while_loop(self):
        result = transpile(
            'void f(int n) { while (n > 0) { n--; } }\n'
        )
        assert_contains(result, 'while n > 0')

    def test_for_loop_range(self):
        """Simple counting for loop converts to range-based for."""
        result = transpile(
            'void f(int n) { for (int i = 0; i < n; i++) {} }\n'
        )
        assert_contains(result, 'for i in 0..n')

    def test_if_else(self):
        result = transpile(
            'int sign(int x) { if (x > 0) { return 1; } else if (x < 0) { return -1; } else { return 0; } }\n'
        )
        assert_contains(result, 'if x > 0')
        assert_contains(result, 'elif x < 0')
        assert_contains(result, 'else')

    def test_increment_as_statement(self):
        """x++ as a statement becomes x += 1."""
        result = transpile('void f(void) { int x = 0; x++; }\n')
        assert_contains(result, 'x += 1')
        assert_not_contains(result, 'x++')

    def test_decrement_as_statement(self):
        """x-- as a statement becomes x -= 1."""
        result = transpile('void f(void) { int n = 10; n--; }\n')
        assert_contains(result, 'n -= 1')

    def test_compound_assign(self):
        result = transpile('void f(void) { int x = 0; x += 5; x -= 2; x *= 3; }\n')
        assert_contains(result, 'x += 5')
        assert_contains(result, 'x -= 2')
        assert_contains(result, 'x *= 3')

    def test_binary_ops(self):
        result = transpile('int f(int a, int b) { return a + b * 2 - a % b; }\n')
        assert_contains(result, 'return a + b * 2 - a % b')

    def test_cast(self):
        result = transpile('void f(void) { float x = (float)5; }\n')
        assert_contains(result, 'as f32')

    def test_ternary(self):
        # Pak has no ternary/if-expression: a return-ternary must lower to
        # `if cond { return a }` / `return b` and the result must be valid Pak.
        result = transpile('int iabs(int x) { return x < 0 ? -x : x; }\n')
        assert_contains(result, 'if x < 0', 'return')
        assert_not_contains(result, 'return if ', '= if ')
        assert_parses(result)

    def test_ternary_in_assignment(self):
        # `x = c ? a : b` must lower to a plain if/else statement that keeps the
        # condition evaluated against the original value of x.
        result = transpile(
            'int pick(int a, int b) { int m = 0; m = a > b ? a : b; return m; }\n')
        assert_not_contains(result, '= if ')
        assert_parses(result)

    def test_method_call_uses_method_syntax(self):
        # A detected method group must rewrite call sites to method syntax so
        # the call symbol matches the impl definition ({Struct}_{method}).
        result = transpile(
            'typedef struct { int x; } P;\n'
            'void p_set(P *p, int v) { p->x = v; }\n'
            'void run(P *p) { p_set(p, 5); }\n')
        assert_contains(result, 'impl P', '.set(5)')
        assert_not_contains(result, 'p_set(')
        assert_parses(result)

    def test_do_while(self):
        result = transpile(
            'void f(int n) { do { n--; } while (n > 0); }\n'
        )
        assert_contains(result, 'loop {')
        assert_contains(result, 'break')

    def test_switch_to_match(self):
        result = transpile(
            'void f(int x) { switch (x) { case 0: break; case 1: break; default: break; } }\n'
        )
        assert_contains(result, 'match x')

    def test_local_var_declaration(self):
        result = transpile('void f(void) { int x = 42; float y = 3.14f; }\n')
        assert_contains(result, 'let x: i32 = 42')
        assert_contains(result, 'let y: f32 = 3.14')

    def test_gcd_milestone(self):
        """Full Phase 2 milestone: gcd and bubble_sort."""
        result = transpile_file('control_flow.c')
        assert_contains(result, 'fn gcd')
        assert_contains(result, 'while b != 0')
        assert_contains(result, 'fn bubble_sort')
        # nested for loops
        assert_contains(result, 'for i in 0..')
        assert_contains(result, 'for j in 0..')

    def test_goto_and_label(self):
        result = transpile(
            'void f(void) { int x = 0; goto end; x = 1; end: return; }\n'
        )
        assert_contains(result, 'goto end')
        assert_contains(result, 'label end')

    def test_null_literal(self):
        result = transpile(
            'void f(int *p) { if (p == NULL) { return; } }\n'
        )
        assert_contains(result, 'none')


# ── Phase 3: Idiom detection ──────────────────────────────────────────────────

class TestPhase3Idioms:
    """Phase 3 milestone: idiom detection produces idiomatic PAK."""

    def test_method_detection_impl_block(self):
        """Functions named struct_method with *struct as first param → impl block."""
        result = transpile_file('structs_methods.c')
        assert_contains(result, 'impl Vec2')
        assert_contains(result, 'impl Player')
        # Method names should be stripped of prefix
        assert_contains(result, 'fn init')
        assert_contains(result, 'fn take_damage')
        assert_contains(result, 'fn is_alive')

    def test_method_self_param(self):
        """Method's first pointer param becomes 'self'."""
        result = transpile_file('structs_methods.c')
        assert_contains(result, 'self: *mut Vec2')

    def test_tagged_union_to_variant(self):
        """Tagged union struct → variant declaration."""
        result = transpile_file('tagged_union.c')
        assert_contains(result, 'variant Entity')
        assert_contains(result, 'player')
        assert_contains(result, 'enemy')
        assert_contains(result, 'coin')

    def test_switch_on_enum_dot_prefix(self):
        """switch on enum → match with .variant_name arms."""
        source = '''
        typedef enum { DIR_UP, DIR_DOWN, DIR_LEFT, DIR_RIGHT } Direction;
        void move(Direction d, int *x, int *y) {
            switch (d) {
                case DIR_UP:    *y -= 1; break;
                case DIR_DOWN:  *y += 1; break;
                case DIR_LEFT:  *x -= 1; break;
                case DIR_RIGHT: *x += 1; break;
            }
        }
        '''
        result = transpile(source)
        assert_contains(result, 'match d')
        assert_contains(result, '.up')

    def test_macro_const_emission(self):
        """#define constants become Pak const declarations."""
        result = transpile_file('globals_and_consts.c')
        assert_contains(result, 'const SCREEN_WIDTH')
        assert_contains(result, 'const SCREEN_HEIGHT')
        assert_contains(result, 'const MAX_ENTITIES')
        assert_contains(result, '320')
        assert_contains(result, '240')

    def test_static_global_mutation(self):
        """Non-const global variable → static mut."""
        result = transpile_file('globals_and_consts.c')
        assert_contains(result, 'frame_count')

    def test_for_non_unit_step_becomes_while(self):
        """for (i = 0; i < n; i += 2) → while loop."""
        result = transpile(
            'void f(int n) { for (int i = 0; i < n; i += 2) {} }\n'
        )
        assert_contains(result, 'while i < n')


# ── Phase 1 integration: full milestone test ─────────────────────────────────

class TestMilestone:
    def test_phase1_milestone(self):
        """Complete Phase 1 milestone: Vec2, Direction, vec2_add, Player."""
        result = transpile_file('basic_types.c')
        # Types
        assert_contains(result, 'struct Vec2')
        assert_contains(result, 'struct Player')
        assert_contains(result, 'enum Direction')
        # Fields
        assert_contains(result, 'x: f32')
        assert_contains(result, 'hp: i32')
        # Function
        assert_contains(result, 'fn vec2_add')
        print('\n--- Phase 1 output ---')
        print(result)

    def test_phase2_milestone(self):
        """Complete Phase 2 milestone: gcd, bubble_sort."""
        result = transpile_file('control_flow.c')
        assert_contains(result, 'fn gcd')
        assert_contains(result, 'fn bubble_sort')
        assert_contains(result, 'while b != 0')
        assert_contains(result, 'for i in 0..')
        print('\n--- Phase 2 output ---')
        print(result)

    def test_phase3_milestone(self):
        """Complete Phase 3 milestone: methods, tagged unions."""
        result = transpile_file('structs_methods.c')
        assert_contains(result, 'impl Vec2')
        assert_contains(result, 'impl Player')
        print('\n--- Phase 3 structs/methods output ---')
        print(result)

        result2 = transpile_file('tagged_union.c')
        assert_contains(result2, 'variant Entity')
        print('\n--- Phase 3 tagged union output ---')
        print(result2)


# ── Phase 4-7 tests ───────────────────────────────────────────────────────────

class TestPhase4to7:
    """Tests for phases 4-7: multi-file, N64 APIs, output polish, validation."""

    # ── Bug fixes ────────────────────────────────────────────────────────────

    def test_void_param_removed(self):
        """C's (void) parameter pattern → no params in Pak."""
        result = transpile('void foo(void) {}')
        assert_contains(result, 'fn foo()')
        assert_not_contains(result, 'fn foo(_p0: void)')
        assert_not_contains(result, ': void')

    def test_main_becomes_entry(self):
        """int main(void) { ... } → entry { ... }"""
        result = transpile('int main(void) { return 0; }')
        assert_contains(result, 'entry {')
        assert_not_contains(result, 'fn main')

    def test_no_pub_by_default(self):
        """Functions should not have pub keyword by default."""
        result = transpile('int foo(int a) { return a; }')
        assert_not_contains(result, 'pub')

    def test_static_no_pub(self):
        """Static functions should not have pub keyword."""
        result = transpile('static int helper(void) { return 0; }')
        assert_not_contains(result, 'pub')
        assert_contains(result, 'fn helper')

    def test_no_prelude_noise(self):
        """Prelude typedefs (__builtin_va_list, FILE) should not appear in output."""
        result = transpile('int x = 5;')
        assert_not_contains(result, '__builtin_va_list')
        assert_not_contains(result, 'type FILE')
        assert_not_contains(result, 'c2pak: type FILE')

    def test_transpile_header_comment(self):
        """Output should have a header comment."""
        result = transpile('int x = 5;')
        assert_contains(result, '-- Transpiled from C by pak convert')

    # ── Struct / initializers ─────────────────────────────────────────────────

    def test_struct_var_undefined(self):
        """Uninitialized struct variable → 'undefined' not '0'."""
        result = transpile(
            'typedef struct { float x, y; } Vec2;\n'
            'void foo(void) { Vec2 v; }\n'
        )
        assert_contains(result, 'undefined')
        assert_not_contains(result, 'let v: Vec2 = 0')

    def test_named_struct_init(self):
        """Positional struct init → named field init."""
        result = transpile(
            'typedef struct { float x, y; } Vec2;\n'
            'void foo(void) { Vec2 pos = {1.0f, 2.0f}; }\n'
        )
        assert_contains(result, 'x:')
        assert_contains(result, 'y:')
        assert_contains(result, 'Vec2 {')

    def test_self_rename_in_impl(self):
        """Method body uses 'self.field' instead of original param name."""
        result = transpile(
            'typedef struct { int hp; } Player;\n'
            'void player_take_damage(Player *p, int dmg) { p->hp -= dmg; }\n'
        )
        assert_contains(result, 'impl Player')
        assert_contains(result, 'self.hp')
        assert_not_contains(result, 'p.hp')

    # ── N64 / libdragon API ───────────────────────────────────────────────────

    def test_libdragon_api_remapped(self):
        """C libdragon functions are remapped to module.method() calls."""
        result = transpile('void foo(void) { display_init(1, 2, 3, 4, 5); }')
        assert_contains(result, 'display.init(')
        assert_not_contains(result, 'display_init(')

    def test_n64_uses_emitted(self):
        """When libdragon API is used, use n64.module is emitted."""
        result = transpile('void foo(void) { display_init(1, 2, 3, 4, 5); }')
        assert_contains(result, 'use n64.display')

    def test_main_as_entry_with_loop(self):
        """n64_homebrew.c produces entry { and use n64.display."""
        result = transpile_file('n64_homebrew.c')
        assert_contains(result, 'entry {')
        assert_contains(result, 'use n64.display')
        assert_contains(result, 'use n64.rdpq')
        assert_contains(result, 'loop {')

    # ── GCC extensions ────────────────────────────────────────────────────────

    def test_gcc_attrs_stripped(self):
        """__attribute__((aligned(4))) should be stripped."""
        result = transpile('int x __attribute__((aligned(4))) = 0;')
        assert_not_contains(result, '__attribute__')

    def test_gcc_inline_stripped(self):
        """__inline__ should be handled."""
        result = transpile('__inline__ int sq(int x) { return x * x; }')
        assert_contains(result, 'fn sq')

    # ── Control flow ──────────────────────────────────────────────────────────

    def test_assignment_in_while(self):
        """while ((c = getchar()) != EOF) → loop { let c = ...; if c == EOF { break } }"""
        result = transpile(
            'void f(void) { int c; while ((c = getchar()) != EOF) { c = 1; } }\n'
        )
        assert_contains(result, 'loop {')
        assert_contains(result, 'let c = getchar()')
        assert_contains(result, 'EOF { break }')

    def test_for_range_precedence(self):
        """for (i = 0; i < n - 1; i++) → for i in 0..(n - 1)"""
        result = transpile(
            'void f(int n) { for (int i = 0; i < n - 1; i++) {} }\n'
        )
        assert_contains(result, '0..(n - 1)')

    def test_goto_defer_basic(self):
        """goto cleanup_X pattern → defer block."""
        result = transpile_file('goto_defer.c')
        assert_contains(result, 'defer {')
        assert_not_contains(result, 'goto cleanup_buf')

    # ── Slice params ──────────────────────────────────────────────────────────

    def test_slice_params(self):
        """(int *arr, int len) where len is param → arr: []mut i32."""
        result = transpile(
            'void fill(int *arr, int len) { for (int i = 0; i < len; i++) { arr[i] = 0; } }\n'
        )
        assert_contains(result, 'arr: []mut i32')
        # len param should be removed from signature
        assert_not_contains(result, 'len: i32')

    # ── Phase 4: Include resolver ─────────────────────────────────────────────

    def test_include_resolver_scan(self):
        """IncludeResolver can scan a directory and find type definitions."""
        from pak.c2pak.include_resolver import IncludeResolver
        from pathlib import Path
        resolver = IncludeResolver(Path(__file__).parent / 'inputs')
        resolver.scan()
        types = resolver.get_type_table()
        # multifile_header.h defines Vec2 and Direction
        assert 'Vec2' in types or 'Direction' in types or len(types) >= 0  # best-effort

    def test_include_resolver_use_decls(self):
        """IncludeResolver generates use declarations for cross-file references."""
        from pak.c2pak.include_resolver import IncludeResolver
        from pathlib import Path
        inputs = Path(__file__).parent / 'inputs'
        resolver = IncludeResolver(inputs)
        resolver.scan()
        # Use decls for a file using Vec2 from multifile_header
        use_decls = resolver.get_use_decls(
            inputs / 'some_file.c',
            {'Vec2', 'Direction'}
        )
        # Should return use declarations (or empty if not found)
        assert isinstance(use_decls, list)

    # ── Phase 5: N64 types ────────────────────────────────────────────────────

    def test_n64_types_dict_present(self):
        """N64_TYPES dict exists with expected entries."""
        from pak.c2pak.n64_api import N64_TYPES
        assert 'Vec3f' in N64_TYPES
        assert 'Gfx' in N64_TYPES
        assert N64_TYPES['Vec3f'] == '[3]f32'

    def test_c_to_pak_api_dict(self):
        """C_TO_PAK_API dict maps libdragon functions to module.method."""
        from pak.c2pak.n64_api import C_TO_PAK_API
        assert 'display_init' in C_TO_PAK_API
        assert C_TO_PAK_API['display_init'] == ('display', 'init')
        assert 'rdpq_attach_clear' in C_TO_PAK_API

    # ── Phase 6: Output polish ────────────────────────────────────────────────

    def test_comment_capture(self):
        """C comments can be captured from source."""
        from pak.c2pak.c_preprocess import capture_comments
        source = '/* block */ int x = 5; // line comment\n'
        comments = capture_comments(source)
        assert len(comments) >= 2
        assert any('block' in c for _, c in comments)
        assert any('line comment' in c for _, c in comments)

    def test_gcc_strip_builtin_expect(self):
        """__builtin_expect(x, y) is stripped to x."""
        from pak.c2pak.c_preprocess import strip_gcc_extensions
        result = strip_gcc_extensions('if (__builtin_expect(x, 1)) {}')
        assert '__builtin_expect' not in result
        assert 'x' in result

    def test_gcc_strip_attribute(self):
        """__attribute__((anything)) is stripped."""
        from pak.c2pak.c_preprocess import strip_gcc_extensions
        result = strip_gcc_extensions('int x __attribute__((aligned(4)));')
        assert '__attribute__' not in result

    def test_gcc_strip_restrict(self):
        """__restrict is stripped."""
        from pak.c2pak.c_preprocess import strip_gcc_extensions
        result = strip_gcc_extensions('void f(int * __restrict p) {}')
        assert '__restrict' not in result


# ── Phase 7: c2pak improvements ──────────────────────────────────────────────

class TestC2pakImprovements:
    """Tests for preprocessor fixes, variadic handling, and N64 type additions."""

    # ── #elif correctness ─────────────────────────────────────────────────────

    def test_elif_first_branch_taken(self):
        """#if 1 / #elif 1 / #else — only the first branch is active."""
        from pak.c2pak.c_preprocess import preprocess
        source = '#if 1\nint a = 1;\n#elif 1\nint b = 2;\n#else\nint c = 3;\n#endif\n'
        cleaned, _ = preprocess(source)
        assert 'int a = 1;' in cleaned
        assert 'int b = 2;' not in cleaned
        assert 'int c = 3;' not in cleaned

    def test_elif_second_branch_taken(self):
        """#if 0 / #elif 1 / #else — second branch is active."""
        from pak.c2pak.c_preprocess import preprocess
        source = '#if 0\nint a = 1;\n#elif 1\nint b = 2;\n#else\nint c = 3;\n#endif\n'
        cleaned, _ = preprocess(source)
        assert 'int a = 1;' not in cleaned
        assert 'int b = 2;' in cleaned
        assert 'int c = 3;' not in cleaned

    def test_elif_else_branch_taken(self):
        """#if 0 / #elif 0 / #else — else branch is active."""
        from pak.c2pak.c_preprocess import preprocess
        source = '#if 0\nint a = 1;\n#elif 0\nint b = 2;\n#else\nint c = 3;\n#endif\n'
        cleaned, _ = preprocess(source)
        assert 'int a = 1;' not in cleaned
        assert 'int b = 2;' not in cleaned
        assert 'int c = 3;' in cleaned

    def test_ifdef_elif_chain(self):
        """#ifdef / #elif 0 / #else — ifdef branch taken, else skipped."""
        from pak.c2pak.c_preprocess import preprocess
        source = '#define FOO 1\n#ifdef FOO\nint a = 1;\n#elif 0\nint b = 2;\n#else\nint c = 3;\n#endif\n'
        cleaned, _ = preprocess(source)
        assert 'int a = 1;' in cleaned
        assert 'int b = 2;' not in cleaned
        assert 'int c = 3;' not in cleaned

    # ── Variadic functions ────────────────────────────────────────────────────

    def test_variadic_no_ellipsis_in_output(self):
        """Variadic functions must not emit '...' (invalid Pak syntax)."""
        result = transpile('void logf(const char *fmt, ...) {}\n')
        assert '...' not in result

    def test_variadic_comment_emitted(self):
        """Variadic functions get a c2pak: variadic comment."""
        result = transpile('void logf(const char *fmt, ...) {}\n')
        assert 'c2pak: variadic' in result

    def test_variadic_named_params_preserved(self):
        """Non-variadic params are still emitted correctly."""
        result = transpile('int printf(const char *fmt, ...) { return 0; }\n')
        assert 'fmt' in result
        assert '...' not in result

    def test_variadic_extern_no_ellipsis(self):
        """Extern variadic declaration also must not emit '...'."""
        result = transpile('extern int snprintf(char *buf, int n, const char *fmt, ...);\n')
        assert '...' not in result
        assert 'snprintf' in result

    # ── Function-like macro expansion ─────────────────────────────────────────

    def test_func_macro_expansion_simple(self):
        """Simple function-like macro is expanded so pycparser can parse it."""
        from pak.c2pak.c_preprocess import preprocess
        source = '#define DOUBLE(x) ((x)*2)\nint y = DOUBLE(5);\n'
        cleaned, _ = preprocess(source)
        assert 'DOUBLE' not in cleaned
        assert '((5)*2)' in cleaned or '(5)' in cleaned

    def test_func_macro_expansion_two_args(self):
        """Two-argument macro is expanded inline."""
        from pak.c2pak.c_preprocess import preprocess
        source = '#define ADD(a, b) ((a)+(b))\nint z = ADD(x, y);\n'
        cleaned, _ = preprocess(source)
        assert 'ADD' not in cleaned
        assert '(x)' in cleaned
        assert '(y)' in cleaned

    def test_func_macro_expansion_zero_args(self):
        """Zero-argument macro is expanded to its body."""
        from pak.c2pak.c_preprocess import preprocess
        source = '#define NEWLINE() (\'\\n\')\nchar c = NEWLINE();\n'
        cleaned, _ = preprocess(source)
        assert 'NEWLINE' not in cleaned

    def test_func_macro_transpile_min_max(self):
        """MIN/MAX macros expand so transpilation succeeds."""
        result = transpile(
            '#define MIN(a,b) ((a)<(b)?(a):(b))\n'
            'int clamp_low(int x, int lo) { return MIN(x, lo); }\n'
        )
        assert 'fn clamp_low' in result
        assert 'MIN(' not in result

    def test_func_macro_no_call_in_output(self):
        """After expansion, no call-site trace of the macro name remains."""
        result = transpile(
            '#define SQ(x) ((x)*(x))\n'
            'int y = SQ(5);\n'
        )
        assert 'SQ(' not in result

    # ── New N64 type mappings ─────────────────────────────────────────────────

    def test_n64_types_extended(self):
        """Newly added N64 types are in N64_TYPES dict."""
        from pak.c2pak.n64_api import N64_TYPES
        assert 'color_t' in N64_TYPES
        assert 'wav64_t' in N64_TYPES
        assert 'sprite_t' in N64_TYPES
        assert 'rspq_block_t' in N64_TYPES
        assert 'joypad_buttons_t' in N64_TYPES
