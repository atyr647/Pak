/*
 * n64.ld — Pak N64 linker script
 *
 * Code lives at 0x80000400 (start of RDRAM after the 1 KB IPL3 copies it).
 * The physical ROM addresses are handled by rompack.py — here we only care
 * about virtual addresses.
 */

OUTPUT_FORMAT("elf32-bigmips")
OUTPUT_ARCH(mips)
ENTRY(_start)

MEMORY {
    /* 4 MB RDRAM, first 0x400 bytes reserved for IPL3 stack */
    rdram (rwx) : ORIGIN = 0x80000400, LENGTH = 0x003FFC00
}

SECTIONS {
    . = 0x80000400;

    .text : {
        *(.text.boot)        /* boot.S _start must be first */
        *(.text .text.*)
        *(.gnu.linkonce.t*)
    } > rdram

    . = ALIGN(16);
    .rodata : {
        *(.rodata .rodata.*)
        *(.gnu.linkonce.r*)
    } > rdram

    . = ALIGN(8);
    .data : {
        *(.data .data.*)
        *(.gnu.linkonce.d*)
    } > rdram

    . = ALIGN(8);
    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(.gnu.linkonce.b*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > rdram

    /DISCARD/ : {
        *(.MIPS.abiflags)
        *(.pdr)
        *(.comment)
        *(.gnu.attributes)
        *(.reginfo)
        *(.mdebug)
    }
}
