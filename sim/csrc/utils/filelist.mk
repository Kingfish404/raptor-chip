ifeq ($(CONFIG_ITRACE),)
else

ifeq ($(shell uname -s),Linux)
suffix = so.5
else ifeq ($(shell uname -s),Darwin)
suffix = 5.dylib
else
  $(error Unsupported OS)
endif

LIBCAPSTONE = $(RAPTOR_HOME)/nemu/tools/capstone/repo/libcapstone.$(suffix)
CXXFLAGS += -I $(RAPTOR_HOME)/nemu/tools/capstone/repo/include
CXXFLAGS += -DRAPT_CAPSTONE_PATH=$(LIBCAPSTONE)
$(NSIM_HOME)/csrc/utils/disasm.cc: $(LIBCAPSTONE)
$(LIBCAPSTONE):
	$(MAKE) -C $(RAPTOR_HOME)/nemu/tools/capstone
endif
