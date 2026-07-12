# Performance Iterations

Legacy Version: [PROFILE.md](./PROFILE.md)

Tracks microarchitecture changes and their impact on IPC, cycle count, and stall breakdown.

- Benchmark: `make coremark-npc32 ARGS="-b -n"` and `make microbench-npc32 ARGS="-b -n"` (RV32EM, npc standalone)
- Config: unless a row or footnote says otherwise, benchmark rows use the dual-issue NPC path. Current default RTL/config is `ISSUE_WIDTH=2`, `ROB_SIZE=64`, `RS_SIZE=8`, `RIQ/IIQ=8`, `IOQ_SIZE=8`, `SQ_SIZE=16`, `PHY_SIZE=128`, `L1I: 32 sets × 16 instruction words × 2 ways` (4 KiB, 64-byte lines), `L1D: 16 sets × 16 RV32 words / 8 RV64 words × 2 ways` (2 KiB, 64-byte lines), TAGE direction predictor, and `RAPT_L2_EN` disabled by default (the instantiated L2 stage is passthrough unless that macro is defined).

## Benchmark Results

### CoreMark

| Commit  | Change                  | #Cycle   | #Inst    | IPC   | IFU, % | EX\|RS, % | EX\|IoQ, % | L1D, % | SQ, %  | Bubble, % |
| ------- | ----------------------- | -------- | -------- | ----- | ------ | --------- | ---------- | ------ | ------ | --------- |
| 1245810 | OoO baseline (PRF->top) | 5918107  | 2993965  | 0.506 | 0, 0   | 1e6, 17   | 2e6, 35    | 9e4, 2 | 6e6,99 | 3e6, 49   |
| a9ca568 | SRAM pre-read [1]       | 6784901  | 2993965  | 0.441 | 0, 0   | 5e5, 8    | 2e6, 25    | 1e5, 1 | 7e6,99 | 4e6, 56   |
| 40e3c86 | SQ bypass + STL fwd [2] | 6753082  | 2993965  | 0.443 | 0, 0   | 4e5, 6    | 2e6, 22    | 1e5, 1 | 7e6,99 | 4e6, 56   |
| f14efbe | L1D 2w+RMW, TLB/PTW [3] | 6752062  | 2993966  | 0.443 | 0, 0   | 4e5, 6    | 2e6, 22    | 9e4, 1 | 7e6,99 | 4e6, 56   |
| 2529b49 | L1I 4w, dual cm, SQ [4] | 4889011  | 2993938  | 0.612 | 2e6,34 | 5e5, 9    | 2e6, 31    | 9e4, 2 | 0e0, 0 | 2e6, 45   |
| 905735e | Pipe, BPU infra [5]     | 4910725  | 2996919  | 0.610 | 2e6,34 | 5e5,10    | 2e6, 31    | 1e5, 2 | 0e0, 0 | 2e6, 46   |
| a71d54b | Dual fetch/decode [6]   | 3718623  | 2903330  | 0.781 | 9e5,23 | 7e5,19    | 2e6, 42    | 1e5, 3 | 0e0, 0 | 2e6, 43   |
| ce2f2a1 | Zba/Zbb/Zbs+Zicond [7]  | 3678424  | 2860965  | 0.778 | 8e5,21 | 7e5,19    | 2e6, 42    | 1e5, 3 | 0e0, 0 | 2e6, 44   |
| e913241 | Zbc + ROB fix [8]       | 3681752  | 2860946  | 0.777 | 8e5,21 | 7e5,19    | 2e6, 42    | 1e5, 3 | 0e0, 0 | 2e6, 44   |
| dfca64e | 2ALU pMUL OoO LSU [9]   | 2869704  | 2530446  | 0.882 | 7e5,25 | 1e6,36    | 1e6, 51    | 9e4, 3 | 0e0, 0 | 1e6, 36   |
| 76143bb | RAS-4 + TAGE [10]       | 16958705 | 15914408 | 0.938 | 4e6,26 | 7e6,40    | 9e6, 53    | 3e5, 2 | 0e0, 0 | 5e6, 32   |
| current | Default worktree [12]   | 14321377 | 15914407 | 1.111 | 5e5, 4 | 0e0, 0    | 1e7, 72    | 1e5, 1 | 0e0, 0 | 5e6, 32   |

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
| e913241 | Zbc + ROB fix [8]       | 500857 | 340204 | 0.679 | 1e5,28 | 7e4,13    | 2e5, 44    | 1e4, 3 | 2e4, 3 | 2e5, 49   |
| dfca64e | 2ALU pMUL OoO LSU [9]   | 460943 | 339907 | 0.737 | 1e5,27 | 1e5,26    | 2e5, 46    | 2e4, 4 | 0e0, 0 | 2e5, 46   |
| 76143bb | RAS-4 + TAGE [10]       | 459530 | 339907 | 0.740 | 1e5,25 | 1e5,25    | 2e5, 44    | 2e4, 3 | 0e0, 0 | 2e5, 46   |
| current | Default worktree [12]   | 402118 | 339863 | 0.845 | 3e4, 7 | 0e0, 0    | 3e5, 72    | 1e4, 3 | 0e0, 0 | 2e5, 46   |

