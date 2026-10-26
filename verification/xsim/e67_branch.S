.option norvc
.section .text
.global _start
_start:
  li t2, 256
  la t0, target_a
  la t1, target_b
site:
  addi t2, t2, -1
  beqz t2, done
  jalr zero, 0(t0)
  j site
.balign 16
target_a:
  mv t0, t1
  j site
.balign 16
target_b:
  la t0, target_a
  j site
done:
  li a0, 0
  ebreak
