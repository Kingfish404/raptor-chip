# Unified derived configuration. The main Makefile includes this file at the
# profile, simulation, and FPGA stages so public variables and targets remain
# visible there while evaluation order stays unchanged.

ifeq ($(LITEX_CONFIG_PHASE),profile)

# Private board capability table. User-facing board selection remains in the
# main Makefile; these values only drive derived configuration.
BOARD_tang_mega_138k_pro_VENDOR              := gowin
BOARD_tang_mega_138k_pro_PY                  := tang_mega_138k_pro.py
BOARD_tang_mega_138k_pro_BITNAME             := sipeed_tang_mega_138k_pro.fs
BOARD_tang_mega_138k_pro_TIMINGRPT           :=
BOARD_tang_mega_138k_pro_UART                :=
BOARD_tang_mega_138k_pro_DEVICE              :=
BOARD_tang_mega_138k_pro_PART                :=
BOARD_tang_mega_138k_pro_DEFAULT_SYS_CLK     := 10000000
BOARD_tang_mega_138k_pro_LINUX_SYS_CLK       := 10000000
BOARD_tang_mega_138k_pro_DEFAULT_RAPT_CONFIG := default
BOARD_tang_mega_138k_pro_HAS_LITEDRAM        := 0
BOARD_tang_mega_138k_pro_HAS_MIG             := 0
BOARD_tang_mega_138k_pro_LINUX_WITH_MIG      := 0
BOARD_tang_mega_138k_pro_MIG_TCL             :=
BOARD_tang_mega_138k_pro_HAS_SDCARD          := 0
BOARD_tang_mega_138k_pro_DEFAULT_WITH_SDCARD := 0
BOARD_tang_mega_138k_pro_LINUX_WITH_SDCARD   := 0
BOARD_tang_mega_138k_pro_LINUX_MAIN_RAM_SIZE := 0x80000
BOARD_tang_mega_138k_pro_VIVADO_FLASH        := 0

BOARD_mlk_cu08_ku15p_VENDOR              := vivado
BOARD_mlk_cu08_ku15p_PY                  := mlk_cu08_ku15p.py
BOARD_mlk_cu08_ku15p_BITNAME             := mlk_cu08_ku15p.bit
BOARD_mlk_cu08_ku15p_TIMINGRPT           := mlk_cu08_ku15p_timing.rpt
BOARD_mlk_cu08_ku15p_UART                := /dev/ttyUSB1
BOARD_mlk_cu08_ku15p_DEVICE              := xcku15p
BOARD_mlk_cu08_ku15p_PART                := xcku15p-ffva1156-2-e
BOARD_mlk_cu08_ku15p_DEFAULT_SYS_CLK     := 10000000
BOARD_mlk_cu08_ku15p_LINUX_SYS_CLK       := 50000000
BOARD_mlk_cu08_ku15p_DEFAULT_RAPT_CONFIG := default
BOARD_mlk_cu08_ku15p_HAS_LITEDRAM        := 1
BOARD_mlk_cu08_ku15p_LINUX_WITH_LITEDRAM := 0
BOARD_mlk_cu08_ku15p_LITEDRAM_SIZE       := 0x40000000
BOARD_mlk_cu08_ku15p_HAS_MIG             := 1
BOARD_mlk_cu08_ku15p_LINUX_WITH_MIG      := 1
BOARD_mlk_cu08_ku15p_MIG_TCL             := scripts/ku15p_ddr4_mig.tcl
BOARD_mlk_cu08_ku15p_HAS_SDCARD          := 1
BOARD_mlk_cu08_ku15p_DEFAULT_WITH_SDCARD := 1
BOARD_mlk_cu08_ku15p_LINUX_WITH_SDCARD   := 1
BOARD_mlk_cu08_ku15p_LINUX_MAIN_RAM_SIZE := 0
BOARD_mlk_cu08_ku15p_VIVADO_FLASH        := 1

