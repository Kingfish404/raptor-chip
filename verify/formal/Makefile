# ============================================================================
# Raptor Chip — Formal Verification Makefile
# ============================================================================
# Uses SymbiYosys (sby) from oss-cad-suite for formal verification.
# Run `make setup` to download oss-cad-suite if not already present.
# ============================================================================

SHELL := /bin/bash

# --- Paths ---
YSYX_HOME    ?= $(abspath ../..)
OSS_CAD_DIR  := $(YSYX_HOME)/third_party/oss-cad-suite
OSS_CAD_BIN  := $(OSS_CAD_DIR)/bin

# oss-cad-suite release to download when running `make setup`
OSS_CAD_VERSION ?= 2025-07-30
OSS_CAD_REPO    := https://github.com/YosysHQ/oss-cad-suite-build/releases/download
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    OSS_CAD_PLATFORM := darwin-arm64
  else
    OSS_CAD_PLATFORM := darwin-x64
  endif
else ifeq ($(UNAME_S),Linux)
  ifeq ($(UNAME_M),aarch64)
    OSS_CAD_PLATFORM := linux-arm64
  else
    OSS_CAD_PLATFORM := linux-x64
  endif
endif
OSS_CAD_DATE    := $(subst -,,$(OSS_CAD_VERSION))
OSS_CAD_TARBALL := oss-cad-suite-$(OSS_CAD_PLATFORM)-$(OSS_CAD_DATE).tgz
OSS_CAD_URL     := $(OSS_CAD_REPO)/$(OSS_CAD_VERSION)/$(OSS_CAD_TARBALL)

# Prepend oss-cad-suite/bin to PATH for all recipes
export PATH := $(OSS_CAD_BIN):$(PATH)

# ============================================================================
# Help
# ============================================================================
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
	@echo ""
	@echo "Variables:"
	@echo "  OSS_CAD_VERSION=YYYY-MM-DD  oss-cad-suite release (default: $(OSS_CAD_VERSION))"

# ============================================================================
# Setup / Init
# ============================================================================
.PHONY: setup check-tools

setup: ## Download and install oss-cad-suite (sby, yosys, solvers)
	@if [ -x "$(OSS_CAD_BIN)/sby" ]; then \
		echo "[formal] oss-cad-suite already installed at $(OSS_CAD_DIR)"; \
		echo "  sby:   $$($(OSS_CAD_BIN)/sby --version 2>/dev/null || echo unknown)"; \
		echo "  yosys: $$($(OSS_CAD_BIN)/yosys --version 2>/dev/null | head -1 || echo unknown)"; \
	else \
		echo "[formal] Downloading oss-cad-suite $(OSS_CAD_VERSION) for $(OSS_CAD_PLATFORM)..."; \
		echo "  URL: $(OSS_CAD_URL)"; \
		mkdir -p "$(YSYX_HOME)/third_party"; \
		curl -L --fail --progress-bar -o "/tmp/$(OSS_CAD_TARBALL)" "$(OSS_CAD_URL)"; \
		echo "[formal] Extracting to $(YSYX_HOME)/third_party/ ..."; \
		tar -xzf "/tmp/$(OSS_CAD_TARBALL)" -C "$(YSYX_HOME)/third_party/"; \
		rm -f "/tmp/$(OSS_CAD_TARBALL)"; \
		if [ "$(UNAME_S)" = "Darwin" ]; then \
			echo "[formal] Removing macOS quarantine flags (may require sudo)..."; \
			sudo xattr -rd com.apple.quarantine "$(OSS_CAD_DIR)" 2>/dev/null || true; \
		fi; \
		echo "[formal] Done. Installed:"; \
		echo "  sby:   $$($(OSS_CAD_BIN)/sby --version 2>/dev/null || echo unknown)"; \
		echo "  yosys: $$($(OSS_CAD_BIN)/yosys --version 2>/dev/null | head -1 || echo unknown)"; \
	fi

check-tools: ## Verify sby and yosys are available
	@command -v sby >/dev/null 2>&1 || \
		{ echo "ERROR: sby not found in PATH."; \
		  echo "  Run: make setup"; \
		  echo "  Or:  source $(OSS_CAD_DIR)/environment"; \
		  exit 1; }
	@command -v yosys >/dev/null 2>&1 || \
		{ echo "ERROR: yosys not found in PATH."; \
		  echo "  Run: make setup"; exit 1; }
	@echo "[formal] Tools OK: sby=$$(which sby), yosys=$$(which yosys)"

# ============================================================================
# Formal Verification Targets
# ============================================================================
all: formal_exu_mul formal_bus ## Run all formal verification

formal_bus: check-tools ## Verify AXI bus
	sby -f bus.sby

formal_exu_mul: check-tools ## Verify EXU multiplier
	sby -f exu_mul.sby

formal_gui: check-tools ## Open sby GUI
	sby-gui
