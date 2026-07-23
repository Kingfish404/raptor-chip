/* Compact egos KU15P serialboot stage0.
 *
 * LiteX loads one contiguous bundle at 0x82000000 and jumps here. Recreate the
 * old flat-image layout in DDR, then enter egos at 0x80000000.
 */

.equ STAGE_BASE,       0x82000000
.equ KERNEL_SRC,       (STAGE_BASE + 0x00001000)
.equ KERNEL_DST,       0x80000000
.equ KERNEL_SLOT_SIZE, 0x00010000
.equ DISK_SRC,         (STAGE_BASE + 0x00011000)
.equ DISK_DST,         0x80800000
.equ DISK_SIZE,        0x00400000

.section .text.init, "ax"
.global _start
_start:
    /* Preserve the old flat image's zero-initialized runtime area. */
    li      t0, KERNEL_DST
    li      t1, DISK_DST
1:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b

    li      t0, KERNEL_SRC
    li      t1, KERNEL_DST
    li      t2, KERNEL_SLOT_SIZE
    add     t2, t0, t2
2:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    bltu    t0, t2, 2b

    li      t0, DISK_SRC
    li      t1, DISK_DST
    li      t2, DISK_SIZE
    add     t2, t0, t2
3:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    bltu    t0, t2, 3b

    fence.i
    li      t0, KERNEL_DST
    jr      t0

4:
    wfi
    j       4b