[1]: L1D hit latency reduced from 3 cycles to 2 cycles due to SRAM-based design, and L1I sequential fetch optimized to eliminate bubbles on hits.  
[2]: SQ address-based bypass (loads only block on same-word address conflict instead of blanket `|sq_valid`). Fixed L1D `l1d_update` NBA priority bug. Store-to-load forwarding for full-word (SW) stores, age-ordered youngest-match-wins with STQ>SQ priority. Partial (SB/SH) stores still block conservatively.  
[3]: L1D multi-word cache lines (2 words, banked SRAM), partial store Read-Modify-Write (RMW) instead of invalidation, TLB/PTW extracted into reusable modules (`rapt_tlb.sv`, `rapt_ptw.sv`). Difftest skip moved from bus-level to commit stage. L1D set count reduced from 128 to 64 (total capacity same: 64x2w = 128w). Store-to-load forwarding uses virtual address. `addr_cacheable()`/`addr_mapped()` centralized in `rapt_pkg`.  
[4]: L1I line widened from 2w to 4w (reducing I-cache miss rate -- L1I hit 97%, AMAT 1.2). Dual commit (`RAPT_DUAL_COMMIT`) retires up to 2 consecutive ROB entries/cycle (CoreMark 12.2%, MicroBench 10.0%). SQ stall eliminated (0%) -- loads no longer block on store queue occupancy. Combined: CoreMark -1863k cycles (-27.6%, IPC 0.443->0.612), MicroBench -113k cycles (-15.3%, IPC 0.504->0.595). IFU stall now visible (34%) due to L1I miss latency becoming the dominant frontend bottleneck. BPU rate: CoreMark 90.5%, MicroBench 84.4%.  
[5]: Timing-oriented refactoring (IPC-neutral, targets critical path reduction for frequency). BPU: PHT/BTB sub-modules with `(* keep_hierarchy *)` to isolate registered read ports from `pc_ifu` fanout; BTB upgraded to 2-way set-associative (128 entries = 64 sets x 2 ways). IFU: pre-registered sequential PC (`seq2`/`seq4`) replaces combinational adder on critical path. RNU: 2-stage rename pipeline register (maptable+freelist read -> registered output to ROU). ROU: UOQ operand pre-read at enqueue with broadcast forwarding during residence, eliminating PRF read from dispatch critical path. EXU: RS priority encoding via `casez` one-hot vectors (replaces for-loop). MUL: hybrid fast multiply (2-cycle pipeline) + iterative restoring divider (removes combinational divider). BPU rate: CoreMark 90.5->92.4%, MicroBench 84.4->85.1%. IDU early resteer + BPU infrastructure. IDU sends `resteer` pulse to IFU when BPU predicts taken on a non-branch instruction (BTB alias), redirecting fetch at decode stage (~2 cycle penalty vs ~5-7 at commit). CMU derives `call`/`ret`/`rvc` from committed instruction word via `cmu_bcast_if`. BPU: RSB committed data maintained (push on call, pop on ret, speculative pointer with flush recovery), JALR added to `wen_entry` (BTB entry creation on first misprediction), BTB `wen_type` guarded to only update matching or newly-created entries. RSB prediction and gshare PHT indexing prepared but disabled: 512-entry PHT too small for gshare (destructive aliasing), RSB regresses due to 7-bit BTB tag aliasing. Both ready to enable when BTB/PHT capacity increases. IPC-neutral on current benchmarks.  
[6]: Generalized dual-fetch from C+C only to all combinations: C+C, C+R32, R32+C, R32+R32. IDU slot B now decodes both C-type and R32 instructions. L1I provides `inst_n1` (next 4-byte-aligned word) via 3-tier SRAM pre-read for assembling slot B. Fixed latent EXU multiplier bug: added `mul_target_idx` to ensure multiply results deliver only to the originating RS entry. Combined: CoreMark -1192k cycles (-24.3%, IPC 0.610->0.781), MicroBench -131k cycles (-20.5%, IPC 0.586->0.720). Dual commit: CoreMark 37.2%, MicroBench 35.2%. #Inst decreased slightly (~3%) due to fewer total instructions executed (fewer misspeculated instructions from improved fetch). BPU rate: CoreMark 90.5%, MicroBench 79.9%.  
[7]: Added RISC-V Zba (address generation: sh{1,2,3}add), Zbb (basic bit-manipulation: clz/ctz/cpop/min/max/rotate/sext/orc.b/rev8), Zbs (single-bit: bset/bclr/bext/binv), and Zicond (conditional operations: czero.eqz/czero.nez) extensions. ALU opcode expanded from 5->6 bits (32->64 operations). Compiler flags updated to `-march=rv32imac_..._zicond_zba_zbb_zbs`, allowing GCC to emit bitmanip and conditional-zero instructions. Zicond eliminates short conditional branches by converting simple if-else patterns into branchless `czero` sequences, avoiding the ~8-cycle misprediction penalty. Instruction count reduced (CoreMark -1.5%, MicroBench -6.8%) as multi-instruction sequences are replaced by single bitmanip/conditional ops. CoreMark cycles -1.1% (IPC 0.781->0.778), MicroBench cycles -1.1% (IPC 0.720->0.679). BPU rate: CoreMark 90.5%, MicroBench 80.0%. Dual commit: CoreMark 38.8%, MicroBench 33.7%.  
[8]: Added RISC-V Zbc (carry-less multiply: clmul/clmulh/clmulr). Fixed a latent ROB commit-path bug exposed by the widened ALU opcode encoding; re-integrated LiteX SoC support and added a security-demo app. Performance essentially flat vs. ce2f2a1 since the benchmarks do not exercise Zbc: CoreMark IPC 0.778->0.777 (+90 cycles, -19 committed insts from BPU/RSB accounting), MicroBench IPC unchanged at 0.679 (-271 cycles, +22 insts). BPU rate: CoreMark 90.5%, MicroBench 79.8%. Dual commit: CoreMark 38.7%, MicroBench 33.2%.  
[9]: OoO window expansion + dual ALU + pipelined MUL + OoO LSU. Backend structural upgrade across three axes: (a) Window sizing: RS 4->8, RIQ/IIQ 4->8, ROB 8->16, IOQ 4->8 (PRF kept at 64; ROB=16 is the binding in-flight cap so 64 phys regs >= 32 arch + 16 in-flight is sufficient). (b) *Dual ALU writeback*: second ALU on `exu_rou_b` for simple-ALU slot-B (branch/CSR/system/trap excluded); pipelined MUL with tag-based completion (`mul_target_idx`) allowing multiple MULs in flight. (c) *Out-of-order L1D issue*: IOQ no longer head-of-line blocks younger ready loads on older unresolved stores or slow-returning loads. Per-entry completion state (`ioq_complete`/`ioq_rdata`/`ioq_load_trap`/`ioq_load_cause`/`ioq_load_skip`); oldest-ready PE over `ioq_load_issue_vec` drives L1D; older-store blocker mask holds a load if any older IOQ store has unresolved base reg (`pr1!=0`), pending MMU translation, or word-address conflict; `oo_pending` FSM locks `active_idx` across multi-cycle misses; commit mux at `ioq_head` consumes either the live L1D response (when `active_idx==head`) or the pre-latched `ioq_rdata[head]`; atomics (LR/SC/AMO) and uncacheable MMIO stay gated to ROB head for memory ordering. Single outstanding L1D request (scalar AGU, no address-disambiguation replay). CoreMark IPC 0.777->**0.883 (+13.6%)**, -443218 cycles, dual commit 38.7%->42.0%, BPU 91.3%. MicroBench IPC 0.679->0.737 (+8.5%, -38975 cycles, dual commit 35.8%, BPU 78.0%); its inner loops have short dependency chains so OoO LSU gains are smaller. Also includes two correctness fixes surfaced during RV64 difftest bring-up: (i) RV64 Zba `.UW` variants (`add.uw`/`slli.uw`/`sh[123]add.uw`) now use dedicated ALU opcodes with `zext.w(rs1)` and no output sign-extend truncation (fixes `coremark-npc64` invalid-addr errors); (ii) NEMU C.SLLI shamt decoded as zero-extended `dec_cs_shamt()` instead of sign-extended `dec_ci_imm()` (fixes `coremark-npc64-difftest` ref-vs-dut mismatch on shamt>=32). Verification: RV32/RV64 lint clean, 35/35 cpu-tests PASS on RV32 and RV64, coremark/microbench pass both bare-metal and difftest on RV32 and RV64.  
[10]: RAS (4-entry RSB) + TAGE direction predictor enabled in BPU. Return prediction uses BTB `RETU` + speculative RSB top; calls are pushed speculatively at IDU (slot-A jal/jalr with link rd), rets pop speculatively on prediction, and flush rewinds `spec_idx` to `cmt_idx`. TAGE is used for conditional-branch direction prediction in this iteration. Perf impact: CoreMark IPC **0.882->0.938 (+6.4%)**, BPU 89.8%->93.0%, JALR mispredict 117K->5.7K; MicroBench IPC 0.737->0.740 (+0.4%). STA (nangate45, target 50MHz): period_min 17.35ns (Fmax 57.65MHz), total area 1,095,067.47 um^2, total power 1.01e-01 W. Power split: internal/switching/leakage = 57.1% / 16.9% / 25.9%. Area split: sequential 23.3%, combinational 76.7%.  
[11]: L2-ready integration (`rapt_l2.sv`) + L1I/SRAM refactor, plus EXU/MUL and typo/lint cleanups. In the current default config, `RAPT_L2_EN` is disabled and `rapt_l2` behaves as a passthrough; benchmark gains are therefore attributed primarily to the larger/tuned L1I path and SRAM pre-read tuning unless a run explicitly enables L2. CoreMark IFU stall drops from 26% to 14%, pulling CoreMark IPC **0.938->1.025 (+9.3%)**, -1430585 cycles, dual commit 44.5%, BPU 92.6%. MicroBench IPC 0.740->0.759 (+2.6%, -11427 cycles, dual commit 39.8%, BPU 78.9%). #Inst essentially unchanged (CoreMark identical, MicroBench +24). STA below is run with the `small` (single-issue) uarch preset.
[12]: A shared dual-issue ALQ built from `rapt_exu_iq`; TAGE bimodal-base training on every committed conditional branch; slot-B direct-JAL and conditional-branch packing; line-safe unaligned R32+R32 assembly through `inst_n2`; exact-next-PC/redirect L1I SRAM read-ahead; and 8-word (32 B) L1I sector refills with the read-valid pipeline held through `FINA`. CoreMark was clean-rebuilt with `ITERATIONS=64` and run with `ARGS="-b -n"`, matching the long-run instruction count of the prior row; it reached `HIT GOOD TRAP` at 14,321,377 cycles / 15,914,407 instructions / IPC 1.111. MicroBench ran with `ARGS="-b -n"`; all 10 subtests passed and it reached `HIT GOOD TRAP` at 402,118 cycles / 339,863 instructions / IPC 0.845.

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

