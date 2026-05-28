"""Pak CLI - command-line interface for the Pak compiler."""

import sys
import os
import shutil
import argparse
import subprocess
import tomllib
from pathlib import Path
from typing import Optional, List

from .lexer import Lexer, LexError
from .parser import Parser, ParseError, parse
from .codegen import generate
from .typechecker import typecheck_multi, TypeEnv, PakError
from .checker import semantic_check, check_entry_blocks, CheckDiag
from .headergen import generate_header, module_to_filename, collect_module_includes
from . import ast as pak_ast
from .mips import MipsCodegen, CodegenError


def find_project_root(start: Path = None) -> Optional[Path]:
    """Walk up directories to find pak.toml."""
    current = start or Path.cwd()
    while current != current.parent:
        if (current / 'pak.toml').exists():
            return current
        current = current.parent
    return None


def runtime_dir() -> Path:
    """Return the path to the bundled runtime/ directory."""
    return Path(__file__).parent.parent / 'runtime'


def parse_file(pak_file: Path, verbose: bool = False) -> Optional[pak_ast.Program]:
    """Parse a .pak file and return the AST, or None on error."""
    source = pak_file.read_text(encoding='utf-8')
    if verbose:
        print(f'  Parsing {pak_file.name}...')
    try:
        return parse(source, str(pak_file))
    except LexError as e:
        print(f'error[E001]: {e}', file=sys.stderr)
        print(f'  --> {pak_file}', file=sys.stderr)
        return None
    except ParseError as e:
        print(f'error[E002]: {e}', file=sys.stderr)
        print(f'  --> {pak_file}', file=sys.stderr)
        return None


def compile_file(pak_file: Path, verbose: bool = False,
                 module_headers: dict = None) -> tuple:
    """Parse and generate C for a .pak file. Returns (c_source, program) or exits."""
    program = parse_file(pak_file, verbose)
    if program is None:
        sys.exit(1)

    if verbose:
        print(f'  Generating C for {pak_file.name}...')
    c_source = generate(program, str(pak_file), module_headers=module_headers)
    return c_source, program


def _print_errors(errors: List[PakError], pak_file: Path, root: Path = None) -> int:
    """Print type errors and return the count."""
    for err in errors:
        print(str(err), file=sys.stderr)
    return len(errors)


def load_config(root: Path) -> dict:
    toml_path = root / 'pak.toml'
    with open(toml_path, 'rb') as f:
        return tomllib.load(f)


def _get_module_path(program: pak_ast.Program) -> Optional[str]:
    """Return the module path declared in a program, if any."""
    for decl in program.decls:
        if isinstance(decl, pak_ast.ModuleDecl):
            return decl.path
    return None


