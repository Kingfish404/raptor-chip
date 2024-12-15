BUILD_DIR = ./../vsrc/generated

PRJ = npc
MILL = ./mill

test:
	$(MILL) -i $(PRJ).test

mill:
	wget https://github.com/com-lihaoyi/mill/releases/download/0.11.13/0.11.13 -O mill

verilog: mill
	mkdir -p $(BUILD_DIR)
	$(MILL) -i $(PRJ).runMain Elaborate --target-dir $(BUILD_DIR)

help:
	$(MILL) -i $(PRJ).runMain Elaborate --help

reformat:
	$(MILL) -i __.reformat

checkformat:
	$(MILL) -i __.checkFormat

bsp:
	$(MILL) -i mill.bsp.BSP/install

idea:
	$(MILL) -i mill.idea.GenIdea/idea

clean:
	-rm -rf $(BUILD_DIR)

.PHONY: test verilog help reformat checkformat clean

sim:
	@echo "Write this Makefile by yourself."
