#!/usr/bin/env bash
# run-embench.sh — Build + run Embench-IoT benchmarks in parallel on LiteX sim.
#
# Usage:  bash benchmarks/embench/run-embench.sh          (from fpga/litex)
#
# Env:  BENCHES  JOBS  SIM_TIMEOUT  LOG_DIR  NO_RUN=1  NO_BUILD=1
#
# Parallel approach: one Vsim binary, per-bench workdirs with symlinked
# binary + modules and a unique sim_main_ram.init (generated via hexdump).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LITEX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BENCHES_DEFAULT="aha-mont64 crc32 depthconv edn huffbench matmult-int md5sum \
nettle-aes nettle-sha256 nsichneu picojpeg qrduino sglib-combined slre \
statemate tarfind ud wikisort xgboost"
BENCHES="${BENCHES:-$BENCHES_DEFAULT}"
SIM_TIMEOUT="${SIM_TIMEOUT:-600}"
LOG_DIR="${LOG_DIR:-$LITEX_DIR/build/embench-logs}"

_ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
JOBS="${JOBS:-$(( _ncpu / 2 > 0 ? _ncpu / 2 : 1 ))}"

VARIANT="${VARIANT:-standard}"
GW_DIR="$LITEX_DIR/build/$VARIANT/gateware"
VSIM="$GW_DIR/obj_dir/Vsim"
WORKDIR="$LITEX_DIR/build/embench-work"

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
TIMEOUT_CMD="${TIMEOUT_BIN:+$TIMEOUT_BIN --foreground}"
TIMEOUT_CMD="${TIMEOUT_CMD:-python3 $LITEX_DIR/scripts/run_with_timeout.py}"

mkdir -p "$LOG_DIR"

# ---- Build ----
if [[ "${NO_BUILD:-0}" != "1" ]]; then
    make -C "$LITEX_DIR" embench-build -j"$_ncpu"
fi

# ---- Ensure sim binary (when called standalone, outside `make embench`) ----
if [[ "${NO_RUN:-0}" != "1" && ! -x "$VSIM" ]]; then
    echo "[embench] Vsim not found — run 'make sim-build' in fpga/litex first." >&2
    exit 1
fi

# ---- Per-bench worker ----
_run_one() {
    local b="$1"
    local bin="$SCRIPT_DIR/build/$b/$b.bin"
    local wdir="$WORKDIR/$b"
    [[ -f "$bin" ]] || { echo "[embench] SKIP $b"; return 0; }

    rm -rf "$wdir" && mkdir -p "$wdir"
    ln -sf "$VSIM" "$wdir/Vsim"
    ln -sf "$GW_DIR/modules" "$GW_DIR/sim_config.js" "$wdir/"
    cp "$GW_DIR"/sim_{rom,sram,mem}.init "$wdir/"
    hexdump -v -e '1/4 "%08x\n"' "$bin" > "$wdir/sim_main_ram.init"

    cd "$wdir"
    ( $TIMEOUT_CMD "$SIM_TIMEOUT" ./Vsim 2>&1 \
        | awk -v f="$LOG_DIR/$b.log" '{print>f;fflush(f)} /^--- done ---/{exit}' ) || true
}

# ---- Parallel run ----
if [[ "${NO_RUN:-0}" != "1" ]]; then
    echo "[embench] Running $(echo $BENCHES | wc -w | tr -d ' ') benchmarks (JOBS=$JOBS, timeout=${SIM_TIMEOUT}s)"
    export SCRIPT_DIR LITEX_DIR LOG_DIR WORKDIR GW_DIR VSIM SIM_TIMEOUT TIMEOUT_CMD
    export -f _run_one
    echo "$BENCHES" | tr ' ' '\n' | xargs -P "$JOBS" -I{} bash -c '_run_one "$@"' _ {}
    rm -rf "$WORKDIR"
fi

# ---- Summary ----
bash "$SCRIPT_DIR/report-embench.sh" "$LOG_DIR" | tee "$LOG_DIR/summary.md"
