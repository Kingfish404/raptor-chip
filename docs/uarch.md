# Microarchitecture

Raptor is an out-of-order, super-scalar RISC-V processor core with register renaming, a reorder buffer (ROB), per-class issue queues (a parameterized multi-port ALQ plus BRQ / MDQ / FPQ / IOQ), scalar F/D floating-point execution, and virtual memory support.

## Pipeline

The ordered front/back-end stream has independent `DecodeWidth`, `RenameWidth`,
`DispatchWidth`, and `CommitWidth`. Queue entries are instructions, not fixed pairs.
Execution-port and completion-port counts are independent of those widths.
Local design notes: `docs.agent/architecture/superscalar-widths.md`
(agent working documents are not part of the published manual).

```text
L1I/BPU -> IFU held suffix -> FQU -> IDU input register + decode
        -> RNQ -> rename -> renamed output queue -> UOQ (PRF pre-read)
        -> ROB allocation -> K-entry candidate scan -> W-entry DPU compact
        -> winner payload read -> issue queues -> FUs -> completion
        -> ROB ready-prefix retirement -> RAT / PRF / CSR / CMU
```

The queues and registered payload boundaries are explicit. This diagram is not
an exact-cycle latency model; no IPC, mispredict-penalty or Fmax improvement is
claimed from the width refactor alone.

### Store & Load Ordering

- **Stores**: IOQ computes address+data and allocates one unified SQ entry; ROB commit marks the existing entry committed; committed head entries drain to L1D/BUS in program order.
- **Store-to-load forwarding**: loads CAM the unified SQ by virtual word address; youngest matching full-width store forwards data.
- **Load issue**: IOQ supports out-of-order load issue when older stores are resolved and non-conflicting. Atomics and uncacheable/MMIO requests remain ordered at the ROB/IOQ head.

### Branch Misprediction Recovery

Recovery now has two explicit phases. When a non-faulting misprediction
completion is accepted, ROU registers the oldest outstanding owner and
publishes one `rapt_recovery_if` redirect transaction containing ROB slot,
allocation generation, target and rename-checkpoint identity. A subsequently
completed older misprediction replaces the transaction and produces a new
one-cycle redirect. IFU immediately starts a target data-SRAM read-ahead;
IFU/FQU/IDU and RNU remain fenced and empty while `pending` is asserted. A
later head retirement still performs the architecturally precise whole-pipe
flush: `cmu_bcast.flush_pipe` reasserts the target, PRF transient state is
invalidated, and committed state remains the final recovery authority.

Simulation-only ROB lifecycle events
measure completion-to-retirement latency separately from the existing
flush-to-frontend-delivery interval. The host observer distinguishes retired
mispredicts from younger canceled ones, tracks overlap and ROB-head domains,
and checks identity/residence-time conservation. These probes are absent under
`SYNTHESIS`; timestamps and histograms live in C++, not hardware. Local results
and the remaining selective-recovery requirements are recorded in
`docs.agent/evaluation/recovery-latency-evaluation.md`.

A completed, non-faulting misprediction creates that registered oldest
transaction through `rapt_recovery_pending`. Arbitration uses ROB-ring age
from the current head and a balanced completion-port reduction tree. From the
following cycle, `RAPT_RECOVERY_DISPATCH_FENCE=1` stops new UOQ-to-ROB
allocations while older ROB work continues to issue and retire. Each renamed
control-flow uop also owns a parameterized rename checkpoint: post-branch MAP,
free bitmap and a live-ancestor mask. Correct resolution releases it; a
misprediction restores the selected snapshot, invalidates its descendant
checkpoints, flushes RNQ/rename output state and fences further rename until the
existing precise retirement flush. Free-set recovery unions the snapshot with
registers released by older commits after the snapshot. Correctly resolved
checkpoint releases use the separate multiport `checkpoint_release_if`; they
are not overloaded onto the single recovery transaction. The completion-time
redirect currently overlaps only target-side read-ahead with retirement wait:
it does not admit correct-path decode/rename, restore predictor/RAS checkpoint
state, or selectively squash ROB/IQ/IOQ/SQ entries. Completion producers carry a
ROB allocation generation and pass through one ownership firewall before any
ROB/PRF/IQ/FPR/LSU side effect. This blocks stale generations under the current
full-flush lifecycle, but finite generation is not a cancellation/reuse
protocol for future selective recovery. Local proof, cost and remaining lease
requirements are recorded in
`docs.agent/evaluation/completion-identity-evaluation.md`; recovery-fence work
reduction is in `docs.agent/evaluation/recovery-request-evaluation.md`, and the
unified transaction/read-ahead results are in
`docs.agent/evaluation/recovery-transaction-evaluation.md`.

## Module Details

### Frontend

#### IFU (`rapt_ifu.sv`)

Walks complete 16/32-bit instructions in the existing L1I lookahead window,
up to DecodeWidth. Each instruction carries its own PC, predicted next PC and
fault metadata. The first control-flow, serializing or faulting instruction
ends a fetched prefix. A held suffix survives partial downstream acceptance;
system/atomic/trap instructions block further fetch until recovery.
`RAPT_FETCH_LOOKAHEAD` controls cache/predictor lookahead capability separately
from ordered stage widths. The fixed cache byte window may supply fewer than
DecodeWidth instructions.

**Read-ahead**: every accepted packet supplies its exact next PC (sequential
stride, predicted target, or redirect target) to L1I as a side-effect-free
data-SRAM hint. A completion-time recovery redirect clears the held suffix and
starts the target read, but `recovery.pending` prevents returned data and
prediction history from being accepted until precise cleanup. This hides some
synchronous SRAM latency without creating a cache request or modifying cache
state.

