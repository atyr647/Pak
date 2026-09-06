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
    /* ── CP0 interrupt control ──
     * Status bit 0 is IE, bit 10 is IM2 (the RCP's line). Pak has no way to
     * name a CP0 register, so the runtime calls these.
     *
     * The nops after mtc0 are the VR4300's CP0 hazard: the new Status is not
     * in effect for the next two instructions, and taking (or missing) an
     * interrupt in that window is exactly the bug that would only show up
     * under load. */
.globl __pak_irq_enable
__pak_irq_enable:
    mfc0    $8, $12
    ori     $8, $8, 0x0401      /* IM2 | IE */
    mtc0    $8, $12
    nop
    nop
    jr      $ra
    nop
.size __pak_irq_enable, . - __pak_irq_enable

    /* Returns the previous Status, so a critical section can put it back
     * with __pak_irq_restore rather than assuming interrupts were on. */
.globl __pak_irq_disable
__pak_irq_disable:
    mfc0    $2, $12
    lui     $9, 0xFFFF
    ori     $9, $9, 0xFFFE
    and     $8, $2, $9
    mtc0    $8, $12
    nop
    nop
    jr      $ra
    nop
.size __pak_irq_disable, . - __pak_irq_disable

.globl __pak_irq_restore
__pak_irq_restore:
    mtc0    $4, $12
    nop
    nop
    jr      $ra
    nop
.size __pak_irq_restore, . - __pak_irq_restore

.globl exception_stub
exception_stub:
    j       exception_entry
    nop

    /* Everything arrives here: a crash and an interrupt take the same vector.
     * The crash path resets $sp and never returns, so it has to be reached
     * only by an actual exception -- Cause.ExcCode tells the two apart, and it
     * is read with $k0/$k1, the only registers a handler may use before it has
     * saved anything.
     *
     * ExcCode 0 is Int. Any other code is a fault: fall through to the
     * original behaviour below. */
.globl exception_entry
exception_entry:
    mfc0    $26, $13            /* k0 = Cause */
    andi    $27, $26, 0x7C      /* ExcCode, still shifted left 2 */
    bnez    $27, .Lfault
    nop

    /* An interrupt. IP2 (Cause bit 10) is the RCP's line, the only one the
     * N64 has anything on -- IP7 is the CPU's own timer, IP3..IP6 are the
     * cartridge and reset lines. Anything else returns without doing work
     * rather than running the RCP handler for it. */
    andi    $27, $26, 0x0400
    beqz    $27, .Lirq_done
    nop

    /* Save what the ISR is allowed to clobber. It is compiled Pak code, so
     * that is the whole o32 caller-saved set, plus HI/LO (a multiply in the
     * interrupted code may be in flight) and $f12/$f14, the two FP registers
     * the codegen uses. EXL is set for the whole of this, so nothing nests
     * and the interrupted code's $sp is safe to build a frame on. */
    addiu   $29, $29, -96
    sw      $1, 0($29)
    sw      $2, 4($29)
    sw      $3, 8($29)
    sw      $4, 12($29)
    sw      $5, 16($29)
    sw      $6, 20($29)
    sw      $7, 24($29)
    sw      $8, 28($29)
    sw      $9, 32($29)
    sw      $10, 36($29)
    sw      $11, 40($29)
    sw      $12, 44($29)
    sw      $13, 48($29)
    sw      $14, 52($29)
    sw      $15, 56($29)
    sw      $24, 60($29)
    sw      $25, 64($29)
    sw      $31, 68($29)
    mfhi    $26
    sw      $26, 72($29)
    mflo    $26
    sw      $26, 76($29)
    swc1    $f12, 80($29)
    swc1    $f14, 84($29)

    jal     __pak_irq
    nop

    lwc1    $f14, 84($29)
    lwc1    $f12, 80($29)
    lw      $26, 76($29)
    mtlo    $26
    lw      $26, 72($29)
    mthi    $26
    lw      $31, 68($29)
    lw      $25, 64($29)
    lw      $24, 60($29)
    lw      $15, 56($29)
    lw      $14, 52($29)
    lw      $13, 48($29)
    lw      $12, 44($29)
    lw      $11, 40($29)
    lw      $10, 36($29)
    lw      $9, 32($29)
    lw      $8, 28($29)
    lw      $7, 24($29)
    lw      $6, 20($29)
    lw      $5, 16($29)
    lw      $4, 12($29)
    lw      $3, 8($29)
    lw      $2, 4($29)
    lw      $1, 0($29)
    addiu   $29, $29, 96

.Lirq_done:
    /* ERET clears EXL and jumps to EPC in one step; a jr would race the
     * Status write and take the next interrupt in the wrong place. */
    eret
    nop

    /* Reset $sp (it may be garbage), then dispatch: a non-zero
     * g_exc_handler is jalr'd, otherwise exception_paint. Hang after. */
.Lfault:
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