BOARD_mlk_cu07_ku15p_VENDOR              := vivado
BOARD_mlk_cu07_ku15p_PY                  := mlk_cu07_ku15p.py
BOARD_mlk_cu07_ku15p_BITNAME             := mlk_cu07_ku15p.bit
BOARD_mlk_cu07_ku15p_TIMINGRPT           := mlk_cu07_ku15p_timing.rpt
BOARD_mlk_cu07_ku15p_UART                := /dev/ttyUSB0
BOARD_mlk_cu07_ku15p_DEVICE              := xcku15p
BOARD_mlk_cu07_ku15p_PART                := xcku15p-ffva1156-2-e
BOARD_mlk_cu07_ku15p_DEFAULT_SYS_CLK     := 10000000
BOARD_mlk_cu07_ku15p_LINUX_SYS_CLK       := 50000000
BOARD_mlk_cu07_ku15p_DEFAULT_RAPT_CONFIG := default
BOARD_mlk_cu07_ku15p_HAS_LITEDRAM        := 1
BOARD_mlk_cu07_ku15p_LINUX_WITH_LITEDRAM := 0
BOARD_mlk_cu07_ku15p_LITEDRAM_SIZE       := 0x40000000
BOARD_mlk_cu07_ku15p_HAS_MIG             := 1
BOARD_mlk_cu07_ku15p_LINUX_WITH_MIG      := 1
BOARD_mlk_cu07_ku15p_MIG_TCL             := scripts/ku15p_ddr4_mig.tcl
BOARD_mlk_cu07_ku15p_HAS_SDCARD          := 1
BOARD_mlk_cu07_ku15p_DEFAULT_WITH_SDCARD := 1
BOARD_mlk_cu07_ku15p_LINUX_WITH_SDCARD   := 1
BOARD_mlk_cu07_ku15p_LINUX_MAIN_RAM_SIZE := 0
BOARD_mlk_cu07_ku15p_VIVADO_FLASH        := 1

BOARD_alinx_axau15_VENDOR              := vivado
BOARD_alinx_axau15_PY                  := alinx_axau15.py
BOARD_alinx_axau15_BITNAME             := alinx_axau15.bit
BOARD_alinx_axau15_TIMINGRPT           := alinx_axau15_timing.rpt
BOARD_alinx_axau15_UART                :=
BOARD_alinx_axau15_DEVICE              := xcau15p
BOARD_alinx_axau15_PART                := xcau15p-ffvb676-2-i
BOARD_alinx_axau15_DEFAULT_SYS_CLK     := 25000000
BOARD_alinx_axau15_LINUX_SYS_CLK       := 60000000
BOARD_alinx_axau15_DEFAULT_RAPT_CONFIG := small
BOARD_alinx_axau15_HAS_LITEDRAM        := 0
BOARD_alinx_axau15_HAS_MIG             := 1
BOARD_alinx_axau15_LINUX_WITH_MIG      := 1
BOARD_alinx_axau15_MIG_TCL             := scripts/axau15_ddr4_mig.tcl
BOARD_alinx_axau15_HAS_SDCARD          := 1
BOARD_alinx_axau15_DEFAULT_WITH_SDCARD := 0
BOARD_alinx_axau15_LINUX_WITH_SDCARD   := 1
BOARD_alinx_axau15_LINUX_MAIN_RAM_SIZE := 0
BOARD_alinx_axau15_VIVADO_FLASH        := 0

