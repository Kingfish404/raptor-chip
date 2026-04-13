# ============================================================================
# app/pk/Makefile: Build riscv-pk (proxy kernel + BBL) for NPC
# ============================================================================

APP_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
PK_HOME  := $(dir $(lastword $(MAKEFILE_LIST)))
include $(APP_HOME)/common.mk

ARGS ?= -b ## NPC simulator args (-b: batch, -n: no wave)

# ---- Directories ----
PK_SRC_DIR := $(YSYX_HOME)/third_party/riscv-software-src/riscv-pk
PK_STAGING := $(APP_HOME)/build/pk-staging-rv$(XLEN)
PK_BUILD   := $(APP_HOME)/build/pk-build-rv$(XLEN)
BBL_BUILD  := $(APP_HOME)/build/bbl-build-rv$(XLEN)

# ---- NPC runner ----
NPC_RUN = $(MAKE) $(Q) -C $(NSIM_HOME) ISA=riscv$(XLEN) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)"

MEM_START := 0x80000000

# Derive --host triplet from CROSS_COMPILE (strip trailing dash)
CONFIG_HOST := $(patsubst %-,%,$(CROSS_COMPILE))

# On Linux (apt), bare-metal GCC needs picolibc headers for compilation.
# We use -isystem (not --specs=picolibc.specs) because picolibc specs inject
# -Tpicolibc.ld which conflicts with pk's own linker script (pk.lds),
# causing .text.init (reset_vector) to not be placed first at MEM_START.
# -nostdlib -lgcc lets configure's test compile succeed without picolibc's crt0.
ifeq ($(shell uname),Linux)
  _PICOLIBC_INCDIR := $(shell $(CC) --specs=picolibc.specs -E -Wp,-v -xc /dev/null 2>&1 | sed -n 's/^ *\(.*picolibc.*include\)$$/\1/p' | head -1)
  PK_CC := $(CC) -isystem $(_PICOLIBC_INCDIR) -nostdlib -lgcc
else
  PK_CC := $(CC)
endif

# ============================================================================
# Default target
# ============================================================================
.DEFAULT_GOAL := help

help: ## Show this help
	@echo "Usage: make -C app/pk <target> [VAR=value ...]"
	@awk '\
		BEGIN { state=0; pending=""; first=1 } \
		/^# =+$$/ { if (state==0) state=1; else if (state==2) { pending=section; state=0 } else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		{ if (state==1) state=0 } \
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first) printf "\nTargets:\n"; \
			first=0; \
			t=$$0; sub(/:.*/, "", t); \
			d=$$0; sub(/.*## /, "", d); \
			printf "  %-20s %s\n", t, d }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables:"
	@grep -hE '^[A-Z_][A-Z_0-9]*\s*\?=' $(MAKEFILE_LIST) | \
		awk '!seen[$$1]++ { \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-20s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				if (a[2] != "") printf "  %-20s (default: %s)\n", a[1], a[2] } }'
	@echo ""
