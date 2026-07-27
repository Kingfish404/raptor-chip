#!/usr/bin/env bash
# Generate benchmark summary JSON and GitHub Job Summary markdown.
# Usage: generate-summary.sh <results_dir> <output_json> [github_step_summary]
#
# Reads parsed result files from <results_dir>/*.txt (key=value format)
# and produces:
#   1. A JSON file for shields.io endpoint badges
#   2. A markdown summary written to $GITHUB_STEP_SUMMARY (if available)

set -euo pipefail

RESULTS_DIR="${1:-.github/results}"
OUTPUT_JSON="${2:-.github/benchmark-results.json}"
STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-${3:-/dev/null}}"

# Helper: read a key from a results file
read_val() {
  local file="$1" key="$2" default="${3:-N/A}"
  if [[ -f "$file" ]]; then
    grep -oP "^${key}=\K.*" "$file" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

# Gather results
CM_RV32_SCORE=$(read_val "$RESULTS_DIR/coremark-rv32.txt" "score")
CM_RV32_IPC=$(read_val "$RESULTS_DIR/coremark-rv32.txt" "ipc")
CM_RV32_CYCLES=$(read_val "$RESULTS_DIR/coremark-rv32.txt" "cycles")
CM_RV32_INSTS=$(read_val "$RESULTS_DIR/coremark-rv32.txt" "insts")
CM_RV32_TRAP=$(read_val "$RESULTS_DIR/coremark-rv32.txt" "trap")

CM_RV32E_SCORE=$(read_val "$RESULTS_DIR/coremark-rv32e.txt" "score")
CM_RV32E_IPC=$(read_val "$RESULTS_DIR/coremark-rv32e.txt" "ipc")
CM_RV32E_TRAP=$(read_val "$RESULTS_DIR/coremark-rv32e.txt" "trap")

MB_RV32_RESULT=$(read_val "$RESULTS_DIR/microbench-rv32.txt" "result")
MB_RV32_SCORE=$(read_val "$RESULTS_DIR/microbench-rv32.txt" "score")
MB_RV32_IPC=$(read_val "$RESULTS_DIR/microbench-rv32.txt" "ipc")
MB_RV32_CYCLES=$(read_val "$RESULTS_DIR/microbench-rv32.txt" "cycles")
MB_RV32_INSTS=$(read_val "$RESULTS_DIR/microbench-rv32.txt" "insts")
MB_RV32_TRAP=$(read_val "$RESULTS_DIR/microbench-rv32.txt" "trap")

MB_RV32E_RESULT=$(read_val "$RESULTS_DIR/microbench-rv32e.txt" "result")
MB_RV32E_SCORE=$(read_val "$RESULTS_DIR/microbench-rv32e.txt" "score")
MB_RV32E_IPC=$(read_val "$RESULTS_DIR/microbench-rv32e.txt" "ipc")
MB_RV32E_TRAP=$(read_val "$RESULTS_DIR/microbench-rv32e.txt" "trap")

ARCHTEST_RV32_PASS=$(read_val "$RESULTS_DIR/archtest-rv32.txt" "pass" "0")
ARCHTEST_RV32_FAIL=$(read_val "$RESULTS_DIR/archtest-rv32.txt" "fail" "0")
ARCHTEST_RV32E_PASS=$(read_val "$RESULTS_DIR/archtest-rv32e.txt" "pass" "0")
ARCHTEST_RV32E_FAIL=$(read_val "$RESULTS_DIR/archtest-rv32e.txt" "fail" "0")

STA_FREQ=$(read_val "$RESULTS_DIR/sta.txt" "freq_mhz")
STA_AREA=$(read_val "$RESULTS_DIR/sta.txt" "area")
STA_POWER=$(read_val "$RESULTS_DIR/sta.txt" "power")
HAS_STA=0
if [[ -f "$RESULTS_DIR/sta.txt" ]]; then
  HAS_STA=1
fi

COMMIT_SHA="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')}"
COMMIT_SHORT="${COMMIT_SHA:0:8}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Helper: determine badge color from trap status
trap_color() {
  case "$1" in
    "HIT GOOD TRAP") echo "brightgreen" ;;
    "HIT BAD TRAP")  echo "red" ;;
    *)               echo "yellow" ;;
  esac
}

# Helper: result color
result_color() {
  case "$1" in
    "PASS") echo "brightgreen" ;;
    "FAIL") echo "red" ;;
    *)      echo "yellow" ;;
  esac
}

