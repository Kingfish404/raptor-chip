RAPTOR_HOME := $(abspath ../..)
SHELL := /bin/bash
.DEFAULT_GOAL := all
HDL_HOME := $(RAPTOR_HOME)/rtl
NEMU_HOME := $(RAPTOR_HOME)/nemu
BUILD_DIR ?= $(RAPTOR_HOME)/verification/build/subsystem
CONFIG ?= default
XLEN ?= 32
TRACE_INSTS ?= 20000
IMG ?= $(RAPTOR_HOME)/abstract-machine/app/am-kernels/benchmarks/coremark_eembc/build/coremark-riscv$(XLEN)-npc.bin
TRACE_PREFIX ?= $(BUILD_DIR)/coremark-rv$(XLEN)-$(TRACE_INSTS)
VERILATOR ?= verilator
VERILATOR_JOBS ?= 2
FE_MAX_CYCLES ?= 1000000
EXTRA_DEFINES ?=
BPU_REPORT_DIR ?= $(BUILD_DIR)/bpu
BPU_BASELINE ?=

ifeq ($(XLEN),64)
RV_DEFINE := -DRAPT_RV64
endif

PKG := $(HDL_HOME)/rapt_pkg.sv
RTL := $(shell find $(HDL_HOME) -name '*.sv' ! -name rapt_pkg.sv)
HEADERS := $(HDL_HOME)/configs/$(CONFIG)/rapt_config.svh \
              $(shell find $(HDL_HOME)/include -name '*.svh') \
              $(RAPTOR_HOME)/verification/xsim/tb_core_bcast_defaults.svh
INCLUDES := -I$(HDL_HOME)/configs/$(CONFIG) -I$(HDL_HOME)/include \
            -I$(HDL_HOME)/include/dpic_mock -I$(HDL_HOME)/include/npc \
            -I$(RAPTOR_HOME)/verification/xsim
SV_FLAGS := --binary --timing --assert -Wno-fatal -j $(VERILATOR_JOBS) \
            --timescale 1ns/1ps $(RV_DEFINE) $(EXTRA_DEFINES) $(INCLUDES)

.PHONY: trace fe bpu be mem structure all FORCE
FORCE:
trace:
	@mkdir -p $(dir $(TRACE_PREFIX))
	@cd $(NEMU_HOME) && \
	  RAPT_SUBSYSTEM_TRACE_PREFIX=$(abspath $(TRACE_PREFIX)) \
	  ./build/riscv$(XLEN)-nemu-interpreter -b -m $(TRACE_INSTS) $(abspath $(IMG)) \
	  > $(abspath $(TRACE_PREFIX)).nemu.log 2>&1
	@test -s $(TRACE_PREFIX).inst && test -s $(TRACE_PREFIX).mem
	@python3 check_trace.py --image $(abspath $(IMG)) \
	  --inst $(TRACE_PREFIX).inst --mem $(TRACE_PREFIX).mem \
	  --output $(TRACE_PREFIX).meta.json
	@echo "Trace: $(TRACE_PREFIX).inst $(TRACE_PREFIX).mem"

$(BUILD_DIR)/build.args: FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s\n' 'CONFIG=$(CONFIG) XLEN=$(XLEN) EXTRA_DEFINES=$(EXTRA_DEFINES) VERILATOR=$(VERILATOR)' \
	  | cmp -s - $@ || printf '%s\n' 'CONFIG=$(CONFIG) XLEN=$(XLEN) EXTRA_DEFINES=$(EXTRA_DEFINES) VERILATOR=$(VERILATOR)' > $@

$(BUILD_DIR)/fe/Vtb_frontend_trace: $(PKG) $(RTL) $(HEADERS) tb_frontend_trace.sv $(BUILD_DIR)/build.args
	@mkdir -p $(BUILD_DIR)/fe
	@$(VERILATOR) $(SV_FLAGS) --top-module tb_frontend_trace \
	  $(PKG) $(RTL) tb_frontend_trace.sv --Mdir $(BUILD_DIR)/fe \
	  > $(BUILD_DIR)/fe/build.log 2>&1 || { tail -70 $(BUILD_DIR)/fe/build.log; exit 1; }

fe: $(BUILD_DIR)/fe/Vtb_frontend_trace
	@set -e -o pipefail; $(BUILD_DIR)/fe/Vtb_frontend_trace +IMG=$(abspath $(IMG)) \
	  +TRACE=$(abspath $(TRACE_PREFIX)).inst +MAX_CYCLES=$(FE_MAX_CYCLES) \
	  $(FE_ARGS) | tee $(BUILD_DIR)/fe/run.log

