#!/usr/bin/env python3
"""
n64_link.py — Minimal static linker for Pak "pak object" text files.

This is a bespoke flat linker. There is NO MIPS toolchain and NO ELF involved.
It combines relocatable object files (Contract B text format) into a flat
N64 RDRAM binary image laid out exactly like pak/runtime/n64.ld, then hands
the image to rompack.py to produce a .z64.

Object file format (line oriented text)
---------------------------------------
    # pak object v1               -- optional comment / blank lines ignored
    section .text                 -- start/continue a section
    sym main 0                    -- symbol NAME at BYTEOFFSET within this
                                     object's contribution to the current section
    reloc 16 R_MIPS_26 printf     -- fixup at BYTEOFFSET, KIND, target SYMBOL
    data 27bdff00 afbf00fc ...    -- raw 32-bit big-endian words (8 hex chars each)

Sections concatenate in a fixed order: .text, .rodata, .data, .bss.
Within a section, objects concatenate in command-line order (boot object first).

Memory layout (see pak/runtime/n64.ld)
--------------------------------------
    base = 0x80000400
    .text   at base
    .rodata at ALIGN(16)
    .data   at ALIGN(8)
    .bss    at ALIGN(8)   -- reserved, zero-init at runtime, NOT in ROM image

The flat ROM image = [.text | pad16 | .rodata | pad8 | .data]. .bss bytes are
NOT stored (zeroed by boot.S); they only reserve address space so symbols and
later-section addresses resolve correctly.
"""

from __future__ import annotations

import argparse
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ── Constants ──────────────────────────────────────────────────────────────

BASE_ADDR = 0x8000_0400

# Fixed section order and post-section alignment (alignment applied BEFORE the
# next section is placed, matching n64.ld's ALIGN directives).
SECTION_ORDER = [".text", ".rodata", ".data", ".bss"]
SECTION_ALIGN = {
    ".text": 1,        # base is already 16-aligned; .text starts at base
    ".rodata": 16,     # . = ALIGN(16)
    ".data": 8,        # . = ALIGN(8)
    ".bss": 8,         # . = ALIGN(8)
}

RELOC_KINDS = {"R_MIPS_26", "R_MIPS_HI16", "R_MIPS_LO16", "R_MIPS_32"}

MASK32 = 0xFFFF_FFFF


class LinkError(Exception):
    """Raised on a linking error (undefined/duplicate symbol, bad input, ...)."""


# ── Parsed object representation ────────────────────────────────────────────

@dataclass
class Reloc:
    offset: int        # byte offset within the object's contribution to a section
    kind: str
    symbol: str


@dataclass
class SectionContribution:
    """One object's contribution to one section."""
    data: bytearray = field(default_factory=bytearray)
    symbols: dict[str, int] = field(default_factory=dict)   # name -> byte offset
    relocs: list[Reloc] = field(default_factory=list)


@dataclass
class ParsedObject:
    path: str
    # section name -> contribution (each object has at most one contribution
    # per section; repeated `section X` lines append to the same contribution).
    sections: dict[str, SectionContribution] = field(default_factory=dict)


@dataclass
class LinkResult:
    image: bytes
    symbols: dict[str, int]            # name -> final virtual address
    base: int
    section_bases: dict[str, int]      # section -> final virtual base address
    section_sizes: dict[str, int]      # section -> total size in bytes


# ── Helpers ─────────────────────────────────────────────────────────────────

def _align_up(value: int, alignment: int) -> int:
    if alignment <= 1:
        return value
    return (value + alignment - 1) & ~(alignment - 1)


def _sign_extend16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x1_0000 if value & 0x8000 else value


# ── Parsing ──────────────────────────────────────────────────────────────────

def parse_object(path: str) -> ParsedObject:
    text = Path(path).read_text()
    return parse_object_text(text, path)


