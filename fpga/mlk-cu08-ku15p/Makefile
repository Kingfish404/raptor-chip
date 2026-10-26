# MLK-CU08-KU15P native board build: SoC bitstream and Ubuntu.
# Run `make help` for every target and variable; see README.md for workflows.
.DEFAULT_GOAL := help

CM005_BRIDGE ?= 1 ## Keep CM005 A/B Ethernet forwarding in the bitstream (needs CLOCK_MHZ=50)
CM005_ETHERNET ?= 0 ## Also attach the core to CM005 as a LiteEth NIC (needs CM005_BRIDGE=1)
BRIDGE_PYTHON ?= ## Python with Migen/LiteEth for the CM005 generator (empty: fpga/litex/.venv)
BOARD_VARIABLES := CM005_BRIDGE CM005_ETHERNET BRIDGE_PYTHON
BOARD_OPTIONS = --cm005-bridge $(CM005_BRIDGE) --cm005-ethernet $(CM005_ETHERNET) \
	$(if $(BRIDGE_PYTHON),--bridge-python '$(BRIDGE_PYTHON)')

include ../common/board.mk
include ../common/ubuntu.mk

# Ubuntu uses the CM005 LiteEth NIC.
$(UBUNTU_BITSTREAM_TARGETS): override CM005_BRIDGE := 1
$(UBUNTU_BITSTREAM_TARGETS): override CM005_ETHERNET := 1
