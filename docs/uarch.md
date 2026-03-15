# Microarchitecture (uarch)

## Overview

Raptor is an out-of-order, single-issue RISC-V processor core with register renaming, a reorder buffer (ROB), reservation stations, and virtual memory support.

**ISA**: RV32/RV64 I + M (mul/div) + A (atomics: LR/SC, AMO) + C (compressed) + Zicsr + Sv32 MMU

The core supports configurable **RV32** and **RV64** modes via a compile-time switch (`YSYX_RV64`). When `YSYX_RV64` is defined, XLEN=64 and all datapath, register file, AXI bus, and DPI-C interfaces widen to 64 bits. RV64 adds W-variant instructions (ADDIW, SLLIW, etc.) with 32-bit result sign-extension.

```text
 Pipeline Overview — 3 major partitions

 ┌─ FRONTEND (in-order, speculative) ──────────────────────┐
 │ IFU  — Instruction Fetch Unit (3-state FSM)             │
 │   ├─ L1I  (direct-mapped I-cache, TLB, Sv32 PTW, IFQ)   │
 │   └─ BPU  (bimodal PHT, BTB, GHR, RSB)                  │
 │ IDU  — Instruction Decode Unit                          │
 │   └─ RVC expansion + Chisel-generated decoders          │
 └─────────────────────────────────────────────────────────┘

 ┌─ BACKEND (rename → dispatch → execute → commit) ────────┐
 │ RNU  — Register Naming Unit (pure rename)               │
 │   ├─ RNQ     (rename queue, circular, RIQ_SIZE)         │
 │   ├─ Freelist (rnu_fl_if, circular FIFO, PHY_SIZE)      │
 │   └─ MapTable (rnu_mt_if, spec MAP + committed RAT)     │
 │ PRF  — Physical Register File (top-level, 2R/2W)        │
 │ ROU  — Re-Order Unit (ROB + dispatch)                   │
 │   ├─ UOQ  (dispatch queue, circular, IIQ_SIZE)          │
 │   ├─ ROB  (rob_entry_t[], ROB_SIZE, head/tail)          │
 │   └─ Operand bypass (EXU/IOQ → dispatch)                │
 │ EXU  — Execution Unit (out-of-order)                    │
 │   ├─ RS   (reservation station, RS_SIZE)                │
 │   │   ├─ ALU  (RV32I combinational)                     │
 │   │   └─ MUL  (RV32M, Booth's / iterative div)          │
 │   └─ IOQ  (in-order queue, IOQ_SIZE, for ld/st/amo)     │
 │ CMU  — Commit Unit (broadcast retire info, in-order)    │
 │ CSR  — M/S-mode CSR file + trap/interrupt handling      │
 └─────────────────────────────────────────────────────────┘

 ┌─ MEMORY SUBSYSTEM ──────────────────────────────────────┐
 │ LSU  — Load/Store Unit                                  │
 │   ├─ STQ  (store temp queue, speculative, SQ_SIZE)      │
 │   ├─ SQ   (store queue, committed, SQ_SIZE)             │
 │   └─ Store-to-load forwarding (CAM, virtual address)    │
 │ L1D  — Data Cache (direct-mapped, banked SRAM, RMW)     │
 │   └─ Reservation register (LR/SC atomics)               │
 │ TLB  — Translation Lookaside Buffer (reusable module)   │
 │   ├─ ITLB (L1I), DTLB (L1D load), DSTLB (L1D store)   │
 │ PTW  — Page Table Walker (Sv32, reusable module)        │
 │   ├─ IPTW (L1I), DPTW (L1D)                            │
 │ BUS  — AXI4 master bridge (L1I/L1D arbitration)         │
 │   └─ CLINT (mtime timer, periodic interrupt)            │
 └─────────────────────────────────────────────────────────┘
```

## Pipeline Data Flow

