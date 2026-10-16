PREFIX ?= /usr/local
INSTALL_ROOT := $(DESTDIR)$(PREFIX)
INSTALL_NAME := $(NAME)$(SO)

.PHONY: install install-check
install-check:
	@test "$(CONFIG_TARGET_NATIVE_ELF)$(CONFIG_TARGET_SHARE)" = y || \
		{ echo 'install requires a native or shared-library build' >&2; exit 1; }
	@test "$(CONFIG_ITRACE)" != y || \
		{ echo 'install requires CONFIG_ITRACE disabled (Capstone is source-tree relative)' >&2; exit 1; }
	@case "$(PREFIX)" in /*) ;; *) echo 'PREFIX must be absolute' >&2; exit 1;; esac

install: install-check $(BINARY)
	install -d "$(INSTALL_ROOT)/share/nemu/configs" "$(INSTALL_ROOT)/share/doc/nemu"
	install -m 644 .config "$(INSTALL_ROOT)/share/nemu/configs/$(INSTALL_NAME).config"
	install -m 644 "$(NEMU_HOME)/README.md" "$(INSTALL_ROOT)/share/doc/nemu/README.md"
ifeq ($(CONFIG_TARGET_SHARE),y)
	install -d "$(INSTALL_ROOT)/lib/nemu" "$(INSTALL_ROOT)/include/nemu/$(INSTALL_NAME)/generated"
	install -m 755 "$(BINARY)" "$(INSTALL_ROOT)/lib/nemu/$(INSTALL_NAME)"
	install -m 644 $(NEMU_HOME)/include/difftest-*.h $(NEMU_HOME)/include/macro.h \
		"$(INSTALL_ROOT)/include/nemu/$(INSTALL_NAME)/"
	install -m 644 include/generated/autoconf.h "$(INSTALL_ROOT)/include/nemu/$(INSTALL_NAME)/generated/"
else
	install -d "$(INSTALL_ROOT)/bin" "$(INSTALL_ROOT)/libexec/nemu"
	install -m 755 "$(BINARY)" "$(INSTALL_ROOT)/libexec/nemu/$(INSTALL_NAME)"
	install -m 755 "$(NEMU_HOME)/tools/nemu.py" "$(INSTALL_ROOT)/bin/nemu"
endif
