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
CM_NPC_SCORE=$(read_val "$RESULTS_DIR/coremark-npc.txt" "score")
CM_NPC_IPC=$(read_val "$RESULTS_DIR/coremark-npc.txt" "ipc")
CM_NPC_CYCLES=$(read_val "$RESULTS_DIR/coremark-npc.txt" "cycles")
CM_NPC_INSTS=$(read_val "$RESULTS_DIR/coremark-npc.txt" "insts")
CM_NPC_TRAP=$(read_val "$RESULTS_DIR/coremark-npc.txt" "trap")

CM_NPCE_SCORE=$(read_val "$RESULTS_DIR/coremark-npce.txt" "score")
CM_NPCE_IPC=$(read_val "$RESULTS_DIR/coremark-npce.txt" "ipc")
CM_NPCE_TRAP=$(read_val "$RESULTS_DIR/coremark-npce.txt" "trap")

MB_NPC_RESULT=$(read_val "$RESULTS_DIR/microbench-npc.txt" "result")
MB_NPC_SCORE=$(read_val "$RESULTS_DIR/microbench-npc.txt" "score")
MB_NPC_IPC=$(read_val "$RESULTS_DIR/microbench-npc.txt" "ipc")
MB_NPC_CYCLES=$(read_val "$RESULTS_DIR/microbench-npc.txt" "cycles")
MB_NPC_INSTS=$(read_val "$RESULTS_DIR/microbench-npc.txt" "insts")
MB_NPC_TRAP=$(read_val "$RESULTS_DIR/microbench-npc.txt" "trap")

MB_NPCE_RESULT=$(read_val "$RESULTS_DIR/microbench-npce.txt" "result")
MB_NPCE_SCORE=$(read_val "$RESULTS_DIR/microbench-npce.txt" "score")
MB_NPCE_IPC=$(read_val "$RESULTS_DIR/microbench-npce.txt" "ipc")
MB_NPCE_TRAP=$(read_val "$RESULTS_DIR/microbench-npce.txt" "trap")

ARCHTEST_NPC_PASS=$(read_val "$RESULTS_DIR/archtest-npc.txt" "pass" "0")
ARCHTEST_NPC_FAIL=$(read_val "$RESULTS_DIR/archtest-npc.txt" "fail" "0")
ARCHTEST_NPCE_PASS=$(read_val "$RESULTS_DIR/archtest-npce.txt" "pass" "0")
ARCHTEST_NPCE_FAIL=$(read_val "$RESULTS_DIR/archtest-npce.txt" "fail" "0")

STA_FREQ=$(read_val "$RESULTS_DIR/sta.txt" "freq_mhz")
STA_AREA=$(read_val "$RESULTS_DIR/sta.txt" "area")
STA_POWER=$(read_val "$RESULTS_DIR/sta.txt" "power")

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
      "message": "$CM_NPC_IPC",
      "color": "blue"
    },
    "coremark_score": {
      "schemaVersion": 1,
      "label": "CoreMark",
      "message": "${CM_NPC_SCORE} Marks",
      "color": "$(trap_color "$CM_NPC_TRAP")"
    },
    "microbench_ipc": {
      "schemaVersion": 1,
      "label": "MicroBench IPC",
      "message": "$MB_NPC_IPC",
      "color": "blue"
    },
    "microbench_score": {
      "schemaVersion": 1,
      "label": "MicroBench",
      "message": "${MB_NPC_SCORE} Marks",
      "color": "$(result_color "$MB_NPC_RESULT")"
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
      "message": "${ARCHTEST_NPC_PASS} passed",
      "color": "$([ "$ARCHTEST_NPC_FAIL" = "0" ] && echo "brightgreen" || echo "red")"
    }
  },
  "results": {
    "coremark": {
      "riscv32-npc": {
        "score": "$CM_NPC_SCORE",
        "ipc": "$CM_NPC_IPC",
        "cycles": "$CM_NPC_CYCLES",
        "insts": "$CM_NPC_INSTS",
        "status": "$CM_NPC_TRAP"
      },
      "riscv32e-npc": {
        "score": "$CM_NPCE_SCORE",
        "ipc": "$CM_NPCE_IPC",
        "status": "$CM_NPCE_TRAP"
      }
    },
    "microbench": {
      "riscv32-npc": {
        "result": "$MB_NPC_RESULT",
        "score": "$MB_NPC_SCORE",
        "ipc": "$MB_NPC_IPC",
        "cycles": "$MB_NPC_CYCLES",
        "insts": "$MB_NPC_INSTS",
        "status": "$MB_NPC_TRAP"
      },
      "riscv32e-npc": {
        "result": "$MB_NPCE_RESULT",
        "score": "$MB_NPCE_SCORE",
        "ipc": "$MB_NPCE_IPC",
        "status": "$MB_NPCE_TRAP"
      }
    },
    "archtest": {
      "riscv32-npc": {
        "pass": "$ARCHTEST_NPC_PASS",
        "fail": "$ARCHTEST_NPC_FAIL"
      },
      "riscv32e-npc": {
        "pass": "$ARCHTEST_NPCE_PASS",
        "fail": "$ARCHTEST_NPCE_FAIL"
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

## 🏆 Raptor Chip — Benchmark Results

> Commit: \`$COMMIT_SHORT\` | Updated: $TIMESTAMP

### Performance (riscv32-npc, standalone)

| Benchmark | Score | IPC | Cycles | Instructions | Status |
|-----------|-------|-----|--------|--------------|--------|
| CoreMark  | $CM_NPC_SCORE | $CM_NPC_IPC | $CM_NPC_CYCLES | $CM_NPC_INSTS | $CM_NPC_TRAP |
| MicroBench | $MB_NPC_SCORE | $MB_NPC_IPC | $MB_NPC_CYCLES | $MB_NPC_INSTS | $MB_NPC_TRAP |

### Performance (riscv32e-npc, standalone)

| Benchmark | Score | IPC | Status |
|-----------|-------|-----|--------|
| CoreMark  | $CM_NPCE_SCORE | $CM_NPCE_IPC | $CM_NPCE_TRAP |
| MicroBench | $MB_NPCE_SCORE | $MB_NPCE_IPC | $MB_NPCE_TRAP |

### RISC-V Architecture Tests

| Target | Passed | Failed |
|--------|--------|--------|
| riscv32-npc  | $ARCHTEST_NPC_PASS  | $ARCHTEST_NPC_FAIL  |
| riscv32e-npc | $ARCHTEST_NPCE_PASS | $ARCHTEST_NPCE_FAIL |

### PPA (Synthesis)

| Metric | Value |
|--------|-------|
| Fmax   | $STA_FREQ MHz |
| Area   | $STA_AREA |
| Power  | $STA_POWER W |

ENDMD

echo "Wrote Job Summary to $STEP_SUMMARY"
