#!/usr/bin/env bash

set -euo pipefail

echo "Setting up build environment..."
step=0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/setup-rtl.sh"

brew_dep_install() {
  brew install yosys bazelisk ninja
  brew install riscv64-elf-binutils riscv64-elf-gcc open-ocd
  brew install ncurses readline flex bison
  if [ "$(uname)" == "Darwin" ]; then
    brew install sdl2 sdl2_image sdl2_ttf
  fi
  brew install dtc cmake automake
  brew install libevent json-c
}

apt_install() {
  sudo apt install -y gcc-riscv64-linux-gnu
  sudo apt install -y gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf
  sudo apt install -y libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev
  sudo apt install -y libreadline-dev libncurses5-dev
  sudo apt install -y tcl-dev tcl-tclreadline libeigen3-dev \
    swig autotools-dev libncursesw5-dev device-tree-compiler xxd
  sudo apt install -y libevent-dev libjson-c-dev
}

repo_clone() {
  mkdir -p third_party/NJU-ProjectN
  mkdir -p third_party/kingfish404
  [ -d abstract-machine/app/am-kernels ] || git clone --depth 1 https://github.com/kingfish404/am-kernels abstract-machine/app/am-kernels
  [ -d third_party/kingfish404/ysyxSoC ] || git clone --depth 1 https://github.com/Kingfish404/ysyxSoC third_party/kingfish404/ysyxSoC
  [ -d third_party/NJU-ProjectN/nvboard ] || git clone --depth 1 https://github.com/NJU-ProjectN/nvboard third_party/NJU-ProjectN/nvboard

  mkdir -p third_party/riscv-software-src/
  [ -d third_party/riscv-software-src/opensbi ] || git clone --depth 1 https://github.com/riscv-software-src/opensbi third_party/riscv-software-src/opensbi
  [ -d third_party/riscv-software-src/riscv-pk ] || git clone --depth 1 https://github.com/riscv-software-src/riscv-pk third_party/riscv-software-src/riscv-pk
}

repo_init() {
  make -C ./third_party/kingfish404/ysyxSoC/ dev-init verilog
}

if [ "$(uname)" == "Linux" ]; then
  echo "Linux detected"
  if command -v apt >/dev/null 2>&1; then
    echo "apt-based Linux detected"
    sudo apt update
    sudo apt install -y build-essential git curl
    apt_install
  else
    echo "Non-apt Linux detected, please install dependencies manually."
  fi
elif [ "$(uname)" == "Darwin" ]; then
  echo "macOS detected"
else
  echo "Unsupported OS, please install dependencies manually."
fi

step=$((step + 1))
echo "Step $step: Initializing brew..."
brew_init

step=$((step + 1))
echo "Step $step: Installing development tools..."
brew_dep_install

step=$((step + 1))
echo "Step $step: Running RTL setup pipeline..."
run_setup_rtl

step=$((step + 1))
echo "Step $step: Cloning repositories..."
repo_clone

echo "Step $step: Build environment setup complete."

# step=$((step + 1))
# repo_init
# echo "Step $step: Initializing Third-party Repositories..."
