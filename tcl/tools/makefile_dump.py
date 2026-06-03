#!/usr/bin/env python3
"""Emit Python-generated Makefiles for the same fixed scenarios as
makefile_dump.tcl — oracle for the Tcl makefile_gen port."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.makefile_gen import generate_makefile

scenarios = [
    dict(project_name="mygame", rom_title="My Cool Game", c_files=[Path("main.c"), Path("player.c")], pakfs_archive=None),
    dict(project_name="g2", rom_title="A Very Long Title That Exceeds Twenty Chars", c_files=[Path("a.c")], pakfs_archive="g2.pakfs", save_type="eeprom16k", bit_depth=32, resolution="640x480", framebuffers=2, optimization="release"),
    dict(project_name="m3", rom_title="It's Mine", c_files=[Path("x.s"), Path("y.c")], pakfs_archive="m3.pakfs", backend="mips", use_tiny3d=True),
    dict(project_name="m4", rom_title="3D Demo", c_files=[Path("scene.s")], pakfs_archive=None, backend="mips", use_tiny3d=True, save_type="flashram"),
]
sys.stdout.write("\n=====SCENARIO=====\n".join(generate_makefile(**sc) for sc in scenarios))
