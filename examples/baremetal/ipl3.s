    .set noreorder
    .section .text
    .globl ipl3
ipl3:
    # Minimal IPL3: PI-DMA the program from cartridge to RDRAM, then jump to it.
    # Runs from DMEM (0xA4000040). Uses the PI registers, which both real
    # hardware and HLE emulators service (direct CPU reads of cart space do not
    # work under mupen64plus, hence DMA).
    lui  $t0, 0xA460          # t0 = PI register base 0xA4600000
ipl3_wait1:
    lw   $t1, 0x10($t0)       # PI_STATUS
    andi $t1, $t1, 0x3        # DMA busy | IO busy
    bne  $t1, $zero, ipl3_wait1
    nop
    ori  $t2, $zero, 0x0400   # PI_DRAM_ADDR = phys 0x00000400
    sw   $t2, 0x00($t0)
    lui  $t2, 0x1000
    ori  $t2, $t2, 0x1000     # PI_CART_ADDR = 0x10001000 (ROM offset 0x1000)
    sw   $t2, 0x04($t0)
    lui  $t2, 0x0001          # length-1 = 0x1FFFF (copy 128 KiB)
    ori  $t2, $t2, 0xFFFF
    sw   $t2, 0x0C($t0)       # PI_WR_LEN: writing starts the cart->RDRAM DMA
ipl3_wait2:
    lw   $t1, 0x10($t0)       # PI_STATUS
    andi $t1, $t1, 0x3
    bne  $t1, $zero, ipl3_wait2
    nop
    lui  $t4, 0x8000
    ori  $t4, $t4, 0x0400     # entry = 0x80000400 (cached)
    jr   $t4
    nop
