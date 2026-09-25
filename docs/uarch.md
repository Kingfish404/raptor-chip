---
title: Microarchitecture
---

# Microarchitecture

## Pipeline stages

Each `E` marks a clock edge that captures instruction state; `E0` is the registered fetch PC. Logic between two edges belongs to the following stage. These examples assume ready operands, available queues, L1 hits, no redirects, and same-edge ROB allocation/DPU dispatch. The load and store examples use aligned, cacheable Bare-mode accesses with no older-memory conflict; the load enters an empty IOQ and the store is a full-width local hit. Each Backend line continues the Frontend line above it.

```text
Integer:
Frontend: E0[PC](IFU) -> E1[Fetch](L1I) -> E2[Packet](IFU) -> E3[Queue](FQU) -> E4[Decode Input](IDU)
Backend:  E5[Decoded Queue](RNQ) -> E6[Rename](RNU rename_pipe) -> E7[Operand Queue](UOQ) -> E8[Allocate and Dispatch](ROB+DPU+ALQ) -> E9[Execute and Complete](ALU+CDB+ROB_WB) -> E10[Commit](ROB)

Load:
Frontend: E0[PC](IFU) -> E1[Fetch](L1I) -> E2[Packet](IFU) -> E3[Queue](FQU) -> E4[Decode Input](IDU)
Backend:  E5[Decoded Queue](RNQ) -> E6[Rename](RNU rename_pipe) -> E7[Operand Queue](UOQ) -> E8[Allocate and Request](ROB+DPU+IOQ) -> E9[Cache Access](L1D) -> E10[Complete](IOQ+CDB+ROB_WB) -> E11[Commit](ROB)

Store:
Frontend: E0[PC](IFU) -> E1[Fetch](L1I) -> E2[Packet](IFU) -> E3[Queue](FQU) -> E4[Decode Input](IDU)
Backend:  E5[Decoded Queue](RNQ) -> E6[Rename](RNU rename_pipe) -> E7[Operand Queue](UOQ) -> E8[Allocate and Dispatch](ROB+DPU+IOQ) -> E9[Address and Permission Check](IOQ) -> E10[Complete and Buffer](CDB+ROB_WB+SQ) -> E11[Commit](ROB) -> E12[Drain](SQ+L1D)
```

These are ideal edge sequences, not fixed instruction latencies: L1I may read a sequential word ahead of `E1`; queue or operand waits, `ROB_DP` residence, translation, cache misses, replay, and bus responses extend a path. Store drain occurs after architectural commit and can take longer than the single local-hit edge shown. The default `RAPT_FETCH_RESPONSE_STAGE=0` adds no IFU response register; the common completion fabric registers only the MUL/DIV endpoint.

## Organization

Raptor is a configurable RV32/RV64, dual-width, out-of-order core. `rapt_core` composes `rapt_frontend` (prediction, fetch, FQU, decode), `rapt_backend` (rename, ROB, dispatch, issue, completion, LSU, precise commit), and `rapt_memory` (L1I, L1D, translation, bus, optional L2). The composition boundaries themselves add no registers. The default decode, rename, dispatch, and commit widths are each two; instruction queues hold individual instructions rather than fixed pairs.

The [pipeline explorer](./explore.md) is an illustrative cycle model. It does not model current branch recovery, MSHR replay, or the direct integer completion path, so its cycle counts are not RTL timing or CoreMark IPC.

## Frontend: Fetch, queue, and decode

- **IFU and L1I:** The IFU walks complete 16/32-bit instructions in an L1I lookahead window, keeps any unconsumed suffix in a register, and ends a fetch group at the first control, serializing, or faulting instruction. L1I is a 16 KiB, four-way cache with synchronous banked SRAM and 64-byte lines; pre-reads can hide the SRAM cycle for sequential fetch. The optional IFU response register is disabled by default. Miss refills, translation faults, and accepted-request ownership remain in L1I.
- **FQU and IDU:** FQU is a registered stream queue without empty-queue fall-through; it can regroup instructions across fetch packets. IDU registers its input, decodes each slot combinationally, and corrects accepted direct jumps, return predictions, or stale targets before rename. Flush and recovery invalidate resident frontend instructions.
- **BPU:** The default direction predictor is TAGE, with selectable gshare, bimodal, or static alternatives. A BTB supplies targets; the return-address stack and prediction-history state are repaired at decode or retirement. Prediction queries alone do not advance history: accepted conditional instructions do.

## Backend: Rename, dispatch, and execution

