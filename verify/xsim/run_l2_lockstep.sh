#!/usr/bin/env bash
set -euo pipefail

# Usage: run_l2_lockstep.sh PREVIOUS_RAPT_L2_SV BUILD_DIR [32|64]
reference_source=$1
build_dir=$2
xlen=${3:-64}
tree=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$build_dir"
sed 's/^module rapt_l2 #(/module rapt_l2_reference #(/' "$reference_source" \
  > "$build_dir/rapt_l2_reference.sv"

defines=(-DRAPT_L2_EN)
if [[ $xlen == 64 ]]; then defines+=(-DRAPT_RV64); fi
mapfile -t rtl < <(find "$tree/hdl" -path "$tree/hdl/chisel" -prune -o \
  -name '*.sv' ! -path "$tree/hdl/rapt_pkg.sv" -print | sort)
library=()
for source in "${rtl[@]}"; do library+=(-v "$source"); done

verilator --binary --timing --assert -Wno-fatal -j 2 --timescale 1ns/1ps \
  --top-module tb_l2_lockstep "${defines[@]}" \
  -I"$tree/hdl/configs/default-l2" -I"$tree/hdl/include" \
  -I"$tree/hdl/include/dpic_mock" -I"$tree/hdl/include/npc" \
  -I"$tree/verify/xsim" "$tree/hdl/rapt_pkg.sv" "${library[@]}" \
  "$build_dir/rapt_l2_reference.sv" "$tree/verify/xsim/tb_l2_lockstep.sv" \
  --Mdir "$build_dir/obj" -o tb_l2_lockstep > "$build_dir/build.log" 2>&1

for seed in 1 2 3 4 5 6 7 8 9 10; do
  "$build_dir/obj/tb_l2_lockstep" "+seed=$seed" > "$build_dir/seed-$seed.log" 2>&1
  grep 'PASS: L2 lockstep' "$build_dir/seed-$seed.log"
done
