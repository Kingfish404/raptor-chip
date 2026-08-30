SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.DEFAULT_GOAL := help

.PHONY: help list parallel-info doctor syn sta ppa ppa-summary profile-summary ppa-summary-all-pdks ppa-all-pdks ppa-all ppa-matrix pd-doctor floorplan place cts route pnr viz pd-summary pnr-all clean clean-pnr

help list parallel-info doctor syn sta ppa ppa-summary profile-summary ppa-summary-all-pdks ppa-all-pdks ppa-all ppa-matrix clean:
	+$(MAKE) -C syn $@ $(filter-out $@,$(MAKECMDGOALS))

pd-doctor:
	+$(MAKE) -C pnr doctor $(filter-out $@,$(MAKECMDGOALS))

floorplan place cts route pnr viz pnr-all:
	+$(MAKE) -C pnr $@ $(filter-out $@,$(MAKECMDGOALS))

pd-summary:
	+$(MAKE) -C pnr summary $(filter-out $@,$(MAKECMDGOALS))

clean-pnr:
	+$(MAKE) -C pnr clean

%:
	@:
