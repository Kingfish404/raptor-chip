#!/usr/bin/env bash
set -euo pipefail

# The legacy parser can reject large flattened BLIF files. Keep ABC's native
# parser by default; older tool distributions can explicitly select legacy.
parser="${RAPTOR_ABC_BLIF_PARSER:-default}"
case "$parser" in
  default) ;;
  legacy) ;;
  *) echo "ERROR: RAPTOR_ABC_BLIF_PARSER must be default or legacy" >&2; exit 2 ;;
esac

abc_path="${RAPTOR_ABC_REAL:-}"
if [[ -z $abc_path ]]; then
  tools_bin=$(cd "$(dirname "$0")/../../third_party/oss-cad-suite/bin" && pwd)
  abc_path="$tools_bin/yosys-abc"
fi

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

if [[ $parser == default || -z $script_file || ! -f $script_file ]]; then
  exec "$abc_path" "${args[@]}"
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

# Return through this shell so its EXIT trap removes the temporary script.
"$abc_path" "${args[@]}"
