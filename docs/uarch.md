# Microarchitecture

Raptor is an out-of-order, super-scalar RISC-V processor core with register renaming, a reorder buffer (ROB), per-class issue queues (a dual-ported ALQ shared by the two ALU pipes, plus BRQ / MDQ / FPQ / IOQ), scalar F/D floating-point execution, and virtual memory support.

## Pipeline

9 logical stages, dual-issue width through IF->DI. Valid/ready handshaking at all boundaries; FQU, RNQ, UOQ, ALQ/BRQ/MDQ/FPQ, IOQ, and ROB decouple stages.

```text
 IF0     IF1      FQ       ID      RN       DI       IS/EX    WB      CM
+-----++------++-------++------++-------++--------++-------++-----++------+
|L1I  ||IFU   ||FQU    ||IDU   ||RNU    ||ROU     ||DPU/EUs||ROB  ||CMU   |
|SRAM ||FSM   ||packet ||decode||RNQ->  ||UOQ->    ||IQ->FU ||->WB  ||bcast |
|read ||latch ||queue  ||x2    ||rename ||dispatch||issue  ||state||retire|
|(spec)|      |x2     | latch | pipe x2| +ROB x2 |        |      | x2   |
+--+--++--+---++---+---++--+---++--+----++---+----++--+----++--+--++--+---+
 1 cyc  1 cyc   1 cyc   1 cyc   1 cyc    1 cyc    1 cyc   0 cyc  1 cyc
```

| Stage     | Module | Register boundary                          |
| --------- | ------ | ------------------------------------------ |
| **IF0**   | L1I    | SRAM address latched                       |
| **IF1**   | IFU    | `inst`, `pc`, `pc_ifu` registered          |
| **FQ**    | FQU    | Fetch packet registered before decode       |
| **ID**    | IDU    | `uop_t`, operands registered               |
| **RN**    | RNU    | `rn_pipe_{pr1,pr2,prd,prs,uop}` registered |
| **DI**    | ROU    | UOQ consumed, ROB entry allocated          |
| **IS/EX** | IEU/FEU/LSU | IQ/IOQ entries updated                |
| **WB**    | ROB    | ROB state -> `ROB_WB`                      |
| **CM**    | CMU    | Architectural state committed              |

- **First-instruction latency**: ~10 cycles (empty pipeline, L1I hit, ALU)
- **Peak throughput**: 2 IPC (dual-issue, all queues flowing)
- **Load-use latency**: 3 cycles (IOQ issue -> L1D hit -> result broadcast)
- **Branch misprediction penalty**: ~8 cycles (full pipeline drain, flush at commit)

### Store & Load Ordering

- **Stores**: IOQ computes address+data and allocates one unified SQ entry; ROB commit marks the existing entry committed; committed head entries drain to L1D/BUS in program order.
- **Store-to-load forwarding**: loads CAM the unified SQ by virtual word address; youngest matching full-width store forwards data.
- **Load issue**: IOQ supports out-of-order load issue when older stores are resolved and non-conflicting. Atomics and uncacheable/MMIO requests remain ordered at the ROB/IOQ head.

### Branch Misprediction Recovery

`cmu_bcast.flush_pipe` -> IFU redirect to correct PC, RNU freelist rewinds head + MAP←RAT, PRF transient entries invalidated.

## Module Details

### Frontend

#### IFU (`rapt_ifu.sv`)

3-state FSM (`IDLE`->`VALID`->`STALL`). Sends PC to L1I and BPU in parallel. Next-PC priority: flush > early resteer > BPU taken > sequential (PC+2/+4/+6/+8). Pre-registered `seq2`/`seq4`/`seq6`/`seq8` avoid adder on critical `pc_ifu` loop.

**Dual-fetch**: delivers two instructions from L1I via `ifu_idu_if.{inst_b, pc_b, valid_b}`. Supports C+C, C+R32, R32+C, and R32+R32 at either halfword alignment; the unaligned R32+R32 form uses `inst_n2` for its third-word upper half. Slot-A controls terminate a packet. Slot-B direct JAL/C.J and conditional branches may be packed with their own target/direction metadata; JALR, serializing instructions, traps, and unavailable lookahead data remain single-packet boundaries. System/atomic/trap instructions enter `STALL` until their commit-side flush.