# The BPU view reuses the real FE replay and its compiled executable. The
# detailed counters live in the testbench, so no production RTL is added.
bpu: $(BUILD_DIR)/fe/Vtb_frontend_trace
	@mkdir -p $(BPU_REPORT_DIR)
	@set -e -o pipefail; $(BUILD_DIR)/fe/Vtb_frontend_trace +IMG=$(abspath $(IMG)) \
	  +TRACE=$(abspath $(TRACE_PREFIX)).inst +MAX_CYCLES=$(FE_MAX_CYCLES) \
	  +BPU_EVENTS=$(BPU_REPORT_DIR)/events.csv \
	  $(FE_ARGS) | tee $(BPU_REPORT_DIR)/run.log
	@python3 bpu_report.py --log $(BPU_REPORT_DIR)/run.log \
	  --events $(BPU_REPORT_DIR)/events.csv \
	  --trace $(abspath $(TRACE_PREFIX)).inst --image $(abspath $(IMG)) \
	  --xlen $(XLEN) --config $(CONFIG) --defines="$(EXTRA_DEFINES)" \
	  --executable $(BUILD_DIR)/fe/Vtb_frontend_trace \
	  $(if $(BPU_BASELINE),--baseline $(BPU_BASELINE),) \
	  --output $(BPU_REPORT_DIR)/summary.json

$(BUILD_DIR)/mem/Vtb_memory_trace: $(PKG) $(RTL) $(HEADERS) tb_memory_trace.sv tb_axi_image.sv $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv $(BUILD_DIR)/build.args
	@mkdir -p $(BUILD_DIR)/mem
	@$(VERILATOR) $(SV_FLAGS) --top-module tb_memory_trace \
	  $(PKG) $(RTL) $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv tb_axi_image.sv tb_memory_trace.sv \
	  --Mdir $(BUILD_DIR)/mem > $(BUILD_DIR)/mem/build.log 2>&1 || \
	  { tail -70 $(BUILD_DIR)/mem/build.log; exit 1; }

mem: $(BUILD_DIR)/mem/Vtb_memory_trace
	@set -e -o pipefail; $(BUILD_DIR)/mem/Vtb_memory_trace +IMG=$(abspath $(IMG)) \
	  +TRACE=$(abspath $(TRACE_PREFIX)).inst \
	  +MEM_TRACE=$(abspath $(TRACE_PREFIX)).mem $(MEM_ARGS) \
	  | tee $(BUILD_DIR)/mem/run.log

$(BUILD_DIR)/be/Vtb_backend_trace: $(PKG) $(RTL) $(HEADERS) tb_backend_trace.sv tb_axi_image.sv $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv $(BUILD_DIR)/build.args
	@mkdir -p $(BUILD_DIR)/be
	@$(VERILATOR) $(SV_FLAGS) --top-module tb_backend_trace \
	  $(PKG) $(RTL) $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv tb_axi_image.sv tb_backend_trace.sv \
	  --Mdir $(BUILD_DIR)/be > $(BUILD_DIR)/be/build.log 2>&1 || \
	  { tail -70 $(BUILD_DIR)/be/build.log; exit 1; }

be: $(BUILD_DIR)/be/Vtb_backend_trace
	@set -e -o pipefail; $(BUILD_DIR)/be/Vtb_backend_trace +IMG=$(abspath $(IMG)) \
	  +TRACE=$(abspath $(TRACE_PREFIX)).inst $(BE_ARGS) \
	  | tee $(BUILD_DIR)/be/run.log

all: trace
	+$(MAKE) fe
	+$(MAKE) be
	+$(MAKE) mem

structure:
	@set -e; for module in frontend backend memory; do \
	  $(MAKE) -C $(RAPTOR_HOME)/synth/yosys structure-check MODULE=$$module \
	    RAPT_CONFIG=$(CONFIG) EXTRA_DEFINES="$(if $(filter 64,$(XLEN)),-DRAPT_RV64) $(EXTRA_DEFINES)"; \
	done

# Small, deterministic CPU/VPU integration experiment. The payload lives only
# in BUILD_DIR; no generated program or separate test source enters the tree.

.PHONY: vector-smoke-data vector-backend-smoke vector-core-smoke
vector-smoke-data:
	python3 vector_programs.py smoke --output "$(BUILD_DIR)/vector-smoke" --xlen $(XLEN)

vector-backend-smoke: vector-smoke-data
	$(MAKE) be BUILD_DIR="$(BUILD_DIR)" XLEN="$(XLEN)" \
	  EXTRA_DEFINES="$(strip $(EXTRA_DEFINES) -DRAPT_V_EXTENSION -DRAPT_ASSERT_EN)" \
	  IMG="$(BUILD_DIR)/vector-smoke/trace.bin" TRACE_PREFIX="$(BUILD_DIR)/vector-smoke/trace" \
	  BE_ARGS="+VECTOR_SMOKE"