BOARD_xilinx_vcu118_VENDOR              := vivado
BOARD_xilinx_vcu118_PY                  := xilinx_vcu118.py
BOARD_xilinx_vcu118_BITNAME             := xilinx_vcu118.bit
BOARD_xilinx_vcu118_TIMINGRPT           := xilinx_vcu118_timing.rpt
BOARD_xilinx_vcu118_UART                :=
BOARD_xilinx_vcu118_DEVICE              := xcvu9p
BOARD_xilinx_vcu118_PART                := xcvu9p-flga2104-2-e
BOARD_xilinx_vcu118_DEFAULT_SYS_CLK     := 75000000
BOARD_xilinx_vcu118_LINUX_SYS_CLK       := 50000000
BOARD_xilinx_vcu118_DEFAULT_RAPT_CONFIG := default
BOARD_xilinx_vcu118_HAS_LITEDRAM        := 1
BOARD_xilinx_vcu118_LINUX_WITH_LITEDRAM := 0
BOARD_xilinx_vcu118_LITEDRAM_SIZE       := 0x40000000
BOARD_xilinx_vcu118_HAS_MIG             := 0
BOARD_xilinx_vcu118_LINUX_WITH_MIG      := 0
BOARD_xilinx_vcu118_MIG_TCL             :=
BOARD_xilinx_vcu118_HAS_SDCARD          := 0
BOARD_xilinx_vcu118_DEFAULT_WITH_SDCARD := 0
BOARD_xilinx_vcu118_LINUX_WITH_SDCARD   := 0
BOARD_xilinx_vcu118_LINUX_MAIN_RAM_SIZE := 0x80000
BOARD_xilinx_vcu118_VIVADO_FLASH        := 0

_LINUX_PROFILE_BENCH_GOALS := coremark-fpga main-fpga main-fpga-build irqtest-fpga app-fpga-upload app-llm-fpga app-llm-ops-fpga app-llm-infer-fpga app-llm-train-fpga
_FPGA_ALIAS_GOALS := $(BOARD_ALIASES) $(addsuffix -build,$(BOARD_ALIASES))
_IS_FPGA_GOAL := $(strip \
	$(foreach g,$(MAKECMDGOALS),$(if $(findstring fpga,$(g)),y)) \
	$(filter $(_FPGA_ALIAS_GOALS),$(MAKECMDGOALS)))
_IS_LINUX_PROFILE_DEFAULT_GOAL := $(strip $(_IS_FPGA_GOAL) $(filter $(_LINUX_PROFILE_BENCH_GOALS),$(MAKECMDGOALS)))
_FPGA_BOARD_EXPLICIT := $(filter command line environment override,$(origin FPGA_BOARD))
_FPGA_DETECT_GOAL := $(filter fpga-detect fpga-info,$(MAKECMDGOALS))
_FPGA_BOARD_REQUIRED_GOALS := fpga-gen fpga-build fpga-build-force fpga-load fpga-flash fpga fpga-timing-ok \
	linux-fpga-build linux-fpga-rv32-build linux-fpga-rv64-build \
	linux-fpga-load linux-fpga-rv32-load linux-fpga-rv64-load \
	linux-fpga-run linux-fpga-rv32-run linux-fpga-rv64-run \
	linux-fpga-e2e linux-fpga-rv32-e2e linux-fpga-rv64-e2e \
	opensbi-fpga-run opensbi-fpga-rv32-run opensbi-fpga-rv64-run \
	opensbi-fpga-e2e opensbi-fpga-rv32-e2e opensbi-fpga-rv64-e2e \
	fpga-smoke $(BOARD_ALIASES) $(addsuffix -build,$(BOARD_ALIASES))
_FPGA_BOARD_REQUIRED := $(filter $(_FPGA_BOARD_REQUIRED_GOALS),$(MAKECMDGOALS))
_FPGA_AUTO_DETECT_ENABLED := $(and $(_IS_FPGA_GOAL),$(or $(_FPGA_DETECT_GOAL),$(if $(_FPGA_BOARD_EXPLICIT),,$(filter 1 yes true on,$(FPGA_AUTO_DETECT)))))
_FPGA_DETECT_REFRESH := $(or $(_FPGA_DETECT_GOAL),$(filter 1 yes true on,$(FPGA_DETECT_REFRESH)))

