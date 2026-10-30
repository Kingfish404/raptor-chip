# Additional upstream ISA/data-hazard corpus; ACT4 and block-level checks remain separate.
RISCV_TESTS_ROOT ?= $(BUILD_DIR)/riscv-tests
RISCV_TESTS_REPO ?= $(RISCV_TESTS_ROOT)/source
RISCV_TESTS_OUT ?= $(RISCV_TESTS_ROOT)/rv$(ISA_XLEN)-$(RAPT_CONFIG)
RISCV_TESTS_GROUPS ?= ui um ua uc uf ud uzba uzbb uzbc uzbs uzicond
RISCV_TESTS_SELECT ?=
RISCV_TESTS_TIMEOUT ?= 60
RISCV_TESTS_MEM_DELAYS ?= 0 31
RISCV_TESTS_MEM_SEEDS ?= 1
RISCV_TESTS_JOBS ?= 1
RISCV_TESTS_SIM_ROOT ?= $(RISCV_TESTS_ROOT)/sim
RISCV_TESTS_SIM_PROFILE := $(RAPT_CONFIG)-upstream-tests
RISCV_TESTS_NPC ?= $(RISCV_TESTS_SIM_ROOT)/$(RISCV_TESTS_SIM_PROFILE)/riscv$(ISA_XLEN)-npc-sim
RISCV_TESTS_MROM ?= $(RISCV_TESTS_ROOT)/mrom-rv$(ISA_XLEN)/mrom-data.bin
RISCV_TESTS_SPIKE ?= $(wildcard $(NEMU_HOME)/tools/spike-diff/repo/build/spike)
RISCV_TESTS_RUNNER := $(VERIFY_HOME)/scripts/run_riscv_tests.py
RISCV_TESTS_ARGS = --repo "$(RISCV_TESTS_REPO)" --xlen $(ISA_XLEN)

.PHONY: riscv-tests-setup riscv-tests-list riscv-tests-build-sim riscv-tests riscv-tests-driver-check

riscv-tests-setup: ## Fetch the pinned upstream riscv-tests and test environment
	$(PYTHON) "$(RISCV_TESTS_RUNNER)" setup $(RISCV_TESTS_ARGS)

riscv-tests-list: ## List selected upstream physical-environment ISA tests without running them
	$(PYTHON) "$(RISCV_TESTS_RUNNER)" list $(RISCV_TESTS_ARGS) \
		--groups $(RISCV_TESTS_GROUPS) --tests $(RISCV_TESTS_SELECT)

riscv-tests-build-sim: ## Build an isolated difftest-capable NPC and matching MROM
	$(MAKE) -C "$(NSIM_HOME)" all RAPT_CONFIG="$(RAPT_CONFIG)" DIFFTEST=1 \
		BUILD_ROOT="$(RISCV_TESTS_SIM_ROOT)" BUILD_PROFILE="$(RISCV_TESTS_SIM_PROFILE)" \
		VFLAGS="$(VFLAGS)"
	$(MAKE) -C "$(NSIM_HOME)/csrc/mem/mrom-data" all \
		BUILD_DIR="$(dir $(RISCV_TESTS_MROM))" ISA64=$(if $(filter 64,$(ISA_XLEN)),1,0)
	$(MAKE) -C "$(NSIM_HOME)" nemu-reference RAPT_CONFIG="$(RAPT_CONFIG)" \
		BUILD_ROOT="$(RISCV_TESTS_SIM_ROOT)" BUILD_PROFILE="$(RISCV_TESTS_SIM_PROFILE)" \
		VFLAGS="$(VFLAGS)"

riscv-tests: riscv-tests-setup riscv-tests-build-sim ## Run upstream tests with NEMU and optional Spike
	$(PYTHON) "$(RISCV_TESTS_RUNNER)" run $(RISCV_TESTS_ARGS) \
		--npc "$(RISCV_TESTS_NPC)" --mrom "$(RISCV_TESTS_MROM)" --nemu "$(NEMU_SO)" \
		$(if $(RISCV_TESTS_SPIKE),--spike "$(RISCV_TESTS_SPIKE)") \
		--cross "$(CROSS_COMPILE)" --output "$(RISCV_TESTS_OUT)" --preset "$(RAPT_CONFIG)" \
		--groups $(RISCV_TESTS_GROUPS) --tests $(RISCV_TESTS_SELECT) \
		--timeout $(RISCV_TESTS_TIMEOUT) --jobs $(RISCV_TESTS_JOBS) \
		--mem-delays $(RISCV_TESTS_MEM_DELAYS) --mem-seeds $(RISCV_TESTS_MEM_SEEDS)

riscv-tests-driver-check: ## Check HTIF termination and upstream-runner failure handling
	cd "$(VERIFY_HOME)/scripts" && $(PYTHON) -m unittest \
		test_external_drivers.UpstreamRunnerTest test_external_drivers.HtifMemoryTest

