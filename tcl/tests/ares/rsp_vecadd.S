/*
 * tcl/tests/ares/rsp_vecadd.S — the smallest useful RSP VECTOR task.
 *
 * rsp_add.S proved the RSP's scalar half (a MIPS I subset) runs real
 * microcode. This is the same shape of proof for the vector half: load two
 * 8-lane vectors, add them lane-by-lane, write the sum back, break.
 *
 *   DMEM[0..15]  (v1, 8 lanes) + DMEM[16..31] (v2, 8 lanes) -> DMEM[32..47]
 *
 * v1 = {1,2,3,4,5,6,7,8}, v2 = {10,20,30,40,50,60,70,80}, so a correct run
 * leaves DMEM[32..47] = {11,22,33,44,55,66,77,88} -- checked by the CPU side
 * in rsp_vecadd.pk64, which DMAs both vectors in, runs this, and DMAs the
 * sum back out.
 *
 * $zero as the base register means "DMEM offset 0", same as rsp_add.S --
 * there is no RDRAM in here, only the 4 KB DMEM the SP DMA engine fills.
 *
 * The words this assembles to are checked into rsp_vecadd.pk64, and
 * tcl/tools/ares_test.tcl re-assembles this file and refuses to run if the
 * two have drifted apart.
 */

.set noreorder
.section .text

.globl rsp_vecadd
rsp_vecadd:
    lqv     $v1[0], 0($zero)
    lqv     $v2[0], 16($zero)
    vadd    $v3, $v1, $v2
    sqv     $v3[0], 32($zero)
    break
    nop
