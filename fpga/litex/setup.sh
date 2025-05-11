#!/usr/bin/env bash
python3 -m venv venv
brew install json-c libevent
source ./venv/bin/activate
pip3 install ninja meson

if [ "$(uname)" == "Linux" ]; then
    sudo apt install -y libevent-dev libjson-c-dev
fi

make update