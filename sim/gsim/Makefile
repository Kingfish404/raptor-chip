# gem5 SE-mode runner for raptor-chip

RAPTOR_HOME ?= $(abspath $(CURDIR)/../..)
GEM5_ROOT   ?= $(RAPTOR_HOME)/third_party/gem5
GEM5        ?= $(GEM5_ROOT)/build/RISCV/gem5.opt
PYTHON      ?= python3

CPU_ORIGIN   := $(origin CPU)
BP_ORIGIN    := $(origin BP)
MSHRS_ORIGIN := $(origin MSHRS)

PRESET  ?= default ## Raptor uarch preset (small|default|large|...)
RV64    ?= 0 ## Set to 1 for RV64 ISA and payload selection
CPU     ?= o3 ## CPU model (o3|timing)
BENCH   ?= coremark ## Benchmark name or explicit ELF path
OPTIONS ?= ## Benchmark argv, semicolon-separated
ARGS    ?= ## Extra args forwarded verbatim to raptor_se.py
# Microarchitecture-fidelity knobs (forwarded to raptor_se.py).
# Defaults track raptor RTL: no L2, single-outstanding L1 miss, bimodal-only
# PHT, and StoreSet load speculation disabled.
BP          ?= local ## Branch predictor flavor (local|bimodal|bimode|gshare|tage|ltage|...)
MSHRS       ?= 1 ## L1 MSHRs per cache (RTL default: 1)
MEM_LATENCY ?= ## Override raptor_se.py default --mem-latency (e.g. 30ns)
WITH_L2     ?= 0 ## Set to 1 to re-enable gem5's optional 64KiB L2

# DSE config overrides (applied on top of PRESET's rapt_config.svh).
# JSON_CONFIG: path to a ChampSim-style JSON file (ooo_cpu/L1I/L1D/BTB/...).
# Defaults to dse-config.json in this directory so the canonical raptor-chip
# reference predictor / cache / BPU sizing (TAGE, etc.) is the actual default
# `make coremark` run, matching the comment header of dse-config.json itself.
# Pass JSON_CONFIG= (empty) to fall back to the pure --preset / svh-derived
# defaults from raptor_se.py.
# SET: comma-separated key.path=value pairs (no spaces around commas).
#      e.g.  SET=ooo_cpu.0.rob_size=128,ooo_cpu.0.scheduler_size=64,L1D.mshr_size=4
JSON_CONFIG ?= $(CURDIR)/dse-config.json ## Path to ChampSim-style DSE JSON override (empty to disable)
SET         ?= ## Comma-separated key.path=value overrides applied last
DSE_DIR     ?= $(CURDIR) ## Directory of *.json configs for dse-sweep

# `?=` assignments with trailing `##` comments keep the whitespace before the
# comment in the variable value. Strip the user-facing knobs that are reused in
# paths / command lines so make coremark SET=... does not create split argv.
PRESET      := $(strip $(PRESET))
RV64        := $(strip $(RV64))
CPU         := $(strip $(CPU))
BENCH       := $(strip $(BENCH))
OPTIONS     := $(strip $(OPTIONS))
ARGS        := $(strip $(ARGS))
BP          := $(strip $(BP))
MSHRS       := $(strip $(MSHRS))
MEM_LATENCY := $(strip $(MEM_LATENCY))
WITH_L2     := $(strip $(WITH_L2))
JSON_CONFIG := $(strip $(JSON_CONFIG))
SET         := $(strip $(SET))
DSE_DIR     := $(strip $(DSE_DIR))

# Translate explicit legacy knobs into raptor_se.py args. Defaults live in the
# script / JSON layer so ChampSim-style configs are not masked by Make defaults.
_BP_FROM_USER    := $(filter command line environment override,$(BP_ORIGIN))
_MSHRS_FROM_USER := $(filter command line environment override,$(MSHRS_ORIGIN))
FIDELITY_ARGS := \
	$(if $(_BP_FROM_USER),--bp $(BP),) \
	$(if $(_MSHRS_FROM_USER),--mshrs $(MSHRS),) \
	$(if $(filter 1 y yes true,$(WITH_L2)),--with-l2,) \
	$(if $(MEM_LATENCY),--mem-latency $(MEM_LATENCY),)

