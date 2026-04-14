	.section .text, "ax", @progbits
	.global boot_helper
boot_helper:
	/* x10=r1(a0), x11=r2(a1), x12=r3(a2), x13=addr */
	/* Flush I-cache before jumping to newly loaded code. */
	fence.i
	fence
	/*
	 * RISC-V SBI boot convention: a0 = hartid, a1 = FDT address.
	 * BIOS passes a1=0; override with the DTB location in main_ram.
	 * Convention: DTB is placed at MAIN_RAM_BASE + DTB_OFFSET by the
	 * combined image recipe in fpga/litex/Makefile (default 36 MiB).
	 */
	li a1, 0x82400000
	jr x13