.PHONY: vector-backend-memory
vector-backend-memory: vector-smoke-data
	$(MAKE) be BUILD_DIR="$(BUILD_DIR)" XLEN="$(XLEN)" \
	  EXTRA_DEFINES="$(strip $(EXTRA_DEFINES) -DRAPT_V_EXTENSION -DRAPT_ASSERT_EN)" \
	  IMG="$(BUILD_DIR)/vector-smoke/memory.bin" TRACE_PREFIX="$(BUILD_DIR)/vector-smoke/memory" \
	  BE_ARGS="+VECTOR_MEMORY_SMOKE"

.PHONY: vector-store-fault
vector-store-fault: vector-smoke-data
	$(MAKE) be BUILD_DIR="$(BUILD_DIR)" XLEN="$(XLEN)" \
	  EXTRA_DEFINES="$(strip $(EXTRA_DEFINES) -DRAPT_V_EXTENSION -DRAPT_ASSERT_EN)" \
	  IMG="$(BUILD_DIR)/vector-smoke/fault.bin" TRACE_PREFIX="$(BUILD_DIR)/vector-smoke/fault" \
	  BE_ARGS="+VECTOR_STORE_FAULT +VECTOR_B_DELAY=12 +VECTOR_B_FAULT=80001008"

vector-core-smoke: vector-smoke-data
	@test "$(XLEN)" = 32 || { echo 'RNP core smoke supports RV32 only'; exit 1; }
	$(MAKE) -C "$(RAPTOR_HOME)/sim/tb" verilator-build RAPT_CONFIG=$(VECTOR_RAPT_CONFIG) \
	  DEFINES="$(VECTOR_DEFINES) RAPT_ASSERT_EN" VL_MDIR="$(BUILD_DIR)/vector-core/vl"
	"$(BUILD_DIR)/vector-core/vl/rapt_tb_top" +IMG="$(BUILD_DIR)/vector-smoke/core.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 \
	  +VECTOR_SMOKE +VECTOR_HOLD

# Compile a real RVV intrinsic program into the existing full-core harness.

VECTOR_RAPT_CONFIG ?= $(CONFIG)
VECTOR_DEFINES ?=

.PHONY: vector-axi-build
vector-axi-build:
	$(MAKE) -C "$(RAPTOR_HOME)/sim/tb" verilator-build RAPT_CONFIG=$(VECTOR_RAPT_CONFIG) \
	  TOP=tb_vector_axi \
	  DEFINES="$(VECTOR_DEFINES) RAPT_ASSERT_EN $(if $(filter 64,$(XLEN)),RAPT_RV64,)" \
	  VL_MDIR="$(BUILD_DIR)/vector-axi$(XLEN)/vl" VERILATOR_JOBS=$(VERILATOR_JOBS)

RISCV_CC ?= riscv64-unknown-elf-gcc
RISCV_OBJCOPY ?= riscv64-unknown-elf-objcopy
VECTOR_ABI := $(if $(filter 64,$(XLEN)),lp64d,ilp32d)
VECTOR_NPC ?= $(RAPTOR_HOME)/sim/build/$(CONFIG)/riscv$(XLEN)-npc-sim
VECTOR_REFERENCE ?= $(NEMU_HOME)/build/ref/riscv$(XLEN)_ref_defconfig/riscv$(XLEN)-nemu-interpreter-so

.PHONY: vector-catalog-diff
vector-catalog-diff: vector-smoke-data
	python3 vector_programs.py catalog --output "$(BUILD_DIR)/vector-smoke/catalog.S" \
	  --success-code 0
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/catalog.S" \
	  -o "$(BUILD_DIR)/vector-smoke/catalog.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/catalog.elf" \
	  "$(BUILD_DIR)/vector-smoke/catalog.bin"
	@test -x "$(VECTOR_NPC)" && test -f "$(VECTOR_REFERENCE)" || \
	  { echo 'Build NPC/NEMU first or set VECTOR_NPC and VECTOR_REFERENCE'; exit 1; }
	@set -e -o pipefail; "$(VECTOR_NPC)" -b -n --no-lightsss -t 600 \
	  -d "$(abspath $(VECTOR_REFERENCE))" -r "$(BUILD_DIR)/vector-smoke/boot.bin" \
	  "$(BUILD_DIR)/vector-smoke/catalog.bin" | tee "$(BUILD_DIR)/vector-smoke/catalog.log"; \
	  grep -q 'HIT GOOD TRAP' "$(BUILD_DIR)/vector-smoke/catalog.log"

