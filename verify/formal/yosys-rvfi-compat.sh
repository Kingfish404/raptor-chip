#!/usr/bin/env bash
set -euo pipefail

script_file=""
args=()
while (($#)); do
  args+=("$1")
  if [[ $1 != -* && $1 == *design_aiger.ys ]]; then
    script_file=$1
  fi
  shift
done

real_yosys="${RAPTOR_YOSYS_REAL:-$(cd "$(dirname "$0")/../../third_party/oss-cad-suite/bin" && pwd)/yosys}"
if [[ -z $script_file || ! -f $script_file ]]; then
  exec "$real_yosys" "${args[@]}"
fi

script_dir=$(cd "$(dirname "$script_file")" && pwd)
compat_script=$(mktemp "$script_dir/.design_aiger.compat.XXXXXX.ys")
cleanup() { rm -f "$compat_script"; }
trap cleanup EXIT

abc_wrapper=$(cd "$(dirname "$0")" && pwd)/abc-read-blif-compat.sh
/usr/bin/awk -v abc_wrapper="$abc_wrapper" \
  '{ if ($0 == "abc -g AND -fast") print "abc -exe " abc_wrapper " -g AND -fast"; else print }' \
  "$script_file" > "$compat_script"
for index in "${!args[@]}"; do
  if [[ ${args[$index]} == "$script_file" ]]; then
    args[$index]=$compat_script
  fi
done

exec "$real_yosys" "${args[@]}"