def parse_object_text(text: str, path: str = "<string>") -> ParsedObject:
    obj = ParsedObject(path=path)
    current: SectionContribution | None = None
    current_name: str | None = None

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        kw = parts[0]

        if kw == "section":
            if len(parts) != 2:
                raise LinkError(f"{path}:{lineno}: 'section' needs exactly one name")
            name = parts[1]
            if name not in SECTION_ORDER:
                raise LinkError(f"{path}:{lineno}: unknown section {name!r}")
            current_name = name
            current = obj.sections.setdefault(name, SectionContribution())
            continue

        if current is None:
            raise LinkError(f"{path}:{lineno}: directive {kw!r} before any 'section'")

        if kw == "sym":
            if len(parts) != 3:
                raise LinkError(f"{path}:{lineno}: 'sym' needs NAME OFFSET")
            name, off = parts[1], parts[2]
            try:
                offset = int(off, 0)
            except ValueError as exc:
                raise LinkError(f"{path}:{lineno}: bad sym offset {off!r}") from exc
            if name in current.symbols:
                raise LinkError(
                    f"{path}:{lineno}: duplicate local symbol {name!r} in "
                    f"section {current_name}"
                )
            current.symbols[name] = offset

        elif kw == "reloc":
            if len(parts) != 4:
                raise LinkError(f"{path}:{lineno}: 'reloc' needs OFFSET KIND SYMBOL")
            off, kind, symbol = parts[1], parts[2], parts[3]
            try:
                offset = int(off, 0)
            except ValueError as exc:
                raise LinkError(f"{path}:{lineno}: bad reloc offset {off!r}") from exc
            if kind not in RELOC_KINDS:
                raise LinkError(f"{path}:{lineno}: unknown reloc kind {kind!r}")
            current.relocs.append(Reloc(offset=offset, kind=kind, symbol=symbol))

        elif kw == "data":
            for tok in parts[1:]:
                if len(tok) != 8:
                    raise LinkError(
                        f"{path}:{lineno}: data word {tok!r} must be 8 hex chars"
                    )
                try:
                    word = int(tok, 16)
                except ValueError as exc:
                    raise LinkError(
                        f"{path}:{lineno}: bad data word {tok!r}"
                    ) from exc
                current.data += struct.pack(">I", word)

        elif kw == "space":
            # Optional .bss-style reservation: `space N` reserves N zero bytes.
            if len(parts) != 2:
                raise LinkError(f"{path}:{lineno}: 'space' needs a byte count")
            try:
                n = int(parts[1], 0)
            except ValueError as exc:
                raise LinkError(f"{path}:{lineno}: bad space count {parts[1]!r}") from exc
            current.data += b"\x00" * n

        else:
            raise LinkError(f"{path}:{lineno}: unknown directive {kw!r}")

    return obj


# ── Relocation application ────────────────────────────────────────────────────

def _read_word(buf: bytearray, off: int) -> int:
    return struct.unpack_from(">I", buf, off)[0]


def _write_word(buf: bytearray, off: int, word: int) -> None:
    struct.pack_into(">I", buf, off, word & MASK32)


def _apply_reloc(buf: bytearray, off: int, kind: str, S: int, where: str) -> None:
    """Apply one relocation in-place. S is the target symbol's virtual address."""
    if off + 4 > len(buf):
        raise LinkError(f"{where}: reloc offset {off} out of range")

    if kind == "R_MIPS_32":
        _write_word(buf, off, S)

    elif kind == "R_MIPS_26":
        word = _read_word(buf, off)
        target = (S >> 2) & 0x03FF_FFFF
        word = (word & 0xFC00_0000) | target
        _write_word(buf, off, word)

    elif kind == "R_MIPS_HI16":
        word = _read_word(buf, off)
        hi = ((S + 0x8000) >> 16) & 0xFFFF
        word = (word & 0xFFFF_0000) | hi
        _write_word(buf, off, word)

    elif kind == "R_MIPS_LO16":
        word = _read_word(buf, off)
        lo = S & 0xFFFF
        word = (word & 0xFFFF_0000) | lo
        _write_word(buf, off, word)

    else:  # pragma: no cover - guarded at parse time
        raise LinkError(f"{where}: unknown reloc kind {kind!r}")


# ── Linker core ───────────────────────────────────────────────────────────────

def link_objects(object_paths: list[str], entry: str = "_start") -> LinkResult:
    objects = [parse_object(p) for p in object_paths]
    return link_parsed_objects(objects, entry=entry)