## STA Results

Static timing / area / power across PDKs via `make sta` (OpenROAD/yosys-opensta flow). One row per commit per ISA; Fmax in MHz (post-synth, worst corner), Area in um^2, Power in W. Columns grouped by PDK (nangate45 / asap7 / sky130hd).

The historical `[11]` STA row is run with the `small` (single-issue, low-area) uarch preset (`make sta RAPT_CONFIG=small`). Earlier rows (`[9]`, `[10]`) used the `default` (dual-issue OoO) preset, so `[11]` is not directly comparable in area/Fmax.

### RV32

| Commit  | Change                | NG45 Fmax |    NG45 Area | NG45 Pwr | ASAP7 Fmax | ASAP7 Area | ASAP7 Pwr | SKY130 Fmax |  SKY130 Area | SKY130 Pwr |
| ------- | --------------------- | --------: | -----------: | -------: | ---------: | ---------: | --------: | ----------: | -----------: | ---------: |
| dfca64e | 2ALU pMUL OoO LSU [9] |     76.01 |   915,409.21 | 9.82e-02 |      79.06 |  83,880.13 |  1.51e-02 |       29.70 | 4,836,589.92 |   6.61e-02 |
| 76143bb | RAS-4 + TAGE [10]     |     62.08 | 1,037,535.66 | 9.17e-02 |      92.71 |  95,731.26 |  1.00e-02 |       28.65 | 5,494,031.71 |   7.48e-02 |
| 875aa2f | L2$ + L1I/SRAM [11]   |     77.15 |   529,830.50 | 5.18e-02 |      94.79 |  49,517.43 |  1.22e-02 |       32.89 | 2,818,931.08 |   3.12e-02 |

