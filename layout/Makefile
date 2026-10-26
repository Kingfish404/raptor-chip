SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# Physical design. Netlists come from synth/yosys (see synth/README.md).
.DEFAULT_GOAL := help

.PHONY: help doctor syn floorplan place cts route pnr viz summary pnr-all clean
help doctor syn floorplan place cts route pnr viz summary pnr-all clean:
	+$(MAKE) -C openroad $@ $(filter-out $@,$(MAKECMDGOALS))

%:
	@:
