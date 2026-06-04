"""Tests for the bespoke flat N64 linker (pak.tools.n64_link).

All object files are synthetic text — no MIPS toolchain required.
"""

import struct
import textwrap

import pytest

from pak.tools import n64_link
from pak.tools.n64_link import (
    BASE_ADDR,
    LinkError,
    link_objects,
    link_to_rom,
    parse_object_text,
    link_parsed_objects,
)


def _link_texts(texts):
    """Link a list of object-file source strings without touching the disk."""
    objs = [parse_object_text(t, f"obj{i}") for i, t in enumerate(texts)]
    return link_parsed_objects(objs)


def _word_at(image, vaddr, base=BASE_ADDR):
    off = vaddr - base
    return struct.unpack_from(">I", image, off)[0]


# 1. Single object, no relocs ------------------------------------------------

def test_single_object_no_relocs():
    obj = """\
# pak object v1
section .text
sym _start 0
data 03e00008 00000000
"""
    res = _link_texts([obj])
    assert res.image == bytes.fromhex("03e0000800000000")
    assert len(res.image) == 8
    assert res.symbols["_start"] == 0x8000_0400
    assert res.base == 0x8000_0400


# 2. R_MIPS_32 in .data pointing at a .text symbol ---------------------------

def test_r_mips_32():
    obj = """\
section .text
sym target 0
data 03e00008
section .data
reloc 0 R_MIPS_32 target
data 00000000
"""
    res = _link_texts([obj])
    target_vaddr = res.symbols["target"]
    assert target_vaddr == 0x8000_0400
    # .data word should now equal target's vaddr (big-endian).
    data_word = _word_at(res.image, res.section_bases[".data"])
    assert data_word == target_vaddr


# 3. R_MIPS_26 jal -----------------------------------------------------------

def test_r_mips_26():
    # jal target where target lands at 0x80001000.
    # We pad .text so the target symbol is at 0x80001000, then jal it.
    # Object A: jal at offset 0 (in .text), target defined in object B.
    # Simpler: single object, jal word followed by padding to 0x1000-0x400,
    # then the symbol.
    pad_words = (0x1000 - 0x400) // 4 - 1  # words after the jal up to offset 0xC00
    data_line = "0c000000 " + "00000000 " * pad_words
    obj = f"""\
section .text
sym caller 0
reloc 0 R_MIPS_26 callee
data {data_line.strip()}
sym callee {(pad_words + 1) * 4}
"""
    res = _link_texts([obj])
    assert res.symbols["callee"] == 0x8000_1000
    word = _word_at(res.image, 0x8000_0400)
    # (0x80001000 >> 2) & 0x3FFFFFF = 0x00000400; opcode 0x0C000000.
    assert word == 0x0C00_0400


# 4. HI16/LO16 pair ----------------------------------------------------------

def test_hi16_lo16_pair():
    # lui $a0, %hi(sym) ; addiu $a0, $a0, %lo(sym), sym at 0x80002004.
    pad_words = (0x2004 - 0x400) // 4 - 2  # words between the two insns and sym
    data_line = "3c040000 24840000 " + "00000000 " * pad_words
    obj = f"""\
section .text
reloc 0 R_MIPS_HI16 sym
reloc 4 R_MIPS_LO16 sym
data {data_line.strip()}
sym sym {(pad_words + 2) * 4}
"""
    res = _link_texts([obj])
    assert res.symbols["sym"] == 0x8000_2004
    lui = _word_at(res.image, 0x8000_0400)
    addiu = _word_at(res.image, 0x8000_0404)
    assert lui == 0x3C04_8000     # hi = (0x80002004 + 0x8000) >> 16 = 0x8000
    assert addiu == 0x2484_2004   # lo = 0x2004


# 5. Two objects, cross-object symbol reference ------------------------------