#### FQU (`rapt_fqu.sv`)

Registered instruction-stream queue between IFU and IDU, implemented with
`rapt_stream_queue`. It has no empty-queue fall-through. Partial dequeue and
same-cycle enqueue/reclaim are supported, and decode groups may cross original
fetch boundaries. Flush, system resume, accepted IDU resteer, and a pending
recovery transaction cancel resident instructions and same-cycle acceptance.

#### BPU (`rapt_bpu.sv`)

| Component                   | Implementation                                                 | Key details                                           |
| --------------------------- | -------------------------------------------------------------- | ----------------------------------------------------- |
| **DIRP**                    | Default TAGE; alternatives: gshare, bimodal/PHT, static        | Selected by `RAPT_BPU_DIRP_*` macros                  |
| **PHT** (`rapt_bpu_pht.sv`) | 2-bit saturating, `PHT_SIZE` entries (256)                     | Used by bimodal/PHT mode and as local predictor base  |
| **BTB** (`rapt_bpu_btb.sv`) | 2-way SA, `BTB_SIZE` entries (128), 7-bit tag                  | `(* keep_hierarchy *)`, sync read, XOR-hash, LRU      |
| **History** (`rapt_predict_history.sv`) | 64-bit GHR plus 8-bit PHR at fetch, decode and commit boundaries | Accepted conditional events; post-decode/post-commit repair |
| **RAS** (`rapt_ras.sv`)      | `RSB_SIZE` entries per image (4)                               | Independent committed/speculative data, bounded count, decode-order actions |

BTB entry types: `COND`, `DIRE`, `INDR`, `RETU`. Direction predictor state is trained from committed branch outcomes; BTB updates occur on flushes (including JALR). Predictor structures are invalidated or repaired on `fence_time` / flush paths as appropriate.

Return prediction has an explicit stage boundary: IFU uses its request-aligned
BTB target; IDU uses the pre-action RAS top to repair accepted returns, including
BTB misses. Both speculative push and pop occur only on accepted decode control
instructions (at most one per group), never on prediction queries. Full flush
restores the post-commit RAS data, pointer and count; an IDU-only resteer retains
the accepted action. Local rationale, overflow-policy and verification notes are
kept in `docs.agent/evaluation/ras-recovery-evaluation.md`.

Direction history uses one acceptance protocol for primary and auxiliary
conditionals, including BTB misses. Prediction queries, stalls, non-control BTB
aliases and faulting instructions do not advance it. IDU resteer restores the
post-decode watermark; full flush restores the post-commit watermark, appending
an outcome only when a conditional actually commits. The next-PC predictor
query sees this post-event history on the same edge. `fence_time` clears all
three watermarks. The predicted direction bit travels with the instruction;
next-PC equality alone is insufficient when a taken target is fall-through.
Local proof, cost and regression notes are in
`docs.agent/evaluation/prediction-history-evaluation.md`.

#### L1I (`rapt_l1i.sv`)

N-way set-associative I-cache (`L1I_N_WAYS`, default 2). `2^L1I_LEN` sets (32), `2^L1I_LINE_LEN` words/line (16 RV32 words = 64 B). Default capacity is 4 KiB. 7-state FSM (`IDLE`, `PTWAIT`, `TRAP`, `RD_A`, `RD_0`, `RD_1`, `FINA`).

| Storage | Implementation                                                                       |
| ------- | ------------------------------------------------------------------------------------ |
| Data    | Banked `rapt_sram_1rw` per way per word (single-port, sync read)                     |
| Tags    | Banked `rapt_sram_1rw` per way per word (combinational compare from SRAM output)     |
| Valid   | Register arrays per way (`l1i_valid[way][set]`) for fast `fence.i` bulk invalidation |

3-tier pre-read uses the IFU's exact next-PC hint: current bank reads the hinted word, next bank reads `+2`, and remaining banks read `+4`. This provides `inst_n1` and `inst_n2` for the parameterized instruction-prefix walker while hiding hit-path target/stride transitions. Cache lines retain per-word valid bits; on the default non-SDRAM AR path, `RAPT_L1I_REFILL_WORDS=8` refills one 32 B sector per miss through an 8-entry AR FIFO. The value is capped by the configured line length and may be overridden for experiments; SDRAM burst targets retain their dedicated two-beat burst refill path. Way replacement: first invalid, then toggle `replace_bit` per set. ITLB + IPTW support Sv32/Sv39 translation.

Cache-response ownership is separate from request acceptance. Recovery and
invalidation detach refill ownership while already accepted reads drain; their
late data or errors must not affect a replacement fetch at the same PC. Error
responses are consumed without installing a valid cache word. An error in a
lookahead word does not fault an unrelated current instruction; a later demand
must request that absent word again.

For a 32-bit instruction starting at a halfword boundary, the second-word error
may arrive before the first halfword's synchronous SRAM read reveals instruction
length. `second_error_pending` retains that error with its virtual fetch PC.
Only first-halfword readiness is needed to classify it: a compressed instruction
discards the unrelated error, while a spanning instruction reports the second
halfword's address. Recovery, invalidation, PC changes and consumption end this
ownership; the state is functional and remains present in synthesis.

#### IDU (`rapt_idu.sv`)

A compacting input register feeds DecodeWidth instances of `rapt_decode_slot`.
The decoder is pure combinational per-slot logic; acceptance, prefix termination,
call pushes and early resteers belong to the surrounding stage. Direct JAL,
stale conditional targets and non-control prediction aliases are corrected only
when that instruction is accepted. Unaccepted suffixes remain registered.

