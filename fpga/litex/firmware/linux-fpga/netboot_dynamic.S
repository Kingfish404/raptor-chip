/* RV32/RV64 netboot: firmware/kernel/DTB/initramfs at final addresses.
 * Keep this trampoline and fw_dynamic_info outside OpenSBI's runtime memory.
 */
#include "cmo_init.h"
.section .text
.global _start
_start:
    raptor_enable_cmo
    li a0, 0
    li a1, 0x83f00000
    lla a2, dynamic_info
    li t0, 0x80000000
    fence rw, rw
    fence.i
    jr t0
.balign 8
#if __riscv_xlen == 64
#define INFO_WORD .quad
#define KERNEL_ENTRY 0x80200000
#else
#define INFO_WORD .word
#define KERNEL_ENTRY 0x80400000
#endif
dynamic_info:
    INFO_WORD 0x4942534f /* OSBI */
    INFO_WORD 2          /* fw_dynamic_info version */
    INFO_WORD KERNEL_ENTRY /* kernel entry: RV32 requires 4 MiB alignment */
    INFO_WORD 1          /* supervisor mode */
    INFO_WORD 0          /* options */
    INFO_WORD 0          /* boot hart */