def cmd_build(args):
    """Compile .pak → C, pack assets, and generate Makefile."""
    root = find_project_root()
    if root is None:
        print('error: no pak.toml found. Run `pak init <name>` to create a project.', file=sys.stderr)
        sys.exit(1)

    config = load_config(root)
    project = config.get('project', {})
    project_name = project.get('name', 'game')
    rom_title = project.get('rom_title', project_name.upper()[:20])
    save_type = project.get('save_type', 'none')

    display = config.get('display', {})
    resolution = display.get('resolution', '320x240')
    bit_depth = display.get('bit_depth', 16)
    framebuffers = display.get('framebuffers', 3)

    deps = config.get('dependencies', {})
    use_tiny3d = bool(deps.get('tiny3d', False))

    build_cfg = config.get('build', {})
    optimization = build_cfg.get('optimization', 'debug')

    verbose = getattr(args, 'verbose', False)
    no_style_warnings = getattr(args, 'no_style_warnings', False)
    backend = getattr(args, 'backend', 'c')

    print(f'Building {project_name} (backend: {backend})...')

    build_dir = root / 'build'
    build_dir.mkdir(exist_ok=True)

    # ── 1. Parse all .pak files ───────────────────────────────────────────────
    src_files = sorted(f for f in root.glob('**/*.pak') if 'build' not in f.parts)
    if not src_files:
        print('error: no .pak source files found', file=sys.stderr)
        sys.exit(1)

    parsed: list = []  # [(pak_file, program)]
    for pak_file in src_files:
        program = parse_file(pak_file, verbose)
        if program is None:
            sys.exit(1)
        parsed.append((pak_file, program))

    # ── 2. Type-check + extended semantic check ───────────────────────────────
    tc_input = [(str(pak_file), prog) for pak_file, prog in parsed]
    hard_errors, total_warnings = _run_full_check(tc_input, root, no_style_warnings)
    if total_warnings > 0 and not no_style_warnings:
        print(f'\n{total_warnings} style warning(s). Use --no-style-warnings to suppress.',
              file=sys.stderr)
    if hard_errors > 0:
        print(f'\n{hard_errors} error(s). Fix them before building.', file=sys.stderr)
        print('  Tip: run `pak check` for a detailed report.', file=sys.stderr)
        sys.exit(1)

    # ── 3–4. Code generation (backend-specific) ────────────────────────────────
    if backend == 'mips':
        out_rel_paths = _build_mips(parsed, root, build_dir, verbose)
        out_ext = '.s'
    else:
        out_rel_paths = _build_c(parsed, root, build_dir, verbose)
        out_ext = '.c'

    # ── 5. Copy runtime into project ──────────────────────────────────────────
    rt_src = runtime_dir()
    rt_dst = root / 'runtime'
    if rt_src.exists() and rt_src != rt_dst:
        rt_dst.mkdir(exist_ok=True)
        for f in rt_src.glob('*'):
            dst = rt_dst / f.name
            if not dst.exists():
                shutil.copy2(f, dst)
        print(f'  Runtime -> runtime/')

    # ── 6. Pack assets into PakFS archive ────────────────────────────────────
    # We pack the BUILD_DIR converted outputs, not raw source assets.
    # Conversion happens via Makefile rules at `make` time; here we only pack
    # what already exists in build/ (from a previous make or pre-converted files).
    # The Makefile pakfs rule will redo this after conversion.
    asset_dirs = config.get('assets', {})
    packable = []
    _CONVERT_EXT = {'.png': '.sprite', '.wav': '.wav64', '.xm': '.xm64',
                    '.ym': '.ym64', '.gltf': '.t3dm', '.glb': '.t3dm'}
    for kind, rel_dir in asset_dirs.items():
        asset_path = root / rel_dir
        if asset_path.is_dir():
            for f in sorted(asset_path.rglob('*')):
                if not f.is_file():
                    continue
                converted_ext = _CONVERT_EXT.get(f.suffix.lower())
                if converted_ext:
                    # Look for converted file in build dir
                    rel = f.relative_to(root)
                    converted = build_dir / rel.with_suffix(converted_ext)
                    if converted.exists():
                        arch_name = str(rel.with_suffix(converted_ext)).replace(os.sep, '/')
                        packable.append((arch_name, converted.read_bytes()))
                    # else: skip — make has not converted yet
                else:
                    # Non-convertible asset (e.g. .pak data files): pack as-is
                    name = str(f.relative_to(root)).replace(os.sep, '/')
                    packable.append((name, f.read_bytes()))

    has_assets = bool(packable)
    pakfs_name = f'{project_name}.pakfs'
    if packable:
        from .pakfs import pack
        fs_dir = root / 'filesystem'
        fs_dir.mkdir(exist_ok=True)
        pakfs_file = fs_dir / pakfs_name
        pakfs_file.write_bytes(pack(packable))
        print(f'  Packed {len(packable)} asset(s) -> filesystem/{pakfs_name}')

    # ── 7. Generate Makefile ──────────────────────────────────────────────────
    from .makefile_gen import generate_makefile
    makefile = generate_makefile(
        project_name=project_name,
        rom_title=rom_title,
        c_files=out_rel_paths,
        pakfs_archive=pakfs_name if has_assets else None,
        save_type=save_type,
        bit_depth=bit_depth,
        resolution=resolution,
        framebuffers=framebuffers,
        optimization=optimization,
        use_tiny3d=use_tiny3d,
        project_root=root,
        backend=backend,
    )
    makefile_path = root / 'Makefile'
    makefile_path.write_text(makefile, encoding='utf-8')
    print(f'  Generated Makefile')

    print()
    print(f'Build complete. Next steps:')
    print(f'  1. Set N64_INST to your libdragon installation (export N64_INST=/opt/libdragon)')
    if use_tiny3d:
        print(f'  2. Set TINY3D_INST to your Tiny3D installation')
        print(f'  3. Run: make')
    else:
        print(f'  2. Run: make')
    print(f'  3. Run: make run   (launches in ares emulator)')


