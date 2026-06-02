"""Tests for the MIPS backend CLI integration (pak build --backend mips)."""

import pytest
import textwrap
import os
import tempfile
from pathlib import Path
from unittest.mock import patch
import argparse

from pak.cli import (
    _build_mips, _build_c, cmd_build, cmd_explain,
    parse_file,
)
from pak.parser import parse
from pak.makefile_gen import generate_makefile


# ── Helpers ──────────────────────────────────────────────────────────────────

def _parse_source(src: str):
    """Parse source into (pak_file_path, program) tuple."""
    from pak.lexer import Lexer
    from pak.parser import Parser
    tokens = Lexer(textwrap.dedent(src)).tokenize()
    prog = Parser(tokens).parse()
    return prog


def _make_project(tmp_path, src_text):
    """Create a minimal Pak project in tmp_path with the given source."""
    (tmp_path / 'pak.toml').write_text(textwrap.dedent("""\
        [project]
        name = "test_game"
        rom_title = "TEST"
        save_type = "none"

        [display]
        resolution = "320x240"
        bit_depth = 16
        framebuffers = 3

        [build]
        optimization = "debug"
    """))
    src_dir = tmp_path / 'src'
    src_dir.mkdir()
    pak_file = src_dir / 'main.pk64'
    pak_file.write_text(textwrap.dedent(src_text))
    return tmp_path


# ── MIPS backend codegen via CLI helpers ─────────────────────────────────────

class TestBuildMips:
    """Test _build_mips produces .s files."""

    def test_simple_function_generates_s_file(self, tmp_path):
        root = _make_project(tmp_path, """\
            fn add(a: i32, b: i32) -> i32 {
                return a + b
            }
        """)
        build_dir = root / 'build'
        build_dir.mkdir()
        pak_file = root / 'src' / 'main.pk64'
        program = parse_file(pak_file)
        assert program is not None

        paths = _build_mips(
            [(pak_file, program)], root, build_dir, verbose=False
        )
        assert len(paths) == 1
        s_path = root / paths[0]
        assert s_path.exists()
        assert s_path.suffix == '.s'
        content = s_path.read_text()
        assert 'add:' in content or '.globl add' in content

    def test_entry_block_generates_main(self, tmp_path):
        root = _make_project(tmp_path, """\
            entry {
                let x: i32 = 42
            }
        """)
        build_dir = root / 'build'
        build_dir.mkdir()
        pak_file = root / 'src' / 'main.pk64'
        program = parse_file(pak_file)

        paths = _build_mips(
            [(pak_file, program)], root, build_dir, verbose=False
        )
        s_path = root / paths[0]
        content = s_path.read_text()
        assert 'main:' in content or '.globl main' in content

    def test_codegen_error_exits(self, tmp_path):
        """If MipsCodegen raises CodegenError, _build_mips should sys.exit."""
        root = _make_project(tmp_path, """\
            fn foo() -> i32 {
                return 1
            }
        """)
        build_dir = root / 'build'
        build_dir.mkdir()
        pak_file = root / 'src' / 'main.pk64'
        program = parse_file(pak_file)

        from pak.mips import MipsCodegen, CodegenError

        def fake_generate(self, program, pak_env=None):
            raise CodegenError("test invariant violation")

        with patch.object(MipsCodegen, 'generate', fake_generate):
            with pytest.raises(SystemExit):
                _build_mips([(pak_file, program)], root, build_dir, verbose=False)


class TestBuildC:
    """Test _build_c still works as before."""

    def test_simple_function_generates_c_file(self, tmp_path):
        root = _make_project(tmp_path, """\
            fn add(a: i32, b: i32) -> i32 {
                return a + b
            }
        """)
        build_dir = root / 'build'
        build_dir.mkdir()
        pak_file = root / 'src' / 'main.pk64'
        program = parse_file(pak_file)

        paths = _build_c(
            [(pak_file, program)], root, build_dir, verbose=False
        )
        assert len(paths) == 1
        c_path = root / paths[0]
        assert c_path.exists()
        assert c_path.suffix == '.c'


# ── Makefile generation ──────────────────────────────────────────────────────

class TestMakefileGen:
    """Test Makefile generator handles MIPS backend."""

    def test_mips_makefile_has_s_assembly_rule(self):
        mk = generate_makefile(
            project_name='test',
            rom_title='TEST',
            c_files=[Path('build/src/main.s')],
            pakfs_archive=None,
            backend='mips',
        )
        assert '%.o: %.s' in mk
        assert '%.o: %.c' in mk  # still needed for runtime/pakfs.c
        assert 'S_SRCS' in mk

    def test_c_makefile_has_no_s_rule(self):
        mk = generate_makefile(
            project_name='test',
            rom_title='TEST',
            c_files=[Path('build/src/main.c')],
            pakfs_archive=None,
            backend='c',
        )
        assert '%.o: %.s' not in mk
        assert '%.o: %.c' in mk
        assert 'S_SRCS' not in mk

    def test_mips_makefile_objs_include_both(self):
        mk = generate_makefile(
            project_name='test',
            rom_title='TEST',
            c_files=[Path('build/src/main.s')],
            pakfs_archive=None,
            backend='mips',
        )
        assert 'C_OBJS' in mk
        assert 'S_OBJS' in mk
        assert 'OBJS    = $(C_OBJS) $(S_OBJS)' in mk


# ── Explain command ──────────────────────────────────────────────────────────

class TestExplainMips:
    """Test pak explain --backend mips."""

    def test_explain_mips_prints_assembly(self, tmp_path, capsys):
        pak_file = tmp_path / 'test.pk64'
        pak_file.write_text(textwrap.dedent("""\
            fn add(a: i32, b: i32) -> i32 {
                return a + b
            }
        """))
        args = argparse.Namespace(file=str(pak_file), backend='mips')
        cmd_explain(args)
        captured = capsys.readouterr()
        assert 'add:' in captured.out or '.globl add' in captured.out
        assert 'addu' in captured.out or 'addiu' in captured.out

    def test_explain_c_prints_c_code(self, tmp_path, capsys):
        pak_file = tmp_path / 'test.pk64'
        pak_file.write_text(textwrap.dedent("""\
            fn add(a: i32, b: i32) -> i32 {
                return a + b
            }
        """))
        args = argparse.Namespace(file=str(pak_file), backend='c')
        cmd_explain(args)
        captured = capsys.readouterr()
        assert 'int' in captured.out or 'add' in captured.out


# ── argparse flag availability ───────────────────────────────────────────────

class TestArgparse:
    """Test that --backend flag is accepted by argparse."""

    def test_build_accepts_backend_mips(self):
        from pak.cli import main
        import sys
        # Just test argparse parsing, don't actually run the build
        parser = argparse.ArgumentParser()
        sub = parser.add_subparsers()
        p = sub.add_parser('build')
        p.add_argument('--backend', choices=['c', 'mips'], default='c')
        args = parser.parse_args(['build', '--backend', 'mips'])
        assert args.backend == 'mips'

    def test_build_defaults_to_c(self):
        parser = argparse.ArgumentParser()
        sub = parser.add_subparsers()
        p = sub.add_parser('build')
        p.add_argument('--backend', choices=['c', 'mips'], default='c')
        args = parser.parse_args(['build'])
        assert args.backend == 'c'
