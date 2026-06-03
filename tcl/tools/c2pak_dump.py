#!/usr/bin/env python3
"""Oracle: Python c2pak transpile of a .c file -> .pk64 text."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.c2pak.pak_emitter import transpile, EmitOptions
src = Path(sys.argv[1]).read_text()
sys.stdout.write(transpile(src, Path(sys.argv[1]).name, EmitOptions()))
