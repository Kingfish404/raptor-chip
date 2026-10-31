---
title: Microarchitecture
---

# Microarchitecture

The default core is two-wide with a 32-entry ROB. Start with the
[configuration table](#default-configuration), then follow the pipeline and block
contracts below. Capacities refer to the current RTL; cycle sequences describe
ideal paths and are not benchmark results. The default RV64 configuration supports
[RVA22S64](./README.md#rva22s64-support); the linked overview defines the ISA and
supervisor scope and points to requirement-level verification evidence.

## Pipeline stages

`En` is the n-th clock edge that captures an instruction; cycle *n* is the logic between `En` and `En+1`. An ALU instruction passes 13 edges from fetch PC to retirement: 9 in-order edges up to ROB allocation, 1 to enter an issue queue, 1 to execute, and 2 to write back and retire. Every ordered buffer is registered without empty-queue fall-through, so each one costs an edge even when it is empty.

The numbers assume warm L1I/L1D, ready operands, free queue capacity, and no redirect. They were confirmed by tracing single instructions through the integrated core (default preset, RV32, isolated by serializing CSR writes). The other `default*` presets have the same stage structure: `RAPT_FETCH_RESPONSE_STAGE` and `RAPT_IOQ_LOAD_RESPONSE_STAGE` are 0 in all of them, and the integrated core always sets `RegisteredDispatchPayload`.

| Edge | Register (module) | Logic in the preceding cycle | Kind |
| --- | --- | --- | --- |
| E0 | Fetch PC `pc_ifu_q` (IFU) | Next-PC select: BPU prediction, IDU resteer, recovery or flush redirect, L1I data pre-read | loop |
| E1 | Fetch packet `held` (IFU) | L1I tag compare and way select, instruction walk and RVC handling, packet cut at a control instruction | logic |
| E2 | FQU | Queue write | buffer |
| E3 | IDU input | Queue read and regrouping | buffer |
| E4 | RNQ (RNU) | Decode; decode-time jump, return and target correction; speculative history update | logic |
| E5 | `rename_pipe` (RNU) | Rename: map lookup, intra-group dependencies, free-list and checkpoint allocation | logic |
| E6 | `rapt_operand_stage` | None (pipeline register) | buffer |
| E7 | UOQ (ROU) | UOQ admission of tags and constants | buffer |
| E8 | ROB entry and dispatch carry lane (ROU) | ROB allocation and spill write | logic |
| E9 | Issue-queue entry, or IOQ load request | Dispatch window, PRF read with completion bypass, domain steering | logic |
| E10 | Completion register | Issue select, execute, completion guard, local wakeup | loop |
| E11 | `ROB_WB` (ROU) | ROB writeback, registered wakeup, recovery transaction | logic |
| E12 | Commit (ROU/CMU) | In-order retirement, RAT and free-list update, CMU broadcast | logic |

"Kind" marks where to look first when you re-split the pipeline. *Buffer* cycles hold little more than a queue write or read. *Loop* cycles are single-cycle feedback loops: E0 feeds the fetch PC back to itself, and E10 lets a dependent issue on the next cycle. Splitting a loop cycle costs IPC directly; splitting a logic cycle adds an edge to every instruction.

Per-class edge sequences:

```text
ALU     E0..E8 | E9 ALQ entry  | E10 completion | E11 ROB_WB | E12 commit                    13 edges
Load    E0..E8 | E9 request    | E10 L1D data   | E11 completion | E12 ROB_WB | E13 commit   14 edges
Store   E0..E8 | E9 IOQ entry  | E10 addr/perm  | E11 completion + SQ | E12 ROB_WB | E13 commit, then SQ drain
MUL     E0..E8 | E9 MDQ entry  | E10 M1 | E11 M2 | E12 completion | E13 ROB_WB | E14 commit     15 edges
Branch  E0..E8 | E9 BRQ entry  | E10 completion | E11 recovery register | E12 = target E0 on a mispredict
```

The load row is an aligned, cacheable Bare-mode hit whose base register is ready at dispatch, so the load enters the registered request stage directly from dispatch. The store row completes when its address and permission are checked; it drains from the SQ after commit. Divides are iterative and stay in M1 for about 2 + ceil(significant dividend bits / 2) cycles. FP units add their own latency, with the shared FMA/MUL product pipeline at eight cycles.

| Dependency or event | Cycles |
| --- | --- |
| ALU → dependent ALU or branch | 1 (back to back) |
| Load hit → dependent ALU | 2 |
| MUL → dependent ALU | 3 |
| Result → a consumer outside ALQ/BRQ (ROU dispatch bypass, IOQ, MDQ, FEU integer sources) | +1 over the rows above |
| Branch mispredict, from branch execute to target execute | 12 |
| Unpredicted direct jump, corrected in IDU | 3 bubbles before the target reaches IDU |

The first three rows rely on local wakeup: ALQ and BRQ take integer, load, branch-link and MUL results straight from the accepted completion before it is registered. FPQ does the same for FP results. Every other consumer sees only the registered completion, so it waits one more cycle.

The mispredict row assumes the branch is at the ROB head. Its recovery transaction is registered at the branch's E11. The target PC is captured at E12 and refetched at once, and the L1I pre-reads the target. IDU then waits until the branch retires before it accepts the target, so a branch that is not at the head adds its wait for retirement.

These are ideal sequences, not fixed latencies. Queue or operand waits, `ROB_DP` residence, translation, cache misses, MSHR replay, and bus responses all lengthen a path. Retirement needs the stored `ROB_WB` state and an owner inside the ready head prefix. Reset or flush kills a completion before it is registered.

The `default*`, `small-cache`, and `middle-cache` presets use L1D write-back:
- Eligible cacheable store hits complete locally. Without inclusive L2, aligned full-word misses can also allocate locally.
- Device, uncacheable, and other nonallocating stores wait for the B response.
- Explicit write-through configurations without L2 can set `RAPT_POSTED_WRITES=4`. Eligible stores are then released when AXI accepts the write, with up to four B responses pending.

## Organization

Raptor is a configurable RV32/RV64 out-of-order core with a two-wide default
preset. `rapt_core` composes `rapt_frontend` (prediction, fetch, FQU, decode),
`rapt_backend` (rename, operand stage, ROB, dispatch, issue, completion, LSU,
precise commit), and `rapt_memory` (L1I, L1D, translation, bus interface unit).
The cluster top `rapt` places `rapt_l2_subsystem` between the core and device
router. Every core memory/device access leaves through `l2_client_if`; the
L2 subsystem always owns AXI and the outstanding-transaction budgets, with
cache storage only when enabled by a preset. `rapt_pkg::L2LinkConfig` adapts
the L2 macros into typed capabilities passed to the core, L1s, bus and router.
The current cluster has one core/client; a multi-client arbiter is future work.

Registers inside the blocks define the stage boundaries. Default decode,
rename, dispatch and commit widths are each two; instruction queues hold
individual instructions rather than fixed pairs. The `core` and `memory`
synthesis scopes exclude the L2 subsystem. Historical PPA from before this
split requires a matching-boundary comparison.

The [pipeline explorer](./explore.md) is an illustrative cycle model. It does not model current branch recovery, MSHR replay, or the direct integer completion path, so its cycle counts are not RTL timing or CoreMark IPC.

## Frontend: Fetch, queue, and decode

- **IFU and L1I:** The IFU walks complete 16/32-bit instructions in a six-halfword (three-word) L1I lookahead window, keeps any unconsumed suffix in a register, and ends a fetch group at a taken control, serializing, or faulting instruction, or before a second control instruction. A non-first `jalr` starts a new group so the BTB can be queried at its PC. `default-w4` and `default-w8` widen the window to eight halfwords (`RAPT_FETCH_WIDE`); all presets allow a group to continue past a predicted-not-taken conditional branch until the next control instruction, within the available fetch width. L1I is a 16 KiB, four-way cache with 64-byte lines, stored as four independently addressed 128-bit synchronous SRAM banks per way; pre-reads can hide the SRAM cycle for sequential fetch and for line crossings. A miss refills a 32-byte sector (`RAPT_L1I_REFILL_WORDS=8`) with individual AXI reads. The optional IFU response register is disabled in both the generic default preset and the fixed RV64 netboot profile. Miss refills, translation faults, and accepted-request ownership remain in L1I.
- **FQU and IDU:** FQU is a four-entry registered stream queue without empty-queue fall-through; it can regroup instructions across fetch packets. IDU registers its input, decodes each slot combinationally, and corrects accepted direct jumps, return predictions, or stale targets before rename. Flush and recovery invalidate resident frontend instructions.
- **BPU:** The default direction predictor is TAGE (a 1024-entry bimodal base plus three 1024-entry tagged tables with 8/16/64-bit histories in `default`, `default-w3` and `default-w4`; the shared fallback used by `default-l2` and `default-w8` is 256 + 3 x 128), with selectable gshare, bimodal, or static alternatives. Each preset must define exactly one `RAPT_BPU_DIRP_*` selector; if build flags introduce multiple selectors, RTL precedence is TAGE > GSHARE > BIMODAL > STATIC. Defining none causes a preprocessing error; static prediction requires an explicit selector. With lookahead, a packet's first non-first conditional branch uses TAGE's auxiliary read port whenever TAGE is selected; non-TAGE predictors supply not-taken for that query. This is shared behavior, not a separate preset switch. A 128-entry, two-way BTB (256 entries in `default-w3`/`default-w4`) supplies targets for the packet's first PC; IDU resteers and commit-time mispredictions train it. Prediction queries alone do not advance history: accepted conditional instructions update it speculatively at fetch and decode. A misprediction announcement restores GHR/PHR from its rename checkpoint, and a full flush restores the committed history. The RAS (16 entries in `default`; four in `default-l2` and `default-w8`) is updated at decode and restored from a committed copy on flush. TAGE trains at retirement.

The predictor query PC is `ifu_bpu.nextpc`. IFU and IDU report accepted branch-history events through `history_valid`, `history_taken`, and `history_pc_bit`; IDU also supplies `history_recover` for decode corrections.

## Backend: Rename, dispatch, and execution

- **RNU and PRF:** The eight-entry RNQ stores decoded instructions; RNU maps architectural GPRs to a 64-entry physical register file, resolves dependencies within a rename group, and writes a separate registered `rename_pipe` output queue (`2 x RenameWidth` entries). A separate `rapt_operand_stage` holds one renamed group before the ROU's eight-entry UOQ. The UOQ keeps physical tags and immediate-derived constants, not register values. PRF operands are read on the dispatch lane, and a value completing in that cycle is bypassed into the read. Commit updates the architectural RAT and releases stale mappings; a full flush rebuilds speculative MAP/free state from committed state. Branch checkpoints are a separate bounded resource: 16 by default, each holding GHR/PHR, a conditional-branch flag, and an ancestor set. They do not snapshot MAP/free state; that state is rebuilt from the post-commit RAT at the precise flush.
- **ROU and DPU:** UOQ feeds a 32-entry ROB with states `ROB_DP -> ROB_EX -> ROB_WB -> ROB_CM`. The integrated core sets `RegisteredDispatchPayload`, so a newly allocated owner is dispatched no earlier than the next cycle, from a registered carry lane. The module's live allocation lanes exist but are disabled, so allocation and dispatch never share an edge. Wide integer operand values for owners waiting in `ROB_DP` live in an operand spill bank (16 entries in `default`, eight in `default-w3` and `default-w4`) rather than in every ROB slot. DPU is a capacity-aware selector: it scans the registered dispatch window (12 lanes by default) and sends at most `DispatchWidth` full payloads to eligible domains. A blocked domain can leave an owner resident in `ROB_DP` while other domains progress. Every preset uses `rapt_rob_dispatch_window`. Its ranked resident owners and carried allocation lanes are registered, so full-ROB ranking does not feed operand reads and queue writes in the same cycle. The default window has eight ranked and two carried lanes; `default-w4` has four of each. Each preset also has two or four live lanes, which the integrated core leaves disabled.
- **Issue queues:** The default ALQ has eight entries and two integer issue ports, including in `default-w4`; BRQ has eight entries and MDQ has four, the FPQ has eight, and IOQ has eight. Integer/branch/FP issue queues capture operands and wake on accepted completions; ALQ selection and the simple ALU execute in the same cycle. Current IQ instances use the default `ReclaimOnIssue=0` module parameter in every preset: a slot issued on an edge cannot be reused on that same edge. This delays reuse without adding an execution stage.
- **Execution and completion:** One integer port owns CSR/system operations; FP has an independent completion endpoint. Branches use a separate compare path, and MUL/DIV uses a private queue with a two-stage pipelined multiply and an iterative divide that skips the dividend's leading zero bits in one normalization cycle and then resolves two quotient bits per cycle (about 2 + ceil(significant dividend bits / 2) cycles). For `N` integer ports the guarded fabric has `N+4` outputs: `N` integer, branch, memory, integer MUL/DIV and FP. Every accepted completion enters a completion register.
- **Local wakeup:** ALQ and BRQ capture integer, load, branch-link and MUL results from the live accepted packet. FPQ does the same for FP results.
- **Registered wakeup:** every other operand holder, including the ROU dispatch bypass, IOQ, MDQ and FEU integer sources, wakes from the registered copy, one cycle later.
- **Writeback and recovery:** ROU writes back the registered copy on the next edge, and retirement is possible on the edge after that. Recovery also consumes the registered copy. A ROB slot plus a 4-bit allocation generation identifies each live producer before it can affect ROB, register results or wakeup state.
- **Floating point and commit:** F/D and Zfhmin use the same value-capturing issue queue, age selection, accepted wakeup and recovery contracts as integers. The FP instance adds a third source for FMA and selects the oldest ready instruction whose arithmetic unit has capacity. Independent units overlap; a busy DIV/SQRT does not block ready ADD, conversion or integer work. Fixed arithmetic pipelines accept one operation per cycle; MUL and FMA share one product pipeline per precision with eight-cycle result latency. Each unit reserves result-queue capacity before launch and preserves owner/data/flags through completion backpressure. ROB-backed FP renaming provides one 64-bit speculative result per live instruction, a map for all 32 FPRs including f0, and captured source versions for RAW/WAR/WAW dependencies. The architectural 32x64-bit bank changes only at commit. LSU captures renamed FP store data and publishes nonfaulting FP loads through the common completion fabric, including younger loads before IOQ-head removal. RV32 FLD uses the A lane's two-beat payload; RV64 FLD can use A or B. ROU commits a ready prefix in order and ORs floating-point exception flags across the actual retiring prefix. CSR/system operations still serialize, keeping FRM/FS changes ordered; ordinary FP operations do not. An ordinary commit group admits at most one store and one control-flow instruction, and may retire younger ordinary instructions after that store. CMU broadcasts retirement, redirect, fence and trap effects; CSR holds privilege, translation, interrupt and PMP state.

## Memory: LSU, L1D, translation, and bus

- **LSU:** IOQ computes addresses through one per-entry preparation register, checks older-store dependencies, and can issue a younger ready load when older stores are resolved and nonconflicting. Atomics and uncacheable/MMIO accesses remain ordered at the IOQ head. An aligned full-width store in the unified 16-entry SQ may forward to a load contained in the same word; unresolved or stale-context stores block unsafe forwarding. All presets allow contained narrow-load forwarding in Bare mode; partial overlap without full byte coverage still blocks. The IOQ allocates a store's SQ entry when its completion is accepted; ROB commit marks that entry committed; the SQ drains committed entries in order to L1D or the bus. Flush discards speculative SQ entries but preserves committed ones. In every preset, a load whose base arrives on an eligible completion can form its address directly in the registered request stage; memory-port results are excluded, so a load result cannot close the request register through the L1D response and SQ forwarding in one cycle. All presets also sample older-store disjointness and ordering before early completion and precheck the oldest ready eligible resident store's permission.
- **Memory completion contract:** Load, store, and atomic results use one typed IOQ completion packet and one owner check before ROB writeback. A store-side permission fault takes priority over an atomic read fault; a non-faulting completion reports zero exception cause. A same-cycle reset or pipeline flush suppresses the completion and speculative SQ handoff, while already committed SQ entries retain their independent drain lifetime. An early younger-load broadcast is restricted to a clean result and keeps its IOQ entry until ordered removal. The store permission check remains registered; an ordinary L1D hit can use the direct response path when `RAPT_IOQ_LOAD_RESPONSE_STAGE=0`. Setting that macro to `1` captures the response before completion and disables live response wakeup across that boundary. In every preset, the SC reservation decision is registered, and the SQ load path registers PMP decisions when they cannot bypass. The memory endpoint checks the ROB owner contract with a verification assertion rather than a combinational owner lookup. The shared completion register described above is after accepted operand wakeup; there is no separate preset-controlled memory completion register before CDB fanout.
- **Wider configurations:** This contract is lane independent, but the current IOQ still presents one memory completion packet per cycle and the L1D A/B load paths share one data SRAM read port. Raising dispatch and integer issue widths to four, eight, or sixteen does not add memory completion or hot-hit read bandwidth. If a fraction `f` of committed instructions needs this memory completion port, its steady-state IPC ceiling is `min(issue width, 1/f)`, even with perfect frontend and cache hits. A future multi-lane LSU must apply the same owner, exception, flush, and SQ handoff rules to each accepted packet; then it needs explicit completion arbitration, enough cache banks/read ports, and SQ admission bandwidth. With sixteen integer lanes, the current `N+4` completion fabric already has twenty broadcast endpoints, so banked/distributed wakeup and physically local completion paths also need measurement before adopting that width. Widening dispatch alone does not provide those resources.
- **L1D:** The default 16 KiB, four-way L1D has 64-byte lines, banked synchronous SRAM, four physical-line MSHRs, separate load/store DTLB lookup replicas, and a shared data PTW. Cacheable replayable loads translate and pass permission checks before allocating a miss. IOQ parks these requests and retries them after a wake; a held miss also yields to a late local store so the store can reach the idle cache port; independent Sv32/Sv39 misses can overlap, including later page walks while earlier refills remain outstanding. Same-line misses share a refill, and demanded words can return before RLAST. Replays recheck translation and permissions. MMIO, atomics, and nonreplayable split accesses retain the ordered path. The best-effort B hit-under-miss channel (`RAPT_LSU_HUM`) remains bare-mode only; translated concurrency uses the A-channel MSHR/replay path. Larger capacities are available as [optional presets](#optional-l1d-capacities).
- **Store policy:** All `default*` presets set `RAPT_L1D_WRITEBACK=1` and `RAPT_L1D_MSHRS=4`; both macros remain overridable. L1D has two full-line writeback buffers with per-word dirty masks. Without inclusive L2, a captured dirty victim releases its array slot before B, while unrelated replayable loads continue. A read of a buffered physical line waits for its writeback; full queues backpressure victim capture, and failed B responses retain queued data until reset. Stores drain active refills, and local stores wait for queued writebacks. A store to a line whose install is still queued waits for the install, so it completes as a local hit rather than a write-through whose response cannot update the resident copy. Inclusive L2 victim Release/ReleaseAck and Probe operations retain their serialized ownership protocol. MSHR refills acquire the L2 D-client mark, and a Release also invalidates any retained refill copy. Fences and coherence wait for dirty resident data and queued writebacks. A D-side L1 TLB miss first probes L2 TLB; only an actual PTE bus request triggers dirty publication. I-side PTW reads similarly require publication when they reach the bus. Earlier bus stores retain their response ownership, and new stores wait while a walk is active. DMA coherence remains a platform/software responsibility.
- **Translation and protection:** The fully associative ITLB has 16 entries by default; load/store DTLB replicas each have 64 entries with two-way set associativity. Their miss paths share a 256-entry direct-mapped L2 TLB before the separate Sv32/Sv39 instruction and data PTWs. PMP checks fetch, data, and PTW accesses. Split loads carry both their architectural width and each physical fragment's permission footprint, so a narrower fragment cannot bypass a device-width restriction.
- **Cache-block operations:** `cbo.inval`, `cbo.clean`, and `cbo.flush` check the translated address before retirement, then wait for the SQ to drain; invalidation/flush remove matching L1D blocks. `cbo.zero` commits an aligned 64-byte zero descriptor through SQ and waits for its final write response. Zicbop prefetch encodings are nonfaulting hints.
- **Bus and cluster link:** `rapt_bus` arbitrates L1I, L1D, and PTW requests inside
  `rapt_memory` and exports `l2_client_if`. The always-present cluster-level
  `rapt_l2_subsystem` contains `rapt_axi_master`, which defaults to eight outstanding
  reads. Without an L2 cache, `RAPT_POSTED_WRITES` (default four) bounds eligible
  cacheable writes in flight. Write-through stores may complete at bus capture;
  buffered writebacks retain data until their matching B response. Other writes
  wait for older posted responses and complete on B. Reads cannot overtake a
  posted write to the same line; uncacheable reads wait for all posted writes.
  A failed early-acknowledged store reports its line to L1D. The optional L2 cache
  and the two-entry outer AXI R buffer also live in `rapt_l2_subsystem`.
  `L2LinkConfig.store_writeback` enables that buffer (`default-l2`); `default` bypasses it.
- **Optional L2:** `default-l2` enables a 512 KiB, eight-way L2 with 1024 sets and 64-byte lines. Eight 1024x22 directory SRAMs hold tag/state/dirty/client metadata. Four logical 16384x64 data banks support Vivado RAM inference and optional segmented SRAM macros. This banked geometry stores 18 tag bits and bypasses addresses above its 34-bit cache-address aperture instead of truncating them into an alias.
- **L2 reads and coherence:** Independent clean misses use three ordinary refill contexts in RV32 or five in RV64, interleave outer responses by ID, and return the critical scalar word early. The shared secondary buffer has 15 queues/35 entries in RV32 and 21 queues/33 entries in RV64. Same-tag requests reuse current metadata; different tags re-read the directory. A foreign Get probes a Trunk L1D owner before reading its latest data. C Release can pre-empt a waiting victim/CBO Probe and forward its updated dirty/client metadata. The main L1D replies by invalidating its copy; retained Branch copies and permission upgrades are not enabled.
- **L2 writes:** A 40-list/40-beat Put pool and 40 ordered B slots retain incoming writes. Bufferable scalar stores and supported narrow, masked, FIXED, INCR and WRAP bursts allocate each touched cacheable line. Partial misses merge a refill; complete full-line writes skip the outer read. Non-bufferable writes forward, preserve resident dirty data on an outer error, and commit their resident-byte journal only after successful B. Dirty/client-owned victim misses and allocated Put execution remain serialized.
- **L2 limits:** The reserved scheduler and connected C Release paths do not implement general nested BC/C transitions or independently executing allocated Put lists. SourceD staging still differs from BOOM. Only the L1D is a probe-capable client. CBO write-back failures retain dirty data and stall maintenance; there is no software-visible CBO error report, and a later eviction error cannot be attributed to an already completed store. These limits and FPGA timing acceptance are tracked separately from the passing functional regressions.

Load scheduling conservatively waits behind older stores with unresolved addresses. There is no learned memory-dependence predictor or speculative RAW-violation rollback, and there is no independent data hardware prefetcher. MSHR miss replay, branch-target SRAM read-ahead, and Zicbop hints serve different purposes.

## Recovery and platform control

A nonfaulting branch misprediction produces a registered oldest-owner recovery transaction containing its ROB slot, allocation generation, target, and checkpoint identity. The announcement does three things at once:
- The rename checkpoint restores the predictor's GHR/PHR.
- IFU and FQU discard their younger fetch state.
- IFU redirects to the target with an L1I pre-read.

Fetch then continues down the target path into FQU. While `recovery.pending` is set, IDU, RNQ, `rename_pipe` and the operand stage stay empty, so no new ROB allocation occurs; older ROB work continues until the mispredicted instruction reaches the head. Retirement then performs the precise whole-pipe flush and rebuilds rename state from committed state. When the announced owner retires cleanly, IFU and FQU keep the target stream they already fetched (`recovery.preserve_fetch`). An older exception, interrupt, serializing operation or superseding recovery discards that stream. The announcement selectively cancels younger integer/branch issue entries, issue packets, and MUL/DIV owners. Younger MUL pipeline and iterative DIV owners are cancelled before their MDQ slots can be reused; older operations and the recovery owner survive. ROB/IOQ/SQ and rename still use the retirement-time precise flush, so correct-path execution cannot restart at the announcement. Correct branch resolutions release checkpoints independently, and completion ownership guards reject stale generations. The 4-bit generation guard is used together with producer cancellation and flush ownership; its finite width alone does not establish safety for arbitrarily late completions.

The CSR file supports M/S/U privilege, traps, delegation, Sv32/Sv39 controls, and cycle/time state.
Eight PMP entries implement TOR and NAPOT at the default 4 KiB granularity across 16
architectural CSR slots; slots 8–15 read as zero and ignore writes. NA4 is available only
with an explicit four-byte-grain configuration. The cluster routes CLINT timer/software
interrupts and PLIC external interrupts to the core. CLINT supplies `mtime`, `mtimecmp`,
and `msip`; PLIC has 31 sources and M/S contexts by default. The PLIC window accepts
naturally aligned 32-bit ordinary loads/stores; other ordinary widths fault before a device access.

RNU owns the speculative register map and free-register state. CSR observers read the machine trap-vector base through `csr_bcast.mtvec`.

## Default configuration

These values refer to `rtl/configs/default/rapt_config.svh`, shared defaults in `rtl/include/rapt.svh`, and top-level parameter defaults; other presets and command-line overrides can differ.

`small-cache` and `middle-cache` each have 128 KiB L1I and L1D caches with
64-byte lines. L1I uses 1024 sets and two ways; L1D uses 64 sets and 32 ways to
keep its index within a 4 KiB page. `small-cache` retains the one-wide small
core, ROB 4, integer PRF 48, SQ 4, and bimodal prediction. It enables L1D
write-back, 16-entry fully associative L1 TLBs, and a 64-entry shared L2 TLB.
`middle-cache` uses two-wide ordered stages, ROB 16, integer PRF 64, SQ 8,
TAGE, write-back L1D, and 8-entry L1 TLBs without an L2 TLB. Both disable
the L2 data cache. Select the preset explicitly; FPGA timing and utilization
depend on the board and build constraints.

| Item | Default |
| --- | --- |
| XLEN | RV32; `-DRAPT_RV64` selects RV64 |
| Physical address | 32 bits by default in both modes; RV64 `RAPT_PADDR_BITS` supports 32–38 |
| Stored PC | 32 bits (RV32); 40 bits sign-extended to RV64 (`RAPT_PC_FULL_WIDTH` retains 64) |
| Ordered widths | Decode 2, rename 2, dispatch 2, commit 2 |
| Integer issue | 2 ports; CSR/system on port 0; 6 completion endpoints (`N+4`) |
| Fetch | Six-halfword L1I lookahead; no IFU response register |
| Ordered buffers | FQU 4, RNQ 8, `rename_pipe` 4, operand stage 2, UOQ 8 |
| Window | ROB 32 (4-bit generation), integer PRF 64, operand spill 16, dispatch window 12 lanes, branch checkpoints 16 |
| Execution queues | ALQ 8, BRQ 8, MDQ 4, FPQ 8, IOQ 8, unified SQ 16 |
| Floating point | Renamed F/D/Zfhmin; ROB-backed speculative results; 32x64-bit committed FPRs |
| Branch prediction | TAGE (1024 bimodal + 3 x 1024 tagged), side conditional query of the same TAGE, 128-entry two-way BTB, 16-entry RAS |
| L1I | 16 KiB, four-way, 64 sets, 64-byte lines, 32-byte refill sector |
| L1D | 16 KiB, four-way, 64 sets, 64-byte lines, write-back, 4 MSHRs, 2 writeback buffers, Sv32/Sv39 miss replay |
| TLB | ITLB 16 (fully associative), DTLB 64 (two-way, replicated load/store lookup); shared direct-mapped L2 TLB 256 |
| L2 | No cache: the L2 subsystem only bridges to AXI (`default-l2` adds the cache) |
| AXI master | In `rapt_l2_subsystem`: 4-bit ID, XLEN-bit data, up to 8 reads; up to 4 eligible cacheable writes without L2; buffered writebacks complete on B |
| PMP / PLIC | 8 PMP entries in 16 CSR slots; 31 PLIC sources, M/S contexts |

The `default*` presets use a 16-entry fully associative ITLB and 64-entry,
two-way DTLB replicas. `large` uses ITLB 32 and DTLB 64/two-way.
`small`/`formal` use 4 entries and `middle`/`middle-cache` use 8 entries in
both levels of L1 translation. `small-cache` uses 16 entries. All of these
presets use fully associative DTLBs (`WAYS=0`).

The instruction and data miss paths share one **256-entry, direct-mapped L2
TLB**, implemented by `rapt_l2tlb` and the `rapt_cached_ptw` adapters. It is
enabled in all `default*` presets, `large`, and `formal`; `small-cache` uses
a 64-entry instance. `small`, `middle`, and `middle-cache` set
`RAPT_L2TLB_ENTRIES=0` and bypass it. This setting is independent of the L2
data-cache enable.

The low eight VPN bits index the table. A single synchronous payload port
arbitrates instruction/data lookups and fills in round-robin order. An L1
translation miss first probes this table; a hit refills the requesting L1 TLB,
and a miss starts its existing page-table walker. Superpage results are cached
as resolved 4 KiB subpages. Tags include ASID (ignored for global mappings),
page-table root, PBMTE and SBE. Keeping the root in global tags conservatively
prevents reuse across different roots. Cached PTE flags and the full
architectural PPN preserve permission, Svade A/D, PBMT and physical-address
checks. Access faults and page faults are not cached.

Committed SFENCE.VMA and SINVAL.VMA use address/ASID-selective invalidation in
both L1 TLBs and the shared L2 TLB by default (`RAPT_SFENCE_SELECTIVE=1`).
An ASID-specific fence preserves global mappings; an address-specific fence
also matches every cached fragment of the corresponding superpage. Full fences
and `RAPT_SFENCE_SELECTIVE=0` invalidate all entries. Invalidation takes priority
over fills. `RAPT_SFENCE_KEEP_STATE=3` independently preserves caches and predictor
state across translation fences; it does not weaken translation invalidation or
ordering. A cancelled walk drains an already accepted PTE read without
refilling either level. The dedicated per-word IO instruction-fetch translation
path continues to use its own walker directly. Standalone L1 cache instances
default to `L2Tlb=0`; `rapt_memory` enables and connects the shared table according
to the preset. No frequency, area or workload improvement is implied by these
capacity settings.

## Optional L1D capacities

The standard presets keep their cache capacities. Override the default preset's
`RAPT_L1D_N_WAYS` and `RAPT_L1D_NRU` defines to select these variants:

| Defines with `RAPT_CONFIG=default` | Capacity | Ways | Replacement | 64-bit data banks | Rows per bank |
|---|---:|---:|---|---:|---:|
| `none` | 16 KiB | 4 | tree PLRU | 8 | 256 |
| `RAPT_L1D_N_WAYS=8` | 32 KiB | 8 | tree PLRU | 8 | 512 |
| `RAPT_L1D_N_WAYS=16` | 64 KiB | 16 | tree PLRU | 16 | 512 |
| `RAPT_L1D_N_WAYS=8, RAPT_L1D_NRU=1` | 32 KiB | 8 | NRU | 8 | 512 |
| `RAPT_L1D_N_WAYS=16, RAPT_L1D_NRU=1` | 64 KiB | 16 | NRU | 16 | 512 |

All use 64 sets and 64-byte lines in RV32 and RV64, so the set index stays in the
4 KiB page offset. `RAPT_L1D_WAYS` overrides a preset's way count; without it the
existing `RAPT_L1D_N_WAYS` applies. `RAPT_L1D_NRU=1` selects NRU; zero keeps the
existing replacement policy, including `RAPT_CACHE_LRU` when set.

NRU keeps one recent bit per way. An A-channel tag hit or installation marks its
way recent; when every way becomes recent, only the latest way stays marked.
Replacement chooses the first cold way after checking matching and invalid
entries. Hit and installation updates are mutually exclusive, so one indexed
write port suffices. B probes keep the existing read-only replacement behavior.

The data array reads one 64-bit chunk across ways, or a complete line of one way,
on the next clock edge; RV32 selects either half of the chunk. Every bank uses
`rapt_sram_1rw`, including byte write enables and blocked-write address
reservation. The four-way geometry compacts chunk rows modulo four to avoid unused
SRAM rows. Use a distinct `BUILD_PROFILE` for each define combination so simulator artifacts
stay isolated:

```sh
make build-rv64 RAPT_CONFIG=default BUILD_PROFILE=l1d64-nru \
  VFLAGS="-DRAPT_L1D_N_WAYS=16 -DRAPT_L1D_NRU=1"
make -C synth/yosys structure-check MODULE=l1d RAPT_CONFIG=default \
  EXTRA_DEFINES="-DRAPT_L1D_N_WAYS=16 -DRAPT_L1D_NRU=1"
```

Focused checks are
`verilator-l1d-data`, `verilator-l1d-shared-tags`, `verilator-l1d-nru`, and the
existing L1D writeback/refill families in `verification/Makefile`.
