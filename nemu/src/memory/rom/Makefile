# Canonical device-tree sources live in <repo>/linux/dts (single source of
# truth for both sim and nemu). dtc reads from there; generated .dtb files are
# still written here because CONFIG_ROM_DTB_PATH references this directory.
NEMU_DTS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../..)/linux/dts
DTB_NAMES := qemu-rv32ima spike-rv32ima spike-rv32gc spike-rv32gc-nemu \
	qemu-rv64ima spike-rv64ima spike-rv64gc spike-rv64gc-nemu

build_dtb: $(addsuffix .dtb,$(DTB_NAMES))

%.dtb: $(NEMU_DTS_DIR)/%.dts
	dtc -I dts $< -O dtb -o $@

spike-rv32gc-nemu.dtb: $(NEMU_DTS_DIR)/spike-rv32gc.dts
spike-rv64gc-nemu.dtb: $(NEMU_DTS_DIR)/spike-rv64gc.dts

parse_dtb: generate_qemu_rv32_dts generate_qemu_rv64_dts
	dtc -I dtb qemu-rv32.dtb -O dts -o $(NEMU_DTS_DIR)/qemu-rv32.dts
	dtc -I dtb qemu-rv64.dtb -O dts -o $(NEMU_DTS_DIR)/qemu-rv64.dts

generate_qemu_rv32_dts:
	qemu-system-riscv32 -M virt,dumpdtb=qemu-rv32.dtb

generate_qemu_rv64_dts:
	qemu-system-riscv64 -M virt,dumpdtb=qemu-rv64.dtb

.PHONY: build_dtb parse_dtb generate_qemu_rv32_dts generate_qemu_rv64_dts
