AM_SRCS := native/trm.c \
           native/ioe.c \
           native/cte.c \
           native/trap.S \
           native/vme.c \
           native/mpe.c \
           native/platform.c \
           native/ioe/input.c \
           native/ioe/timer.c \
           native/ioe/gpu.c \
           native/ioe/audio.c \
           native/ioe/disk.c \

CFLAGS  += -fpie $(shell sdl2-config --cflags)
ASFLAGS += -fpie -pie
comma = ,
LDFLAGS_CXX = $(addprefix -Wl$(comma), $(LDFLAGS))

FFLAGS := -Wl,--whole-archive
SFLAGS := -Wl,-no-whole-archive
ifeq ($(shell uname), Darwin)
AS 	   := gcc
CC     := gcc
CXX     := g++
LDFLAGS  := $(shell sdl2-config --libs)

FFLAGS  := -W
SFLAGS := ""
ifeq ($(wildcard $(shell which $(CC))),)
  $(info #  $(CC) not found; Please install $(CC) via Homebrew `brew install gcc@13`)
endif
endif

image:
	@echo + LD "->" $(IMAGE_REL)
	$(CXX) -pie -o $(IMAGE) $(FFLAGS) $(LINKAGE) $(SFLAGS) $(LDFLAGS_CXX)

run: image
	$(IMAGE)

gdb: image
	gdb -ex "handle SIGUSR1 SIGUSR2 SIGSEGV noprint nostop" $(IMAGE)