### Backend

#### RNU (`rapt_rnu.sv`)

RNQ accepts DecodeWidth instructions and supplies RenameWidth candidates.
Cycle-start MAP reads plus older-slot tag bypass implement arbitrary intra-group
RAW and WAW dependencies. A shared bounded-count rank tree selects free physical
identities; only accepted GPR writers consume ranks. This avoids cascading a full
updated MAP and a physical-register priority encoder through every slot. A
registered output queue decouples renamed instructions from UOQ acceptance.

`rapt_rename_admit` separates resource qualification from tag assignment. Each
slot independently counts preceding destination/checkpoint demands, checks the
corresponding ranked resource availability, then accepts only an ordered prefix
whose older slots are valid and qualified. An earlier rejection blocks later
slots without feeding an accepted-rank increment back into their qualification.
Accepted-rank bookkeeping remains in tag/payload construction, including the
existing invalid-slot values; admission adds no sequential stage. Allocation
still cannot consume same-cycle retirement releases.

RNU owns speculative MAP, committed RAT and a free bitmap. RAT update gives the
youngest committed writer priority. Flush reconstructs MAP and the free set from
the post-commit RAT, reclaiming speculative identities even before ROB allocation.
`rapt_rename_checkpoint` independently owns branch-checkpoint allocation,
ancestry, release and restore state. Checkpoint exhaustion stalls the ordered
rename prefix. Clearing a correctly resolved ID from every live ancestry mask
makes numeric-ID reuse safe; it avoids confusing an old checkpoint incarnation
with a later branch. The single oldest restore arrives through
`rapt_recovery_if`; independent correct-resolution releases arrive through
multiport `checkpoint_release_if`. Checkpoint ID travels alongside each renamed
uop through UOQ into ROB. Current PMU probes report occupancy, capacity stalls
and the conservative recovery-fence interval.
The old standalone map/freelist modules are retained only for historical harnesses.

#### PRF (`rapt_prf.sv`)

PHY_SIZE physical entries, two read ports per RenameWidth position, and a typed
completion array. UOQ captures ready operands and continues snooping completion
while resident. Commit deallocates stale mappings and settles current mappings;
a younger WAW deallocation overrides settlement of an older version. Flush
invalidates transient speculative results. Debug architectural reads select the
requested RAT entry before reading one PRF value; the DM/core link carries an
address and one XLEN-wide combinational response, with no extra command cycle.
The complete committed/speculative register views remain available for RVFI and
simulation rather than requiring 32 physical debug read values at the DM boundary.

#### FPR (`rapt_fpr.sv`)

Separate 32 x 64-bit architectural floating-point register bank. The fixed
64-bit width supports RV32 and RV64, with single-precision values NaN-boxed in
the same storage used by double precision. FP arithmetic writes through the FEU
path and FP loads write through the LSU path, with local bypassing for recent
writes. The bank no longer has a combinational IOQ write-through path into FPU
completion generation; accepted writes cross its registered storage boundary.
FP dependency tags include the ROB allocation generation; this bank is not a
second renamed physical register file.

#### ROU (`rapt_rou.sv`)

Dispatch queue + reorder buffer + commit logic.

- **UOQ**: instruction ring with RenameWidth enqueue and DispatchWidth dequeue; no pair grouping.
- **Admission**: `rapt_dispatch_admit` owns the ordered UOQ-to-ROB allocation prefix, serializing barriers, registered recovery fence and ROB capacity acceptance. Execution-domain capacity is a later, independent handshake when buffered dispatch is enabled. Registered first-stop reason/count/domain probes describe the allocation boundary, not rename enqueue readiness.
- **ROB dispatch steering**: allocated owners enter `ROB_DP` until an execution-domain queue accepts them. `rapt_rob_dispatch_select` rotates the circular pending bitmap into age order and uses the shared hierarchical rank tree to expose the oldest `SteerScanEntries=K` owners, independently of `DispatchWidth=W`. Unused candidate lanes fall through from same-cycle ROB allocations. The selector exports only lightweight domain/token identities; after capacity-aware compaction, ROU reads and forwards full payloads for the W winners. Recovery eligibility excludes owners younger than the pending recovery owner.
- **ROB**: `rob_entry_t[]`, `ROB_SIZE` entries (64). States: `ROB_DP`->`ROB_EX`->`ROB_WB`->`ROB_CM`; the common ready path may perform allocation and `ROB_DP`->`ROB_EX` on the same edge. Allocation remains a contiguous prefix of up to DispatchWidth entries, while endpoint acceptance may be sparse.
- **Completion ownership**: allocation identity is `(ROB slot, generation)`. A read-only ROB owner directory validates each physical completion and early-wakeup producer before shared arbitration or architectural/speculative side effects. Immutable `prd/rd` payload is checked by simulation assertions rather than duplicated production muxes. ROU consumes this accepted fabric; its optional strict-input mode is retained for standalone hostile-input tests.
- **Recovery transaction**: a registered oldest-wins reducer holds owner/generation/target atomically and publishes one-shot redirects with a generation-qualified live checkpoint and a level `pending` fence. Both held requests and incoming candidates must match the live ROB generation; publication compares the full held identity, not a generation reconstructed from the current slot. `rapt_rob_age_mask` limits pending dispatch owners to the circular interval strictly before the recovery owner using two prefix comparisons and a shared wrap bit, without per-entry modulo arithmetic. Correct checkpoint releases remain an independent completion-width array. This does not implement selective cancellation acknowledgements or guarantee safety across generation wrap; the conservative fence and retirement-time cleanup remain necessary.
- **Operand bypass**: UOQ pre-read > LSU/IOQ broadcast > CDB broadcast. Forwarding continues during UOQ and `ROB_DP` residence. The dispatch output also merges a completion arriving on the exact endpoint-accept edge, so a one-cycle broadcast cannot be lost between resident-state update and queue sampling.
- **Commit**: scans up to CommitWidth ready entries in order. Special effects retire alone; at most one control-flow event per group; a store requires SQ readiness and terminates the group. BPU trains on the actual branch position.
- **Resident issue during recovery**: the validated redirect event now carries a ROB head age reference to ALQ/BRQ/FPQ. Their shared `rapt_iq` suppresses younger selection in the event cycle and clears those residents at the edge, while preserving older work and checking incoming allocation age. Cancelled entries become free the following cycle, without a new cancellation-to-dispatch bypass. Generation identifies reuse of an individual ROB slot and is not numerically compared across slots as an instruction age. This does not cancel IOQ residents or already-issued operations, nor undo issue on the earlier completion edge. The pending fence and precise global flush remain. `verilator-iq-recovery-window` compares local cancellation/no-event windows; backend recovery targets test RNU/ROU/IQ/PRF integration, not full-core IPC.
- **Flush triggers**: fence\_i, branch mispredict, trap, system op, atomic (retired alone at the head).
- **Async traps**: CLINT software/timer interrupts plus PLIC M/S external interrupts, gated by CSR enables and delegation state.

