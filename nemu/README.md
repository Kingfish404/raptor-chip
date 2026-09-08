# NEMU

## Dev

```shell
# get trace with log for cpu-tests
$NEMU_HOME/build/riscv32-nemu-interpreter -b -f -l $NEMU_HOME/build/nemu-log.txt $RAPTOR_HOME/abstract-machine/app/am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin

# get trace with log for microbench
$NEMU_HOME/build/riscv32-nemu-interpreter -b -f -l $NEMU_HOME/build/nemu-log.txt $RAPTOR_HOME/abstract-machine/app/am-kernels/benchmarks/microbench/build/microbench-riscv32-npc.bin
```

## Introduction

NEMU(NJU Emulator) is a simple but complete full-system emulator designed for teaching purpose.
Currently it supports x86, mips32, riscv32 and riscv64.
To build programs run above NEMU, refer to the [AM project](https://github.com/NJU-ProjectN/abstract-machine).

The main features of NEMU include
* a small monitor with a simple debugger
  * single step
  * register/memory examination
  * expression evaluation without the support of symbols
  * watch point
  * differential testing with reference design (e.g. QEMU)
  * snapshot
* CPU core with support of most common used instructions
  * x86
    * real mode is not supported
    * x87 floating point instructions are not supported
  * mips32
    * CP1 floating point instructions are not supported
  * Raptor RISC-V reference profile
    * RV32/RV64 IMAFDC with M/S/U privilege modes
    * Zba, Zbb, Zbc, Zbs, Zcb, Zicond, Zicsr, Zifencei and Zimop
    * RVA22 additions used by the RTL: Zicbom/Zicbop/Zicboz, Zfhmin,
      Zihintpause, Zicntr/Zihpm, a 64-byte cache block, and Svade
    * the shipped RV32/RV64 defconfigs model the same `misa`, Sv32/Sv39
      translation behavior, CMO privilege controls, and counter CSR gating as
      the HDL
* memory
* paging
  * TLB is optional (but necessary for mips32)
  * protection is not supported
* interrupt and exception
  * protection is not supported
* devices
  * serial, timer, keyboard, VGA, audio, block storage, and SD card
  * virtio-mmio networking with unprivileged libslirp DHCP/DNS/NAT; enabled by
    default in the RV32GC and RV64GC Linux configurations
  * most of them are simplified and unprogrammable
* 2 types of I/O
  * port-mapped I/O and memory-mapped I/O

RV64 enables the existing RVA22S64 execution-environment support by default
(with F/D and Svade). Use `riscv64_ref_defconfig` for the shared reference,
with deterministic cycle-based counters, or `riscv64gc_linux_defconfig` for
the standalone Linux environment. Enabling this support is not a claim of
full RVA22S64 profile certification.

RV64 `satp.ASID` width is configured by `CONFIG_RV_ASID_BITS` (0–16).
Standalone configurations default to 16 bits, matching the classic Sail
reference. `riscv64_ref_defconfig` explicitly uses 9 bits to match Raptor RTL.

RV64 EBREAK and C.EBREAK raise guest breakpoint exceptions even in debug
builds. Legacy test payloads that use EBREAK to exit NEMU with the value in
a0 can explicitly enable `CONFIG_RV_EBREAK_HOST_EXIT` alongside `CONFIG_DEBUG`.
This compatibility option is independent of RVA22S64 support; RV32 debug
configurations retain it by default. Signature testing always uses guest
breakpoint exceptions.

The GC Linux configurations require the libslirp development package
(`libslirp-dev` on Debian/Ubuntu). The user-mode network needs no root or TAP
setup: DHCP assigns `10.0.2.15`, with gateway `10.0.2.2` and DNS `10.0.2.3`.
It provides outbound host/Internet access; unsolicited inbound connections are
not exposed.