FPGA_DETECTED_PARTS := $(strip $(if $(_FPGA_AUTO_DETECT_ENABLED),$(shell \
	set -o pipefail; \
	cache="$(strip $(FPGA_DETECT_CACHE))"; \
	if [ -n "$(_FPGA_DETECT_REFRESH)" ] || [ ! -f "$$cache" ]; then \
		mkdir -p "$$(dirname "$$cache")"; \
		raw="$$cache.raw.$$PPID"; \
		tmp="$$cache.tmp.$$PPID"; \
		info_tmp="$(strip $(FPGA_DETECT_INFO_CACHE)).tmp.$$PPID"; \
		count_tmp="$(strip $(FPGA_DETECT_COUNT_CACHE)).tmp.$$PPID"; \
		if command -v "$(VIVADO)" >/dev/null 2>&1; then \
			"$(VIVADO)" -mode batch -nojournal -nolog \
				-source "$(LITEX_DIR)/scripts/vivado_detect.tcl" > "$$raw" 2>/dev/null || true; \
			sed -n 's/^RAPTOR_FPGA_PART=//p' "$$raw" | sort -u > "$$tmp"; \
			sed -n 's/^RAPTOR_FPGA_INFO=//p' "$$raw" | sort -u > "$$info_tmp"; \
			sed -n 's/^RAPTOR_FPGA_COUNT=//p' "$$raw" | tail -n 1 > "$$count_tmp"; \
			[ -s "$$count_tmp" ] || printf '0\n' > "$$count_tmp"; \
		else \
			: > "$$tmp"; : > "$$info_tmp"; printf '0\n' > "$$count_tmp"; \
		fi; \
		mv -f "$$tmp" "$$cache"; \
		mv -f "$$info_tmp" "$(strip $(FPGA_DETECT_INFO_CACHE))"; \
		mv -f "$$count_tmp" "$(strip $(FPGA_DETECT_COUNT_CACHE))"; \
		rm -f "$$raw"; \
	fi; \
	cat "$$cache" 2>/dev/null)))
FPGA_DETECTED_BOARDS := $(strip $(foreach board,$(BOARDS),$(if $(filter $(BOARD_$(board)_DEVICE),$(FPGA_DETECTED_PARTS)),$(board))))
FPGA_DETECTED_BOARD := $(if $(word 2,$(FPGA_DETECTED_BOARDS)),,$(firstword $(FPGA_DETECTED_BOARDS)))
FPGA_DETECTED_INFO := $(strip $(shell cat $(FPGA_DETECT_INFO_CACHE) 2>/dev/null))
FPGA_DETECTED_COUNT := $(strip $(shell cat $(FPGA_DETECT_COUNT_CACHE) 2>/dev/null || echo 0))
ifneq ($(word 2,$(FPGA_DETECTED_BOARDS)),)
ifneq ($(strip $(_FPGA_DETECT_GOAL)),)
else ifneq ($(strip $(_FPGA_BOARD_REQUIRED)),)
$(error Multiple supported FPGA boards detected ($(FPGA_DETECTED_BOARDS)); set FPGA_BOARD explicitly for build/load/flash operations)
else
endif
endif

_default_variant = linux32
_linux_fpga_profile = $(if $(and $(_IS_FPGA_GOAL),$(filter linux32 linux64,$(1))),1,)
_default_fpga_board = $(if $(FPGA_DETECTED_BOARD),$(FPGA_DETECTED_BOARD),$(if $(LINUX_FPGA_PROFILE),mlk_cu07_ku15p,tang_mega_138k_pro))

define _linux_profile_notice
$(if $(and $(filter file,$(origin VARIANT)),$(filter linux32,$(VARIANT)),$(_IS_LINUX_PROFILE_DEFAULT_GOAL),$(if $(strip $(GOWIN_APP)),,y),$(filter 0,$(MAKELEVEL))),$(info [litex] GOWIN_APP empty on FPGA goal -> defaulting to VARIANT=linux32))
endef

else ifeq ($(LITEX_CONFIG_PHASE),sim)

ifeq ($(ROM),sim)
SIM_ROM_BIN  := $(FW_SIM_BIN)
SIM_ROM_DEP  := $(FW_SIM_BIN)
SIM_ROM_FLAGS := --no-compile-software --integrated-rom-init=$(SIM_ROM_BIN)
SIM_NEEDS_BIOS_PATCHES := 0
else ifeq ($(ROM),fpga)
SIM_ROM_BIN  := $(FW_FPGA_BIN)
SIM_ROM_DEP  := $(FW_FPGA_BIN)
SIM_ROM_FLAGS := --no-compile-software --integrated-rom-init=$(SIM_ROM_BIN)
SIM_NEEDS_BIOS_PATCHES := 0
else ifeq ($(ROM),bios)
SIM_ROM_BIN  :=
SIM_ROM_DEP  :=
SIM_ROM_FLAGS :=
SIM_NEEDS_BIOS_PATCHES := 1
else
$(error Invalid ROM='$(ROM)'. Use ROM=sim|fpga|bios)
endif