# ============================================================================
# Stage pk source tree with our modifications
# ============================================================================
$(PK_STAGING)/.stamp: $(PK_SRC_DIR)/configure \
                      $(PK_HOME)/src/frontend.c \
                      $(PK_HOME)/src/pk.c \
                      $(PK_HOME)/src/elf_mem.c \
                      $(PK_HOME)/src/elf_mem.h \
                      $(PK_HOME)/src/pk_payload.S
	@echo "=== Staging pk source with NPC patches ==="
	rm -rf $(PK_STAGING)
	@mkdir -p $(dir $(PK_STAGING))
	cp -r $(PK_SRC_DIR) $(PK_STAGING)
	# Override pk files with our no-HTIF versions
	cp $(PK_HOME)/src/frontend.c $(PK_STAGING)/pk/frontend.c
	cp $(PK_HOME)/src/pk.c       $(PK_STAGING)/pk/pk.c
	cp $(PK_HOME)/src/elf_mem.c  $(PK_STAGING)/pk/elf_mem.c
	cp $(PK_HOME)/src/elf_mem.h  $(PK_STAGING)/pk/elf_mem.h
	cp $(PK_HOME)/src/pk_payload.S  $(PK_STAGING)/pk/pk_payload.S
	# Add elf_mem.c and payload.S to pk build sources
	@cd $(PK_STAGING)/pk && \
		awk '/^pk_c_srcs/{found=1} found && /^$$/{print "  elf_mem.c \\"; found=0} {print}' pk.mk.in > pk.mk.in.tmp && mv pk.mk.in.tmp pk.mk.in
	@cd $(PK_STAGING)/pk && \
		awk '/^pk_asm_srcs/{found=1} found && /^$$/{print "  pk_payload.S \\"; found=0} {print}' pk.mk.in > pk.mk.in.tmp && mv pk.mk.in.tmp pk.mk.in
	# Add .payload section to pk linker script (before .data)
	@cd $(PK_STAGING)/pk && \
		awk '/_fdata/{print "  .payload : { *(.payload) }"; print "  . = ALIGN(0x1000);"} {print}' pk.lds > pk.lds.tmp && mv pk.lds.tmp pk.lds
	# Patch poweroff() in mtrap.c: add ebreak fallback before wfi loop
	@cd $(PK_STAGING)/machine && \
		sed 's/send_ipi_many(0, IPI_HALT);/asm volatile("ebreak"); send_ipi_many(0, IPI_HALT);/' mtrap.c > mtrap.c.tmp && mv mtrap.c.tmp mtrap.c
	# Patch mtrap.c machine_page_fault: redirect non-MPRV page faults to S-mode
	# NPC bug: exceptions from S/U go to M-mode, land on trap_table[13]=trap_from_machine_mode
	@cd $(PK_STAGING)/machine && \
		awk '/^fail:/{print; getline; \
		  print "  /* NPC workaround: redirect page faults from S/U mode to S-mode */"; \
		  print "  {"; \
		  print "    uintptr_t mpp = (read_csr(mstatus) >> 11) & 3;"; \
		  print "    if (mpp != 3)"; \
		  print "      redirect_trap(mepc, read_csr(mstatus), read_csr(mtval));"; \
		  print "  }"; \
		  print $$0; next} {print}' mtrap.c > mtrap.c.tmp && mv mtrap.c.tmp mtrap.c
	# Patch mentry.S: redirect delegatable exceptions to S-mode via pmp_trap
	# NPC RTL bug: exceptions always trap to M-mode even when medeleg delegates them
	@cd $(PK_STAGING)/machine && \
		sed -e 's|/\* 00 \*/ \.dc\.a bad_trap|/* 00 */ .dc.a pmp_trap|' \
		    -e 's|/\* 03 \*/ \.dc\.a bad_trap|/* 03 */ .dc.a pmp_trap|' \
		    -e 's|/\* 08 \*/ \.dc\.a bad_trap|/* 08 */ .dc.a pmp_trap|' \
		    -e 's|/\* 12 \*/ \.dc\.a bad_trap|/* 12 */ .dc.a pmp_trap|' \
		    -e 's|/\* 15 \*/ \.dc\.a bad_trap|/* 15 */ .dc.a pmp_trap|' \
		    mentry.S > mentry.S.tmp && mv mentry.S.tmp mentry.S
	# Patch minit.c: fix missing CSRs, force NS16550 UART, disable HTIF
	@cd $(PK_STAGING)/machine && \
		awk '/write_csr\(mcounteren/{print "  // " $$0 " // NPC/NEMU lack mcounteren"; next} \
		/write_csr\(menvcfg/{print "  // " $$0 " // NPC/NEMU lack menvcfg"; next} \
		/^  query_htif\(dtb\);/{print; \
		  print "  htif = 0;"; \
		  print "  if (!uart16550) uart16550 = (volatile uint8_t*)0x10000000UL;"; next} \
		{print}' minit.c > minit.c.tmp && mv minit.c.tmp minit.c
	# Patch uart16550_putchar: skip LSR check for NPC simulated UART
	@cd $(PK_STAGING)/machine && \
		awk '/void uart16550_putchar/{p=1} p && /uart16550\[UART_REG_LSR/{$$0="  // LSR check skipped for NPC sim"; p=0} {print}' uart16550.c > uart16550.c.tmp && mv uart16550.c.tmp uart16550.c
	touch $@

