# External platform description; the fetched upstream tree stays unchanged.
PLATFORM = raptor
TOOLCHAIN = raptor-toolchain
SHELL = /bin/bash
PLATFORM_AL_SRCS = $(TOPDIR)mith/al/src/al_single.c $(TOPDIR)mith/al/src/al_smp.c $(TOPDIR)mith/al/src/al_file.c
TH_EXTRA_OBJS = $(CMP_PORT_OBJS)
COPY_DATA = cp -Ru
RUN =
RUN_FLAGS =
CMD_SEP =