**Read-ahead**: every accepted packet supplies its exact next PC (sequential stride, predicted target, or redirect target) to L1I as a side-effect-free data-SRAM hint. This hides the synchronous SRAM read latency without creating a cache request or modifying cache state.

#### FQU (`rapt_fqu.sv`)

Two-entry registered elastic fetch queue between IFU and IDU. A packet accepted from IFU is always stored before IDU can observe it; there is no empty-queue flow-through path. This makes FQU an explicit timing boundary while still allowing one packet to dequeue and one to enqueue in the same cycle.

FQU carries the complete dual-issue fetch packet (`inst`, PC, `pnpc`, and fetch-trap metadata). `flush_pipe`, `sys_resume`, and an IDU early resteer clear resident packets and block same-cycle IFU acceptance. The early-resteer channel itself remains combinational through FQU so IFU can squash stale fetch data in that cycle.

#### BPU (`rapt_bpu.sv`)

| Component                   | Implementation                                                 | Key details                                           |
| --------------------------- | -------------------------------------------------------------- | ----------------------------------------------------- |
| **DIRP**                    | Default TAGE; alternatives: gshare, bimodal/PHT, static        | Selected by `RAPT_BPU_DIRP_*` macros                  |
| **PHT** (`rapt_bpu_pht.sv`) | 2-bit saturating, `PHT_SIZE` entries (256)                     | Used by bimodal/PHT mode and as local predictor base  |
| **BTB** (`rapt_bpu_btb.sv`) | 2-way SA, `BTB_SIZE` entries (128), 7-bit tag                  | `(* keep_hierarchy *)`, sync read, XOR-hash, LRU      |
| **History**                 | 64-bit GHR plus 8-bit path history for TAGE/gshare-style DIRPs | Speculative prediction state with commit/flush repair |
| **RSB**                     | `RSB_SIZE` entries (4)                                         | Committed + speculative pointers, link-reg detection  |

BTB entry types: `COND`, `DIRE`, `INDR`, `RETU`. Direction predictor state is trained from committed branch outcomes; BTB updates occur on flushes (including JALR). Predictor structures are invalidated or repaired on `fence_time` / flush paths as appropriate.

#### L1I (`rapt_l1i.sv`)

N-way set-associative I-cache (`L1I_N_WAYS`, default 2). `2^L1I_LEN` sets (32), `2^L1I_LINE_LEN` words/line (16 RV32 words = 64 B). Default capacity is 4 KiB. 7-state FSM (`IDLE`, `PTWAIT`, `TRAP`, `RD_A`, `RD_0`, `RD_1`, `FINA`).

| Storage | Implementation                                                                       |
| ------- | ------------------------------------------------------------------------------------ |
| Data    | Banked `rapt_sram_1rw` per way per word (single-port, sync read)                     |
| Tags    | Banked `rapt_sram_1rw` per way per word (combinational compare from SRAM output)     |
| Valid   | Register arrays per way (`l1i_valid[way][set]`) for fast `fence.i` bulk invalidation |

3-tier pre-read uses the IFU's exact next-PC hint: current bank reads the hinted word, next bank reads `+2`, and remaining banks read `+4`. This provides `inst_n1` and `inst_n2` for generalized dual-fetch while hiding hit-path target/stride transitions. Cache lines retain per-word valid bits; on the default non-SDRAM AR path, `RAPT_L1I_REFILL_WORDS=8` refills one 32 B sector per miss through an 8-entry AR FIFO. The value is capped by the configured line length and may be overridden for experiments; SDRAM burst targets retain their dedicated two-beat burst refill path. Way replacement: first invalid, then toggle `replace_bit` per set. ITLB + IPTW support Sv32/Sv39 translation.

#### IDU (`rapt_idu.sv`)

2-state FSM (`IDLE`/`VALID`). Dual decode: slot A has `rapt_idu_decoder_c` + `rapt_idu_decoder`; slot B has its own pair (`rapt_idu_decoder_c` + `rapt_idu_decoder`), handling both C-type and R32 instructions. Slot B suppressed on slot A branch/jump/trap.

**Early resteer**: detects BPU misprediction on non-branch (`pnpc ≠ pc + inst_len && !branch`), sends one-shot `resteer` pulse + corrected PC back to IFU, patches `pnpc` in downstream UOP.

