#!/usr/bin/env bash
# Build the pinned classic RISCOF reference with a full-access PMP precheck.
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: $0 WORK_DIR INSTALL_PREFIX" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy_patch="$script_dir/../riscof/sail/full-access-pmp-precheck.patch"
mkdir -p "$1" "$2"
work_dir="$(cd "$1" && pwd)"
install_prefix="$(cd "$2" && pwd)"

model_version=0.16
source_revision=e5acebb04ff573e93203596486b831a5974117c3
source_sha256=ed2a584601eb2961fde4dd17eb73695af46efa17a8042c50fa3179ddfaeb6ab2
compiler_version=0.20.3
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    compiler_platform=Linux-x86_64
    compiler_sha256=8d7cd75624ece407d7001ad32905a13ae111d5cc1a055404f21510e113207e3f
    ;;
  Linux-aarch64)
    compiler_platform=Linux-aarch64
    compiler_sha256=bdb1d68ca6b3a9eb74c409e42e54f71e77418debe3376dabdaabf3b6cd2bcf2d
    ;;
  *) echo "The pinned Sail compiler requires Linux x86_64 or aarch64." >&2; exit 2 ;;
esac

fetch() {
  local url="$1" archive="$2" digest="$3"
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 3 --connect-timeout 30 --max-time 600 \
      --output "$archive.partial" "$url"
    echo "$digest  $archive.partial" | sha256sum --check --strict
    mv "$archive.partial" "$archive"
  fi
  echo "$digest  $archive" | sha256sum --check --strict
}

mkdir -p "$work_dir/downloads"
compiler_archive="$work_dir/downloads/sail-$compiler_version-$compiler_platform.tar.gz"
fetch "https://github.com/rems-project/sail/releases/download/$compiler_version-binary/sail-$compiler_platform.tar.gz" \
  "$compiler_archive" "$compiler_sha256"
source_archive="$work_dir/downloads/sail-riscv-$source_revision.tar.gz"
fetch "https://codeload.github.com/riscv/sail-riscv/tar.gz/$source_revision" \
  "$source_archive" "$source_sha256"

compiler_dir="$work_dir/compiler-$compiler_version-$compiler_platform"
if [[ ! -x "$compiler_dir/bin/sail" ]]; then
  mkdir -p "$compiler_dir"
  tar -xzf "$compiler_archive" -C "$compiler_dir" --strip-components=1
fi
compiler_dir="$(cd "$compiler_dir" && pwd -P)"
# Sail invokes z3 by name; use the solver shipped in the verified compiler archive.
export PATH="$compiler_dir/bin:$PATH"

patch_sha256="$(sha256sum "$policy_patch" | cut -d ' ' -f 1)"
source_dir="$work_dir/source-${source_revision:0:12}-${patch_sha256:0:12}"
build_dir="$work_dir/build-${patch_sha256:0:12}"
if [[ ! -f "$source_dir/.raptor-policy-applied" ]]; then
  mkdir -p "$source_dir"
  tar -xzf "$source_archive" -C "$source_dir" --strip-components=1
  patch --batch --forward --directory="$source_dir" -p1 < "$policy_patch"
  printf '%s\n' "$patch_sha256" > "$source_dir/.raptor-policy-applied"
fi
source_dir="$(cd "$source_dir" && pwd -P)"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd -P)"

# Do not let upstream's git describe identify a containing Raptor checkout.
cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE \
  -DCMAKE_INSTALL_PREFIX="$install_prefix" -DSAIL_BIN="$compiler_dir/bin/sail" \
  -DDOWNLOAD_GMP=OFF -DFIRST_PARTY_TESTS=OFF -DENABLE_RISCV_TESTS=OFF
cmake --build "$build_dir" --target sail_riscv_sim --parallel "${JOBS:-2}"
cmake --install "$build_dir"
test "$("$install_prefix/bin/sail_riscv_sim" --version)" = "$model_version"
"$install_prefix/bin/sail_riscv_sim" --rv32 --validate-config
"$install_prefix/bin/sail_riscv_sim" --validate-config

python3 - "$install_prefix" "$model_version" "$source_revision" "$source_sha256" \
  "$compiler_version" "$compiler_sha256" "$patch_sha256" \
  "$("$compiler_dir/bin/z3" --version)" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

prefix = Path(sys.argv[1])
keys = ("model_version", "source_revision", "source_sha256", "compiler_version",
        "compiler_sha256", "patch_sha256", "solver_version")
record = dict(zip(keys, sys.argv[2:]))
binary = prefix / "bin/sail_riscv_sim"
record["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
record["cxx_compiler"] = subprocess.check_output(["c++", "--version"], text=True).splitlines()[0]
record["policy"] = "full-access PMP precheck; physical splitting and upstream default preserved"
manifest = prefix / "share/sail-riscv/raptor-reference.json"
manifest.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
print(manifest)
PY
