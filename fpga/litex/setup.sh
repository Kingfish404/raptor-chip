#!/usr/bin/env bash
python3 -m venv .venv
source .venv/bin/activate
pip3 install ninja meson

if [ "$(uname)" == "Darwin" ]; then
    brew install json-c libevent
elif [ "$(uname)" == "Linux" ]; then
    sudo apt install -y libevent-dev libjson-c-dev
fi

make init
make update
make link