def _build_c(parsed, root, build_dir, verbose):
    """Generate C code and headers for all parsed programs. Returns list of relative paths."""
    # Generate headers for modules
    module_headers: dict = {}
    for pak_file, program in parsed:
        mod_path = _get_module_path(program)
        if mod_path:
            header_name = module_to_filename(mod_path)
            h_file = build_dir / header_name
            module_headers[mod_path] = header_name
            h_source = generate_header(program, mod_path)
            h_file.write_text(h_source, encoding='utf-8')
            if verbose:
                rel = pak_file.relative_to(root)
                print(f'  Header  {rel} -> {h_file.relative_to(root)}')

    # Compile .pak → .c
    c_rel_paths = []
    for pak_file, program in parsed:
        rel = pak_file.relative_to(root)
        c_file = build_dir / rel.with_suffix('.c')
        c_file.parent.mkdir(parents=True, exist_ok=True)

        if verbose:
            print(f'  Generating C for {rel}...')
        c_source = generate(program, str(pak_file), module_headers=module_headers)
        c_file.write_text(c_source, encoding='utf-8')
        c_rel_paths.append(c_file.relative_to(root))
        print(f'  Compiled {rel} -> {c_file.relative_to(root)}')

    return c_rel_paths


def _build_mips(parsed, root, build_dir, verbose):
    """Generate MIPS assembly for all parsed programs. Returns list of relative paths."""
    # Run typechecker to get TypeEnv for codegen
    tc_input = [(str(pf), prog) for pf, prog in parsed]
    from .typechecker import typecheck_multi
    typecheck_multi(tc_input)  # we already checked; this just gives us the env

    s_rel_paths = []
    for pak_file, program in parsed:
        rel = pak_file.relative_to(root)
        s_file = build_dir / rel.with_suffix('.s')
        s_file.parent.mkdir(parents=True, exist_ok=True)

        if verbose:
            print(f'  Generating MIPS assembly for {rel}...')
        try:
            cg = MipsCodegen(bounds_check=True, optimize=True)
            asm_text = cg.generate(program)
        except CodegenError as e:
            print(f'error[codegen]: {e}', file=sys.stderr)
            print(f'  --> {pak_file}', file=sys.stderr)
            sys.exit(1)

        s_file.write_text(asm_text, encoding='utf-8')
        s_rel_paths.append(s_file.relative_to(root))
        print(f'  Compiled {rel} -> {s_file.relative_to(root)}')

    return s_rel_paths


def _run_full_check(
    parsed: list,          # [(str, Program)]
    root: Optional[Path],
    no_style_warnings: bool,
) -> tuple:
    """Run typecheck + extended semantic check on all parsed files.

    Returns (hard_error_count, warning_count).
    Prints all diagnostics to stderr, with per-file status lines to stdout.
    """
    # ── 1. Typechecker ────────────────────────────────────────────────────────
    tc_results = typecheck_multi(
        [(fn, prog) for fn, prog in parsed],
        no_style_warnings=no_style_warnings,
    )
    hard_errors = 0
    warnings    = 0
    tc_diags: dict = {}   # filename → list[diag]
    for filename, diagnostics in tc_results.items():
        tc_diags[filename] = diagnostics
        for d in diagnostics:
            if d.is_warning:
                warnings += 1
            else:
                hard_errors += 1

    # ── 2. Extended semantic checker (per file) ───────────────────────────────
    sem_diags: dict = {}  # filename → (errors, warnings)
    for filename, program in parsed:
        errs, warns = semantic_check(program, filename)
        sem_diags[filename] = (errs, warns)
        hard_errors += len(errs)
        if not no_style_warnings:
            warnings += len(warns)

    # ── 3. Cross-file entry block check ──────────────────────────────────────
    entry_diags = check_entry_blocks(parsed)
    for d in entry_diags:
        hard_errors += 1
        print(str(d), file=sys.stderr)

    # ── 4. Per-file output ────────────────────────────────────────────────────
    for filename, program in parsed:
        rel = Path(filename).relative_to(root) if root else Path(filename)
        file_errs  = [d for d in tc_diags.get(filename, []) if not d.is_warning]
        file_warns = [d for d in tc_diags.get(filename, []) if d.is_warning]
        sem_e, sem_w = sem_diags.get(filename, ([], []))
        file_errs  += sem_e
        file_warns += sem_w

        for d in file_errs:
            print(str(d), file=sys.stderr)
        if not no_style_warnings:
            for d in file_warns:
                print(str(d), file=sys.stderr)

        if file_errs:
            print(f'  {rel}: {len(file_errs)} error(s)')
        elif file_warns and not no_style_warnings:
            print(f'  {rel}: ok  ({len(file_warns)} warning(s))')
        else:
            print(f'  {rel}: ok')

    return hard_errors, warnings