#### DPU (`rapt_dpu.sv`)

Stateless, capacity-aware compactor driven by `uop.schedule.domain`, not execution
opcode classes. For K age-ordered candidate tokens it computes the number of older
valid candidates in the same domain, compares that rank with the domain's ordered
capacity prefix, and uses the shared rank selector to choose the oldest W admissible
tokens. It then produces fixed-W per-domain grant masks; endpoint adapters translate
those grants to IQ free indices or IOQ tail ranks. Full operand-bearing payloads do
not cross the K-wide DPU boundary and are assembled by ROU only for selected tokens.
Domain classification belongs to decode/composition. This is bounded dispatch
bypass, not an arbitrary full-ROB scheduler.

#### IEU (`ieu/rapt_ieu.sv`)

- **Generic IQ** (`rapt_iq.sv`): shared parameterized data-capture scheduler. IEU instantiates the ALQ (8 entries, `RAPT_INTEGER_ISSUE_PORTS` issue ports) and BRQ (4 entries); FEU instantiates FPQ separately. Operands wake from the typed completion array plus the **fast load-use** tag path. Payload-independent `rapt_issue_select` consumes the age matrix, readiness and local port masks. Default selection remains port-first oldest-ready; optional one-hop port rebalancing never evicts a selected uop. Reset/flush suppress selection before the execution boundary. Local policy-cost and proof-scope notes: `docs.agent/evaluation/issue-selection-evaluation.md` and `docs.agent/evaluation/integer-issue-port-evaluation.md`.
- **Issue-slot reclaim**: when enabled, IQ admission uses already-free slots first, then slots selected to issue on the same edge. Old payload is consumed before the edge, while replacement allocation takes priority over issue-clear and receives a new age. `RAPT_IQ_RECLAIM_ON_ISSUE` defaults to 1 and can be disabled for timing comparisons. This adds select-to-admission combinational dependence; local evaluation notes are in `docs.agent/evaluation/dispatch-admission-evaluation.md`, not a physical timing signoff.
- **ALU-CSR pipe** (`ieu/rapt_ieu_pipe_alu_csr.sv`): full ALU + CSR/system/trap redirect semantics. `RAPT_INTEGER_SYSTEM_PORT` chooses which member of the integer-port array instantiates it and shares its completion endpoint with FP.
- **Generated simple-ALU pipes** (`ieu/rapt_ieu_pipe_alu.sv`): every integer port other than `RAPT_INTEGER_SYSTEM_PORT` instantiates a simple ALU + JAL/JALR link path. Dispatch slots never own a port; the ALQ selects from all resident compatible uops each cycle. A one-port configuration contains only the full ALU-CSR pipe.
- **Branch pipe** (`ieu/rapt_ieu_pipe_branch.sv`): one conditional-branch resolution path; checks both next PC and retained predicted direction and never writes PRF data.
- **MULDIV pipe** (`ieu/rapt_ieu_muldiv.sv`): one private four-entry MDQ plus `rapt_ieu_mul`; pipelined multiply and iterative divide use their own completion path.
- **Completion layout**: for `N` integer ports, the guarded fabric has `N+3` physical outputs: integer ports at `0..N-1` (the configured system port is shared with FP), branch at `N`, memory at `N+1`, and multiply/divide at `N+2`. Producer ownership guards and routing use the same generated indices; this is composition, not a fixed CDB-number ABI.
- **ALU** (`ieu/rapt_ieu_alu.sv`): combinational 6-bit opcode datapath, including the RV64 Zba `.UW` operations. CPOP uses a balanced population-count sum tree instead of serial conditional increments; RV64 CPOPW masks the upper operand bits before reduction. This changes combinational structure, not issue/completion latency.

#### FEU (`feu/rapt_feu.sv`)

Owns the four-entry in-order FPQ and scalar F/D arithmetic, FMA,
divide/square-root, conversions, comparison/classification, sign injection and
move operations under `feu/fpu/`. It reads/writes the architectural FPR bank
and produces the FPU candidate for the configured shared completion endpoint.
`rapt_cdb_arb.sv` arbitrates that endpoint: an FPU completion wins over the
configured integer system pipe, and the losing issue source is backpressured.
No dispatch or issue position owns this endpoint. FP loads/stores remain in LSU.