def test_cross_object_reference():
    # Object A defines `func` in .text at a known final address.
    # Object B (linked second) has a jal referencing A's func.
    # A is 4 words of .text, so func at offset 0 -> 0x80000400.
    obj_a = """\
section .text
sym func 0
data 03e00008 00000000 00000000 00000000
"""
    # B's .text starts at base + 16 = 0x80000410.
    obj_b = """\
section .text
sym bcaller 0
reloc 0 R_MIPS_26 func
data 0c000000
"""
    res = _link_texts([obj_a, obj_b])
    assert res.symbols["func"] == 0x8000_0400
    assert res.symbols["bcaller"] == 0x8000_0410
    word = _word_at(res.image, 0x8000_0410)
    target = (0x8000_0400 >> 2) & 0x03FF_FFFF
    assert word == (0x0C00_0000 | target)


# 6. Section ordering / alignment --------------------------------------------

def test_section_ordering_alignment():
    # .text 6 words (24 bytes) + .rodata 2 words.
    # base = 0x80000400 (16-aligned). +24 = 0x80000418.
    # .rodata aligns to 16 -> 0x80000420.
    obj = """\
section .text
data 00000000 00000000 00000000 00000000 00000000 00000000
section .rodata
sym rosym 0
data 48656c6c 6f000000
"""
    res = _link_texts([obj])
    assert res.section_bases[".text"] == 0x8000_0400
    assert res.section_bases[".rodata"] == 0x8000_0420
    assert res.symbols["rosym"] == 0x8000_0420


# 7. Undefined symbol --------------------------------------------------------

def test_undefined_symbol():
    obj = """\
section .text
reloc 0 R_MIPS_26 nowhere
data 0c000000
"""
    with pytest.raises(LinkError) as exc:
        _link_texts([obj])
    assert "nowhere" in str(exc.value)


# 8. Duplicate symbol --------------------------------------------------------

def test_duplicate_symbol():
    obj_a = """\
section .text
sym main 0
data 03e00008
"""
    obj_b = """\
section .text
sym main 0
data 03e00008
"""
    with pytest.raises(LinkError) as exc:
        _link_texts([obj_a, obj_b])
    assert "main" in str(exc.value)


# 9. rompack integration -----------------------------------------------------

def test_rompack_integration(tmp_path):
    obj_path = tmp_path / "boot.pakobj"
    obj_path.write_text("""\
section .text
sym _start 0
data 03e00008 00000000
""")
    out = tmp_path / "game.z64"
    res = link_to_rom([str(obj_path)], str(out), "TESTROM")
    assert out.exists()
    data = out.read_bytes()
    assert len(data) > 0
    # rompack pads the ROM to at least 0x101000 and to a multiple of 4.
    assert len(data) % 4 == 0
    assert len(data) >= 0x101000
    # Header magic from rompack.build_header.
    assert data[0] == 0x80 and data[1] == 0x37
    # User code lands right after the 4 KB header+IPL3 region.
    assert data[0x1000:0x1008] == bytes.fromhex("03e0000800000000")
    assert res.symbols["_start"] == 0x8000_0400


# Extra: .bss reservation does not enter the image but reserves address space.

def test_bss_reservation():
    obj = """\
section .text
sym _start 0
data 03e00008 00000000
section .data
sym dval 0
data deadbeef
section .bss
sym bvar 0
space 64
"""
    res = _link_texts([obj])
    # .data is 4 bytes; image = .text(8) + pad to align16 (rodata empty) + .data.
    # .text ends at 0x80000408; rodata base = align16(0x80000408)=0x80000410.
    # rodata empty, .data base = align8(0x80000410) = 0x80000410.
    assert res.section_bases[".data"] == 0x8000_0410
    assert res.symbols["dval"] == 0x8000_0410
    # .bss base = align8(0x80000414) = 0x80000418, reserved but not in image.
    assert res.section_bases[".bss"] == 0x8000_0418
    assert res.symbols["bvar"] == 0x8000_0418
    # Image excludes .bss: length = (data base - text base) + data size.
    assert len(res.image) == (0x8000_0410 - 0x8000_0400) + 4


def test_cli_emit_bin(tmp_path):
    obj_path = tmp_path / "o.pakobj"
    obj_path.write_text("section .text\nsym _start 0\ndata 03e00008 00000000\n")
    binp = tmp_path / "out.bin"
    rc = n64_link.main([str(obj_path), "--emit-bin", str(binp)])
    assert rc == 0
    assert binp.read_bytes() == bytes.fromhex("03e0000800000000")