ifeq ($(SOC),default)
SIM_SOC_FLAGS :=
else ifeq ($(SOC),fpga)
SIM_SOC_FLAGS := --integrated-rom-size=0x8000 --integrated-sram-size=0x2000 --integrated-main-ram-size=0
else
$(error Invalid SOC='$(SOC)'. Use SOC=default|fpga)
endif

SIM_PAYLOAD_BIN   :=
SIM_PAYLOAD_BUILD :=
ifeq ($(PAYLOAD),none)
else ifeq ($(PAYLOAD),coremark)
SIM_PAYLOAD_BIN   := $(COREMARK_BIN)
SIM_PAYLOAD_BUILD := coremark-build
else ifeq ($(PAYLOAD),microbench)
SIM_PAYLOAD_BIN   := $(MICROBENCH_BIN)
SIM_PAYLOAD_BUILD := microbench-build
else ifeq ($(PAYLOAD),opensbi)
SIM_PAYLOAD_BIN   := $(OPENSBI_BIN)
SIM_PAYLOAD_BUILD := opensbi-build
else ifeq ($(PAYLOAD),linux)
SIM_PAYLOAD_BIN    = $(LINUX_IMG)
SIM_PAYLOAD_BUILD := $(LINUX_VARIANT)-build
else ifeq ($(PAYLOAD),img)
ifndef IMG
$(error PAYLOAD=img requires IMG=/path/to/binary.bin)
endif
SIM_PAYLOAD_BIN   := $(IMG)
else ifneq (,$(filter embench-%,$(PAYLOAD)))
_EMBENCH_NAME     := $(patsubst embench-%,%,$(PAYLOAD))
SIM_PAYLOAD_BIN   := $(EMBENCH_BENCH)/build/$(_EMBENCH_NAME)/$(_EMBENCH_NAME).bin
SIM_PAYLOAD_BUILD := embench-build-$(_EMBENCH_NAME)
else ifneq (,$(filter app-llm-%,$(PAYLOAD)))
_APP_LLM_NAME     := $(patsubst app-llm-%,%,$(PAYLOAD))
SIM_PAYLOAD_BIN   := $(APP_LLM_BUILD_DIR)/llm-$(_APP_LLM_NAME).bin
SIM_PAYLOAD_BUILD := app-llm-build-$(_APP_LLM_NAME)
else ifneq (,$(filter test-%,$(PAYLOAD)))
_TEST_NAME        := $(patsubst test-%,%,$(PAYLOAD))
SIM_PAYLOAD_BIN   := $(TESTS_BUILD_DIR)/$(_TEST_NAME).bin
SIM_PAYLOAD_BUILD := tests
else
$(error Invalid PAYLOAD='$(PAYLOAD)')
endif

ifneq ($(SIM_PAYLOAD_BIN),)
SIM_PAYLOAD_FLAG = --ram-init=$(SIM_PAYLOAD_BIN)
else
SIM_PAYLOAD_FLAG :=
endif

else ifeq ($(LITEX_CONFIG_PHASE),fpga)

BOOT_MODE := $(strip $(BOOT_MODE))
ifneq ($(BOOT_MODE),custom)
ifneq ($(BOOT_MODE),bios)
$(error Invalid BOOT_MODE='$(BOOT_MODE)'. Use BOOT_MODE=custom or BOOT_MODE=bios)
endif
endif

