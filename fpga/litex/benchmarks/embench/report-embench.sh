#!/usr/bin/env bash
# ============================================================================
# report-embench.sh: Parse per-bench logs and emit a markdown summary with
#                    the official Embench Score vs Cortex-M4 @ 16 MHz.
# ============================================================================
# Usage:
#   bash report-embench.sh <log-dir>
#
# Expects per-bench logs named <bench>.log with lines:
#   --- <name> ---
#   Cycles: <N>
#   Ticks:  <N> (CLOCKS_PER_SEC=1000000)
#   Result: PASS|FAIL|TIMEOUT|ERROR
#
# Reference data: <repo>/.github/data/embench-m4-ref.json
#   Cortex-M4 @ 16 MHz baseline, in ms. Embench Score = geomean(speed_i)
#   where speed_i = ref_ms * 1000 / measured_cycles (cycle-normalised).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# SCRIPT_DIR = <repo>/fpga/litex/benchmarks/embench  -> 4 parents up = repo root
RAPTOR_HOME="$( cd "$SCRIPT_DIR/../../../.." && pwd )"
REF_JSON="$RAPTOR_HOME/.github/data/embench-m4-ref.json"

if [[ ! -f "$REF_JSON" ]]; then
    echo "[ERR] Missing reference file: $REF_JSON" >&2
    exit 1
fi

LOG_DIR="${1:-}"
if [[ -z "$LOG_DIR" || ! -d "$LOG_DIR" ]]; then
    echo "Usage: $0 <log-dir>" >&2
    exit 1
fi

RUN_CONFIG="$LOG_DIR/run-config.env"
if [[ ! -f "$RUN_CONFIG" ]]; then
    echo "[ERR] Missing run manifest: $RUN_CONFIG" >&2
    exit 1
fi

CANONICAL_BENCHES="aha-mont64 crc32 depthconv edn huffbench matmult-int md5sum \
nettle-aes nettle-sha256 nsichneu picojpeg qrduino sglib-combined slre \
statemate tarfind ud wikisort xgboost"

_manifest_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { sub(/\r$/, "", $2); print $2; exit }' "$RUN_CONFIG"
}

MANIFEST_VERSION=$(_manifest_value MANIFEST_VERSION)
if [[ "$MANIFEST_VERSION" != "2" ]]; then
    echo "[ERR] Unsupported run manifest version: ${MANIFEST_VERSION:-missing}" >&2
    exit 1
fi

