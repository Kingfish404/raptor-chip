OUTPUT_DIR := $(abspath $(O))
ifeq ($(OUTPUT_DIR),$(abspath $(NEMU_HOME)))
$(error O must differ from the NEMU source directory)
endif
ifneq ($(filter reference,$(MAKECMDGOALS)),)
$(error reference already uses private directories; omit O)
endif

.DEFAULT_GOAL := output-build
.PHONY: output-build $(MAKECMDGOALS)

$(filter-out output-build,$(MAKECMDGOALS)): output-build

output-build:
	@mkdir -p "$(OUTPUT_DIR)"
	@for name in src configs; do \
		link="$(OUTPUT_DIR)/$$name"; source="$(NEMU_HOME)/$$name"; \
		if [ -e "$$link" ] || [ -L "$$link" ]; then \
			[ "$$(readlink -f "$$link")" = "$$(readlink -f "$$source")" ] || \
			{ echo "Refusing to replace $$link" >&2; exit 1; }; \
		else ln -s "$$source" "$$link"; fi; \
	done
	@for tool in kconfig fixdep; do \
		mkdir -p "$(OUTPUT_DIR)/tools/$$tool"; \
		for source in "$(NEMU_HOME)/tools/$$tool/"*; do \
			[ "$${source##*/}" = build ] && continue; \
			link="$(OUTPUT_DIR)/tools/$$tool/$${source##*/}"; \
			if [ -e "$$link" ] || [ -L "$$link" ]; then \
				[ "$$(readlink -f "$$link")" = "$$(readlink -f "$$source")" ] || \
				{ echo "Refusing to replace $$link" >&2; exit 1; }; \
			else ln -s "$$source" "$$link"; fi; \
		done; \
	done
	+$(MAKE) -C "$(OUTPUT_DIR)" -f "$(NEMU_HOME)/Makefile" \
		O= BUILD_DIR="$(OUTPUT_DIR)/build" \
		KCONFIG_PATH="$(OUTPUT_DIR)/tools/kconfig" \
		FIXDEP_PATH="$(OUTPUT_DIR)/tools/fixdep" \
		$(if $(MAKECMDGOALS),$(MAKECMDGOALS),app)
