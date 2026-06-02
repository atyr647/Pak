    .set noreorder
    .section .text
    .globl _start
_start:
    li $t0, 0
    la $a0, msg
loop:
    addiu $t0, $t0, 1
    slt $t1, $t0, $a1
    bne $t1, $zero, loop
    nop
    jal helper
    nop
    bge $t0, $a1, done
    nop
done:
    jr $ra
    nop
helper:
    addu $v0, $t0, $t0
    jr $ra
    nop
    .section .rodata
    .align 2
msg:
    .asciiz "hi"
    .align 2
val:
    .word 305419896
