# gem5 SE-mode runner for raptor-chip
#
# Usage:
#   make help
#   make coremark
#   make coremark PRESET=large RV64=1
#   make sweep BENCH=coremark
#
# Variables:
#   GEM5      gem5 binary (default: $(GEM5_ROOT)/build/RISCV/gem5.opt)
#   GEM5_ROOT gem5 source/build root
#   PRESET    raptor uarch preset: small | default | large (default: default)
#   RV64      1 → use rv64 ELFs and RV64 ISA (default: 0)
#   BENCH     benchmark name (coremark, embench-crc32, ...)
#   CPU       o3 | timing (default: o3)
#   OUTDIR    gem5 m5out subdir (default: nsim/build/gsim/<bench>-<preset>-<cpu>-rv$XLEN)
#   ARGS      extra args forwarded to raptor_se.py
#   OPTIONS   benchmark argv (semicolon-separated; e.g. "0x0;0x0;0x66;10")

RAPTOR_HOME ?= $(abspath $(CURDIR)/../..)
GEM5_ROOT   ?= $(RAPTOR_HOME)/third_party/gem5
GEM5        ?= $(GEM5_ROOT)/build/RISCV/gem5.opt
PYTHON      ?= python3

PRESET ?= default
RV64   ?= 0
CPU    ?= o3
BENCH  ?= coremark
OPTIONS ?=
ARGS   ?=
# Microarchitecture-fidelity knobs (forwarded to raptor_se.py).
# Defaults track raptor RTL: no L2, single-outstanding L1 miss, bimodal-only
# PHT, and StoreSet load speculation disabled.
BP       ?= local##      local | bimode
MSHRS    ?= 1##          L1 MSHRs per cache (RTL: 1)
MEM_LATENCY ?=##         override raptor_se.py default --mem-latency (e.g. 30ns)
WITH_L2  ?= 0##          1 = re-enable gem5's optional 64KiB L2

# Translate the knobs into raptor_se.py args. WITH_L2=1 explicitly opts in
# (script default is --no-l2).
FIDELITY_ARGS := --bp $(BP) --mshrs $(MSHRS) \
    $(if $(filter 1 y yes true,$(WITH_L2)),--with-l2,) \
    $(if $(MEM_LATENCY),--mem-latency $(MEM_LATENCY),)

XLEN := $(if $(filter 1 y yes true,$(RV64)),64,32)
RV64_FLAG := $(if $(filter 1 y yes true,$(RV64)),--rv64,)

# All gem5 / gsim artifacts live under nsim/build/gsim/, alongside the
# verilator builds in nsim/build/<preset>/. Per-run dirs are named so
# they sort by benchmark, preset, cpu, and XLEN.
GSIM_BUILD   := $(RAPTOR_HOME)/nsim/build/gsim
OUTDIR      ?= $(GSIM_BUILD)/$(BENCH)-$(PRESET)-$(CPU)-rv$(XLEN)

SCRIPT     := $(CURDIR)/raptor_se.py
SUMMARY_PY := $(CURDIR)/summarize_stats.py

# Sweep / aggregate outputs.
RESULTS_DIR  ?= $(GSIM_BUILD)/results
SWEEP_OUTDIR := $(GSIM_BUILD)/sweep-$(BENCH)
SWEEP_CSV    := $(RESULTS_DIR)/sweep-$(BENCH)-rv$(XLEN).csv

ELF_BASE := $(RAPTOR_HOME)/app/build/rv$(XLEN)
COREMARK_ELF := $(ELF_BASE)/coremark/coremark.elf
EMBENCH_DIR  := $(ELF_BASE)/embench

# CoreMark canonical args (validation seed): 0 0 0x66 10
COREMARK_OPTS ?= 0;0;0x66;10

.PHONY: help check-gem5 build-coremark build-embench \
        coremark embench-% timing run summary sweep aggregate clean

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_%-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Examples:"
	@echo "  make coremark"
	@echo "  make coremark PRESET=small"
	@echo "  make coremark PRESET=large RV64=1"
	@echo "  make embench-crc32"
	@echo "  make sweep BENCH=coremark"

