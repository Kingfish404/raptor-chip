SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.DEFAULT_GOAL := help

.PHONY: fpga-syn fpga-eval fpga-summary fpga-eval-check
fpga-syn fpga-eval fpga-summary fpga-eval-check:
	+$(MAKE) -C yosys $@ SRAM_MODE=flops $(filter-out $@,$(MAKECMDGOALS))

.PHONY: help list parallel-info doctor syn sta ppa ppa-summary profile-summary ppa-summary-all-pdks ppa-all-pdks ppa-all ppa-matrix clean

help list parallel-info doctor syn sta ppa ppa-summary profile-summary ppa-summary-all-pdks ppa-all-pdks ppa-all ppa-matrix clean:
	+$(MAKE) -C yosys $@ $(filter-out $@,$(MAKECMDGOALS))

%:
	@:
