/* No compressed instructions or relaxation: exactly 64 target operations per
 * loop body. a0=memory, a1=measurement output; all registers are caller saved.
 * Timers intentionally include the loop and final fence. */
.option norvc
.option norelax
#if __riscv_xlen == 64
#define LOAD ld
#define STORE sd
#define SZ 8
#define PTR .dword
#else
#define LOAD lw
#define STORE sw
#define SZ 4
#define PTR .word
#endif
.macro begin name
.balign 64
.globl \name
.type \name,@function
\name:
  li t0, 0
  li t1, 0
  li t2, 0
  li t3, 0
  li t4, 0
  li t5, 0
  li t6, 0
  li a2, 0
.endm
.macro timer
  fence rw,rw
  csrr a5, mcycle
  csrr a6, minstret
.endm
.macro finish
  fence rw,rw
  csrr a3, minstret
  csrr a4, mcycle
  sub a3, a3, a6
  sub a4, a4, a5
  STORE a4, 0(a1)
  STORE a3, SZ(a1)
  add t0, t0, t1
  add t0, t0, t2
  add t0, t0, t3
  add t0, t0, t4
  add t0, t0, t5
  add t0, t0, t6
  add a0, t0, a2
  ret
.endm
begin empty
 timer
 finish

.macro arithmetic name, op, lanes
begin \name
  li t0, 1
  li t1, 1
  li t2, 1
  li t3, 1
  li t4, 1
  li t5, 1
  li t6, 1
  li a2, 1
  li a3, 3
  li a4, ROUNDS
  timer
1:
.rept 8
.if \lanes == 8
  \op t0,t0,a3
  \op t1,t1,a3
  \op t2,t2,a3
  \op t3,t3,a3
  \op t4,t4,a3
  \op t5,t5,a3
  \op t6,t6,a3
  \op a2,a2,a3
.else
.rept 8
  \op t0,t0,a3
.endr
.endif
.endr
  addi a4,a4,-1
  bnez a4,1b
  finish
.endm
arithmetic add_dep, add, 1
arithmetic add_8, add, 8
arithmetic xor_dep, xor, 1
arithmetic xor_8, xor, 8
arithmetic mul_dep, mul, 1
arithmetic mul_8, mul, 8

.macro rename name, war
begin \name
  li t0,7
  li a4,ROUNDS
  timer
1:
.rept 32
.if \war
  add t1,t0,zero
.else
  addi t0,zero,7
.endif
  addi t0,zero,7
.endr
  addi a4,a4,-1
  bnez a4,1b
  finish
.endm
rename rename_waw, 0
rename rename_war, 1

begin load_dep
  mv t0,a0
  li a4,ROUNDS
  timer
1:
.rept 64
  LOAD t0,0(t0)
.endr
  addi a4,a4,-1
  bnez a4,1b
  finish

.macro loads
  LOAD t0,0(a0)
  LOAD t1,64(a0)
  LOAD t2,128(a0)
  LOAD t3,192(a0)
  LOAD t4,256(a0)
  LOAD t5,320(a0)
  LOAD t6,384(a0)
  LOAD a2,448(a0)
.endm
begin load_8_hot
  li a4,ROUNDS
  timer
1:
.rept 8
  loads
.endr
  addi a4,a4,-1
  bnez a4,1b
  finish

begin load_8_cold
  timer
  loads
  finish

begin load_chain_cold
  mv t0,a0
  timer
.rept 8
  LOAD t0,0(t0)
.endr
  finish

/* Same six hot loads, but the isolated cold line is oldest vs youngest.
 * The aggregate completion time is observable; exact broadcast order needs
 * an IOQ/completion trace, not just this timer. */
.macro mixed name, first
begin \name
  li a7,4096
  add a7,a0,a7
  timer
.if \first
  LOAD t0,0(a0)
.endif
  LOAD t1,0(a7)
  LOAD t2,64(a7)
  LOAD t3,128(a7)
  LOAD t4,192(a7)
  LOAD t5,256(a7)
  LOAD t6,320(a7)
.if !\first
  LOAD t0,0(a0)
.endif
  finish
.endm
mixed load_miss_first, 1
mixed load_miss_last, 0

.macro stores name, stride
begin \name
  li t0,7
  li a4,ROUNDS
  timer
1:
.rept 8
  STORE t0,0(a0)
  STORE t0,(1*\stride)(a0)
  STORE t0,(2*\stride)(a0)
  STORE t0,(3*\stride)(a0)
  STORE t0,(4*\stride)(a0)
  STORE t0,(5*\stride)(a0)
  STORE t0,(6*\stride)(a0)
  STORE t0,(7*\stride)(a0)
.endr
  addi a4,a4,-1
  bnez a4,1b
  finish
.endm
stores store_same, 0
stores store_words, SZ
stores store_lines, 64

begin store_load
  li t0,7
  li a4,ROUNDS
  timer
1:
.rept 32
  STORE t0,0(a0)
  LOAD t1,0(a0)
.endr
  addi a4,a4,-1
  bnez a4,1b
  finish

/* Never software-initialize cold regions: doing so would warm the cache.
 * Each 8 KiB bank contains an eight-node ring at 64-byte spacing and a
 * separate region used for the hot side of mixed tests. */
.section .data
.balign 8192
.globl cold_banks
cold_banks:
.set bank,0
.rept (4*SAMPLES)
.set node,0
.rept 8
  PTR cold_banks + bank*8192 + ((node+1)%8)*64
  .zero (64-SZ)
.set node,node+1
.endr
.zero (8192-512)
.set bank,bank+1
.endr
