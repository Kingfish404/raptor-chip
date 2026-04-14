SED = sed
LN = ln
ifeq ($(shell uname),Darwin)
  SED = gsed
  LN = gln
else
  SED = sed
  LN = ln
endif

REPO_PATH = repo
ifeq ($(wildcard repo/include/palcommon.h),)
  $(shell mkdir -p $(NAVY_HOME)/fsimg/share/games)
  $(shell git clone --depth=1 git@github.com:NJU-ProjectN/pal-navy.git $(REPO_PATH))
  $(shell $(SED) -i '/#define SDL_strcasecmp strcasecmp/c\#define SDL_strcasecmp strcmp' repo/include/common.h;)
endif

NAME = pal
SRCS = $(shell find $(REPO_PATH)/src/ -name "*.c" -or -name "*.cpp")
INC_PATH = $(REPO_PATH)/include $(NAVY_HOME)/libs/include
LIBS += libminiSDL libfixedptc
include $(NAVY_HOME)/Makefile

install: install-file
init:;

install-file:
	mkdir -p $(REPO_PATH)/data
	echo "OPLSampleRate=11025\nSampleRate=11025\nWindowHeight=200\nWindowWidth=320" > \
		$(REPO_PATH)/data/sdlpal.cfg
	$(LN) -sf -T $(abspath $(REPO_PATH)/data) $(NAVY_HOME)/fsimg/share/games/pal

.PHONY: install-file init
