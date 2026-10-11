#!/usr/bin/env bash
# CI installs only the tools used by its job. Local ./setup.sh remains complete.
set -euo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$CI_ROOT/setup-rtl.sh"
cd "$CI_ROOT"

install_tools() {
  local profile="$1"
  local apt_packages=(build-essential git curl cmake pkg-config flex bison
    libreadline-dev libncurses-dev zlib1g-dev liblz4-dev ccache)
  local brew_packages=()
  case "$profile" in
    build)
      brew_packages+=(verilator sbt)
      ;;
    sim | litex)
      apt_packages+=(gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf
        device-tree-compiler xxd libsdl2-dev)
      brew_packages+=(verilator sbt riscv64-elf-binutils riscv64-elf-gcc)
      if [[ "$profile" == litex ]]; then
        apt_packages+=(python3-venv python3-dev libevent-dev libjson-c-dev libslirp-dev)
      fi
      ;;
    riscof)
      # Workers execute an already built simulator and compile guest programs.
      apt_packages+=(device-tree-compiler xxd)
      brew_packages+=(riscv64-elf-binutils riscv64-elf-gcc)
      ;;
    sta)
      # OpenSTA needs FlexLexer.h. Ubuntu's flex only recommends libfl-dev;
      # --no-install-recommends below deliberately omits that implicit install.
      apt_packages+=(libfl-dev tcl-dev tcl-tclreadline libeigen3-dev libfmt-dev swig)
      brew_packages+=(yosys verilator sbt)
      ;;
    nemu)
      apt_packages+=(gcc-riscv64-linux-gnu device-tree-compiler xxd libsdl2-dev)
      ;;
    *) echo "Unknown CI profile: $profile" >&2; return 2 ;;
  esac
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "${apt_packages[@]}"
  if (( ${#brew_packages[@]} )); then
    brew_bootstrap
    brew install "${brew_packages[@]}"
    if [[ -n "${GITHUB_PATH:-}" ]]; then
      brew --prefix | while IFS= read -r prefix; do
        printf '%s/bin\n%s/sbin\n' "$prefix" "$prefix" >> "$GITHUB_PATH"
      done
    fi
  fi
}

prepare_decoders() {
  local cached="$1"
  if [[ "$cached" == true ]]; then
    # Only the exact content-keyed decoder cache is accepted. Checkouts have
    # newer mtimes than cached files; refresh outputs after validating the hit
    # so sim/Makefile does not invoke sbt again in every consumer.
    test -s hdl/generated/rapt_idu_decoder.sv
    test -s hdl/generated/rapt_idu_decoder_c.sv
    touch hdl/generated/rapt_idu_decoder{,_c}.sv
  else
    clone_build_espresso
    make -C hdl/chisel verilog
  fi
}

clone_workloads() {
  local profile="$1"
  case "$profile" in
    sim)
      [[ -d abstract-machine/app/am-kernels ]] ||
        git clone --depth 1 https://github.com/kingfish404/am-kernels abstract-machine/app/am-kernels
      mkdir -p third_party/riscv-software-src
      [[ -d third_party/riscv-software-src/riscv-pk ]] ||
        git clone --depth 1 https://github.com/riscv-software-src/riscv-pk third_party/riscv-software-src/riscv-pk
      ;;
    nemu)
      mkdir -p third_party/riscv-software-src
      [[ -d third_party/riscv-software-src/opensbi ]] ||
        git clone --depth 1 https://github.com/riscv-software-src/opensbi third_party/riscv-software-src/opensbi
      ;;
    build | sta | litex | riscof) ;;
    *) echo "Unknown CI profile: $profile" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    tools) install_tools "${2:?profile required}" ;;
    decoders) prepare_decoders "${2:-false}" ;;
    workloads) clone_workloads "${2:?profile required}" ;;
    *) echo "Usage: $0 {tools PROFILE|decoders CACHE_HIT|workloads PROFILE}" >&2; exit 2 ;;
  esac
fi
