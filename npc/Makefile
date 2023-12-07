ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

ifeq ($(VERILATOR_ROOT),)
VERILATOR = verilator
else
export VERILATOR_ROOT
VERILATOR = $(VERILATOR_ROOT)/bin/verilator
endif

VTARGET=npc
BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(VTARGET)
INC_PATH ?= $(abspath ./csrc/include) $(abspath ./vsrc/include)
CXXFLAGS = -Wall -Werror
LDFLAGS = -lreadline

FILELIST_MK = $(shell find -L ./csrc -name "filelist.mk")
include $(FILELIST_MK)

$(shell mkdir -p $(BUILD_DIR))

VSRCS = $(shell find $(abspath ./vsrc) -name "*.v")
CSRCS = $(shell find $(abspath ./csrc) -name "*.c" -or -name "*.cc" -or -name "*.cpp")

all: $(BIN)

# rules for NVBoard
include $(NVBOARD_HOME)/scripts/nvboard.mk
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(VTARGET)\"" 

$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)
	$(call git_commit, "build RTL")
	$(VERILATOR) --trace -cc --exe --build -j $(shell nproc) $^ \
		--top-module top \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		$(addprefix -I, $(INC_PATH)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

IMG ?=
NPC_EXEC := $(BIN) $(ARGS) $(IMG)

run: $(BIN)
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
