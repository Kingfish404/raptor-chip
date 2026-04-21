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
SIM_TIMEOUT="${SIM_TIMEOUT:-1200}"
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
# Strategy: run Vsim in the background, stream its output straight to a log
# file, and poll the log for the `--- done ---` sentinel. As soon as the
# benchmark finishes we SIGTERM Vsim; otherwise we bail out after SIM_TIMEOUT.
# (The old `Vsim | awk ... exit` pipe relied on SIGPIPE to kill Vsim, but the
# benchmark's post-done `hang()` never writes again, so Vsim would sit idle
# for the full SIM_TIMEOUT on every bench and stall CI.)
_run_one() {
    local b="$1"
    local bin="$SCRIPT_DIR/build/$b/$b.bin"
    local wdir="$WORKDIR/$b"
    local log="$LOG_DIR/$b.log"
    [[ -f "$bin" ]] || { echo "[embench] SKIP $b"; return 0; }

    rm -rf "$wdir" && mkdir -p "$wdir"
    ln -sf "$VSIM" "$wdir/Vsim"
    ln -sf "$GW_DIR/modules" "$GW_DIR/sim_config.js" "$wdir/"
    cp "$GW_DIR"/sim_{rom,sram,mem}.init "$wdir/"
    hexdump -v -e '1/4 "%08x\n"' "$bin" > "$wdir/sim_main_ram.init"

    cd "$wdir"
    : > "$log"
    ./Vsim >"$log" 2>&1 &
    local vpid=$!

    local deadline=$(( SECONDS + SIM_TIMEOUT ))
    local done_seen=0
    while kill -0 "$vpid" 2>/dev/null; do
        if grep -q '^--- done ---' "$log" 2>/dev/null; then
            done_seen=1
            break
        fi
        if (( SECONDS >= deadline )); then
            echo "[embench] TIMEOUT $b after ${SIM_TIMEOUT}s" >> "$log"
            break
        fi
        sleep 1
    done

    # Terminate Vsim (done or timeout). Give it a moment, then SIGKILL.
    kill "$vpid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        kill -0 "$vpid" 2>/dev/null || break
        sleep 0.2
    done
    kill -9 "$vpid" 2>/dev/null || true
    wait "$vpid" 2>/dev/null || true

    # Trim anything emitted after `--- done ---` to keep logs tidy.
    if (( done_seen )); then
        awk '{print} /^--- done ---/{exit}' "$log" > "$log.trim" && mv "$log.trim" "$log"
    fi
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
