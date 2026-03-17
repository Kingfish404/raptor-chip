#!/usr/bin/env bash
# Parse benchmark output and extract key metrics.
# Usage: parse-benchmark.sh <type> <log_file>
#   type: coremark | microbench | sta | ipc
#   log_file: path to the log file to parse
#
# Output: key=value pairs on stdout, one per line.

set -euo pipefail

TYPE="${1:-}"
LOG="${2:-}"

if [[ -z "$TYPE" || -z "$LOG" ]]; then
  echo "Usage: $0 <coremark|microbench|sta|ipc> <log_file>" >&2
  exit 1
fi

case "$TYPE" in
  coremark)
    # Extract: CoreMark PASS  <score>/1000 Marks  or  CoreMark PASS  <score> Marks
    SCORE=$(grep -oP 'CoreMark PASS\s+\K\d+' "$LOG" | head -1 || echo "N/A")
    IPC=$(grep -oP 'IPC:\s*\K[0-9.]+' "$LOG" | head -1 || echo "N/A")
    CYCLES=$(grep -oP 'cycle:\s*\K\d+' "$LOG" | head -1 || echo "N/A")
    INSTS=$(grep -oP '#inst:\s*\K\d+' "$LOG" | head -1 || echo "N/A")
    TRAP=$(grep -oE 'HIT (GOOD|BAD) TRAP|NPC QUIT' "$LOG" | head -1 || echo "UNKNOWN")
    echo "score=$SCORE"
    echo "ipc=$IPC"
    echo "cycles=$CYCLES"
    echo "insts=$INSTS"
    echo "trap=$TRAP"
    ;;
  microbench)
    # Extract: MicroBench PASS/FAIL and score
    RESULT=$(grep -oP 'MicroBench \K(PASS|FAIL)' "$LOG" | head -1 || echo "UNKNOWN")
    SCORE=$(grep -oP '\d+(?= Marks)' "$LOG" | tail -1 || echo "N/A")
    IPC=$(grep -oP 'IPC:\s*\K[0-9.]+' "$LOG" | head -1 || echo "N/A")
    CYCLES=$(grep -oP 'cycle:\s*\K\d+' "$LOG" | head -1 || echo "N/A")
    INSTS=$(grep -oP '#inst:\s*\K\d+' "$LOG" | head -1 || echo "N/A")
    TRAP=$(grep -oE 'HIT (GOOD|BAD) TRAP|NPC QUIT' "$LOG" | head -1 || echo "UNKNOWN")
    echo "result=$RESULT"
    echo "score=$SCORE"
    echo "ipc=$IPC"
    echo "cycles=$CYCLES"
    echo "insts=$INSTS"
    echo "trap=$TRAP"
    ;;
  sta)
    # Extract frequency: "core_clock period_min = 13.83 fmax = 72.28"
    FREQ=$(grep -oP 'fmax\s*=\s*\K[0-9.]+' "$LOG" | head -1 || echo "N/A")
    # Extract area: "Chip area for module '\ysyx': 533288.770000"
    AREA=$(grep -oP 'Chip area for module.*?:\s*\K[0-9.]+' "$LOG" | head -1 || echo "N/A")
    # Extract total power: "Total  2.67e+00  2.56e+00  1.23e-02  5.25e+00 100.0%"
    POWER=$(grep -oP '^Total\s+\S+\s+\S+\s+\S+\s+\K\S+' "$LOG" | head -1 || echo "N/A")
    echo "freq_mhz=$FREQ"
    echo "area=$AREA"
    echo "power=$POWER"
    ;;
  archtest)
    PASS=$(grep -c 'HIT GOOD TRAP' "$LOG" || echo "0")
    FAIL=$(grep -c 'HIT BAD TRAP' "$LOG" || echo "0")
    echo "pass=$PASS"
    echo "fail=$FAIL"
    ;;
  *)
    echo "Unknown type: $TYPE" >&2
    exit 1
    ;;
esac
