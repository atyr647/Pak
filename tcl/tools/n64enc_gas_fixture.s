/*
 * tcl/tools/n64enc_gas_fixture.s — every pseudo-instruction n64enc expands.
 *
 * The generated-code half of tcl/tools/n64enc_gas_test.tcl only covers what
 * the codegen happens to emit today, so a pseudo nothing currently uses (the
 * unsigned comparisons, say) would go unchecked. This names them all, once,
 * with operands chosen so each expansion arm is taken:
 *   - li across the four ranges it distinguishes
 *   - seq/sne against $zero and against a register
 *   - both operand orders for the ordered comparisons
 *
 * Assembled by GNU as and by n64enc; the two must agree byte for byte.
 */

.set noreorder
.section .text

.globl fixture
fixture:
    /* li: signed 16-bit, unsigned 16-bit, high half only, both halves,
       and an unsigned spelling of a negative constant */
    li      $t0, 5
    li      $t0, -8
    li      $t0, 32768
    li      $t0, 65535
    li      $t0, 0xA4000000
    li      $t0, 0x1004FFFF
    li      $t0, 0xFFFFFFF8

    /* register moves and the not/nor pair */
    move    $t0, $t1
    nor     $t0, $t1, $zero

    /* equality: against zero (folded) and against a register */
    seq     $t0, $t1, $zero
    seq     $t0, $zero, $t1
    seq     $t0, $t1, $t2
    sne     $t0, $t1, $zero
    sne     $t0, $zero, $t1
    sne     $t0, $t1, $t2

    /* signed ordered comparisons */
    slt     $t0, $t1, $t2
    sle     $t0, $t1, $t2
    sgt     $t0, $t1, $t2
    sge     $t0, $t1, $t2

    /* unsigned ordered comparisons */
    sltu    $t0, $t1, $t2
    sleu    $t0, $t1, $t2
    sgtu    $t0, $t1, $t2
    sgeu    $t0, $t1, $t2

    /* multiply and both divide signednesses */
    mul     $t0, $t1, $t2
    mult    $t1, $t2
    multu   $t1, $t2
    div     $zero, $t1, $t2
    divu    $zero, $t1, $t2
    mflo    $t0
    mfhi    $t0
    mtlo    $t1
    mthi    $t1

    /* shifts, variable and constant, both signednesses */
    sllv    $t0, $t1, $t2
    srlv    $t0, $t1, $t2
    srav    $t0, $t1, $t2
    sll     $t0, $t1, 3
    srl     $t0, $t1, 3
    sra     $t0, $t1, 3

    /* branch pseudos. bge is the one that expands to two words, so it is also
       the one whose delay slot the filler must never fill with another. */
.Ltarget:
    beqz    $t0, .Ltarget
    nop
    bnez    $t0, .Ltarget
    nop
    bge     $t1, $t2, .Ltarget
    nop
    /* CP0 and exception return, which only boot.S writes */
    mfc0    $t0, $12
    mtc0    $t0, $12
    eret

    /* break, plain and with a code: how an RSP microcode task ends */
    break
    break   0x7

    jr      $ra
    nop