The scalar FEU permits one long operation in flight. `rapt_fpu_mul_fma` uses
that contract to share one significand multiplier per precision between FMUL
and FMA, retaining their four- and six-stage pipelines respectively. FMUL
consumes the product in stage 2 and FMA in stage 1; normalization, rounding and
flags remain in their original pipelines. The standalone `rapt_fpu_mul` and
`rapt_fpu_fma` wrappers retain private multipliers and their existing APIs,
including for vector users. This sharing is a resource binding for the current
serial scalar endpoint, not a multi-request arbiter: increasing FP concurrency
requires revisiting product ownership, ready and completion routing explicitly.

For a single in-order IQ port, payload selection pre-reads the oldest surviving
resident independently of operand readiness and port enable. The issue selector
still controls valid and state updates; this adds no pipeline stage. While
waiting, the output may carry that head's identity rather than slot zero's, so
consumers must qualify effects with valid. Reset and full flush suppress valid
immediately but do not steer the unqualified payload; queue state is still cleared
on the clock edge. This separates reset/flush and late load confirmation
from FP opcode/FPR-address selection. Unordered and multiport queues retain
grant-based payload selection. Directed checks cover both valid transfers and
waiting-head identity, including reset pulses and flush; each timing change
requires its own mapped comparison.

#### CMU (`rapt_cmu.sv`)

Broadcast unit. Outputs: `rpc`, `cpc`, branch resolution, `flush_pipe`, `fence_i`,
`fence_time`, `time_trap`. It selects the actual control-flow slot from the
parameterized retirement prefix (currently at most one control instruction),
and exposes every retirement slot to simulation/RVFI. Retirement packets carry
explicit original compressed length and trap status: expanded instruction bits
cannot recover length. Shared RISC-V RAS hint classification drives `call`
(push) and `ret` (pop), both true for a coroutine switch and both suppressed for
faulting instructions. Rename recovery consumes typed per-slot PRF identities.

#### CSR (`rapt_csr.sv`)

32-entry register file, M/S-mode. Trap entry/exit (`ecall`/`ebreak`/`mret`/`sret`), privilege transitions (M/S/U), delegation (`medeleg`/`mideleg`), `MSTATUS`<->`SSTATUS` mirroring, `mcycle`/`time` counters. Broadcasts: `priv`, `satp`, MMU enables, `tvec`, and `pmpcfg`/`pmpaddr` shadow arrays for PMP.

#### PMP (`rapt_pmp.sv`)

16 PMP entries (`RAPT_PMP_NUM=16`). Combinational match logic supporting TOR / NA4 / NAPOT modes, with locked (`L` bit) entries enforced even in M-mode. CSR file owns the architectural `pmpcfg[0..3]` / `pmpaddr[0..15]` registers (WARL on reserved A-mode encodings) and broadcasts them through `csr_bcast_if`. Checks are wired into three sites: IFU instruction fetch (raises instruction access-fault, `mtval` = faulting byte address for cross-boundary fetches), L1D load/store (raises load/store access-fault, MPRV-aware effective privilege), and PTW PTE-load path (raises access-fault on the failing PTE address). Empty PMP table allows all accesses in M-mode and denies all accesses in S/U-mode, matching the privileged spec.

### Memory Subsystem

#### LSU (`lsu/rapt_lsu.sv`)

- **IOQ / AGU** (`lsu/rapt_lsu_ioq.sv`): `IOQ_SIZE` entries (default 8) for loads, stores and atomics. A younger ready load may issue ahead of older work only after older stores have resolved and are known non-conflicting. With translation enabled, unequal 4 KiB page word offsets are sufficient to prove non-aliasing before the physical address is available; equal offsets remain conservatively ordered. `oo_pending` retains the selected entry across a multicycle L1D request; atomics and uncacheable/MMIO accesses remain ordered. The IOQ drives `completion[IntegerIssuePorts+1]` (port 3 in the default configuration) and the independent early `load_fast_if` wakeup path to IEU/FEU.
- **Unified SQ**: `SQ_SIZE` entries (default 16). One ring stores each store from execute/writeback through commit and drain. `[head,cmt)` entries are committed and survive flush; `[cmt,tail)` entries are speculative and are discarded on flush.
- Store FSM: six states (`LS_S_V`/`LS_S_R`, `LS_S_HI_V`/`LS_S_HI_R`,
  `LS_S_X_V`/`LS_S_X_R`) handle aligned drains, split misaligned drains, and
  the third RV32D FSD beat.
- Store-to-load forwarding: a shared SQ CAM gives every query port the same youngest-possible-alias priority. A younger partial store, unresolved synonym, or same-cycle allocation blocks an older forwarding candidate; CBO.ZERO also blocks forwarding. An exact, aligned, full-width store may forward only while its saved virtual address belongs to the current translation context.
- Retained stores carry a per-entry stale-context bit. System/exception flushes and fences conservatively invalidate their virtual forwarding identity, including when the next load runs in Bare mode; different page word offsets can still bypass. Ordinary non-trapping branch/jump recovery preserves the context, while interrupt/fence indications take priority. Allocation clears the reused entry's bit. These rules affect forwarding, not the committed store's saved physical drain address.
- The best-effort B load path reports completion only from an eligible SQ forwarding hit or an admitted L1D request with a matching ready response; locally blocked queries cannot inherit downstream ready.
- Split loads distinguish the aligned data beat from its architectural byte footprint. LSU supplies `rcheck_valid/offset/size_m1`; L1D captures this metadata with the request, retains it across translation, and checks the physical fragment in `rapt_l1d_access`. Live metadata from a later request cannot replace the active owner's check. The LSU precheck applies PMP to Bare addresses only; translated requests receive their physical PMP check in L1D. This does not add a pipeline stage.

