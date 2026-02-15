# Performance Iterations

Tracks microarchitecture changes and their impact on IPC, cycle count, and stall breakdown.

- **Benchmark**: `make coremark ARGS="-b -n"` and `make microbench ARGS="-b -n"` (RV32EM, npc standalone)
- **Config**: `ISSUE_WIDTH=1`, `ROB_SIZE=8`, `RS_SIZE=4`, `IOQ_SIZE=4`, `SQ_SIZE=4`, `PHY_SIZE=64`, `L1I: 4×8B`, `L1D: 4×8B`

## CoreMark

| Commit    | Change                  | #Cycle  | #Inst   | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| --------- | ----------------------- | ------- | ------- | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 8bd5a63a  | OoO baseline (PRF→top)  | 5918107 | 2993965 | 0.506 | 0, 0   | 1e6, 17   | 2e6, 35    | 9e4, 2 | 6e6,99 | 3e6, 49   |

## MicroBench

| Commit    | Change                  | #Cycle | #Inst  | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| --------- | ----------------------- | ------ | ------ | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 8bd5a63a  | OoO baseline (PRF→top)  | 606833 | 373461 | 0.615 | 0, 0   | 9e4, 14   | 3e5, 46    | 2e4, 3 | 6e5,99 | 2e5, 38   |

## Column Description

| Column    | Description |
| --------- | ----------- |
| Commit    | Short git hash |
| Change    | Brief description of the microarchitecture change |
| #Cycle    | Total simulation cycles |
| #Inst     | Total committed instructions |
| IPC       | Instructions per cycle |
| IFU, %    | Stall cycles from instruction fetch, percentage of total |
| EX\|RS, % | Stall cycles from reservation station (ALU/MUL), percentage |
| EX\|IoQ, %| Stall cycles from in-order queue (LSU/CSR), percentage |
| L1D, %    | Stall cycles from L1D cache misses, percentage |
| SQ, %     | Stall cycles from store queue, percentage |
| Bubble, % | Pipeline bubble cycles, percentage |
