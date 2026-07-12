#!/usr/bin/env bash
# run-embench.sh — Build + run Embench-IoT benchmarks in parallel on LiteX sim.
#
# Usage:  bash benchmarks/embench/run-embench.sh          (from fpga/litex)
#
# Env:  BENCHES  JOBS  SIM_TIMEOUT  LOG_DIR  NO_RUN=1  NO_BUILD=1
#       SYS_CLK_HZ  EMBENCH_NETTLE_SHA256_LOCAL_SCALE
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
NETTLE_SHA256_LOCAL_SCALE="${EMBENCH_NETTLE_SHA256_LOCAL_SCALE:-562}"
SYS_CLK_HZ="${SYS_CLK_HZ:-}"
BUILD_CONFIG="$SCRIPT_DIR/build/.build-config"

_ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
JOBS="${JOBS:-$(( _ncpu / 2 > 0 ? _ncpu / 2 : 1 ))}"

VARIANT="${VARIANT:-standard}"
ROM="${ROM:-sim}"
SOC="${SOC:-default}"

# Keep path logic in sync with fpga/litex/Makefile:
#   SIM_DIR := build/sim/<variant>-<rom>-<soc>
SIM_GW_DIR_DEFAULT="$LITEX_DIR/build/sim/${VARIANT}-${ROM}-${SOC}/gateware"
# Backward-compatible fallback for older layouts.
SIM_GW_DIR_LEGACY="$LITEX_DIR/build/$VARIANT/gateware"

GW_DIR="${SIM_GW_DIR:-$SIM_GW_DIR_DEFAULT}"
if [[ ! -x "$GW_DIR/obj_dir/Vsim" && -x "$SIM_GW_DIR_LEGACY/obj_dir/Vsim" ]]; then
    GW_DIR="$SIM_GW_DIR_LEGACY"
fi
VSIM="$GW_DIR/obj_dir/Vsim"
WORKDIR="$LITEX_DIR/build/embench-work"

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
TIMEOUT_CMD="${TIMEOUT_BIN:+$TIMEOUT_BIN --foreground}"
TIMEOUT_CMD="${TIMEOUT_CMD:-python3 $LITEX_DIR/scripts/run_with_timeout.py}"

_die() {
    echo "[embench] ERROR: $*" >&2
    exit 1
}

mkdir -p "$LOG_DIR"
if [[ ! "$SIM_TIMEOUT" =~ ^[0-9]+$ ]]; then
    _die "invalid SIM_TIMEOUT: $SIM_TIMEOUT"
fi
if [[ ! "$NETTLE_SHA256_LOCAL_SCALE" =~ ^[1-9][0-9]*$ ]]; then
    _die "invalid EMBENCH_NETTLE_SHA256_LOCAL_SCALE: $NETTLE_SHA256_LOCAL_SCALE"
fi

selected_benches=""
for bench in $BENCHES; do
    known=0
    for canonical_bench in $BENCHES_DEFAULT; do
        if [[ "$bench" == "$canonical_bench" ]]; then
            known=1
            break
        fi
    done
    (( known )) || _die "unknown benchmark: $bench"

    for selected_bench in $selected_benches; do
        [[ "$bench" != "$selected_bench" ]] || _die "duplicate benchmark: $bench"
    done
    selected_benches="${selected_benches:+$selected_benches }$bench"
done
[[ -n "$selected_benches" ]] || _die "no benchmarks selected"
BENCHES="$selected_benches"

# ---- Build ----
if [[ "${NO_BUILD:-0}" != "1" ]]; then
    build_args=("EMBENCH_NETTLE_SHA256_LOCAL_SCALE=$NETTLE_SHA256_LOCAL_SCALE")
    if [[ -n "$SYS_CLK_HZ" ]]; then
        build_args+=("SYS_CLK=$SYS_CLK_HZ")
    fi
    make -C "$LITEX_DIR" embench-build -j"$_ncpu" "${build_args[@]}"
else
    [[ -n "$SYS_CLK_HZ" ]] || _die "NO_BUILD=1 requires SYS_CLK_HZ"
    [[ -f "$BUILD_CONFIG" ]] || _die "NO_BUILD=1 requires $BUILD_CONFIG"
    expected_config="$(mktemp "$BUILD_CONFIG.expected.XXXXXX")"
    if ! make -s --no-print-directory -C "$SCRIPT_DIR" print-build-config \
        SYS_CLK_HZ="$SYS_CLK_HZ" \
        NETTLE_SHA256_LOCAL_SCALE="$NETTLE_SHA256_LOCAL_SCALE" > "$expected_config"; then
        rm -f "$expected_config"
        _die "failed to derive the expected build configuration"
    fi
    if ! cmp -s "$expected_config" "$BUILD_CONFIG"; then
        rm -f "$expected_config"
        _die "NO_BUILD=1 cache identity mismatch; rebuild without NO_BUILD"
    fi
    rm -f "$expected_config"
    for bench in $BENCHES; do
        [[ -f "$SCRIPT_DIR/build/$bench/$bench.bin" ]] \
            || _die "NO_BUILD=1 missing binary for selected benchmark: $bench"
    done