# JSON / --set forwarding
_JSON_FLAG := $(if $(JSON_CONFIG),--json-config $(JSON_CONFIG),)
comma      := ,
# Convert SET=a=1,b=2 → --set a=1 --set b=2
_SET_FLAGS := $(foreach s,$(subst $(comma), ,$(SET)),--set $(s))
# Build a readable suffix from SET so ad-hoc overrides never overwrite the base
# preset/JSON run directory. Keep '.' and '=' for readability; collapse commas
# to '-' so multiple overrides stay in one path component.
empty      :=
space      := $(empty) $(empty)
_SET_SLUG_RAW  := $(strip $(SET))
_SET_SLUG_STEP1 := $(subst $(space),,$(_SET_SLUG_RAW))
_SET_SLUG_STEP2 := $(subst $(comma),-,$(_SET_SLUG_STEP1))
_SET_SLUG_STEP3 := $(subst /,_,$(_SET_SLUG_STEP2))
_SET_SLUG_STEP4 := $(subst :,_,$(_SET_SLUG_STEP3))
_SET_SLUG      := $(_SET_SLUG_STEP4)
_SET_SUFFIX    := $(if $(_SET_SLUG),.$(_SET_SLUG),)

XLEN := $(if $(filter 1 y yes true,$(RV64)),64,32)
RV64_FLAG := $(if $(filter 1 y yes true,$(RV64)),--rv64,)
_CPU_FROM_USER := $(filter command line environment override,$(CPU_ORIGIN))
CPU_FLAG := $(if $(_CPU_FROM_USER),--cpu $(CPU),)

# All gem5 / gsim artifacts live under sim/build/gsim/, alongside the
# Verilator builds in sim/build/<preset>/. Per-run dirs are named so
# they sort by benchmark, config, cpu, and XLEN.
# When JSON_CONFIG is set, its basename (without .json) replaces PRESET in the
# dir name so sweeps across configs don't overwrite each other. When SET is
# used, append a `.ooo_cpu.0.foo=...-L1D.bar=...` suffix so ad-hoc overrides land
# in a distinct folder. Omit CPU from the tag for the default `o3` case.
GSIM_BUILD   := $(RAPTOR_HOME)/sim/build/gsim
_JSON_SLUG   := $(if $(JSON_CONFIG),$(basename $(notdir $(JSON_CONFIG))),)
_CONFIG_TAG  := $(if $(_JSON_SLUG),$(_JSON_SLUG),$(PRESET))
_CPU_SUFFIX  := $(if $(filter o3,$(CPU)),,.cpu=$(CPU))
_RUN_TAG     := $(_CONFIG_TAG)-rv$(XLEN)$(_CPU_SUFFIX)$(_SET_SUFFIX)
OUTDIR      ?= $(GSIM_BUILD)/$(BENCH)-$(_RUN_TAG)

SCRIPT     := $(CURDIR)/raptor_se.py
SUMMARY_PY := $(CURDIR)/summarize_stats.py

# Sweep / aggregate outputs.
RESULTS_DIR   ?= $(GSIM_BUILD)/results ## Aggregated CSV output directory
SWEEP_OUTDIR  := $(GSIM_BUILD)/sweep-$(BENCH)
SWEEP_CSV     := $(RESULTS_DIR)/sweep-$(BENCH)-rv$(XLEN).csv
DSE_OUTDIR    := $(GSIM_BUILD)/dse-$(BENCH)
DSE_CSV       := $(RESULTS_DIR)/dse-$(BENCH)-rv$(XLEN).csv
RESULTS_DIR   := $(strip $(RESULTS_DIR))
SWEEP_CSV     := $(RESULTS_DIR)/sweep-$(BENCH)-rv$(XLEN).csv
DSE_CSV       := $(RESULTS_DIR)/dse-$(BENCH)-rv$(XLEN).csv

