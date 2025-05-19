ifeq ($(wildcard $(YSYX_HOME)/npc/Makefile),)
  $(error YSYX_HOME=$(YSYX_HOME) is not a YSYX repo)
endif

LITEX_PATH = $(YSYX_HOME)/third_party/enjoy-digital/litex

$(LITEX_PATH)/README.md:
	mkdir -p $(YSYX_HOME)/third_party/enjoy-digital/
	git clone https://github.com/enjoy-digital/litex/ $(LITEX_PATH)
	cd $(LITEX_PATH) && python3 ./litex_setup.py --init --install
	make link

link:
	ln -sf $(abspath cores/cpu/ysyx) $(LITEX_PATH)/litex/soc/cores/cpu/
	ln -sf $(abspath software/coremark) $(LITEX_PATH)/litex/soc/software/

update: $(LITEX_PATH)/README.md
	cd $(LITEX_PATH) && python3 ./litex_setup.py --update

build:
	cd $(LITEX_PATH) && \
	python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
		--integrated-main-ram-size 0x10000 \
		--no-compile-gateware

run: $(LITEX_PATH)/README.md
	cd $(LITEX_PATH) && \
		python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--integrated-main-ram-size 0x10000

linux_btb: build
	litex_json2dts_linux $(LITEX_PATH)/build/sim/csr.json > $(LITEX_PATH)/build/ysyx.dts

liftoff: $(LITEX_PATH)/README.md
	cd $(LITEX_PATH) && \
			python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--ram-init=demo.bin --integrated-main-ram-size=0x10000

coremark: $(LITEX_PATH)/README.md
	cd $(LITEX_PATH) && \
			python3 ./litex/tools/litex_sim.py --cpu-type=ysyx \
			--ram-init=coremark.bin --integrated-main-ram-size=0x10000