```text
 ┌─ frontend (in-order, speculative) ──────────────────────┐
 │      v─ [BUS <─load─ AXI4]                              │
 │  IFU[l1i,tlb,ifq] ═issue═> IDU                          │
 │      ^─ bpu[btb(COND/DIRE/INDR/RETU),pht,ghr,rsb]       │
 └─────────────────────────────────────────────────────────┘
          ║ ifu_idu_if
 ┌─ backend (rename → dispatch → execute → commit) ────────┐
 │  IDU ═issue═> RNU[rnq,freelist,maptable]                │
 │  RNU ═rename═> ROU[uoq]                                 │
 │  ROU[uoq] ─dispatch─> ROU[rob(rob_entry_t)]             │
 │           ═dispatch═> EXU[rs] / EXU[ioq]                │
 │                                                         │
 │  EXU[rs] ═writeback═> ROU[rob]   (via exu_rou_if)       │
 │      ^─ ALU :alu ops                                    │
 │      ├─ MUL :mult/div (Booth's / iterative)             │
 │  EXU[ioq] ═writeback═> ROU[rob]  (via exu_ioq_bcast_if) │
 │      ^─ CSR :Zicsr read                                 │
 │      ├─ AMO :atomics (LR/SC/AMO*)                       │
 │                                                         │
 │  ROU[rob] ═commit═> CMU & LSU[sq] & CSR                 │
 │  CMU ═broadcast═> frontend: IFU[pc], BPU[update]        │
 └─────────────────────────────────────────────────────────┘
          ║ exu_lsu_if, rou_lsu_if, lsu_l1d_if
 ┌─ memory subsystem ──────────────────────────────────────┐
 │  LSU[stq] (speculative store temp queue)                │
 │  LSU[sq ] (committed store queue → L1D/BUS)             │
 │  L1D[dtlb,dstlb,dptw] → BUS → AXI4 (write-through)     │
 │  TLB (reusable: itlb, dtlb, dstlb)                      │
 │  PTW (reusable: iptw, dptw — Sv32 walker)                │
 └─────────────────────────────────────────────────────────┘
```

## Module Details

### Frontend

#### IFU — Instruction Fetch Unit (`ysyx_ifu.sv`)

- **FSM**: 3-state (`IDLE` → `VALID` → `STALL`)
- Sends PC to L1I cache and BPU in parallel
- Next-PC mux priority: flush redirect > BPU taken > sequential (PC+2/+4)
- Pre-decodes compressed instruction bit for PC stride (2 vs 4)
- Stalls pipeline on system/atomic/trap instructions until flush completes

#### BPU — Branch Prediction Unit (`ysyx_bpu.sv`)

- **PHT**: 2-bit saturating counters, `PHT_SIZE` entries (default 512), bimodal indexing
- **GHR**: Global History Register, 11 bits
- **BTB**: `BTB_SIZE` entries (default 64), 7-bit tag, XOR-hash index
  - Entry types: `COND` (conditional), `DIRE` (direct jump), `INDR` (indirect), `RETU` (return)
- **RSB**: Return Stack Buffer, `RSB_SIZE` entries (default 8)
- Updates: PHT on committed branches, BTB on flushes
- Reset: PHT/BTB invalidated on `fence_time`

#### L1I — Instruction Cache (`ysyx_l1i.sv`)

- Direct-mapped, `2^L1I_LEN` entries (default 64, 6-bit index)
- Line size: `2^L1I_LINE_LEN` words (default 2 words per line)
- **Data storage**: Banked `ysyx_sram_1r1w` instances (one per word position) with synchronous read (1-cycle latency)
- **SRAM data readiness**: `pc_ifu_d1` register tracks PC stability; `sram_data_ready = (pc_ifu_d1 == pc_ifu)` ensures SRAM output matches the current fetch address before asserting `valid`
- **Tag/Valid**: Register arrays (multi-port read, fast bulk invalidation)
- **IFQ**: 2-entry instruction fetch queue for outstanding requests
- **ITLB**: `ysyx_tlb` instance (`u_itlb`, default 4 entries, ASID-aware, combinational lookup)
- **PTW**: `ysyx_ptw` instance (`u_iptw`), shares AXI read channel with cache fill; `ptw_req` issued on TLB miss in IDLE
- Address validation via `ysyx_pkg::addr_valid()`
- Supports 16-bit alignment for RVC (cross-word fetch)
- `fence.i` invalidation support
- **FSM**: 7-state (`IDLE`, `PTWAIT`, `TRAP`, `RD_A`, `RD_0`, `RD_1`, `FINA`)

