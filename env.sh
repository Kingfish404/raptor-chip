if [ "${BASH_SOURCE-}" = "$0" ]; then
    echo "You must source this script: \$ source $0" >&2
    exit 1
fi

if [ -n "${ZSH_VERSION-}" ] ; then
    env_dir="$(dirname "$0")"
else
    env_dir="$(dirname "${BASH_SOURCE[0]}")"
fi

BASE_DIR=$(cd "$env_dir" && pwd)
echo "BASE_DIR => $BASE_DIR"

export RAPTOR_HOME=$BASE_DIR

export NEMU_HOME=$RAPTOR_HOME/nemu
export NSIM_HOME=$RAPTOR_HOME/nsim

export AM_HOME=$RAPTOR_HOME/abstract-machine
export NAVY_HOME=$RAPTOR_HOME/abstract-machine/app/navy-apps
export NVBOARD_HOME=$RAPTOR_HOME/third_party/NJU-ProjectN/nvboard

export CROSS_COMPILE=riscv64-elf-

echo "CROSS_COMPILE set to: $CROSS_COMPILE"
