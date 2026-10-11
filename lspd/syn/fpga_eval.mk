# Separate, cached evaluation flow. The existing fpga-syn always-rerun contract
# and its build directories are unchanged.
FPGA_EVAL_STAGE ?= place
FPGA_EVAL_MODE ?= screen
FPGA_CACHE_DIR ?= $(abspath ../fpga/cache)
FPGA_EVAL_DIR ?= $(abspath ../fpga/eval/$(RAPT_CONFIG)/$(FPGA_PART)/rv$(FPGA_XLEN)/$(MODULE)/$(CLK_FREQ_MHZ)MHz/$(FPGA_EVAL_MODE)-$(FPGA_EVAL_STAGE))
FPGA_CONTEXT_XDC ?=
FPGA_PHASE_TIMEOUT ?= 0
FPGA_REPORTS ?= $(FPGA_EVAL_DIR)
FPGA_SUMMARY ?= $(abspath ../fpga/eval/summary.md)

.PHONY: fpga-eval fpga-summary fpga-eval-check
fpga-eval: ## Cached OOC synth/place/route; FPGA_EVAL_STAGE=synth|place|route
	@test '$(SRAM_MODE)' = flops || { echo 'FPGA evaluation requires SRAM_MODE=flops'; exit 1; }
	@EVAL_ROOT='$(RAPT_HOME)' EVAL_MODULE='$(MODULE)' EVAL_TOP='$(TOP)' \
	 EVAL_CONFIG='$(RAPT_CONFIG)' EVAL_XLEN='$(FPGA_XLEN)' EVAL_PART='$(FPGA_PART)' \
	 EVAL_PERIOD='$(PERIOD_NS)' EVAL_IO_FRAC='$(IO_DELAY_FRAC)' EVAL_CLOCK='$(CLOCK_PORT)' \
	 EVAL_THREADS='$(FPGA_THREADS)' EVAL_SYNTH_DIRECTIVE='$(FPGA_SYNTH_DIRECTIVE)' \
	 EVAL_FLAGS='$(SLANG_FLAGS) $(if $(filter 64,$(FPGA_XLEN)),-DRAPT_RV64) -DRAPT_FPGA_DSP=1 $(FPGA_LUTRAM_DEFINE)' \
	 EVAL_SOURCES='$(SYNTH_SV_FILES)' EVAL_HEADERS='$(HDL_HEADERS)' \
	 EVAL_YOSYS='$(YOSYS)' EVAL_VIVADO='$(VIVADO)' EVAL_TIME='$(TIME)' \
	 $(PYTHON) scripts/fpga_eval.py run --stage '$(FPGA_EVAL_STAGE)' --mode '$(FPGA_EVAL_MODE)' \
		--cache '$(FPGA_CACHE_DIR)' --output '$(FPGA_EVAL_DIR)' \
		--context-xdc '$(FPGA_CONTEXT_XDC)' --timeout '$(FPGA_PHASE_TIMEOUT)'

fpga-summary: ## Collect existing fpga-eval results; FPGA_REPORTS="dir1 dir2 ..."
	@$(PYTHON) scripts/fpga_eval.py summary --output '$(FPGA_SUMMARY)' $(FPGA_REPORTS)

fpga-eval-check: ## Test evaluation caching, invalidation, and report integrity
	@$(PYTHON) -B -m unittest discover -s scripts -p 'test_fpga_eval.py' -v
