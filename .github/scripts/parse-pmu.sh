#!/usr/bin/env bash
# Extract PMU performance counters from simulation logs and output markdown.
# Usage: parse-pmu.sh <label> <log_file> [<label> <log_file> ...]
# Output: Collapsible <details> markdown blocks to stdout.
#         If no PMU data found in a log, that entry is silently skipped.

set -euo pipefail

while [[ $# -ge 2 ]]; do
  LABEL="$1"
  LOG="$2"
  shift 2

  if [[ ! -f "$LOG" ]]; then
    continue
  fi

  # Extract lines emitted by pmu.cc (perf counters and statistics)
  PMU_LINES=$(grep -E 'pmu\.cc:[0-9]+ (perf|statistic) ' "$LOG" 2>/dev/null || true)

  if [[ -z "$PMU_LINES" ]]; then
    continue
  fi

  # Strip the "pmu.cc:NNN perf " / "pmu.cc:NNN statistic " prefix for readability
  CLEAN=$(echo "$PMU_LINES" | sed -E 's/pmu\.cc:[0-9]+ (perf|statistic) //')

  echo "<details>"
  echo "<summary>PMU Details: $LABEL</summary>"
  echo ""
  echo '```'
  echo "$CLEAN"
  echo '```'
  echo "</details>"
  echo ""
done
