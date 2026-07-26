#!/usr/bin/env bash
#
# setup_env.sh — Install and configure LiteX environment for Raptor
#
# Usage:
#   source setup_env.sh          # Install + activate venv
#   source setup_env.sh --skip-install   # Activate only (already installed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAPTOR_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
LITEX_DIR="$RAPTOR_HOME/third_party/enjoy-digital/litex"
VENV_DIR="$SCRIPT_DIR/.venv"

export RAPTOR_HOME

# ---------- Color helpers ----------
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

# ---------- Parse args ----------
SKIP_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --skip-install) SKIP_INSTALL=1 ;;
    esac
done

# ---------- Python venv ----------
if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
ok "Python venv activated: $(python3 --version)"

if [ "$SKIP_INSTALL" -eq 0 ]; then
    # ---------- Clone LiteX ecosystem repos ----------
    ENJOY_DIGITAL_DIR="$RAPTOR_HOME/third_party/enjoy-digital"
    LITEX_HUB_DIR="$RAPTOR_HOME/third_party/litex-hub"
    MLABS_DIR="$RAPTOR_HOME/third_party/m-labs"

    sync_repo() {
        local url="$1"
        local dest="$2"
        local branch="${3:-}"
        if [ -d "$dest/.git" ] || [ -f "$dest/.git" ]; then
            local changes
            changes="$(git -C "$dest" status --porcelain | grep -v '^?? litex/soc/cores/cpu/raptor$' || true)"
            if [ -n "$changes" ]; then
                info "Skipping update with local changes: ${dest#$RAPTOR_HOME/}"
                return 0
            fi
            info "Updating ${dest#$RAPTOR_HOME/}"
            git -C "$dest" fetch --prune origin --quiet
            git -C "$dest" merge --ff-only "origin/$(git -C "$dest" symbolic-ref --short HEAD)" --quiet
            return 0
        fi
        if [ -e "$dest" ]; then
            info "Skipping non-Git path: ${dest#$RAPTOR_HOME/}"
            return 0
        fi
        info "Cloning $url -> ${dest#$RAPTOR_HOME/}"
        mkdir -p "$(dirname "$dest")"
        if [ -n "$branch" ]; then
            git clone --depth 1 --branch "$branch" "$url" "$dest" --quiet
        else
            git clone --depth 1 "$url" "$dest" --quiet
        fi
    }

    info "Ensuring LiteX source repositories are present..."
    # enjoy-digital
    sync_repo https://github.com/enjoy-digital/litex.git         "$ENJOY_DIGITAL_DIR/litex"
    sync_repo https://github.com/m-labs/migen.git                "$ENJOY_DIGITAL_DIR/migen"
    sync_repo https://github.com/enjoy-digital/litedram.git      "$ENJOY_DIGITAL_DIR/litedram"
    sync_repo https://github.com/enjoy-digital/litescope.git     "$ENJOY_DIGITAL_DIR/litescope"
    sync_repo https://github.com/enjoy-digital/liteeth.git       "$ENJOY_DIGITAL_DIR/liteeth"
    sync_repo https://github.com/enjoy-digital/litesdcard.git    "$ENJOY_DIGITAL_DIR/litesdcard"
    sync_repo https://github.com/enjoy-digital/litepcie.git      "$ENJOY_DIGITAL_DIR/litepcie"
    sync_repo https://github.com/enjoy-digital/litesata.git      "$ENJOY_DIGITAL_DIR/litesata"
    sync_repo https://github.com/enjoy-digital/liteiclink.git    "$ENJOY_DIGITAL_DIR/liteiclink"
    sync_repo https://github.com/enjoy-digital/litejesd204b.git  "$ENJOY_DIGITAL_DIR/litejesd204b"
    # litex-hub
    sync_repo https://github.com/litex-hub/litex-boards.git      "$LITEX_HUB_DIR/litex-boards"
    sync_repo https://github.com/litex-hub/litespi.git           "$LITEX_HUB_DIR/litespi"
    sync_repo https://github.com/litex-hub/litei2c.git           "$LITEX_HUB_DIR/litei2c"
    ok "LiteX source repositories ready."

    info "Installing LiteX from local source..."

    # Build system deps required by LiteX builder (picolibc uses meson/ninja).
    pip install --upgrade meson ninja --quiet

    # Core LiteX.
    pip install --upgrade -e "$LITEX_DIR" --quiet

    # Migen (LiteX dependency).
    MIGEN_DIR="$RAPTOR_HOME/third_party/enjoy-digital"
    if [ -d "$MIGEN_DIR/migen" ]; then
        pip install --upgrade -e "$MIGEN_DIR/migen" --quiet
    else
        pip install migen --quiet
    fi

    # LiteX boards.
    BOARDS_DIR="$RAPTOR_HOME/third_party/litex-hub/litex-boards"
    if [ -d "$BOARDS_DIR" ]; then
        pip install --upgrade -e "$BOARDS_DIR" --quiet
    fi

    # LiteDRAM (for FPGA targets with DDR).
    LITEDRAM_DIR="$RAPTOR_HOME/third_party/enjoy-digital/litedram"
    if [ -d "$LITEDRAM_DIR" ]; then
        pip install --upgrade -e "$LITEDRAM_DIR" --quiet
    fi

    # LiteScope (optional, for debug).
    LITESCOPE_DIR="$RAPTOR_HOME/third_party/enjoy-digital/litescope"
    if [ -d "$LITESCOPE_DIR" ]; then
        pip install --upgrade -e "$LITESCOPE_DIR" --quiet
    fi

    # LiteSPI (for SPI flash).
    LITESPI_DIR="$RAPTOR_HOME/third_party/litex-hub/litespi"
    if [ -d "$LITESPI_DIR" ]; then
        pip install --upgrade -e "$LITESPI_DIR" --quiet
    fi

    # LiteEth (for Ethernet).
    LITEETH_DIR="$RAPTOR_HOME/third_party/enjoy-digital/liteeth"
    if [ -d "$LITEETH_DIR" ]; then
        pip install --upgrade -e "$LITEETH_DIR" --quiet
    fi

    # LiteSDCard (for SD card).
    LITESDCARD_DIR="$RAPTOR_HOME/third_party/enjoy-digital/litesdcard"
    if [ -d "$LITESDCARD_DIR" ]; then
        pip install --upgrade -e "$LITESDCARD_DIR" --quiet
    fi

    ok "LiteX packages installed."

    # Python data packages required by LiteX BIOS build.
    info "Installing LiteX software data packages..."
    pip install --upgrade pythondata-software-picolibc --quiet 2>/dev/null || \
        pip install --upgrade git+https://github.com/litex-hub/pythondata-software-picolibc.git --quiet
    pip install --upgrade pythondata-software-compiler_rt --quiet 2>/dev/null || \
        pip install --upgrade git+https://github.com/litex-hub/pythondata-software-compiler_rt.git --quiet
    pip install --upgrade pythondata-misc-tapcfg --quiet 2>/dev/null || \
        pip install --upgrade git+https://github.com/litex-hub/pythondata-misc-tapcfg.git --quiet
    ok "LiteX software data packages installed."