# ============================================================================
# Configure pk (one-time, uses staged source)
# ============================================================================
$(PK_BUILD)/Makefile: $(PK_STAGING)/.stamp
	@echo "=== Configuring pk for rv$(XLEN) ==="
	@mkdir -p $(PK_BUILD)
	# Create dummy payload for initial configure
	touch $(PK_BUILD)/payload.elf
	cd $(PK_BUILD) && \
		unset CFLAGS CPPFLAGS LDFLAGS && \
		CC="$(PK_CC)" \
		$(PK_STAGING)/configure \
			--host=$(CONFIG_HOST) \
			--with-arch=$(ARCH) \
			--with-abi=$(ABI) \
			--with-mem-start=$(MEM_START) \
			--disable-fp-emulation \
			--prefix=$(PK_BUILD)/install

# ============================================================================
# Build pk with current payload
# ============================================================================
$(PK_BUILD)/pk: $(PK_BUILD)/Makefile
	@env -u CFLAGS -u CPPFLAGS -u LDFLAGS $(MAKE) $(Q) -C $(PK_BUILD) -j$(NPROC)

pk-build: $(PK_BUILD)/pk ## Build pk (proxy kernel)
	@echo "=== pk built: $(PK_BUILD)/pk ==="

# ============================================================================
# Run USER_ELF via pk on NPC
# ============================================================================
USER_ELF ?= ## ELF binary to embed in pk

# Convert to absolute path if relative
ifneq ($(USER_ELF),)
  _ABS_USER_ELF := $(abspath $(USER_ELF))
endif

pk-run: $(PK_BUILD)/Makefile ## Run USER_ELF via pk on NPC
ifeq ($(strip $(USER_ELF)),)
	$(error Usage: make pk-run USER_ELF=<path-to-elf> [ARGS="..."])
endif
	@echo "=== Embedding $(notdir $(_ABS_USER_ELF)) into pk ==="
	@cp $(_ABS_USER_ELF) $(PK_BUILD)/payload.elf
	@rm -f $(PK_BUILD)/pk_payload.o $(PK_BUILD)/pk
	@env -u CFLAGS -u CPPFLAGS -u LDFLAGS $(MAKE) $(Q) -C $(PK_BUILD) -j$(NPROC) > /dev/null
	@$(OBJCOPY) -S -O binary $(PK_BUILD)/pk $(PK_BUILD)/pk.bin
	@$(SIZE) $(PK_BUILD)/pk
	@echo "=== Running on NPC ==="
	@$(NPC_RUN) IMG=$(PK_BUILD)/pk.bin

# ============================================================================
# BBL + Linux boot
# ============================================================================
LINUX_IMAGE ?= $(YSYX_HOME)/linux/build/arch/riscv/boot/Image ## Linux kernel Image path

bbl-linux: $(PK_STAGING)/.stamp ## Build BBL with Linux payload, run on NPC
	@test -f $(LINUX_IMAGE) || (echo "ERROR: Linux Image not found at $(LINUX_IMAGE)" && \
		echo "  Build it: make -C $(YSYX_HOME)/linux build_linux" && exit 1)
	rm -rf $(BBL_BUILD)
	@mkdir -p $(BBL_BUILD)
	cd $(BBL_BUILD) && CC="$(PK_CC)" $(PK_STAGING)/configure \
		--host=$(CONFIG_HOST) \
		--with-arch=$(ARCH) \
		--with-abi=$(ABI) \
		--with-mem-start=$(MEM_START) \
		--with-payload=$(LINUX_IMAGE) \
		--disable-fp-emulation \
		--prefix=$(BBL_BUILD)/install
	$(MAKE) -C $(BBL_BUILD) -j$(NPROC)
	$(OBJCOPY) -S -O binary $(BBL_BUILD)/bbl $(BBL_BUILD)/bbl.bin
	@echo "=== Running BBL + Linux on NPC ==="
	$(NPC_RUN) IMG=$(BBL_BUILD)/bbl.bin

# ============================================================================
# Clean
# ============================================================================
clean: ## Clean staging and build directories
	rm -rf $(PK_STAGING) $(PK_BUILD) $(BBL_BUILD)

.PHONY: help pk-build pk-run bbl-linux clean
