/* A single full-width device command must reach the endpoint intact. */
#include "raptor_platform.h"
.option norvc
.section .text
.globl _start
_start:
  li a0, 1
  li t0, RAPTOR_FINISHER_BASE
  li t1, 0x5555
  sb t1, 0(t0) // invalid one-byte command must not power off
  fence iorw,iorw
  sw t1, 0(t0)
  fence iorw,iorw
  ebreak