# Independent model checker and the upstream academic Cascade program generator.
PONO_OUT ?= $(BUILD_DIR)/pono-recovery
PONO ?= $(RAPTOR_HOME)/third_party/oss-cad-suite/bin/pono
BTORSIM ?= $(RAPTOR_HOME)/third_party/oss-cad-suite/bin/btorsim
PONO_ARGS ?=
CASCADE_ROOT ?= $(BUILD_DIR)/cascade
CASCADE_REPO ?= $(CASCADE_ROOT)/source
CASCADE_VENV ?= $(CASCADE_ROOT)/venv
CASCADE_PYTHON ?= $(CASCADE_VENV)/bin/python
CASCADE_OUT ?= $(CASCADE_ROOT)/rv$(ISA_XLEN)-$(RAPT_CONFIG)
CASCADE_SPIKE ?= $(NEMU_HOME)/tools/spike-diff/repo/build/spike
CASCADE_SEEDS ?= 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
CASCADE_BLOCKS ?= 20
CASCADE_INSTRUCTIONS ?= 1000
CASCADE_MEM_DELAYS ?= 0 31
CASCADE_TIMEOUT ?= 120
CASCADE_MEM_BYTES ?= 65536
CASCADE_MEMORY_SEED ?= 1
CASCADE_ISA_PROFILE ?= gc
CASCADE_RUNNER := $(VERIFY_HOME)/scripts/cascade_fuzz.py
EXTENDED_CAMPAIGN_OUT ?= $(BUILD_DIR)/extended-campaign
EXTENDED_CAMPAIGN_SECONDS ?= 10800
EXTENDED_CAMPAIGN_PRESETS ?= small middle-cache default-w4-cache
EXTENDED_CAMPAIGN_XLENS ?= 32 64

.PHONY: formal-pono-recovery cascade-setup cascade-fuzz advanced-driver-check
.PHONY: extended-campaign

formal-pono-recovery: ## Prove recovery selection with Pono; replay covers and mutation failures
	$(PYTHON) "$(VERIFY_HOME)/scripts/pono_recovery.py" --output "$(PONO_OUT)" \
		--pono "$(PONO)" --btorsim "$(BTORSIM)" $(PONO_ARGS)

cascade-setup: ## Fetch pinned Cascade sources and install its isolated Python dependencies
	$(PYTHON) "$(CASCADE_RUNNER)" setup --repo "$(CASCADE_REPO)"
	@test -x "$(CASCADE_PYTHON)" || $(PYTHON) -m venv "$(CASCADE_VENV)"
	"$(CASCADE_PYTHON)" -m pip install numpy==2.4.6 filelock==4.2.4

# Reuse the isolated difftest-capable simulator/MROM build, without fetching riscv-tests.
cascade-fuzz: riscv-tests-build-sim ## Run Cascade plus Spike state checks and NEMU lockstep
	"$(CASCADE_PYTHON)" "$(CASCADE_RUNNER)" run --repo "$(CASCADE_REPO)" \
		--output "$(CASCADE_OUT)" --xlen $(ISA_XLEN) --preset "$(RAPT_CONFIG)" \
		--npc "$(RISCV_TESTS_NPC)" --mrom "$(RISCV_TESTS_MROM)" --nemu "$(NEMU_SO)" \
		--spike "$(CASCADE_SPIKE)" --objcopy "$(CROSS_COMPILE)objcopy" \
		--seeds $(CASCADE_SEEDS) --blocks $(CASCADE_BLOCKS) \
		--instructions $(CASCADE_INSTRUCTIONS) --mem-delays $(CASCADE_MEM_DELAYS) \
		--isa-profile "$(CASCADE_ISA_PROFILE)" --mem-bytes $(CASCADE_MEM_BYTES) \
		--memory-seed $(CASCADE_MEMORY_SEED) \
		--timeout $(CASCADE_TIMEOUT)

advanced-driver-check: ## Check formal outcomes, epilogue guards and checkpoint failure detection
	cd "$(VERIFY_HOME)/scripts" && $(PYTHON) -m unittest $(addprefix test_external_drivers.,\
		PonoOutcomes CascadeChecks ExtendedCampaignChecks)

extended-campaign: ## Run snapshotted formal/fuzz lanes for at least three active hours each
	$(PYTHON) "$(VERIFY_HOME)/scripts/extended_campaign.py" \
		--output "$(EXTENDED_CAMPAIGN_OUT)" --seconds $(EXTENDED_CAMPAIGN_SECONDS) \
		--presets $(EXTENDED_CAMPAIGN_PRESETS) --xlens $(EXTENDED_CAMPAIGN_XLENS) \
		--cascade-repo "$(CASCADE_REPO)" --python "$(CASCADE_PYTHON)" \
		--spike "$(CASCADE_SPIKE)" --nemu32 "$(NEMU_SO_32)" --nemu64 "$(NEMU_SO_64)" \
		--objcopy "$(CROSS_COMPILE)objcopy" --cross "$(CROSS_COMPILE)" \
		--pono "$(PONO)" --btorsim "$(BTORSIM)"