ELF_BASE := $(RAPTOR_HOME)/app/build/rv$(XLEN)
COREMARK_ELF := $(ELF_BASE)/coremark/coremark.elf
EMBENCH_DIR  := $(ELF_BASE)/embench
MICROBENCH_ELF := $(ELF_BASE)/microbench/microbench.elf

# CoreMark canonical args (validation seed): 0 0 0x66 10
COREMARK_OPTS ?= 0;0;0x66;10 ## Canonical CoreMark validation args
COREMARK_OPTS := $(strip $(COREMARK_OPTS))
BP_STUDY_BENCHES ?= coremark microbench ## SE-compatible workloads for bp-study
BP_STUDY_BENCHES := $(strip $(BP_STUDY_BENCHES))

# ============================================================================
# Examples
# ============================================================================
#   make coremark
#   make coremark PRESET=small
#   make coremark PRESET=large RV64=1
#   make embench-crc32
#   make sweep BENCH=coremark

# ============================================================================
# Design-space exploration
# ============================================================================
#   make coremark JSON_CONFIG=dse-config.json
#   make coremark SET=ooo_cpu.0.rob_size=128,ooo_cpu.0.scheduler_size=64,L1D.mshr_size=4
#   make coremark SET=L1I.ways=2
#   make coremark SET=ooo_cpu.0.branch_predictor=gshare,RAS.enabled=false
#   make dse-sweep BENCH=coremark DSE_DIR=sweep-rob
#   make print-config PRESET=default SET=ooo_cpu.0.rob_size=96

.PHONY: help check-gem5 build-coremark build-microbench build-embench \
	coremark microbench embench-% timing run summary sweep aggregate \
		bp-study dse-sweep dse-aggregate print-config clean


# ============================================================================
# Default target
# ============================================================================
.DEFAULT_GOAL := help

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
		/^[a-zA-Z0-9_%-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first_target) printf "\nTargets:\n"; \
			first_target=0; \
			target=$$0; sub(/:.*/, "", target); \
			desc=$$0; sub(/.*## /, "", desc); \
			printf "  %-20s %s\n", target, desc }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables (override with VAR=value):"
	@grep -hE '^[A-Z_]+\s*\?=' $(MAKEFILE_LIST) | \
		awk '{ \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-16s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				printf "  %-16s %s\n", a[1], a[2] } }'
	@awk '\
		BEGIN { state=0; pending=""; printed=0 } \
		/^# =+$$/ { \
			if (state==0) state=1; \
			else if (state==2) state=3; \
			else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		state==2 { state=0 } \
		state==3 && /^#   / { \
			if (!printed || pending!=section) { printf "\n%s:\n", section; pending=section; printed=1 } \
			printf "  %s\n", substr($$0,5); next } \
		state==3 { state=0 }' $(MAKEFILE_LIST)

# ============================================================================
# Environment checks
# ============================================================================
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
	@$(GEM5) --help >/dev/null 2>&1 || { \
	  echo "gem5 cannot start: $(GEM5)"; \
	  echo "Rebuild it against the current host dependencies before running DSE."; \
	  exit 1; }

# ============================================================================
# Workload build helpers
# ============================================================================
build-coremark: ## Build raptor coremark.elf for current XLEN
	$(MAKE) -C $(RAPTOR_HOME)/app coremark-build $(if $(filter 64,$(XLEN)),ISA64=1,)

build-microbench: ## Build MicroBench SE ELF for current XLEN
	$(MAKE) -C $(RAPTOR_HOME)/app microbench-build $(if $(filter 64,$(XLEN)),ISA64=1,)

