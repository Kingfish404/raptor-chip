# NEMU checks, included by verification/Makefile. Every check runs through
# verification/nemu/check.py; `python3 verification/nemu/check.py NAME --help` lists its
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
NEMU_MULTIHART_CHECKS := smp stats storage lockstep journal replay stream irq clint plic uart rng net block dma finisher console
.PHONY: nemu-unit-check nemu-multihart-check nemu-tlb-check nemu-distro-check $(NEMU_MULTIHART_CHECKS:%=nemu-%-check)

nemu-unit-check:
	cd "$(NEMU_VERIFY)" && $(PYTHON) -m unittest discover -s tests -t .

.PHONY: nemu-application-check
nemu-application-check: nemu-unit-check
	$(PYTHON) "$(NEMU_VERIFY)/check.py" application --output "$(BUILD_DIR)/nemu-application"

$(NEMU_MULTIHART_CHECKS:%=nemu-%-check): nemu-%-check: nemu-unit-check
	$(call nemu_check,$*,$(NEMU_EXTRA_$*))

NEMU_EXTRA_stream = $(if $(NEMU_SANITIZE),,--long)
nemu-irq-check: nemu-trap-delegation-check

NEMU_STORAGE_LINUX_PREPARED ?= $(RAPTOR_HOME)/linux/build/distro-boot-smp2-threaded/debian
NEMU_STORAGE_LINUX_TIMEOUT ?= 600
NEMU_STORAGE_LINUX_LAUNCHER ?=
NEMU_STORAGE_LINUX_NETWORK ?= 0
.PHONY: nemu-storage-linux-check
nemu-storage-linux-check: nemu-unit-check
	$(PYTHON) "$(NEMU_VERIFY)/check.py" storage-linux --prepared "$(NEMU_STORAGE_LINUX_PREPARED)" \
		--timeout "$(NEMU_STORAGE_LINUX_TIMEOUT)" --output "$(BUILD_DIR)/nemu-storage-linux" \
		$(if $(NEMU_STORAGE_LINUX_LAUNCHER),--launcher "$(NEMU_STORAGE_LINUX_LAUNCHER)") \
		$(if $(filter 1,$(NEMU_STORAGE_LINUX_NETWORK)),--network)

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
NEMU_ISA_CHECKS := memory-map compressed trap-delegation rva23-profile rva23-scalar \
	rva23-diel rva23-runtime zicond mop zcb zicbop svpbmt svpbmt-access svpbmt-decode \
	pmp-priority pmp-granularity pmp-capacity satp-warl sv39-superpage sv39-permissions \
	svnapot svinval h-gstage zawrs zfa zvbb zvfhmin pointer-mask sscofpmf smstateen \
	vector-control vector-data vector-misaligned vector-opcodes physical-address \
	counter-trap rva22s64
.PHONY: nemu-isa-check nemu-vector-fp-rtl-check nemu-vector-estimate-spike-check $(NEMU_ISA_CHECKS:%=nemu-%-check)
nemu-isa-check: $(NEMU_ISA_CHECKS:%=nemu-%-check)

nemu-rva23-profile-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" rva23-profile --reference "$(NEMU_SO_64)" --xlen 64 --output "$(BUILD_DIR)/nemu-rva23-profile-rv64.json"

nemu-rva23-scalar-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" rva22s64 --xlen 64 --profile rva23 --mcountinhibit absent \
		--reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-rva23-scalar.json"

nemu-rva23-diel-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" rva23-diel --reference "$(NEMU_SO_64)" \
		--output "$(BUILD_DIR)/nemu-rva23-diel.json"

.PHONY: nemu-rva23-vector-check
nemu-rva23-vector-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-spike --xlen 64 --profile rva23 \
		--reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-rva23-vector.json"

nemu-rva23-runtime-check:
	$(call nemu_check,rva23-runtime)

.PHONY: nemu-rva23-multihart-check
nemu-rva23-multihart-check: nemu-unit-check
	$(call nemu_check,rva23,,rva23-multihart)

NEMU_RVA23_KERNEL ?=
NEMU_RVA23_KERNEL_PACKAGE ?=
NEMU_RVA23_LINUX_TIMEOUT ?= 1800
NEMU_RVA23_HARTS ?= 1
.PHONY: nemu-rva23-linux-check
nemu-rva23-linux-check: nemu-unit-check
	@test -n "$(NEMU_RVA23_KERNEL)$(NEMU_RVA23_KERNEL_PACKAGE)" || { echo 'Set NEMU_RVA23_KERNEL or NEMU_RVA23_KERNEL_PACKAGE'; exit 1; }
	$(PYTHON) "$(NEMU_VERIFY)/check.py" rva23-linux \
		$(if $(NEMU_RVA23_KERNEL),--kernel "$(NEMU_RVA23_KERNEL)") \
		$(if $(NEMU_RVA23_KERNEL_PACKAGE),--kernel-package "$(NEMU_RVA23_KERNEL_PACKAGE)") \
		--timeout $(NEMU_RVA23_LINUX_TIMEOUT) --harts $(NEMU_RVA23_HARTS) --output "$(BUILD_DIR)/nemu-rva23-linux"

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

nemu-pmp-granularity-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" pmp-priority --test-source "$(NEMU_VERIFY)/isa/pmp_granularity.c"

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

nemu-svnapot-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" svnapot --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-svnapot/disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" svnapot --enable --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-svnapot/enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" svnapot --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-svnapot/rv32.json"

nemu-svinval-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" svinval --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-svinval/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" svinval --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-svinval/rv64.json"

