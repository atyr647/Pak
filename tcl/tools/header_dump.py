#!/usr/bin/env python3
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.parser import parse
from pak.headergen import generate_header
src = Path(sys.argv[1]).read_text()
sys.stdout.write(generate_header(parse(src), sys.argv[2]))
