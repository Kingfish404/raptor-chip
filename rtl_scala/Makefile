BUILD_DIR = ./../rtl_sv/generated

test:
	sbt test

verilog:
	mkdir -p $(BUILD_DIR)
	sbt "runMain Elaborate --target-dir $(BUILD_DIR)"

help:
	sbt "runMain Elaborate --help"

clean:
	-rm -rf $(BUILD_DIR)

.PHONY: test verilog help clean