#### Backend optimization handoff

The EXU split is intentionally structural. The following optimization items
remain separate microarchitecture projects, now rooted at their owning module:

- **P0-1 — earlier speculative load wakeup**: move the `load_fast_if` pulse in
  [`lsu/rapt_lsu_ioq.sv`](../hdl/backend/lsu/rapt_lsu_ioq.sv) toward the L1D
  tag-compare stage while retaining `rebusy` cancellation in
  [`rapt_iq.sv`](../hdl/backend/rapt_iq.sv). The current refactor preserves the
  existing data-return-cycle wakeup behavior.
- **P0-2 — precise memory disambiguation / store sets**: page-offset
  disambiguation now removes provably non-aliasing MMU dependencies. Replace
  the remaining same-offset/unknown-address portion of `ioq_older_store_blk` in
  [`lsu/rapt_lsu_ioq.sv`](../hdl/backend/lsu/rapt_lsu_ioq.sv) with violation
  detection, replay, and eventually a load-PC-to-store-set predictor. IOQ and
  SQ now share the LSU hierarchy; possible aliases remain ordered.
- **P1-2 — multiple outstanding L1D misses**: extract the single-miss state in
  [`memory/rapt_l1d.sv`](../hdl/memory/rapt_l1d.sv) into a small MSHR file and
  return completions to the per-entry IOQ completion storage. The current L1D
  remains single-outstanding apart from its hit-under-miss B channel.
- **P1-3 — scalable issue selection**: replace the data-capture age matrix in
  [`rapt_iq.sv`](../hdl/backend/rapt_iq.sv) with position-based oldest-first
  selection and PRF read-after-select. ALQ, BRQ, and FPQ deliberately retain
  their existing age and bypass semantics in this structural change. Selection
  is now an independent module, but read-after-select and a new pipeline stage
  have not been implemented; optional rebalancing is not a timing solution.

#### L1D (`rapt_l1d.sv`)

2-way set-associative. `2^L1D_LEN` sets (16), `2^L1D_LINE_LEN` words/line (16 RV32 words or 8 RV64 words = 64 B). Default capacity is 2 KiB. 5-state FSM (`IDLE`, `PTWAIT`, `TRAP`, `LD_A`, `LD_D`).

| Storage   | Implementation                                                                      |
| --------- | ----------------------------------------------------------------------------------- |
| Data      | Banked `rapt_sram_1rw` wide subarrays (single-port, sync read, write bypass)        |
| Tag/Valid | Per-word register arrays for simultaneous ld/st hit check + fast fence invalidation |

Write-through policy. Partial stores (SB/SH): read-modify-write (RMW) 2-cycle merge in IDLE. Speculative SRAM read: VIPT-safe virtual index in IDLE. Separate DTLB + DSTLB instances; shared DPTW for both. Reservation register for LR/SC. Cacheability via `addr_cacheable()`.

Zicbom `cbo.inval`, `cbo.clean`, and `cbo.flush` are serializing operations. Their
effective address is translated and checked as a CMO access before retirement:
load or store permission is sufficient, the PTE A bit is required, the D bit is
not, and failures use store/AMO page- or access-fault causes. M/S/U execution is
gated by the corresponding `menvcfg`/`senvcfg` CBIE and CBCFE controls. After the
unified SQ drains, the existing `fence_time` maintenance path invalidates every
L1D valid entry and flushes the data-side TLBs. This is a conservative whole-L1D
implementation; because L1D is write-through, it is architecturally at least as
strong as cleaning or invalidating the selected 64-byte architectural block.

Zicboz `cbo.zero` uses the same checked effective-address path with ordinary
store permissions, including PTE A and D checks and CBZE gating. At commit, the
SQ expands it into eight 64-bit writes in RV64 (sixteen 32-bit writes in RV32),
zeroing exactly the naturally aligned 64-byte architectural cache block. This
also implements Zic64b on physical configurations whose cache lines are only
16 bytes. Zicbop prefetch encodings are accepted as non-faulting HINTs.

#### TLB (`rapt_tlb.sv`)

Reusable fully-associative Sv32/Sv39 TLB. `ENTRIES` is configured independently for instruction and data translation (`RAPT_ITLB_ENTRIES` / `RAPT_DTLB_ENTRIES`; both 16 in the default configuration). Lookup is combinational and honors global PTEs. Fill first refreshes an existing translation, then consumes an invalid entry, and finally uses round-robin replacement. L1D instantiates separate load/store lookup replicas (`u_dtlb` and `u_dstlb`) but cross-fills both from every completed DPTW, avoiding a second walk when a page changes access direction. Bulk flush clears all entries.

#### PTW (`rapt_ptw.sv`)

Reusable page-table walker. RV32 uses a Sv32 two-level FSM (`IDLE`->`LVL1`->`LVL0`); RV64 uses a Sv39 three-level FSM (`IDLE`->`LVL2`->`LVL1`->`LVL0`). Leaf detection follows `PTE.R||PTE.X`. Svade is implemented: A=0, or D=0 for a store, produces a page fault and the walker never modifies a PTE. Instantiated as: `u_iptw` (L1I), `u_dptw` (L1D).

#### BUS (`rapt_bus.sv`)

