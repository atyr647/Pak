/*
 * tcl/tests/ares/rsp_add.S — the smallest useful RSP task.
 *
 * Reads two words out of DMEM, adds them, writes the sum back, and breaks.
 * No vector unit: the RSP's scalar half is a MIPS I subset, which is why
 * tcl/n64enc.tcl can assemble this at all.
 *
 * DMEM is the RSP's whole address space for loads and stores -- $zero as the
 * base register means "DMEM offset 0". There is no RDRAM from in here; the
 * CPU DMAs the operands in and the result out.
 *
 *   DMEM[0] + DMEM[4] -> DMEM[8]
 *
 * Eight instructions, 32 bytes: SP DMA moves multiples of 8 only.
 *
 * The words this assembles to are checked into tcl/tests/ares/rsp.pk64, and
 * tcl/tools/ares_test.tcl re-assembles this file and refuses to run if the two
 * have drifted apart.
 */

.set noreorder
.section .text

.globl rsp_add
rsp_add:
    lw      $8, 0($0)
    lw      $9, 4($0)
    nop
    addu    $10, $8, $9
    sw      $10, 8($0)
    nop
    break
    nop
