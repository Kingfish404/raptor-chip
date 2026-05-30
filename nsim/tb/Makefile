# =============================================================================
# nsim/tb/Makefile — DPI-free SystemVerilog testbench (commercial + Verilator)
# -----------------------------------------------------------------------------
# Runs rapt_tb_top under Verilator / VCS / Xcelium / Questa, in RTL or
# gate-level (post-layout) mode with optional SDF back-annotation.
#
# Targets:
#   make verilator IMG=foo.bin            RTL sim under Verilator (alignment)
#   make vcs       IMG=foo.bin            RTL sim under Synopsys VCS
#   make xrun      IMG=foo.bin            RTL sim under Cadence Xcelium
#   make vsim      IMG=foo.bin            RTL sim under Siemens Questa
#   make vcs-gls   NETLIST=... LIBS=...   gate-level sim (set SDF=... for timing)
#   make filelist                         dump the RTL filelist (rtl.f)
#   make clean
#
# Key variables:
#   IMG       program .bin  -> PMEM  @ 0x80000000
#   MROM      trampoline .bin -> MROM @ 0x20000000 (default: nsim mrom-data.bin)
#   FLASH     flash .bin    -> FLASH @ 0x30000000 (optional)
#   MAX_CYCLES watchdog cycles (default 100_000_000)
#   WAVE=1    enable waveform dump
#   SDF       SDF file for gate-level timing (implies +define+RAPT_TB_SDF)
#   SDF_MTM   MINIMUM | TYPICAL | MAXIMUM (default MAXIMUM)
#   NETLIST   gate netlist .v for *-gls targets
#   LIBS      space-separated stdcell/SRAM/PAD sim model files (-v each)
#   RAPT_CONFIG  config preset (default: small)
#
# NOTE: the chip drives the host memory through the single-word rnp interface
# (axi2rnp -> pins -> rnp2axi), which only carries one beat per transaction.
# The DUT must therefore be built so its internal AXI master never issues a
# burst (arlen must stay 0). This requires the single-outstanding bus
# (-DRAPT_SOC) and a config WITHOUT the L2 cache (RAPT_L2_EN). The `default`
# and `large` presets enable RAPT_L2_EN (16-beat line fills) and are NOT
# compatible with the rnp interface; use a no-L2 preset such as `small`.
# =============================================================================

RAPTOR_HOME ?= $(abspath $(CURDIR)/../..)
RTL_SV      := $(RAPTOR_HOME)/rtl_sv
NSIM_RTL    := $(RAPTOR_HOME)/nsim/rtl
TB_DIR      := $(CURDIR)
# Single-word rnp interface needs a no-L2 preset (see note above).
RAPT_CONFIG ?= small
CONFIG_DIR  := $(RAPTOR_HOME)/configs/$(RAPT_CONFIG)

# Include search paths (config dir first so rapt_config.svh wins; dpic_mock
# stubs all DPI macros to no-ops so the harness is DPI-free).
INCDIRS := \
	$(CONFIG_DIR) \
	$(RAPTOR_HOME)/nsim/include \
	$(RTL_SV)/include \
	$(RTL_SV)/include/npc \
	$(RTL_SV)/include/dpic_mock

# RTL sources: rapt_pkg.sv first (package before import), then the rest of
# rtl_sv plus the rng_chip wrapper (nsim/rtl/wrap_rnp_soc.sv).
PKG_SRC  := $(RTL_SV)/rapt_pkg.sv
RTL_REST := $(shell find -L $(RTL_SV) -name '*.sv' ! -name 'rapt_pkg.sv') \
            $(NSIM_RTL)/wrap_rnp_soc.sv
TB_SRC   := $(TB_DIR)/rapt_tb_mem.sv $(TB_DIR)/rapt_tb_top.sv

VSRCS := $(PKG_SRC) $(RTL_REST) $(TB_SRC)

# The rnp single-word interface requires the single-outstanding ysyxSoC-style
# bus so the chip never issues a burst on its internal AXI master.
DEFINES += RAPT_SOC

# The rnp interface (and its axi2rnp/rnp2axi adapters) is hardwired 32-bit
# (rnp_mdata/rnp_cdata are 32 bits, arsize is fixed at 2). The tapeout chip is
# therefore RV32 only; an RV64 core cannot drive 64-bit accesses through it.
ISA64 ?= 0
ifeq ($(ISA64),1)
$(error ISA64=1 is not supported: the single-word rnp interface is 32-bit \
(RV32 only). Use the AXI-based nsim flow for RV64.)
endif

# Common plusargs assembled from variables.
PLUSARGS :=
ifneq ($(IMG),)
PLUSARGS += +IMG=$(abspath $(IMG))
endif
MROM ?= $(RAPTOR_HOME)/nsim/csrc/mem/mrom-data/build/mrom-data.bin
ifneq ($(wildcard $(MROM)),)
PLUSARGS += +MROM=$(MROM)
endif
ifneq ($(FLASH),)
PLUSARGS += +FLASH=$(abspath $(FLASH))
endif
ifneq ($(MAX_CYCLES),)
PLUSARGS += +MAX_CYCLES=$(MAX_CYCLES)
endif
ifneq ($(WAVE),)
PLUSARGS += +WAVE=1
endif
ifneq ($(SDF),)
PLUSARGS += +SDF=$(abspath $(SDF)) +SDF_MTM=$(or $(SDF_MTM),MAXIMUM)
endif

