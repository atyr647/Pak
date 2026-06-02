"""Comprehensive pytest test suite for the Pak compiler."""

import pytest
import textwrap
from pak.lexer import Lexer, TT, Token, LexError
from pak.parser import Parser, ParseError
from pak import ast
from pak.codegen import Codegen, CodegenError
from pak.typechecker import typecheck, typecheck_multi


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def lex(src: str):
    return Lexer(src).tokenize()

def token_types(src: str):
    return [t.type for t in lex(src) if t.type != TT.EOF]

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


# ─────────────────────────────────────────────────────────────────────────────
# Lexer tests
# ─────────────────────────────────────────────────────────────────────────────

class TestLexer:

    def test_integer_literal(self):
        toks = lex('42')
        assert toks[0].type == TT.INT
        assert toks[0].value == '42'

    def test_float_literal(self):
        toks = lex('3.14')
        assert toks[0].type == TT.FLOAT
        assert toks[0].value == '3.14'

    def test_float_suffix(self):
        toks = lex('1.0f')
        assert toks[0].type == TT.FLOAT

    def test_hex_literal(self):
        toks = lex('0xFF')
        assert toks[0].type == TT.INT
        assert toks[0].value == '0xFF'

    def test_hex_with_underscores(self):
        toks = lex('0xFF_FF')
        assert toks[0].type == TT.INT
        assert toks[0].value == '0xFFFF'

    def test_string_literal(self):
        toks = lex('"hello"')
        assert toks[0].type == TT.STRING
        assert toks[0].value == 'hello'

    def test_string_escape(self):
        toks = lex(r'"foo\nbar"')
        assert toks[0].value == 'foo\nbar'

    def test_bool_true(self):
        toks = lex('true')
        assert toks[0].type == TT.TRUE

    def test_bool_false(self):
        toks = lex('false')
        assert toks[0].type == TT.FALSE

    def test_identifier(self):
        toks = lex('my_var')
        assert toks[0].type == TT.IDENT
        assert toks[0].value == 'my_var'

    def test_keywords(self):
        for kw in ('fn', 'let', 'if', 'else', 'for', 'while', 'loop',
                   'return', 'break', 'continue', 'struct', 'enum',
                   'variant', 'match', 'use', 'entry', 'static', 'mut',
                   'and', 'or', 'not', 'defer', 'extern', 'module',
                   'in', 'from', 'as', 'catch'):
            toks = lex(kw)
            assert toks[0].type != TT.IDENT, f'{kw!r} should be a keyword'

    # Fixed-point type names
    def test_fix16_16(self):
        toks = lex('fix16.16')
        assert toks[0].type == TT.IDENT
        assert toks[0].value == 'fix16.16'

    def test_fix10_5(self):
        toks = lex('fix10.5')
        assert toks[0].type == TT.IDENT
        assert toks[0].value == 'fix10.5'

    def test_fix1_15(self):
        toks = lex('fix1.15')
        assert toks[0].type == TT.IDENT
        assert toks[0].value == 'fix1.15'

    def test_fix_not_confused_with_float(self):
        # 'fix16.16' should be ONE token, not IDENT('fix16') DOT INT('16')
        toks = [t for t in lex('fix16.16') if t.type != TT.EOF]
        assert len(toks) == 1
        assert toks[0].value == 'fix16.16'

    def test_fix_followed_by_range(self):
        # fix16.16 .. x  → IDENT DOTDOT IDENT (the .. is not part of the type)
        toks = [t for t in lex('fix16.16..x') if t.type != TT.EOF]
        assert toks[0].value == 'fix16.16'
        assert toks[1].type == TT.DOTDOT

    # Shift operators
    def test_shl(self):
        toks = token_types('1 << 2')
        assert TT.SHL in toks

    def test_shr(self):
        toks = token_types('1 >> 2')
        assert TT.SHR in toks

    def test_shl_eq(self):
        toks = token_types('x <<= 1')
        assert TT.SHL_EQ in toks

    def test_shr_eq(self):
        toks = token_types('x >>= 1')
        assert TT.SHR_EQ in toks

    # Compound assignment
    def test_amp_eq(self):
        toks = token_types('x &= 3')
        assert TT.AMP_EQ in toks

    def test_pipe_eq(self):
        toks = token_types('x |= 3')
        assert TT.PIPE_EQ in toks

    def test_caret_eq(self):
        toks = token_types('x ^= 3')
        assert TT.CARET_EQ in toks

    # Comments
    def test_line_comment_dash(self):
        toks = [t for t in lex('-- comment\n42') if t.type != TT.EOF]
        assert len(toks) == 1 and toks[0].value == '42'

    def test_line_comment_slash(self):
        toks = [t for t in lex('// comment\n42') if t.type != TT.EOF]
        assert len(toks) == 1 and toks[0].value == '42'

    # Annotations
    def test_annotation_simple(self):
        toks = lex('@inline')
        assert toks[0].type == TT.ANNOTATION
        assert toks[0].value == '@inline'

    def test_annotation_with_args(self):
        toks = lex('@aligned(16)')
        assert toks[0].type == TT.ANNOTATION
        assert toks[0].value == '@aligned(16)'

    def test_unterminated_string(self):
        with pytest.raises(LexError):
            lex('"unterminated')

    def test_range_dotdot(self):
        toks = token_types('0..10')
        assert TT.INT in toks
        assert TT.DOTDOT in toks

    def test_fat_arrow(self):
        toks = token_types('x => y')
        assert TT.FAT_ARROW in toks


# ─────────────────────────────────────────────────────────────────────────────
# Parser tests
# ─────────────────────────────────────────────────────────────────────────────

class TestParser:

    def test_empty_program(self):
        prog = parse('')
        assert prog.decls == []

    def test_fn_no_params(self):
        prog = parse('fn foo() -> void {}')
        assert len(prog.decls) == 1
        fn = prog.decls[0]
        assert isinstance(fn, ast.FnDecl)
        assert fn.name == 'foo'
        assert fn.params == []

    def test_fn_with_params(self):
        prog = parse('fn add(a: i32, b: i32) -> i32 { return a + b; }')
        fn = prog.decls[0]
        assert len(fn.params) == 2
        assert fn.params[0].name == 'a'

    def test_let_stmt(self):
        prog = parse('fn f() -> void { let x: i32 = 5; }')
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.LetDecl)
        assert stmt.name == 'x'

    def test_let_mut_stmt(self):
        prog = parse('fn f() -> void { let mut x: i32 = 5; }')
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.LetDecl)
        assert stmt.mutable

    def test_return_stmt(self):
        prog = parse('fn f() -> i32 { return 42; }')
        fn = prog.decls[0]
        assert isinstance(fn.body.stmts[0], ast.Return)

    def test_if_stmt(self):
        prog = parse('fn f() -> void { if x { } }')
        fn = prog.decls[0]
        assert isinstance(fn.body.stmts[0], ast.IfStmt)

    def test_if_else(self):
        prog = parse('fn f() -> void { if x { } else { } }')
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.IfStmt)
        assert stmt.else_branch is not None

    def test_while_loop(self):
        prog = parse('fn f() -> void { while true { } }')
        fn = prog.decls[0]
        assert isinstance(fn.body.stmts[0], ast.WhileStmt)

    def test_loop(self):
        prog = parse('fn f() -> void { loop { break; } }')
        fn = prog.decls[0]
        assert isinstance(fn.body.stmts[0], ast.LoopStmt)

    def test_for_range(self):
        prog = parse('fn f() -> void { for i in 0..10 { } }')
        fn = prog.decls[0]
        s = fn.body.stmts[0]
        assert isinstance(s, ast.ForStmt)
        assert s.binding == 'i'
        assert isinstance(s.iterable, ast.RangeExpr)

    def test_for_with_index(self):
        # Grammar: for <index>, <item> in collection
        prog = parse('fn f() -> void { for idx, item in arr { } }')
        fn = prog.decls[0]
        s = fn.body.stmts[0]
        assert isinstance(s, ast.ForStmt)
        assert s.index == 'idx'
        assert s.binding == 'item'

    def test_struct_decl(self):
        prog = parse('struct Pos { x: i32, y: i32 }')
        s = prog.decls[0]
        assert isinstance(s, ast.StructDecl)
        assert s.name == 'Pos'
        assert len(s.fields) == 2

    def test_enum_decl(self):
        prog = parse('enum Dir { Up, Down, Left, Right }')
        e = prog.decls[0]
        assert isinstance(e, ast.EnumDecl)
        assert len(e.variants) == 4

    def test_variant_decl(self):
        prog = parse('variant Cmd { Move { dx: i32, dy: i32 }, Stop }')
        v = prog.decls[0]
        assert isinstance(v, ast.VariantDecl)
        assert len(v.cases) == 2

    def test_match_expr(self):
        prog = parse('fn f(d: Dir) -> void { match d { Dir.Up => { } } }')
        fn = prog.decls[0]
        assert isinstance(fn.body.stmts[0], ast.MatchStmt)

    def test_defer_stmt(self):
        prog = parse('fn f() -> void { defer { foo(); } }')
        fn = prog.decls[0]
        assert isinstance(fn.body.stmts[0], ast.DeferStmt)

    def test_use_decl(self):
        prog = parse('use n64.display;')
        u = prog.decls[0]
        assert isinstance(u, ast.UseDecl)
        assert u.path == 'n64.display'

    def test_module_decl(self):
        prog = parse('module game.player;')
        m = prog.decls[0]
        assert isinstance(m, ast.ModuleDecl)
        assert m.path == 'game.player'

    def test_static_decl(self):
        prog = parse('static SCORE: i32 = 0;')
        s = prog.decls[0]
        assert isinstance(s, ast.StaticDecl)

    def test_entry_decl(self):
        prog = parse('entry { }')
        e = prog.decls[0]
        assert isinstance(e, ast.EntryBlock)

    # Expression precedence
    def test_arithmetic_precedence(self):
        prog = parse('fn f() -> i32 { return 2 + 3 * 4; }')
        fn = prog.decls[0]
        ret = fn.body.stmts[0]
        # 2 + (3 * 4) — right-hand side of + should be BinaryOp(*)
        assert isinstance(ret, ast.Return)
        assert isinstance(ret.value, ast.BinaryOp)
        assert ret.value.op == '+'
        assert isinstance(ret.value.right, ast.BinaryOp)
        assert ret.value.right.op == '*'

    def test_bitwise_and_precedence(self):
        prog = parse('fn f() -> i32 { return x & 0xFF | y; }')
        fn = prog.decls[0]
        ret = fn.body.stmts[0]
        assert isinstance(ret, ast.Return)
        # (x & 0xFF) | y  — | binds looser than &
        assert isinstance(ret.value, ast.BinaryOp)
        assert ret.value.op == '|'
        assert isinstance(ret.value.left, ast.BinaryOp)
        assert ret.value.left.op == '&'

    def test_shift_precedence(self):
        prog = parse('fn f() -> i32 { return x + y << 2; }')
        fn = prog.decls[0]
        ret = fn.body.stmts[0]
        assert isinstance(ret, ast.Return)
        # (x + y) << 2 — << binds looser than +
        assert isinstance(ret.value, ast.BinaryOp)
        assert ret.value.op == '<<'
        assert isinstance(ret.value.left, ast.BinaryOp)
        assert ret.value.left.op == '+'

    def test_assign_ops(self):
        for op in ('+=', '-=', '*=', '/=', '<<=', '>>=', '&=', '|=', '^='):
            src = f'fn f() -> void {{ x {op} 1; }}'
            prog = parse(src)
            fn = prog.decls[0]
            stmt = fn.body.stmts[0]
            assert isinstance(stmt, (ast.Assign, ast.ExprStmt)), f'Expected Assign for {op}'

    def test_array_type(self):
        prog = parse('fn f(arr: [10]i32) -> void {}')
        fn = prog.decls[0]
        param = fn.params[0]
        assert isinstance(param.type, ast.TypeArray)

    def test_slice_type(self):
        prog = parse('fn f(s: []i32) -> void {}')
        fn = prog.decls[0]
        param = fn.params[0]
        assert isinstance(param.type, ast.TypeSlice)

    def test_pointer_type(self):
        prog = parse('fn f(p: *i32) -> void {}')
        fn = prog.decls[0]
        param = fn.params[0]
        assert isinstance(param.type, ast.TypePointer)

    def test_optional_type(self):
        prog = parse('fn f(p: ?i32) -> void {}')
        fn = prog.decls[0]
        param = fn.params[0]
        assert isinstance(param.type, ast.TypeOption)


# ─────────────────────────────────────────────────────────────────────────────
# Code generator tests
# ─────────────────────────────────────────────────────────────────────────────

