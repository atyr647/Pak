/*
 * boot.S — Pak N64 crt0
 *
 * After the IPL3 bootstrap copies the ROM payload to RDRAM and jumps
 * here (0x80000400), we:
 *   1. Set up the stack pointer
 *   2. Zero .bss
 *   3. Call main()
 *   4. Spin forever on return
 */

.set noreorder
.set noat

.section .text.boot,"ax",@progbits
.globl _start
.type  _start, @function
_start:
    /* ── Disable interrupts ── */
    mfc0    $8, $12             /* read CP0 Status */
    li      $9, ~1
    and     $8, $8, $9          /* clear IE bit */
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

    /* ── Call main ── */
    jal     main
    nop

    /* ── Hang on return ── */
.Lhalt:
    j       .Lhalt
    nop

.size _start, . - _start
