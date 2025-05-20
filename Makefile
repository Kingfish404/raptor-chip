STUID = ysyx_2022111024
STUNAME = 金宇

# DO NOT modify the following code!!!

TRACER = tracer-ysyx
GITFLAGS = -q --author='$(TRACER) <tracer@ysyx.org>' --no-verify --allow-empty

YSYX_HOME = $(shell realpath $(NEMU_HOME)/..)
WORK_BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
WORK_INDEX = $(YSYX_HOME)/.git/index.$(WORK_BRANCH)
TRACER_BRANCH = $(TRACER)

LOCK_DIR = $(YSYX_HOME)/.git/

# prototype: git_soft_checkout(branch)
define git_soft_checkout
	git checkout --detach -q && git reset --soft $(1) -q -- && git checkout $(1) -q --
endef

.clean_index:
	rm -f $(WORK_INDEX)

_default:
	@echo "Please run 'make' under subprojects."

.PHONY: .clean_index _default