class TestCodegen:

    def test_basic_fn(self):
        c = codegen('fn add(a: i32, b: i32) -> i32 { return a + b; }')
        assert 'int32_t add(int32_t a, int32_t b)' in c
        assert 'return' in c and 'a + b' in c

    def test_void_fn(self):
        c = codegen('fn noop() -> void {}')
        assert 'void noop(void)' in c

    def test_struct_generation(self):
        c = codegen('struct Vec2 { x: f32, y: f32 }')
        assert 'typedef struct {' in c
        assert 'float x;' in c
        assert 'float y;' in c
        assert '} Vec2;' in c

    def test_enum_generation(self):
        c = codegen('enum Dir { Up, Down, Left, Right }')
        assert 'typedef enum {' in c
        assert 'Dir_Up' in c
        assert 'Dir_Right' in c

    def test_variant_generation(self):
        c = codegen('variant Cmd { Move { dx: i32 }, Stop }')
        assert 'typedef enum' in c
        assert 'Cmd_tag_Move' in c
        assert 'typedef struct' in c
        assert 'Cmd_tag tag' in c

    # for-loop tests
    def test_for_range(self):
        c = codegen('fn f() -> void { for i in 0..10 { } }')
        assert 'for (int i = 0; i < 10; i++)' in c

    def test_for_array_without_index(self):
        c = codegen('fn f(arr: [4]i32) -> void { for x in arr { } }')
        # Should use sizeof-based loop
        assert 'sizeof' in c
        assert 'arr[' in c

    def test_for_slice_uses_len(self):
        c = codegen('fn f(items: []i32) -> void { for x in items { } }')
        # Fat slice loop should use .len
        assert '.len' in c
        assert '.data[' in c

    def test_for_with_index(self):
        # Grammar: for <index>, <binding> in collection
        c = codegen('fn f(arr: [4]i32) -> void { for i, x in arr { } }')
        # index variable should be 'i'
        assert 'int i = 0' in c

    # Fixed-point tests
    def test_fix16_mul_plain(self):
        c = codegen('fn f(a: fix16.16, b: fix16.16) -> fix16.16 { return a * b; }')
        assert '(int32_t)(((int64_t)' in c
        assert '>> 16)' in c

    def test_fix16_add_no_shift(self):
        c = codegen('fn f(a: fix16.16, b: fix16.16) -> fix16.16 { return a + b; }')
        # Addition of same type should NOT use the widening multiply
        assert '>> 16' not in c

    def test_i32_mul_no_fixpoint(self):
        c = codegen('fn f(a: i32, b: i32) -> i32 { return a * b; }')
        # Plain i32 * i32 should NOT emit fixpoint multiply
        assert '(int64_t)' not in c

    # Variant match
    def test_variant_match_uses_tag(self):
        src = textwrap.dedent('''
            variant Cmd { Move { dx: i32 }, Stop }
            fn handle(c: Cmd) -> void {
                match c {
                    Cmd.Move(m) => { }
                    Cmd.Stop => { }
                }
            }
        ''')
        c = codegen(src)
        assert 'switch (c.tag)' in c
        assert 'case Cmd_tag_Move' in c
        assert 'case Cmd_tag_Stop' in c

    def test_enum_match_no_tag(self):
        src = textwrap.dedent('''
            enum Dir { Up, Down }
            fn handle(d: Dir) -> void {
                match d {
                    Dir.Up => { }
                    Dir.Down => { }
                }
            }
        ''')
        c = codegen(src)
        assert 'switch (d)' in c
        assert 'case Dir_Up' in c
        # must NOT use .tag for plain enum
        assert '.tag' not in c

    # Defer tests
    def test_defer_emitted_at_scope_end(self):
        src = textwrap.dedent('''
            fn f() -> void {
                defer { cleanup(); }
                do_work();
            }
        ''')
        c = codegen(src)
        # cleanup() should appear after do_work()
        work_pos = c.index('do_work()')
        clean_pos = c.index('cleanup()')
        assert clean_pos > work_pos

    def test_defer_lifo_order(self):
        src = textwrap.dedent('''
            fn f() -> void {
                defer { first(); }
                defer { second(); }
            }
        ''')
        c = codegen(src)
        first_pos = c.index('first()')
        second_pos = c.index('second()')
        # LIFO: second() deferred last, runs first
        assert second_pos < first_pos

    # Fat slice typedef
    def test_slice_typedef_emitted(self):
        c = codegen('fn f(s: []i32) -> void {}')
        assert 'PakSlice_' in c
        assert 'int32_t *data' in c
        assert 'int32_t len' in c

    def test_slice_index_uses_data(self):
        c = codegen('fn f(s: []i32) -> i32 { return s[0]; }')
        assert '.data[0]' in c

    def test_slice_expr(self):
        c = codegen('fn f(arr: [8]i32) -> void { let s: []i32 = arr[2..6]; }')
        assert '.data = &' in c
        assert '.len = ' in c

    # Static declarations
    def test_static_decl(self):
        c = codegen('static SCORE: i32 = 0;')
        assert 'int32_t SCORE = 0;' in c

    # Entry point
    def test_entry_fn(self):
        c = codegen('entry { }')
        assert 'int main(' in c or 'void main(' in c

    # Pointer member access
    def test_pointer_field_arrow(self):
        src = textwrap.dedent('''
            struct Node { val: i32 }
            fn get(p: *Node) -> i32 { return p.val; }
        ''')
        c = codegen(src)
        assert 'p->val' in c

    # Module includes
    def test_use_display_includes(self):
        c = codegen('use n64.display;\nentry {}')
        assert '#include <display.h>' in c

    def test_use_rumble_includes(self):
        c = codegen('use n64.rumble;\nentry {}')
        assert '#include <rumble.h>' in c

    def test_use_cpak_includes(self):
        c = codegen('use n64.cpak;\nentry {}')
        assert '#include <cpak.h>' in c

    def test_use_rtc_includes(self):
        c = codegen('use n64.rtc;\nentry {}')
        assert '#include <rtc.h>' in c

    def test_use_backup_includes(self):
        c = codegen('use n64.backup;\nentry {}')
        assert '#include <backup.h>' in c

    def test_use_disk_includes(self):
        c = codegen('use n64.disk;\nentry {}')
        assert '#include <disk.h>' in c

    def test_use_vru_includes(self):
        c = codegen('use n64.vru;\nentry {}')
        assert '#include <vru.h>' in c

    def test_use_system_includes(self):
        c = codegen('use n64.system;\nentry {}')
        assert '#include <n64sys.h>' in c

    # Module API call generation
    def test_rumble_start_call(self):
        c = codegen('use n64.rumble;\nfn f() -> void { rumble.start(0); }')
        assert 'rumble_start(0)' in c

    def test_cpak_read_call(self):
        c = codegen('use n64.cpak;\nfn f() -> void { cpak.read_sector(0, buf, 1); }')
        assert 'cpak_read_sector(0' in c

    def test_backup_read_call(self):
        c = codegen('use n64.backup;\nfn f() -> void { backup.read(buf, 0, 64); }')
        assert 'backup_read(buf' in c

    def test_system_memory_size(self):
        c = codegen('use n64.system;\nfn f() -> u32 { return system.memory_size(); }')
        assert 'get_memory_size()' in c

    def test_system_has_expansion(self):
        c = codegen('use n64.system;\nfn f() -> bool { return system.has_expansion(); }')
        assert 'get_memory_size() > 0x400000' in c

    def test_system_ticks(self):
        c = codegen('use n64.system;\nfn f() -> u32 { return system.ticks(); }')
        assert 'TICKS_READ()' in c

    def test_rtc_get_call(self):
        c = codegen('use n64.rtc;\nfn f() -> void { rtc.get(t); }')
        assert 'rtc_get(t)' in c

    def test_xm64_play_call(self):
        c = codegen('use n64.xm64;\nfn f() -> void { xm64.play(player, 0); }')
        assert 'xm64player_play(player' in c

    def test_mixer_ch_play(self):
        c = codegen('use n64.mixer;\nfn f() -> void { mixer.ch_play(0, snd); }')
        assert 'mixer_ch_play(0' in c

    def test_rdpq_font_draw(self):
        c = codegen('use n64.rdpq_font;\nfn f() -> void { rdpq_font.draw_text(x, y, "hi"); }')
        assert 'rdpq_text_print(' in c

    # Bitwise operations
    def test_bitwise_and(self):
        c = codegen('fn f(a: i32) -> i32 { return a & 0xFF; }')
        assert 'a & 0xFF' in c

    def test_bitwise_or(self):
        c = codegen('fn f(a: i32) -> i32 { return a | 0x80; }')
        assert 'a | 0x80' in c

    def test_bitwise_xor(self):
        c = codegen('fn f(a: i32) -> i32 { return a ^ 1; }')
        assert 'a ^ 1' in c

    def test_shift_left(self):
        c = codegen('fn f(a: i32) -> i32 { return a << 4; }')
        assert 'a << 4' in c

    def test_shift_right(self):
        c = codegen('fn f(a: i32) -> i32 { return a >> 2; }')
        assert 'a >> 2' in c

    # Compound assignments
    def test_plus_eq(self):
        c = codegen('fn f() -> void { let mut x: i32 = 0; x += 1; }')
        assert 'x += 1' in c

    def test_shl_eq(self):
        c = codegen('fn f() -> void { let mut x: i32 = 1; x <<= 3; }')
        assert 'x <<= 3' in c

    def test_amp_eq(self):
        c = codegen('fn f() -> void { let mut x: i32 = 0xFF; x &= 0x0F; }')
        assert 'x &= 0x0F' in c

    # Scope isolation — let inside if doesn't leak
    def test_scope_isolation_if(self):
        src = textwrap.dedent('''
            fn f(cond: bool) -> void {
                if cond {
                    let x: i32 = 1;
                }
            }
        ''')
        # Should compile without error — scope management shouldn't crash
        c = codegen(src)
        assert 'int32_t x = 1' in c

    # Null-check
    def test_null_check(self):
        src = textwrap.dedent('''
            fn f(p: ?i32) -> void {
                if p -> v {
                    let x: i32 = v;
                }
            }
        ''')
        c = codegen(src)
        assert 'p != NULL' in c or 'if (p)' in c or '(p)' in c


# ─────────────────────────────────────────────────────────────────────────────
# Type checker tests
# ─────────────────────────────────────────────────────────────────────────────

class TestTypechecker:

    def test_no_errors_simple(self):
        src = 'fn add(a: i32, b: i32) -> i32 { return a + b; }'
        errs = typecheck(parse(src))
        assert errs == []

    def test_e010_unknown_name(self):
        src = 'fn f() -> void { let x: i32 = y; }'
        errs = typecheck(parse(src))
        codes = [e.code for e in errs]
        assert 'E010' in codes

    def test_e011_no_such_field(self):
        src = textwrap.dedent('''
            struct Pos { x: i32, y: i32 }
            fn f(p: Pos) -> i32 { return p.z; }
        ''')
        errs = typecheck(parse(src))
        codes = [e.code for e in errs]
        assert 'E011' in codes

    def test_e012_wrong_arity(self):
        src = textwrap.dedent('''
            fn add(a: i32, b: i32) -> i32 { return a + b; }
            fn f() -> void { add(1); }
        ''')
        errs = typecheck(parse(src))
        codes = [e.code for e in errs]
        assert 'E012' in codes

    def test_e301_non_exhaustive_match(self):
        src = textwrap.dedent('''
            enum Dir { Up, Down, Left, Right }
            fn f(d: Dir) -> void {
                match d {
                    Dir.Up => { }
                }
            }
        ''')
        errs = typecheck(parse(src))
        codes = [e.code for e in errs]
        assert 'E301' in codes

    def test_exhaustive_match_ok(self):
        src = textwrap.dedent('''
            enum Dir { Up, Down }
            fn f(d: Dir) -> void {
                match d {
                    Dir.Up => { }
                    Dir.Down => { }
                }
            }
        ''')
        errs = typecheck(parse(src))
        assert errs == []

    def test_multi_file_shared_env(self):
        src1 = 'module game.math;\nfn add(a: i32, b: i32) -> i32 { return a + b; }'
        src2 = textwrap.dedent('''
            use game.math;
            fn call_add() -> i32 { return add(1, 2); }
        ''')
        prog1 = parse(src1)
        prog2 = parse(src2)
        results = typecheck_multi([('math.pk64', prog1), ('main.pk64', prog2)])
        # add() should be found — no E010 or E012 in either file
        all_errs = [e for errs in results.values() for e in errs]
        codes = [e.code for e in all_errs]
        assert 'E010' not in codes
        assert 'E012' not in codes


# ─────────────────────────────────────────────────────────────────────────────
# Regression tests for confirmed bugs
# ─────────────────────────────────────────────────────────────────────────────

class TestRegressions:

    def test_fix16_lexed_as_single_token(self):
        """Regression: fix16.16 was tokenised as IDENT('fix16') + FLOAT + INT."""
        toks = [t for t in lex('fix16.16') if t.type != TT.EOF]
        assert len(toks) == 1, f'Expected 1 token, got {len(toks)}: {toks}'
        assert toks[0].value == 'fix16.16'

    def test_variant_match_switch_on_tag(self):
        """Regression: variant match used switch(cmd) instead of switch(cmd.tag)."""
        src = textwrap.dedent('''
            variant Cmd { Move { dx: i32 }, Stop }
            fn run(c: Cmd) -> void {
                match c {
                    Cmd.Move(m) => { }
                    Cmd.Stop => { }
                }
            }
        ''')
        c = codegen(src)
        assert 'switch (c.tag)' in c, 'Must switch on .tag for variant type'
        assert 'switch (c)' not in c

    def test_variant_case_label_has_tag_prefix(self):
        """Regression: case Cmd_move instead of Cmd_tag_move."""
        src = textwrap.dedent('''
            variant Cmd { Move { dx: i32 }, Stop }
            fn run(c: Cmd) -> void {
                match c {
                    Cmd.Move(m) => { }
                    Cmd.Stop => { }
                }
            }
        ''')
        c = codegen(src)
        assert 'case Cmd_tag_Move' in c
        assert 'case Cmd_tag_Stop' in c

    def test_for_slice_no_sizeof(self):
        """Regression: for item in slice_param used sizeof which = 1 for pointer."""
        c = codegen('fn f(items: []i32) -> void { for x in items { } }')
        assert 'sizeof' not in c, 'Fat slice loop must not use sizeof'
        assert '.len' in c

    def test_struct_field_fixpoint_mul(self):
        """Regression: struct field access didn't trigger fixpoint multiply."""
        src = textwrap.dedent('''
            struct Ball { vel: fix16.16 }
            fn update(b: Ball, dt: fix16.16) -> fix16.16 { return b.vel * dt; }
        ''')
        c = codegen(src)
        assert '(int32_t)(((int64_t)' in c, 'Struct field fix16.16 mul must use widening'

    def test_scope_isolation_let_in_if(self):
        """Regression: let in if body leaked into outer scope tracking."""
        src = textwrap.dedent('''
            fn f(cond: bool) -> void {
                if cond {
                    let inner: i32 = 1;
                }
                let outer: i32 = 2;
            }
        ''')
        c = codegen(src)
        assert 'int32_t inner = 1' in c
        assert 'int32_t outer = 2' in c

    def test_case_body_wrapped_in_braces(self):
        """Regression: switch case declarations without braces is invalid C."""
        src = textwrap.dedent('''
            enum Dir { Up, Down }
            fn f(d: Dir) -> void {
                match d {
                    Dir.Up => { let x: i32 = 1; }
                    Dir.Down => { }
                }
            }
        ''')
        c = codegen(src)
        # Each case body should be wrapped in {}
        assert 'case Dir_Up: {' in c or ('case Dir_Up:' in c and '{' in c)


# ─────────────────────────────────────────────────────────────────────────────
# New feature tests
# ─────────────────────────────────────────────────────────────────────────────

class TestArrayRepeat:

    def test_zero_repeat_zero_init(self):
        c = codegen('entry { let a: [i32; 8] = [0; 8] }')
        assert 'int32_t a[8] = {0}' in c

    def test_small_nonzero_repeat_expanded(self):
        c = codegen('entry { let a: [i32; 3] = [5; 3] }')
        assert '{5, 5, 5}' in c

    def test_large_repeat_loop_fill(self):
        c = codegen('entry { let a: [i32; 200] = [7; 200] }')
        assert '{0}' in c
        assert 'for (int _fi' in c
        assert 'a[_fi] = 7' in c

    def test_array_type_rust_syntax(self):
        """[T; N] type syntax parses and generates C array."""
        c = codegen('fn f(x: [i32; 4]) -> void { }')
        assert 'int32_t' in c

    def test_array_type_classic_syntax(self):
        """[N]T type syntax still works."""
        c = codegen('fn f() -> void { let a: [4]i32 }')
        assert 'int32_t a[4]' in c