PROFILE_VECTOR_DEFINES := RAPT_ZVBB RAPT_ZVFHMIN RAPT_ZVKT
PROFILE_PROGRAMS ?= profile
.PHONY: vector-profile-smoke rva23u64-smoke
vector-profile-smoke: VECTOR_DEFINES += $(PROFILE_VECTOR_DEFINES)
vector-profile-smoke: vector-smoke-data vector-axi-build
	@set -e; for payload in $(PROFILE_PROGRAMS); do \
	  base="$(BUILD_DIR)/vector-smoke/$$payload"; \
	  python3 vector_programs.py "$$payload" --output "$$base.S" --xlen $(XLEN); \
	  $(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	    -Wl,-Ttext=0x80000000,-e,_start "$$base.S" -o "$$base.elf"; \
	  $(RISCV_OBJCOPY) -O binary -j .text "$$base.elf" "$$base.bin"; \
	  args=(); if [[ $$payload == profile-system ]]; then args+=(+RVA23_WRS +VECTOR_PROBE); fi; \
	  "$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" +IMG="$$base.bin" \
	    +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=2500000 "$${args[@]}"; \
	done

rva23u64-smoke:
	+$(MAKE) vector-profile-smoke XLEN=64 PROFILE_PROGRAMS='profile zfa profile-system' \
	  VECTOR_DEFINES='$(VECTOR_DEFINES)'

RISCV_LINUX_CC ?= riscv64-linux-gnu-gcc
RVA23_PROBE_SOURCES := $(addprefix $(RAPTOR_HOME)/app/tests/linux/,nemu_rva23.c nemu_rva23_start.S)
.PHONY: rva23u64-linux-probe rva23s64-linux-probe
rva23u64-linux-probe: $(BUILD_DIR)/rva23-check
rva23s64-linux-probe: $(BUILD_DIR)/rva23s64-check

$(BUILD_DIR)/rva23-check: $(RVA23_PROBE_SOURCES) Makefile
	@mkdir -p "$(dir $@)"
	$(RISCV_LINUX_CC) -nostdlib -static -fno-pie -no-pie -fno-builtin -fno-stack-protector \
	  -fno-tree-vectorize -mno-relax -march=rv64gcv -mabi=lp64d -O2 -Wall -Wextra -Werror \
	  -DRVA23_USER_ONLY $(RVA23_PROBE_SOURCES) -o "$@"

$(BUILD_DIR)/rva23s64-check: $(RVA23_PROBE_SOURCES) Makefile
	@mkdir -p "$(dir $@)"
	$(RISCV_LINUX_CC) -nostdlib -static -fno-pie -no-pie -fno-builtin -fno-stack-protector \
	  -fno-tree-vectorize -mno-relax -march=rv64gcv -mabi=lp64d -O2 -Wall -Wextra -Werror \
	  $(RVA23_PROBE_SOURCES) -o "$@"

.PHONY: vector-disabled-data vector-disabled-smoke
vector-disabled-data: vector-smoke-data
	python3 vector_programs.py disabled --output "$(BUILD_DIR)/vector-smoke/disabled.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000,-e,_start "$(BUILD_DIR)/vector-smoke/disabled.S" \
	  -o "$(BUILD_DIR)/vector-smoke/disabled.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/disabled.elf" \
	  "$(BUILD_DIR)/vector-smoke/disabled.bin"

vector-disabled-smoke: vector-disabled-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/disabled.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 +VECTOR_DISABLED

.PHONY: vector-program-data vector-program-smoke
vector-program-data: vector-smoke-data
	python3 vector_programs.py program --output "$(BUILD_DIR)/vector-smoke/program.c"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -O2 -fno-strict-aliasing -nostdlib -ffreestanding \
	  -nostartfiles -Wl,-Ttext=0x80000000 -Wl,-e,_start \
	  "$(BUILD_DIR)/vector-smoke/program.c" -o "$(BUILD_DIR)/vector-smoke/program.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/program.elf" \
	  "$(BUILD_DIR)/vector-smoke/program.bin"

vector-program-smoke: vector-program-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/program.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 +VECTOR_PROGRAM

# Exercise VS=Off traps, read-only vector CSRs, and trap return.

.PHONY: vector-trap-data vector-trap-smoke
vector-trap-data: vector-smoke-data
	python3 vector_programs.py trap --output "$(BUILD_DIR)/vector-smoke/trap.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/trap.S" \
	  -o "$(BUILD_DIR)/vector-smoke/trap.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/trap.elf" \
	  "$(BUILD_DIR)/vector-smoke/trap.bin"

vector-trap-smoke: vector-trap-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/trap.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 +VECTOR_TRAP

# A one-shot AXI error must preserve the completed prefix, trap at the failed
# vector element, and resume the same instruction after mret.

.PHONY: vector-restart-data vector-restart-smoke
vector-restart-data: vector-smoke-data
	python3 vector_programs.py restart --output "$(BUILD_DIR)/vector-smoke/restart.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/restart.S" \
	  -o "$(BUILD_DIR)/vector-smoke/restart.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/restart.elf" \
	  "$(BUILD_DIR)/vector-smoke/restart.bin"

vector-restart-smoke: vector-restart-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/restart.bin" +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" \
	  +MAX_CYCLES=100000 +VECTOR_RESTART +VECTOR_B_DELAY=12 +VECTOR_B_FAULT=0f001008 \
	  +VECTOR_B_FAULT_ONCE

# Fault the third strided element on a separate cache line, then restart it.

.PHONY: vector-read-restart-data vector-read-restart-smoke
vector-read-restart-data: vector-smoke-data
	python3 vector_programs.py read-restart --output "$(BUILD_DIR)/vector-smoke/read-restart.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/read-restart.S" \
	  -o "$(BUILD_DIR)/vector-smoke/read-restart.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/read-restart.elf" \
	  "$(BUILD_DIR)/vector-smoke/read-restart.bin"

vector-read-restart-smoke: vector-read-restart-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/read-restart.bin" +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" \
	  +MAX_CYCLES=100000 +VECTOR_RESTART +VECTOR_R_FAULT=80001080 +VECTOR_R_FAULT_ONCE

# The same data spans a cache-line boundary in both small configurations.

.PHONY: vector-read-fof-data vector-read-fof-smoke
vector-read-fof-data: vector-smoke-data
	python3 vector_programs.py read-fof --output "$(BUILD_DIR)/vector-smoke/read-fof.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/read-fof.S" \
	  -o "$(BUILD_DIR)/vector-smoke/read-fof.elf"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles -DFIRST_FAULT \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/read-fof.S" \
	  -o "$(BUILD_DIR)/vector-smoke/read-fof-first.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/read-fof.elf" \
	  "$(BUILD_DIR)/vector-smoke/read-fof.bin"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/read-fof-first.elf" \
	  "$(BUILD_DIR)/vector-smoke/read-fof-first.bin"

vector-read-fof-smoke: vector-read-fof-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/read-fof.bin" +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" \
	  +MAX_CYCLES=100000 +VECTOR_R_FAULT=80001040 +VECTOR_R_FAULT_ONCE
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/read-fof-first.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 \
	  +VECTOR_R_FAULT=80001038 +VECTOR_R_FAULT_ONCE

# Exercise an RV32 64-bit element when the second word's write response fails.

.PHONY: vector-wide-restart-data
vector-wide-restart-data: vector-smoke-data
	python3 vector_programs.py wide-restart --output "$(BUILD_DIR)/vector-smoke/wide-restart.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/wide-restart.S" \
	  -o "$(BUILD_DIR)/vector-smoke/wide-restart.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/wide-restart.elf" \
	  "$(BUILD_DIR)/vector-smoke/wide-restart.bin"

# Segment probes must reject MMIO without issuing a side-effecting read.

.PHONY: vector-probe-data vector-probe-smoke
vector-probe-data: vector-smoke-data
	python3 vector_programs.py probe --output "$(BUILD_DIR)/vector-smoke/probe.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/probe.S" \
	  -o "$(BUILD_DIR)/vector-smoke/probe.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/probe.elf" \
	  "$(BUILD_DIR)/vector-smoke/probe.bin"

# Reuse one program for precise device faults, FOF, masking and segment probes.

.PHONY: vector-device-data vector-device-smoke
vector-device-data: vector-smoke-data
	python3 vector_programs.py device --output "$(BUILD_DIR)/vector-smoke/device.S"
	@set -e; for mode in 0 1; do for index in 0 1 2 3; do \
	  name="device-$$mode-$$index"; \
	  $(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	    -DDEVICE_CASE=$$mode -DFAULT_INDEX=$$index -Wl,-Ttext=0x80000000 -Wl,-e,_start \
	    "$(BUILD_DIR)/vector-smoke/device.S" -o "$(BUILD_DIR)/vector-smoke/$$name.elf"; \
	  $(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/$$name.elf" \
	    "$(BUILD_DIR)/vector-smoke/$$name.bin"; \
	done; done
	@set -e; for mode in 2 3 4; do \
	  name="device-$$mode-0"; \
	  index=0; if [ $$mode -eq 4 ]; then index=2; fi; \
	  $(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	    -DDEVICE_CASE=$$mode -DFAULT_INDEX=$$index -Wl,-Ttext=0x80000000 -Wl,-e,_start \
	    "$(BUILD_DIR)/vector-smoke/device.S" -o "$(BUILD_DIR)/vector-smoke/$$name.elf"; \
	  $(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/$$name.elf" \
	    "$(BUILD_DIR)/vector-smoke/$$name.bin"; \
	done

.PHONY: vector-device-board-data
vector-device-board-data: vector-device-data
	@set -e; for mode in 0 1 2 3 4; do \
	  index=0; if [ $$mode -eq 0 ] || [ $$mode -eq 1 ] || [ $$mode -eq 4 ]; then index=2; fi; \
	  name="device-board-$$mode"; \
	  $(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	    -DDEVICE_CASE=$$mode -DFAULT_INDEX=$$index -DNATIVE_DEVICE_BOARD \
	    -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/device.S" \
	    -o "$(BUILD_DIR)/vector-smoke/$$name.elf"; \
	  $(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/$$name.elf" \
	    "$(BUILD_DIR)/vector-smoke/$$name.bin"; \
	done
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -DDEVICE_CASE=0 -DFAULT_INDEX=2 -DNATIVE_DEVICE_BOARD -DNATIVE_DEVICE_NEGATIVE \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/device.S" \
	  -o "$(BUILD_DIR)/vector-smoke/device-board-negative.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/device-board-negative.elf" \
	  "$(BUILD_DIR)/vector-smoke/device-board-negative.bin"

vector-device-smoke: vector-device-data vector-axi-build
	@set -e; ulimit -c 0; \
	  simulator="$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi"; \
	  boot="$(BUILD_DIR)/vector-smoke/boot.bin"; \
	  for response in 2 3; do for mode in 0 1; do for index in 0 1 2 3; do \
	    addr=$$(printf '%08x' $$((0x10000040 + 4 * index))); \
	    err=$$(printf '%04x' $$((1 << index))); \
	    readmask=000f; writemask=000f; writeerr=$$err; \
	    if [ $$mode -eq 1 ]; then \
	      writemask=0000; writeerr=0000; \
	      if [ $$index -ne 0 ]; then readmask=$$(printf '%04x' $$(((1 << index) - 1))); fi; \
	    fi; \
	    echo "RV$(XLEN) device mode=$$mode fault_index=$$index response=$$response"; \
	    "$$simulator" +IMG="$(BUILD_DIR)/vector-smoke/device-$$mode-$$index.bin" \
	      +MROM="$$boot" +MAX_CYCLES=100000 +VECTOR_DEVICE_TEST +VECTOR_B_DELAY=12 \
	      +VECTOR_R_DELAY=7 +VECTOR_FAULT_RESP=$$response \
	      +VECTOR_R_FAULT=$$addr +VECTOR_R_FAULT_ONCE +VECTOR_B_FAULT=$$addr \
	      +VECTOR_B_FAULT_ONCE +VD_READ_MASK=$$readmask +VD_WRITE_MASK=$$writemask \
	      +VD_READ_ERROR_MASK=$$err +VD_WRITE_ERROR_MASK=$$writeerr; \
	  done; done; done; \
	  "$$simulator" +IMG="$(BUILD_DIR)/vector-smoke/device-2-0.bin" +MROM="$$boot" \
	    +MAX_CYCLES=100000 +VECTOR_DEVICE_TEST +VECTOR_R_FAULT=10000044 \
	    +VECTOR_R_FAULT_ONCE +VECTOR_B_FAULT=10000044 +VECTOR_B_FAULT_ONCE \
	    +VD_READ_MASK=0004 +VD_WRITE_MASK=0004; \
	  "$$simulator" +IMG="$(BUILD_DIR)/vector-smoke/device-3-0.bin" +MROM="$$boot" \
	    +MAX_CYCLES=100000 +VECTOR_DEVICE_TEST; \
	  "$$simulator" +IMG="$(BUILD_DIR)/vector-smoke/device-4-0.bin" +MROM="$$boot" \
	    +MAX_CYCLES=100000 +VECTOR_DEVICE_TEST +VECTOR_R_DELAY=7 +VECTOR_B_DELAY=12 \
	    +VECTOR_R_FAULT=10000040 +VECTOR_R_FAULT_AFTER=2 +VECTOR_R_FAULT_ONCE \
	    +VECTOR_B_FAULT=10000040 +VECTOR_B_FAULT_AFTER=2 +VECTOR_B_FAULT_ONCE \
	    +VD_REPEAT=4 +VD_READ_MASK=0001 +VD_WRITE_MASK=0001 \
	    +VD_READ_ERROR_MASK=0001 +VD_WRITE_ERROR_MASK=0001; \
	  if "$$simulator" +IMG="$(BUILD_DIR)/vector-smoke/device-0-2.bin" +MROM="$$boot" \
	    +MAX_CYCLES=100000 +VECTOR_DEVICE_TEST +VECTOR_DEVICE_FAULT_EFFECT \
	    +VECTOR_R_FAULT=10000048 +VECTOR_R_FAULT_ONCE +VECTOR_B_FAULT=10000048 \
	    +VECTOR_B_FAULT_ONCE +VD_READ_MASK=000f +VD_WRITE_MASK=000f \
	    +VD_READ_ERROR_MASK=0004 +VD_WRITE_ERROR_MASK=0004 \
	    >"$(BUILD_DIR)/vector-smoke/device-negative.log" 2>&1; then \
	    echo 'device side-effect negative control unexpectedly passed'; exit 1; \
	  fi; \
	  grep -Eq 'RVV AXI result=|device word .* effects/attempts' \
	    "$(BUILD_DIR)/vector-smoke/device-negative.log"; \
	  echo 'PASS device side-effect negative control'

# RV32 ELEN=64 uses two 32-bit beats per element. Use SRAM so the external
# response describes the individual beat, even when the core has L2.
VECTOR_WIDE_FAULT_BASE := 0x0f001000

.PHONY: vector-wide-fault-data vector-wide-fault-smoke
vector-wide-fault-data: vector-smoke-data
	@test "$(XLEN)" = 32 || { echo 'wide fault test requires RV32'; exit 1; }
	python3 vector_programs.py wide-fault --output "$(BUILD_DIR)/vector-smoke/wide-fault.S"
	@set -e; for write in 0 1; do for index in 0 1; do for half in 0 1; do \
	  name="wide-fault-$$write-$$index-$$half"; \
	  $(RISCV_CC) -march=rv32gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	    -DFAULT_WRITE=$$write -DFAULT_INDEX=$$index -DFAULT_HALF=$$half \
	    -DFAULT_BASE=$(VECTOR_WIDE_FAULT_BASE) \
	    -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/wide-fault.S" \
	    -o "$(BUILD_DIR)/vector-smoke/$$name.elf"; \
	  $(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/$$name.elf" \
	    "$(BUILD_DIR)/vector-smoke/$$name.bin"; \
	done; done; done

vector-wide-fault-smoke: vector-wide-fault-data vector-axi-build
	@set -e; ulimit -c 0; \
	  simulator="$(BUILD_DIR)/vector-axi32/vl/tb_vector_axi"; \
	  boot="$(BUILD_DIR)/vector-smoke/boot.bin"; \
	  for response in 2 3; do for write in 0 1; do for index in 0 1; do for half in 0 1; do \
	    addr=$$(printf '%08x' $$(($(VECTOR_WIDE_FAULT_BASE) + 64 * index + 4 * half))); \
	    name="wide-fault-$$write-$$index-$$half"; \
	    echo "RV32 wide fault write=$$write index=$$index half=$$half response=$$response"; \
	    if [ $$write -eq 1 ]; then \
	      fault="+VECTOR_B_FAULT=$$addr +VECTOR_B_FAULT_ONCE"; \
	    else \
	      fault="+VECTOR_R_FAULT=$$addr +VECTOR_R_FAULT_ONCE"; \
	    fi; \
	    "$$simulator" +IMG="$(BUILD_DIR)/vector-smoke/$$name.bin" +MROM="$$boot" \
	      +MAX_CYCLES=100000 +VECTOR_RESTART +VECTOR_B_DELAY=12 +VECTOR_R_DELAY=7 \
	      +VECTOR_FAULT_RESP=$$response $$fault; \
	  done; done; done; done; \
	  if "$$simulator" +IMG="$(BUILD_DIR)/vector-smoke/wide-fault-0-1-1.bin" \
	    +MROM="$$boot" +MAX_CYCLES=100000 +VECTOR_RESTART \
	    >"$(BUILD_DIR)/vector-smoke/wide-fault-negative.log" 2>&1; then \
	    echo 'wide fault negative control unexpectedly passed'; exit 1; \
	  fi; \
	  grep -Eq 'RVV AXI result=|restart trap count=' \
	    "$(BUILD_DIR)/vector-smoke/wide-fault-negative.log"; \
	  echo 'PASS wide fault negative control'

# Distinct 4 KiB mappings on either side of a real Sv32/Sv39 page fault.

.PHONY: vector-page-data vector-page-smoke
vector-page-data: vector-smoke-data
	python3 vector_programs.py page --output "$(BUILD_DIR)/vector-smoke/page.S"
	@set -e; for mode in 0 1 2 3; do \
	  name="page-$$mode"; \
	  $(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	    -DPAGE_CASE=$$mode -Wl,-Ttext=0x80000000 -Wl,-e,_start \
	    "$(BUILD_DIR)/vector-smoke/page.S" -o "$(BUILD_DIR)/vector-smoke/$$name.elf"; \
	  $(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/$$name.elf" \
	    "$(BUILD_DIR)/vector-smoke/$$name.bin"; \
	  $(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	    -DPAGE_CASE=$$mode -DMAP_SECOND_EARLY -Wl,-Ttext=0x80000000 -Wl,-e,_start \
	    "$(BUILD_DIR)/vector-smoke/page.S" -o "$(BUILD_DIR)/vector-smoke/$$name-negative.elf"; \
	  $(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/$$name-negative.elf" \
	    "$(BUILD_DIR)/vector-smoke/$$name-negative.bin"; \
	done

vector-page-smoke: vector-page-data vector-axi-build
	@set -e; ulimit -c 0; for mode in 0 1 2 3; do \
	  echo "RV$(XLEN) cross-page vector mode=$$mode"; \
	  "$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	    +IMG="$(BUILD_DIR)/vector-smoke/page-$$mode.bin" \
	    +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000; \
	  if "$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	    +IMG="$(BUILD_DIR)/vector-smoke/page-$$mode-negative.bin" \
	    +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 \
	    >"$(BUILD_DIR)/vector-smoke/page-$$mode-negative.log" 2>&1; then \
	    echo "page mode=$$mode negative control unexpectedly passed"; exit 1; \
	  fi; \
	  grep -q 'RVV AXI result=' "$(BUILD_DIR)/vector-smoke/page-$$mode-negative.log"; \
	  echo "PASS page mode=$$mode negative control"; \
	done

vector-probe-smoke: vector-probe-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/probe.bin" +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" \
	  +MAX_CYCLES=100000 +VECTOR_PROBE

# Supervisor-mode vector memory accesses through Sv32/Sv39 superpages.

.PHONY: vector-mmu-data vector-mmu-smoke
vector-mmu-data: vector-smoke-data
	python3 vector_programs.py mmu --output "$(BUILD_DIR)/vector-smoke/mmu.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/mmu.S" \
	  -o "$(BUILD_DIR)/vector-smoke/mmu.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/mmu.elf" \
	  "$(BUILD_DIR)/vector-smoke/mmu.bin"

vector-mmu-smoke: vector-mmu-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/mmu.bin" +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" \
	  +MAX_CYCLES=100000 +VECTOR_MMU

# Indexed and strided accesses, masked loads and undisturbed vector tails.

.PHONY: vector-indexed-data vector-indexed-smoke
vector-indexed-data: vector-smoke-data
	python3 vector_programs.py indexed --output "$(BUILD_DIR)/vector-smoke/indexed.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/indexed.S" \
	  -o "$(BUILD_DIR)/vector-smoke/indexed.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/indexed.elf" \
	  "$(BUILD_DIR)/vector-smoke/indexed.bin"

vector-indexed-smoke: vector-indexed-data vector-axi-build
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/indexed.bin" +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" \
	  +MAX_CYCLES=100000

# Simulate an OS saving and restoring all vector registers and control state.

.PHONY: vector-context-data
vector-context-data: vector-smoke-data
	python3 vector_programs.py context --output "$(BUILD_DIR)/vector-smoke/context.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/context.S" \
	  -o "$(BUILD_DIR)/vector-smoke/context.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/context.elf" \
	  "$(BUILD_DIR)/vector-smoke/context.bin"

# Deliver an external interrupt while an irrevocable vector instruction runs.

.PHONY: vector-interrupt-data
vector-interrupt-data: vector-smoke-data
	python3 vector_programs.py interrupt --output "$(BUILD_DIR)/vector-smoke/interrupt.S"
	$(RISCV_CC) -march=rv$(XLEN)gcv -mabi=$(VECTOR_ABI) -nostdlib -nostartfiles \
	  -Wl,-Ttext=0x80000000 -Wl,-e,_start "$(BUILD_DIR)/vector-smoke/interrupt.S" \
	  -o "$(BUILD_DIR)/vector-smoke/interrupt.elf"
	$(RISCV_OBJCOPY) -O binary -j .text "$(BUILD_DIR)/vector-smoke/interrupt.elf" \
	  "$(BUILD_DIR)/vector-smoke/interrupt.bin"

# One build runs the directed core-integration programs and fault suites.
.PHONY: vector-system-smoke
vector-system-smoke: vector-integration-smoke vector-device-smoke vector-page-smoke \
    vector-read-restart-smoke vector-read-fof-smoke \
    $(if $(filter 32,$(XLEN)),vector-wide-fault-smoke)

.PHONY: vector-integration-smoke
vector-integration-smoke: vector-program-smoke vector-trap-smoke vector-mmu-smoke \
    vector-indexed-smoke vector-probe-smoke vector-restart-smoke \
    vector-context-data vector-interrupt-data \
    $(if $(filter 32,$(XLEN)),vector-wide-restart-data)
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/context.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/interrupt.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 +VECTOR_INTERRUPT
ifeq ($(XLEN),32)
	"$(BUILD_DIR)/vector-axi$(XLEN)/vl/tb_vector_axi" \
	  +IMG="$(BUILD_DIR)/vector-smoke/wide-restart.bin" \
	  +MROM="$(BUILD_DIR)/vector-smoke/boot.bin" +MAX_CYCLES=100000 \
	  +VECTOR_RESTART +VECTOR_B_DELAY=12 +VECTOR_B_FAULT=0f00100c +VECTOR_B_FAULT_ONCE
endif
