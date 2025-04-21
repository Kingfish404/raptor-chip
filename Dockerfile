FROM --platform=linux/amd64 homebrew/ubuntu24.04

RUN brew install verilator yosys mill
RUN sudo apt update && \
    sudo apt install -y \
    gcc g++ gcc-riscv64-linux-gnu g++-riscv64-linux-gnu \
    wget cmake curl llvm \
    tcl-dev tcl-tclreadline libeigen3-dev swig bison automake autotools-dev \
    libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev flex \
    libreadline-dev libncurses5-dev libncursesw5-dev device-tree-compiler

WORKDIR /app
RUN git clone https://github.com/Kingfish404/ysyx-workbench
WORKDIR /app/ysyx-workbench/
RUN git clone https://github.com/kingfish404/am-kernels && \
    git clone https://github.com/Kingfish404/riscv-arch-test-am && \
    git clone https://github.com/Kingfish404/ysyxSoC && \
    git clone https://github.com/Kingfish404/yosys-opensta

# setting environment variables
ENV YSYX_HOME=/app/ysyx-workbench
ENV NEMU_HOME=${YSYX_HOME}/nemu
ENV AM_HOME=${YSYX_HOME}/abstract-machine
ENV NPC_HOME=${YSYX_HOME}/npc
ENV NVBOARD_HOME=${YSYX_HOME}/nvboard
ENV NAVY_HOME=${YSYX_HOME}/navy-apps
ENV ISA=riscv32
ENV CROSS_COMPILE=riscv64-linux-gnu-

# Prepare STA env: https://github.com/parallaxsw/OpenSTA
WORKDIR /app/ysyx-workbench/yosys-opensta/
RUN make init && \
    wget https://raw.githubusercontent.com/davidkebo/cudd/main/cudd_versions/cudd-3.0.0.tar.gz && \
    tar -xvf cudd-3.0.0.tar.gz && \
    rm cudd-3.0.0.tar.gz
# Build CUDD
RUN cd cudd-3.0.0 && \
    mkdir ../cudd && \
    ./configure && \
    make -j`nproc`
# Get NANGATE45
RUN make init && git clone https://github.com/parallaxsw/OpenSTA.git

WORKDIR /app/ysyx-workbench/yosys-opensta/OpenSTA/
RUN cmake -DCUDD_DIR=../cudd-3.0.0 -B build . && cmake --build build -j`nproc`

WORKDIR /app/ysyx-workbench/npc/ssrc
RUN make verilog -j`nproc`

WORKDIR /app/ysyx-workbench/ysyxSoC
RUN git clone https://github.com/chipsalliance/rocket-chip.git && \
    make dev-init && \
    make verilog -j`nproc`

WORKDIR /app/ysyx-workbench/npc
RUN make o2_defconfig && \
    sed -i 's/-Werror//' Makefile && \
    sudo touch /usr/riscv64-linux-gnu/include/gnu/stubs-ilp32.h && \
    make -j`nproc` && \
    make sta_local
RUN make o2soc_defconfig && \
    make -j`nproc`

CMD ["bash"]