build-embench: ## Build raptor embench ELFs for current XLEN
	$(MAKE) -C $(RAPTOR_HOME)/app embench-build $(if $(filter 64,$(XLEN)),ISA64=1,)

# ============================================================================
# Run and summary
# ============================================================================
run: check-gem5 ## Run any --benchmark via $(BENCH); supports JSON_CONFIG and SET for DSE
	@mkdir -p $(OUTDIR)
	@echo "[gem5] -> $(OUTDIR)/run.log"
	@set -o pipefail; $(GEM5) --outdir=$(OUTDIR) $(SCRIPT) \
	    --preset $(PRESET) $(RV64_FLAG) $(CPU_FLAG) \
	    --benchmark $(BENCH) $(if $(OPTIONS),--options "$(OPTIONS)",) \
	    $(_JSON_FLAG) $(_SET_FLAGS) \
	    $(FIDELITY_ARGS) \
	    $(ARGS) 2>&1 | tee $(OUTDIR)/run.log
	@$(MAKE) -s summary OUTDIR=$(OUTDIR) AGGREGATE_CSV="$(AGGREGATE_CSV)" \
	    SUMMARY_TAG="$(BENCH)-$(_RUN_TAG)"

summary: ## Re-summarise an existing $(OUTDIR) (writes summary.txt/.csv)
	@$(PYTHON) $(SUMMARY_PY) $(OUTDIR) \
	    $(if $(SUMMARY_TAG),--tag $(SUMMARY_TAG),) \
	    $(if $(AGGREGATE_CSV),--csv $(AGGREGATE_CSV),)

# ============================================================================
# Benchmark entrypoints
# ============================================================================
coremark: build-coremark ## Run CoreMark with seed 0 0 0x66 10 (SE-mode bare-metal newlib)
	$(MAKE) run BENCH=coremark OPTIONS="$(COREMARK_OPTS)"

microbench: build-microbench ## Run MicroBench as a gem5 SE user process
	$(MAKE) run BENCH=$(MICROBENCH_ELF)

embench-%: build-embench ## Run an Embench-IoT workload (e.g. embench-crc32)
	$(MAKE) run BENCH=embench-$*

timing: ## Run on the in-order TimingSimpleCPU baseline
	$(MAKE) run CPU=timing

bp-study: check-gem5 build-coremark build-microbench ## Compare BPU designs on SE-compatible workloads
	@set -e; \
	  for bench in $(BP_STUDY_BENCHES); do \
	    if [ "$$bench" = coremark ]; then \
	      workload=coremark; options='$(COREMARK_OPTS)'; \
	    elif [ "$$bench" = microbench ]; then \
	      workload='$(MICROBENCH_ELF)'; options='test'; \
	    else \
	      echo "Unknown bp-study workload: $$bench (expected coremark or microbench)"; exit 2; \
	    fi; \
	    csv='$(RESULTS_DIR)/bp-study-'"$$bench"'-rv$(XLEN).csv'; \
	    rm -f "$$csv"; \
	    for label in rtl-tage same-budget-gshare practical-tage-sc upper-tage-sc; do \
	      case "$$label" in \
	        rtl-tage) set_args='';; \
	        same-budget-gshare) set_args='ooo_cpu.0.branch_predictor=gshare';; \
	        practical-tage-sc) set_args='ooo_cpu.0.branch_predictor=tage_sc_l_8kb,sim.equalize_budget=false';; \
	        upper-tage-sc) set_args='ooo_cpu.0.branch_predictor=tage_sc_l_64kb,sim.equalize_budget=false';; \
	      esac; \
	      $(MAKE) --no-print-directory run BENCH="$$workload" OPTIONS="$$options" SET="$$set_args" \
	        OUTDIR='$(GSIM_BUILD)/bp-study/'"$$bench"'/rv$(XLEN)/'"$$label" \
	        AGGREGATE_CSV="$$csv"; \
	    done; \
	    echo "[bp-study] aggregated -> $$csv"; \
	    column -t -s, "$$csv" 2>/dev/null || cat "$$csv"; \
	  done

