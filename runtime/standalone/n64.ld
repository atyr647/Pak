/*
 * n64.ld — Pak standalone memory map (the flat linker reproduces this).
 *
 * Cached KSEG0 addresses. Uncached KSEG1 is (addr | 0xA0000000), which is
 * how the runtime names framebuffers and the RDP display list.
 *
 *   0x80000400  .text / .rodata / .data / .bss
 *               64-byte gap (linker error if sections grow into it)
 *   0x80200000  FB0  320×240×16bpp   (KSEG1 0xA0200000)  0x25800 bytes
 *   0x80225800  FB1                  (KSEG1 0xA0225800)
 *   0x8024B000  FB2  ends 0x80270800 (KSEG1 0xA024B000)
 *   0x80271000  RDP display list, 8 KB (KSEG1 0xA0271000)
 *   0x80280000  bump heap
 *   0x803C0000  heap limit
 *   0x80400000  stack top (grows down)
 *
 * A full Z buffer is not reserved yet (TRI_TEX is affine; 0x0E + Z is later).
 * Cart image is padded to 4/8/16/32/64 MiB by tcl/n64rom.tcl; FZ crashes on a
 * 2.9 MB ROM.
 *
 * The physical ROM addresses (header, IPL3, payload at 0x1000) are handled
 * by tcl/n64rom.tcl — here we only care about virtual addresses.
 */

OUTPUT_FORMAT("elf32-bigmips")
OUTPUT_ARCH(mips)
ENTRY(_start)

MEMORY {
    /* 4 MB RDRAM, first 0x400 bytes reserved for IPL3 stack */
    rdram (rwx) : ORIGIN = 0x80000400, LENGTH = 0x001FFC00 /* up to FB0 */
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

    /* Hardware regions (FB, DL, heap, stack) live above 0x80200000 and are
     * not placed by ld. The flat linker errors if _end + 64 > FB0. */
    ASSERT(. <= 0x801FFF80, "program sections overlap framebuffer 0 (need a 64-byte gap)")

    /DISCARD/ : {
        *(.MIPS.abiflags)
        *(.pdr)
        *(.comment)
        *(.gnu.attributes)
        *(.reginfo)
        *(.mdebug)
    }
}
