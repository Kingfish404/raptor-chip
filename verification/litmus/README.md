# RVWMO Litmus & Memory Ordering Verification

This directory provides Raptor Chip's RVWMO (RISC-V Weak Memory Ordering) litmus
and coherence regression suite.

## Coverage

1. **Single-hart OoO & Store-Queue Coherence (`generate`)**:
   - `co_wr_same`, `co_wr_mixed_subword`, `rv64_co_wr_dw_mixed`: Store-to-load
     forwarding across aligned and overlapping sub-word widths.
   - `co_ww_order`, `co_rw_rr`: Per-location coherence (`CoWW`, `CoRW`, `CoRR`).
   - `sq_flush_no_leak`: Speculative store isolation across mispredicted branches.
   - `sq_deep_drain`: Store-queue capacity saturation and FIFO drain ordering.
   - `fence_rw_rw`, `fence_tso`, `fence_i_smc`: Memory fences and instruction
     fetch coherence.
   - `lr_sc_reservation`, `lr_sc_aqrl`, `amo_aqrl_chain`: Atomic reservation and
     acquire/release ordering.
   - `ppo_addr_dep`, `ppo_data_dep`, `ppo_ctrl_dep`: RVWMO Preserved Program Order
     dependencies.

2. **Multi-hart `herd7` `.litmus` Export (`export-herd7`)**:
   - Exports standard `MP+fence.rw.rw`, `SB+fence.rw.rw`, `LB+addr+data`,
     `IRIW+fence.rw.rw`, and `2+2W+fence.rw.rw` litmus tests compatible with
     `herd7 -model riscv.cat` and `litmus7`.

## Usage

```sh
python3 verification/litmus/rvwmo_litmus.py generate --xlen 64 --outdir /tmp/raptor-litmus-rv64
python3 verification/litmus/rvwmo_litmus.py export-herd7 --outdir /tmp/raptor-litmus-herd7
```