FPGA_FLAVOR := $(BOOT_MODE)
FPGA_FLAVOR := $(FPGA_FLAVOR)-$(VARIANT)
ifneq (,$(filter 1 yes true on,$(WITH_LITEDRAM)))
FPGA_FLAVOR := $(FPGA_FLAVOR)-litedram
endif
ifneq (,$(filter 1 yes true on,$(WITH_MIG)))
FPGA_FLAVOR := $(FPGA_FLAVOR)-mig
endif
ifneq (,$(filter 1 yes true on,$(WITH_SDCARD)))
FPGA_FLAVOR := $(FPGA_FLAVOR)-sdcard
endif
ifneq (,$(filter 1 yes true on,$(SDCARD_BOOT)))
FPGA_FLAVOR := $(FPGA_FLAVOR)-boot
endif
FPGA_FLAVOR := $(FPGA_FLAVOR)-$(RAPT_CONFIG)
FPGA_FLAVOR_SUFFIX := $(strip $(FPGA_FLAVOR_SUFFIX))
ifneq ($(FPGA_FLAVOR_SUFFIX),)
FPGA_FLAVOR := $(FPGA_FLAVOR)-$(FPGA_FLAVOR_SUFFIX)
endif

FPGA_DIR       := $(BUILD_DIR)/$(FPGA_BOARD)/$(FPGA_FLAVOR)
FPGA_BUILD_DIR := $(FPGA_DIR)/gateware
_FPGA_REPORTS_INDEX_ARGS = FPGA_BUILD_DIR="$(FPGA_BUILD_DIR)" FPGA_BOARD="$(FPGA_BOARD)" BOOT_MODE="$(BOOT_MODE)"
FPGA_BITSTREAM := $(FPGA_BUILD_DIR)/$(BOARD_$(FPGA_BOARD)_BITNAME)

ifneq ($(strip $(GOWIN_APP)),)
GOWIN_BIN_DIR := $(GOWIN_APP)/Contents/Resources/Gowin_EDA/IDE/bin
export PATH   := $(GOWIN_BIN_DIR):$(PATH)
endif

VIVADO := $(strip $(VIVADO))
VIVADO_JOBS := $(strip $(VIVADO_JOBS))
VIVADO_INCREMENTAL := $(strip $(VIVADO_INCREMENTAL))
VIVADO_ROUTE_DIRECTIVE := $(strip $(VIVADO_ROUTE_DIRECTIVE))
OFL := $(strip $(OFL))
OFL_CABLE := $(strip $(OFL_CABLE))

ifeq ($(FPGA_VENDOR),vivado)
FPGA_LOAD_TOOL_CHECK = command -v $(VIVADO) >/dev/null 2>&1 || { echo "[ERR] $(VIVADO) not found on PATH — source settings64.sh"; exit 1; }
FPGA_LOAD_CMD  = $(VIVADO) -mode batch -nojournal -nolog -source $(LITEX_DIR)/scripts/vivado_load.tcl -tclargs $(FPGA_BITSTREAM) $(FPGA_DEVICE)
FPGA_FLASH_CMD = $(VIVADO) -mode batch -nojournal -nolog -source $(LITEX_DIR)/scripts/vivado_flash.tcl -tclargs $(FPGA_BITSTREAM) $(FPGA_BUILD_DIR) $(FPGA_DEVICE)
else
FPGA_LOAD_TOOL_CHECK = command -v $(OFL) >/dev/null 2>&1 || { echo "[ERR] openFPGALoader not found"; exit 1; }
FPGA_LOAD_CMD  = $(OFL) --cable $(OFL_CABLE) --bitstream $(FPGA_BITSTREAM)
FPGA_FLASH_CMD = $(OFL) --cable $(OFL_CABLE) --write-flash --external-flash --bitstream $(FPGA_BITSTREAM)
endif