def cmd_check(args):
    """Parse, typecheck, and run extended semantic checks — no code generation."""
    root               = find_project_root()
    no_style_warnings  = getattr(args, 'no_style_warnings', False)
    show_summary       = getattr(args, 'summary', True)

    # ── Collect source files ──────────────────────────────────────────────────
    if root is None:
        files_arg = getattr(args, 'files', None) or []
        if not files_arg:
            print('error: no pak.toml found and no files specified', file=sys.stderr)
            print('  hint: run `pak check file.pak` or `cd` to a project directory',
                  file=sys.stderr)
            sys.exit(1)
        src_files = [Path(f) for f in files_arg]
    else:
        src_files = sorted(f for f in root.glob('**/*.pak') if 'build' not in f.parts)
        if not src_files:
            print('error: no .pak source files found', file=sys.stderr)
            sys.exit(1)

    # ── Parse ─────────────────────────────────────────────────────────────────
    parsed  = []
    n_parse_errors = 0
    for pak_file in src_files:
        program = parse_file(pak_file)
        if program is None:
            n_parse_errors += 1
        else:
            parsed.append((str(pak_file), program))

    # ── Type + semantic check ──────────────────────────────────────────────────
    hard_errors = n_parse_errors
    warnings    = 0
    if parsed:
        h, w = _run_full_check(parsed, root, no_style_warnings)
        hard_errors += h
        warnings     = w

    # ── Summary ───────────────────────────────────────────────────────────────
    if show_summary:
        n = len(src_files)
        if hard_errors:
            print(f'\n{hard_errors} error(s) in {n} file(s).', file=sys.stderr)
        elif warnings and not no_style_warnings:
            print(f'\n{n} file(s) checked — {warnings} warning(s). '
                  f'Use --no-style-warnings to suppress.')
        else:
            print(f'\n{n} file(s) checked — all passed.')

    sys.exit(1 if hard_errors else 0)


def cmd_explain(args):
    """Show generated code for a .pak file."""
    pak_file = Path(args.file)
    if not pak_file.exists():
        print(f'error: file not found: {pak_file}', file=sys.stderr)
        sys.exit(1)

    backend = getattr(args, 'backend', 'c')
    if backend == 'mips':
        program = parse_file(pak_file)
        if program is None:
            sys.exit(1)
        try:
            cg = MipsCodegen(bounds_check=True, optimize=True)
            asm_text = cg.generate(program)
        except CodegenError as e:
            print(f'error[codegen]: {e}', file=sys.stderr)
            sys.exit(1)
        print(asm_text)
    else:
        c_source, _ = compile_file(pak_file)
        print(c_source)


def cmd_run(args):
    """Build, then invoke `make run`."""
    cmd_build(args)
    root = find_project_root()
    if root and (root / 'Makefile').exists():
        print('Running: make run')
        subprocess.run(['make', 'run'], cwd=root)


