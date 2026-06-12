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

pacman_install() {
  # Brew provides the latest toolchain (verilator, sbt, yosys, riscv64-elf-*,
  # openocd, dtc, libevent, json-c, ...) and is preferred for those.
  # Here we install only the system-level libraries brew does not ship on Linux.
  local aur_helper=""
  if command -v yay >/dev/null 2>&1; then
    aur_helper="yay"
  elif command -v paru >/dev/null 2>&1; then
    aur_helper="paru"
  fi

  # Official repo packages (sdl2-compat provides sdl2).
  sudo pacman -S --needed --noconfirm \
    base-devel git curl \
    riscv64-linux-gnu-gcc \
    sdl2-compat sdl2_image sdl2_ttf \
    readline ncurses \
    tcl eigen swig \
    autoconf automake

  # xxd is usually provided by vim/gvim; only pull tinyxxd if missing
  # (tinyxxd conflicts with vim, which already ships an xxd).
  command -v xxd >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm tinyxxd

  # AUR packages.
  #   riscv64-elf-picolibc: RISC-V cross picolibc matching riscv64-elf-gcc
  #     (equivalent to apt's picolibc-riscv64-unknown-elf; avoids building the
  #      x86 host BIOS that the generic 'picolibc' package fails on).
  #   tcllib: equivalent to apt's tcl-tclreadline support libraries.
  if [ -n "$aur_helper" ]; then
    "$aur_helper" -S --needed --noconfirm riscv64-elf-picolibc tcllib
  else
    echo "No AUR helper (yay/paru) found; please install 'riscv64-elf-picolibc' and 'tcllib' from the AUR manually."
  fi
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
  elif command -v pacman >/dev/null 2>&1; then
    echo "Arch-based Linux detected"
    sudo pacman -Sy --needed --noconfirm base-devel git curl
    pacman_install
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