# Generate JSON for shields.io endpoint badges
mkdir -p "$(dirname "$OUTPUT_JSON")"
cat > "$OUTPUT_JSON" << ENDJSON
{
  "schemaVersion": 1,
  "updatedAt": "$TIMESTAMP",
  "commit": "$COMMIT_SHORT",
  "badges": {
    "coremark_ipc": {
      "schemaVersion": 1,
      "label": "CoreMark IPC",
      "message": "$CM_RV32_IPC",
      "color": "blue"
    },
    "coremark_score": {
      "schemaVersion": 1,
      "label": "CoreMark",
      "message": "${CM_RV32_SCORE} Marks",
      "color": "$(trap_color "$CM_RV32_TRAP")"
    },
    "microbench_ipc": {
      "schemaVersion": 1,
      "label": "MicroBench IPC",
      "message": "$MB_RV32_IPC",
      "color": "blue"
    },
    "microbench_score": {
      "schemaVersion": 1,
      "label": "MicroBench",
      "message": "${MB_RV32_SCORE} Marks",
      "color": "$(result_color "$MB_RV32_RESULT")"
    },
    "sta_freq": {
      "schemaVersion": 1,
      "label": "Fmax",
      "message": "${STA_FREQ} MHz",
      "color": "blue"
    },
    "sta_area": {
      "schemaVersion": 1,
      "label": "Area",
      "message": "$STA_AREA",
      "color": "blue"
    },
    "archtest": {
      "schemaVersion": 1,
      "label": "RISC-V Arch Test",
      "message": "${ARCHTEST_RV32_PASS} passed",
      "color": "$([ "$ARCHTEST_RV32_FAIL" = "0" ] && echo "brightgreen" || echo "red")"
    }
  },
  "results": {
    "coremark": {
      "rv32": {
        "score": "$CM_RV32_SCORE",
        "ipc": "$CM_RV32_IPC",
        "cycles": "$CM_RV32_CYCLES",
        "insts": "$CM_RV32_INSTS",
        "status": "$CM_RV32_TRAP"
      },
      "rv32e": {
        "score": "$CM_RV32E_SCORE",
        "ipc": "$CM_RV32E_IPC",
        "status": "$CM_RV32E_TRAP"
      }
    },
    "microbench": {
      "rv32": {
        "result": "$MB_RV32_RESULT",
        "score": "$MB_RV32_SCORE",
        "ipc": "$MB_RV32_IPC",
        "cycles": "$MB_RV32_CYCLES",
        "insts": "$MB_RV32_INSTS",
        "status": "$MB_RV32_TRAP"
      },
      "rv32e": {
        "result": "$MB_RV32E_RESULT",
        "score": "$MB_RV32E_SCORE",
        "ipc": "$MB_RV32E_IPC",
        "status": "$MB_RV32E_TRAP"
      }
    },
    "archtest": {
      "rv32": {
        "pass": "$ARCHTEST_RV32_PASS",
        "fail": "$ARCHTEST_RV32_FAIL"
      },
      "rv32e": {
        "pass": "$ARCHTEST_RV32E_PASS",
        "fail": "$ARCHTEST_RV32E_FAIL"
      }
    },
    "sta": {
      "freq_mhz": "$STA_FREQ",
      "area": "$STA_AREA",
      "power": "$STA_POWER"
    }
  }
}
ENDJSON

echo "Wrote results JSON to $OUTPUT_JSON"

# Generate GitHub Job Summary markdown
cat >> "$STEP_SUMMARY" << ENDMD

## Raptor Chip: Benchmark Results

> Commit: \`$COMMIT_SHORT\` | Updated: $TIMESTAMP

### Performance (rv32, standalone sim)

| Benchmark | Score | IPC | Cycles | Instructions | Status |
|-----------|-------|-----|--------|--------------|--------|
| CoreMark  | $CM_RV32_SCORE | $CM_RV32_IPC | $CM_RV32_CYCLES | $CM_RV32_INSTS | $CM_RV32_TRAP |
| MicroBench | $MB_RV32_SCORE | $MB_RV32_IPC | $MB_RV32_CYCLES | $MB_RV32_INSTS | $MB_RV32_TRAP |

### Performance (rv32e, standalone sim)

| Benchmark | Score | IPC | Status |
|-----------|-------|-----|--------|
| CoreMark  | $CM_RV32E_SCORE | $CM_RV32E_IPC | $CM_RV32E_TRAP |
| MicroBench | $MB_RV32E_SCORE | $MB_RV32E_IPC | $MB_RV32E_TRAP |

### RISC-V Architecture Tests

| Target | Passed | Failed |
|--------|--------|--------|
| rv32  | $ARCHTEST_RV32_PASS  | $ARCHTEST_RV32_FAIL  |
| rv32e | $ARCHTEST_RV32E_PASS | $ARCHTEST_RV32E_FAIL |

ENDMD

if [[ "$HAS_STA" == "1" ]]; then
  cat >> "$STEP_SUMMARY" << ENDMD
### PPA (Synthesis)

| Metric | Value |
|--------|-------|
| Fmax   | $STA_FREQ MHz |
| Area   | $STA_AREA |
| Power  | $STA_POWER W |

ENDMD
fi

echo "Wrote Job Summary to $STEP_SUMMARY"
