SED = sed

REPO_PATH = repo
ifeq ($(wildcard repo/include/palcommon.h),)
$(shell mkdir -p $(NAVY_HOME)/fsimg/share/games)
$(shell git clone --depth=1 git@github.com:NJU-ProjectN/pal-navy.git $(REPO_PATH))
$(shell $(SED) -i.bak 's/^#define SDL_strcasecmp strcasecmp$$/#define SDL_strcasecmp strcmp/' repo/include/common.h && rm -f repo/include/common.h.bak)
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
	printf '%s\n' \
		'OPLSampleRate=11025' \
		'SampleRate=11025' \
		'WindowHeight=200' \
		'WindowWidth=320' > $(REPO_PATH)/data/sdlpal.cfg
	ln -sfn $(abspath $(REPO_PATH)/data) $(NAVY_HOME)/fsimg/share/games/pal

.PHONY: install-file init
