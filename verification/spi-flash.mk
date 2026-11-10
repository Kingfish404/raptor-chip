# Raw reset-vector firmware and CPU integration with a real serial NOR model.
SPI_FLASH_BOOT_DIR := $(BUILD_DIR)/spi-flash-boot
SPI_FLASH_MODEL := $(VERIFY_HOME)/models/rapt_w25q64jw_model.sv
SPI_FLASH_SW := $(RAPTOR_HOME)/synth/configs/pin-limited/sw
SPI_FLASH_XLEN = $(if $(filter %-rv64,$@),64,32)
SPI_FLASH_BOOT_BIN = $(SPI_FLASH_BOOT_DIR)/boot-rv$(SPI_FLASH_XLEN).bin

.PHONY: spi-flash-boot-images
spi-flash-boot-images:
	mkdir -p "$(SPI_FLASH_BOOT_DIR)"
	@set -e; for xlen in 32 64; do \
		abi=ilp32; if [ "$$xlen" = 64 ]; then abi=lp64; fi; \
		$(CC) -march=rv$${xlen}i_zicsr_zifencei -mabi=$$abi -mcmodel=medany \
			-nostdlib -nostartfiles -I"$(SPI_FLASH_SW)" \
			-Wl,-T,"$(SPI_FLASH_SW)/flash_boot.ld",--build-id=none \
			-o "$(SPI_FLASH_BOOT_DIR)/boot-rv$$xlen.elf" "$(XSIM_DIR)/spi_flash_boot.S"; \
		$(OBJCOPY) -O binary "$(SPI_FLASH_BOOT_DIR)/boot-rv$$xlen.elf" \
			"$(SPI_FLASH_BOOT_DIR)/boot-rv$$xlen.bin"; \
	done

verilator-spi-flash-boot-rv32 verilator-spi-flash-boot-rv64: spi-flash-boot-images
$(eval $(call XLEN_TEST,spi-flash-boot,tb_spi_flash_boot,$$(SPI_FLASH_MODEL),,\
  +FLASH_IMAGE=$$(SPI_FLASH_BOOT_BIN) $$(SPI_FLASH_BOOT_PLUSARGS)))

# Standards-based host transactions with an independent target/monitor.
$(eval $(call XLEN_TEST,xspi-flash,tb_xspi_flash,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv))
$(eval $(call XLEN_TEST,xspi-flash-sfdp,tb_xspi_flash,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv,-GBadSfdp=1))

BOOT_CONTROL_BIN = $(SPI_FLASH_BOOT_DIR)/control-rv$(SPI_FLASH_XLEN).bin
.PHONY: boot-control-images
boot-control-images:
	mkdir -p "$(SPI_FLASH_BOOT_DIR)"
	@set -e; for xlen in 32 64; do \
		abi=ilp32; if [ "$$xlen" = 64 ]; then abi=lp64; fi; \
		$(CC) -march=rv$${xlen}i_zicsr_zifencei -mabi=$$abi -nostdlib -nostartfiles \
			-Wl,-Ttext=0x30000000,--build-id=none \
			-o "$(SPI_FLASH_BOOT_DIR)/control-rv$$xlen.elf" "$(XSIM_DIR)/boot_control.S"; \
		$(OBJCOPY) -O binary "$(SPI_FLASH_BOOT_DIR)/control-rv$$xlen.elf" \
			"$(SPI_FLASH_BOOT_DIR)/control-rv$$xlen.bin"; \
	done

verilator-chip-xspi-boot-rv32 verilator-chip-xspi-boot-rv64: boot-control-images
$(eval $(call XLEN_TEST,chip-xspi-boot,tb_chip_xspi_boot,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv $$(IO25_SOURCES) \
  $$(RAPTOR_HOME)/fpga/common/rtl/rapt_xspi_target.sv $$(XSIM_DIR)/tb_xspi_link.sv,,\
  +FLASH_IMAGE=$$(BOOT_CONTROL_BIN)))

$(eval $(call XLEN_TEST,chip-flash-absent,tb_chip_flash_recovery,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv $$(IO25_SOURCES) \
  $$(RAPTOR_HOME)/fpga/common/rtl/rapt_xspi_target.sv $$(XSIM_DIR)/tb_xspi_link.sv))
$(eval $(call XLEN_TEST,chip-flash-blank,tb_chip_flash_recovery,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv $$(IO25_SOURCES) \
  $$(RAPTOR_HOME)/fpga/common/rtl/rapt_xspi_target.sv $$(XSIM_DIR)/tb_xspi_link.sv,-GFailure=1))
$(eval $(call XLEN_TEST,chip-flash-stalled,tb_chip_flash_recovery,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv $$(IO25_SOURCES) \
  $$(RAPTOR_HOME)/fpga/common/rtl/rapt_xspi_target.sv $$(XSIM_DIR)/tb_xspi_link.sv,-GFailure=2))

$(eval $(call XLEN_TEST,xspi-protection,tb_xspi_protection,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv))

$(eval $(call XLEN_TEST,xspi-flash-delayed,tb_xspi_flash,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv,-GReturnDelayNs=85))

$(eval $(call XLEN_TEST,xspi-flash-board,tb_xspi_flash,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv,-GBoardMapping=1))

$(eval $(call XLEN_TEST,xspi-tail,tb_xspi_tail))
$(eval $(call XLEN_TEST,xspi-tail-late,tb_xspi_tail,,-GLate=1))

$(eval $(call XLEN_TEST,xspi-tail-skew-plus,tb_xspi_tail,,\
  -GHalfPeriod=8 -GClockHalfNs=50 -GReturnDelayNs=90 -GDqSkewNs=25))
$(eval $(call XLEN_TEST,xspi-tail-skew-minus,tb_xspi_tail,,\
  -GHalfPeriod=8 -GClockHalfNs=50 -GReturnDelayNs=90 -GDqSkewNs=-25))
$(eval $(call XLEN_TEST,xspi-tail-skew-fast-plus,tb_xspi_tail,,\
  -GHalfPeriod=8 -GClockHalfNs=5 -GReturnDelayNs=8.5 -GDqSkewNs=2.5))
$(eval $(call XLEN_TEST,xspi-tail-skew-fast-minus,tb_xspi_tail,,\
  -GHalfPeriod=8 -GClockHalfNs=5 -GReturnDelayNs=8.5 -GDqSkewNs=-2.5))

$(eval $(call XLEN_TEST,xspi-flash-board-edge,tb_xspi_flash,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv,\
  -GCoreClockHz=10000000 -GHalfPeriod=8 -GClockHalfNs=50 -GBoardMapping=1))
$(eval $(call XLEN_TEST,xspi-protection-span,tb_xspi_protection,\
  $$(VERIFY_HOME)/models/rapt_xspi_profile1_model.sv,-GNarrowLimit=1))

$(eval $(call XLEN_TEST,xspi-tail-min-late,tb_xspi_tail,,\
  -GHalfPeriod=8 -GClockHalfNs=50 -GLate=1))
$(eval $(call XLEN_TEST,xspi-tail-fast-min-late,tb_xspi_tail,,\
  -GHalfPeriod=8 -GClockHalfNs=5 -GLate=1))