nemu-h-gstage-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" h-gstage --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-h-gstage/rv32-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" h-gstage --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-h-gstage/rv64-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" h-gstage --xlen 64 --enable --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-h-gstage/rv64-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" h-gstage --xlen 64 --enable --svnapot --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-h-gstage/rv64-svnapot.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" h-gstage --xlen 64 --enable --pointer-mask --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-h-gstage/rv64-pointer-mask.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" h-gstage --xlen 64 --enable --vector --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-h-gstage/rv64-vector.json"

nemu-zawrs-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zawrs --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zawrs/rv32-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zawrs --xlen 32 --enable --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zawrs/rv32-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zawrs --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zawrs/rv64-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zawrs --xlen 64 --enable --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zawrs/rv64-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zawrs --xlen 64 --enable --hypervisor --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zawrs/rv64-hypervisor.json"

nemu-zicond-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zicond --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zicond/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zicond --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zicond/rv64.json"

nemu-mop-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" mop --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-mop/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" mop --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-mop/rv64.json"

nemu-zcb-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zcb --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zcb/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zcb --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zcb/rv64.json"

nemu-zicbop-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zicbop --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zicbop/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zicbop --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zicbop/rv64.json"

nemu-zfa-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zfa --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zfa/rv32-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zfa --xlen 32 --enable --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zfa/rv32-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zfa --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zfa/rv64-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zfa --xlen 64 --enable --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zfa/rv64-enabled.json"

nemu-zvbb-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zvbb --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-zvbb/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" zvbb --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-zvbb/rv64.json"

nemu-zvfhmin-check:
	@set -e; for xlen in 32 64; do \
		for mode in disabled enabled; do \
			options=""; if [ "$$mode" = enabled ]; then options=--enable; fi; \
			$(PYTHON) "$(NEMU_VERIFY)/check.py" zvfhmin --xlen $$xlen \
				$$options \
				--reference "$(NEMU_HOME)/build/ref/riscv$${xlen}_ref_defconfig/riscv$${xlen}-nemu-interpreter-so" \
				--output "$(BUILD_DIR)/nemu-zvfhmin/rv$${xlen}-$${mode}.json"; \
		done; \
	done

nemu-pointer-mask-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" pointer-mask --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-pointer-mask/rv32.json"
	@set -e; for extensions in none ssnpm smnpm ssnpm,smnpm; do \
		$(PYTHON) "$(NEMU_VERIFY)/check.py" pointer-mask --reference "$(NEMU_SO_64)" --extensions "$$extensions" \
			--output "$(BUILD_DIR)/nemu-pointer-mask/$$extensions.json"; \
	done

nemu-sscofpmf-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" sscofpmf --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-sscofpmf/rv32-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" sscofpmf --xlen 32 --enable --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-sscofpmf/rv32-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" sscofpmf --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-sscofpmf/rv64-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" sscofpmf --xlen 64 --enable --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-sscofpmf/rv64-enabled.json"

nemu-smstateen-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" smstateen --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-smstateen/rv32-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" smstateen --xlen 32 --enable --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-smstateen/rv32-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" smstateen --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-smstateen/rv64-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" smstateen --xlen 64 --enable --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-smstateen/rv64-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" smstateen --xlen 64 --enable --hypervisor --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-smstateen/rv64-hypervisor.json"

nemu-vector-control-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-control --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-vector-control/rv32-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-control --xlen 32 --enable --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-vector-control/rv32-enabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-control --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-control/rv64-disabled.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-control --xlen 64 --enable --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-control/rv64-enabled.json"

nemu-vector-data-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-data --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-vector-data/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-data --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-data/rv64.json"

nemu-vector-misaligned-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-misaligned --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-misaligned-rv64.json"

nemu-vector-opcodes-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-opcodes --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-vector-opcodes/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-opcodes --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-opcodes/rv64.json"

nemu-vector-estimate-spike-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-estimate-spike --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-vector-estimate-spike/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-estimate-spike --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-estimate-spike/rv64.json"

.PHONY: nemu-vector-spike-check nemu-vector-memory-spike-check
.PHONY: nemu-hypervisor-runtime-check
nemu-hypervisor-runtime-check:
	$(call nemu_check,hypervisor-runtime)

nemu-vector-spike-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-spike --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-vector-spike/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-spike --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-spike/rv64.json"

nemu-vector-memory-spike-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-memory-spike --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-vector-memory-spike/rv32.json"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" vector-memory-spike --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-vector-memory-spike/rv64.json"

NEMU_VECTOR_RTL_UNITS := alu muldiv reduce mask-scan slide gather mask-ops vpu fp-transfer move memory
NEMU_VECTOR_RTL_CHECKS := vector-rtl $(addprefix vector-,$(addsuffix -rtl,$(NEMU_VECTOR_RTL_UNITS)))
.PHONY: $(NEMU_VECTOR_RTL_CHECKS:%=nemu-%-check)
$(NEMU_VECTOR_RTL_CHECKS:%=nemu-%-check): nemu-%-check:
	$(PYTHON) "$(NEMU_VERIFY)/check.py" $* --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-$*/rv32"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" $* --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-$*/rv64"

nemu-vector-fp-rtl-check: nemu-vector-fp-transfer-rtl-check

nemu-physical-address-check nemu-counter-trap-check: nemu-%-check:
	@mkdir -p "$(BUILD_DIR)/nemu-$*"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" $* --xlen 32 --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-$*/rv32"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" $* --xlen 64 --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-$*/rv64"

nemu-rva22s64-check:
	@mkdir -p "$(BUILD_DIR)/nemu-rva22s64"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" rva22s64 --xlen 32 --mcountinhibit absent --reference "$(NEMU_SO_32)" --output "$(BUILD_DIR)/nemu-rva22s64/rv32"
	$(PYTHON) "$(NEMU_VERIFY)/check.py" rva22s64 --xlen 64 --mcountinhibit absent --reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-rva22s64/rv64"