TOP := rapt_tb_top

# -----------------------------------------------------------------------------
.PHONY: help
help:
	@grep -E '^#   make' Makefile | sed 's/^#   //'

# -----------------------------------------------------------------------------
# Verilator (RTL alignment). Requires Verilator >= 5 (--timing, --binary).
# -----------------------------------------------------------------------------
VERILATOR ?= verilator
VL_FLAGS  := --binary -j 0 --timing --top-module $(TOP) \
	-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME \
	-Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-LATCH \
	-Wno-VARHIDDEN -Wno-TIMESCALEMOD \
	--timescale 1ns/1ps
ifneq ($(filter-out 0,$(WAVE)),)
VL_FLAGS += --trace-fst
endif

.PHONY: verilator
verilator: ## RTL sim under Verilator
	mkdir -p build/vl
	$(VERILATOR) $(VL_FLAGS) \
		$(addprefix +define+,$(DEFINES) RAPT_TB_EBREAK_HALT) \
		$(addprefix -I,$(INCDIRS)) \
		$(VSRCS) \
		--Mdir build/vl -o $(TOP)
	./build/vl/$(TOP) $(PLUSARGS)

# -----------------------------------------------------------------------------
# Synopsys VCS (RTL).
# -----------------------------------------------------------------------------
VCS       ?= vcs
VCS_FLAGS := -full64 -sverilog -debug_access+all +v2k -timescale=1ns/1ps \
	-l build/vcs_comp.log $(addprefix +define+,$(DEFINES)) \
	$(addprefix +incdir+,$(INCDIRS)) -top $(TOP)

.PHONY: vcs
vcs: ## RTL sim under VCS
	mkdir -p build
	$(VCS) $(VCS_FLAGS) $(VSRCS) -o build/simv
	./build/simv $(PLUSARGS) -l build/vcs_run.log

# Gate-level: pass +define+RAPT_TB_GLS, the netlist, and vendor sim libs.
.PHONY: vcs-gls
vcs-gls: ## gate-level sim under VCS (set NETLIST=, LIBS=, SDF=)
	mkdir -p build
	$(VCS) $(VCS_FLAGS) +define+RAPT_TB_GLS +define+RAPT_TB_SDF +neg_tchk -negdelay \
		$(addprefix -v ,$(LIBS)) \
		$(NETLIST) \
		$(RTL_SV)/perip/wrap_rnp.sv \
		$(TB_SRC) -o build/simv_gls
	./build/simv_gls $(PLUSARGS) +sdfverbose -l build/vcs_gls_run.log

# -----------------------------------------------------------------------------
# Cadence Xcelium (xrun).
# -----------------------------------------------------------------------------
XRUN       ?= xrun
XRUN_FLAGS := -64bit -sv -timescale 1ns/1ps -l build/xrun.log \
	$(addprefix -define ,$(DEFINES)) $(addprefix -incdir ,$(INCDIRS)) -top $(TOP)

.PHONY: xrun
xrun: ## RTL sim under Xcelium
	mkdir -p build
	$(XRUN) $(XRUN_FLAGS) $(VSRCS) $(PLUSARGS)

.PHONY: xrun-gls
xrun-gls: ## gate-level sim under Xcelium (set NETLIST=, LIBS=, SDF=)
	mkdir -p build
	$(XRUN) -64bit -sv -timescale 1ns/1ps -l build/xrun_gls.log -top $(TOP) \
		-define RAPT_TB_GLS -define RAPT_TB_SDF -negdelay \
		$(addprefix -v ,$(LIBS)) \
		$(NETLIST) $(RTL_SV)/perip/wrap_rnp.sv $(TB_SRC) $(PLUSARGS)

# -----------------------------------------------------------------------------
# Siemens Questa / ModelSim.
# -----------------------------------------------------------------------------
VLOG  ?= vlog
VSIM  ?= vsim
VLOG_FLAGS := -sv -timescale 1ns/1ps $(addprefix +define+,$(DEFINES)) \
	$(addprefix +incdir+,$(INCDIRS))

.PHONY: vsim
vsim: ## RTL sim under Questa
	mkdir -p build
	cd build && vlib work && $(VLOG) $(VLOG_FLAGS) $(VSRCS)
	cd build && $(VSIM) -c -do "run -all; quit -f" $(TOP) $(addprefix -g,) \
		$(addprefix +,$(patsubst +%,%,$(PLUSARGS)))

# -----------------------------------------------------------------------------
.PHONY: filelist
filelist: ## dump RTL filelist to rtl.f
	@printf '%s\n' $(addprefix +incdir+,$(INCDIRS)) > rtl.f
	@printf '%s\n' $(VSRCS) >> rtl.f
	@echo "wrote rtl.f"

.PHONY: clean
clean: ## remove build artifacts
	rm -rf build rtl.f *.vcd *.fsdb rapt_tb_sdf.log csrc *.daidir ucli.key \
		xcelium.d xrun.* INCA_libs work transcript vsim.wlf
