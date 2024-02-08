BUILD_DIR = ./build

test:
	mill -i __.test

verilog:
	mkdir -p $(BUILD_DIR)
	mill -i __.test.runMain Elaborate --target-dir $(BUILD_DIR)

help:
	mill -i __.test.runMain Elaborate --help

compile:
	mill -i __.compile

clean:
	-rm -rf $(BUILD_DIR)