#### IDU — Instruction Decode Unit (`ysyx_idu.sv`)

- **FSM**: 2-state (`IDLE`, `VALID`) with valid/ready handshake
- Instantiates `ysyx_idu_decoder_c` (RVC expansion) and `ysyx_idu_decoder` (Chisel-generated)
- `csr_addr_valid()` function validates all M-mode + S-mode CSR addresses
- Aggregates traps from IFU (page faults) and decode-time errors (illegal inst/CSR)
- Outputs full `uop_t` micro-op struct

### Backend

#### RNU — Register Naming Unit (`ysyx_rnu.sv`)

- Pure rename stage: maps architectural registers → physical registers
- **RNQ**: Circular rename queue, `RIQ_SIZE` entries (default 4), buffers uops from IDU
- **Freelist** (`ysyx_rnu_freelist.sv`): Circular FIFO, `PHY_SIZE` entries (default 64)
  - Allocates physical register on rename, deallocates on commit
  - Flush recovery: rewinds head pointer by in-flight count
  - Initial state: first 32 entries identity-mapped, rest free
- **MapTable** (`ysyx_rnu_maptable.sv`): Dual-table design
  - **MAP**: Speculative rename map, 3 read ports (rs1, rs2, rd\_old)
  - **RAT**: Committed architectural map, written on ROB commit
  - Flush recovery: MAP ← RAT (with concurrent commit write forwarding)
- Outputs: `map_snapshot` / `rat_snapshot` for PRF debug view

#### PRF — Physical Register File (`ysyx_prf.sv`)

- `PHY_SIZE` entries (default 64), 2 read ports + 2 write ports
- Instantiated at top level (`ysyx.sv`), shared resource
- **Valid tracking**: `prf_valid[]` bits per physical register
- **Transient tracking**: `prf_transient[]` bits for speculative writes
  - On flush: transient registers invalidated and zeroed
  - On commit: transient bit cleared
  - On dealloc: valid bit cleared
- Write port A: `exu_rou_if` (ALU/RS writeback)
- Write port B: `exu_ioq_bcast_if` (IOQ/LSU/CSR writeback)
- Read port: `exu_prf_if` (operand fetch for ROU dispatch)
- Debug: `rf[]` (committed view via RAT), `rf_map[]` (speculative view via MAP)

#### ROU — Re-Order Unit (`ysyx_rou.sv`)

- **UOQ**: Circular dispatch queue, `IIQ_SIZE` entries (default 4)
- **ROB**: `rob_entry_t` struct array, `ROB_SIZE` entries (default 8), head/tail pointers
  - States: `ROB_EX` (executing) → `ROB_WB` (written back) → `ROB_CM` (committed)
- **Operand bypass**: Forwards from EXU/IOQ broadcasts to dispatch operands
  - Priority: PRF > IOQ broadcast > EXU broadcast
- **Commit**: In-order, waits for ROB head `ROB_WB` + store queue ready
- **Flush triggers**: fence\_i, branch mispredict, trap, system op, atomic
- **Async trap**: Timer interrupt from CLINT (`clint_trap`)
- Interfaces: `rou_exu_if` (dispatch to EXU), `rou_csr_if` (CSR commit), `rou_lsu_if` (store commit)

#### EXU — Execution Unit (`ysyx_exu.sv`)

- **RS** (Reservation Station): `RS_SIZE` entries (default 4)
  - Operand forwarding from both EXU and IOQ broadcasts
  - Priority issue: first ready entry with both operands available
  - Submodules: `ysyx_exu_alu` (combinational), `ysyx_exu_mul` (multi-cycle)
- **IOQ** (In-Order Queue): `IOQ_SIZE` entries (default 4), circular FIFO
  - Handles: load/store, atomics (LR/SC, AMO\*), Zicsr (CSRRW/S/C)
  - In-order issue, also supports operand forwarding