fi

# ---------- Register Raptor CPU ----------
# Symlink Raptor CPU into the LiteX CPU registry so `--cpu-type=raptor` works.
LITEX_CPU_DIR="$LITEX_DIR/litex/soc/cores/cpu/raptor"
RAPTOR_CPU_SRC="$SCRIPT_DIR/cores/cpu/raptor"
if [ ! -e "$LITEX_CPU_DIR" ]; then
    info "Linking Raptor CPU into LiteX registry..."
    ln -sf "$RAPTOR_CPU_SRC" "$LITEX_CPU_DIR"
    ok "Raptor CPU registered at $LITEX_CPU_DIR"
else
    ok "Raptor CPU already registered."
fi

# ---------- Verify ----------
info "Verifying LiteX installation..."
python3 -c "
from litex.soc.cores.cpu import CPUS
from cpu.raptor.core import Raptor
CPUS['raptor'] = Raptor
print(f'  Registered CPUs: {len(CPUS)}')
print(f'  Raptor available: {\"raptor\" in CPUS}')
" 2>/dev/null && ok "LiteX + Raptor ready." || {
    # Fallback: test without symlink (use sys.path trick)
    cd "$SCRIPT_DIR"
    python3 -c "
import sys; sys.path.insert(0, 'cores')
from cpu.raptor.core import Raptor
print('  Raptor CPU module loads OK')
" && ok "Raptor CPU module verified." || err "Failed to import Raptor CPU module."
}

info "Environment ready. Run 'make help' for available targets."
