# Performance Iterations

Tracks microarchitecture changes and their impact on IPC, cycle count, and stall breakdown.

- Benchmark: `make coremark-npc32 ARGS="-b -n"` and `make microbench-npc32 ARGS="-b -n"` (RV32EM, npc standalone)
- Config: `ISSUE_WIDTH=2` (dual-issue), `ROB_SIZE=8`, `RS_SIZE=4`, `IOQ_SIZE=4`, `SQ_SIZE=8`, `PHY_SIZE=64`, `L1I: 64x4w 1-way`, `L1D: 32x2w 2-way`

## Benchmark Results

### CoreMark
| Commit  | Change                  | #Cycle  | #Inst   | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| ------- | ----------------------- | ------- | ------- | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 1245810 | OoO baseline (PRF->top) | 5918107 | 2993965 | 0.506 | 0, 0   | 1e6, 17   | 2e6, 35    | 9e4, 2 | 6e6,99 | 3e6, 49   |
| a9ca568 | SRAM pre-read [1]       | 6784901 | 2993965 | 0.441 | 0, 0   | 5e5, 8    | 2e6, 25    | 1e5, 1 | 7e6,99 | 4e6, 56   |
| 40e3c86 | SQ bypass + STL fwd [2] | 6753082 | 2993965 | 0.443 | 0, 0   | 4e5, 6    | 2e6, 22    | 1e5, 1 | 7e6,99 | 4e6, 56   |
| f14efbe | L1D 2w+RMW, TLB/PTW [3] | 6752062 | 2993966 | 0.443 | 0, 0   | 4e5, 6    | 2e6, 22    | 9e4, 1 | 7e6,99 | 4e6, 56   |
| 2529b49 | L1I 4w, dual cm, SQ [4] | 4889011 | 2993938 | 0.612 | 2e6,34 | 5e5, 9    | 2e6, 31    | 9e4, 2 | 0e0, 0 | 2e6, 45   |
| 905735e | Pipe, BPU infra [5]     | 4910725 | 2996919 | 0.610 | 2e6,34 | 5e5,10    | 2e6, 31    | 1e5, 2 | 0e0, 0 | 2e6, 46   |
| a71d54b | Dual fetch/decode [6]   | 3718623 | 2903330 | 0.781 | 9e5,23 | 7e5,19    | 2e6, 42    | 1e5, 3 | 0e0, 0 | 2e6, 43   |
| ce2f2a1 | Zba/Zbb/Zbs+Zicond [7]  | 3678424 | 2860965 | 0.778 | 8e5,21 | 7e5,19    | 2e6, 42    | 1e5, 3 | 0e0, 0 | 2e6, 44   |

### MicroBench
| Commit  | Change                  | #Cycle | #Inst  | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| ------- | ----------------------- | ------ | ------ | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 1245810 | OoO baseline (PRF->top) | 606833 | 373461 | 0.615 | 0, 0   | 9e4, 14   | 3e5, 46    | 2e4, 3 | 6e5,99 | 2e5, 38   |
| a9ca568 | SRAM pre-read [1]       | 749629 | 373461 | 0.498 | 0, 0   | 6e4, 8    | 2e5, 30    | 2e4, 3 | 7e5,99 | 4e5, 50   |
| 40e3c86 | SQ bypass + STL fwd [2] | 742618 | 373461 | 0.503 | 0, 0   | 4e4, 5    | 2e5, 27    | 2e4, 3 | 7e5,99 | 4e5, 50   |
| f14efbe | L1D 2w+RMW, TLB/PTW [3] | 740918 | 373462 | 0.504 | 0, 0   | 4e4, 5    | 2e5, 26    | 2e4, 2 | 7e5,99 | 4e5, 50   |
| 2529b49 | L1I 4w, dual cm, SQ [4] | 627667 | 373462 | 0.595 | 2e5,34 | 4e4, 7    | 2e5, 31    | 2e4, 3 | 0e0, 0 | 3e5, 46   |
| 905735e | Pipe, BPU infra [5]     | 637357 | 373461 | 0.586 | 2e5,34 | 4e4, 7    | 2e5, 31    | 1e4, 2 | 0e0, 0 | 3e5, 47   |
| a71d54b | Dual fetch/decode [6]   | 506854 | 364937 | 0.720 | 1e5,27 | 6e4,12    | 2e5, 46    | 1e4, 3 | 2e4, 3 | 2e5, 47   |
| ce2f2a1 | Zba/Zbb/Zbs+Zicond [7]  | 501128 | 340182 | 0.679 | 1e5,25 | 7e4,13    | 2e5, 44    | 1e4, 3 | 2e4, 4 | 2e5, 49   |