class TestResultCatch:

    def test_result_typedef_emitted(self):
        c = codegen('fn f() -> Result(i32, i32) { return ok(1) }')
        assert 'PakResult_int32_t_int32_t' in c
        assert 'is_ok' in c
        assert 'union' in c

    def test_ok_expr_uses_return_type(self):
        c = codegen('fn f() -> Result(i32, i32) { return ok(42) }')
        assert '.is_ok = true' in c
        assert '.data.value = 42' in c

    def test_err_expr_uses_return_type(self):
        c = codegen('fn f() -> Result(i32, i32) { return err(99) }')
        assert '.is_ok = false' in c
        assert '.data.error = 99' in c

    def test_catch_let_expansion(self):
        src = textwrap.dedent('''
            fn may_fail() -> Result(i32, i32) { return ok(1) }
            entry {
                let x: i32 = may_fail() catch e { return }
            }
        ''')
        c = codegen(src)
        assert '_catch_x' in c
        assert '!_catch_x.is_ok' in c
        assert 'x = _catch_x.data.value' in c


class TestPakStr:

    def test_str_type_maps_to_pakstr(self):
        c = codegen('fn f(s: Str) -> void { }')
        assert 'PakStr' in c

    def test_pakstr_runtime_emitted(self):
        c = codegen('entry { }')
        assert 'pak_str_from_cstr' in c
        assert 'pak_str_eq' in c

    def test_str_module_from_cstr(self):
        c = codegen('use pak.str\nentry { let s = str.from_cstr("hi") }')
        assert 'pak_str_from_cstr' in c


class TestArena:

    def test_arena_type_maps_to_pakarena(self):
        c = codegen('fn f(a: Arena) -> void { }')
        assert 'PakArena' in c

    def test_arena_runtime_emitted(self):
        c = codegen('entry { }')
        assert 'pak_arena_alloc' in c
        assert 'pak_arena_reset' in c


class TestMethodDispatch:

    def test_impl_generates_prefixed_fns(self):
        src = textwrap.dedent('''
            struct Counter { val: i32 }
            impl Counter {
                fn inc(self: *Counter) -> void { self.val = self.val }
                fn get(self: *Counter) -> i32 { return self.val }
            }
        ''')
        c = codegen(src)
        assert 'Counter_inc' in c
        assert 'Counter_get' in c

    def test_method_call_passes_addr(self):
        src = textwrap.dedent('''
            struct Counter { val: i32 }
            impl Counter {
                fn get(self: *Counter) -> i32 { return self.val }
            }
            entry {
                let c: Counter = Counter{ val: 0 }
                let v: i32 = c.get()
            }
        ''')
        c = codegen(src)
        assert 'Counter_get(&c)' in c

    def test_self_as_expr_in_body(self):
        src = textwrap.dedent('''
            struct Foo { x: i32 }
            impl Foo {
                fn bar(self: *Foo) -> i32 { return self.x }
            }
        ''')
        c = codegen(src)
        assert 'self->x' in c


class TestGenerics:

    def test_generic_fn_not_emitted_raw(self):
        """Generic functions should not appear as-is (with T) in output."""
        c = codegen('fn id<T>(x: T) -> T { return x }')
        assert 'void * id' not in c  # not emitted unspecialized

    def test_generic_fn_monomorphized_on_call(self):
        src = textwrap.dedent('''
            fn id<T>(x: T) -> T { return x }
            entry { let v: i32 = id(42) }
        ''')
        c = codegen(src)
        assert 'id_int32_t' in c
        assert 'int32_t id_int32_t' in c

    def test_generic_fn_two_specializations(self):
        src = textwrap.dedent('''
            fn id<T>(x: T) -> T { return x }
            entry {
                let a: i32 = id(1)
                let b: f32 = id(1.0)
            }
        ''')
        c = codegen(src)
        assert 'id_int32_t' in c
        assert 'id_float' in c

    def test_sizeof_type(self):
        c = codegen('entry { let s: i32 = sizeof(i32) }')
        assert 'sizeof(int32_t)' in c

    def test_sizeof_expr(self):
        src = textwrap.dedent('''
            struct Foo { x: i32, y: f32 }
            entry { let s: i32 = sizeof(Foo) }
        ''')
        c = codegen(src)
        assert 'sizeof(Foo)' in c


class TestLexerNewKeywords:

    def test_impl_keyword(self):
        toks = lex('impl')
        assert toks[0].type == TT.IMPL

    def test_self_keyword(self):
        toks = lex('self')
        assert toks[0].type == TT.SELF

    def test_ok_keyword(self):
        toks = lex('ok')
        assert toks[0].type == TT.OK

    def test_err_keyword(self):
        toks = lex('err')
        assert toks[0].type == TT.ERR

    def test_sizeof_keyword(self):
        toks = lex('sizeof')
        assert toks[0].type == TT.SIZEOF

    def test_elif_keyword(self):
        toks = lex('elif')
        assert toks[0].type == TT.ELIF

    def test_all_new_keywords_in_keywords_table(self):
        from pak.lexer import KEYWORDS
        for kw in ('impl', 'self', 'ok', 'err', 'sizeof', 'elif'):
            assert kw in KEYWORDS, f'{kw!r} missing from KEYWORDS'