- **RNU and PRF:** RNQ stores decoded instructions; RNU maps architectural GPRs to a 64-entry physical register file, resolves dependencies within a rename group, and writes a separate registered `rename_pipe` output queue. The UOQ pre-reads operands and keeps listening for completions. Commit updates the architectural RAT and releases stale mappings; a full flush rebuilds speculative MAP/free state from committed state. Branch checkpoints are a separate bounded resource.
- **ROU and DPU:** UOQ feeds a 32-entry ROB with states `ROB_DP -> ROB_EX -> ROB_WB -> ROB_CM`. A ready allocation can bypass `ROB_DP` and enter an execution queue on the same edge. DPU is a combinational, capacity-aware selector: it scans the oldest pending ROB owners and sends at most `DispatchWidth` full payloads to eligible domains. A blocked domain can leave an owner resident in `ROB_DP` while other domains progress.
- **Issue queues:** The default ALQ has eight entries and two integer issue ports; BRQ and MDQ have four entries each, the scalar FPQ has one, and IOQ has eight. Integer/branch/FP issue queues capture operands and wake on accepted completions. The default `RAPT_IQ_RECLAIM_ON_ISSUE=1` allows a slot issued on an edge to be reused on that edge; disabling it delays reuse rather than adding an execution stage.
- **Execution and completion:** One integer port owns CSR/system operations and shares its completion endpoint with scalar FP; the other simple ALU port remains independent. Branches use a separate compare path, and MUL/DIV uses a private queue with pipelined multiply and iterative divide. For `N` integer ports the guarded fabric has `N+3` outputs: `N` integer, one branch, one memory, and one MUL/DIV. Integer, branch, and memory results reach the common completion fabric directly; MUL/DIV has an additional completion register. A ROB slot plus allocation generation identifies each live producer before it can affect ROB, PRF, or wakeup state.
- **Floating point and commit:** FEU owns scalar F/D and Zfhmin arithmetic, including FMA and divide/square root, and uses the architectural 32×64-bit FPR bank; FP loads/stores use LSU. Current scalar FP operations serialize at an empty ROB. ROU commits a ready prefix in order, up to two instructions by default; special effects retire alone, and a store ends its retirement group. CMU broadcasts retirement, redirect, fence, and trap effects; CSR holds privilege, translation, interrupt, and PMP state.

## Memory: LSU, L1D, translation, and bus

- **LSU:** IOQ computes addresses, checks older-store dependencies, and can issue a younger ready load when older stores are resolved and nonconflicting. Atomics and uncacheable/MMIO accesses remain ordered. An aligned full-width store in the unified 16-entry SQ may forward to a matching load; unresolved, partial, or stale-context stores block unsafe forwarding. The IOQ allocates a store's SQ entry when its completion is accepted; ROB commit marks that entry committed; the SQ drains committed entries in order to L1D or the bus. Flush discards speculative SQ entries but preserves committed ones.
- **L1D:** The default 16 KiB, four-way L1D has 64-byte lines, banked synchronous SRAM, separate load/store DTLB lookup replicas, and a shared data PTW. A hit returns from the registered access state; misses may park in the default two physical-line MSHRs and replay from IOQ after a wake. Same-line misses share a refill, while MMIO, atomics, and some split accesses use the blocking path. Demand data can return before the last refill beat, but the accepted bus owner remains live through the final beat.
- **Store policy:** `L1dWriteBack=0` is the default for the core, memory subsystem, and simulation wrappers, so stores use write-through. The optional write-back mode locally completes eligible cacheable store hits, tracks dirty words, and writes back a dirty victim before replacement; it disables MSHRs while active. A writeback error latches `writeback_error_o` and stops affected traffic until reset. Cache maintenance and DMA coherence remain platform/software responsibilities.
- **Translation and protection:** Fully associative ITLB and load/store DTLBs have 16 entries each by default; separate instruction and data PTWs implement Sv32/Sv39. PMP checks fetch, data, and PTW accesses. Split loads carry both their architectural width and each physical fragment's permission footprint, so a narrower fragment cannot bypass a device-width restriction.
- **Cache-block operations:** `cbo.inval`, `cbo.clean`, and `cbo.flush` check the translated address before retirement, then wait for the SQ to drain; invalidation/flush remove matching L1D blocks. `cbo.zero` commits an aligned 64-byte zero descriptor through SQ and waits for its final write response. Zicbop prefetch encodings are nonfaulting hints.
- **Bus:** `rapt_bus` arbitrates L1I, L1D, and PTW requests; `rapt_axi_master` supports up to eight outstanding reads and one outstanding write. The default preset leaves L2 as a passthrough.
- **Optional L2:** The experimental `default-l2` preset enables a 512 KiB, eight-way, 64-byte-line L2 with 1024 sets. Its eight 1024×22 directory SRAMs are the sole tag/valid state, and its data layout has 16 banks of 4096×64. Bufferable store hits use byte enables and dirty metadata; a read miss writes back a dirty victim before refill. CBO invalidation scans the selected sets, writes back dirty ways, then clears them. Non-bufferable writes and store misses still pass through; forwarded burst beats merge their byte masks into resident lines. Write-miss allocation, L1 probes, multiple MSHRs, and CBO write-back error reporting remain unfinished, so this preset is not yet BOOM-equivalent.

## Recovery and platform control

A nonfaulting branch misprediction produces a registered oldest-owner recovery transaction containing its ROB slot, allocation generation, target, and checkpoint identity. IFU may read the target SRAM early, but `recovery.pending` fences frontend delivery and new rename; older ROB work continues until the mispredicted instruction reaches the head. Retirement then performs the precise whole-pipe flush and reconstructs rename state from committed state. This is not selective ROB/IQ/IOQ/SQ recovery. Correct branch resolutions release checkpoints independently, and completion ownership guards reject stale generations.

The CSR file supports M/S/U privilege, traps, delegation, Sv32/Sv39 controls, and cycle/time state. Eight PMP entries implement TOR, NA4, and NAPOT across 16 architectural CSR slots; slots 8–15 read as zero and ignore writes. The cluster routes CLINT timer/software interrupts and PLIC external interrupts to the core. CLINT supplies `mtime`, `mtimecmp`, and `msip`; PLIC has 31 sources and M/S contexts by default. The PLIC window accepts naturally aligned 32-bit ordinary loads/stores; other ordinary widths fault before a device access.

## Default configuration

These values refer to `hdl/configs/default/rapt_config.svh`, shared defaults in `hdl/include/rapt.svh`, and top-level parameter defaults; other presets and command-line overrides can differ.
