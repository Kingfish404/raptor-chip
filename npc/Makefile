ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

ifeq ($(VERILATOR_ROOT),)
VERILATOR = verilator
else
export VERILATOR_ROOT
VERILATOR = $(VERILATOR_ROOT)/bin/verilator
endif

-include ./include/config/auto.conf
-include ./include/config/auto.conf.cmd

VTARGET=ysyxSoCFull
BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(VTARGET)
SOC_HOME = $(abspath ./../ysyxSOC)
INC_PATH ?= $(abspath ./include) $(abspath ./vsrc/include) \
	$(abspath $(SOC_HOME)/perip/uart16550/rtl) $(abspath $(SOC_HOME)/perip/spi/rtl)
VERILATOR_FLAG =--prof-c --prof-cfuncs --prof-exec --timescale "1ns/1ns" --no-timing
CXXFLAGS = -Wall -Werror $(call remove_quote,$(CONFIG_CC_OPT))
LDFLAGS = -lreadline -ldl

FILELIST_MK = $(shell find -L ./csrc -name "filelist.mk")
include $(FILELIST_MK)

$(shell mkdir -p $(BUILD_DIR))

VSRCS = $(shell find $(abspath ./vsrc) -name "*.v") \
	$(shell find $(abspath $(SOC_HOME)/perip) -name "*.v") \
	$(SOC_HOME)/generated/ysyxSoCFull.v
CSRCS = $(shell find $(abspath ./csrc) -name "*.c" -or -name "*.cc" -or -name "*.cpp")

all: $(BIN)

# rules for NVBoard
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(VTARGET)\"" 

$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)
	$(call git_commit, "build RTL")
	$(VERILATOR) --trace -cc --exe --build -j $(shell nproc) --debug $(VERILATOR_FLAG) $^ \
		--top-module $(VTARGET) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		$(addprefix -I, $(INC_PATH)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

DIFF_REF_SO = -d $(abspath $(NEMU_HOME)/build/riscv32-nemu-interpreter-so)
IMG ?=
NPC_EXEC := $(BIN) $(NPCFLAGS) $(DIFF_REF_SO) $(IMG)

run: $(BIN)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(NPC_EXEC)

sim: $(BIN)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@$^

test:
	echo $(VTARGET)

include ../Makefile

maintainer-copy::
clean mostlyclean distclean maintainer-clean::
	-rm -rf obj_dir *.log *.dmp *.vpd core $(BUILD_DIR)

include ./scripts/config.mk

all: $(BINARY)
.DEFAULT_GOAL = all