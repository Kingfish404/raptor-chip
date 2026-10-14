# NEMU checks, included by verify/Makefile. Every check runs through
# verify/nemu/check.py; `python3 verify/nemu/check.py NAME --help` lists its
# options. Results go to $(BUILD_DIR)/nemu-NAME[-SANITIZER]/run-*/results.json.
#
#   NEMU_SANITIZE=undefined|thread  sanitizer for the private NEMU builds
#   NEMU_REPEAT=N                   threaded repetitions (default: per check)
#   NEMU_TSAN_NO_ASLR=1             run the checked programs under `setarch -R`

NEMU_VERIFY := $(VERIFY_HOME)/nemu
NEMU_SANITIZE ?=
NEMU_REPEAT ?=
NEMU_TSAN_NO_ASLR ?= 0
NEMU_CHECK_ARGS = $(if $(NEMU_SANITIZE),--sanitize $(NEMU_SANITIZE)) $(if $(NEMU_REPEAT),--repeat $(NEMU_REPEAT)) \
	$(if $(filter 1,$(NEMU_TSAN_NO_ASLR)),--disable-aslr)
# $(call nemu_check,NAME[,EXTRA ARGS[,OUTPUT NAME]])
nemu_check = $(PYTHON) "$(NEMU_VERIFY)/check.py" $(1) \
	--output "$(BUILD_DIR)/nemu-$(or $(3),$(1))$(if $(NEMU_SANITIZE),-$(NEMU_SANITIZE))" $(NEMU_CHECK_ARGS) $(2)

# Multi-hart execution and multicore DiffTest (see nemu/README.md#checks).
NEMU_MULTIHART_CHECKS := smp lockstep journal replay stream irq clint plic uart rng net block dma finisher console
.PHONY: nemu-unit-check nemu-multihart-check nemu-tlb-check nemu-distro-check $(NEMU_MULTIHART_CHECKS:%=nemu-%-check)

nemu-unit-check:
	cd "$(NEMU_VERIFY)" && $(PYTHON) -m unittest discover -s tests -t .

$(NEMU_MULTIHART_CHECKS:%=nemu-%-check): nemu-%-check: nemu-unit-check
	$(call nemu_check,$*,$(NEMU_EXTRA_$*))

NEMU_EXTRA_stream = $(if $(NEMU_SANITIZE),,--long)
nemu-irq-check: nemu-trap-delegation-check

# Retained TLBs: the focused TLB payload plus the UART matrix with --diff-tlb=retain.
nemu-tlb-check: nemu-unit-check
	$(call nemu_check,tlb)
	$(call nemu_check,uart,--tlb-retain,tlb-uart)

nemu-multihart-check: $(NEMU_MULTIHART_CHECKS:%=nemu-%-check) nemu-tlb-check

# Full Debian/Ubuntu boot under live DiffTest; needs a prepared image
# (make -C linux nemu-distro-prepare DISTRO_HARTS=2 DISTRO_NEMU_BACKEND=threaded).
NEMU_DISTRO_PREPARED ?= $(RAPTOR_HOME)/linux/build/distro-boot-smp2-threaded/debian
NEMU_DISTRO_TIMEOUT ?= 3600
NEMU_DISTRO_PIPE_BYTES ?= 65536
NEMU_DISTRO_PROGRESS ?= 1000000
NEMU_DISTRO_CLOCK_DIV ?=
nemu-distro-check: nemu-unit-check
	$(PYTHON) "$(NEMU_VERIFY)/check.py" distro --prepared "$(NEMU_DISTRO_PREPARED)" \
		--timeout $(NEMU_DISTRO_TIMEOUT) --pipe-bytes $(NEMU_DISTRO_PIPE_BYTES) --progress $(NEMU_DISTRO_PROGRESS) \
		$(if $(NEMU_DISTRO_CLOCK_DIV),--clock-div $(NEMU_DISTRO_CLOCK_DIV)) --output "$(BUILD_DIR)/nemu-distro"

# Single-hart ISA and platform checks.
NEMU_ISA_CHECKS := memory-map compressed trap-delegation svpbmt svpbmt-access svpbmt-decode pmp-priority \
	pmp-capacity satp-warl sv39-superpage sv39-permissions physical-address counter-trap rva22s64
.PHONY: nemu-isa-check $(NEMU_ISA_CHECKS:%=nemu-%-check)
nemu-isa-check: $(NEMU_ISA_CHECKS:%=nemu-%-check)

nemu-memory-map-check nemu-compressed-check: nemu-%-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" $*

nemu-trap-delegation-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" trap-delegation --sanitize
	$(PYTHON) "$(NEMU_VERIFY)/check.py" trap-delegation --sanitize --shared

nemu-svpbmt-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" svpbmt

nemu-svpbmt-access-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" svpbmt --access

nemu-svpbmt-decode-check:
	@mkdir -p "$(BUILD_DIR)"
	$(HOST_CXX) -std=c++17 -DCONFIG_ISA64 -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/nemu_svpbmt_decode.cc" -ldl -o "$(BUILD_DIR)/nemu-svpbmt-decode"
	"$(BUILD_DIR)/nemu-svpbmt-decode" "$(NEMU_SO_64)" 1
	"$(BUILD_DIR)/nemu-svpbmt-decode" "$(NEMU_SO_64)" 2

nemu-pmp-priority-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" pmp-priority

nemu-pmp-capacity-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" pmp-priority --test-source "$(RAPTOR_HOME)/app/tests/host/nemu_pmp_capacity.c"

# Checks that drive the shared reference library; build it first with
# make build-nemu32-ref build-nemu64-ref (svpbmt-decode needs the RV64 one too).
nemu-satp-warl-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" satp-warl --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-satp-warl.json"

nemu-sv39-superpage-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" sv39-superpage --reference "$(NEMU_SO_64)" \
		--output "$(BUILD_DIR)/nemu-sv39-superpage" --cc "$(CC)" --objcopy "$(OBJCOPY)"

nemu-sv39-permissions-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" sv39-permissions --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-sv39-permissions"

nemu-physical-address-check nemu-counter-trap-check nemu-rva22s64-check: nemu-%-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" $* --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-$*/rv32"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" $* --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-$*/rv64"