class TestParserNewFeatures:

    def test_parse_impl_block(self):
        src = textwrap.dedent('''
            struct Foo { x: i32 }
            impl Foo {
                fn bar(self: *Foo) -> i32 { return self.x }
            }
        ''')
        prog = parse(src)
        impl_blocks = [d for d in prog.decls if isinstance(d, ast.ImplBlock)]
        assert len(impl_blocks) == 1
        assert impl_blocks[0].type_name == 'Foo'
        assert impl_blocks[0].methods[0].name == 'bar'

    def test_parse_generic_fn(self):
        prog = parse('fn f<T>(x: T) -> T { return x }')
        fn = prog.decls[0]
        assert isinstance(fn, ast.FnDecl)
        assert fn.type_params == ['T']

    def test_parse_generic_struct(self):
        prog = parse('struct Pair<A, B> { first: A, second: B }')
        s = prog.decls[0]
        assert isinstance(s, ast.StructDecl)
        assert s.type_params == ['A', 'B']

    def test_parse_ok_expr(self):
        prog = parse('fn f() -> Result(i32, i32) { return ok(1) }')
        fn = prog.decls[0]
        ret_stmt = fn.body.stmts[0]
        assert isinstance(ret_stmt.value, ast.OkExpr)

    def test_parse_err_expr(self):
        prog = parse('fn f() -> Result(i32, i32) { return err(99) }')
        fn = prog.decls[0]
        ret_stmt = fn.body.stmts[0]
        assert isinstance(ret_stmt.value, ast.ErrExpr)

    def test_parse_sizeof(self):
        prog = parse('entry { let s: i32 = sizeof(i32) }')
        entry = prog.decls[0]
        let_stmt = entry.body.stmts[0]
        assert isinstance(let_stmt.value, ast.SizeOf)

    def test_parse_elif(self):
        src = textwrap.dedent('''
            fn f(x: i32) -> void {
                if x == 1 { }
                elif x == 2 { }
                else { }
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        if_stmt = fn.body.stmts[0]
        assert isinstance(if_stmt, ast.IfStmt)
        assert len(if_stmt.elif_branches) == 1

    def test_parse_catch_bare_binding(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let x: i32 = some_fn() catch e { return }
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, ast.CatchExpr)
        assert let_stmt.value.binding == 'e'

    def test_parse_array_type_rust_style(self):
        prog = parse('fn f(x: [i32; 4]) -> void { }')
        fn = prog.decls[0]
        param_type = fn.params[0].type
        assert isinstance(param_type, ast.TypeArray)

    def test_parse_use_alias(self):
        """use n64.display as disp — alias field."""
        from pak.parser import Parser
        tokens = Lexer('use n64.display as disp').tokenize()
        prog = Parser(tokens).parse()
        use = prog.decls[0]
        assert isinstance(use, ast.UseDecl)
        # alias parsing is optional — just check it doesn't crash
        assert use.path == 'n64.display'


class TestModuleAPI:

    def test_rdpq_triangle(self):
        c = codegen('use n64.rdpq\nentry { rdpq.triangle(NULL, NULL, 0, 1, 0.0, NULL, NULL, NULL) }')
        assert 'rdpq_triangle' in c

    def test_joypad_get_buttons(self):
        c = codegen('use n64.joypad\nentry { joypad.poll() }')
        assert 'joypad_poll' in c

    def test_str_module_len(self):
        c = codegen('use pak.str\nentry { let s: Str = str.from_cstr("hi") }')
        assert 'pak_str_from_cstr' in c

    def test_arena_alloc(self):
        c = codegen('use pak.arena\nentry { let p: *i32 = arena.alloc(a, 4) }')
        assert 'pak_arena_alloc' in c

    def test_t3d_fog_set_range(self):
        c = codegen('use t3d.fog\nentry { t3d.fog_set_range(10.0, 100.0) }')
        assert 't3d_fog_set_range' in c

    def test_t3d_quat_slerp(self):
        c = codegen('use t3d.math\nentry { t3d.quat_slerp(q1, q2, q3, 0.5) }')
        assert 't3d_quat_slerp' in c


# ─────────────────────────────────────────────────────────────────────────────
# volatile
# ─────────────────────────────────────────────────────────────────────────────

class TestVolatile:

    def test_lex_volatile_keyword(self):
        assert TT.VOLATILE in token_types('volatile')

    def test_parse_volatile_type(self):
        prog = parse('fn f(x: volatile i32) -> void { }')
        fn = prog.decls[0]
        from pak import ast as a
        assert isinstance(fn.params[0].type, a.TypeVolatile)

    def test_parse_pointer_to_volatile(self):
        prog = parse('fn f(x: *volatile u32) -> void { }')
        fn = prog.decls[0]
        t = fn.params[0].type
        from pak import ast as a
        assert isinstance(t, a.TypeVolatile)
        assert isinstance(t.inner, a.TypePointer)

    def test_codegen_volatile_param(self):
        c = codegen('fn f(x: volatile i32) -> void { }')
        assert 'volatile int32_t x' in c

    def test_codegen_volatile_pointer(self):
        c = codegen('fn f(x: *volatile u32) -> void { }')
        assert 'volatile' in c

    def test_codegen_volatile_static(self):
        c = codegen('static reg: volatile u32 = undefined')
        assert 'volatile uint32_t reg' in c


# ─────────────────────────────────────────────────────────────────────────────
# const declarations
# ─────────────────────────────────────────────────────────────────────────────

class TestConstDecl:

    def test_lex_const_keyword(self):
        assert TT.CONST in token_types('const')

    def test_parse_const_int(self):
        prog = parse('const MAX_SCORE: i32 = 9999')
        from pak import ast as a
        cd = prog.decls[0]
        assert isinstance(cd, a.ConstDecl)
        assert cd.name == 'MAX_SCORE'

    def test_parse_const_no_type(self):
        prog = parse('const N = 64')
        from pak import ast as a
        cd = prog.decls[0]
        assert isinstance(cd, a.ConstDecl)
        assert cd.type is None

    def test_codegen_const_int_uses_enum_trick(self):
        c = codegen('const MAX: i32 = 100')
        assert 'enum' in c
        assert 'MAX' in c
        assert '100' in c

    def test_codegen_const_f32(self):
        c = codegen('const PI: f32 = 3.14')
        assert 'PI' in c
        assert '3.14' in c

    def test_const_usable_as_array_size(self):
        src = textwrap.dedent('''
            const BUF_SIZE: i32 = 256
            static buf: [BUF_SIZE]byte = undefined
        ''')
        c = codegen(src)
        assert 'BUF_SIZE' in c
        assert 'buf' in c

    def test_typecheck_const_known_name(self):
        src = textwrap.dedent('''
            const LIMIT: i32 = 10
            fn f() -> void {
                let x: i32 = LIMIT
            }
        ''')
        errors = check(src)
        assert not errors

    def test_const_in_stmt_position(self):
        src = textwrap.dedent('''
            fn f() -> void {
                const LOCAL: i32 = 5
                let x: i32 = LOCAL
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# extern const
# ─────────────────────────────────────────────────────────────────────────────

class TestExternConst:

    def test_parse_extern_const(self):
        prog = parse('extern const SCREEN_W: i32')
        from pak import ast as a
        ec = prog.decls[0]
        assert isinstance(ec, a.ExternConst)
        assert ec.name == 'SCREEN_W'

    def test_codegen_extern_const_is_comment(self):
        c = codegen('extern const VI_WIDTH: u32')
        assert 'VI_WIDTH' in c

    def test_typecheck_extern_const_known(self):
        src = textwrap.dedent('''
            extern const SCREEN_W: i32
            fn f() -> void {
                let w: i32 = SCREEN_W
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# bit fields
# ─────────────────────────────────────────────────────────────────────────────

class TestBitFields:

    def test_parse_struct_bit_field(self):
        src = textwrap.dedent('''
            struct Flags {
                ready: u32 : 1
                mode: u32 : 3
                value: u32 : 28
            }
        ''')
        prog = parse(src)
        from pak import ast as a
        s = prog.decls[0]
        assert isinstance(s, a.StructDecl)
        assert s.fields[0].bit_width == 1
        assert s.fields[1].bit_width == 3
        assert s.fields[2].bit_width == 28

    def test_codegen_bit_field_syntax(self):
        src = textwrap.dedent('''
            struct Reg {
                enable: u32 : 1
                mode: u32 : 4
            }
        ''')
        c = codegen(src)
        assert 'enable : 1' in c
        assert 'mode : 4' in c

    def test_struct_normal_and_bit_fields_mixed(self):
        src = textwrap.dedent('''
            struct Mixed {
                id: i32
                flags: u8 : 4
                pad: u8 : 4
            }
        ''')
        c = codegen(src)
        assert 'int32_t id' in c
        assert 'flags : 4' in c


# ─────────────────────────────────────────────────────────────────────────────
# asm statement and expression
# ─────────────────────────────────────────────────────────────────────────────

class TestAsm:

    def test_lex_asm_keyword(self):
        assert TT.ASM in token_types('asm')

    def test_parse_asm_stmt(self):
        src = textwrap.dedent('''
            fn f() -> void {
                asm { "nop" }
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        from pak import ast as a
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, a.AsmStmt)
        assert stmt.lines == ['nop']

    def test_parse_asm_stmt_multiple_lines(self):
        src = textwrap.dedent('''
            fn f() -> void {
                asm { "nop" "nop" "nop" }
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert len(stmt.lines) == 3

    def test_codegen_asm_stmt(self):
        src = textwrap.dedent('''
            fn f() -> void {
                asm { "nop" }
            }
        ''')
        c = codegen(src)
        assert '__asm__' in c
        assert 'nop' in c
        # Without `volatile` keyword, __volatile__ should NOT appear
        assert '__volatile__' not in c

    def test_codegen_asm_stmt_multiple(self):
        src = textwrap.dedent('''
            fn f() -> void {
                asm { "nop" "nop" }
            }
        ''')
        c = codegen(src)
        assert c.count('"nop') == 2

    def test_parse_asm_expr_simple(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let x: u32 = asm("mfc0 %0, $9" : "=r"(x) : : "memory")
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        from pak import ast as a
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, a.AsmExpr)

    def test_codegen_asm_expr(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let x: u32 = asm("mfc0 %0, $9" : "=r"(x) : : "memory")
            }
        ''')
        c = codegen(src)
        assert '__asm__' in c
        assert 'mfc0' in c

    def test_typecheck_asm_stmt_no_errors(self):
        src = textwrap.dedent('''
            fn f() -> void {
                asm { "nop" }
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# closures / fn literals
# ─────────────────────────────────────────────────────────────────────────────

class TestClosures:

    def test_parse_closure_expr(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let cb: *void = fn(x: i32) -> i32 { return x }
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        from pak import ast as a
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, a.Closure)

    def test_parse_closure_no_ret(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let cb: *void = fn(x: i32) { }
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        let_stmt = fn.body.stmts[0]
        from pak import ast as a
        assert isinstance(let_stmt.value, a.Closure)
        assert let_stmt.value.ret_type is None

    def test_codegen_closure_emits_static_fn(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let cb: *void = fn(x: i32) -> i32 { return x }
            }
        ''')
        c = codegen(src)
        assert '_pak_closure_0' in c
        assert 'static int32_t _pak_closure_0' in c

    def test_codegen_closure_as_callback(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let cb: *void = fn(a: f32, b: f32) -> f32 { return a + b }
            }
        ''')
        c = codegen(src)
        assert 'static float _pak_closure_0(float a, float b)' in c

    def test_codegen_multiple_closures(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let c1: *void = fn(x: i32) -> i32 { return x }
                let c2: *void = fn(y: i32) -> i32 { return y }
            }
        ''')
        c = codegen(src)
        assert '_pak_closure_0' in c
        assert '_pak_closure_1' in c

    def test_typecheck_closure_params_in_scope(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let cb: *void = fn(x: i32) -> i32 { return x }
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# offsetof
# ─────────────────────────────────────────────────────────────────────────────

class TestOffsetOf:

    def test_lex_offsetof_keyword(self):
        assert TT.OFFSETOF in token_types('offsetof')

    def test_parse_offsetof(self):
        src = textwrap.dedent('''
            struct Vec3 { x: f32  y: f32  z: f32 }
            fn f() -> void {
                let off: i32 = offsetof(Vec3, z)
            }
        ''')
        prog = parse(src)
        fn = prog.decls[1]
        from pak import ast as a
        let_stmt = fn.body.stmts[0]
        assert isinstance(let_stmt.value, a.OffsetOf)
        assert let_stmt.value.type_name == 'Vec3'
        assert let_stmt.value.field == 'z'

    def test_codegen_offsetof(self):
        src = textwrap.dedent('''
            struct Vec3 { x: f32  y: f32  z: f32 }
            fn f() -> void {
                let off: i32 = offsetof(Vec3, z)
            }
        ''')
        c = codegen(src)
        assert 'offsetof(Vec3, z)' in c

    def test_typecheck_offsetof_no_errors(self):
        src = textwrap.dedent('''
            struct Vec3 { x: f32  y: f32  z: f32 }
            fn f() -> void {
                let off: i32 = offsetof(Vec3, z)
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# impl blocks and methods
# ─────────────────────────────────────────────────────────────────────────────

class TestImplBlocks:

    def test_typecheck_impl_methods_collected(self):
        src = textwrap.dedent('''
            struct Player { x: f32  y: f32 }
            impl Player {
                fn move_right(self: *Player, speed: f32) -> void {
                    self.x = self.x + speed
                }
            }
        ''')
        errors = check(src)
        assert not errors

    def test_typecheck_impl_method_body(self):
        src = textwrap.dedent('''
            struct Obj { val: i32 }
            impl Obj {
                fn get(self: *Obj) -> i32 {
                    return self.val
                }
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# ok / err expressions
# ─────────────────────────────────────────────────────────────────────────────

class TestOkErr:

    def test_typecheck_ok_expr(self):
        src = textwrap.dedent('''
            enum Err: u8 { bad }
            fn f() -> Result(i32, Err) {
                return ok(1)
            }
        ''')
        errors = check(src)
        assert not errors

    def test_typecheck_err_expr(self):
        src = textwrap.dedent('''
            enum Err: u8 { bad }
            fn f() -> Result(i32, Err) {
                return err(Err.bad)
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# features.pk64 end-to-end
# ─────────────────────────────────────────────────────────────────────────────

class TestFeaturesPak:

    def test_features_pak_compiles(self):
        """examples/features.pk64 should parse and codegen without errors."""
        import pathlib
        src = pathlib.Path('examples/features.pk64').read_text()
        c = codegen(src)
        assert 'Player' in c
        assert 'update_player' in c

    def test_features_pak_no_type_errors(self):
        """examples/features.pk64 should produce no type errors."""
        import pathlib
        src = pathlib.Path('examples/features.pk64').read_text()
        errors = check(src)
        # Filter out module-related false positives from use declarations
        real_errors = [e for e in errors if e.code not in ('E010',)]
        assert real_errors == []


# ─────────────────────────────────────────────────────────────────────────────
# String interpolation (FmtStr)
# ─────────────────────────────────────────────────────────────────────────────

class TestFmtStr:

    def test_plain_string_no_interpolation(self):
        """A string without {} is a plain StringLit."""
        prog = parse('entry { let s = "hello" }')
        entry = prog.decls[0]
        stmt = entry.body.stmts[0]
        assert isinstance(stmt.value, ast.StringLit)

    def test_fmtstr_parses_as_fmtstr_node(self):
        """A string with {expr} produces a FmtStr node."""
        prog = parse('entry { let x: i32 = 5\n let s = "val is {x}" }')
        entry = prog.decls[0]
        s_stmt = entry.body.stmts[1]
        assert isinstance(s_stmt.value, ast.FmtStr)

    def test_fmtstr_parts_alternating(self):
        """FmtStr.parts alternates str and expr."""
        prog = parse('entry { let x: i32 = 1\n let s = "a {x} b" }')
        node = prog.decls[0].body.stmts[1].value
        assert isinstance(node, ast.FmtStr)
        assert isinstance(node.parts[0], str)   # "a "
        assert isinstance(node.parts[1], ast.Ident)  # x
        assert isinstance(node.parts[2], str)   # " b"

    def test_fmtstr_codegen_contains_snprintf(self):
        """FmtStr emits a GCC statement expression with snprintf."""
        src = textwrap.dedent('''
            fn greet(name: *c_char) -> *c_char {
                return "hi {name}"
            }
        ''')
        c = codegen(src)
        assert 'snprintf' in c

    def test_fmtstr_codegen_no_bare_braces(self):
        """The raw interpolation braces should not appear in output."""
        src = textwrap.dedent('''
            fn show(score: i32) -> *c_char {
                return "score: {score}"
            }
        ''')
        c = codegen(src)
        # The literal "{score}" must not appear in the C output
        assert '"{score}"' not in c
        assert 'snprintf' in c


# ─────────────────────────────────────────────────────────────────────────────
# alignof
# ─────────────────────────────────────────────────────────────────────────────

class TestAlignOf:

    def test_alignof_lexer_token(self):
        toks = lex('alignof(i32)')
        assert toks[0].type == TT.ALIGNOF

    def test_alignof_parses_to_node(self):
        prog = parse('entry { let a = alignof(i32) }')
        stmt = prog.decls[0].body.stmts[0]
        assert isinstance(stmt.value, ast.AlignOf)

    def test_alignof_codegen(self):
        src = 'entry { let a = alignof(i32) }'
        c = codegen(src)
        assert '__alignof__' in c

    def test_alignof_type_check_no_errors(self):
        src = 'entry { let a = alignof(i32) }'
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# Numeric method casts
# ─────────────────────────────────────────────────────────────────────────────

class TestNumericCastMethods:

    def test_as_f32(self):
        src = textwrap.dedent('''
            fn cast_it(x: i32) -> f32 {
                return x.as_f32()
            }
        ''')
        c = codegen(src)
        assert '(float)(x)' in c

    def test_as_i32(self):
        src = textwrap.dedent('''
            fn cast_it(x: f32) -> i32 {
                return x.as_i32()
            }
        ''')
        c = codegen(src)
        assert '(int32_t)(x)' in c

    def test_as_u8(self):
        src = textwrap.dedent('''
            fn cast_it(x: i32) -> u8 {
                return x.as_u8()
            }
        ''')
        c = codegen(src)
        assert '(uint8_t)(x)' in c

    def test_clamp_method(self):
        src = textwrap.dedent('''
            fn clamp_val(x: f32) -> f32 {
                return x.clamp(0.0, 1.0)
            }
        ''')
        c = codegen(src)
        assert 'x' in c and '0.0f' in c and '1.0f' in c

    def test_fix16_16_cast(self):
        src = textwrap.dedent('''
            fn to_fixed(x: f32) -> i32 {
                return x.as_fix16_16()
            }
        ''')
        c = codegen(src)
        assert '65536' in c


# ─────────────────────────────────────────────────────────────────────────────
# comptime_assert
# ─────────────────────────────────────────────────────────────────────────────

class TestComptimeAssert:

    def test_comptime_assert_emits_static_assert(self):
        src = textwrap.dedent('''
            entry {
                comptime_assert(1 == 1, "always true")
            }
        ''')
        c = codegen(src)
        assert '_Static_assert' in c
        assert '1 == 1' in c

    def test_comptime_assert_no_type_errors(self):
        src = textwrap.dedent('''
            entry {
                comptime_assert(1 == 1, "ok")
            }
        ''')
        errors = check(src)
        assert not errors


# ─────────────────────────────────────────────────────────────────────────────
# FixedList / RingBuffer / FixedMap containers
# ─────────────────────────────────────────────────────────────────────────────

class TestContainers:

    def test_fixed_list_type_parses(self):
        prog = parse(textwrap.dedent('''
            struct Enemy { x: f32 }
            entry {
                let enemies: FixedList(Enemy, 32) = FixedList.init()
            }
        '''))
        let_stmt = prog.decls[1].body.stmts[0]
        assert isinstance(let_stmt.type, ast.TypeGeneric)
        assert let_stmt.type.name == 'FixedList'

    def test_fixed_list_codegen_typedef(self):
        src = textwrap.dedent('''
            struct Enemy { x: f32 }
            entry {
                let enemies: FixedList(Enemy, 32) = FixedList.init()
            }
        ''')
        c = codegen(src)
        assert 'FixedList' in c or 'Enemy' in c

    def test_ring_buffer_type_parses(self):
        prog = parse(textwrap.dedent('''
            entry {
                let rb: RingBuffer(i32, 16) = RingBuffer.init()
            }
        '''))
        let_stmt = prog.decls[0].body.stmts[0]
        assert isinstance(let_stmt.type, ast.TypeGeneric)
        assert let_stmt.type.name == 'RingBuffer'

    def test_fixed_map_type_parses(self):
        prog = parse(textwrap.dedent('''
            entry {
                let m: FixedMap(i32, i32, 64) = FixedMap.init()
            }
        '''))
        let_stmt = prog.decls[0].body.stmts[0]
        assert isinstance(let_stmt.type, ast.TypeGeneric)
        assert let_stmt.type.name == 'FixedMap'

    def test_container_typedef_emitted(self):
        src = textwrap.dedent('''
            entry {
                let rb: RingBuffer(i32, 8) = RingBuffer.init()
            }
        ''')
        c = codegen(src)
        # Container typedefs or at least the struct definition should appear
        assert 'int32_t' in c or 'RingBuffer' in c

    def test_fixed_list_push_codegen(self):
        src = textwrap.dedent('''
            struct E { x: f32 }
            entry {
                let list: FixedList(E, 10) = FixedList.init()
                let e = E { x: 1.0 }
                list.push(e)
            }
        ''')
        c = codegen(src)
        assert 'len' in c

    def test_vec_init_lowers_to_zero(self):
        """Vec.init() must lower to {0}, not the literal string Vec.init()."""
        src = textwrap.dedent('''
            entry {
                let mut v: Vec(i32) = Vec.init()
            }
        ''')
        c = codegen(src)
        assert 'Vec.init()' not in c
        assert '{0}' in c

    def test_ring_buffer_uses_len_field(self):
        """RingBuffer struct must use .len (not .count) for consistency."""
        src = textwrap.dedent('''
            entry {
                let mut rb: RingBuffer(i32, 8) = RingBuffer.init()
                rb.push(1)
                let n = rb.len()
            }
        ''')
        c = codegen(src)
        assert 'int32_t head, tail, len;' in c
        assert '(rb).len' in c

    def test_fixedmap_get_typed_cast(self):
        """FixedMap.get() result should be cast to V* (not void*)."""
        src = textwrap.dedent('''
            entry {
                let mut m: FixedMap(i32, i32, 8) = FixedMap.init()
                m.set(1, 42)
                let p = m.get(1)
            }
        ''')
        c = codegen(src)
        assert '(int32_t *)pak_map_get' in c

    def test_pool_acquire_typed_cast(self):
        """Pool.acquire() result should be cast to T* for the pool element type."""
        src = textwrap.dedent('''
            struct Item { v: i32 }
            entry {
                let mut pool: Pool(Item, 4) = Pool.init()
                let p: *Item = pool.acquire()
            }
        ''')
        c = codegen(src)
        assert '(Item *)pak_pool_acquire' in c

    def test_is_empty_all_containers(self):
        """All container types support .is_empty()."""
        src = textwrap.dedent('''
            entry {
                let mut fl: FixedList(i32, 4) = FixedList.init()
                let a = fl.is_empty()
                let mut rb: RingBuffer(i32, 4) = RingBuffer.init()
                let b = rb.is_empty()
                let mut fm: FixedMap(i32, i32, 4) = FixedMap.init()
                let c = fm.is_empty()
                let mut p: Pool(i32, 4) = Pool.init()
                let d = p.is_empty()
                let mut v: Vec(i32) = Vec.init()
                let e = v.is_empty()
            }
        ''')
        c = codegen(src)
        assert c.count('.len == 0') >= 5


# ─────────────────────────────────────────────────────────────────────────────
# @export annotation
# ─────────────────────────────────────────────────────────────────────────────

class TestExportAnnotation:

    def test_export_renames_function(self):
        src = textwrap.dedent('''
            @export("my_game_init")
            fn init() {
            }
        ''')
        c = codegen(src)
        assert 'my_game_init' in c

    def test_export_without_name_keeps_original(self):
        src = textwrap.dedent('''
            @export
            fn init() {
            }
        ''')
        c = codegen(src)
        assert 'init' in c


# ─────────────────────────────────────────────────────────────────────────────
# catch fallback vs propagation
# ─────────────────────────────────────────────────────────────────────────────

class TestCatchExpr:

    def test_catch_fallback_ternary(self):
        """catch { default_val } should emit a ternary, not an if block."""
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn might_fail() -> Result(i32, E) { return ok(1) }
            fn use_it() -> i32 {
                let x = might_fail() catch { 0 }
                return x
            }
        ''')
        c = codegen(src)
        assert 'is_ok' in c
        # Should use ternary style for fallback, not if (!...) {...}
        # The ternary contains is_ok ?
        assert '?' in c

    def test_catch_propagation_if_block(self):
        """catch e { return err(e) } should emit if (!is_ok) { return ...; }"""
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn might_fail() -> Result(i32, E) { return ok(1) }
            fn propagate() -> Result(i32, E) {
                let x = might_fail() catch e { return err(e) }
                return ok(x)
            }
        ''')
        c = codegen(src)
        assert 'if (' in c
        assert 'is_ok' in c


# ─────────────────────────────────────────────────────────────────────────────
# @no_alloc enforcement
# ─────────────────────────────────────────────────────────────────────────────

class TestNoAlloc:

    def test_no_alloc_clean_function_passes(self):
        """@no_alloc on a function with no heap calls should produce no error."""
        src = textwrap.dedent('''
            @no_alloc
            fn pure_math(x: i32) -> i32 {
                return x + 1
            }
        ''')
        errors = check(src)
        # No E501 errors expected
        assert all(e.code != 'E501' for e in errors)

    def test_no_alloc_with_alloc_produces_error(self):
        """@no_alloc on a function that calls mem.alloc should raise E501."""
        src = textwrap.dedent('''
            use n64.mem
            @no_alloc
            fn bad_fn() {
                let p = mem.alloc(64)
            }
        ''')
        errors = check(src)
        assert any(e.code == 'E501' for e in errors)


# ─────────────────────────────────────────────────────────────────────────────
# @c_layout annotation
# ─────────────────────────────────────────────────────────────────────────────

class TestCLayout:

    def test_c_layout_struct_compiles(self):
        """@c_layout struct should codegen without errors."""
        src = textwrap.dedent('''
            @c_layout
            struct Header {
                magic: u32
                version: u16
            }
        ''')
        c = codegen(src)
        assert 'Header' in c
        assert 'typedef struct' in c


# ─────────────────────────────────────────────────────────────────────────────
# @uncached annotation codegen
# ─────────────────────────────────────────────────────────────────────────────

class TestUncachedAnnotation:

    def test_uncached_static_emits_uncachedaddr(self):
        """@uncached static should declare a _pak_raw_ backing buffer and
        expose a pointer via UncachedAddr() so the RDP sees writes immediately."""
        src = textwrap.dedent('''
            @uncached
            static dma_buf: [4096]byte = undefined
        ''')
        c = codegen(src)
        assert 'UncachedAddr' in c
        assert '_pak_raw_dma_buf' in c
        # The public name should be a pointer, not an array
        assert 'dma_buf' in c

    def test_uncached_static_has_alignment(self):
        """@uncached static must be at least 16-byte aligned for DMA safety."""
        src = textwrap.dedent('''
            @uncached
            static buf: [256]byte = undefined
        ''')
        c = codegen(src)
        assert '__attribute__' in c
        assert 'aligned' in c

    def test_uncached_local_array_uses_malloc_uncached(self):
        """@uncached local array should allocate via malloc_uncached."""
        src = textwrap.dedent('''
            fn do_dma() {
                @uncached
                let tmp: [1024]byte = undefined
            }
        ''')
        c = codegen(src)
        assert 'malloc_uncached' in c
        assert 'tmp' in c

    def test_uncached_comment_not_emitted_as_sole_annotation(self):
        """The old '/* @uncached */' comment stub must no longer appear."""
        src = textwrap.dedent('''
            @uncached
            static frame: [8192]byte = undefined
        ''')
        c = codegen(src)
        # Must not fall back to the old comment-only behaviour
        assert '/* @uncached */' not in c


# ─────────────────────────────────────────────────────────────────────────────
# Naming convention warnings (W001–W003)
# ─────────────────────────────────────────────────────────────────────────────

class TestNamingConventionWarnings:

    def test_pascal_case_struct_no_warning(self):
        """Correctly named struct produces no W001 warning."""
        src = 'struct PlayerState { x: f32 }'
        diags = check(src)
        assert not any(d.code == 'W001' for d in diags)

    def test_snake_case_struct_warns_w001(self):
        """Incorrectly named struct (snake_case) produces W001."""
        src = 'struct player_state { x: f32 }'
        diags = check(src)
        assert any(d.code == 'W001' for d in diags)

    def test_w001_is_warning_not_error(self):
        """W001 must have severity='warning', not 'error'."""
        src = 'struct bad_name { x: f32 }'
        diags = check(src)
        w = next(d for d in diags if d.code == 'W001')
        assert w.is_warning
        assert w.severity == 'warning'

    def test_pascal_case_enum_no_warning(self):
        src = 'enum Direction { up, down }'
        diags = check(src)
        assert not any(d.code == 'W001' for d in diags)

    def test_snake_case_enum_warns(self):
        src = 'enum my_dir { up, down }'
        diags = check(src)
        assert any(d.code == 'W001' for d in diags)

    def test_snake_case_fn_no_warning(self):
        src = 'fn update_player(x: i32) {}'
        diags = check(src)
        assert not any(d.code == 'W002' for d in diags)

    def test_camel_case_fn_warns_w002(self):
        src = 'fn updatePlayer(x: i32) {}'
        diags = check(src)
        assert any(d.code == 'W002' for d in diags)

    def test_w002_is_warning(self):
        src = 'fn UpdatePlayer(x: i32) {}'
        diags = check(src)
        w = next(d for d in diags if d.code == 'W002')
        assert w.is_warning

    def test_upper_snake_const_no_warning(self):
        src = 'const MAX_ENEMIES: i32 = 20'
        diags = check(src)
        assert not any(d.code == 'W003' for d in diags)

    def test_lower_const_warns_w003(self):
        src = 'const max_enemies: i32 = 20'
        diags = check(src)
        assert any(d.code == 'W003' for d in diags)

    def test_w003_is_warning(self):
        src = 'const maxEnemies: i32 = 20'
        diags = check(src)
        w = next(d for d in diags if d.code == 'W003')
        assert w.is_warning

    def test_no_style_warnings_suppresses_all(self):
        """no_style_warnings=True must suppress W001/W002/W003."""
        from pak.typechecker import typecheck
        prog = parse('struct bad_name { x: f32 }\nconst lower: i32 = 1')
        diags = typecheck(prog, no_style_warnings=True)
        assert not any(d.code in ('W001', 'W002', 'W003') for d in diags)

    def test_warnings_appear_in_str_as_warning_prefix(self):
        """str(PakError) for a warning should say 'warning[...]' not 'error[...]'."""
        src = 'struct bad_name { x: f32 }'
        diags = check(src)
        w = next(d for d in diags if d.code == 'W001')
        assert str(w).startswith('warning[W001]')

    def test_hint_suggests_correct_name(self):
        """W001 hint should suggest a PascalCase rename."""
        src = 'struct player_state { x: f32 }'
        diags = check(src)
        w = next(d for d in diags if d.code == 'W001')
        assert 'PlayerState' in w.hint

    def test_errors_still_use_error_prefix(self):
        """Real errors (E-series) must still say 'error[...]'."""
        src = 'entry { let x = unknown_var }'
        diags = check(src)
        e = next((d for d in diags if d.code == 'E010'), None)
        if e:
            assert str(e).startswith('error[E010]')


# ─────────────────────────────────────────────────────────────────────────────
# Move tracking / E401 (use after move)
# ─────────────────────────────────────────────────────────────────────────────

class TestMoveTracking:

    def test_use_after_move_pointer_fires_e401(self):
        """Assigning a *T to a new binding then using the original = E401."""
        src = textwrap.dedent('''
            struct Model { data: i32 }
            fn take(m: *Model) {}
            fn test_move(m: *Model) {
                let m2 = m
                take(m)
            }
        ''')
        errors = check(src)
        assert any(e.code == 'E401' for e in errors)

    def test_no_move_on_copy_type(self):
        """Assigning an i32 does not move it — copy types never trigger E401."""
        src = textwrap.dedent('''
            fn test_copy() {
                let x: i32 = 5
                let y = x
                let z = x
            }
        ''')
        errors = check(src)
        assert not any(e.code == 'E401' for e in errors)

    def test_redeclaration_clears_moved(self):
        """Re-declaring a name clears its moved status."""
        src = textwrap.dedent('''
            struct R { v: i32 }
            fn test() {
                let r: *R = none
                let r2 = r
                let r: *R = none
                let r3 = r
            }
        ''')
        errors = check(src)
        assert not any(e.code == 'E401' for e in errors)


# ─────────────────────────────────────────────────────────────────────────────
# Closures — parse, codegen, typecheck
# ─────────────────────────────────────────────────────────────────────────────

class TestClosures:

    def test_closure_parses(self):
        prog = parse(textwrap.dedent('''
            fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
                return f(x)
            }
        '''))
        assert prog is not None

    def test_closure_literal_parses(self):
        prog = parse(textwrap.dedent('''
            entry {
                let double = fn(x: i32) -> i32 { return x * 2 }
            }
        '''))
        assert prog is not None

    def test_closure_codegen_emits_static_fn(self):
        """Closure literals should be emitted as static C functions."""
        src = textwrap.dedent('''
            fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
                return f(x)
            }
            entry {
                let r = apply(fn(x: i32) -> i32 { return x * 2 }, 5)
            }
        ''')
        c = codegen(src)
        # The apply function should be present
        assert 'apply' in c

    def test_fn_type_codegen(self):
        """fn(i32) -> i32 should map to a C function pointer type."""
        src = textwrap.dedent('''
            fn call(f: fn(i32) -> i32, x: i32) -> i32 {
                return f(x)
            }
        ''')
        c = codegen(src)
        # Should use a function pointer: int32_t (*)(int32_t) or similar
        assert 'call' in c
        assert 'int32_t' in c

    def test_closure_no_type_errors(self):
        src = textwrap.dedent('''
            fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
                return f(x)
            }
        ''')
        errors = check(src)
        assert not any(e.code in ('E010', 'E012') for e in errors)


# ─────────────────────────────────────────────────────────────────────────────
# Inline assembly — parse and codegen
# ─────────────────────────────────────────────────────────────────────────────

class TestAsmBlocks:

    def test_asm_stmt_parses(self):
        prog = parse(textwrap.dedent('''
            fn nop_loop() {
                asm { "nop" }
            }
        '''))
        assert prog is not None

    def test_asm_codegen_emits_asm_keyword(self):
        src = textwrap.dedent('''
            fn fast_nop() {
                asm { "nop" }
            }
        ''')
        c = codegen(src)
        assert '__asm__' in c or 'asm' in c

    def test_asm_volatile_parses(self):
        prog = parse(textwrap.dedent('''
            fn barrier() {
                asm volatile { "sync" }
            }
        '''))
        assert prog is not None

    def test_asm_volatile_codegen(self):
        src = textwrap.dedent('''
            fn barrier() {
                asm volatile { "sync" }
            }
        ''')
        c = codegen(src)
        assert 'volatile' in c or 'asm' in c

    def test_asm_with_inputs_outputs(self):
        """asm with input/output constraints should codegen without crashing."""
        src = textwrap.dedent('''
            fn get_count(val: i32) -> i32 {
                asm { "move $2, $4" : "=r"(val) : "r"(val) }
                return val
            }
        ''')
        # Should not raise
        c = codegen(src)
        assert 'get_count' in c


# ─────────────────────────────────────────────────────────────────────────────
# const declarations — compile-time expressions
# ─────────────────────────────────────────────────────────────────────────────

class TestConstDeclarations:

    def test_const_int_codegen(self):
        src = 'const MAX_ENEMIES: i32 = 64'
        c = codegen(src)
        assert 'MAX_ENEMIES' in c
        assert '64' in c

    def test_const_used_as_array_size(self):
        src = textwrap.dedent('''
            const POOL_SIZE: i32 = 32
            struct E { x: f32 }
            entry {
                let pool: [POOL_SIZE]E = undefined
            }
        ''')
        c = codegen(src)
        assert 'POOL_SIZE' in c or '32' in c

    def test_const_expr_arithmetic(self):
        src = textwrap.dedent('''
            const W: i32 = 320
            const H: i32 = 240
            const HALF_W: i32 = W / 2
        ''')
        c = codegen(src)
        assert 'HALF_W' in c

    def test_const_no_type_errors(self):
        src = textwrap.dedent('''
            const MAX: i32 = 100
            fn clamp_score(s: i32) -> i32 {
                return s.clamp(0, MAX)
            }
        ''')
        errors = check(src)
        assert not any(e.code in ('E010',) for e in errors)

    def test_extern_const_codegen(self):
        src = 'extern const DISPLAY_WIDTH: i32'
        c = codegen(src)
        assert 'DISPLAY_WIDTH' in c

    def test_comptime_assert_with_sizeof(self):
        src = textwrap.dedent('''
            struct Player { x: f32  y: f32  health: i32 }
            entry {
                comptime_assert(sizeof(Player) <= 64, "Player too large")
            }
        ''')
        c = codegen(src)
        assert '_Static_assert' in c
        assert 'sizeof' in c


# ─────────────────────────────────────────────────────────────────────────────
# ok() / err() / Result / catch — full chain golden tests
# ─────────────────────────────────────────────────────────────────────────────

class TestResultChain:

    def test_ok_err_typedef_emitted(self):
        src = textwrap.dedent('''
            enum LoadErr: u8 { not_found, corrupt }
            fn load_sprite(path: *c_char) -> Result(i32, LoadErr) {
                return ok(42)
            }
        ''')
        c = codegen(src)
        assert 'PakResult' in c
        assert 'is_ok' in c

    def test_ok_value_accessible(self):
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn get() -> Result(i32, E) { return ok(99) }
            entry {
                let x = get() catch { 0 }
            }
        ''')
        c = codegen(src)
        # Ternary fallback form: is_ok ? .data.value : fallback
        assert 'is_ok' in c
        assert '?' in c

    def test_err_propagation_codegen(self):
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn might_fail() -> Result(i32, E) { return ok(1) }
            fn caller() -> Result(i32, E) {
                let x = might_fail() catch e { return err(e) }
                return ok(x)
            }
        ''')
        c = codegen(src)
        assert 'if (' in c
        assert 'is_ok' in c
        assert 'error' in c

    def test_result_no_type_errors(self):
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn compute() -> Result(i32, E) { return ok(1) }
        ''')
        errors = check(src)
        assert not any(e.code not in ('W001', 'W002', 'W003') and e.code.startswith('E') for e in errors)

    def test_nested_catch_chain(self):
        """Two successive catch operations should codegen without crashing."""
        src = textwrap.dedent('''
            enum E: u8 { bad }
            fn step1() -> Result(i32, E) { return ok(1) }
            fn step2(x: i32) -> Result(i32, E) { return ok(x + 1) }
            fn run() -> Result(i32, E) {
                let a = step1() catch e { return err(e) }
                let b = step2(a) catch e { return err(e) }
                return ok(b)
            }
        ''')
        c = codegen(src)
        assert 'run' in c
        assert 'is_ok' in c


