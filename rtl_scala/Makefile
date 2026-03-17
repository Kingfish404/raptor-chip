BUILD_DIR = ./../rtl_sv/generated

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

test: ## Run Chisel tests
	sbt test

verilog: ## Generate SystemVerilog decoders
	mkdir -p $(BUILD_DIR)
	sbt "runMain Elaborate --target-dir $(BUILD_DIR)"

help: ## Show Chisel elaboration help
	sbt "runMain Elaborate --help"

clean: ## Clean generated files
	-rm -rf $(BUILD_DIR)

.PHONY: test verilog help clean