### RV64

| Commit  | Change                | NG45 Fmax |    NG45 Area | NG45 Pwr | ASAP7 Fmax | ASAP7 Area | ASAP7 Pwr | SKY130 Fmax |  SKY130 Area | SKY130 Pwr |
| ------- | --------------------- | --------: | -----------: | -------: | ---------: | ---------: | --------: | ----------: | -----------: | ---------: |
| dfca64e | 2ALU pMUL OoO LSU [9] |     46.67 | 1,531,961.83 | 1.11e-01 |      67.62 | 139,624.54 |  4.29e-03 |       21.02 | 8,115,397.06 |   1.04e-01 |
| 76143bb | RAS-4 + TAGE [10]     |     27.82 | 1,695,775.00 | 1.02e-01 |      62.43 | 155,137.83 |  4.85e-03 |       16.14 | 9,027,255.35 |   1.21e-01 |
| 875aa2f | L2$ + L1I/SRAM [11]   |     53.78 |   859,590.97 | 9.00e-02 |      57.67 |  80,248.39 |  6.80e-03 |       22.71 | 4,680,833.04 |   5.09e-02 |

Footnote `[9]` matches the corresponding entry in the CoreMark/MicroBench tables above. `[10]` and `[11]` STA were run via CI across all three PDKs and both ISAs. `[10]` used the `default` (dual-issue OoO) preset; `[11]` was measured at `875aa2f` with the `small` (single-issue) preset, so its lower area/higher Fmax (e.g. RV32 NG45 area 1.04M -> 0.53M um^2, Fmax 62.08 -> 77.15 MHz) reflect the smaller preset, not a like-for-like uarch comparison. No STA result is recorded for the current default worktree [12].

