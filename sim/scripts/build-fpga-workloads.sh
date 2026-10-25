#!/usr/bin/env bash
# Build local evaluation workloads; leave host scheduling to the caller.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  cat <<'HELP'
Usage: build-fpga-workloads.sh TREE memprobe|pagefault|embench [MEMPROBE_VARIANT]
Memprobe variants: full, full-matched, quick (default), quick-matched, store, store-matched.
EVAL_CAL_DIR defaults to TREE/sim/build/fpga-eval; EVAL_BUILD_ROOT relocates objects.
MEMPROBE_STEPS overrides access counts; EMBENCH_SOURCE selects local Embench source.
No simulator build or source download is performed.
HELP
  exit 0
fi
tree=$(realpath "${1:-$script_dir/../..}")
workload=${2:?Select memprobe, pagefault, or embench}
cal_dir=$(realpath -m "${EVAL_CAL_DIR:-$tree/sim/build/fpga-eval}")
job_dir=$(realpath -m "${EVAL_BUILD_ROOT:-$cal_dir/build}")
out_dir=$cal_dir/img/$workload-rv64
mkdir -p "$job_dir" "$out_dir"
export RAPTOR_HOME=$tree NEMU_HOME=$tree/nemu NSIM_HOME=$tree/sim
export AM_HOME=$tree/abstract-machine CROSS_COMPILE=${CROSS_COMPILE:-riscv64-elf-}
# AM libraries are shared within a tree. Lock the tree, independent of output paths.
exec 9>"$tree/abstract-machine/.fpga-workloads.lock"
flock 9
build=(make -C "$tree/app/benchmarks/$workload" -j4
  HDL_FORMAT_SOURCES= ALL_SV_FORMAT_SOURCES=)
case "$workload" in
  memprobe)
    variant=${3:-quick}
    quick=0 matched=0 store_only=0 steps=65536
    case "$variant" in
      full) suffix= ;;
      full-matched) matched=1; suffix=-matched ;;
      quick) quick=1; steps=8192; suffix=-quick ;;
      quick-matched) quick=1; matched=1; steps=8192; suffix=-quick-matched ;;
      store) store_only=1; steps=8192; suffix=-store ;;
      store-matched) store_only=1; matched=1; steps=8192; suffix=-store-matched ;;
      *) echo "Unknown memprobe variant: $variant" >&2; exit 2 ;;
    esac
    steps=${MEMPROBE_STEPS:-$steps}
    build+=(ARCH=riscv64-npc "MEMPROBE_QUICK=$quick" "MEMPROBE_STEPS=$steps"
      "MEMPROBE_MATCH_BOARD=$matched" "MEMPROBE_STORE_ONLY=$store_only"
      "DST_DIR=$job_dir/memprobe-$variant-$steps-obj"
      "IMAGE=$out_dir/memprobe$suffix-riscv64-npc")
    ;;
  pagefault) build+=("OUT=$out_dir") ;;
  embench)
    source_dir=${EMBENCH_SOURCE:-$tree/app/build/src/embench-iot}
    [[ -f "$source_dir/support/main.c" ]] || {
      printf 'Missing local Embench source: %s\n' "$source_dir" >&2; exit 1;
    }
    mkdir -p "$job_dir/embench/source"
    cp -a "$source_dir/src" "$source_dir/support" "$source_dir/COPYING" \
      "$job_dir/embench/source/"
    build+=(baremetal-build ISA64=1 "EMBENCH_DIR=$job_dir/embench/source"
      "BARE_BUILD_DIR=$job_dir/embench/objects")
    ;;
  *) echo "Unknown workload: $workload" >&2; exit 2 ;;
esac
"${build[@]}" > "$out_dir/build.log" 2>&1
if [[ $workload == embench ]]; then
  python3 - "$script_dir/../tools" "$job_dir/embench" "$out_dir" <<'PY'
import hashlib
from pathlib import Path
import shutil
import sys
sys.path.insert(0, sys.argv[1])
from fpga_eval_summary import BENCHMARKS
build, out = map(Path, sys.argv[2:])
for name in BENCHMARKS:
    shutil.copy2(build / 'objects' / name / (name + '.bin'), out / (name + '.bin'))
shutil.copy2(build / 'objects/.build-config', out / 'build-config.txt')
source = build / 'source'
rows = [f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(source)}'
        for p in sorted(source.rglob('*')) if p.is_file()]
(out / 'source-SHA256SUMS').write_text('\n'.join(rows) + '\n')
PY
fi
(cd "$out_dir" && sha256sum -- *.bin > SHA256SUMS)
printf 'Built %s images in %s\n' "$workload" "$out_dir"