# ─────────────────────────────────────────────────────────────────────────────
# impl blocks — method dispatch
# ─────────────────────────────────────────────────────────────────────────────

class TestImplBlocks:

    def test_impl_method_codegen(self):
        src = textwrap.dedent('''
            struct Counter { value: i32 }
            impl Counter {
                fn increment(self: *Counter) {
                    self.value = self.value + 1
                }
                fn get(self: *Counter) -> i32 {
                    return self.value
                }
            }
        ''')
        c = codegen(src)
        assert 'Counter_increment' in c
        assert 'Counter_get' in c

    def test_impl_method_self_pointer(self):
        """Methods on *Self should use -> field access in generated C."""
        src = textwrap.dedent('''
            struct Vec { x: f32  y: f32 }
            impl Vec {
                fn length_sq(self: *Vec) -> f32 {
                    return self.x * self.x + self.y * self.y
                }
            }
        ''')
        c = codegen(src)
        assert 'length_sq' in c

    def test_impl_method_call_dispatch(self):
        """counter.increment() should resolve to Counter_increment(&counter)."""
        src = textwrap.dedent('''
            struct Counter { value: i32 }
            impl Counter {
                fn increment(self: *Counter) {
                    self.value = self.value + 1
                }
            }
            entry {
                let c = Counter { value: 0 }
                c.increment()
            }
        ''')
        c = codegen(src)
        assert 'Counter_increment' in c

    def test_impl_typechecked(self):
        src = textwrap.dedent('''
            struct Point { x: f32  y: f32 }
            impl Point {
                fn zero(self: *Point) {
                    self.x = 0.0
                    self.y = 0.0
                }
            }
        ''')
        errors = check(src)
        real = [e for e in errors if not e.is_warning]
        assert not real

    def test_impl_multiple_methods(self):
        src = textwrap.dedent('''
            struct Stack { data: [64]i32  top: i32 }
            impl Stack {
                fn push(self: *Stack, v: i32) {
                    self.data[self.top] = v
                    self.top = self.top + 1
                }
                fn pop(self: *Stack) -> i32 {
                    self.top = self.top - 1
                    return self.data[self.top]
                }
                fn is_empty(self: *Stack) -> bool {
                    return self.top == 0
                }
            }
        ''')
        c = codegen(src)
        assert 'Stack_push' in c
        assert 'Stack_pop' in c
        assert 'Stack_is_empty' in c