fi

[[ -f "$BUILD_CONFIG" ]] || _die "missing build configuration: $BUILD_CONFIG"

if [[ "${NO_RUN:-0}" == "1" ]]; then
    echo "[embench] Build complete (NO_RUN=1)."
    exit 0
fi

# ---- Ensure sim binary (when called standalone, outside `make embench`) ----
if [[ ! -x "$VSIM" ]]; then
    _die "Vsim not found at: $VSIM (run make sim-build or make embench first)"
fi

# A manifest and its logs are one batch. Do not allow a later selected run to
# inherit rows from an earlier full run.
rm -f "$LOG_DIR"/*.log "$LOG_DIR/summary.md" "$LOG_DIR/run-config.env"
manifest_tmp="$LOG_DIR/.run-config.env.$$"
{
    printf 'MANIFEST_VERSION=2\n'
    cat "$BUILD_CONFIG"
    for bench in $BENCHES; do
        printf 'BENCH=%s\n' "$bench"
    done
} > "$manifest_tmp"
mv -f "$manifest_tmp" "$LOG_DIR/run-config.env"

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
    if [[ ! -f "$bin" ]]; then
        echo "[embench] ERROR $b: missing binary $bin" >&2
        printf '[embench] ERROR %s: missing binary %s\nResult: ERROR\n' "$b" "$bin" > "$log"
        return 1
    fi

    rm -rf "$wdir" && mkdir -p "$wdir"
    ln -sf "$VSIM" "$wdir/Vsim"
    ln -sf "$GW_DIR/modules" "$GW_DIR/sim_config.js" "$wdir/"
    cp "$GW_DIR"/sim_{rom,sram,mem}.init "$wdir/"
    hexdump -v -e '1/4 "%08x\n"' "$bin" > "$wdir/sim_main_ram.init"

    cd "$wdir"
    : > "$log"
    ./Vsim >"$log" 2>&1 &
    local vpid=$!

    local deadline=0
    local done_seen=0
    local timed_out=0
    if (( SIM_TIMEOUT > 0 )); then
        deadline=$(( SECONDS + SIM_TIMEOUT ))
    fi
    while kill -0 "$vpid" 2>/dev/null; do
        if grep -q '^--- done ---' "$log" 2>/dev/null; then
            done_seen=1
            break
        fi
        if (( SIM_TIMEOUT > 0 && SECONDS >= deadline )); then
            timed_out=1
            break
        fi
        sleep 1
    done

    # Terminate Vsim after observing completion or the hard deadline. An
    # already-exited process is left alone so its real exit status is reported.
    if kill -0 "$vpid" 2>/dev/null; then
        kill "$vpid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$vpid" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$vpid" 2>/dev/null || true
    fi

    local vsim_rc=0
    if wait "$vpid" 2>/dev/null; then
        vsim_rc=0
    else
        vsim_rc=$?
    fi

    if (( ! done_seen )) && grep -q '^--- done ---' "$log" 2>/dev/null; then
        done_seen=1
    fi

    # Trim anything emitted after `--- done ---` to keep logs tidy and make a
    # completed benchmark the only successful worker outcome.
    if (( done_seen )); then
        awk '{print} /^--- done ---/{exit}' "$log" > "$log.trim" && mv "$log.trim" "$log"
        return 0
    fi

    if (( timed_out )); then
        echo "[embench] TIMEOUT $b after ${SIM_TIMEOUT}s" >&2
        printf '\n[embench] TIMEOUT %s after %ss\nResult: TIMEOUT\n' "$b" "$SIM_TIMEOUT" >> "$log"
    else
        echo "[embench] ERROR $b: Vsim exited ${vsim_rc} before completion" >&2
        printf '\n[embench] ERROR %s: Vsim exited %s before completion\nResult: ERROR\n' "$b" "$vsim_rc" >> "$log"
    fi
    return 1
}

# ---- Parallel run ----
run_status=0
echo "[embench] Running $(echo $BENCHES | wc -w | tr -d ' ') benchmarks (JOBS=$JOBS, timeout=${SIM_TIMEOUT}s)"
export SCRIPT_DIR LITEX_DIR LOG_DIR WORKDIR GW_DIR VSIM SIM_TIMEOUT TIMEOUT_CMD
export -f _run_one
if ! echo "$BENCHES" | tr ' ' '\n' | xargs -P "$JOBS" -I{} bash -c '_run_one "$@"' _ {}; then
    run_status=1
fi
rm -rf "$WORKDIR"

# ---- Summary ----
bash "$SCRIPT_DIR/report-embench.sh" "$LOG_DIR" | tee "$LOG_DIR/summary.md"
exit "$run_status"