# ============================================================================
# Aggregation and sweeps
# ============================================================================
sweep: check-gem5 ## Sweep small/default/large × in-order/o3 for $(BENCH); writes $(SWEEP_CSV)
	@mkdir -p $(RESULTS_DIR)
	@rm -f $(SWEEP_CSV)
	@for cpu in timing o3; do \
	  for p in small default large; do \
	    echo "=== preset=$$p cpu=$$cpu ==="; \
	    $(MAKE) run PRESET=$$p CPU=$$cpu BENCH=$(BENCH) OPTIONS="$(OPTIONS)" \
	        OUTDIR=$(SWEEP_OUTDIR)/$(BENCH)-$${p}-rv$(XLEN)$$(if [ "$$cpu" = o3 ]; then printf ''; else printf '.cpu=%s' "$$cpu"; fi) \
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

dse-sweep: check-gem5 ## Sweep all *.json in $(DSE_DIR) for $(BENCH); writes $(DSE_CSV)
	@if [ ! -d $(DSE_DIR) ]; then echo "DSE_DIR not found: $(DSE_DIR)"; exit 1; fi
	@mkdir -p $(RESULTS_DIR)
	@rm -f $(DSE_CSV)
	@found=0; \
	for json in $(DSE_DIR)/*.json; do \
	  [ -f "$$json" ] || continue; \
	  found=1; \
	  slug=$$(basename $$json .json); \
	  echo "=== DSE json=$$slug bench=$(BENCH) cpu=$(CPU) rv$(XLEN) ==="; \
	  $(MAKE) run BENCH=$(BENCH) OPTIONS="$(OPTIONS)" CPU=$(CPU) RV64=$(RV64) \
	      PRESET=$(PRESET) JSON_CONFIG=$$json SET=$(SET) \
	      OUTDIR=$(DSE_OUTDIR)/$(BENCH)-$${slug}-rv$(XLEN)$(_CPU_SUFFIX)$(_SET_SUFFIX) \
	      AGGREGATE_CSV=$(DSE_CSV) \
	      || exit $$?; \
	done; \
	if [ $$found -eq 0 ]; then echo "No *.json files found in $(DSE_DIR)"; exit 1; fi
	@echo "[dse-sweep] aggregated -> $(DSE_CSV)"
	@column -t -s, $(DSE_CSV) 2>/dev/null || cat $(DSE_CSV)

dse-aggregate: ## Re-aggregate existing DSE runs under $(DSE_OUTDIR) into $(DSE_CSV)
	@mkdir -p $(RESULTS_DIR)
	@rm -f $(DSE_CSV)
	@for d in $(DSE_OUTDIR)/*/; do \
	  [ -f "$${d}stats.txt" ] || continue; \
	  $(PYTHON) $(SUMMARY_PY) "$$d" --tag "$$(basename $$d)" --csv $(DSE_CSV) >/dev/null; \
	done
	@echo "[dse-aggregate] $(DSE_CSV)"
	@column -t -s, $(DSE_CSV) 2>/dev/null || cat $(DSE_CSV)

# ============================================================================
# Configuration inspection
# ============================================================================
print-config: check-gem5 ## Resolve + dump effective config without running simulation
	@$(GEM5) --outdir=$(OUTDIR) $(SCRIPT) \
	    --preset $(PRESET) $(RV64_FLAG) --cpu $(CPU) \
	    --benchmark $(BENCH) \
	    $(_JSON_FLAG) $(_SET_FLAGS) \
	    $(FIDELITY_ARGS) \
	    $(ARGS) --print-config-only

# ============================================================================
# Cleanup
# ============================================================================
clean: ## Remove all gem5 / gsim build artifacts (sim/build/gsim/)
	rm -rf $(GSIM_BUILD)