def cmd_pack(args):
    """Pack converted assets into a PakFS archive.

    Usage:
      pak pack --output game.pakfs                    # auto-discover build/ assets
      pak pack build/assets/*.sprite --output g.pakfs  # explicit list
      pak pack file1 file2 --base build/ --output g.pakfs  # strip base path
    """
    from .pakfs import pack
    out = Path(args.output)
    base = Path(args.base) if getattr(args, 'base', None) else None
    files_arg = getattr(args, 'files', [])

    packable = []
    if files_arg:
        for f_str in files_arg:
            f = Path(f_str)
            if f.is_file():
                if base:
                    try:
                        arch_name = str(f.relative_to(base)).replace(os.sep, '/')
                    except ValueError:
                        arch_name = f.name
                else:
                    arch_name = f.name
                packable.append((arch_name, f.read_bytes()))
    else:
        # Auto-discover converted assets in build/
        build_dir = Path('build')
        if build_dir.is_dir():
            for f in sorted(build_dir.rglob('*')):
                if f.is_file() and f.suffix in ('.sprite', '.wav64', '.xm64',
                                                 '.ym64', '.t3dm'):
                    arch_name = str(f.relative_to(build_dir)).replace(os.sep, '/')
                    packable.append((arch_name, f.read_bytes()))

    if not packable:
        print('warning: no assets found to pack', file=sys.stderr)
        return

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(pack(packable))
    print(f'Packed {len(packable)} file(s) into {out}')


def cmd_init(args):
    """Create a new project from template."""
    name = args.name
    project_dir = Path(name)
    if project_dir.exists():
        print(f'error: directory {name!r} already exists', file=sys.stderr)
        sys.exit(1)

    project_dir.mkdir()
    (project_dir / 'src').mkdir()
    (project_dir / 'assets').mkdir()
    (project_dir / 'assets' / 'sprites').mkdir()
    (project_dir / 'assets' / 'models').mkdir()
    (project_dir / 'assets' / 'audio').mkdir()
    (project_dir / 'assets' / 'fonts').mkdir()

    # ── pak.toml ──────────────────────────────────────────────────────────────
    (project_dir / 'pak.toml').write_text(f'''\
[project]
name = "{name}"
rom_title = "{name.upper()[:20]}"
save_type = "none"

[display]
resolution = "320x240"
bit_depth = 16
framebuffers = 3

[assets]
sprites = "assets/sprites/"
models  = "assets/models/"
audio   = "assets/audio/"
fonts   = "assets/fonts/"

[dependencies]
tiny3d = false

[build]
optimization = "debug"
''', encoding='utf-8')

    # ── src/main.pak ──────────────────────────────────────────────────────────
    (project_dir / 'src' / 'main.pak').write_text(f'''\
-- {name}
-- Created with: pak init {name}

use n64.display
use n64.controller
use n64.rdpq

entry {{
    -- Initialize display: 0=320x240, 2=16bpp, 3=triple-buffer, 0=GAMMA_NONE, 1=FILTERS_RESAMPLE
    display.init(0, 2, 3, 0, 1)

    loop {{
        let input = controller.read(0)

        -- Begin frame
        let disp = display.get()
        rdpq.attach_clear(disp, none)

        -- ── Game logic here ─────────────────────────────────────────────

        rdpq.detach_show()
    }}
}}
''', encoding='utf-8')

    # ── Copy runtime ──────────────────────────────────────────────────────────
    rt_src = runtime_dir()
    if rt_src.exists():
        rt_dst = project_dir / 'runtime'
        shutil.copytree(rt_src, rt_dst)

    # ── .gitignore ────────────────────────────────────────────────────────────
    (project_dir / '.gitignore').write_text('''\
build/
filesystem/
Makefile
*.z64
*.elf
''', encoding='utf-8')

    print(f"Created project '{name}'")
    print(f'  {name}/pak.toml')
    print(f'  {name}/src/main.pak')
    print(f'  {name}/assets/sprites/')
    print(f'  {name}/assets/models/')
    print(f'  {name}/assets/audio/')
    print(f'  {name}/assets/fonts/')
    print(f'  {name}/runtime/       (PakFS C runtime)')
    print()
    print('Next steps:')
    print(f'  cd {name}')
    print(f'  export N64_INST=/opt/libdragon   # or wherever libdragon is installed')
    print(f'  pak build && make')


