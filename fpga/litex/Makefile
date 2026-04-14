ifeq ($(wildcard $(YSYX_HOME)/nsim/Makefile),)
  $(error YSYX_HOME=$(YSYX_HOME) is not a YSYX repo)
endif

LITEX_PATH = $(YSYX_HOME)/third_party/enjoy-digital/litex

help: ## Show this help message
	@echo "Usage: make <target> [VAR=value ...]"
	@awk '\
		BEGIN { state=0; pending=""; first_target=1 } \
		/^# =+$$/ { \
			if (state==0) state=1; \
			else if (state==2) { pending=section; state=0 } \
			else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		{ if (state==1) state=0 } \
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first_target) printf "\nTargets:\n"; \
			first_target=0; \
			target=$$0; sub(/:.*/, "", target); \
			desc=$$0; sub(/.*## /, "", desc); \
			printf "  %-20s %s\n", target, desc }' $(MAKEFILE_LIST)

$(LITEX_PATH)/README.md:
	$(MAKE) install

install:
	mkdir -p $(YSYX_HOME)/third_party/enjoy-digital/
	if [ ! -d $(LITEX_PATH) ]; then git clone https://github.com/enjoy-digital/litex/ $(LITEX_PATH); fi
	cd $(LITEX_PATH) && python3 ./litex_setup.py --init --install
	$(MAKE) link

link: ## Link ysyx CPU core into LiteX
	ln -sf $(abspath cores/cpu/ysyx) $(LITEX_PATH)/litex/soc/cores/cpu/
	ln -sf $(abspath software/coremark) $(LITEX_PATH)/litex/soc/software/

init: $(LITEX_PATH)/README.md ## Init LiteX
	cd $(LITEX_PATH) && python3 ./litex_setup.py --init

update: $(LITEX_PATH)/README.md ## Update LiteX dependencies
	cd $(LITEX_PATH) && python3 ./litex_setup.py --update

# ==============================================================================
# Simulation (standard variant)
# ==============================================================================

build: ## Build LiteX SoC (no gateware compile)
	cd $(LITEX_PATH) && \
	python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
		--integrated-main-ram-size 0x10000 \
		--no-compile-gateware

run: $(LITEX_PATH)/README.md ## Run LiteX simulation
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--integrated-main-ram-size 0x10000

run_ni: $(LITEX_PATH)/README.md ## Run LiteX simulation (non-interactive)
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--non-interactive \
			--integrated-main-ram-size 0x10000

# ==============================================================================
# Linux boot (linux variant)
# ==============================================================================

LINUX_SIM_FLAGS = --cpu-type=ysyx --cpu-variant=linux \
	--integrated-main-ram-size=0x04000000 \
	--timer-uptime

# Pre-built OpenSBI+Linux payload (managed by linux/Makefile).
LINUX_HOME     := $(YSYX_HOME)/linux
LINUX_PAYLOAD  ?= $(shell $(MAKE) -s -C $(LINUX_HOME) print-rv32-payload 2>/dev/null || \
	echo $(LINUX_HOME)/build/linux-riscv-rv32-v6.18.15/fw_payload.bin)

linux_build: $(LITEX_PATH)/README.md ## Build LiteX SoC for Linux (no gateware)
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py $(LINUX_SIM_FLAGS) \
			--no-compile-gateware

LITEX_SIM_DTS := $(LITEX_PATH)/build/sim/litex_sim.dts
LITEX_SIM_DTB := $(LITEX_PATH)/build/sim/litex_sim.dtb

linux_dts: linux_build ## Generate Linux device tree from SoC config
	cd $(LITEX_PATH) && \
		python3 -c " \
		from litex.tools.litex_json2dts_linux import *; \
		import json; \
		d = json.load(open('build/sim/csr.json')); \
		open('build/sim/litex_sim.dts','w').write(generate_dts(d))"
	@# Patch DTS for runtime FDT boot:
	@#  - Use SBI earlycon (works regardless of kernel liteuart driver)
	@#  - Remove initrd hints (kernel has built-in initramfs)
	sed -i '' \
		's|earlycon=liteuart,[^ "]*|earlycon=sbi|' \
		$(LITEX_SIM_DTS)
	sed -i '' \
		'/linux,initrd-start/d; /linux,initrd-end/d' \
		$(LITEX_SIM_DTS)
	cd $(LITEX_PATH) && \
		dtc -I dts -O dtb -o build/sim/litex_sim.dtb build/sim/litex_sim.dts
	@echo "DTB written to $(LITEX_SIM_DTB)"

# ------------------------------------------------------------------------------
# Runtime FDT combined images
# ------------------------------------------------------------------------------
# boot-helper.S passes DTB address (MAIN_RAM_BASE + DTB_OFFSET) in a1 to
# OpenSBI.  The combined image recipe pads the payload to DTB_OFFSET bytes
# then appends the DTB.  36 MiB accommodates both the ~4 MiB standalone
# OpenSBI test payload and the ~34 MiB pre-built OpenSBI+Linux payload.
DTB_OFFSET := 0x02400000

# Local OpenSBI payload (built from linux/opensbi source).
OPENSBI_PAYLOAD   ?= $(LINUX_HOME)/opensbi/build/platform/generic/firmware/fw_payload.bin
OPENSBI_COMBINED  := $(LITEX_PATH)/build/sim/opensbi_combined.bin
LINUX_COMBINED    := $(LITEX_PATH)/build/sim/linux_combined.bin

# Helper: create combined image  $(call CREATE_COMBINED,<payload>,<output>)
define CREATE_COMBINED
	python3 -c "\
	payload = open('$(1)', 'rb').read(); \
	dtb = open('$(LITEX_SIM_DTB)', 'rb').read(); \
	offset = $(DTB_OFFSET); \
	assert len(payload) <= offset, \
	    f'payload ({len(payload):#x} B) exceeds DTB offset ({offset:#x} B)'; \
	open('$(2)', 'wb').write(payload.ljust(offset, b'\x00') + dtb)"
