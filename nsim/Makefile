ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

ifeq ($(wildcard $(YSYX_HOME)/nsim/Makefile),)
  $(error YSYX_HOME=$(YSYX_HOME) is not a YSYX repo)
endif

ifeq ($(VERILATOR_ROOT),)
VERILATOR = verilator
else
export VERILATOR_ROOT
VERILATOR = $(VERILATOR_ROOT)/bin/verilator
endif

-include ./include/config/auto.conf
-include ./include/config/auto.conf.cmd

VSRC_PATH ?= $(abspath ../rtl_sv)

INC_PATH ?= $(abspath ./include) $(abspath $(VSRC_PATH)/include)

ifeq ($(CONFIG_MODE), "soc")
SOC_HOME  = $(abspath $(YSYX_HOME)/third_party/kingfish404/ysyxSoC)
INC_PATH += $(abspath $(SOC_HOME)/perip/uart16550/rtl) $(abspath $(SOC_HOME)/perip/spi/rtl)
VTARGET=ysyxSoCFull
SOC_DEFINE=-DYSYX_SOC
SOC_SOURCE=$(shell find $(abspath $(SOC_HOME)/perip) -name "*.v") \
    $(SOC_HOME)/build/ysyxSoCFull.v
INC_PATH +=	$(abspath $(VSRC_PATH)/include/ysyxsoc)
else
ifeq ($(CONFIG_wrapBus), y)
VTARGET=wrapSoC
else
VTARGET=ysyxSoC
endif
SOC_SOURCE=
INC_PATH +=	$(abspath $(VSRC_PATH)/include/npc)
endif
BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(VTARGET)
VERILATOR_FLAG =--prof-c --prof-cfuncs --prof-exec \
	--autoflush --timescale "1ns/1ns" --no-timing # -Wall -Wno-DECLFILENAME -Wno-UNUSED
CXXFLAGS = -Wall -Werror \
	-Wno-bool-operation -Wno-implicit-fallthrough -Wno-macro-redefined \
	-Wno-parentheses-equality -Wno-unused-variable \
	$(call remove_quote,$(CONFIG_CC_OPT))
LDFLAGS = -lreadline -ldl

FILELIST_MK = $(shell find -L ./csrc -name "filelist.mk")
include $(FILELIST_MK)

$(shell mkdir -p $(BUILD_DIR))

VSRCS = \
	$(shell find $(VSRC_PATH) -name "*.sv") \
	$(SOC_SOURCE)
VHSRCS = $(shell find $(VSRC_PATH) -name "*.svh")
CSRCS = $(shell find $(abspath ./csrc) -name "*.c")
CCSRCS = $(shell find $(abspath ./csrc) -name "*.cc" -or -name "*.cpp")
CHSRCS = $(shell find $(abspath ./csrc) -name "*.h" -or -name "*.hpp")

ifeq ($(MROM_IMG),)
MROM_IMG ?= $(NSIM_HOME)/csrc/mem/mrom-data/build/mrom-data.bin
endif

$(NSIM_HOME)/csrc/mem/mrom-data/build/mrom-data.bin:
	$(MAKE) -C $(NSIM_HOME)/csrc/mem/mrom-data

all: $(BIN)

ifeq ($(CONFIG_NVBoard),y) # rules for NVBoard
include $(NVBOARD_HOME)/scripts/nvboard.mk
endif

INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(VTARGET)\"" $(SOC_DEFINE) \
	-DMROM_PATH=$(MROM_IMG)

ifneq (,$(filter sta%,$(MAKECMDGOALS)))
INC_PATH += $(abspath $(VSRC_PATH)/include/dpic_mock)
else
INC_PATH += $(abspath $(VSRC_PATH)/include/dpic)
endif

$(BIN): $(VSRCS) $(VHSRCS) $(CCSRCS) $(CHSRCS) $(NVBOARD_ARCHIVE)
	$(VERILATOR) --trace-fst -cc --exe --build -j $(shell nproc) --debug $(VERILATOR_FLAG) $^ \
		--top-module $(VTARGET) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		$(addprefix -I, $(INC_PATH)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

DIFF_REF_SO = -d $(abspath $(NEMU_HOME)/build/riscv32-nemu-interpreter-so)
IMG ?=
NPC_EXEC := $(BIN) $(FLAGS) $(DIFF_REF_SO) -m $(MROM_IMG) $(IMG)

verilog:
	make -C ssrc verilog

run: $(BIN) $(MROM_IMG)
	$(NPC_EXEC)

sim: $(BIN)
	@$^

AM_KERNEL = $(YSYX_HOME)/third_party/kingfish404/am-kernels

AM_KERNEL:
	mkdir -p $(abspath $(AM_KERNEL))
	git clone https://github.com/kingfish404/am-kernels $(YSYX_HOME)/am-kernels

perf:
	if [ ! -d $(AM_KERNEL) ]; then make AM_KERNEL; fi
	make -s -C $(AM_KERNEL)/benchmarks/microbench/ ARCH=riscv32-ysyxsoc FLAGS='-b -n' mainargs=test run

YOSYS_OPENSTA = $(YSYX_HOME)/third_party/yosys-opensta

YOSYS_OPENSTA:
	git clone https://github.com/Kingfish404/yosys-opensta $(YOSYS_OPENSTA)
	make -C $(YOSYS_OPENSTA) init init_opensta

pack: $(VSRCS)
	mkdir -p $(YSYX_HOME)/npc/build/pack
	cp -r $(VSRCS) $(YSYX_HOME)/npc/build/pack
	cp -r $(abspath $(VSRC_PATH)/include)/*.svh \
		  $(abspath $(VSRC_PATH)/include/dpic_mock)/*.svh \
		  $(abspath $(VSRC_PATH)/include/npc)/*.svh $(YSYX_HOME)/npc/build/pack
	cp scripts/pack.sh $(YSYX_HOME)/npc/build/pack && chmod +x $(YSYX_HOME)/npc/build/pack/pack.sh
	cd $(YSYX_HOME)/npc/build/pack && ./pack.sh

sta:
	echo $(MAKECMDGOALS)
	if [ ! -d $(YOSYS_OPENSTA) ]; then make YOSYS_OPENSTA; fi
	make -C $(YOSYS_OPENSTA) sta show \
		DESIGN=ysyx \
		RTL_FILES="$(VSRCS)" \
		VERILOG_INCLUDE_DIRS="$(INC_PATH)"

sta_local:
	make -C $(YOSYS_OPENSTA) sta_local show \
	DESIGN=ysyx \
	RTL_FILES="$(VSRCS)" \
	VERILOG_INCLUDE_DIRS="$(INC_PATH)"

lint:
	$(VERILATOR) --lint-only -Wall $(VSRCS) $(INCFLAGS) --top-module $(VTARGET)

test:
	echo $(CXXFLAGS)

include ../Makefile

maintainer-copy::
clean mostlyclean distclean maintainer-clean::
	-rm -rf obj_dir *.log *.dmp *.vpd core $(BUILD_DIR)

include ./scripts/config.mk

all: $(BINARY)
.DEFAULT_GOAL = all