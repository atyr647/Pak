    .set noreorder
    .section .text
    .globl _start
_start:
    lui $sp, 0x8038
    ori $sp, $sp, 0x0000
    jal main
    nop
__bare_hang:
    j __bare_hang
    nop
