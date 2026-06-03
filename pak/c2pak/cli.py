"""CLI entry point for 'pak convert'.

Registered in the main pak CLI as the 'convert' subcommand.

Usage:
    pak convert path/to/file.c               # print .pk64 to stdout
    pak convert path/to/file.c -o out.pk64    # write to file
    pak convert src/ -o out/                 # batch convert directory
    pak convert file.c --preserve-comments
    pak convert file.c --no-idioms
    pak convert file.c --decomp
    pak convert file.c --style compact
"""

from __future__ import annotations
import sys
import os
from pathlib import Path
from typing import Optional


def cmd_convert(args):
    """Implementation of 'pak convert' subcommand."""
    try:
        from pak.c2pak.pak_emitter import transpile_file, transpile, EmitOptions
    except ImportError as e:
        if 'pycparser' in str(e):
            print('error: pycparser is required for pak convert', file=sys.stderr)
            print('  Install it with: pip install pycparser', file=sys.stderr)
        else:
            print(f'error: {e}', file=sys.stderr)
        sys.exit(1)

    options = EmitOptions(
        preserve_comments=getattr(args, 'preserve_comments', False),
        no_idioms=getattr(args, 'no_idioms', False),
        decomp=getattr(args, 'decomp', False),
        style=getattr(args, 'style', 'default'),
    )

    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else None

    if input_path.is_dir():
        _batch_convert(input_path, output_path, options)
    elif input_path.is_file():
        _convert_file(input_path, output_path, options)
    else:
        print(f'error: {input_path} does not exist', file=sys.stderr)
        sys.exit(1)


def _convert_file(input_path: Path, output_path: Optional[Path], options):
    """Convert a single .c file."""
    from pak.c2pak.pak_emitter import transpile_file, EmitOptions

    if not input_path.suffix in ('.c', '.h'):
        print(f'warning: {input_path} does not have a .c/.h extension', file=sys.stderr)

    try:
        pak_source = transpile_file(input_path, options)
    except ImportError as e:
        print(f'error: {e}', file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        print(f'error: {e}', file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f'error transpiling {input_path}: {e}', file=sys.stderr)
        if os.environ.get('PAK_DEBUG'):
            import traceback
            traceback.print_exc()
        sys.exit(1)

    if output_path is None:
        # Print to stdout
        print(pak_source, end='')
    else:
        output_path.write_text(pak_source, encoding='utf-8')
        print(f'Written: {output_path}')


def _batch_convert(input_dir: Path, output_dir: Optional[Path], options):
    """Convert all .c files in a directory."""
    from pak.c2pak.pak_emitter import transpile_file, EmitOptions

    c_files = list(input_dir.rglob('*.c'))
    if not c_files:
        print(f'No .c files found in {input_dir}')
        return

    if output_dir is None:
        print(f'error: -o / --output required for directory input', file=sys.stderr)
        sys.exit(1)

    output_dir.mkdir(parents=True, exist_ok=True)
    ok, failed = 0, 0

    for c_file in sorted(c_files):
        rel = c_file.relative_to(input_dir)
        out_path = output_dir / rel.with_suffix('.pk64')
        out_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            pak_source = transpile_file(c_file, options)
            out_path.write_text(pak_source, encoding='utf-8')
            print(f'  OK  {rel} → {out_path.relative_to(output_dir)}')
            ok += 1
        except Exception as e:
            print(f'  ERR {rel}: {e}', file=sys.stderr)
            failed += 1

    print(f'\n{ok} converted, {failed} failed out of {len(c_files)} files.')


def register_subcommand(subparsers):
    """Register the 'convert' subcommand with the main argparse parser."""
    p = subparsers.add_parser(
        'convert',
        help='Transpile a C file (or directory) to Pak source',
    )
    p.add_argument('input', help='Input .c file or directory')
    p.add_argument('-o', '--output', default=None,
                   help='Output .pk64 file or directory (default: stdout)')
    p.add_argument('--preserve-comments', action='store_true',
                   dest='preserve_comments',
                   help='Preserve C comments in output (not yet implemented)')
    p.add_argument('--no-idioms', action='store_true', dest='no_idioms',
                   help='Disable idiom detection (emit literal line-by-line translation)')
    p.add_argument('--decomp', action='store_true',
                   help='Enable N64 decompilation-specific patterns')
    p.add_argument('--style', choices=['default', 'compact'], default='default',
                   help='Output formatting style')
    p.set_defaults(func=cmd_convert)
    return p