def cmd_clean(args):
    """Remove build artifacts."""
    root = find_project_root()
    if root is None:
        print('error: no pak.toml found', file=sys.stderr)
        sys.exit(1)
    removed = []
    for target in ['build', 'filesystem']:
        d = root / target
        if d.exists():
            shutil.rmtree(d)
            removed.append(str(d.relative_to(root)))
    for target in ['Makefile']:
        f = root / target
        if f.exists():
            f.unlink()
            removed.append(target)
    # Remove generated .z64 / .elf
    for pat in ['*.z64', '*.elf']:
        for f in root.glob(pat):
            f.unlink()
            removed.append(f.name)
    if removed:
        print('Cleaned: ' + ', '.join(removed))
    else:
        print('Nothing to clean.')


def cmd_runtime_dir(args):
    """Print the path to the bundled runtime (used by generated Makefile)."""
    print(runtime_dir())


def main():
    parser = argparse.ArgumentParser(
        prog='pak',
        description='Pak - A language for Nintendo 64 homebrew development',
    )
    parser.add_argument('--version', action='version', version='pak 0.1.0')

    sub = parser.add_subparsers(dest='command', metavar='COMMAND')

    # build
    p_build = sub.add_parser('build', help='Compile .pak to C or MIPS assembly, pack assets, generate Makefile')
    p_build.add_argument('-v', '--verbose', action='store_true')
    p_build.add_argument('--backend', choices=['c', 'mips'], default='c',
                         help='Code generation backend (default: c)')
    p_build.add_argument('--no-style-warnings', dest='no_style_warnings',
                         action='store_true',
                         help='Suppress naming-convention warnings (W001–W003)')
    p_build.set_defaults(func=cmd_build)

    # check
    p_check = sub.add_parser('check', help='Type-check without building')
    p_check.add_argument('files', nargs='*')
    p_check.add_argument('--no-style-warnings', dest='no_style_warnings',
                         action='store_true',
                         help='Suppress naming-convention warnings (W001–W003)')
    p_check.set_defaults(func=cmd_check)

    # explain
    p_explain = sub.add_parser('explain', help='Show generated code for a .pak file')
    p_explain.add_argument('file', help='.pak file')
    p_explain.add_argument('--backend', choices=['c', 'mips'], default='c',
                           help='Code generation backend (default: c)')
    p_explain.set_defaults(func=cmd_explain)

    # run
    p_run = sub.add_parser('run', help='Build then `make run` (launches in ares)')
    p_run.add_argument('-v', '--verbose', action='store_true')
    p_run.add_argument('--backend', choices=['c', 'mips'], default='c',
                       help='Code generation backend (default: c)')
    p_run.add_argument('--no-style-warnings', dest='no_style_warnings',
                       action='store_true',
                       help='Suppress naming-convention warnings (W001–W003)')
    p_run.set_defaults(func=cmd_run)

    # init
    p_init = sub.add_parser('init', help='Create a new project')
    p_init.add_argument('name', help='Project name')
    p_init.set_defaults(func=cmd_init)

    # clean
    p_clean = sub.add_parser('clean', help='Remove build artifacts and generated Makefile')
    p_clean.set_defaults(func=cmd_clean)

    # pack
    p_pack = sub.add_parser('pack', help='Pack converted assets into a PakFS archive')
    p_pack.add_argument('files', nargs='*', help='Specific files to pack (or auto-discover)')
    p_pack.add_argument('--output', '-o', required=True, help='Output .pakfs file')
    p_pack.add_argument('--base', help='Base directory to strip from archive paths')
    p_pack.set_defaults(func=cmd_pack)

    # convert (C-to-Pak transpiler)
    from .c2pak.cli import register_subcommand as _register_convert
    _register_convert(sub)

    # runtime-dir (internal, used by generated Makefile)
    p_rtdir = sub.add_parser('--runtime-dir', help=argparse.SUPPRESS)
    p_rtdir.set_defaults(func=cmd_runtime_dir)

    args = parser.parse_args()
    if args.command is None:
        parser.print_help()
        sys.exit(0)
    args.func(args)


if __name__ == '__main__':
    main()
