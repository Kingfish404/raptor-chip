ifeq ($(CONFIG_ITRACE),)
else

ifeq ($(shell uname -s),Linux)
suffix = so.5
else ifeq ($(shell uname -s),Darwin)
suffix = 5.dylib
else
  $(error Unsupported OS)
endif

LIBCAPSTONE = $(YSYX_HOME)/nemu/tools/capstone/repo/libcapstone.$(suffix)
CXXFLAGS += -I $(YSYX_HOME)/nemu/tools/capstone/repo/include
$(YSYX_HOME)/npc/csrc/utils/disasm.cc: $(LIBCAPSTONE)
$(LIBCAPSTONE):
	$(MAKE) -C $(YSYX_HOME)/nemu/tools/capstone
endif