WITH_LED_CHASER_FLAG := $(if $(filter 1 yes true on,$(WITH_LED_CHASER)),--with-led-chaser,)
WITH_LITEDRAM_FLAG := $(if $(filter 1 yes true on,$(WITH_LITEDRAM)),--with-litedram,)
LITEDRAM_SIZE_FLAG := $(if $(WITH_LITEDRAM_FLAG),--litedram-size=$(LITEDRAM_SIZE),)
WITH_MIG_FLAG := $(if $(filter 1 yes true on,$(WITH_MIG)),--with-mig,)
MIG_SIZE_FLAG := $(if $(WITH_MIG_FLAG),--mig-size=$(MIG_SIZE),)
WITH_SDCARD_FLAG := $(if $(filter 1 yes true on,$(WITH_SDCARD)),--with-sdcard,)
SDCARD_BOOT_FLAG := $(if $(filter 1 yes true on,$(SDCARD_BOOT)),--sdcard-boot,)
VIVADO_INCREMENTAL_FLAG := $(if $(filter 1 yes true on,$(VIVADO_INCREMENTAL)),--vivado-incremental,)

ifneq ($(WITH_LITEDRAM_FLAG),)
ifneq ($(WITH_MIG_FLAG),)
$(error WITH_LITEDRAM and WITH_MIG are mutually exclusive)
endif
endif

ifeq ($(BOOT_MODE),custom)
_FPGA_BOOT_FLAGS := --boot-mode=custom --integrated-rom-init=$(FW_FPGA_BIN)
_FPGA_FW_DEP     := $(FW_FPGA_BIN)
else
_FPGA_BOOT_FLAGS := --boot-mode=bios
_FPGA_FW_DEP     :=
endif

_FPGA_FLAGS = --output-dir=$(FPGA_DIR) \
	--cpu-variant=$(VARIANT) --sys-clk-freq=$(SYS_CLK) \
	--vivado-max-threads=$(VIVADO_JOBS) --vivado-route-directive=$(VIVADO_ROUTE_DIRECTIVE) $(VIVADO_INCREMENTAL_FLAG) \
	--uart-baudrate=$(UART_BAUD) \
	$(_FPGA_BOOT_FLAGS) \
	$(_MAIN_RAM_FLAG) \
	$(WITH_LED_CHASER_FLAG) $(WITH_LITEDRAM_FLAG) $(LITEDRAM_SIZE_FLAG) \
	$(WITH_MIG_FLAG) $(MIG_SIZE_FLAG) $(WITH_SDCARD_FLAG) $(SDCARD_BOOT_FLAG) $(EXTRA_FLAGS)

FPGA_STAMP := $(FPGA_DIR)/.bitstream_stamp
_FPGA_HASH_COMMON_INPUTS = $(PACK_SV) $(FPGA_PY) $(LITEX_DIR)/Makefile \
	$(LITEX_DIR)/mk/config.mk $(LITEX_DIR)/mk/recipes.mk \
	$(LITEX_DIR)/scripts/patch_litex_sdcard_boot.py \
	$(if $(WITH_MIG_FLAG),$(LITEX_DIR)/$(BOARD_$(FPGA_BOARD)_MIG_TCL),)
ifeq ($(BOOT_MODE),custom)
_FPGA_HASH_INPUTS = $(_FPGA_HASH_COMMON_INPUTS) $(FW_FPGA_BIN)
else
_FPGA_HASH_INPUTS = $(_FPGA_HASH_COMMON_INPUTS)
endif
# Keep this as a shell command instead of a parse-time value: LiteX finalization
# can refresh PACK_SV, so fpga-build must recompute the stamp after generation.
_FPGA_HASH_COMMAND = { cat $(_FPGA_HASH_INPUTS) 2>/dev/null; printf '%s' '$(_FPGA_FLAGS)'; printf '%s' '$(RAPT_PACK_VFLAGS)'; } | shasum 2>/dev/null | cut -d' ' -f1

GOWIN_REPORTS_INDEX_SRC  := $(LITEX_DIR)/scripts/reports_index.html
GOWIN_REPORTS_INDEX_DST  := $(FPGA_BUILD_DIR)/impl/index.html
VIVADO_REPORTS_INDEX_GEN := $(LITEX_DIR)/scripts/vivado_reports_index.py
VIVADO_REPORTS_INDEX_DST := $(FPGA_BUILD_DIR)/index.html

else
$(error Invalid LITEX_CONFIG_PHASE='$(LITEX_CONFIG_PHASE)')
endif
