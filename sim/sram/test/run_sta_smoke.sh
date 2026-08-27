#!/usr/bin/env bash
# Run a minimal STA smoke against the SRAM macro stubs.
#
# Requires: yosys (with yosys-slang plugin) and OpenSTA, available via the
# yosys-opensta third-party flow. Exits 0 on success, 1 on any failure.
#
# What this validates:
#   * Yosys reads the design + blackbox + Liberty without errors.
#   * Yosys does NOT flatten the macro (blackbox preserved in netlist).
#   * OpenSTA produces a non-empty timing report.
#   * The report references the macro instance (proves the .lib hooked up).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRAM_DIR="$(cd "$HERE/.." && pwd)"
RAPTOR="$(cd "$SRAM_DIR/../.." && pwd)"
YOSTA="$RAPTOR/third_party/yosys-opensta"

PLATFORM="${STA_PLATFORM:-nangate45}"
CLK_FREQ_MHZ="${CLK_FREQ_MHZ:-100}"
DESIGN="rapt_sram_test_top"

# --- Prereqs --------------------------------------------------------------
command -v yosys >/dev/null 2>&1 || { echo "FAIL: yosys not on PATH"; exit 1; }
if ! yosys -p "plugin -i slang" -q 2>/dev/null; then
    echo "FAIL: yosys-slang plugin not installed (need slang.so)"
    exit 1
fi
[ -d "$YOSTA" ] || { echo "FAIL: $YOSTA missing (make YOSYS_OPENSTA)"; exit 1; }

# --- Ensure stub libs exist ------------------------------------------------
LIB="$SRAM_DIR/build/sky130/macro/rapt_openram_1rw_32x32/rapt_openram_1rw_32x32.lib"
if [ ! -f "$LIB" ]; then
    echo ">>> stub .lib missing, generating..."
    make -C "$SRAM_DIR" stubs PLATFORM=sky130
fi
[ -f "$LIB" ] || { echo "FAIL: stub .lib still missing at $LIB"; exit 1; }

# --- Build the design input (preprocessed SV) ------------------------------
TMP="$HERE/_tmp_sta"
mkdir -p "$TMP"
SV_OUT="$TMP/rapt_sram_test_pack.sv"
verilator -E -P -DRAPT_USE_SRAM_MACRO \
    -I"$RAPTOR/hdl/configs/default" \
    -I"$RAPTOR/hdl/include" \
    "$RAPTOR/hdl/rapt_pkg.sv" \
    "$RAPTOR/hdl/memory/rapt_sram_1rw.sv" \
    "$HERE/fixtures/rapt_sram_test_top.sv" \
    > "$SV_OUT"

# --- Drive yosys-opensta ---------------------------------------------------
EXTRA_LIB_FILES="$LIB" \
EXTRA_BLACKBOX_V_FILES="$SRAM_DIR/wrappers/rapt_sram_blackbox.v" \
make -C "$YOSTA" sta \
    DESIGN="$DESIGN" \
    PLATFORM="$PLATFORM" \
    CLK_FREQ_MHZ="$CLK_FREQ_MHZ" \
    RTL_FILES="$SV_OUT" \
    2>&1 | tee "$TMP/sta.log"

# --- Assertions on the artefacts ------------------------------------------
RESULT_DIR="$YOSTA/result/${PLATFORM}-${DESIGN}-${CLK_FREQ_MHZ}MHz"
NETLIST="$RESULT_DIR/${DESIGN}.netlist.syn.v"
REPORT="$RESULT_DIR/${DESIGN}.sta.rep"

fail=0
trap '[ $fail -ne 0 ] && echo ">>> SMOKE FAILED ($fail check(s))"' EXIT

check() {
    if eval "$1"; then
        echo "  PASS  $2"
    else
        echo "  FAIL  $2"
        fail=$((fail + 1))
    fi
}

echo
echo "=== Smoke assertions ==="
check "[ -f '$NETLIST' ]"                              "yosys produced synthesised netlist"
check "[ -f '$REPORT' ]"                               "OpenSTA produced timing report"
check "grep -q 'rapt_openram_1rw_32x32' '$NETLIST'"    "macro instance preserved in netlist (not flattened)"
check "grep -qE 'clk0|clk1' '$REPORT'"                 "STA report references macro clock pins"
check "[ -s '$REPORT' ]"                               "STA report is non-empty"

if [ $fail -ne 0 ]; then
    exit 1
fi
echo ">>> All STA smoke assertions passed."
