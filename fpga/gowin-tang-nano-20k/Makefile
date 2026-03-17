ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

ifeq ($(VERILATOR_ROOT),)
VERILATOR = verilator
else
export VERILATOR_ROOT
VERILATOR = $(VERILATOR_ROOT)/bin/verilator
endif

VTARGET=TOP
BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(VTARGET)
INC_PATH ?=

$(shell mkdir -p $(BUILD_DIR))

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
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first_target) printf "\nTargets:\n"; \
			first_target=0; \
			target=$$0; sub(/:.*/, "", target); \
			desc=$$0; sub(/.*## /, "", desc); \
			printf "  %-20s %s\n", target, desc }' $(MAKEFILE_LIST)

VSRCS = $(shell find $(abspath ./src) -name "*.v")
CSRCS = $(shell find $(abspath ./src/csrc) -name "*.c" -or -name "*.cc")

INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(VTARGET)\""

$(BIN): $(VSRCS) $(CSRCS)
	$(VERILATOR) --trace -cc --exe --build -j \
		$^ \
		--top-module Top \
		$(addprefix -I, ./src/include) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

all: ## Build Verilator simulation
	$(MAKE) $(BIN)

sim: $(BIN) ## Run Verilator simulation
	$(BIN)

test:
	echo $(VTARGET)

syn: ## Synthesize for Gowin FPGA
	mkdir -p impl/syn
	yosys -p "read_verilog -sv -I src/include \
		src/*.v src/gowin_rpll/*.v; \
		synth_gowin -json impl/syn/fpga.json" \
		| tee impl/syn/fpga-synth.log

pnr: ## Place and route for Gowin FPGA
	nextpnr-himbaechel \
		--json impl/syn/fpga.json \
		--write impl/syn/pnrfpga.json \
		--device GW2AR-LV18QN88C8/I7 \
		--freq 27 \
		--report  impl/syn/fpga-pnr-report.json \
			--detailed-timing-report \
		--vopt family=GW2A-18C --vopt cst=fpga.cst \
		2>&1 | tee impl/syn/fpga-pnr.log 
	gowin_pack -d GW2AR-LV18QN88C8/I7 \
		-o impl/syn/fpga.fs \impl/syn/pnrfpga.json

program_flash: ## Program FPGA flash
	openFPGALoader -b tangnano20k -f impl/pnr/fpga.fs

program_sdram: ## Program FPGA SDRAM
	openFPGALoader -b tangnano20k impl/pnr/fpga.fs

maintainer-copy::
clean mostlyclean distclean maintainer-clean:: ## Clean build artifacts
	-rm -rf obj_dir *.log *.dmp *.vpd core $(BUILD_DIR)