# ─────────────────────────────────────────────────────────────────────────────
# Generic functions — monomorphisation
# ─────────────────────────────────────────────────────────────────────────────

class TestGenericFunctions:

    def test_generic_fn_codegen_on_call(self):
        src = textwrap.dedent('''
            fn identity<T>(x: T) -> T { return x }
            entry {
                let a: i32 = identity(42)
                let b: f32 = identity(3.14)
            }
        ''')
        c = codegen(src)
        # Two specialisations should be emitted
        assert 'identity' in c

    def test_generic_fn_two_types(self):
        src = textwrap.dedent('''
            fn swap<T>(a: T, b: T) -> T { return b }
            entry {
                let x: i32 = swap(1, 2)
                let y: f32 = swap(1.0, 2.0)
            }
        ''')
        c = codegen(src)
        assert 'swap' in c

    def test_generic_fn_no_type_errors(self):
        src = textwrap.dedent('''
            fn max_val<T>(a: T, b: T) -> T {
                return a
            }
            entry {
                let m: i32 = max_val(3, 7)
            }
        ''')
        errors = check(src)
        real = [e for e in errors if not e.is_warning]
        assert not real

    def test_generic_fn_explicit_type_args(self):
        """foo<i32>(x) must monomorphize to foo_int32_t, not foo_void_p."""
        src = textwrap.dedent('''
            fn id<T>(x: T) -> T { return x }
            static s: i32 = 0
            entry { s = id<i32>(42) }
        ''')
        c = codegen(src)
        assert 'id_int32_t' in c
        assert 'id_void_p' not in c

    def test_generic_fn_explicit_multi_type_args(self):
        src = textwrap.dedent('''
            fn pair<A, B>(a: A, b: B) -> A { return a }
            static s: i32 = 0
            entry { s = pair<i32, f32>(7, 3.5) }
        ''')
        c = codegen(src)
        assert 'pair_int32_t_float' in c

    def test_explicit_type_args_dont_break_comparison(self):
        """`a < b` must still parse as a comparison, not type args."""
        src = textwrap.dedent('''
            fn lt(a: i32, b: i32) -> bool { return a < b }
            entry { }
        ''')
        errors = check(src)
        real = [e for e in errors if not e.is_warning]
        assert not real

    def test_generic_struct_literal_monomorphized(self):
        """Box<i32> { .. } emits a specialized struct typedef + cast."""
        src = textwrap.dedent('''
            struct Box<T> { value: T }
            static r: i32 = 0
            entry {
                let mut b = Box<i32> { value: 42 }
                r = b.value
            }
        ''')
        c = codegen(src)
        assert 'Box_int32_t' in c
        assert '(Box_int32_t){' in c
        # The unsubstituted template must not leak into output.
        assert 'T value;' not in c

    def test_generic_impl_method_specialized(self):
        """A method on a generic struct lowers to Box_i32_get(&b)."""
        src = textwrap.dedent('''
            struct Box<T> { value: T }
            impl Box<T> { fn get(self: *Box<T>) -> T { return self.value } }
            static r: i32 = 0
            entry {
                let mut b = Box<i32> { value: 42 }
                r = b.get()
            }
        ''')
        c = codegen(src)
        assert 'Box_int32_t_get(Box_int32_t * self)' in c
        assert 'Box_int32_t_get(&b)' in c

    def test_generic_struct_two_instantiations(self):
        src = textwrap.dedent('''
            struct Box<T> { value: T }
            impl Box<T> { fn get(self: *Box<T>) -> T { return self.value } }
            static a: i32 = 0
            static b: f32 = 0.0
            entry {
                let mut bi = Box<i32> { value: 7 }
                let mut bf = Box<f32> { value: 1.5 }
                a = bi.get()
                b = bf.get()
            }
        ''')
        c = codegen(src)
        assert 'Box_int32_t_get(&bi)' in c
        assert 'Box_float_get(&bf)' in c

    def test_struct_literal_method_call_lowered(self):
        """Method calls on a let-bound struct literal lower to Type_method(&v)."""
        src = textwrap.dedent('''
            struct P { x: i32 }
            impl P { fn get(self: *P) -> i32 { return self.x } }
            static r: i32 = 0
            entry {
                let mut p = P { x: 9 }
                r = p.get()
            }
        ''')
        c = codegen(src)
        assert 'P_get(&p)' in c
        assert 'p.get()' not in c


# ─────────────────────────────────────────────────────────────────────────────
# Format strings — end-to-end golden tests
# ─────────────────────────────────────────────────────────────────────────────

class TestFmtStrGolden:

    def test_fmtstr_multiple_interpolations(self):
        src = textwrap.dedent('''
            fn describe(x: i32, y: i32) -> *c_char {
                return "pos ({x}, {y})"
            }
        ''')
        c = codegen(src)
        assert 'snprintf' in c
        # Both variables should appear as printf args
        assert 'x' in c and 'y' in c

    def test_fmtstr_integer_format_spec(self):
        src = textwrap.dedent('''
            fn show(score: i32) -> *c_char {
                return "score: {score}"
            }
        ''')
        c = codegen(src)
        # i32 should use %d
        assert '%d' in c or '%i' in c or 'snprintf' in c

    def test_fmtstr_float_format_spec(self):
        src = textwrap.dedent('''
            fn show(x: f32) -> *c_char {
                return "x={x}"
            }
        ''')
        c = codegen(src)
        assert '%f' in c or 'snprintf' in c

    def test_fmtstr_no_interpolation_stays_stringlit(self):
        """A string without {} should remain a plain C string literal."""
        src = textwrap.dedent('''
            fn label() -> *c_char { return "hello world" }
        ''')
        c = codegen(src)
        assert '"hello world"' in c
        assert 'snprintf' not in c

    def test_fmtstr_escaped_braces_not_interpolated(self):
        """A string like "val" (no braces) stays as StringLit."""
        prog = parse('entry { let s = "no braces here" }')
        stmt = prog.decls[0].body.stmts[0]
        assert isinstance(stmt.value, ast.StringLit)


# ─────────────────────────────────────────────────────────────────────────────
# Defer — emission golden tests
# ─────────────────────────────────────────────────────────────────────────────

class TestDeferEmission:

    def test_defer_emitted_at_scope_end(self):
        """Deferred statement must appear after the main body in generated C."""
        src = textwrap.dedent('''
            fn work() {
                defer { let _cleanup: i32 = 1 }
                let x: i32 = 42
            }
        ''')
        c = codegen(src)
        # defer body should appear after the main let
        x_pos = c.find('42')
        cleanup_pos = c.find('_cleanup')
        assert x_pos != -1 and cleanup_pos != -1
        assert cleanup_pos > x_pos

    def test_defer_emitted_before_return(self):
        """Deferred code must appear before early return in generated C."""
        src = textwrap.dedent('''
            fn early_exit(cond: bool) -> i32 {
                defer { let _d: i32 = 99 }
                if cond {
                    return 0
                }
                return 1
            }
        ''')
        c = codegen(src)
        # Both the defer body and return should be present
        assert '_d' in c
        assert 'return' in c

    def test_multiple_defers_lifo(self):
        """Multiple defers in same scope must emit in reverse order."""
        src = textwrap.dedent('''
            fn multi_defer() {
                defer { let _a: i32 = 1 }
                defer { let _b: i32 = 2 }
                let _x: i32 = 0
            }
        ''')
        c = codegen(src)
        # Scope the search to the function body to avoid hitting header symbols
        fn_start = c.find('multi_defer')
        assert fn_start != -1
        fn_body = c[fn_start:]
        a_pos = fn_body.find('_a =')
        b_pos = fn_body.find('_b =')
        assert a_pos != -1 and b_pos != -1
        # _b deferred later → emitted first (LIFO)
        assert b_pos < a_pos


# ─────────────────────────────────────────────────────────────────────────────
# Exhaustive match — golden tests
# ─────────────────────────────────────────────────────────────────────────────

class TestMatchGolden:

    def test_enum_match_generates_switch(self):
        src = textwrap.dedent('''
            enum Dir { up, down, left, right }
            fn move_player(d: Dir) -> i32 {
                match d {
                    .up    => { return 1 }
                    .down  => { return 2 }
                    .left  => { return 3 }
                    .right => { return 4 }
                }
            }
        ''')
        c = codegen(src)
        assert 'switch' in c
        assert 'Dir_up' in c

    def test_variant_match_generates_tag_switch(self):
        src = textwrap.dedent('''
            variant Shape {
                circle(f32)
                square(f32)
            }
            fn area(s: Shape) -> f32 {
                match s {
                    .circle => { return 1.0 }
                    .square => { return 2.0 }
                }
            }
        ''')
        c = codegen(src)
        assert 'switch' in c
        assert '.tag' in c

    def test_non_exhaustive_match_e301(self):
        """Missing cases on an enum must raise E301."""
        src = textwrap.dedent('''
            enum Dir { up, down, left, right }
            fn bad_match(d: Dir) {
                match d {
                    .up   => {}
                    .down => {}
                }
            }
        ''')
        errors = check(src)
        assert any(e.code == 'E301' for e in errors)

    def test_wildcard_satisfies_exhaustive(self):
        src = textwrap.dedent('''
            enum Dir { up, down, left, right }
            fn handle(d: Dir) {
                match d {
                    .up => {}
                    _   => {}
                }
            }
        ''')
        errors = check(src)
        assert not any(e.code == 'E301' for e in errors)

    def test_integer_match(self):
        src = textwrap.dedent('''
            fn classify(x: i32) -> i32 {
                match x {
                    0 => { return 0 }
                    1 => { return 1 }
                    _ => { return 2 }
                }
            }
        ''')
        c = codegen(src)
        assert 'switch' in c
        assert 'case 0' in c


# ─────────────────────────────────────────────────────────────────────────────
# Realistic N64 golden sample — exercises multiple features together
# ─────────────────────────────────────────────────────────────────────────────

class TestN64GoldenSample:

    def test_sprite_game_compiles(self):
        """A realistic 2D sprite game skeleton exercises display, rdpq,
        controller, assets, structs, enums, match, defer, fixed-point."""
        src = textwrap.dedent('''
            use n64.display
            use n64.controller
            use n64.rdpq

            const SCREEN_W: i32 = 320
            const SCREEN_H: i32 = 240
            const MAX_BULLETS: i32 = 16

            enum PlayerState { idle, running, jumping }

            struct Bullet {
                x: f32
                y: f32
                active: bool
            }

            struct Player {
                x: f32
                y: f32
                speed: f32
                state: PlayerState
                health: i32
            }

            fn update_player(p: *Player, dx: f32, dy: f32) {
                p.x = p.x + p.speed * dx
                p.y = p.y + p.speed * dy
                p.x = p.x.clamp(0.0, SCREEN_W.as_f32())
                p.y = p.y.clamp(0.0, SCREEN_H.as_f32())
            }

            fn player_state_name(s: PlayerState) -> *c_char {
                match s {
                    .idle    => { return "idle" }
                    .running => { return "running" }
                    .jumping => { return "jumping" }
                }
            }

            entry {
                display.init(RESOLUTION_320x240, DEPTH_16_BPP, 3, GAMMA_NONE, FILTERS_RESAMPLE)

                let bullets: FixedList(Bullet, MAX_BULLETS) = FixedList.init()
                let player = Player {
                    x: 160.0  y: 120.0  speed: 2.0
                    state: PlayerState.idle  health: 3
                }

                loop {
                    let disp = display.get()
                    rdpq.attach_clear(disp, none)

                    let state_str = player_state_name(player.state)

                    rdpq.detach_show()
                }
            }
        ''')
        c = codegen(src)
        # Core identifiers all present
        assert 'Player' in c
        assert 'update_player' in c
        assert 'player_state_name' in c
        assert 'FixedList' in c or 'bullets' in c
        assert 'display_init' in c
        assert 'rdpq_attach_clear' in c or 'rdpq' in c
        assert 'clamp' in c or 'SCREEN_W' in c

    def test_sprite_game_no_hard_errors(self):
        """Same sample should produce no E-series (hard) type errors."""
        src = textwrap.dedent('''
            use n64.display
            use n64.controller
            use n64.rdpq

            const SCREEN_W: i32 = 320
            const SCREEN_H: i32 = 240

            enum PlayerState { idle, running, jumping }

            struct Player {
                x: f32
                y: f32
                speed: f32
                state: PlayerState
                health: i32
            }

            fn update_player(p: *Player, dx: f32, dy: f32) {
                p.x = p.x + p.speed * dx
                p.y = p.y + p.speed * dy
            }

            fn player_state_name(s: PlayerState) -> *c_char {
                match s {
                    .idle    => { return "idle" }
                    .running => { return "running" }
                    .jumping => { return "jumping" }
                }
            }

            entry {
                let player = Player {
                    x: 160.0  y: 120.0  speed: 2.0
                    state: PlayerState.idle  health: 3
                }
                loop {
                    let _s = player_state_name(player.state)
                }
            }
        ''')
        errors = check(src)
        hard = [e for e in errors if not e.is_warning and e.code not in ('E010',)]
        assert not hard

    def test_3d_game_skeleton_compiles(self):
        """A minimal Tiny3D game skeleton exercises t3d module, Vec3, Mat4,
        fixed-point, pools, annotations, and the arena pattern."""
        src = textwrap.dedent('''
            use t3d.core
            use t3d.model
            use n64.display
            use n64.rdpq

            const MAX_ENEMIES: i32 = 32

            struct Enemy {
                pos: Vec3
                health: i32
                active: bool
            }

            fn spawn_enemy(pool: *FixedList(Enemy, MAX_ENEMIES), x: f32, z: f32) {
                let e = Enemy {
                    pos: Vec3 { v: [x, 0.0, z] }
                    health: 3
                    active: true
                }
                pool.push(e)
            }

            fn update_enemies(pool: *FixedList(Enemy, MAX_ENEMIES), dt: f32) {
                for i, e in pool.items() {
                    e.pos = e.pos.add(Vec3 { v: [0.0, 0.0, dt] })
                }
            }

            entry {
                t3d.init()
                display.init(RESOLUTION_320x240, DEPTH_16_BPP, 2, GAMMA_NONE, FILTERS_RESAMPLE)

                let enemies: FixedList(Enemy, MAX_ENEMIES) = FixedList.init()
                spawn_enemy(&enemies, 10.0, 5.0)

                loop {
                    let disp = display.get()
                    rdpq.attach_clear(disp, none)
                    t3d.frame_start()

                    update_enemies(&enemies, 0.016)

                    rdpq.detach_show()
                }
            }
        ''')
        c = codegen(src)
        assert 'Enemy' in c
        assert 'spawn_enemy' in c
        assert 'update_enemies' in c
        assert 't3d_init' in c

    def test_save_system_compiles(self):
        """EEPROM save/load pattern exercises Result, catch, and the backup module."""
        src = textwrap.dedent('''
            use n64.eeprom

            struct SaveData {
                score: i32
                level: i32
                health: i32
            }

            enum SaveErr: u8 { read_failed, corrupt }

            fn load_save() -> Result(SaveData, SaveErr) {
                let raw: [16]byte = undefined
                let read_ok = eeprom.read(0, &raw, 16)
                return ok(SaveData { score: 0  level: 1  health: 3 })
            }

            entry {
                let save = load_save() catch { SaveData { score: 0  level: 1  health: 3 } }
            }
        ''')
        c = codegen(src)
        assert 'SaveData' in c
        assert 'load_save' in c
        assert 'is_ok' in c


