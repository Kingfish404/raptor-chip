#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host_nproc() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

brew_init() {
  # Check if Homebrew is installed
  if ! command -v brew &> /dev/null; then
    echo "Homebrew not found, installing..."
    # https://brew.sh/
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ "$(uname)" == "Linux" ]; then
      echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bash_profile
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
      if [ -f ~/.zshrc ]; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.zshrc
      fi
    else
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.bash_profile
      eval "$(/opt/homebrew/bin/brew shellenv)"
      if [ -f ~/.zshrc ]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
      fi
    fi
  else
    echo "Homebrew is already installed"
  fi

  local brew_packages=(verilator sbt asciidoctor)

  # On Linux, prefer the system build toolchain when it already exists.
  # Mixing Homebrew make with the runner's system gmake can break nested CMake builds.
  if [ "$(uname)" == "Darwin" ]; then
    brew_packages+=(gcc make cmake)
  else
    command -v gcc >/dev/null 2>&1 || brew_packages+=(gcc)
    command -v make >/dev/null 2>&1 || brew_packages+=(make)
    command -v cmake >/dev/null 2>&1 || brew_packages+=(cmake)
  fi

  brew install "${brew_packages[@]}"
}

clone_build_espresso() {
  mkdir -p "$ROOT_DIR/third_party"
  [ -d "$ROOT_DIR/third_party/espresso" ] || git clone --depth 1 https://github.com/chipsalliance/espresso "$ROOT_DIR/third_party/espresso"

  cmake -S "$ROOT_DIR/third_party/espresso" -B "$ROOT_DIR/third_party/espresso/build"
  cmake --build "$ROOT_DIR/third_party/espresso/build" -j"$(host_nproc)"
}

run_setup_rtl() {
  local step=0
  echo "Setting up RTL build environment..."

  step=$((step + 1))
  echo "Step $step: Initializing brew..."
  brew_init

  step=$((step + 1))
  echo "Step $step: Cloning/building espresso..."
  clone_build_espresso

  step=$((step + 1))
  echo "Step $step: Running RTL build pipeline..."
  source "$ROOT_DIR/env.sh"
  if [ -d "$ROOT_DIR/rtl_sv/generated" ] && [ "$(ls -A "$ROOT_DIR/rtl_sv/generated" 2>/dev/null)" ]; then
    echo "rtl_sv/generated/ exists, skipping Chisel verilog generation"
  else
    make -C "$ROOT_DIR/rtl_scala" verilog -j"$(host_nproc)"
  fi
  make -C "$ROOT_DIR/nsim" pack

  echo "RTL build environment setup complete."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_setup_rtl "$@"
fi