- **ALU** (`ysyx_exu_alu.sv`): Purely combinational RV32I ops (ADD/SUB/SLT/XOR/OR/AND/SLL/SRL/SRA/comparisons)
- **MUL** (`ysyx_exu_mul.sv`): RV32M ops with two modes:
  - Fast mode (`YSYX_M_FAST`): single-cycle (for simulation)
  - Iterative: Booth's multiplication (33/65 cycles), restoring division (32 cycles)
- **Atomics**: Full AMO support — LR/SC with reservation, AMOSWAP/ADD/XOR/AND/OR/MIN/MAX
- **Store MMU**: Address translation via `exu_l1d_if`
- **Difftest skip detection**: RS detects CSR reads from TIME/TIMEH/CYCLE/MCYCLE/MCYCLEH; IOQ detects MMIO store addresses and load `difftest_skip` from LSU. Propagated via `exu_rou.difftest_skip` and `exu_ioq_bcast.difftest_skip` to ROB.

#### CMU — Commit Unit (`ysyx_cmu.sv`)

- Lightweight broadcast unit: receives commit info from ROU, broadcasts to pipeline
- Broadcasts: `rpc` (retire PC), `cpc` (correct/redirect PC), branch resolution, `flush_pipe`, `fence_i`, `fence_time`, `time_trap`
- Tracks instruction retire count (`pmu_inst_retire`)
- DPI-C hooks for difftest and ebreak
- **Difftest skip**: Issues `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF` at commit time when `rou_cmu.difftest_skip` is set (MMIO loads/stores, CSR time reads)

#### CSR — Control & Status Registers (`ysyx_csr.sv`)

- 32-entry CSR register file, M-mode + S-mode
- Handles trap entry/exit: `ecall`, `ebreak`, `mret`, `sret`
- Privilege mode transitions (M/S/U)
- Trap delegation (`medeleg` / `mideleg`)
- `MSTATUS` ↔ `SSTATUS` mirroring
- `mcycle` / `time` counters
- Broadcasts: `priv`, `satp_ppn`, `satp_asid`, `immu_en`/`dmmu_en`, `tvec`, `interrupt_en`

### Memory Subsystem

#### LSU — Load/Store Unit (`ysyx_lsu.sv`)

- **STQ** (Store Temporary Queue): `SQ_SIZE` entries, speculative stores before commit; stores virtual address (`stq_waddr`) for forwarding comparison
- **SQ** (Store Queue): `SQ_SIZE` entries, committed stores pending L1D write; tracks both physical address (`sq_waddr` for bus write-through) and virtual address (`sq_vaddr` for forwarding)
- **Store FSM**: 2-state (`LS_S_V`, `LS_S_R`)
- **Store-to-load forwarding**: CAM search of SQ by virtual address (`sq_vaddr`), age-ordered youngest-match-wins
- Load data alignment/sign-extension (LB/LBU/LH/LHU/LW)
- Loads blocked while SQ/STQ non-empty (memory ordering)
- `difftest_skip` propagated from L1D through to EXU

#### L1D — Data Cache (`ysyx_l1d.sv`)

