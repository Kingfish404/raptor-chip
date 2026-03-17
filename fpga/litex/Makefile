ifeq ($(wildcard $(YSYX_HOME)/nsim/Makefile),)
  $(error YSYX_HOME=$(YSYX_HOME) is not a YSYX repo)
endif

LITEX_PATH = $(YSYX_HOME)/third_party/enjoy-digital/litex

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

$(LITEX_PATH)/README.md:
	mkdir -p $(YSYX_HOME)/third_party/enjoy-digital/
	git clone https://github.com/enjoy-digital/litex/ $(LITEX_PATH)
	cd $(LITEX_PATH) && python3 ./litex_setup.py --init --install
	make link

link: ## Link ysyx CPU core into LiteX
	ln -sf $(abspath cores/cpu/ysyx) $(LITEX_PATH)/litex/soc/cores/cpu/
	ln -sf $(abspath software/coremark) $(LITEX_PATH)/litex/soc/software/

update: $(LITEX_PATH)/README.md ## Update LiteX dependencies
	cd $(LITEX_PATH) && python3 ./litex_setup.py --update

build: ## Build LiteX SoC (no gateware compile)
	cd $(LITEX_PATH) && \
	python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
		--integrated-main-ram-size 0x10000 \
		--no-compile-gateware

run: $(LITEX_PATH)/README.md ## Run LiteX simulation
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--integrated-main-ram-size 0x10000

run_ni: $(LITEX_PATH)/README.md ## Run LiteX simulation (non-interactive)
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--non-interactive \
			--integrated-main-ram-size 0x10000

linux_btb: build ## Generate Linux device tree
	litex_json2dts_linux $(LITEX_PATH)/build/sim/csr.json > $(LITEX_PATH)/build/ysyx.dts

liftoff: $(LITEX_PATH)/README.md ## Run LiteX with demo binary
	cd $(LITEX_PATH) && \
			python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--ram-init=demo.bin --integrated-main-ram-size=0x10000

coremark: $(LITEX_PATH)/README.md ## Run CoreMark on LiteX
	cd $(LITEX_PATH) \
		&& python3 ./litex/soc/software/coremark/coremark.py \
			--build-path=build/sim/ \
		&& python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--non-interactive \
			--ram-init=coremark.bin --integrated-main-ram-size=0x10000

coremark_wave: $(LITEX_PATH)/README.md ## Run CoreMark on LiteX with waveform
	cd $(LITEX_PATH) \
		&& python3 ./litex/soc/software/coremark/coremark.py \
			--build-path=build/sim/ \
		&& python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--non-interactive --gtkwave-savefile --trace --trace-fst \
			--ram-init=coremark.bin --integrated-main-ram-size=0x10000
