# Boot real CPU firmware through both serial backends of the 25-signal top.
IO25_BOOT_DIR := $(BUILD_DIR)/io25-boot
IO25_SW := $(RAPTOR_HOME)/synth/configs/io25/sw
IO25_BOOT_XLEN = $(if $(filter %-rv64,$@),64,32)
IO25_BOOT_BIN = $(IO25_BOOT_DIR)/boot-rv$(IO25_BOOT_XLEN).bin

.PHONY: io25-boot-images
io25-boot-images:
	mkdir -p "$(IO25_BOOT_DIR)"
	@set -e; for xlen in 32 64; do \
		abi=ilp32; if [ "$$xlen" = 64 ]; then abi=lp64; fi; \
		$(CC) -march=rv$${xlen}i_zicsr_zifencei -mabi=$$abi -mcmodel=medany \
			-nostdlib -nostartfiles -I"$(IO25_SW)" \
			-Wl,-Ttext=0x30000000,--build-id=none \
			-o "$(IO25_BOOT_DIR)/boot-rv$$xlen.elf" "$(XSIM_DIR)/chip_io25_boot.S"; \
		$(OBJCOPY) -O binary "$(IO25_BOOT_DIR)/boot-rv$$xlen.elf" \
			"$(IO25_BOOT_DIR)/boot-rv$$xlen.bin"; \
	done

verilator-chip-io25-rv32 verilator-chip-io25-rv64: io25-boot-images
$(eval $(call XLEN_TEST,chip-io25,tb_chip_io25,$$(IO25_SOURCES) \
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv $$(RAPTOR_HOME)/fpga/common/rtl/rapt_xspi_target.sv \
  $$(VERIFY_HOME)/models/rapt_boot_rom_model.sv,,+FLASH_IMAGE=$$(IO25_BOOT_BIN)))