NETTLE_SHA256_LOCAL_SCALE=$(_manifest_value NETTLE_SHA256_LOCAL_SCALE)
if [[ ! "$NETTLE_SHA256_LOCAL_SCALE" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERR] Invalid SHA-256 scale in run manifest: $RUN_CONFIG" >&2
    exit 1
fi
if [[ -n "${EMBENCH_NETTLE_SHA256_LOCAL_SCALE:-}" \
      && "$EMBENCH_NETTLE_SHA256_LOCAL_SCALE" != "$NETTLE_SHA256_LOCAL_SCALE" ]]; then
    echo "[ERR] SHA-256 scale override conflicts with run manifest: " \
         "$EMBENCH_NETTLE_SHA256_LOCAL_SCALE != $NETTLE_SHA256_LOCAL_SCALE" >&2
    exit 1
fi

# ----- helpers (awk) -----
_ref_ms() {
    # $1 = bench name  -> prints ms (float) or empty if unknown
    local name="$1"
    grep -oE "\"${name}\"[[:space:]]*:[[:space:]]*[0-9.]+" "$REF_JSON" \
        | head -n1 | grep -oE '[0-9.]+$' || true
}

# Aggregate in awk for geomean + average.
# Columns: benchmark | status | speed | cycles | ticks | ref_ms
tmp_rows="$(mktemp)"
selected_benches="$(mktemp)"
trap 'rm -f "$tmp_rows" "$selected_benches"' EXIT

awk -F= '$1 == "BENCH" { sub(/\r$/, "", $2); print $2 }' "$RUN_CONFIG" > "$selected_benches"
if [[ ! -s "$selected_benches" ]]; then
    echo "[ERR] Run manifest contains no benchmarks: $RUN_CONFIG" >&2
    exit 1
fi

selected_count=0
selected_names=""
while IFS= read -r name; do
    known=0
    for canonical_name in $CANONICAL_BENCHES; do
        if [[ "$name" == "$canonical_name" ]]; then
            known=1
            break
        fi
    done
    if (( ! known )); then
        echo "[ERR] Unknown benchmark in run manifest: $name" >&2
        exit 1
    fi
    for selected_name in $selected_names; do
        if [[ "$name" == "$selected_name" ]]; then
            echo "[ERR] Duplicate benchmark in run manifest: $name" >&2
            exit 1
        fi
    done
    selected_names="${selected_names:+$selected_names }$name"
    selected_count=$(( selected_count + 1 ))
done < "$selected_benches"

full_canonical_run=1
canonical_count=0
for canonical_name in $CANONICAL_BENCHES; do
    canonical_count=$(( canonical_count + 1 ))
    if ! grep -Fqx "$canonical_name" "$selected_benches"; then
        full_canonical_run=0
    fi
done
if (( selected_count != canonical_count )); then
    full_canonical_run=0
fi

echo "## Embench-IoT (Raptor LiteX SoC)"
echo ""
echo "| Benchmark | Status | Cycles | Ticks | Ref ms (M4@16MHz) | Speed (vs M4) |"
echo "|-----------|--------|-------:|------:|------------------:|--------------:|"

all_selected_pass=1
while IFS= read -r name; do
    log="$LOG_DIR/$name.log"
    cycles=""
    ticks=""
    status="MISSING"
    if [[ -f "$log" ]]; then
        cycles=$(grep -m1 -E '^Cycles:[[:space:]]*[0-9]+'       "$log" | grep -oE '[0-9]+' | head -n1 || true)
        ticks=$( grep -m1 -E '^Ticks:[[:space:]]*[0-9]+'        "$log" | grep -oE '[0-9]+' | head -n1 || true)
        status=$(grep -m1 -oE '^Result:[[:space:]]*(PASS|FAIL|TIMEOUT|ERROR)' "$log" | awk '{print $NF}' || true)
        [[ -n "$status" ]] || status="?"
    fi

    ref_ms=$(_ref_ms "$name")

    if [[ -n "$cycles" && -n "$ref_ms" && "$cycles" -gt 0 ]]; then
        speed=$(awk -v r="$ref_ms" -v c="$cycles" 'BEGIN{ printf "%.3f", r*1000.0/c }')
    else
        speed="N/A"
    fi

    score_excluded=0
    status_display="$status"
    if [[ "$name" == "nettle-sha256" && "$NETTLE_SHA256_LOCAL_SCALE" != "562" ]]; then
        score_excluded=1
        status_display="$status (smoke x${NETTLE_SHA256_LOCAL_SCALE})"
    fi

    if [[ "$status" != "PASS" || -z "$cycles" || -z "$ref_ms" || "$cycles" -le 0 ]]; then
        all_selected_pass=0
    fi

    printf "| %s | %s | %s | %s | %s | %s |\n" \
        "$name" "$status_display" "${cycles:-N/A}" "${ticks:-N/A}" "${ref_ms:-N/A}" "$speed"

    if [[ -n "$cycles" && -n "$ref_ms" && "$cycles" -gt 0 && "$status" == "PASS" && "$score_excluded" -eq 0 ]]; then
        echo "$name $cycles $ticks $ref_ms $speed" >> "$tmp_rows"
    fi
done < "$selected_benches"

echo ""

SCORE_TITLE="Partial Embench Score"
SCORE_SCOPE="selected workloads only"
SCORE_COUNT_LABEL="selected passing benchmarks"
if [[ "$NETTLE_SHA256_LOCAL_SCALE" != "562" ]]; then
    SCORE_SCOPE="selected canonical workloads; nettle-sha256 smoke excluded"
elif (( full_canonical_run )) && (( all_selected_pass )); then
    SCORE_TITLE="Embench Score"
    SCORE_SCOPE="geomean speed vs Cortex-M4@16MHz"
    SCORE_COUNT_LABEL="passing benchmarks"
elif (( full_canonical_run )); then
    SCORE_SCOPE="incomplete canonical workload set"
fi

# ---- Aggregates ----
awk -v score_title="$SCORE_TITLE" -v score_scope="$SCORE_SCOPE" -v score_count_label="$SCORE_COUNT_LABEL" '
BEGIN { n=0; sum_log=0; sum_cyc=0; sum_tick=0; sum_speed=0 }
{
    name=$1; cyc=$2+0; tick=$3+0; refms=$4+0; speed=$5+0;
    n++;
    sum_log  += log(speed);
    sum_cyc  += cyc;
    sum_tick += tick;
    sum_speed+= speed;
}
END {
    if (n==0) { print "_No passing benchmarks to aggregate._"; exit }
    score = exp(sum_log / n);
    avg_speed = sum_speed / n;
    printf "### Aggregate (%d %s)\n\n", n, score_count_label;
    printf "| Metric | Value |\n";
    printf "|--------|------:|\n";
    printf "| **%s** (%s) | **%.3f** |\n", score_title, score_scope, score;
    printf "| Arithmetic-mean speed | %.3f |\n", avg_speed;
    printf "| Total cycles | %d |\n", sum_cyc;
    printf "| Total ticks  | %d |\n", sum_tick;
}
' "$tmp_rows"

echo ""
if [[ "$NETTLE_SHA256_LOCAL_SCALE" != "562" ]]; then
    if grep -Fqx "nettle-sha256" "$selected_benches"; then
        echo "_nettle-sha256 ran at local scale ${NETTLE_SHA256_LOCAL_SCALE} instead of the canonical scale 562; it is a correctness smoke check and is excluded from the aggregate._"
    else
        echo "_The run uses SHA-256 local scale ${NETTLE_SHA256_LOCAL_SCALE}; it is not an official Embench score._"
    fi
    echo ""
fi
echo "_Score definition: for each benchmark speed_i = ref_ms × 1000 / measured_cycles;_"
echo "_Embench Score = geomean(speed_i). Reference ms from [.github/data/embench-m4-ref.json](../../../../.github/data/embench-m4-ref.json)._"
