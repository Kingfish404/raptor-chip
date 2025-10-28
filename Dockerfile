FROM --platform=linux/amd64 homebrew/ubuntu24.04:latest

WORKDIR /workspaces
RUN git clone https://github.com/Kingfish404/raptor-chip
WORKDIR /workspaces/raptor-chip/
RUN chmod +x ./setup.sh && ./setup.sh
RUN git clone https://github.com/Kingfish404/riscv-arch-test-am && \
    git clone https://github.com/Kingfish404/yosys-opensta third_party/yosys-opensta

# setting environment variables
ENV YSYX_HOME=/workspaces/raptor-chip/
ENV NEMU_HOME=${YSYX_HOME}/nemu
ENV AM_HOME=${YSYX_HOME}/abstract-machine
ENV NAVY_HOME=${YSYX_HOME}/navy-apps
ENV NVBOARD_HOME=${YSYX_HOME}/third_party/NJU-ProjectN/nvboard
ENV ISA=riscv32
ENV CROSS_COMPILE=riscv64-elf-

RUN make -C ./rtl_scala verilog -j`nproc`

WORKDIR /workspaces/raptor-chip/nemu/tools/capstone
RUN make
WORKDIR /workspaces/raptor-chip/nemu
RUN make riscv32_ref_defconfig && make -j`nproc`
WORKDIR /workspaces/raptor-chip/nsim
RUN make o2_defconfig && sed -i 's/-Werror//' Makefile
# RUN make o2soc_defconfig && make -j`nproc`
# waiting for mill support

# Prepare STA env: https://github.com/parallaxsw/OpenSTA
WORKDIR /workspaces/raptor-chip/third_party/yosys-opensta/
RUN wget https://raw.githubusercontent.com/davidkebo/cudd/main/cudd_versions/cudd-3.0.0.tar.gz && \
    tar -xvf cudd-3.0.0.tar.gz && \
    rm cudd-3.0.0.tar.gz
# Build CUDD
RUN cd cudd-3.0.0 && \
    mkdir ../cudd && \
    ./configure && \
    make -j`nproc`
# Get NANGATE45
RUN make init && git clone https://github.com/parallaxsw/OpenSTA.git

WORKDIR /workspaces/raptor-chip/third_party/yosys-opensta/OpenSTA/
RUN cmake -DCUDD_DIR=../cudd-3.0.0 -B build . && cmake --build build -j`nproc`

RUN git clone --recursive https://github.com/povik/yosys-slang \
    && cd yosys-slang && make -j`nproc` && make install

WORKDIR /workspaces/raptor-chip/nemu
RUN make riscv32_linux_defconfig && make -j

WORKDIR /workspaces/raptor-chip/nsim
RUN make o2_defconfig && make -j`nproc`
# RUN make sta_local

CMD ["bash"]