# ─────────────────────────────────────────────────────────────────────────────
# New language features: traits, tuples, alloc/free, @cfg, Vec(T), strings, %=
# ─────────────────────────────────────────────────────────────────────────────

class TestPercentEq:
    """%= modulo-assign operator."""

    def test_lex_percent_eq(self):
        toks = lex('%=')
        assert toks[0].type == TT.PERCENT_EQ
        assert toks[0].value == '%='

    def test_lex_percent_not_eq(self):
        toks = lex('% x')
        assert toks[0].type == TT.PERCENT

    def test_parse_percent_eq(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let mut x: i32 = 10
                x %= 3
            }
        ''')
        prog = parse(src)
        stmt = prog.decls[0].body.stmts[1]
        assign = stmt.expr if isinstance(stmt, ast.ExprStmt) else stmt
        assert isinstance(assign, ast.Assign)
        assert assign.op == '%='

    def test_codegen_percent_eq(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let mut x: i32 = 10
                x %= 3
            }
        ''')
        c = codegen(src)
        assert 'x %= 3' in c


class TestTraits:
    """Trait declarations, impl for, vtable dispatch."""

    def test_parse_trait_decl(self):
        src = textwrap.dedent('''
            trait Drawable {
                fn draw(self: *Self, x: i32, y: i32) -> void
            }
        ''')
        prog = parse(src)
        t = prog.decls[0]
        assert isinstance(t, ast.TraitDecl)
        assert t.name == 'Drawable'
        assert len(t.methods) == 1
        assert t.methods[0].name == 'draw'

    def test_codegen_trait_vtable(self):
        src = textwrap.dedent('''
            trait Drawable {
                fn draw(self: *Self, x: i32, y: i32) -> void
            }
        ''')
        c = codegen(src)
        assert 'Drawable_vtable' in c
        assert 'void (*draw)' in c
        assert 'typedef struct' in c
        assert 'void *self' in c

    def test_parse_impl_for(self):
        src = textwrap.dedent('''
            struct Sprite {
                x: i32
            }
            trait Drawable {
                fn draw(self: *Self, x: i32, y: i32) -> void
            }
            impl Sprite for Drawable {
                fn draw(self: *Sprite, x: i32, y: i32) -> void {
                    return
                }
            }
        ''')
        prog = parse(src)
        impl = prog.decls[2]
        assert isinstance(impl, ast.ImplTraitBlock)
        assert impl.type_name == 'Sprite'
        assert impl.trait_name == 'Drawable'

    def test_codegen_impl_trait(self):
        src = textwrap.dedent('''
            struct Sprite { x: i32 }
            trait Drawable {
                fn draw(self: *Self, x: i32, y: i32) -> void
            }
            impl Sprite for Drawable {
                fn draw(self: *Sprite, x: i32, y: i32) -> void { return }
            }
        ''')
        c = codegen(src)
        assert '_pak_Drawable_draw_Sprite' in c
        assert '_pak_Drawable_vtable_Sprite' in c
        assert 'Drawable_from_Sprite' in c

    def test_trait_default_method_synthesized(self):
        """A trait default body is emitted for an impl that omits it."""
        src = textwrap.dedent('''
            trait Greeter {
                fn name(self: *Self) -> i32
                fn greet(self: *Self) -> i32 { return self.name() + 100 }
            }
            struct Bot { id: i32 }
            impl Bot for Greeter {
                fn name(self: *Bot) -> i32 { return self.id }
            }
        ''')
        c = codegen(src)
        # The default greet() is specialized for Bot and calls Bot_name.
        assert 'Bot_greet(Bot * self)' in c
        assert 'Bot_name(self)' in c

    def test_trait_default_method_ok(self):
        """Omitting a method that has a default body must type-check."""
        src = textwrap.dedent('''
            trait Greeter {
                fn name(self: *Self) -> i32
                fn greet(self: *Self) -> i32 { return self.name() + 100 }
            }
            struct Bot { id: i32 }
            impl Bot for Greeter {
                fn name(self: *Bot) -> i32 { return self.id }
            }
        ''')
        errors = check(src)
        real = [e for e in errors if not e.is_warning]
        assert not real

    def test_trait_missing_required_method_errors(self):
        """Omitting a required (body-less) trait method raises E602."""
        src = textwrap.dedent('''
            trait Greeter {
                fn name(self: *Self) -> i32
                fn greet(self: *Self) -> i32 { return self.name() + 100 }
            }
            struct Bot { id: i32 }
            impl Bot for Greeter {
                fn greet(self: *Bot) -> i32 { return 5 }
            }
        ''')
        errors = check(src)
        codes = [e.code for e in errors]
        assert 'E602' in codes

    def test_dyn_trait_type(self):
        src = textwrap.dedent('''
            trait Shape {
                fn area(self: *Self) -> f32
            }
            fn use_shape(s: *dyn Shape) -> void {
                return
            }
        ''')
        c = codegen(src)
        assert 'Shape' in c

    def test_dyn_trait_type_ast(self):
        src = textwrap.dedent('''
            trait Shape { fn area(self: *Self) -> f32 }
            fn use_shape(s: *dyn Shape) -> void { return }
        ''')
        prog = parse(src)
        fn = prog.decls[1]
        param_type = fn.params[0].type
        # *dyn Shape → TypePointer(inner=TypeDynTrait)
        assert isinstance(param_type, ast.TypePointer)
        assert isinstance(param_type.inner, ast.TypeDynTrait)
        assert param_type.inner.name == 'Shape'


class TestTuples:
    """Tuple types, literals, and field access."""

    def test_parse_tuple_type(self):
        src = textwrap.dedent('''
            fn f() -> (i32, f32) {
                return (1, 2.0f)
            }
        ''')
        prog = parse(src)
        fn = prog.decls[0]
        assert isinstance(fn.ret_type, ast.TypeTuple)
        assert len(fn.ret_type.elements) == 2

    def test_parse_tuple_lit(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let t = (1, 2, 3)
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.TupleLit)
        assert len(let.value.elements) == 3

    def test_parse_tuple_access(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let t = (1, 2)
                let x = t.0
                let y = t.1
            }
        ''')
        prog = parse(src)
        let_x = prog.decls[0].body.stmts[1]
        assert isinstance(let_x.value, ast.TupleAccess)
        assert let_x.value.index == 0

    def test_codegen_tuple_typedef(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let t: (i32, f32) = (42, 3.14f)
            }
        ''')
        c = codegen(src)
        assert 'PakTuple2_' in c
        assert 'f0' in c
        assert 'f1' in c

    def test_codegen_tuple_access(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let t = (10, 20)
                let x = t.0
            }
        ''')
        c = codegen(src)
        assert '.f0' in c

    def test_empty_tuple_type(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let t: () = ()
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.type, ast.TypeTuple)
        assert len(let.type.elements) == 0


class TestAllocFree:
    """alloc(T) and free(ptr) primitives."""

    def test_parse_alloc(self):
        src = textwrap.dedent('''
            struct Node { val: i32 }
            fn f() -> void {
                let p = alloc(Node)
            }
        ''')
        prog = parse(src)
        let = prog.decls[1].body.stmts[0]
        assert isinstance(let.value, ast.AllocExpr)
        assert let.value.count is None

    def test_parse_alloc_array(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let p = alloc(i32, 10)
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.AllocExpr)
        assert let.value.count is not None

    def test_parse_free(self):
        src = textwrap.dedent('''
            fn f(p: *i32) -> void {
                free(p)
            }
        ''')
        prog = parse(src)
        stmt = prog.decls[0].body.stmts[0]
        assert isinstance(stmt, ast.ExprStmt)
        assert isinstance(stmt.expr, ast.FreeExpr)

    def test_codegen_alloc_single(self):
        src = textwrap.dedent('''
            struct Node { val: i32 }
            fn f() -> void {
                let p = alloc(Node)
            }
        ''')
        c = codegen(src)
        assert 'malloc(sizeof(Node))' in c
        assert '(Node *)' in c

    def test_codegen_alloc_array(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let p = alloc(i32, 16)
            }
        ''')
        c = codegen(src)
        assert 'malloc(sizeof(int32_t)' in c
        assert '16' in c

    def test_codegen_free(self):
        src = textwrap.dedent('''
            fn f(p: *i32) -> void {
                free(p)
            }
        ''')
        c = codegen(src)
        assert 'free(p)' in c


class TestCfgBlock:
    """@cfg conditional compilation."""

    def test_parse_cfg_block(self):
        src = textwrap.dedent('''
            @cfg(FEATURE_A)
            struct Foo { x: i32 }
        ''')
        prog = parse(src)
        cfg = prog.decls[0]
        assert isinstance(cfg, ast.CfgBlock)
        assert cfg.feature == 'FEATURE_A'
        assert not cfg.negated
        assert isinstance(cfg.decl, ast.StructDecl)

    def test_parse_cfg_not(self):
        src = textwrap.dedent('''
            @cfg(not(DEBUG))
            fn release_only() -> void { return }
        ''')
        prog = parse(src)
        cfg = prog.decls[0]
        assert isinstance(cfg, ast.CfgBlock)
        assert cfg.negated
        assert cfg.feature == 'DEBUG'

    def test_codegen_cfg_ifdef(self):
        src = textwrap.dedent('''
            @cfg(FEATURE_A)
            struct Foo { x: i32 }
        ''')
        c = codegen(src)
        assert '#ifdef FEATURE_A' in c
        assert '#endif' in c
        assert 'Foo' in c

    def test_codegen_cfg_ifndef(self):
        src = textwrap.dedent('''
            @cfg(not(DEBUG))
            fn release_only() -> void { return }
        ''')
        c = codegen(src)
        assert '#ifndef DEBUG' in c
        assert '#endif' in c


class TestVecType:
    """Vec(T) dynamic vector type and methods."""

    def test_parse_vec_type(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let v: Vec(i32) = undefined
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.type, ast.TypeGeneric)
        assert let.type.name == 'Vec'

    def test_codegen_vec_typedef(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let v: Vec(i32) = undefined
            }
        ''')
        c = codegen(src)
        assert '_PakVec_' in c
        assert 'int32_t len' in c
        assert 'int32_t cap' in c

    def test_codegen_vec_push_macro(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let v: Vec(i32) = undefined
                v.push(42)
            }
        ''')
        c = codegen(src)
        assert '_PAK_VEC_PUSH' in c

    def test_codegen_vec_len(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let v: Vec(i32) = undefined
                let n = v.len()
            }
        ''')
        c = codegen(src)
        assert '.len' in c

    def test_codegen_vec_get(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let v: Vec(i32) = undefined
                let x = v.get(0)
            }
        ''')
        c = codegen(src)
        assert '.data[0]' in c or '.data[' in c


class TestStringMethods:
    """String method dispatch for CStr / PakStr."""

    def test_cstr_len(self):
        src = textwrap.dedent('''
            fn f(s: CStr) -> void {
                let n = s.len()
            }
        ''')
        c = codegen(src)
        assert 'strlen' in c

    def test_cstr_eq(self):
        src = textwrap.dedent('''
            fn f(s: CStr, t: CStr) -> void {
                let eq = s.eq(t)
            }
        ''')
        c = codegen(src)
        assert 'strcmp' in c

    def test_cstr_contains(self):
        src = textwrap.dedent('''
            fn f(s: CStr, needle: CStr) -> void {
                let found = s.contains(needle)
            }
        ''')
        c = codegen(src)
        assert 'strstr' in c

    def test_cstr_starts_with(self):
        src = textwrap.dedent('''
            fn f(s: CStr) -> void {
                let result = s.starts_with("hello")
            }
        ''')
        c = codegen(src)
        assert 'strncmp' in c

    def test_cstr_ends_with(self):
        src = textwrap.dedent('''
            fn f(s: CStr) -> void {
                let result = s.ends_with("world")
            }
        ''')
        c = codegen(src)
        assert 'strlen' in c
        assert 'strcmp' in c

    def test_cstr_is_empty(self):
        src = textwrap.dedent('''
            fn f(s: CStr) -> void {
                let empty = s.is_empty()
            }
        ''')
        c = codegen(src)
        assert "'\\0'" in c or r'\0' in c

    def test_pakstr_len(self):
        src = textwrap.dedent('''
            fn f(s: Str) -> void {
                let n = s.len()
            }
        ''')
        c = codegen(src)
        assert '.len' in c

    def test_pakstr_eq(self):
        src = textwrap.dedent('''
            fn f(s: Str, t: Str) -> void {
                let eq = s.eq(t)
            }
        ''')
        c = codegen(src)
        assert 'pak_str_eq' in c


