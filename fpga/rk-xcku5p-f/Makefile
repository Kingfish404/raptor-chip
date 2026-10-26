# RK-XCKU5P-F native board build: SoC bitstream and Ubuntu.
# Run `make help` for every target and variable; see README.md for workflows.
.DEFAULT_GOAL := help

WITH_ETHERNET ?= 0 ## Add the onboard RGMII gigabit Ethernet MAC (0|1)
UBUNTU_SSH_KEY ?= $(CURDIR)/keys/ubuntu-test.pub ## SSH public key installed for root
BOARD_VARIABLES := WITH_ETHERNET
BOARD_OPTIONS = --ethernet $(WITH_ETHERNET)

include ../common/board.mk
include ../common/ubuntu.mk

# Ubuntu uses the onboard Ethernet MAC.
$(UBUNTU_BITSTREAM_TARGETS): override WITH_ETHERNET := 1

# ============================================================================
# Board tests
# ============================================================================

ethernet-test: ## Run the Ethernet packet and MAC regressions
	$(PYTHON) scripts/test_ethernet.py

.PHONY: ethernet-test
