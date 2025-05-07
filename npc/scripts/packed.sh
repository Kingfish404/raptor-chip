#!/bin/bash
if [ ! -f ysyx.sv ]; then
    echo "ysyx.sv not found"
    exit 1
fi
find . -maxdepth 1 ! -name "ysyx.sv" ! -name "ysyx_packed.sv" -name "*.sv" -o -name "*.svh" | sed 's|^\./||' | sort | awk '{print "`include \"" $0 "\""}' > ysyx_packed.sv
cat ysyx.sv >> ysyx_packed.sv