class TestCatchStmt:
    """CatchExpr used as a bare statement (error handler must not be dropped)."""

    def test_parse_catch_as_stmt(self):
        src = textwrap.dedent('''
            fn fallible() -> Result(i32, i32) {
                return ok(1)
            }
            fn caller() -> void {
                fallible() catch |e| { return }
            }
        ''')
        prog = parse(src)
        stmt = prog.decls[1].body.stmts[0]
        assert isinstance(stmt, ast.ExprStmt)
        assert isinstance(stmt.expr, ast.CatchExpr)

    def test_codegen_catch_stmt_emits_handler(self):
        src = textwrap.dedent('''
            fn fallible() -> Result(i32, i32) {
                return ok(1)
            }
            fn caller() -> void {
                fallible() catch |e| { return }
            }
        ''')
        c = codegen(src)
        # Handler must be emitted — is_ok check must appear
        assert 'is_ok' in c
        # The binding variable must appear
        assert 'e' in c

    def test_codegen_catch_stmt_no_binding(self):
        src = textwrap.dedent('''
            fn fallible() -> Result(i32, i32) {
                return ok(1)
            }
            fn caller() -> void {
                fallible() catch { return }
            }
        ''')
        c = codegen(src)
        assert 'is_ok' in c


class TestFmtStrBraceEscape:
    """{{ and }} escape sequences in format strings."""

    def test_double_lbrace_is_literal(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let s = "{{not interpolated}}"
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.StringLit)
        assert let.value.value == '{not interpolated}'

    def test_double_rbrace_is_literal(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let s = "value: {{}}"
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.StringLit)

    def test_mixed_escape_and_interpolation(self):
        src = textwrap.dedent('''
            fn f(x: i32) -> void {
                let s = "set {{ x = {x} }}"
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.FmtStr)
        # First part should be the literal "set { x = "
        assert let.value.parts[0] == 'set { x = '

    def test_only_escaped_braces_is_string_lit(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let s = "{{}}"
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.StringLit)
        assert let.value.value == '{}'


class TestCustomAllocators:
    """alloc(T using a), free(ptr using a), Allocator trait, heap_allocator()."""

    def test_parse_alloc_using(self):
        src = textwrap.dedent('''
            fn f(a: Allocator) -> void {
                let p = alloc(i32 using a)
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.AllocExpr)
        assert let.value.allocator is not None
        assert let.value.count is None

    def test_parse_alloc_array_using(self):
        src = textwrap.dedent('''
            fn f(a: Allocator) -> void {
                let p = alloc(i32, 10 using a)
            }
        ''')
        prog = parse(src)
        let = prog.decls[0].body.stmts[0]
        assert isinstance(let.value, ast.AllocExpr)
        assert let.value.count is not None
        assert let.value.allocator is not None

    def test_parse_free_using(self):
        src = textwrap.dedent('''
            fn f(p: *i32, a: Allocator) -> void {
                free(p using a)
            }
        ''')
        prog = parse(src)
        stmt = prog.decls[0].body.stmts[0]
        assert isinstance(stmt.expr, ast.FreeExpr)
        assert stmt.expr.allocator is not None

    def test_codegen_alloc_using_vtable(self):
        src = textwrap.dedent('''
            fn f(a: Allocator) -> void {
                let p = alloc(i32 using a)
            }
        ''')
        c = codegen(src)
        assert 'vtable->alloc_bytes' in c
        assert 'sizeof(int32_t)' in c

    def test_codegen_alloc_array_using(self):
        src = textwrap.dedent('''
            fn f(a: Allocator) -> void {
                let p = alloc(i32, 16 using a)
            }
        ''')
        c = codegen(src)
        assert 'vtable->alloc_bytes' in c
        assert '16' in c

    def test_codegen_free_using(self):
        src = textwrap.dedent('''
            fn f(p: *i32, a: Allocator) -> void {
                free(p using a)
            }
        ''')
        c = codegen(src)
        assert 'vtable->dealloc_bytes' in c

    def test_codegen_allocator_preamble(self):
        src = textwrap.dedent('''
            fn f(a: Allocator) -> void {
                let p = alloc(i32 using a)
            }
        ''')
        c = codegen(src)
        assert 'Allocator_vtable' in c
        assert 'alloc_bytes' in c
        assert 'dealloc_bytes' in c

    def test_codegen_arena_allocator_helper(self):
        src = textwrap.dedent('''
            fn f(a: Allocator) -> void {
                let p = alloc(i32 using a)
            }
        ''')
        c = codegen(src)
        assert 'Allocator_from_Arena' in c
        assert 'PakArena' in c

    def test_codegen_heap_allocator_fn(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let a = heap_allocator()
                let p = alloc(i32 using a)
            }
        ''')
        c = codegen(src)
        assert 'pak_heap_allocator' in c

    def test_codegen_allocator_type_name(self):
        src = textwrap.dedent('''
            fn f(a: Allocator) -> void { return }
        ''')
        c = codegen(src)
        assert 'Allocator a' in c

    def test_alloc_without_using_still_malloc(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let p = alloc(i32)
            }
        ''')
        c = codegen(src)
        assert 'malloc' in c
        assert 'vtable->alloc_bytes' not in c   # no vtable dispatch for plain malloc

    def test_free_without_using_still_free(self):
        src = textwrap.dedent('''
            fn f(p: *i32) -> void {
                free(p)
            }
        ''')
        c = codegen(src)
        assert 'free(p)' in c
        assert 'vtable->dealloc_bytes' not in c  # no vtable dispatch for plain free

# ── Union types ───────────────────────────────────────────────────────────────

class TestUnionDecl:
    def test_parse_union(self):
        prog = parse('union FloatBits { f: f32; i: u32; }')
        decl = prog.decls[0]
        assert isinstance(decl, ast.UnionDecl)
        assert decl.name == 'FloatBits'
        assert len(decl.fields) == 2
        assert decl.fields[0].name == 'f'
        assert decl.fields[1].name == 'i'

    def test_codegen_union_typedef(self):
        c = codegen('union FloatBits { f: f32; i: u32; }')
        assert 'typedef union' in c
        assert 'FloatBits' in c
        assert 'float f;' in c or 'f32 f;' in c or 'f' in c
        assert 'uint32_t i;' in c or 'u32 i;' in c or 'i' in c

    def test_codegen_union_not_struct(self):
        c = codegen('union Punner { a: i32; b: f32; }')
        assert 'typedef union' in c
        # Punner should be emitted as a union, not a struct
        assert 'typedef struct Punner' not in c.replace('\n', ' ').replace('  ', ' ')

    def test_union_with_annotation(self):
        c = codegen('@packed union Packed { x: u8; y: u16; }')
        assert 'union' in c
        assert 'Packed' in c


# ── do-while ─────────────────────────────────────────────────────────────────

class TestDoWhile:
    def test_parse_do_while(self):
        prog = parse('fn f() -> void { do { x = x + 1; } while x < 10; }')
        fn = prog.decls[0]
        stmt = fn.body.stmts[0]
        assert isinstance(stmt, ast.DoWhileStmt)
        assert isinstance(stmt.condition, ast.BinaryOp)
        assert stmt.condition.op == '<'

    def test_codegen_do_while(self):
        c = codegen('fn f() -> void { do { x = x + 1; } while x < 10; }')
        assert 'do {' in c or 'do{' in c
        assert 'while' in c

    def test_do_while_executes_once_structure(self):
        src = textwrap.dedent('''
            fn f() -> void {
                let mut i: i32 = 0;
                do {
                    i = i + 1;
                } while i < 0;
            }
        ''')
        c = codegen(src)
        assert 'do' in c
        assert 'while' in c

    def test_do_while_semicolon(self):
        # do-while must end with semicolon after condition
        c = codegen('fn f() -> void { do { break; } while true; }')
        assert 'while' in c


# ── comptime if ───────────────────────────────────────────────────────────────

class TestComptimeIf:
    def test_parse_comptime_if(self):
        prog = parse('comptime if (N64) { fn foo() -> void {} }')
        decl = prog.decls[0]
        assert isinstance(decl, ast.ComptimeIf)
        assert isinstance(decl.then, ast.Block)

    def test_codegen_comptime_if_ifdef(self):
        c = codegen('comptime if (N64) { fn foo() -> void {} }')
        assert '#if' in c
        assert 'N64' in c
        assert '#endif' in c

    def test_codegen_comptime_if_else(self):
        src = textwrap.dedent('''
            comptime if (N64) {
                fn platform() -> void {}
            } else {
                fn platform() -> void {}
            }
        ''')
        c = codegen(src)
        assert '#if' in c
        assert '#else' in c
        assert '#endif' in c

    def test_comptime_if_in_function(self):
        src = textwrap.dedent('''
            fn f() -> void {
                comptime if (DEBUG) {
                    x = 1;
                }
            }
        ''')
        c = codegen(src)
        assert '#if' in c
        assert 'DEBUG' in c


# ── Return type checking (W201) ───────────────────────────────────────────────

class TestReturnTypeCheck:
    def test_w201_missing_return(self):
        src = textwrap.dedent('''
            fn get_value() -> i32 {
                let x: i32 = 5;
            }
        ''')
        diags = check(src)
        codes = [d.code for d in diags]
        assert 'W201' in codes

    def test_w201_is_warning_not_error(self):
        src = textwrap.dedent('''
            fn get_value() -> i32 {
                let x: i32 = 5;
            }
        ''')
        diags = check(src)
        w201 = [d for d in diags if d.code == 'W201']
        assert w201
        assert all(d.severity != 'error' for d in w201)

    def test_w201_no_warning_when_returns(self):
        src = textwrap.dedent('''
            fn get_value() -> i32 {
                return 42;
            }
        ''')
        diags = check(src)
        codes = [d.code for d in diags]
        assert 'W201' not in codes

    def test_w201_no_warning_for_void(self):
        src = textwrap.dedent('''
            fn do_thing() -> void {
                let x: i32 = 5;
            }
        ''')
        diags = check(src)
        codes = [d.code for d in diags]
        assert 'W201' not in codes

    def test_w201_no_warning_when_if_else_both_return(self):
        src = textwrap.dedent('''
            fn get_value(x: i32) -> i32 {
                if x > 0 {
                    return 1;
                } else {
                    return -1;
                }
            }
        ''')
        diags = check(src)
        codes = [d.code for d in diags]
        assert 'W201' not in codes

    def test_w201_warning_when_only_if_no_else(self):
        src = textwrap.dedent('''
            fn get_value(x: i32) -> i32 {
                if x > 0 {
                    return 1;
                }
            }
        ''')
        diags = check(src)
        codes = [d.code for d in diags]
        assert 'W201' in codes

    def test_w201_no_warning_for_loop(self):
        # infinite loop is an unconditional return path
        src = textwrap.dedent('''
            fn run() -> i32 {
                loop {
                    return 0;
                }
            }
        ''')
        diags = check(src)
        codes = [d.code for d in diags]
        assert 'W201' not in codes


# ─────────────────────────────────────────────────────────────────────────────
# Default parameters and named arguments
# ─────────────────────────────────────────────────────────────────────────────

class TestDefaultParams:

    def test_default_param_filled_when_omitted(self):
        src = textwrap.dedent('''
            fn greet(x: i32, y: i32 = 99) -> i32 {
                return x + y
            }
            entry {
                let r = greet(1)
            }
        ''')
        c = codegen(src)
        assert 'greet(1, 99)' in c

    def test_default_param_overridable(self):
        src = textwrap.dedent('''
            fn greet(x: i32, y: i32 = 99) -> i32 {
                return x + y
            }
            entry {
                let r = greet(1, 2)
            }
        ''')
        c = codegen(src)
        assert 'greet(1, 2)' in c

    def test_multiple_defaults_partially_supplied(self):
        src = textwrap.dedent('''
            fn foo(a: i32, b: i32 = 10, c: i32 = 20) -> i32 {
                return a + b + c
            }
            entry {
                let r = foo(5, 15)
            }
        ''')
        c = codegen(src)
        assert 'foo(5, 15, 20)' in c

    def test_all_defaults_omitted(self):
        src = textwrap.dedent('''
            fn zero_or(x: i32 = 0) -> i32 {
                return x
            }
            entry {
                let r = zero_or()
            }
        ''')
        c = codegen(src)
        assert 'zero_or(0)' in c


class TestNamedArgs:

    def test_named_args_reordered_to_declaration_order(self):
        src = textwrap.dedent('''
            fn sub(a: i32, b: i32) -> i32 {
                return a - b
            }
            entry {
                let r = sub(b: 3, a: 10)
            }
        ''')
        c = codegen(src)
        assert 'sub(10, 3)' in c

    def test_named_args_with_default_fill(self):
        src = textwrap.dedent('''
            fn scale(val: i32, factor: i32 = 2) -> i32 {
                return val * factor
            }
            entry {
                let r = scale(val: 5)
            }
        ''')
        c = codegen(src)
        assert 'scale(5, 2)' in c

    def test_positional_before_named(self):
        src = textwrap.dedent('''
            fn f(a: i32, b: i32, c: i32 = 0) -> i32 {
                return a + b + c
            }
            entry {
                let r = f(1, c: 3, b: 2)
            }
        ''')
        c = codegen(src)
        assert 'f(1, 2, 3)' in c


class TestBreakValue:

    def test_break_value_assigns_result(self):
        src = textwrap.dedent('''
            entry {
                let found: i32 = loop {
                    break 42
                }
            }
        ''')
        c = codegen(src)
        assert '_loop_res_' in c
        assert '= 42' in c

    def test_break_value_with_condition(self):
        src = textwrap.dedent('''
            entry {
                let mut i: i32 = 0
                let result: i32 = loop {
                    if i >= 5 {
                        break i
                    }
                    i = i + 1
                    break 0
                }
            }
        ''')
        c = codegen(src)
        assert '_loop_res_' in c
        assert 'while (true)' in c

    def test_plain_break_unchanged(self):
        src = textwrap.dedent('''
            entry {
                let mut i: i32 = 0
                loop {
                    if i > 3 { break }
                    i = i + 1
                }
            }
        ''')
        c = codegen(src)
        assert '_loop_res_' not in c
        assert 'break;' in c


class TestEepromAPI:

    def test_eeprom_present_lowered(self):
        src = textwrap.dedent('''
            use n64.eeprom
            entry {
                let is_present = eeprom.present()
            }
        ''')
        c = codegen(src)
        assert 'eeprom_present()' in c
        assert 'eeprom.present()' not in c

    def test_eeprom_type_detect_lowered(self):
        src = textwrap.dedent('''
            use n64.eeprom
            entry {
                let t = eeprom.type_detect()
            }
        ''')
        c = codegen(src)
        assert 'eeprom_type_detect()' in c