endef

opensbi_build: ## Rebuild standalone OpenSBI (no FDT baked in)
	$(MAKE) -C $(LINUX_HOME) opensbi

$(OPENSBI_COMBINED): $(OPENSBI_PAYLOAD) $(LITEX_SIM_DTB)
	@echo "Creating OpenSBI combined image: payload + DTB @ offset $(DTB_OFFSET)"
	$(call CREATE_COMBINED,$(OPENSBI_PAYLOAD),$(OPENSBI_COMBINED))
	@echo "  -> $(OPENSBI_COMBINED) ($$(stat -f%z '$(OPENSBI_COMBINED)') bytes)"

opensbi_sim: opensbi_build linux_dts $(OPENSBI_COMBINED) ## Run LiteX sim with OpenSBI + runtime FDT
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py $(LINUX_SIM_FLAGS) \
			--ram-init=$(OPENSBI_COMBINED)

opensbi_sim_ni: opensbi_build linux_dts $(OPENSBI_COMBINED) ## Run LiteX OpenSBI sim (non-interactive)
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py $(LINUX_SIM_FLAGS) \
			--non-interactive \
			--ram-init=$(OPENSBI_COMBINED)

# ------------------------------------------------------------------------------
# Linux boot
# ------------------------------------------------------------------------------

$(LINUX_PAYLOAD):
	$(MAKE) -C $(LINUX_HOME) download-rv32

$(LINUX_COMBINED): $(LINUX_PAYLOAD) $(LITEX_SIM_DTB)
	@echo "Creating Linux combined image: payload + DTB @ offset $(DTB_OFFSET)"
	$(call CREATE_COMBINED,$(LINUX_PAYLOAD),$(LINUX_COMBINED))
	@echo "  -> $(LINUX_COMBINED) ($$(stat -f%z '$(LINUX_COMBINED)') bytes)"

linux_sim: linux_dts $(LINUX_COMBINED) ## Run LiteX Linux simulation (Verilator)
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py $(LINUX_SIM_FLAGS) \
			--ram-init=$(LINUX_COMBINED)

linux_sim_ni: linux_dts $(LINUX_COMBINED) ## Run LiteX Linux sim (non-interactive)
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py $(LINUX_SIM_FLAGS) \
			--non-interactive \
			--ram-init=$(LINUX_COMBINED)

# ==============================================================================
# Device Tree
# ==============================================================================

linux_btb: build ## Generate Linux device tree (legacy alias)
	litex_json2dts_linux $(LITEX_PATH)/build/sim/csr.json > $(LITEX_PATH)/build/ysyx.dts

# ==============================================================================
# Demos / Benchmarks
# ==============================================================================

liftoff: $(LITEX_PATH)/README.md ## Run LiteX with demo binary
	cd $(LITEX_PATH) && \
			python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--ram-init=demo.bin --integrated-main-ram-size=0x10000

LITEX_COREMARK_FLAGS = --cpu-type=ysyx --integrated-main-ram-size=0x10000 --bios-format=double

# Workaround: litex minimal picolibc build is missing *tox_engine.c needed by
# %a (hex-float) code path in vfprintf.  Patch before build, restore after.
# Remove once https://github.com/enjoy-digital/litex/commit/00639b68d is fixed upstream.
LITEX_LIBC_MK = $(LITEX_PATH)/litex/soc/software/libc/Makefile
define _litex_libc_patch
	python3 -c "p='$(LITEX_LIBC_MK)';t=open(p).read();\
	t=t.replace('dtoa_engine.c \\\\\\n','dtoa_engine.c \\\\\\n\t\$$(PICOLIBC_SRC_DIR)/libc/stdio/dtox_engine.c \\\\\\n') if 'dtox_engine' not in t else t;\
	t=t.replace('ftoa_engine.c\\n','ftoa_engine.c \\\\\\n\t\$$(PICOLIBC_SRC_DIR)/libc/stdio/ftox_engine.c\\n') if 'ftox_engine' not in t else t;\
	open(p,'w').write(t)"
endef
define _litex_libc_restore
	cd $(LITEX_PATH) && git checkout -- litex/soc/software/libc/Makefile 2>/dev/null || true
endef

coremark: $(LITEX_PATH)/README.md ## Run CoreMark on LiteX
	$(call _litex_libc_patch)
	@trap '$(call _litex_libc_restore)' EXIT; \
	cd $(LITEX_PATH) \
		&& python3 ./litex/tools/litex_sim.py $(LITEX_COREMARK_FLAGS) \
			--no-compile-gateware \
		&& python3 ./litex/soc/software/coremark/coremark.py \
			--build-path=build/sim/ \
		&& python3 ./litex/tools/litex_sim.py $(LITEX_COREMARK_FLAGS) \
			--non-interactive \
			--ram-init=coremark.bin

coremark_wave: $(LITEX_PATH)/README.md ## Run CoreMark on LiteX with waveform
	$(call _litex_libc_patch)
	@trap '$(call _litex_libc_restore)' EXIT; \
	cd $(LITEX_PATH) \
		&& python3 ./litex/tools/litex_sim.py $(LITEX_COREMARK_FLAGS) \
			--no-compile-gateware \
		&& python3 ./litex/soc/software/coremark/coremark.py \
			--build-path=build/sim/ \
		&& python3 ./litex/tools/litex_sim.py $(LITEX_COREMARK_FLAGS) \
			--non-interactive --gtkwave-savefile --trace --trace-fst \
			--ram-init=coremark.bin
