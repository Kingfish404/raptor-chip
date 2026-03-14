# Performance Iterations

Tracks microarchitecture changes and their impact on IPC, cycle count, and stall breakdown.

- Benchmark: `make coremark-npc32 ARGS="-b -n"` and `make microbench-npc32 ARGS="-b -n"` (RV32EM, npc standalone)
- Config: `ISSUE_WIDTH=1`, `ROB_SIZE=8`, `RS_SIZE=4`, `IOQ_SIZE=4`, `SQ_SIZE=4`, `PHY_SIZE=64`, `L1I: 4×8B`, `L1D: 4×8B`

## Benchmark Results

### CoreMark
| Commit   | Change                  | #Cycle  | #Inst   | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| -------- | ----------------------- | ------- | ------- | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 8bd5a63a | OoO baseline (PRF→top)  | 5918107 | 2993965 | 0.506 | 0, 0   | 1e6, 17   | 2e6, 35    | 9e4, 2 | 6e6,99 | 3e6, 49   |
| 4190ade0 | SRAM pre-read [1]       | 6784901 | 2993965 | 0.441 | 0, 0   | 5e5, 8    | 2e6, 25    | 1e5, 1 | 7e6,99 | 4e6, 56   |
| a9ca5680 | SQ bypass + STL fwd [2] | 6753082 | 2993965 | 0.443 | 0, 0   | 4e5, 6    | 2e6, 22    | 1e5, 1 | 7e6,99 | 4e6, 56   |

### MicroBench
| Commit   | Change                  | #Cycle | #Inst  | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| -------- | ----------------------- | ------ | ------ | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 8bd5a63a | OoO baseline (PRF→top)  | 606833 | 373461 | 0.615 | 0, 0   | 9e4, 14   | 3e5, 46    | 2e4, 3 | 6e5,99 | 2e5, 38   |
| 4190ade0 | SRAM pre-read [1]       | 749629 | 373461 | 0.498 | 0, 0   | 6e4, 8    | 2e5, 30    | 2e4, 3 | 7e5,99 | 4e5, 50   |
| a9ca5680 | SQ bypass + STL fwd [2] | 742618 | 373461 | 0.503 | 0, 0   | 4e4, 5    | 2e5, 27    | 2e4, 3 | 7e5,99 | 4e5, 50   |

[1]: L1D hit latency reduced from 3 cycles to 2 cycles due to SRAM-based design, and L1I sequential fetch optimized to eliminate bubbles on hits.
[2]: SQ address-based bypass (loads only block on same-word address conflict instead of blanket `|sq_valid`). Fixed L1D `l1d_update` NBA priority bug. Store-to-load forwarding for full-word (SW) stores, age-ordered youngest-match-wins with STQ>SQ priority. Partial (SB/SH) stores still block conservatively.

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
