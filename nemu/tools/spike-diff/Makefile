#***************************************************************************************
# Copyright (c) 2014-2022 Zihao Yu, Nanjing University
#
# NEMU is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#          http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
#
# See the Mulan PSL v2 for more details.
#**************************************************************************************/

REPO_PATH = repo
REPO_MARKER = $(REPO_PATH)/softfloat/softfloat.h

$(REPO_PATH)/.git:
	git clone --depth=1 https://github.com/riscv-software-src/riscv-isa-sim $(REPO_PATH)

# Recent Spike headers link into the berkeley-softfloat-3 submodule. Run this
# even for an existing checkout: softfloat.h alone does not prove that its
# includes exist (for example after an interrupted bootstrap).
.PHONY: prepare-repo
prepare-repo: $(REPO_PATH)/.git
	git -C $(REPO_PATH) submodule update --init --recursive
	bash ./patch.sh

$(REPO_MARKER): | prepare-repo

REPO_BUILD_PATH = $(REPO_PATH)/build
REPO_MAKEFILE = $(REPO_BUILD_PATH)/Makefile
NPROC := $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
SUBMAKE_JOBS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(NPROC))
$(REPO_MAKEFILE): $(REPO_MARKER)
	@mkdir -p $(@D)
	cd $(@D) && $(abspath $(REPO_PATH))/configure
	sed -i.bak -e 's/-g -O2/-O2/' $@ && rm -f $@.bak

$(REPO_BUILD_PATH)/libsoftfloat.a: $(REPO_MAKEFILE)
	$(MAKE) -C $(REPO_BUILD_PATH) $(SUBMAKE_JOBS) libsoftfloat.a

SPIKE = $(REPO_BUILD_PATH)/spike
$(SPIKE): $(REPO_MAKEFILE)
	$(MAKE) -C $(^D) $(SUBMAKE_JOBS) \
		CFLAGS="-fvisibility=hidden" CXXFLAGS="-fvisibility=hidden"

BUILD_DIR = ./build
$(shell mkdir -p $(BUILD_DIR))

inc_dependencies = riscv disasm customext fdt softfloat spike_main spike_dasm build
NEMU_CONFIG_DIR ?= $(NEMU_HOME)/include
INC_PATH  = -I$(NEMU_CONFIG_DIR) -I$(REPO_PATH) $(addprefix -I$(REPO_PATH)/, $(inc_dependencies))
INC_PATH += -iquote $(REPO_PATH)/fesvr
INC_PATH += -I$(NEMU_HOME)/include
INC_PATH += -I$(NEMU_HOME)/src/isa/$(GUEST_ISA)/include
lib_dependencies = libspike_main.a libriscv.a libdisasm.a libsoftfloat.a libfesvr.a libfdt.a
INC_LIBS  = $(addprefix $(REPO_PATH)/build/, $(lib_dependencies))

# Suffix the .so with 32/64 to match NEMU's binary naming, so RV32 and RV64
# difftest references coexist and switching CONFIG_RV64 picks the right one.
NAME = $(if $(filter riscv,$(GUEST_ISA)),$(GUEST_ISA)$(if $(CONFIG_RV64),64,32),$(GUEST_ISA))-spike-so
BINARY = $(BUILD_DIR)/$(NAME)
SRCS = difftest.cc

$(BINARY): $(SPIKE) $(SRCS) $(NEMU_CONFIG_DIR)/generated/autoconf.h \
           $(NEMU_HOME)/src/isa/riscv/include/riscv-state.h
	g++ -std=c++20 -O2 -shared -fPIC -fvisibility=hidden $(INC_PATH) $(SRCS) $(INC_LIBS) -o $@

clean:
	rm -rf $(BUILD_DIR)

all: $(BINARY)
.DEFAULT_GOAL = all

.PHONY: all clean $(SPIKE)
