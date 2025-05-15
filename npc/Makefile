ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

ifeq ($(wildcard $(YSYX_HOME)/npc/Makefile),)
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

INC_PATH ?= $(abspath ./include) $(abspath ./vsrc/include)

ifeq ($(CONFIG_MODE), "soc")
SOC_HOME  = $(abspath ./../ysyxSoC)
INC_PATH += $(abspath $(SOC_HOME)/perip/uart16550/rtl) $(abspath $(SOC_HOME)/perip/spi/rtl)
VTARGET=ysyxSoCFull
SOC_DEFINE=-DYSYX_SOC
SOC_SOURCE=$(shell find $(abspath $(SOC_HOME)/perip) -name "*.v") \
    $(SOC_HOME)/build/ysyxSoCFull.v
INC_PATH +=	$(abspath ./vsrc/include/ysyxsoc)
else
ifeq ($(CONFIG_wrapBus), y)
VTARGET=wrapSoC
else
VTARGET=ysyxSoC
endif
SOC_SOURCE=
INC_PATH +=	$(abspath ./vsrc/include/npc)
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
	$(shell find $(abspath ./vsrc) -name "*.sv") \
	$(SOC_SOURCE)
CSRCS = $(shell find $(abspath ./csrc) -name "*.c")
CCSRCS = $(shell find $(abspath ./csrc) -name "*.cc" -or -name "*.cpp")

ifeq ($(MROM_IMG),)
MROM_IMG ?= $(NPC_HOME)/csrc/mem/mrom-data/build/mrom-data.bin
endif

$(NPC_HOME)/csrc/mem/mrom-data/build/mrom-data.bin:
	$(MAKE) -C $(NPC_HOME)/csrc/mem/mrom-data

all: $(BIN)

ifeq ($(CONFIG_NVBoard),y) # rules for NVBoard
include $(NVBOARD_HOME)/scripts/nvboard.mk
endif

INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(VTARGET)\"" $(SOC_DEFINE) \
	-DMROM_PATH=$(MROM_IMG)

ifneq (,$(filter sta%,$(MAKECMDGOALS)))
INC_PATH += $(abspath ./vsrc/include/dpic_mock)
else
INC_PATH += $(abspath ./vsrc/include/dpic)
endif

$(BIN): $(VSRCS) $(CCSRCS) $(NVBOARD_ARCHIVE)
	$(call git_commit, "build RTL")
	$(VERILATOR) --trace-fst -cc --exe --build -j $(shell nproc) --debug $(VERILATOR_FLAG) $^ \
		--top-module $(VTARGET) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		$(addprefix -I, $(INC_PATH)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

DIFF_REF_SO = -d $(abspath $(NEMU_HOME)/build/riscv32-nemu-interpreter-so)
IMG ?=
NPC_EXEC := $(BIN) $(FLAGS) $(DIFF_REF_SO) -m $(MROM_IMG) $(IMG)

run: $(BIN) $(MROM_IMG)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(NPC_EXEC)

sim: $(BIN)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@$^

AM_KERNEL = $(YSYX_HOME)/am-kernels

AM_KERNEL:
	git clone https://github.com/kingfish404/am-kernels $(YSYX_HOME)/am-kernels

perf:
	if [ ! -d $(AM_KERNEL) ]; then make AM_KERNEL; fi
	make -s -C $(AM_KERNEL)/benchmarks/microbench/ ARCH=riscv32e-ysyxsoc FLAGS='-b -n' mainargs=test run

YOSYS_OPENSTA = $(YSYX_HOME)/yosys-opensta

YOSYS_OPENSTA:
	git clone https://github.com/Kingfish404/yosys-opensta $(YSYX_HOME)/yosys-opensta
	make -C $(YSYX_HOME)/yosys-opensta init init_opensta

pack:
	mkdir -p $(YSYX_HOME)/npc/build/pack
	cp -r $(VSRCS) $(YSYX_HOME)/npc/build/pack
	cp -r $(abspath ./vsrc/include)/*.svh \
		  $(abspath ./vsrc/include/dpic_mock)/*.svh \
		  $(abspath ./vsrc/include/npc)/*.svh $(YSYX_HOME)/npc/build/pack
	cp scripts/pack.sh $(YSYX_HOME)/npc/build/pack && chmod +x $(YSYX_HOME)/npc/build/pack/pack.sh
	cd $(YSYX_HOME)/npc/build/pack && ./pack.sh

sta:
	echo $(MAKECMDGOALS)
	if [ ! -d $(YSYX_HOME)/yosys-opensta ]; then make YOSYS_OPENSTA; fi
	make -C $(YSYX_HOME)/yosys-opensta sta show \
		DESIGN=ysyx \
		RTL_FILES="$(VSRCS)" \
		VERILOG_INCLUDE_DIRS="$(INC_PATH)"

sta_local:
	make -C $(YSYX_HOME)/yosys-opensta sta_local show \
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