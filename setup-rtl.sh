#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIBLE_VERSION="v0.0-4157-gfdbac312"

host_nproc() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

install_verible_linux() {
  local install_bin="$HOME/.local/bin"
  local installed_version=""
  if [ -x "$install_bin/verible-verilog-format" ]; then
    installed_version="$($install_bin/verible-verilog-format --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  fi
  if [ "$installed_version" = "$VERIBLE_VERSION" ]; then
    export PATH="$install_bin:$PATH"
    if [ -n "${GITHUB_PATH:-}" ]; then
      echo "$install_bin" >> "$GITHUB_PATH"
    fi
    return
  fi

  local arch sha256
  case "$(uname -m)" in
    x86_64 | amd64)
      arch=x86_64
      sha256=9e7ead54bc5efcc31476eb87dd970fe51314e8ca6bd00e0646e1ea6cde137448
      ;;
    aarch64 | arm64)
      arch=arm64
      sha256=e87ac5918115dc17e68bec8f32ed01901bfaeffb41c29daf5743bbd8d271d3a0
      ;;
    *)
      echo "Unsupported Linux architecture for Verible: $(uname -m)" >&2
      return 1
      ;;
  esac

  local archive_name="verible-${VERIBLE_VERSION}-linux-static-${arch}.tar.gz"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/raptor-chip"
  local archive="$cache_dir/$archive_name"
  local url="https://github.com/chipsalliance/verible/releases/download/${VERIBLE_VERSION}/${archive_name}"

  mkdir -p "$cache_dir" "$HOME/.local"
  if [ ! -f "$archive" ] || ! printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status; then
    echo "Downloading Verible ${VERIBLE_VERSION} for Linux ${arch}..."
    curl -fL --retry 3 --output "$archive" "$url"
  fi
  printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check
  tar -xzf "$archive" -C "$HOME/.local" --strip-components=1 "verible-${VERIBLE_VERSION}/bin"

  export PATH="$install_bin:$PATH"
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$install_bin" >> "$GITHUB_PATH"
  fi
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
    brew tap chipsalliance/verible
    brew trust --tap chipsalliance/verible
    brew_packages+=(verible gcc make cmake)
  else
    install_verible_linux
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
  if [ -d "$ROOT_DIR/hdl/generated" ] && [ "$(ls -A "$ROOT_DIR/hdl/generated" 2>/dev/null)" ]; then
    echo "hdl/generated/ exists, skipping Chisel verilog generation"
  else
    make -C "$ROOT_DIR/hdl/chisel" verilog -j"$(host_nproc)"
  fi
  make -C "$ROOT_DIR/sim" pack

  echo "RTL build environment setup complete."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_setup_rtl "$@"
fi
