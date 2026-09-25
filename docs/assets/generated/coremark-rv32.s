00000000 <matrix_mul_matrix>:
   0:	beqz a0,800009b2
   2:	mv t6,a2
   4:	sh1add t1,a0,a2
   6:	li t0,0
   8:	li t2,0
   a:	sh2add t4,t0,a1
   c:	mv t3,a3
   e:	li t5,0
   10:	mv a2,t3
   12:	mv a5,t6
   14:	li a6,0
   16:	lh a4,0(a5)
   18:	lh a7,0(a2)
   1a:	addi a5,a5,2
   1c:	sh1add a2,a0,a2
   1e:	mul a4,a4,a7
   20:	add a6,a6,a4
   22:	bne t1,a5,80000976
   24:	sw a6,0(t4)
   26:	addi a5,t5,1
   28:	addi t4,t4,4
   2a:	addi t3,t3,2
   2c:	beq a0,a5,800009a0
   2e:	mv t5,a5
   30:	j 80000970
   32:	sh1add t6,a0,t6
   34:	add t0,t0,a0
   36:	sh1add t1,a0,t1
   38:	beq t2,t5,800009b2
   3a:	addi t2,t2,1
   3c:	j 80000968
   3e:	ret
00000040 <core_bench_list>:
   40:	lh t5,4(a0)
   42:	addi sp,sp,-48
   44:	sw s0,40(sp)
   46:	sw ra,44(sp)
   48:	sw s1,36(sp)
   4a:	sw s2,32(sp)
   4c:	sw s3,28(sp)
   4e:	lw s0,36(a0)
   50:	blez t5,800010b4
   52:	bltz a1,800010bc
   54:	beqz s0,800010ce
   56:	mv a3,a1
   58:	li t4,0
   5a:	li t6,0
   5c:	li a2,0
   5e:	li a7,0
00000060 <crc16>:
   60:	zext.b a5,a0
   62:	lui a3,0x1c
   64:	addi a3,a3,-1
   66:	xor a5,a5,a1
   68:	clmul a5,a5,a3
   6a:	lui a4,0x14
   6c:	addi a4,a4,2
   6e:	srli a1,a1,0x8
   70:	srli a0,a0,0x8
   72:	zext.b a0,a0
   74:	slli a5,a5,0x18
   76:	clmulh a5,a5,a4
00000078 <putch>:
   78:	lui a5,0x10000
   7a:	sb a0,0(a5)
   7c:	ret