`rapt_bus.sv` arbitrates core memory traffic onto `mem_link_if`. Reads use request IDs (`L1I`, `L1D`, `TLBI`, `TLBD`): L1I has a configurable refill-request FIFO, L1D has a held request slot, and L1D has issue priority. Responses are demultiplexed by ID. `rapt_axi_master.sv` converts that internal link to AXI4, supports up to eight outstanding reads with per-ID ownership tracking, and handles AW and W handshakes independently for one outstanding write. The bus is SoC-memory-map agnostic; the cluster-level `rapt_router.sv` decodes CLINT/PLIC MMIO and forwards all other transactions off chip.

#### L2 (`rapt_l2.sv`)

Optional unified AXI4 cache between the core bus/router path and off-chip memory. When `RAPT_L2_EN` is undefined, the module collapses to a transparent passthrough; the default configuration currently leaves it disabled. When enabled, the configured implementation is a 16 KiB direct-mapped cache (`2^RAPT_L2_LEN` sets, 64 B lines) with multi-way support reserved.

#### CLINT (`rapt_clint.sv`)

Cluster-level 64-bit `mtime` counter with `mtimecmp` and `msip`. `mtime` is paced by `RAPT_MTIME_DIV`, and the timer interrupt is level-triggered when `mtime >= mtimecmp`. CLINT MMIO is decoded by `rapt_router.sv` beside the PLIC.

The CLINT write interface carries byte strobes. The router shifts data and strobes together into the addressed register half; `mtimecmp` preserves bytes whose strobes are clear, and `msip` changes only when byte zero is enabled. Both XLEN configurations expose the `+4` high-half addresses of `mtime` and `mtimecmp`; RV64 also supports full-width access at their base addresses. `mtime` accepts byte-enabled writes; a nonempty write wins a coincident timer tick while the divider phase continues. The shared counter also supplies CSR `time/timeh` and Sstc comparisons. These register semantics do not establish supported transfer widths for other MMIO devices.

The platform also supports naturally aligned byte/halfword accesses within these CLINT registers. The router normalizes AXI lanes to the transfer's first byte; the endpoint then selects the addressed byte within the register. Reads share one register-selection and byte-alignment path. Writes reposition the normalized data and strobes within the register, preserving all unselected bytes. MSIP's upper bytes remain read-only zero. Byte/halfword support is a platform choice; RV64 aligned 64-bit `mtime`/`mtimecmp` accesses still use one atomic register transaction. RV32 FLD/FSD may decompose into two word transactions and do not provide an atomic 64-bit timer snapshot.

NPC architectural snapshots save CLINT `mtime` as the authoritative time state. Legacy `csr_time`/`csr_timeh` metadata is exported from that counter and ignored on load, including when older snapshots contain different values. CLINT time advances during the restore trampoline and is not rewound at the first resumed commit. This is architectural resume with elapsed restore time, not cycle-exact replay of the timer divider phase.

#### PLIC (`rapt_plic.sv`)

Cluster-level Platform-Level Interrupt Controller. Default `NDEV=31` sources and `NCTX=2` contexts (`ctx0` M-mode hart 0, `ctx1` S-mode hart 0). Implements priority, pending, enable, threshold, and claim/complete registers in the standard `0x0c00_0000` 16 MB window. The legacy single-bit `io_interrupt` input is merged into PLIC source 1, and the core consumes `meip/seip` from the PLIC context outputs.

Threshold controls interrupt notification; polling a claim register still selects the highest-priority enabled pending source, with priority zero excluded. Completion checks the full 32-bit command and the receiving context's enable mask, so an out-of-range ID cannot alias a valid source. An enabled context may complete a source claimed by another context. These rules follow the [PLIC 1.0 claim and completion specification](https://github.com/riscv/riscv-plic-spec/blob/master/riscv-plic.adoc).

For word-aligned PLIC register transactions, the router shifts byte strobes with write data into the endpoint. Unselected enable bytes are preserved; priority, threshold and completion require the low byte, and zero strobes cause no write side effect. The core's supported-access PMA permits naturally aligned 32-bit ordinary loads/stores in this PLIC window. Other ordinary access widths raise load/store access faults before device data reads or SQ allocation. This is the platform's width policy; the PLIC specification defines atomic 32-bit register accesses without mandating this particular fault policy for every other width.

Split loads carry their original architectural width separately from each physical fragment's permission footprint. L1D captures both with the request; IOQ checks stores using the architectural width before SQ allocation. Consequently RV32 FLD/FSD cannot turn an unsupported eight-byte device access into two permitted word accesses. The policy applies after translation as well as in Bare mode, independently of PBMT. Other devices' supported widths require separate region contracts. The existing software pending-set extension remains a platform-specific behavior and is not evidence of full PLIC 1.0 conformance.

NPC differential interrupt synchronization observes the driving PLIC `seip_q` bit for hart 0. It does not use an optimized-away core input shadow or replace the hardware level with the combined software/hardware `mip.SEIP` value.

## Interfaces

### Inter-module (`rapt_if.svh`, `rapt_*_if.svh`)