# ── End-to-end: .pk64 → .pakobj (Tcl codegen + encoder) → link → .z64 ────────
# Requires tclsh; skipped otherwise. No MIPS toolchain involved.

import shutil
import subprocess
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
_TCLSH = shutil.which("tclsh")

# A self-contained program with no runtime externs (pure integer arithmetic),
# so the linker can resolve every symbol without a runtime object.
_STANDALONE_PK = """\
fn compute(a: i32, b: i32) -> i32 {
    let mut sum: i32 = 0
    let mut i: i32 = a
    while i < b {
        sum = sum + i
        i = i + 1
    }
    return sum
}

entry {
    let r: i32 = compute(1, 10)
}
"""


@pytest.mark.skipif(_TCLSH is None, reason="tclsh required for objgen")
def test_end_to_end_pk64_to_z64(tmp_path):
    """Full toolchain-free chain: source → object → linked flat image."""
    src = tmp_path / "standalone.pk64"
    src.write_text(_STANDALONE_PK)
    obj = tmp_path / "standalone.pakobj"

    result = subprocess.run(
        [_TCLSH, str(_ROOT / "tcl" / "cli.tcl"),
         "objgen", str(src), "-o", str(obj)],
        capture_output=True, text=True, cwd=str(_ROOT),
    )
    assert result.returncode == 0, result.stderr
    assert obj.exists()

    text = obj.read_text()
    # Both functions must be present, and the internal call must be a reloc.
    assert "sym compute " in text
    assert "sym main " in text
    assert "R_MIPS_26 compute" in text

    # Link with main as the entry; every symbol resolves (no undefined externs).
    res = link_objects([str(obj)], entry="main")
    assert res.symbols["compute"] == BASE_ADDR
    assert res.symbols["main"] > BASE_ADDR
    assert len(res.image) > 0

    # Produce a real .z64 and sanity-check it is non-empty.
    z64 = tmp_path / "standalone.z64"
    link_to_rom([str(obj)], str(z64), name="STANDALONE", entry="main")
    assert z64.exists() and z64.stat().st_size > 0


# ── Full runtime build: hand-asm boot + Pak HAL + game → linked ROM ──────────

_DISPLAY_DEMO_PK = """\
use n64.display
use n64.rdpq

entry {
    display.init(0, 0, 2, 0, 0)
    rdpq.init()
    let mut t: i32 = 0
    loop {
        let fb = display.get()
        rdpq.attach_clear(fb, 0x0000FFFF)
        rdpq.set_mode_fill(0xFF0000FF)
        rdpq.fill_rectangle(40, 100, 80, 140)
        rdpq.detach_show()
        t = t + 1
    }
}
"""


def _tcl(*args, cwd):
    return subprocess.run(
        [_TCLSH, str(_ROOT / "tcl" / "cli.tcl"), *args],
        capture_output=True, text=True, cwd=str(cwd),
    )


@pytest.mark.skipif(_TCLSH is None, reason="tclsh required for objgen/asmobj")
def test_tcl_check_cfg_annotation_no_crash(tmp_path):
    """Regression: Tcl checker produced diag dicts without 'filename', crashing
    diag_str with 'key filename not known in dictionary' when a W103 warning
    was emitted for an unknown @cfg feature. pak check must not crash."""
    src = tmp_path / "cfg.pk64"
    src.write_text(textwrap.dedent("""\
        @cfg(UNKNOWN_FEATURE_XYZ)
        fn maybe() { }
        entry { }
    """))
    r = _tcl("check", str(src), cwd=_ROOT)
    # Should exit 0 (warning only, not an error) and must not crash.
    assert r.returncode == 0, f"crash or hard error: {r.stderr}"
    assert "W103" in r.stdout or "W103" in r.stderr


@pytest.mark.skipif(_TCLSH is None, reason="tclsh required for objgen/asmobj")
def test_mips_deep_nested_binop(tmp_path):
    """Regression: emit_binop pre-allocated both lhs/rhs temps before evaluating
    either sub-expression, exhausting the 10-register temp pool for deeply nested
    binary op chains.  A balanced tree of 8+ OR operands must compile."""
    src = tmp_path / "deep.pk64"
    src.write_text(textwrap.dedent("""\
        entry {
            let a: u32 = 1
            let b: u32 = 2
            let c: u32 = 3
            let d: u32 = 4
            let e: u32 = 5
            let f: u32 = 6
            let g: u32 = 7
            let h: u32 = 8
            let result: u32 = ((a | b) | (c | d)) | ((e | f) | (g | h))
        }
    """))
    obj = tmp_path / "deep.pakobj"
    r = _tcl("objgen", str(src), "-o", str(obj), cwd=_ROOT)
    assert r.returncode == 0, f"MIPS codegen failed: {r.stderr}"
    assert obj.exists()