[1]: L1D hit latency reduced from 3 cycles to 2 cycles due to SRAM-based design, and L1I sequential fetch optimized to eliminate bubbles on hits.
[2]: SQ address-based bypass (loads only block on same-word address conflict instead of blanket `|sq_valid`). Fixed L1D `l1d_update` NBA priority bug. Store-to-load forwarding for full-word (SW) stores, age-ordered youngest-match-wins with STQ>SQ priority. Partial (SB/SH) stores still block conservatively.
[3]: L1D multi-word cache lines (2 words, banked SRAM), partial store Read-Modify-Write (RMW) instead of invalidation, TLB/PTW extracted into reusable modules (`ysyx_tlb.sv`, `ysyx_ptw.sv`). Difftest skip moved from bus-level to commit stage. L1D set count reduced from 128 to 64 (total capacity same: 64x2w = 128w). Store-to-load forwarding uses virtual address. `addr_cacheable()`/`addr_valid()` centralized in `ysyx_pkg`.
[4]: L1I line widened from 2w to 4w (reducing I-cache miss rate -- L1I hit 97%, AMAT 1.2). Dual commit (`YSYX_DUAL_COMMIT`) retires up to 2 consecutive ROB entries/cycle (CoreMark 12.2%, MicroBench 10.0%). SQ stall eliminated (0%) -- loads no longer block on store queue occupancy. Combined: CoreMark -1863k cycles (-27.6%, IPC 0.443->0.612), MicroBench -113k cycles (-15.3%, IPC 0.504->0.595). IFU stall now visible (34%) due to L1I miss latency becoming the dominant frontend bottleneck. BPU rate: CoreMark 90.5%, MicroBench 84.4%.
[5]: Timing-oriented refactoring (IPC-neutral, targets critical path reduction for frequency). BPU: PHT/BTB sub-modules with `(* keep_hierarchy *)` to isolate registered read ports from `pc_ifu` fanout; BTB upgraded to 2-way set-associative (128 entries = 64 sets x 2 ways). IFU: pre-registered sequential PC (`seq2`/`seq4`) replaces combinational adder on critical path. RNU: 2-stage rename pipeline register (maptable+freelist read -> registered output to ROU). ROU: UOQ operand pre-read at enqueue with broadcast forwarding during residence, eliminating PRF read from dispatch critical path. EXU: RS priority encoding via `casez` one-hot vectors (replaces for-loop). MUL: hybrid fast multiply (2-cycle pipeline) + iterative restoring divider (removes combinational divider). BPU rate: CoreMark 90.5->92.4%, MicroBench 84.4->85.1%. IDU early resteer + BPU infrastructure. IDU sends `resteer` pulse to IFU when BPU predicts taken on a non-branch instruction (BTB alias), redirecting fetch at decode stage (~2 cycle penalty vs ~5-7 at commit). CMU derives `call`/`ret`/`rvc` from committed instruction word via `cmu_bcast_if`. BPU: RSB committed data maintained (push on call, pop on ret, speculative pointer with flush recovery), JALR added to `wen_entry` (BTB entry creation on first misprediction), BTB `wen_type` guarded to only update matching or newly-created entries. RSB prediction and gshare PHT indexing prepared but disabled: 512-entry PHT too small for gshare (destructive aliasing), RSB regresses due to 7-bit BTB tag aliasing. Both ready to enable when BTB/PHT capacity increases. IPC-neutral on current benchmarks.
[6]: Generalized dual-fetch from C+C only to all combinations: C+C, C+R32, R32+C, R32+R32. IDU slot B now decodes both C-type and R32 instructions. L1I provides `inst_n1` (next 4-byte-aligned word) via 3-tier SRAM pre-read for assembling slot B. Fixed latent EXU multiplier bug: added `mul_target_idx` to ensure multiply results deliver only to the originating RS entry. Combined: CoreMark -1192k cycles (-24.3%, IPC 0.610->0.781), MicroBench -131k cycles (-20.5%, IPC 0.586->0.720). Dual commit: CoreMark 37.2%, MicroBench 35.2%. #Inst decreased slightly (~3%) due to fewer total instructions executed (fewer misspeculated instructions from improved fetch). BPU rate: CoreMark 90.5%, MicroBench 79.9%.
[7]: Added RISC-V Zba (address generation: sh{1,2,3}add), Zbb (basic bit-manipulation: clz/ctz/cpop/min/max/rotate/sext/orc.b/rev8), Zbs (single-bit: bset/bclr/bext/binv), and Zicond (conditional operations: czero.eqz/czero.nez) extensions. ALU opcode expanded from 5->6 bits (32->64 operations). Compiler flags updated to `-march=rv32imac_..._zicond_zba_zbb_zbs`, allowing GCC to emit bitmanip and conditional-zero instructions. Zicond eliminates short conditional branches by converting simple if-else patterns into branchless `czero` sequences, avoiding the ~8-cycle misprediction penalty. Instruction count reduced (CoreMark -1.5%, MicroBench -6.8%) as multi-instruction sequences are replaced by single bitmanip/conditional ops. CoreMark cycles -1.1% (IPC 0.781->0.778), MicroBench cycles -1.1% (IPC 0.720->0.679). BPU rate: CoreMark 90.5%, MicroBench 80.0%. Dual commit: CoreMark 38.8%, MicroBench 33.7%.

### Column Description

| Column     | Description                                                 |
| ---------- | ----------------------------------------------------------- |
| Commit     | Short git hash                                              |
| Change     | Brief description of the microarchitecture change           |
| #Cycle     | Total simulation cycles                                     |
| #Inst      | Total committed instructions                                |
| IPC        | Instructions per cycle                                      |
| IFU, %     | Stall cycles from instruction fetch, percentage of total    |
| EX\|RS, %  | Stall cycles from reservation station (ALU/MUL), percentage |
| EX\|IoQ, % | Stall cycles from in-order queue (LSU/CSR), percentage      |
| L1D, %     | Stall cycles from L1D cache misses, percentage              |
| SQ, %      | Stall cycles from store queue, percentage                   |
| Bubble, %  | Pipeline bubble cycles, percentage                          |