| Interface        | Direction               | Description                                               |
| ---------------- | ----------------------- | --------------------------------------------------------- |
| `ifu_bpu_if`     | IFU<->BPU               | PC for prediction; NPC + taken back                       |
| `ifu_l1i_if`     | IFU<->L1I               | PC fetch request; `inst_n0` + `inst_n1` + trap response   |
| `ifu_idu_if`     | IFU<->FQU / FQU<->IDU   | fetch slot[] with per-instruction metadata; valid/ready[]   |
| `idu_rnu_if`     | IDU->RNU                | slot[DecodeWidth] with uop, operands and arch IDs                         |
| `rnu_rou_if`     | RNU->ROU                | slot[RenameWidth] with uop, physical mappings and control-flow checkpoint identity |
| `rapt_recovery_if` | ROU->IFU/FQU/IDU/RNU | One oldest-mispredict transaction: pending, one-shot redirect, owner/generation, target and checkpoint |
| `checkpoint_release_if` | ROU->RNU       | Completion-width correct-control releases; independent of recovery ownership |
| `{domain,token} candidate[K]` | ROU->DPU | Age-ordered lightweight steering candidates; identity does not depend on endpoint ready |
| `token winner[W]` | DPU->ROU               | Oldest capacity-admissible candidate identities            |
| `SlotT dispatch[W]` | ROU->EUs            | Winner uop/operands/ROB tag; full payload remains DispatchWidth-wide |
| `rou_lsu_if`     | ROU->LSU                | Store commit (addr/data/alu)                              |
| `rou_csr_if`     | ROU->CSR                | CSR write + trap/system on commit                         |
| `rou_cmu_if`     | ROU->CMU                | slot[CommitWidth] events plus scalar recovery effects           |
| `dpu_iq_if`      | DPU<->IEU/FEU           | Queue allocation and free-slot backpressure               |
| `dpu_ioq_if`     | DPU<->LSU               | IOQ capacity and accepted global slot mask               |
| `CompletionT completion[]` | EUs->ROU/PRF/LSU/IQs | Guarded effects/results with ROB slot + allocation generation identity |
| `rob_completion_owner_if` | ROU->core guards | Read-only live/executing/generation/destination ownership directory |
| `load_fast_if`   | LSU->IEU/FEU            | Guarded early-load identity, rebusy, and full-identity confirmation data |
| `IssueT issue[]` | IQ->pipe                | Whole-uop issue packets; per-port availability/capability |
| `exu_prf_if`     | ROU->PRF                | Operand pre-read (2 per rename position)                        |
| `fpr_if`         | FEU/LSU<->FPR           | FP register reads and arithmetic/load writeback          |
| `lsu_pipe_if`    | LSU internal            | IOQ/AGU to SQ load request and response                   |
| `exu_csr_if`     | IEU->CSR                | CSR read port                                             |
| `lsu_l1d_mmu_if` | LSU->L1D                | Store MMU + SC reservation check                          |
| `cmu_bcast_if`   | CMU->all                | Retire broadcast (flush, fence, branch, call/ret)         |
| `csr_bcast_if`   | CSR->all                | Priv, SATP, MMU enable, tvec                              |
| `lsu_l1d_if`     | LSU->L1D                | Load/store data path                                      |
| `l1i_bus_if`     | L1I->BUS                | I-cache miss read                                         |
| `l1d_bus_if`     | L1D->BUS                | D-cache miss read + write-through                         |

### Legacy RNU harness interfaces

`rapt_rnu_internal_if.svh` and the old standalone MAP/freelist modules are not
instantiated by the core. Their historical formal harness does not prove the
current integrated allocator; see the new rename recovery test. The
`superscalar-structure-check` target excludes these legacy harnesses and the
LSU's intentionally physical hit-under-miss channels, while rejecting fixed
A/B lane APIs anywhere in the active ordered frontend/backend pipeline.

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
| `RAPT_ROB_GENERATION_BITS` | 4 | Per-slot allocation generation width; not a standalone cancellation protocol |
| `RAPT_BRANCH_CHECKPOINTS` | 16 | Independent control-flow rename snapshots; exhaustion backpressures rename |
| `RAPT_RS_SIZE`       | 8         | ALU issue queue (ALQ) entries, shared by ALU-CSR/ALU |
| `RAPT_IOQ_SIZE`      | 8         | In-order memory queue entries              |
| `BRQ_SIZE` (param)   | 4         | Branch issue queue entries                 |
| `MDQ_SIZE` (param)   | 4         | MUL/DIV issue queue entries                |
| `RAPT_SQ_SIZE`       | 16        | Unified store queue entries                |
| `RAPT_L1D_LINE_LEN`  | 4 / 3     | RV32: 16 words/line; RV64: 8 words/line    |
| `RAPT_L1D_LEN`       | 4         | L1D sets: 2⁴ = 16                          |
| `RAPT_L1D_N_WAYS`    | 2         | L1D ways (2-way SA)                        |
| `RAPT_ITLB_ENTRIES`   | 16        | Fully-associative ITLB entries             |
| `RAPT_DTLB_ENTRIES`   | 16        | Entries in each L1D DTLB lookup replica    |
| `RAPT_L2_EN`         | undefined | Optional L2 defaults to passthrough        |
| `RAPT_L2_LEN`        | 8         | L2 sets: 2⁸ = 256 when enabled             |
| `RAPT_L2_N_WAYS`     | 1         | L2 ways when enabled                       |
| `RAPT_COMMIT_WIDTH` | 2 | Maximum ready-prefix retirement width |
| `RAPT_DECODE_WIDTH` | 2 | Decode / frontend slot width |
| `RAPT_RENAME_WIDTH` | DecodeWidth | Rename / PRF pre-read width |
| `RAPT_DISPATCH_WIDTH` | RenameWidth | ROB / execution-queue allocation width |
| `RAPT_INTEGER_ISSUE_PORTS` | 2 | Number of physical integer issue/FU ports |
| `RAPT_INTEGER_SYSTEM_PORT` | 0 | Integer-port index owning CSR/system capability and the FP-shared completion endpoint |
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