- Direct-mapped, `2^L1D_LEN` sets (default 64, 6-bit index)
- Line size: `2^L1D_LINE_LEN` words per line (default 2), parameterized
- **Data storage**: Banked `ysyx_sram_1r1w` instances (one per word position via `gen_data_bank` generate loop) with synchronous read (1-cycle latency)
- **Tag/Valid**: Per-word register arrays (`l1d_valid[set][word]`, `l1d_tag[set][word]`), enabling simultaneous load/store hit check and fast fence invalidation
- **Hit logic**: Split into `tag_hit` (combinational from register tags in `LD_A`, guarded by `sram_bypass_r` to prevent write-first bypass corruption) and `data_hit` (SRAM data ready). Bus requests suppressed by `tag_hit`; load data returned by `data_hit`.
- Write-through policy: full-word writes update cache; partial stores (SB/SH) use **Read-Modify-Write (RMW)** — 2-cycle merge: read old SRAM word, byte-lane merge, write back (`l1d_rmw`, `rmw_merged_data`). RMW only fires in IDLE when SRAM read port is free (`partial_store_rmw`). Falls back to invalidation when read port is busy.
- **Speculative SRAM read**: In IDLE with a pending load, drives incoming virtual index directly (VIPT safe: `L1D_LEN+L1D_LINE_LEN+OFFSET_BITS < 12`). RMW steers `sram_raddr` to store's set when active.
- **Load TLB**: `ysyx_tlb` instance (`u_dtlb`, default 4 entries, ASID-aware, combinational lookup)
- **Store TLB (STLB)**: Separate `ysyx_tlb` instance (`u_dstlb`) for store address translation
- **PTW**: Shared `ysyx_ptw` instance (`u_dptw`) for both load and store TLB misses; `ptw_req` issued on TLB miss in IDLE, `stlb_mmu` flag distinguishes store vs load PTW
- **Reservation register**: For LR/SC atomics
- Misalignment detection for loads/stores
- Cacheability via `ysyx_pkg::addr_cacheable()`
- `fence_time` invalidates entire cache
- **FSM**: 5-state (`IDLE`, `PTWAIT`, `TRAP`, `LD_A`, `LD_D`)

#### TLB — Translation Lookaside Buffer (`ysyx_tlb.sv`)

- Reusable fully-associative TLB module for Sv32 page translation
- Parameterized entry count (`ENTRIES`, default 4), ASID-aware
- **Lookup**: Combinational — matches `lookup_vtag` + `lookup_asid` against all entries simultaneously
- **Fill**: Sequential on `fill_valid` (posedge clock), only fills on miss (no duplicate entries)
- **Replacement**: Round-robin (`rr_ptr`)
- **Flush**: Bulk invalidation via `flush` input (used by `fence_time`)
- Instantiated as: `u_itlb` (L1I), `u_dtlb` (L1D load), `u_dstlb` (L1D store)

#### PTW — Page Table Walker (`ysyx_ptw.sv`)

- Reusable Sv32 two-level page table walker module
- **FSM**: 3-state (`IDLE` → `LVL1` → `LVL0`)
  - `LVL1`: Reads first-level PTE using `vpn[1]`
  - `LVL0`: Reads second-level PTE using `vpn[0]` (if LVL1 was non-leaf)
- Leaf detection: `PTE.R || PTE.X` → superpage (LVL1 leaf) or regular page (LVL0 leaf)
- **Outputs**: `done` (translation complete), `fault` (page fault), `result_ptag`/`result_vtag` (for TLB fill)
- Shares AXI read channel with cache fill (`bus_arvalid`/`bus_araddr`/`bus_rdata`)
- RV64-aware: selects correct 32-bit PTE half from 64-bit bus read (`ppn_a[2]`)
- Instantiated as: `u_iptw` (L1I), `u_dptw` (L1D)

#### BUS — AXI4 Bus Bridge (`ysyx_bus.sv`)

- Arbitrates L1I and L1D requests to single AXI4 master port
- L1D has priority over L1I for reads
- **Read FSM**: 3-state (`LD_A`, `LD_AS`, `LD_D`)
- **Write FSM**: 3-state (`LS_S_A`, `LS_S_W`, `LS_S_B`)
- Load source tracking: `L1I` / `L1D` / `TLBI` / `TLBD`
- L1I issues individual word reads (no burst)
- CLINT reads handled locally (not sent over AXI)
- **Difftest**: MMIO detection via `l1d_load_is_mmio` flag (latched on L1D load request), propagated via `l1d_bus.difftest_skip` to commit stage

#### CLINT — Core Local Interrupt Controller (`ysyx_clint.sv`)

- 64-bit `mtime` counter
- Periodic timer interrupt every 262144 cycles (`mtime[18:0] == 0x40000`)
- Reads return lower or upper 32 bits of `mtime` based on address
- Instantiated inside BUS module

## Interface Summary

### Inter-module interfaces (`ysyx_if.svh`, `ysyx_*_if.svh`)

