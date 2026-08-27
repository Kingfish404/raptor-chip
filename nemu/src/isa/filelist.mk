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

INC_PATH += $(NEMU_HOME)/src/isa/$(GUEST_ISA)/include
DIRS-y += src/isa/$(GUEST_ISA)

ifeq ($(CONFIG_ISA_riscv),y)
SOFTFLOAT_ROOT := $(NEMU_HOME)/tools/spike-diff/repo
SOFTFLOAT_HEADER := $(SOFTFLOAT_ROOT)/softfloat/softfloat.h
SOFTFLOAT_ARCHIVE := $(SOFTFLOAT_ROOT)/build/libsoftfloat.a
INC_PATH += $(SOFTFLOAT_ROOT)/softfloat
GENERATED_HEADERS += $(SOFTFLOAT_HEADER)
ARCHIVES += $(SOFTFLOAT_ARCHIVE)

$(SOFTFLOAT_HEADER):
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff repo/softfloat/softfloat.h

$(SOFTFLOAT_ARCHIVE): $(SOFTFLOAT_HEADER)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff repo/build/libsoftfloat.a
endif