### Backend

#### RNU (`rapt_rnu.sv`)

Pure rename: maps arch -> physical registers. Dual-rename with RAW dependency handling (slot B sees slot A's result when they share an arch register).

- **RNQ**: Circular queue, `RIQ_SIZE` entries (8). Dual-issue enqueues atomically; paired via `rnq_is_pair`.
- **Freelist** (`rapt_rnu_freelist.sv`): Circular FIFO, `PHY_SIZE` entries (128). Dual alloc ports (B reads `head+1`). Dual dealloc for dual commit. Flush: rewinds head by in-flight count.
- **MapTable** (`rapt_rnu_maptable.sv`): MAP (6R + 2W, B wins conflict) + RAT (2W, B wins). Flush: MAP←RAT with concurrent commit forwarding.

#### PRF (`rapt_prf.sv`)

`PHY_SIZE` entries (128). 4 read ports (2 per dispatch slot) + 4 write ports, one per value-producing CDB pipe (ALU-CSR, ALU, MEM, MULDIV; the Branch pipe never writes a register). `prf_valid[]` + `prf_transient[]` tracking. Flush: transient entries invalidated. Commit: transient cleared. Dealloc: valid cleared.

#### FPR (`rapt_fpr.sv`)

Separate 32 x 64-bit architectural floating-point register bank. The fixed
64-bit width supports RV32 and RV64, with single-precision values NaN-boxed in
the same storage used by double precision. FP arithmetic writes through the FEU
path and FP loads write through the LSU path, with local bypassing for recent
writes. FP dependency tags are tracked through the ROB; this bank is not a
second renamed physical register file.

#### ROU (`rapt_rou.sv`)

Dispatch queue + reorder buffer + commit logic.

- **UOQ**: Circular, `IIQ_SIZE` entries (8). Dual enqueue/dequeue with `uoq_is_pair` tracking.
- **ROB**: `rob_entry_t[]`, `ROB_SIZE` entries (64). States: `ROB_EX`->`ROB_WB`->`ROB_CM`. Dual dispatch inserts 2 entries at tail/tail+1.
- **Operand bypass**: UOQ pre-read > LSU/IOQ broadcast > CDB broadcast. Broadcast forwarding continues during UOQ residence.
- **Dual commit**: slot 0 commits; slot 1 joins if slot 0 doesn't flush/store, neither has `difftest_skip`, and slot 1 is ready. BPU trains on slot 1's branch info during dual commit.
- **Flush triggers**: fence\_i, branch mispredict, trap, system op, atomic (from either slot).
- **Async traps**: CLINT software/timer interrupts plus PLIC M/S external interrupts, gated by CSR enables and delegation state.

#### DPU (`rapt_dpu.sv`)

Stateless dispatch router. It classifies each uop with priority memory >
MUL/DIV > FP > branch > ALU-class and steers it to the owning queue through
`dpu_iq_if` or `dpu_ioq_if`. FP loads/stores stay in the LSU IOQ; other scalar
FP operations enter the FEU FPQ. CSR/system/trap entries are marked
**ALU-port-blocked**, so only the IEU ALU-CSR pipe can issue them. Queue free
slots return through the same interfaces and form `rou_exu.ready/ready_b`.

#### IEU (`ieu/rapt_ieu.sv`)

- **Generic IQ** (`rapt_iq.sv`): shared parameterized data-capture scheduler. IEU instantiates the ALQ (8 entries, two issue ports) and BRQ (4 entries); FEU instantiates FPQ separately. Operands wake from all four value-producing CDB ports plus the **fast load-use** tag path. The age matrix selects oldest-first, with a second ALQ winner constrained by port eligibility.
- **ALU-CSR pipe** (`ieu/rapt_ieu_pipe_alu_csr.sv`): full ALU + CSR/system/trap redirect semantics; produces the raw CDB0 candidate.
- **ALU pipe** (`ieu/rapt_ieu_pipe_alu.sv`): simple ALU + JAL/JALR link write; drives CDB1.
- **Branch pipe** (`ieu/rapt_ieu_pipe_branch.sv`): conditional-branch resolution; drives CDB2 and never writes PRF data.
- **MULDIV pipe** (`ieu/rapt_ieu_muldiv.sv`): private four-entry MDQ plus `rapt_ieu_mul`; pipelined multiply and iterative divide complete through CDB4.
- **ALU** (`ieu/rapt_ieu_alu.sv`): combinational 6-bit opcode datapath, including the RV64 Zba `.UW` operations.

#### FEU (`feu/rapt_feu.sv`)

Owns the four-entry in-order FPQ and scalar F/D arithmetic, FMA,
divide/square-root, conversions, comparison/classification, sign injection and
move operations under `feu/fpu/`. It reads/writes the architectural FPR bank
and produces the FPU candidate for CDB0. `rapt_cdb_arb.sv` preserves the
original arbitration: an FPU completion wins over the IEU ALU-CSR candidate,
and the losing issue source is backpressured. FP loads/stores remain in LSU.

#### CMU (`rapt_cmu.sv`)

Broadcast unit. Outputs: `rpc`, `cpc`, branch resolution, `flush_pipe`, `fence_i`, `fence_time`, `time_trap`. Dual-commit broadcasts slot 1's branch info; call/return detection via link register (`rd/rs1 == x1|x5`). Per-slot `rd_a`/`rd_b`/`valid_b` for freelist recovery.

#### CSR (`rapt_csr.sv`)

32-entry register file, M/S-mode. Trap entry/exit (`ecall`/`ebreak`/`mret`/`sret`), privilege transitions (M/S/U), delegation (`medeleg`/`mideleg`), `MSTATUS`<->`SSTATUS` mirroring, `mcycle`/`time` counters. Broadcasts: `priv`, `satp`, MMU enables, `tvec`, and `pmpcfg`/`pmpaddr` shadow arrays for PMP.

#### PMP (`rapt_pmp.sv`)

16 PMP entries (`RAPT_PMP_NUM=16`). Combinational match logic supporting TOR / NA4 / NAPOT modes, with locked (`L` bit) entries enforced even in M-mode. CSR file owns the architectural `pmpcfg[0..3]` / `pmpaddr[0..15]` registers (WARL on reserved A-mode encodings) and broadcasts them through `csr_bcast_if`. Checks are wired into three sites: IFU instruction fetch (raises instruction access-fault, `mtval` = faulting byte address for cross-boundary fetches), L1D load/store (raises load/store access-fault, MPRV-aware effective privilege), and PTW PTE-load path (raises access-fault on the failing PTE address). Empty PMP table allows all accesses in M-mode and denies all accesses in S/U-mode, matching the privileged spec.

### Memory Subsystem

#### LSU (`lsu/rapt_lsu.sv`)

- **IOQ / AGU** (`lsu/rapt_lsu_ioq.sv`): `IOQ_SIZE` entries (default 8) for loads, stores and atomics. A younger ready load may issue ahead of older work only after older stores have resolved and are known non-conflicting. `oo_pending` retains the selected entry across a multicycle L1D request; atomics and uncacheable/MMIO accesses remain ordered. The IOQ drives CDB3 and the early `load_fast_if` wakeup path to IEU/FEU.
- **Unified SQ**: `SQ_SIZE` entries (default 16). One ring stores each store from execute/writeback through commit and drain. `[head,cmt)` entries are committed and survive flush; `[cmt,tail)` entries are speculative and are discarded on flush.
- Store FSM: six states (`LS_S_V`/`LS_S_R`, `LS_S_HI_V`/`LS_S_HI_R`,
  `LS_S_X_V`/`LS_S_X_R`) handle aligned drains, split misaligned drains, and
  the third RV32D FSD beat.
- Store-to-load forwarding: single SQ CAM by virtual word address, youngest-match-wins for full-width stores; partial or conflicting stores conservatively block/retry.

#### Backend optimization handoff

The EXU split is intentionally structural. The following optimization items
remain separate microarchitecture projects, now rooted at their owning module:

- **P0-1 — earlier speculative load wakeup**: move the `load_fast_if` pulse in
  [`lsu/rapt_lsu_ioq.sv`](../hdl/backend/lsu/rapt_lsu_ioq.sv) toward the L1D
  tag-compare stage while retaining `rebusy` cancellation in
  [`rapt_iq.sv`](../hdl/backend/rapt_iq.sv). The current refactor preserves the
  existing data-return-cycle wakeup behavior.
- **P0-2 — precise memory disambiguation / store sets**: replace the
  conservative unknown-address portion of `ioq_older_store_blk` in
  [`lsu/rapt_lsu_ioq.sv`](../hdl/backend/lsu/rapt_lsu_ioq.sv) with violation
  detection, replay, and eventually a load-PC-to-store-set predictor. IOQ and
  SQ now share the LSU hierarchy, but this refactor does not relax ordering.
- **P1-2 — multiple outstanding L1D misses**: extract the single-miss state in
  [`memory/rapt_l1d.sv`](../hdl/memory/rapt_l1d.sv) into a small MSHR file and
  return completions to the per-entry IOQ completion storage. The current L1D
  remains single-outstanding apart from its hit-under-miss B channel.
- **P1-3 — scalable issue selection**: replace the data-capture age matrix in
  [`rapt_iq.sv`](../hdl/backend/rapt_iq.sv) with position-based oldest-first
  selection and PRF read-after-select. ALQ, BRQ, and FPQ deliberately retain
  their existing age and bypass semantics in this structural change.

#### L1D (`rapt_l1d.sv`)

2-way set-associative. `2^L1D_LEN` sets (16), `2^L1D_LINE_LEN` words/line (16 RV32 words or 8 RV64 words = 64 B). Default capacity is 2 KiB. 5-state FSM (`IDLE`, `PTWAIT`, `TRAP`, `LD_A`, `LD_D`).

| Storage   | Implementation                                                                      |
| --------- | ----------------------------------------------------------------------------------- |
| Data      | Banked `rapt_sram_1rw` wide subarrays (single-port, sync read, write bypass)        |
| Tag/Valid | Per-word register arrays for simultaneous ld/st hit check + fast fence invalidation |

Write-through policy. Partial stores (SB/SH): read-modify-write (RMW) 2-cycle merge in IDLE. Speculative SRAM read: VIPT-safe virtual index in IDLE. Separate DTLB + DSTLB instances; shared DPTW for both. Reservation register for LR/SC. Cacheability via `addr_cacheable()`.

Zicbom `cbo.inval`, `cbo.clean`, and `cbo.flush` are serializing operations. Retirement waits for the unified SQ to become empty, then the existing `fence_time` maintenance path invalidates every L1D valid entry and flushes the data-side TLBs. This is a conservative whole-L1D implementation: the encoded `rs1` address is accepted but does not yet select one cache block. Because L1D is write-through, treating `cbo.clean` as the same stronger whole-cache operation is functionally correct. LiteX uses this behavior as its full-cache fallback after non-coherent DMA.

#### TLB (`rapt_tlb.sv`)

Reusable fully-associative Sv32/Sv39 TLB. `ENTRIES` param (default 4), ASID-aware. Combinational lookup, sequential fill (no duplicates), round-robin replacement, bulk flush. Instantiated as: `u_itlb` (L1I), `u_dtlb` (L1D load), `u_dstlb` (L1D store).

#### PTW (`rapt_ptw.sv`)

Reusable page-table walker. RV32 uses a Sv32 two-level FSM (`IDLE`->`LVL1`->`LVL0`); RV64 uses a Sv39 three-level FSM (`IDLE`->`LVL2`->`LVL1`->`LVL0`). Leaf detection follows `PTE.R||PTE.X`, with hardware A/D-bit writeback before `done`. Instantiated as: `u_iptw` (L1I), `u_dptw` (L1D).

#### BUS (`rapt_bus.sv`)

`rapt_bus.sv` arbitrates core memory traffic onto `mem_link_if`. Reads use request IDs (`L1I`, `L1D`, `TLBI`, `TLBD`): L1I has a configurable refill-request FIFO, L1D has a held request slot, and L1D has issue priority. Responses are demultiplexed by ID. `rapt_axi_master.sv` converts that internal link to AXI4, supports up to eight outstanding reads with per-ID ownership tracking, and handles AW and W handshakes independently for one outstanding write. The bus is SoC-memory-map agnostic; the cluster-level `rapt_router.sv` decodes CLINT/PLIC MMIO and forwards all other transactions off chip.

#### L2 (`rapt_l2.sv`)

Optional unified AXI4 cache between the core bus/router path and off-chip memory. When `RAPT_L2_EN` is undefined, the module collapses to a transparent passthrough; the default configuration currently leaves it disabled. When enabled, the configured implementation is a 16 KiB direct-mapped cache (`2^RAPT_L2_LEN` sets, 64 B lines) with multi-way support reserved.

#### CLINT (`rapt_clint.sv`)

Cluster-level 64-bit `mtime` counter with `mtimecmp` and `msip`. `mtime` is paced by `RAPT_MTIME_DIV`, and the timer interrupt is level-triggered when `mtime >= mtimecmp`. CLINT MMIO is decoded by `rapt_router.sv` beside the PLIC.

#### PLIC (`rapt_plic.sv`)

Cluster-level Platform-Level Interrupt Controller. Default `NDEV=31` sources and `NCTX=2` contexts (`ctx0` M-mode hart 0, `ctx1` S-mode hart 0). Implements priority, pending, enable, threshold, and claim/complete registers in the standard `0x0c00_0000` 16 MB window. The legacy single-bit `io_interrupt` input is merged into PLIC source 1, and the core consumes `meip/seip` from the PLIC context outputs.

## Interfaces

### Inter-module (`rapt_if.svh`, `rapt_*_if.svh`)

| Interface        | Direction               | Description                                               |
| ---------------- | ----------------------- | --------------------------------------------------------- |
| `ifu_bpu_if`     | IFU<->BPU               | PC for prediction; NPC + taken back                       |
| `ifu_l1i_if`     | IFU<->L1I               | PC fetch request; `inst_n0` + `inst_n1` + trap response   |
| `ifu_idu_if`     | IFU<->FQU / FQU<->IDU   | inst_a/b + PC_a/b + pnpc; early resteer returns via FQU   |
| `idu_rnu_if`     | IDU->RNU                | uop_a/b + operands + arch reg IDs                         |
| `rnu_rou_if`     | RNU->ROU                | uop_a/b + physical reg mappings                           |
| `rou_exu_if`     | ROU->DPU/EUs            | uop/uop_b + operands + ROB dest (dual dispatch)           |
| `rou_lsu_if`     | ROU->LSU                | Store commit (addr/data/alu)                              |
| `rou_csr_if`     | ROU->CSR                | CSR write + trap/system on commit                         |
| `rou_cmu_if`     | ROU->CMU                | Commit info slot A/B (PC, branch, fence, flush)           |
| `dpu_iq_if`      | DPU<->IEU/FEU           | Queue allocation and free-slot backpressure               |
| `dpu_ioq_if`     | DPU<->LSU               | IOQ allocation and paired-slot backpressure               |
| `cdb_if` (x5)    | EUs->ROU/PRF/LSU/IQs    | Unified writeback: ALU-CSR or FPU / ALU / Branch / MEM / MULDIV |
| `load_fast_if`   | LSU->IEU/FEU            | Early load tag wakeup and rebusy confirmation             |
| `iq_iss_if`      | IQ->pipe                | Oldest-ready issue payload                                 |
| `exu_prf_if`     | ROU->PRF                | Operand read (4 ports: 2 per slot)                        |
| `fpr_if`         | FEU/LSU<->FPR           | FP register reads and arithmetic/load writeback          |
| `lsu_pipe_if`    | LSU internal            | IOQ/AGU to SQ load request and response                   |
| `exu_csr_if`     | IEU->CSR                | CSR read port                                             |
| `lsu_l1d_mmu_if` | LSU->L1D                | Store MMU + SC reservation check                          |
| `cmu_bcast_if`   | CMU->all                | Retire broadcast (flush, fence, branch, call/ret)         |
| `csr_bcast_if`   | CSR->all                | Priv, SATP, MMU enable, tvec                              |
| `lsu_l1d_if`     | LSU->L1D                | Load/store data path                                      |
| `l1i_bus_if`     | L1I->BUS                | I-cache miss read                                         |
| `l1d_bus_if`     | L1D->BUS                | D-cache miss read + write-through                         |

### RNU internal (`rapt_rnu_internal_if.svh`)

| Interface   | Description                                              |
| ----------- | -------------------------------------------------------- |
| `rnu_fl_if` | Freelist: dual alloc (A/B), dual dealloc, flush recovery |
| `rnu_mt_if` | MapTable: 6R + 2W (MAP), 2W (RAT)                        |

## Configuration (`rapt_config.svh`)

| Parameter            | Default   | Description                                |
| -------------------- | --------- | ------------------------------------------ |
| `RAPT_XLEN`          | 32        | Register width (64 with `RAPT_RV64`)       |
| `RAPT_M_FAST`        | 1         | Single-cycle mul/div (sim mode)            |
| `RAPT_L1I_LINE_LEN`  | 4         | L1I line: 2⁴ = 16 words (64 B in RV32)     |
| `RAPT_L1I_LEN`       | 5         | L1I sets: 2⁵ = 32                          |
| `RAPT_L1I_N_WAYS`    | 2         | L1I ways (2-way SA)                        |
| `RAPT_L1I_REFILL_WORDS` | 8      | Words per L1I sector refill (capped at line size) |
| `RAPT_PHT_SIZE`      | 256       | PHT entries                                |
| `RAPT_BTB_SIZE`      | 128       | BTB entries (64 sets × 2 ways)             |
| `RAPT_BTB_WAYS`      | 2         | BTB associativity                          |
| `RAPT_RSB_SIZE`      | 4         | Return stack entries                       |
| `RAPT_BPU_DIRP_TAGE` | defined   | Default direction predictor                |
| `RAPT_RIQ_SIZE`      | 8         | Rename queue (RNQ) entries                 |
| `RAPT_IIQ_SIZE`      | 8         | Dispatch queue (UOQ) entries               |
| `RAPT_ROB_SIZE`      | 64        | Reorder buffer entries                     |
| `RAPT_RS_SIZE`       | 8         | ALU issue queue (ALQ) entries, shared by ALU-CSR/ALU |
| `RAPT_IOQ_SIZE`      | 8         | In-order memory queue entries              |
| `BRQ_SIZE` (param)   | 4         | Branch issue queue entries                 |
| `MDQ_SIZE` (param)   | 4         | MUL/DIV issue queue entries                |
| `RAPT_SQ_SIZE`       | 16        | Unified store queue entries                |
| `RAPT_L1D_LINE_LEN`  | 4 / 3     | RV32: 16 words/line; RV64: 8 words/line    |
| `RAPT_L1D_LEN`       | 4         | L1D sets: 2⁴ = 16                          |
| `RAPT_L1D_N_WAYS`    | 2         | L1D ways (2-way SA)                        |
| `RAPT_L2_EN`         | undefined | Optional L2 defaults to passthrough        |
| `RAPT_L2_LEN`        | 8         | L2 sets: 2⁸ = 256 when enabled             |
| `RAPT_L2_N_WAYS`     | 1         | L2 ways when enabled                       |
| `RAPT_DUAL_COMMIT`   | defined   | Retire up to 2 ROB entries/cycle           |
| `RAPT_DUAL_ISSUE`    | defined   | Dual-issue: 2 insts/cycle through pipeline |
| `RAPT_ISSUE_WIDTH`   | 2         | Dispatch width (2 when dual-issue, else 1) |
| `RAPT_PHY_SIZE`      | 128       | Physical registers                         |

## Key Types (`rapt_pkg.sv`)

| Type               | Description                                                                                   |
| ------------------ | --------------------------------------------------------------------------------------------- |
| `uop_t`            | Micro-op: alu, branch, mem, CSR, trap, pc, inst, imm                                          |
| `prd_t`            | Physical register descriptor: op1/op2 + pr1/pr2/prd/prs                                       |
| `rob_state_t`      | ROB state: `ROB_CM` (committed), `ROB_WB` (written-back), `ROB_EX` (executing)                |
| `rob_entry_t`      | Full ROB entry: phys regs, arch rd, state, branch, memory, atomics, CSR, trap, fence, inst/PC |
| `addr_cacheable()` | Returns true for cacheable regions (mrom, flash, psram, sdram)                                |
| `addr_mapped()`    | Returns true for any mapped memory or MMIO region                                             |
| `addr_mmio()`      | Returns true for MMIO regions that difftest should skip                                       |