| Interface | Direction | Description |
|-----------|-----------|-------------|
| `ifu_bpu_if` | IFU → BPU | PC for prediction, NPC + taken back |
| `ifu_l1i_if` | IFU → L1I | PC fetch request, inst + trap response |
| `ifu_idu_if` | IFU → IDU | Fetched instruction + PC + predicted NPC |
| `idu_rnu_if` | IDU → RNU | Decoded uop + operands + arch reg IDs |
| `rnu_rou_if` | RNU → ROU | Renamed uop + physical reg mappings |
| `rou_exu_if` | ROU → EXU | Dispatched uop + operands + ROB dest |
| `rou_lsu_if` | ROU → LSU | Store commit (addr/data/alu) |
| `rou_csr_if` | ROU → CSR | CSR write + trap/system on commit |
| `rou_cmu_if` | ROU → CMU | Commit info (PC, branch, fence, flush) |
| `exu_rou_if` | EXU → ROU | RS writeback (result, branch, CSR, trap) |
| `exu_ioq_bcast_if` | EXU → ROU/PRF/LSU | IOQ broadcast (ld/st/CSR result) |
| `exu_prf_if` | ROU → PRF | Operand read (2 ports, valid check) |
| `exu_lsu_if` | EXU(IOQ) → LSU | Load request (addr/alu/atomic) |
| `exu_csr_if` | EXU → CSR | CSR read port |
| `exu_l1d_if` | EXU → L1D | Store MMU + SC reservation check |
| `cmu_bcast_if` | CMU → all | Retire broadcast (flush, fence, branch) |
| `csr_bcast_if` | CSR → all | Priv mode, SATP, MMU enable, tvec |
| `lsu_l1d_if` | LSU → L1D | Load/store data path |
| `l1i_bus_if` | L1I → BUS | I-cache miss read |
| `l1d_bus_if` | L1D → BUS | D-cache miss read + write-through |

### RNU internal interfaces (`ysyx_rnu_internal_if.svh`)

| Interface | Description |
|-----------|-------------|
| `rnu_fl_if` | Freelist: alloc\_req/alloc\_pr (rename), dealloc (commit), flush recovery |
| `rnu_mt_if` | MapTable: 3 read ports (rs1, rs2, rd\_old), spec write (MAP), commit write (RAT) |

## Configuration Parameters (`ysyx_config.svh`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `YSYX_XLEN` | 32 | Register width |
| `YSYX_I_EXTENSION` | 1 | RV32I base |
| `YSYX_M_EXTENSION` | 1 | M extension (mul/div) |
| `YSYX_M_FAST` | 1 | Single-cycle mul/div (sim mode) |
| `YSYX_L1I_LINE_LEN` | 1 | L1I line: 2^1 = 2 words |
| `YSYX_L1I_LEN` | 6 | L1I entries: 2^6 = 64 |
| `YSYX_PHT_SIZE` | 512 | PHT entries |
| `YSYX_BTB_SIZE` | 64 | BTB entries |
| `YSYX_RSB_SIZE` | 8 | Return stack entries |
| `YSYX_RIQ_SIZE` | 4 | Rename queue (RNQ) entries |
| `YSYX_IIQ_SIZE` | 4 | Dispatch queue (UOQ) entries |
| `YSYX_ROB_SIZE` | 8 | Reorder buffer entries |
| `YSYX_RS_SIZE` | 4 | Reservation station entries |
| `YSYX_IOQ_SIZE` | 4 | In-order queue entries |
| `YSYX_SQ_SIZE` | 8 | Store queue entries |
| `YSYX_L1D_LINE_LEN` | 1 | L1D line: 2^1 = 2 words per line |
| `YSYX_L1D_LEN` | 6 | L1D sets: 2^6 = 64 |
| `YSYX_ISSUE_WIDTH` | 1 | Instructions dispatched per cycle |
| `YSYX_REG_SIZE` | 32 | Architectural registers |
| `YSYX_PHY_SIZE` | 64 | Physical registers |

## Key Types (`ysyx_pkg.sv`)

