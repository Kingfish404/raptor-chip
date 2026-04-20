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
#   Result: PASS|FAIL
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
trap 'rm -f "$tmp_rows"' EXIT

echo "## Embench-IoT (Raptor LiteX SoC)"
echo ""
echo "| Benchmark | Status | Cycles | Ticks | Ref ms (M4@16MHz) | Speed (vs M4) |"
echo "|-----------|--------|-------:|------:|------------------:|--------------:|"

for log in "$LOG_DIR"/*.log; do
    [[ -e "$log" ]] || continue
    name=$(basename "$log" .log)
    [[ "$name" == "summary" ]] && continue

    cycles=$(grep -m1 -E '^Cycles:[[:space:]]*[0-9]+'       "$log" | grep -oE '[0-9]+' | head -n1 || true)
    ticks=$( grep -m1 -E '^Ticks:[[:space:]]*[0-9]+'        "$log" | grep -oE '[0-9]+' | head -n1 || true)
    status=$(grep -m1 -oE '^Result:[[:space:]]*(PASS|FAIL)' "$log" | awk '{print $NF}' || true)
    [[ -z "$status" ]] && status="?"

    ref_ms=$(_ref_ms "$name")

    if [[ -n "$cycles" && -n "$ref_ms" && "$cycles" -gt 0 ]]; then
        speed=$(awk -v r="$ref_ms" -v c="$cycles" 'BEGIN{ printf "%.3f", r*1000.0/c }')
    else
        speed="N/A"
    fi

    printf "| %s | %s | %s | %s | %s | %s |\n" \
        "$name" "$status" "${cycles:-N/A}" "${ticks:-N/A}" "${ref_ms:-N/A}" "$speed"

    if [[ -n "$cycles" && -n "$ref_ms" && "$cycles" -gt 0 && "$status" == "PASS" ]]; then
        echo "$name $cycles $ticks $ref_ms $speed" >> "$tmp_rows"
    fi
done

echo ""

# ---- Aggregates ----
awk '
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
    printf "### Aggregate (%d passing benchmarks)\n\n", n;
    printf "| Metric | Value |\n";
    printf "|--------|------:|\n";
    printf "| **Embench Score** (geomean speed vs Cortex-M4@16MHz) | **%.3f** |\n", score;
    printf "| Arithmetic-mean speed | %.3f |\n", avg_speed;
    printf "| Total cycles | %d |\n", sum_cyc;
    printf "| Total ticks  | %d |\n", sum_tick;
}
' "$tmp_rows"

echo ""
echo "_Score definition: for each benchmark speed_i = ref_ms × 1000 / measured_cycles;_"
echo "_Embench Score = geomean(speed_i). Reference ms from [.github/data/embench-m4-ref.json](../../../../.github/data/embench-m4-ref.json)._"
