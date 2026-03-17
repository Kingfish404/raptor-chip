# Performance Iterations

Tracks microarchitecture changes and their impact on IPC, cycle count, and stall breakdown.

- Benchmark: `make coremark-npc32 ARGS="-b -n"` and `make microbench-npc32 ARGS="-b -n"` (RV32EM, npc standalone)
- Config: `ISSUE_WIDTH=1`, `ROB_SIZE=8`, `RS_SIZE=4`, `IOQ_SIZE=4`, `SQ_SIZE=8`, `PHY_SIZE=64`, `L1I: 64×4w`, `L1D: 64×2w`

## Benchmark Results

### CoreMark
| Commit   | Change                  | #Cycle  | #Inst   | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| -------- | ----------------------- | ------- | ------- | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 8bd5a63a | OoO baseline (PRF→top)  | 5918107 | 2993965 | 0.506 | 0, 0   | 1e6, 17   | 2e6, 35    | 9e4, 2 | 6e6,99 | 3e6, 49   |
| 4190ade0 | SRAM pre-read [1]       | 6784901 | 2993965 | 0.441 | 0, 0   | 5e5, 8    | 2e6, 25    | 1e5, 1 | 7e6,99 | 4e6, 56   |
| a9ca5680 | SQ bypass + STL fwd [2] | 6753082 | 2993965 | 0.443 | 0, 0   | 4e5, 6    | 2e6, 22    | 1e5, 1 | 7e6,99 | 4e6, 56   |
| f14efbe6 | L1D 2w+RMW, TLB/PTW [3] | 6752062 | 2993966 | 0.443 | 0, 0   | 4e5, 6    | 2e6, 22    | 9e4, 1 | 7e6,99 | 4e6, 56   |
| (HEAD)   | L1I 4w, dual cm, SQ [4] | 4889011 | 2993938 | 0.612 | 2e6,34 | 5e5, 9    | 2e6, 31    | 9e4, 2 | 0e0, 0 | 2e6, 45   |

### MicroBench
| Commit   | Change                  | #Cycle | #Inst  | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| -------- | ----------------------- | ------ | ------ | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 8bd5a63a | OoO baseline (PRF→top)  | 606833 | 373461 | 0.615 | 0, 0   | 9e4, 14   | 3e5, 46    | 2e4, 3 | 6e5,99 | 2e5, 38   |
| 4190ade0 | SRAM pre-read [1]       | 749629 | 373461 | 0.498 | 0, 0   | 6e4, 8    | 2e5, 30    | 2e4, 3 | 7e5,99 | 4e5, 50   |
| a9ca5680 | SQ bypass + STL fwd [2] | 742618 | 373461 | 0.503 | 0, 0   | 4e4, 5    | 2e5, 27    | 2e4, 3 | 7e5,99 | 4e5, 50   |
| f14efbe6 | L1D 2w+RMW, TLB/PTW [3] | 740918 | 373462 | 0.504 | 0, 0   | 4e4, 5    | 2e5, 26    | 2e4, 2 | 7e5,99 | 4e5, 50   |
| (HEAD)   | L1I 4w, dual cm, SQ [4] | 627667 | 373462 | 0.595 | 2e5,34 | 4e4, 7    | 2e5, 31    | 2e4, 3 | 0e0, 0 | 3e5, 46   |

[1]: L1D hit latency reduced from 3 cycles to 2 cycles due to SRAM-based design, and L1I sequential fetch optimized to eliminate bubbles on hits.
[2]: SQ address-based bypass (loads only block on same-word address conflict instead of blanket `|sq_valid`). Fixed L1D `l1d_update` NBA priority bug. Store-to-load forwarding for full-word (SW) stores, age-ordered youngest-match-wins with STQ>SQ priority. Partial (SB/SH) stores still block conservatively.
[3]: L1D multi-word cache lines (2 words, banked SRAM), partial store Read-Modify-Write (RMW) instead of invalidation, TLB/PTW extracted into reusable modules (`ysyx_tlb.sv`, `ysyx_ptw.sv`). Difftest skip moved from bus-level to commit stage. L1D set count reduced from 128 to 64 (total capacity same: 64×2w = 128w). Store-to-load forwarding uses virtual address. `addr_cacheable()`/`addr_valid()` centralized in `ysyx_pkg`.
[4]: L1I line widened from 2w to 4w (reducing I-cache miss rate — L1I hit 97%, AMAT 1.2). Dual commit (`YSYX_DUAL_COMMIT`) retires up to 2 consecutive ROB entries/cycle (CoreMark 12.2%, MicroBench 10.0%). SQ stall eliminated (0%) — loads no longer block on store queue occupancy. Combined: CoreMark -1863k cycles (-27.6%, IPC 0.443→0.612), MicroBench -113k cycles (-15.3%, IPC 0.504→0.595). IFU stall now visible (34%) due to L1I miss latency becoming the dominant frontend bottleneck. BPU rate: CoreMark 90.5%, MicroBench 84.4%.

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
