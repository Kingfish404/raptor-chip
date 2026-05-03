#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
NEMU_HOME="${ROOT_DIR}/nemu"
NSIM_HOME="${ROOT_DIR}/nsim"
HOST_OS="$(uname -s)"
RAPT_CFG_RAW="${RAPT_CONFIG:-default}"
RAPT_CFG_RAW="${RAPT_CFG_RAW%%#*}"
RAPT_CFG="$(echo "${RAPT_CFG_RAW}" | awk '{$1=$1;print}')"
if [[ -z "${RAPT_CFG}" ]]; then
  RAPT_CFG="default"
fi

NPROC="${NPROC:-$( (command -v nproc >/dev/null 2>&1 && nproc) || (command -v getconf >/dev/null 2>&1 && getconf _NPROCESSORS_ONLN) || (command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu) || echo 4)}"

NSIM_BUILD_DIR="${NSIM_HOME}/build/${RAPT_CFG}"
NEMU_DB="${NEMU_HOME}/build/compile_commands.json"
NSIM_DB="${NSIM_BUILD_DIR}/compile_commands.json"
ROOT_DB="${ROOT_DIR}/compile_commands.json"

pick_cmd() {
  local candidate resolved
  for candidate in "$@"; do
    [[ -n "${candidate}" ]] || continue
    if resolved="$(command -v "${candidate}" 2>/dev/null)"; then
      printf '%s\n' "${resolved}"
      return 0
    fi
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

die() {
  echo "[compile-commands] error: $*" >&2
  exit 1
}

INTERCEPT_BUILD_BIN="$(pick_cmd \
  "${INTERCEPT_BUILD:-}" \
  intercept-build \
  /opt/homebrew/opt/llvm/bin/intercept-build \
  /usr/local/opt/llvm/bin/intercept-build)" \
  || die "intercept-build not found"

# override-compiler mode needs intercept-cc/intercept-c++ in PATH.
if ! command -v intercept-cc >/dev/null 2>&1; then
  LLVM_PREFIX="$(cd "$(dirname "${INTERCEPT_BUILD_BIN}")/.." && pwd)"
  for extra_path in \
    "${LLVM_PREFIX}/libexec" \
    /opt/homebrew/opt/llvm/libexec \
    /usr/local/opt/llvm/libexec; do
    [[ -d "${extra_path}" ]] || continue
    export PATH="${extra_path}:${PATH}"
    command -v intercept-cc >/dev/null 2>&1 && break
  done
fi

command -v intercept-cc >/dev/null 2>&1 || die "intercept-cc not found in PATH"
command -v jq >/dev/null 2>&1 || die "jq not found"

if [[ "${HOST_OS}" == "Darwin" ]]; then
  CDB_CC_BIN="$(pick_cmd "${CDB_CC:-}" "${CC:-}" /usr/bin/clang clang gcc cc)" \
    || die "no usable C compiler found (try setting CDB_CC)"
  CDB_CXX_BIN="$(pick_cmd "${CDB_CXX:-}" "${CXX:-}" /usr/bin/clang++ clang++ g++ c++)" \
    || die "no usable C++ compiler found (try setting CDB_CXX)"
else
  CDB_CC_BIN="$(pick_cmd "${CDB_CC:-}" "${CC:-}" clang gcc cc)" \
    || die "no usable C compiler found (try setting CDB_CC)"
  CDB_CXX_BIN="$(pick_cmd "${CDB_CXX:-}" "${CXX:-}" clang++ g++ c++)" \
    || die "no usable C++ compiler found (try setting CDB_CXX)"
fi

mkdir -p "${NEMU_HOME}/build" "${NSIM_BUILD_DIR}"

echo "[compile-commands] Generating NEMU database..."
"${INTERCEPT_BUILD_BIN}" \
  --override-compiler \
  --use-cc "${CDB_CC_BIN}" \
  --use-c++ "${CDB_CXX_BIN}" \
  --cdb "${NEMU_DB}" \
  make -C "${NEMU_HOME}" -B -j"${NPROC}" CONFIG_CC=

echo "[compile-commands] Generating NSIM database..."
TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
NSIM_LOG="$(mktemp "${TMP_PARENT}/nsim-cdb.XXXXXX")"
make -C "${NSIM_HOME}" -B -j"${NPROC}" >"${NSIM_LOG}" 2>&1

# Verilator's nested build emits the real C++ compile lines in obj_dir.
awk -v objdir="${NSIM_BUILD_DIR}/obj_dir" '
  /^(c\+\+|clang\+\+|g\+\+)/ && / -c / {
    cmd = $0
    n = split(cmd, a, " ")
    file = ""
    for (i = n; i >= 1; i--) {
      if (a[i] ~ /\.(c|cc|cpp|cxx)$/) { file = a[i]; break }
    }
    if (file == "") next
    if (file ~ /^\//) f = file; else f = objdir "/" file
    gsub(/\\/, "\\\\", cmd)
    gsub(/\"/, "\\\"", cmd)
    printf("{\"directory\":\"%s\",\"file\":\"%s\",\"command\":\"%s\"}\n", objdir, f, cmd)
  }
' "${NSIM_LOG}" \
  | jq -s 'unique_by(.directory + "|" + .file + "|" + .command)' \
  > "${NSIM_DB}"
rm -f "${NSIM_LOG}"

echo "[compile-commands] Merging databases..."
jq -s '
  add
  | map(select(type == "object" and has("file") and has("directory") and has("command")))
  | unique_by(.directory + "|" + .file + "|" + .command)
' \
  "${NEMU_DB}" \
  "${NSIM_DB}" \
  > "${ROOT_DB}"

echo "[compile-commands] Done: ${ROOT_DB}"
