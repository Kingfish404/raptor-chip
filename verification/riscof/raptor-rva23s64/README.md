# Raptor RVA23S64 ACT4 + Sail 0.16 Self-Checking Compliance

This directory provides the full **RVA23S64** (plus `Smstateen`, `Smnpm`,
`Svvptc`, and `Zbc`) upstream ACT4 + Sail `0.16` self-checking compliance
configuration for Raptor.

## Covered Extensions

- Unprivileged base & integer/FP: `I`, `M`/`Zmmul`, `A` (`Zaamo`, `Zalrsc`),
  `F`, `D`, `Zfa`, `Zfhmin`, `C` (`Zca`, `Zcd`, `Zcb`, `Zcmop`),
  `B` (`Zba`, `Zbb`, `Zbs`, `Zbc`), `Zicond`, `Zimop`, `Zihintntl`,
  `Zihintpause`, `Zicbom`, `Zicbop`, `Zicboz`, `Zic64b`, `Zicclsm`, `Zicntr`,
  `Zihpm`, `Zicsr`, `Zifencei`, `Zawrs`, `Zkt`.
- Vector (`VLEN=128`, `ELEN=64`): `V` (`Vx`, `Vf`, `Vls`, `ExceptionsV*`,
  `MisalignV`, privileged `VS`/`FS` state transitions), `Zvbb`, `Zvkb`,
  `Zvfhmin`, `Zvkt`.
- Privileged & Hypervisor: `Sm` (1.13), `S` (1.13), `U`, `H`, `Sha`
  (`Shcounterenw`, `Shgatpa`, `Shtvala`, `Shvsatpa`, `Shvstvala`, `Shvstvecd`),
  `Sv39`, `Svbare`, `Svade`, `Svpbmt`, `Svnapot`, `Svinval`, `Svvptc`,
  `Smstateen`, `Ssstateen`, `Sscofpmf` (`mhpmcounter3`/`mhpmevent3`,
  `EV_FENCE`), `Sstc`, `Smnpm`, `Ssnpm`, `Supm`, `PMP` (8 usable entries,
  4 KiB granularity, full-access precheck).

## Usage

```sh
make -C verification riscof ISA=rv64
```

To run sharded compliance (as used in GitHub Actions CI):

```sh
make -C verification riscof-gen ISA=rv64
python3 verification/scripts/run_act4.py --trap-on-ebreak \
  --shard-index 0 --shard-count 4 \
  --npc-bin sim/build/default-act4-rv64/riscv64-npc-sim \
  --mrom-img sim/csrc/mem/mrom-data/build/mrom-data.bin \
  verification/build/riscof/raptor-rva23s64/elfs
```