def link_parsed_objects(objects: list[ParsedObject], entry: str = "_start") -> LinkResult:
    # 1. Concatenate each section's bytes across objects (command-line order),
    #    recording each contribution's offset within the merged section so we
    #    can resolve symbols and relocs to final addresses.
    section_bytes: dict[str, bytearray] = {s: bytearray() for s in SECTION_ORDER}
    # contributions[section] = list of (object, offset_within_section)
    contributions: dict[str, list[tuple[ParsedObject, int]]] = {
        s: [] for s in SECTION_ORDER
    }

    for obj in objects:
        for sec in SECTION_ORDER:
            contrib = obj.sections.get(sec)
            if contrib is None:
                continue
            start = len(section_bytes[sec])
            contributions[sec].append((obj, start))
            section_bytes[sec] += contrib.data

    # 2. Assign final virtual addresses to each section.
    section_bases: dict[str, int] = {}
    section_sizes: dict[str, int] = {s: len(section_bytes[s]) for s in SECTION_ORDER}

    cursor = BASE_ADDR
    for sec in SECTION_ORDER:
        cursor = _align_up(cursor, SECTION_ALIGN[sec])
        section_bases[sec] = cursor
        cursor += section_sizes[sec]

    # 3. Build the global symbol table; detect duplicate definitions.
    symbols: dict[str, int] = {}
    sym_origin: dict[str, str] = {}
    for sec in SECTION_ORDER:
        sec_base = section_bases[sec]
        for obj, contrib_off in contributions[sec]:
            contrib = obj.sections[sec]
            for name, byte_off in contrib.symbols.items():
                vaddr = sec_base + contrib_off + byte_off
                if name in symbols:
                    raise LinkError(
                        f"duplicate symbol {name!r}: defined in {sym_origin[name]} "
                        f"and {obj.path} (section {sec})"
                    )
                symbols[name] = vaddr
                sym_origin[name] = f"{obj.path} (section {sec})"

    # 3b. Linker-defined symbols. boot.S zero-fills .bss between these; the
    #     classic GNU-ld names are provided so the hand-written crt0 links.
    #     A user object defining them is an error (they are reserved).
    bss_start = section_bases[".bss"]
    bss_end = section_bases[".bss"] + section_sizes[".bss"]
    for name, value in (
        ("__bss_start", bss_start),
        ("_fbss", bss_start),
        ("__bss_end", bss_end),
        ("_end", bss_end),
    ):
        if name in symbols:
            raise LinkError(
                f"reserved linker symbol {name!r} is also defined in "
                f"{sym_origin[name]}"
            )
        symbols[name] = value

    # 4. Apply relocations (collecting all undefined symbols for one report).
    undefined: list[str] = []
    for sec in SECTION_ORDER:
        if sec == ".bss":
            # .bss is not stored in the image and should not carry relocs, but
            # if any are present we cannot patch zero-filled space.
            for obj, _ in contributions[sec]:
                if obj.sections[sec].relocs:
                    raise LinkError(
                        f"{obj.path}: relocations in .bss are not supported"
                    )
            continue
        buf = section_bytes[sec]
        sec_base = section_bases[sec]
        for obj, contrib_off in contributions[sec]:
            contrib = obj.sections[sec]
            for rel in contrib.relocs:
                if rel.symbol not in symbols:
                    undefined.append(
                        f"{rel.symbol} (referenced from {obj.path} "
                        f"section {sec} offset {rel.offset})"
                    )
                    continue
                S = symbols[rel.symbol]
                site = contrib_off + rel.offset
                where = f"{obj.path} {sec}+{rel.offset:#x}"
                _apply_reloc(buf, site, rel.kind, S, where)

    if undefined:
        raise LinkError("undefined symbol(s):\n  " + "\n  ".join(undefined))

    # 5. Build the flat ROM image: [.text | pad16 | .rodata | pad8 | .data].
    #    .bss is NOT included (zeroed at runtime by boot.S). Inter-section
    #    alignment padding is only emitted between sections that actually carry
    #    bytes — trailing alignment for an empty later section would just bloat
    #    the image with bytes nothing references, so it is omitted. The first
    #    non-empty section always starts at the image's first byte (vaddr base).
    stored_order = [".text", ".rodata", ".data"]
    image = bytearray()
    prev_end: int | None = None   # virtual address just past the last stored section
    for sec in stored_order:
        data = section_bytes[sec]
        if not data:
            continue
        if prev_end is not None:
            # Pad from the end of the previous stored section to this one's base.
            image += b"\x00" * (section_bases[sec] - prev_end)
        image += data
        prev_end = section_bases[sec] + len(data)

    return LinkResult(
        image=bytes(image),
        symbols=symbols,
        base=BASE_ADDR,
        section_bases=section_bases,
        section_sizes=section_sizes,
    )


# ── ROM production ────────────────────────────────────────────────────────────

def link_to_rom(
    object_paths: list[str],
    out_z64: str,
    name: str,
    ipl3: bytes | str | Path | None = None,
    entry: str = "_start",
) -> LinkResult:
    from pak.tools import rompack

    result = link_objects(object_paths, entry=entry)

    if ipl3 is None:
        ipl3_bytes = b"\x00" * rompack.IPL3_SIZE
    elif isinstance(ipl3, (str, Path)):
        ipl3_bytes = Path(ipl3).read_bytes()
    else:
        ipl3_bytes = ipl3

    rompack.pack_rom(result.image, ipl3_bytes, name, Path(out_z64))
    return result


# ── CLI ───────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="python -m pak.tools.n64_link",
        description="Link pak object files into a flat N64 image and pack a .z64",
    )
    ap.add_argument("objects", nargs="+", help="Input pak object files (boot object first)")
    ap.add_argument("-o", "--output", help="Output .z64 path")
    ap.add_argument("--name", default="PAK GAME", help="ROM name (max 20 chars)")
    ap.add_argument("--ipl3", default=None, help="Path to IPL3 binary (4032 bytes)")
    ap.add_argument("--emit-bin", default=None, help="Dump the flat image to this path")
    ap.add_argument("--entry", default="_start", help="Entry symbol (default _start)")
    args = ap.parse_args(argv)

    if not args.output and not args.emit_bin:
        ap.error("nothing to do: pass -o/--output and/or --emit-bin")

    try:
        if args.output:
            result = link_to_rom(
                args.objects, args.output, args.name,
                ipl3=args.ipl3, entry=args.entry,
            )
        else:
            result = link_objects(args.objects, entry=args.entry)
    except LinkError as exc:
        print(f"link error: {exc}", file=sys.stderr)
        return 1

    if args.emit_bin:
        Path(args.emit_bin).write_bytes(result.image)
        print(f"BIN: {args.emit_bin}  ({len(result.image):,} bytes)  base={result.base:#010x}")

    if args.entry in result.symbols:
        print(f"entry {args.entry} -> {result.symbols[args.entry]:#010x}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