| Type | Description |
|------|-------------|
| `uop_t` | Micro-op: decoded instruction fields (alu, branch, mem, CSR, trap, pc, inst, imm) |
| `prd_t` | Physical register descriptor: op1/op2 values + pr1/pr2/prd/prs mappings |
| `rob_state_t` | ROB entry state enum: `ROB_CM` (committed), `ROB_WB` (written-back), `ROB_EX` (executing) |
| `rob_entry_t` | Full ROB entry: phys regs, arch rd, state, branch/jump, memory, atomics, CSR, trap, fence, difftest_skip, inst/PC |
| `addr_cacheable()` | Function: returns true if address is in a cacheable region (mrom, flash, psram, sdram) |
| `addr_valid()` | Function: returns true if address is in any valid memory-mapped region |

## Mermaid Diagram

mermaid [^1] diagram [^2] of the uarch:

```mermaid
flowchart TD
 subgraph FE["Frontend (in-order)"]
        IFU["IFU (3-state FSM)"]
        L1I["L1I (direct-mapped, ITLB, PTW)"]
        IFQ["IFQ (2-entry)"]
        IDU["IDU (RVC + decoder)"]
        BPU["BPU (PHT/BTB/GHR/RSB)"]
  end
 subgraph BE["Backend (rename → dispatch → execute → commit)"]
        subgraph RNU_TOP["RNU (pure rename)"]
            RNQ["RNQ (RIQ_SIZE)"]
            FL["Freelist (rnu_fl_if)"]
            MT["MapTable (rnu_mt_if)"]
        end
        PRF["PRF (2R/2W, valid+transient)"]
        ROU["ROU (UOQ + ROB: rob_entry_t[])"]
        EXU["EXU"]
        RS["RS (RS_SIZE)"]
        IOQ["IOQ (IOQ_SIZE, in-order)"]
        ALU["ALU (RV32I)"]
        MUL["MUL (RV32M, Booth)"]
        CMU["CMU (retire broadcast)"]
        CSR["CSR (M/S-mode, Sv32)"]
  end
 subgraph MEM["Memory Subsystem"]
        LSU["LSU (STQ + SQ, forwarding)"]
        L1D["L1D (direct-mapped, banked SRAM, RMW)"]
        TLB["TLB (reusable: ITLB, DTLB, DSTLB)"]
        PTW["PTW (reusable: IPTW, DPTW)"]
        BUS["BUS (AXI4 bridge)"]
        CLINT["CLINT (mtime, timer IRQ)"]
  end
    BPU -->|"npc,taken"| IFU
    IFU -->|"ifu_l1i_if"| L1I
    L1I --- IFQ
    L1I -->|"inst"| IFU
    IFU -->|"ifu_idu_if"| IDU
    IDU -->|"idu_rnu_if"| RNU_TOP
    RNQ --> FL & MT
    RNU_TOP -->|"rnu_rou_if"| ROU
    ROU -->|"exu_prf_if"| PRF
    ROU -->|"rou_exu_if"| EXU
    EXU --> RS & IOQ
    RS --> ALU & MUL
    IOQ -->|"exu_lsu_if"| LSU
    IOQ -->|"exu_csr_if"| CSR
    RS -->|"exu_rou_if"| ROU
    IOQ -->|"exu_ioq_bcast_if"| ROU
    EXU -->|"write"| PRF
    ROU -->|"rou_cmu_if"| CMU
    ROU -->|"rou_csr_if"| CSR
    ROU -->|"rou_lsu_if"| LSU
    CMU -->|"cmu_bcast_if"| IFU & BPU
    LSU -->|"lsu_l1d_if"| L1D
    EXU -->|"exu_l1d_if"| L1D
    L1I --- TLB & PTW
    L1D --- TLB & PTW
    L1I -->|"l1i_bus_if"| BUS
    L1D -->|"l1d_bus_if"| BUS
    BUS <-->|"AXI4"| AXI["AXI4 Master"]
    CLINT --- BUS
    CSR -->|"csr_bcast_if"| L1I & L1D & EXU
```

[^1]: https://mermaid.js.org/
[^2]: https://www.mermaidchart.com/play
