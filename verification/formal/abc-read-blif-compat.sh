#!/usr/bin/env bash
set -euo pipefail

script_file=""
args=()
while (($#)); do
  if [[ $1 == "-f" && $# -ge 2 ]]; then
    script_file=$2
    args+=("-f" "$2")
    shift 2
  else
    args+=("$1")
    shift
  fi
done

if [[ -z $script_file || ! -f $script_file ]]; then
  exec "${RAPTOR_ABC_REAL:-$(cd "$(dirname "$0")/../../third_party/oss-cad-suite/bin" && pwd)/yosys-abc}" "${args[@]}"
fi

compat_script=$(mktemp "${TMPDIR:-/tmp}/yosys-abc-compat.XXXXXX")
cleanup() { rm -f "$compat_script"; }
trap cleanup EXIT

sed 's/^read_blif /read_blif -n /' "$script_file" > "$compat_script"
for index in "${!args[@]}"; do
  if [[ ${args[$index]} == "$script_file" ]]; then
    args[$index]=$compat_script
  fi
done

exec "${RAPTOR_ABC_REAL:-$(cd "$(dirname "$0")/../../third_party/oss-cad-suite/bin" && pwd)/yosys-abc}" "${args[@]}"
