/*
 * boot.S — Pak N64 crt0
 *
 * After the IPL3 bootstrap copies the ROM payload to RDRAM and jumps
 * here (0x80000400), we:
 *   1. Set up the stack pointer
 *   2. Zero .bss
 *   3. Install CPU exception vectors at 0x80000000 / 80 / 100 / 180
 *   4. Call main()
 *   5. Spin forever on return
 *
 * Pak cannot express mfc0/mtc0/cache, so the vector trampoline stays here.
 * A crash jal's exception_paint (runtime.pk64) which fills the framebuffers
 * solid red (RGBA5551 0xF801) so a hung black screen is not a mystery.
 */

.set noreorder
.set noat

.section .text.boot,"ax",@progbits
.globl _start
.type  _start, @function
_start:
    /* ── Disable IE and BEV so vectors live in KSEG0, not bootstrap ── */
    mfc0    $8, $12             /* read CP0 Status */
    lui     $9, 0xFFBF
    ori     $9, $9, 0xFFFE      /* ~ (BEV | IE) */
    and     $8, $8, $9
    mtc0    $8, $12

    /* ── Stack: top of first 4 MB RDRAM ── */
    lui     $29, 0x8040         /* $sp = 0x80400000 */
    addiu   $29, $29, -8

    /* ── Zero .bss ── */
    la      $8, __bss_start
    la      $9, __bss_end
    beq     $8, $9, .Ldone_bss
    nop
.Lbss_loop:
    sw      $0, 0($8)
    addiu   $8, $8, 4
    bne     $8, $9, .Lbss_loop
    nop
.Ldone_bss:

    /* ── Install exception vectors ──
     * Copy the 8-byte stub (j exception_entry; nop) to the four VR4300
     * vector addresses through KSEG1 so the stores bypass D-cache, then
     * Hit-Invalidate the corresponding I-cache lines in KSEG0. */
    la      $8, exception_stub
    lw      $12, 0($8)
    lw      $13, 4($8)
    lui     $9, 0xA000          /* KSEG1 = 0xA0000000 */
    li      $10, 4
    li      $11, 0x80
.Lvec_copy:
    sw      $12, 0($9)
    sw      $13, 4($9)
    addu    $9, $9, $11
    addiu   $10, $10, -1
    bnez    $10, .Lvec_copy
    nop

    lui     $8, 0x8000          /* KSEG0 = 0x80000000 */
    li      $10, 4
.Lvec_ic:
    cache   0x10, 0($8)         /* Hit_Invalidate_I */
    addu    $8, $8, $11
    addiu   $10, $10, -1
    bnez    $10, .Lvec_ic
    nop

    /* ── Tell the PIF the boot process is finished ──
     * Writing 8 to the last word of PIF RAM (0xBFC007FC). If nobody does,
     * the PIF halts the CPU five seconds in -- ares reports it as
     * "boot timeout: CPU has not sent the boot termination command".
     * Official IPL3 left this to the game, and libdragon's *compat* IPL3
     * (the one Pak ships) follows suit; only its mainline loader does it
     * itself. So it is the crt0's job here.
     * SI_STATUS is 0xA4800018; bits 0 and 1 are DMA_BUSY and IO_BUSY. */
    lui     $9, 0xA480
    ori     $9, $9, 0x0018
.Lsi_idle:
    lw      $10, 0($9)
    andi    $10, $10, 0x3
    bnez    $10, .Lsi_idle
    nop
    lui     $8, 0xBFC0
    ori     $8, $8, 0x07FC
    li      $11, 8
    sw      $11, 0($8)

    /* ── Call main ── */
    jal     main
    nop

    /* ── Hang on return ── */
.Lhalt:
    j       .Lhalt
    nop

.size _start, . - _start

    /* 8-byte trampoline copied to each exception vector. `j` is patched
     * at link time; copying the relocated word is correct because 0x80000000
     * and 0x80000400 sit in the same 256 MB J-region. */
.globl exception_stub
exception_stub:
    j       exception_entry
    nop

    /* Reset $sp (it may be garbage), then dispatch: a non-zero
     * g_exc_handler is jalr'd, otherwise exception_paint. Hang after. */
.globl exception_entry
exception_entry:
    mfc0    $8, $12
    lui     $9, 0xFFBF
    ori     $9, $9, 0xFFFE
    and     $8, $8, $9
    mtc0    $8, $12
    lui     $29, 0x8040
    addiu   $29, $29, -16
    la      $8, g_exc_handler
    lw      $8, 0($8)
    beq     $8, $0, .Ldefault
    nop
    jalr    $8
    nop
    j       .Lexc_hang
    nop
.Ldefault:
    jal     exception_paint
    nop
.Lexc_hang:
    j       .Lexc_hang
    nop
