#!/usr/bin/env bash
echo "Setting up build environment..."
step=0

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
}

brew_install() {
  brew install verilator yosys mill
  brew install riscv64-elf-binutils riscv64-elf-gcc
  brew install ncurses readline flex bison
if [ "$(uname)" == "Darwin" ]; then
  brew install sdl2 sdl2_image sdl2_ttf
fi
  brew install gnu-sed wget dtc cmake automake
}

apt_install() {
  sudo apt install -y gcc-riscv64-linux-gnu
  sudo apt install -y libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev
  sudo apt install -y libreadline-dev libncurses5-dev
  sudo apt install -y tcl-dev tcl-tclreadline libeigen3-dev \
    swig autotools-dev libncursesw5-dev device-tree-compiler
}

repo_clone() {
  mkdir -p third_party/NJU-ProjectN
  git clone https://github.com/kingfish404/am-kernels
  git clone https://github.com/Kingfish404/ysyxSoC
  git clone https://github.com/NJU-ProjectN/nvboard third_party/NJU-ProjectN/nvboard

  mkdir -p third_party/riscv-software-src/
  git clone https://github.com/riscv-software-src/opensbi third_party/riscv-software-src/opensbi
}

repo_init() {
  cd ysyxSoC
  sed -i 's/git@github.com:/https:\/\/github.com\//' .git/config 
  make dev-init
  cd ..

  # generated from chisel (scala) at `npc/ssrc`
  cd ./npc/ssrc &&  make verilog && cd ../..
}

if [ "$(uname)" == "Linux" ]; then
  echo "Linux detected"
  # Check if the system is Ubuntu/Debian
  if [ -f /etc/os-release ]; then
    echo "Ubuntu/Debian detected"
    sudo apt update
    sudo apt install -y build-essential git curl gcc
    apt_install
  else
    echo "Non-Ubuntu Linux detected, please install dependencies manually."
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
brew_install

step=$((step + 1))
echo "Step $step: Cloning repositories..."
repo_clone

step=$((step + 1))
echo "Step $step: Initializing repositories..."
repo_init

step=$((step + 1))
source ./environment.env
make -C ./npc pack
echo "Step $step: Build environment setup complete."