@pytest.mark.skipif(_TCLSH is None, reason="tclsh required for objgen/asmobj")
def test_runtime_compiles_and_exports_hal(tmp_path):
    """pak/runtime/runtime.pk64 compiles and exports the HAL symbols."""
    obj = tmp_path / "runtime.pakobj"
    r = _tcl("objgen", str(_ROOT / "pak" / "runtime" / "runtime.pk64"),
             "-o", str(obj), cwd=_ROOT)
    assert r.returncode == 0, r.stderr
    text = obj.read_text()
    for sym in ("display_init", "display_get", "display_show",
                "rdpq_init", "rdpq_attach_clear", "rdpq_set_mode_fill",
                "rdpq_fill_rectangle", "rdpq_detach_show", "memset", "memcpy"):
        assert f"sym {sym} " in text, f"missing runtime symbol {sym}"


@pytest.mark.skipif(_TCLSH is None, reason="tclsh required for objgen/asmobj")
def test_end_to_end_boot_runtime_game(tmp_path):
    """boot.S (hand-asm) + runtime.pk64 (Pak HAL) + game → linked ROM.

    Proves the complete toolchain-free path including the crt0 cross-object
    `jal main` fixup and the linker-defined __bss_start/__bss_end symbols.
    """
    boot_obj = tmp_path / "boot.pakobj"
    rt_obj = tmp_path / "runtime.pakobj"
    game_src = tmp_path / "demo.pk64"
    game_obj = tmp_path / "demo.pakobj"
    game_src.write_text(_DISPLAY_DEMO_PK)

    assert _tcl("asmobj", str(_ROOT / "pak" / "runtime" / "boot.S"),
                "-o", str(boot_obj), cwd=_ROOT).returncode == 0
    assert _tcl("objgen", str(_ROOT / "pak" / "runtime" / "runtime.pk64"),
                "-o", str(rt_obj), cwd=_ROOT).returncode == 0
    assert _tcl("objgen", str(game_src),
                "-o", str(game_obj), cwd=_ROOT).returncode == 0

    res = link_objects([str(boot_obj), str(rt_obj), str(game_obj)],
                       entry="_start")
    # crt0 entry sits at the image base.
    assert res.symbols["_start"] == BASE_ADDR
    # Cross-object symbols resolve: boot -> game main, game -> runtime HAL.
    assert res.symbols["main"] > BASE_ADDR
    assert res.symbols["display_init"] > BASE_ADDR
    assert res.symbols["rdpq_fill_rectangle"] > BASE_ADDR
    # Linker-defined bss bounds exist; runtime now has static buffers so
    # __bss_end > __bss_start.  Joypad symbols must be present.
    assert res.symbols["__bss_end"] >= res.symbols["__bss_start"]
    assert res.symbols["joypad_get_status"] > BASE_ADDR
    assert res.symbols["joypad_poll"] > BASE_ADDR
    assert res.symbols["g_pif_buf"] >= res.symbols["__bss_start"]

    # _start begins with the CP0 status read (mfc0 $8,$12 = 0x40086000).
    assert struct.unpack_from(">I", res.image, 0)[0] == 0x4008_6000

    # boot's `jal main` (byte 64) targets exactly the game's main symbol.
    jal = struct.unpack_from(">I", res.image, 64)[0]
    assert jal >> 26 == 0x03  # jal opcode
    target = ((jal & 0x03FF_FFFF) << 2) | 0x8000_0000
    assert target == res.symbols["main"]

    z64 = tmp_path / "demo.z64"
    link_to_rom([str(boot_obj), str(rt_obj), str(game_obj)],
                str(z64), name="DEMO", entry="_start")
    assert z64.exists() and z64.stat().st_size > 0
