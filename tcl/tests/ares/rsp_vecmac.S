/*
 * tcl/tests/ares/rsp_vecmac.S — the smallest useful RSP multiply-ACCUMULATE
 * task: VMUDN then VMADH, read back through VSAR.
 *
 * rsp_vecadd.S proved plain vector arithmetic (VADD). Every real transform
 * or lighting microcode leans on the OTHER half of the vector unit instead:
 * a multiply that starts the 48-bit accumulator (VMUDx) followed by one or
 * more multiplies that ADD into it (VMADx) -- exactly the pattern
 * docs/rsp-microcode-in-pak.md's worked example chains across a 4x4 matrix.
 * This is the two-instruction version of that chain.
 *
 *   VMUDN $v3,$v1,$v2        -- acc[n] = u16(v1[n]) * s16(v2[n])   (fresh)
 *   VMADH $v3,$v1,$v2        -- acc[n] += v1[n] * v2[n] (top 32 bits only)
 *   VSAR  $v4,$v4,$v4[9]     -- $v4 = ACCM (the accumulator's mid slice)
 *
 * v1 = {2,3,4,5,6,7,8,9}, v2 = {3,3,3,3,3,3,3,3}. Every product stays small
 * and positive, so there is no sign-extension or saturation subtlety to
 * account for -- but it is NOT simply doubled: VMUDN's own product (2*3=6,
 * ...) is small enough to land entirely in the accumulator's LOW slice, so
 * ACCM is still 0 when VMADH runs, and VMADH's product becomes the whole of
 * ACCM. Final ACCM is v1[n]*v2[n], once -- {6,9,12,15,18,21,24,27} --
 * checked by the CPU side in rsp_vecmac.pk64.
 *
 * The words this assembles to are checked into rsp_vecmac.pk64, and
 * tcl/tools/ares_test.tcl re-assembles this file and refuses to run if the
 * two have drifted apart.
 */

.set noreorder
.section .text

.globl rsp_vecmac
rsp_vecmac:
    lqv     $v1[0], 0($zero)
    lqv     $v2[0], 16($zero)
    vmudn   $v3, $v1, $v2
    vmadh   $v3, $v1, $v2
    vsar    $v4, $v4, $v4[9]
    sqv     $v4[0], 32($zero)
    break
    nop