check-gem5: ## Verify gem5 source tree + built binary are available
	@if [ ! -e $(GEM5_ROOT)/SConstruct ]; then \
	  echo "gem5 source tree not found at: $(GEM5_ROOT)"; \
	  echo "Expected a (sym)link/clone under third_party/gem5."; \
	  echo "Set up with one of:"; \
	  echo "  git clone https://github.com/gem5/gem5.git $(GEM5_ROOT)"; \
	  echo "  ln -s /path/to/your/gem5 $(GEM5_ROOT)"; \
	  exit 1; \
	fi
	@test -x $(GEM5) || { \
	  echo "gem5 binary not found: $(GEM5)"; \
	  echo "Build it first: cd $(GEM5_ROOT) && scons build/RISCV/gem5.opt -j\$$(sysctl -n hw.ncpu)"; \
	  exit 1; }

build-coremark: ## Build raptor coremark.elf for current XLEN
	$(MAKE) -C $(RAPTOR_HOME)/app coremark-build $(if $(filter 64,$(XLEN)),ISA64=1,)

build-embench: ## Build raptor embench ELFs for current XLEN
	$(MAKE) -C $(RAPTOR_HOME)/app embench-build $(if $(filter 64,$(XLEN)),ISA64=1,)

run: check-gem5 ## Run any --benchmark via $(BENCH); pass $(OPTIONS) and extra $(ARGS); tees to run.log + writes summary.txt/.csv
	@mkdir -p $(OUTDIR)
	@echo "[gem5] -> $(OUTDIR)/run.log"
	@set -o pipefail; $(GEM5) --outdir=$(OUTDIR) $(SCRIPT) \
	    --preset $(PRESET) $(RV64_FLAG) --cpu $(CPU) \
	    --benchmark $(BENCH) $(if $(OPTIONS),--options "$(OPTIONS)",) \
	    $(FIDELITY_ARGS) \
	    $(ARGS) 2>&1 | tee $(OUTDIR)/run.log
	@$(MAKE) -s summary OUTDIR=$(OUTDIR) AGGREGATE_CSV="$(AGGREGATE_CSV)" \
	    SUMMARY_TAG="$(BENCH)-$(PRESET)-$(CPU)-rv$(XLEN)"

summary: ## Re-summarise an existing $(OUTDIR) (writes summary.txt/.csv)
	@$(PYTHON) $(SUMMARY_PY) $(OUTDIR) \
	    $(if $(SUMMARY_TAG),--tag $(SUMMARY_TAG),) \
	    $(if $(AGGREGATE_CSV),--csv $(AGGREGATE_CSV),)

coremark: build-coremark ## Run CoreMark with seed 0 0 0x66 10 (SE-mode bare-metal newlib)
	$(MAKE) run BENCH=coremark OPTIONS="$(COREMARK_OPTS)"

embench-%: build-embench ## Run an Embench-IoT workload (e.g. embench-crc32)
	$(MAKE) run BENCH=embench-$*

timing: ## Run on the in-order TimingSimpleCPU baseline
	$(MAKE) run CPU=timing

sweep: check-gem5 ## Sweep small/default/large × in-order/o3 for $(BENCH); writes $(SWEEP_CSV)
	@mkdir -p $(RESULTS_DIR)
	@rm -f $(SWEEP_CSV)
	@for cpu in timing o3; do \
	  for p in small default large; do \
	    echo "=== preset=$$p cpu=$$cpu ==="; \
	    $(MAKE) run PRESET=$$p CPU=$$cpu BENCH=$(BENCH) OPTIONS="$(OPTIONS)" \
	        OUTDIR=$(SWEEP_OUTDIR)/$${p}-$${cpu}-rv$(XLEN) \
	        AGGREGATE_CSV=$(SWEEP_CSV) \
	        || exit $$?; \
	  done; \
	done
	@echo "[sweep] aggregated -> $(SWEEP_CSV)"
	@column -t -s, $(SWEEP_CSV) 2>/dev/null || cat $(SWEEP_CSV)

aggregate: ## Re-aggregate existing runs under $(SWEEP_OUTDIR) into $(SWEEP_CSV)
	@mkdir -p $(RESULTS_DIR)
	@rm -f $(SWEEP_CSV)
	@for d in $(SWEEP_OUTDIR)/*/; do \
	  [ -f "$${d}stats.txt" ] || continue; \
	  $(PYTHON) $(SUMMARY_PY) "$$d" --tag "$$(basename $$d)" --csv $(SWEEP_CSV) >/dev/null; \
	done
	@echo "[aggregate] $(SWEEP_CSV)"
	@column -t -s, $(SWEEP_CSV) 2>/dev/null || cat $(SWEEP_CSV)

clean: ## Remove all gem5 / gsim build artifacts (nsim/build/gsim/)
	rm -rf $(GSIM_BUILD)
