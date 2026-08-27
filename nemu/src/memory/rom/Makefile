# Canonical device-tree sources live in <repo>/linux/dts (single source of
# truth for both sim and nemu). dtc reads from there; generated .dtb files are
# still written here because CONFIG_ROM_DTB_PATH references this directory.
NEMU_DTS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../..)/linux/dts

build_dtb:
	# device-tree-compiler: dtc
	dtc -I dts $(NEMU_DTS_DIR)/qemu-rv32ima.dts -O dtb -o qemu-rv32ima.dtb
	dtc -I dts $(NEMU_DTS_DIR)/spike-rv32ima.dts -O dtb -o spike-rv32ima.dtb
	dtc -I dts $(NEMU_DTS_DIR)/qemu-rv64ima.dts -O dtb -o qemu-rv64ima.dtb
	dtc -I dts $(NEMU_DTS_DIR)/spike-rv64ima.dts -O dtb -o spike-rv64ima.dtb

parse_dtb: generate_qemu_rv32_dts generate_qemu_rv64_dts
	dtc -I dtb qemu-rv32.dtb -O dts -o $(NEMU_DTS_DIR)/qemu-rv32.dts
	dtc -I dtb qemu-rv64.dtb -O dts -o $(NEMU_DTS_DIR)/qemu-rv64.dts

generate_qemu_rv32_dts:
	qemu-system-riscv32 -M virt,dumpdtb=qemu-rv32.dtb

generate_qemu_rv64_dts:
	qemu-system-riscv64 -M virt,dumpdtb=qemu-rv64.dtb
