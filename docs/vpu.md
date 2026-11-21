---
title: Vector extension
---

# Raptor vector extension

Raptor implements V 1.0 on RV32 and RV64, including integer, fixed-point,
permutation, vector memory and FP32/FP64 instruction families.
`rapt_backend` instantiates `rapt_vpu_core` when `RAPT_V_EXTENSION` is defined.
The VPU executes under ROB-head ownership and uses the core's existing data
MMU, PMP/PMA, L1D and cluster memory path.

The default full-V geometry is VLEN=128, ELEN=64 and two 64-bit VRF banks
in either XLEN mode. RV32 supports 64-bit vector data but limits indexed memory
index EEW to 32 bits. Full V requires scalar F/D and precise traps.
[Ratified V 1.0 specification](https://docs.riscv.org/reference/isa/v20260120/unpriv/v-st-ext.html)

## Core configuration and architectural state

The [ISA matrix](./README.md#isa-scope) lists the default presets and opt-outs.
Other F/D-capable presets can enable V with `RAPT_V_EXTENSION`.
`RAPT_VLEN`, `RAPT_VRF_BANK_BITS` and `RAPT_VRF_BANKS` configure storage
geometry. Integrated ELEN is 64; the current NPC/NEMU vector sidecar uses
VLEN=128. Standalone tests exercise other widths and bank geometries.

MISA.V, the device tree and simulator reference features follow the effective
configuration. VS gates vector instructions and CSRs. Vector and FP completion
updates dirty state and accrued flags. Vector commands retain their tagged
ROB owner through the final memory response. Permission probes have no data
side effects or cache-miss allocation. RV32 splits 64-bit ordinary-memory
elements into two bus beats and rejects an unsupported 64-bit device access
before issuing it. Segment probes precede data accesses and reject non-idempotent
segments before side effects. Precise stores bypass the scalar SQ's
post-retirement error path and wait for the L1D response. Errors beyond a
write-back cache's acknowledgement remain platform errors at that boundary.

NPC compares all 32 vector registers and seven vector CSRs at retirement through
versioned NEMU sidecars. Checkpoints include that state and restore it through
real vector instructions before resuming the guest. The restore path checks the
complete vector state before resynchronizing the reference.

```sh
make -C verification/subsystem vector-system-smoke \
  CONFIG=default XLEN=32 BUILD_DIR=/tmp/vector-rv32
make -C verification/subsystem vector-system-smoke \
  CONFIG=default XLEN=64 BUILD_DIR=/tmp/vector-rv64
make -C verification/subsystem vector-disabled-smoke CONFIG=default XLEN=64 \
  VECTOR_DEFINES=RAPT_NO_VPU BUILD_DIR=/tmp/vector-disabled
```

The shared payload generator is `verification/subsystem/vector_programs.py`.
Its `catalog` mode expands the 375 baseline opcode entries across SEW, mask,
segment count and restart settings and emits a case manifest beside the assembly.
Use `--success-code 0` for NPC and the default ten for the directed RTL harness.
`make -C verification/subsystem vector-catalog-diff XLEN=64` uses an existing
NPC/NEMU build. `VECTOR_NPC` and `VECTOR_REFERENCE` select isolated binaries.
The whole-core smoke covers VS and CSR traps, context restart, non-idempotent
MMIO and precision of page/access faults, including the second beat of RV32
64-bit elements. The chip-link tests inject AXI/xSPI decode and slave errors.
The November 19, 2026 integration run passed 17 ACT4 vector-memory cases on
each XLEN.
[Integrated test commands](https://github.com/Kingfish404/raptor-chip/blob/master/verification/subsystem/README.md#integrated-vector-programs)

The [RV64 user profile](./README.md#rva23u64-support) enables Zvbb, Zvfhmin
and Zvkt. Zvfhmin provides binary16 conversions. Zvkt uses fixed multiply
latency and reads both vector merge sources independently of the selector bits.
The profile also enables misaligned elements in ordinary memory and checks
every byte before a split store. Run `make -C verification/subsystem
rva23u64-smoke` to exercise these paths, including U-mode vector memory.

In the [RV64 supervisor profile](./README.md#rva23s64-support), guest execution
also checks `vsstatus.VS` and `vsstatus.FS` for the applicable vector operations.
Guest vector memory uses the shared VS-stage and G-stage translation path.
The [directed supervisor suite](./getting-started.md#verify-the-rv64-supervisor-profile)
includes guest vector execution alongside the translation and timer cases.

## Available modules

These modules live in `rtl/core/backend/vpu/`. Their default SRAM control type
is `rapt_pkg::sram_ctrl_t`.

| Module | Contract |
| --- | --- |
| `rapt_vpu_vtype` | Calculate type legality, VLMAX and `min(AVL, VLMAX)` or keep-VL. |
| `rapt_vpu_vrf` | Store 32 architectural registers in banked 1RW SRAM with byte writes and held reads. |
| `rapt_vpu_csr` | Own seven vector CSRs, VS checks, restart, FOF and saturation updates. |
| `rapt_vpu_owner` | Capture, authorize, cancel, complete and drain operations by owner tag. |
| `rapt_vpu_element` | Route naturally aligned 8/16/32/64-bit accesses across VRF banks. |
| `rapt_vpu_predicate_cache` | Cache the predicate byte for an element index. |
| `rapt_vpu_decode` | Admit raw encodings and classify the supported operations. |
| `rapt_vpu_memory` | Sequence unit/strided/indexed/segment/whole/mask/FOF memory with restart. |
| `rapt_vpu_muldiv` | Iteratively multiply/divide 8–64-bit elements, with optional early completion. |
| `rapt_vpu_mask_write` | Update one mask bit with an exclusive byte read-modify-write. |
| `rapt_vpu_geometry` | Check EEW, EMUL, group extents, alignment and overlap for each operand. |
| `rapt_vpu_fixed` | Round and saturate fixed-point arithmetic, including the full product for `vsmul`. |
| `rapt_vpu_mask_scan` | Find the first set bit or count bits with predicate reuse. |
| `rapt_vpu_move` | Sequence aligned whole-register moves with SEW-based restart. |
| `rapt_vpu_reduce` | Reduce integer sums, min/max, logical results and widening sums. |
| `rapt_vpu_alu` | Evaluate integer arithmetic, logic, shifts, compares and merge/carry/borrow. |
| `rapt_vpu_slide` | Route slide and slide1 elements using full-XLEN offsets. |
| `rapt_vpu_divsqrt` | Divide or take a square root with FP32/FP64 selection and held result/flags. |
| `rapt_vpu_fp_decode` | Decode scalar sources, element widths and FP arithmetic/conversion. |
| `rapt_vpu_fp_arith`, `rapt_vpu_fma` | Evaluate FP32/FP64 add, subtract, multiply and FMA. |
| `rapt_vpu_int_fp_decode` | Decode eighteen integer/FP conversion selectors with EEW and rounding. |
| `rapt_vpu_int_fp`, `rapt_vpu_int_fp_shared` | Convert integer16/32/64 and FP32/64 under legal width pairings. |
| `rapt_vpu_fp_convert` | Convert FP widths, including the Zvfhmin half-precision paths. |
| `rapt_vpu_fp_estimate` | Produce seven-bit FP32/FP64 reciprocal and reciprocal square-root estimates. |
| `rapt_vpu_fp_transfer` | Route merge, broadcast, scalar transfer and slide1 for vector FP. |
| `rapt_vpu_fp_reduce` | Reduce FP sums, min/max and FP32-to-FP64 widening sums. |
| `rapt_vpu_core_adapter` | Match ROB-head authorization and preserve immutable retirement metadata. |
| `rapt_vpu_core` | Connect the numerical VPU to its core-side adapter. |
| `rapt_vpu` | Compose the VRF and execution engines, with serialized commands and an idle host port. |

## Relocatable RTL source export

`python3 verification/vpu/export_rtl.py /tmp/my-vpu-rtl` creates a new directory
containing the required source/license files, a relative-path `sources.f`, a short
integration README and a SHA-256 manifest. Existing destinations are refused.
The export includes both `rapt_vpu` and `rapt_vpu_core`, shared scalar numerical
primitives, the behavioral `rapt_sram_1rw`, and required headers. It does not
depend on generated scalar decode or `sim/.config`. The bundle contains the
minimal shared package and default preset. Technology-specific SRAM macro
libraries are not included.

From the exported directory:

```sh
verilator --lint-only --assert -Wall -DRAPT_ASSERT_EN \
  verification/vpu/fma_legacy.vlt -f sources.f --top-module rapt_vpu_core
```

`python3 verification/vpu/test_export_rtl.py` relocates a fresh export outside the
repository into a directory containing a space, then checks both tops in five
configurations: RV32/128/32/64/1, RV32/128/64/64/2, RV64/128/64/64/2,
RV32/256/64/64/4 and RV64/512/64/128/4 (XLEN/VLEN/ELEN/BankBits/Banks).
The ten lint/elaboration checks retain the existing narrow FMA waivers;
they are not functional simulations or physical implementation checks.
The test also requires a missing shared header to fail and an existing export
destination to remain untouched. Logs and source-current evidence are recorded
under `verification/build/vpu/export-rtl/`.

## Independent tests

From the repository root:

```sh
make -C verification/vpu test
make -C verification/vpu matrix
make -C verification/vpu top-matrix
make -C verification/vpu owner-formal
make -C verification/vpu synth
make -C verification/vpu vrf VLEN=512 BANK_BITS=128 BANKS=4
```

The standalone Verilator tests use a host C++ toolchain. They enable assertions
and fatal warnings with scoped waivers for unused bits and shared scalar FMA.
Builds, logs and source fingerprints live under `verification/build/vpu/`.
The VRF test uses seed `0x6a09e667`.

`test` runs the default leaves, ownership and top suites. `matrix` covers
configuration, CSRs and VRF. `top-matrix` covers five configurations and two
tag widths. The integrated element adapter requires `BankBits >= 64`; VRF
storage tests also cover narrower banks.

`synth` requires Yosys with slang. It checks latches, unexpected blackboxes
or assertion cells, VRF capacity, and one write port and registered reads per
bank. See `verification/build/vpu/synth/summary.json`. For individual leaf
and optimization targets, see the
[VPU Makefile](https://github.com/Kingfish404/raptor-chip/blob/master/verification/vpu/Makefile).

### Independent Spike differential tests

```sh
make -C verification/vpu top-matrix DIFF=1 SPIKE_BUILD=/path/to/spike-source-build
make -C verification/vpu opt-check DIFF=1 SPIKE_BUILD=/path/to/spike-source-build
```

The optional adapter requires a separately built Spike source/build tree with
its static libraries and development headers, plus the libraries named in the
Makefile. `reference_manifest.py` enforces source revision
`770ce31f7543f57472b35e66600085ea81184bb2`, checks the relevant tracked source
directories for modifications, and records static-library/configuration hashes.
It does not rebuild or modify the reference tree. The commit and library hashes identify the reference used by a run.

Each non-cancelled command executes through Spike's instruction fetch/decode/
execution path. Scalar inputs and idle host VRF initialization are injected as
test inputs. Results, trap metadata, CSR reads and VRF contents are compared;
there are no instruction-difftest skips. VSTART-capable arithmetic is selected
using Spike's existing `vstart_alu` policy. RV32 PC and result comparisons use
XLEN-sized values because Spike internally sign-extends RV32 addresses.
The reference executes in M-mode. Data accesses use an independent 64 KiB
byte array at 0x90000000 via Spike's MMIO callbacks, so direct host-memory TLB
entries cannot bypass fault injection. Access failures and synthetic page-fault
exceptions are injected at chosen addresses. This does not exercise page-table
walks, S-mode translation, Linux, interrupts, or physical MMIO devices. The bus
scoreboard separately checks external effect counts; the Spike adapter never
copies DUT stores back into the reference array.

The additional integer reference model snapshots source registers before
updating destinations and remains enabled alongside Spike. The current pinned
reference preserves the inactive/tail elements exercised here, matching the
DUT's permitted undisturbed policy. The pinned reference also preserves the mask-result bits exercised here. Other
allowed reference policies, floating reductions and architecturally variable
results require explicit allowed-result comparison rules; full-byte equality is
not assumed to apply to every future instruction/reference configuration.

Build/run logs, current source SHA256 fingerprints (`sources.json`), and
reference fingerprints (`reference.json`) reside in each configuration's build
directory. Differential tests use a separate `-spike` build suffix.

## Module contracts

### Top and instruction lifecycle

`cmd_valid && cmd_ready` captures the instruction and scalar operands, including
`cmd_frs1` (64-bit FPR value), `cmd_frm` (resolved FRM), and `cmd_fp_enabled`
(FS availability). These fields may be tied to zero when floating point is
not used. The adapter must resolve older FPR/FRM/FS dependencies before command
acceptance; these inputs are snapshots, not live CSR bypasses. A later
`authorize_valid && authorize_ready` grants irrevocable execution for the matching
opaque tag. The tag must include host ROB allocation generation as well as slot.
Wrong-tag authorization has no effect. A matching kill before authorization
cancels the command, including a kill coincident with initial acceptance or
authorization; `cancelled` reports that event.

Once authorized, cancellation is blocked (`kill_blocked`). The host must retain
the instruction's retirement/trap owner until `rsp_valid && rsp_ready`. Results
and tag remain stable during completion backpressure. The owner can accept a
zero-cycle engine result and drains early, stale and duplicate results without
overwriting a valid completion. A finite tag cannot distinguish a delayed result
from a later reuse of the identical tag: future memory completion must guarantee
all accepted work has drained before releasing ownership.

The engine generally processes active elements sequentially and issues vector
memory accesses per element. With `PackLogic=1` (the default), unmasked e8
vector-vector AND, OR and XOR process each complete aligned group of eight bytes
as one operation; leading, trailing and masked elements use the ordinary path.
Byte-oriented vector loops can still have lower throughput than tuned scalar code.
Memory coalescing would need to preserve masking, `vstart`, fault-only-first
behavior and device-memory access semantics; measure it with real workloads as
well as block-level tests before enabling it.

`vector_enabled` supplies architectural VS availability when the engine accepts
the authorized command. Scalar operands are supplied by the host after resolving
scalar dependencies. Vector configuration is read in execution order from the
VPU's architectural CSR module. The engine is non-speculative and accepts
only one command at a time. Normal arithmetic clears VSTART on completion;
illegal instructions preserve vector state and return cause=2 with the instruction
bits in TVAL. `rsp_rd` identifies scalar writes; vector arithmetic returns rd=0.
`rsp_dirty` tells the host to update VS/SD at its architectural update boundary.
For legal FP arithmetic, `rsp_fp_dirty` also requests FS/SD dirty state and
`rsp_fflags` supplies this command's exception delta. The host ORs that delta
into architectural fflags at the matching completion boundary. The VPU does not
own a second FCSR. Inactive/prestart/tail elements contribute no exceptions;
flags are accumulated after each active element's VRF write acknowledgement.
Trap and cancellation paths produce no FP flags update. Completion backpressure
holds the FP metadata along with the existing tag/result.

The idle-only `host_*` interface accesses VRF elements for debug/context/test
setup. Accepted requests block new commands until the host consumes the response.
The host must provide natural-aligned addresses and is responsible for debug
authorization and context CSR/VS management; this port is not a user-mode ISA.
Tie it inactive when it is not used by an integration. Host traffic cannot access
VRF while a vector command is pending, executing or waiting for retirement.

Currently executable instruction families:

| Family | Forms |
| --- | --- |
| Configuration | vsetvli, vsetivli, vsetvl |
| Vector CSR | CSRRW/CSRRS/CSRRC and immediate forms at the seven vector CSR addresses |
| Add and logical | vadd, vand, vor, vxor: vv/vx/vi |
| Subtract and min/max | vsub, vmin[u], vmax[u]: vv/vx; vrsub: vx/vi |
| Shifts | vsll, vsrl, vsra: vv/vx/vi; immediate shift amounts are zero-extended |
| Multiply/divide | vmul, vmulh[u], vmulhsu, vdiv[u], vrem[u]: vv/vx |
| Multiply-add/subtract | vmacc, vnmsac, vmadd, vnmsub: vv/vx; old destination is an explicit input |
| Widening add/subtract | vwadd[u], vwsub[u]: vv/vx and wv/wx |
| Widening multiply | vwmul[u], vwmulsu: vv/vx |
| Widening multiply-add | vwmacc[u], vwmaccsu: vv/vx; vwmaccus: vx |
| Narrowing shift | vnsrl, vnsra: wv/wx/wi |
| Integer extension | vzext.vf2/vf4/vf8, vsext.vf2/vf4/vf8 |
| Saturating arithmetic | vsadd[u]: vv/vx/vi; vssub[u]: vv/vx |
| Averaging arithmetic | vaadd[u], vasub[u]: vv/vx |
| Fractional multiply | vsmul: vv/vx |
| Scaling shifts | vssrl, vssra: vv/vx/vi |
| Narrowing clip | vnclip[u]: wv/wx/wi |
| Compare | vmseq/vmsne/vmsle[u]: vv/vx/vi; vmslt[u]: vv/vx; vmsgt[u]: vx/vi |
| Mask logic | vmand[n], vmor[n], vmxor, vmnand, vmnor, vmxnor: mm |
| Carry/borrow | vadc, vmadc: vector/vector, scalar and immediate forms; vsbc, vmsbc: vector/vector and scalar forms; optional carry-in for mask results |
| Merge and move | vmerge.vvm/vxm/vim; vmv.v.v/v.x/v.i |
| Memory | Unit-stride, strided, ordered/unordered indexed, segment, whole-register, mask and unit-stride FOF loads |
| Integer reductions and transfers | Sum/min/max/logical reductions; whole-register moves; scalar/vector transfers; vid |
| Mask scans and permutation | vcpop/vfirst, first-bit mask prefixes, viota, compression, integer slides and gathers |
| FP32/FP64 arithmetic | Single-width and widening arithmetic, FMA, divide/sqrt, min/max, sign injection, classification and comparisons |
| FP conversion and routing | Format and integer conversions, reciprocal estimates, merge/broadcast, scalar transfers and slide1 |
| FP reductions | Ordered/unordered sums, min/max, and FP32-to-FP64 widening sums |

Supported integer instructions honor the legal SEW/LMUL combinations, register
group alignment, masking and VSTART. Tail and inactive elements are preserved,
including in agnostic modes. Unsupported parameter/width combinations and
optional extensions outside this baseline raise illegal instruction. Some
reserved encodings also trap; others execute as a compatibility behavior and
must not be relied on by portable software.

### Fixed-point arithmetic and saturation ownership

The fixed-point stage implements signed/unsigned saturating add/subtract,
averaging add/subtract, scaling right shifts, narrowing clips and signed fractional
multiply. `rapt_vpu_fixed` is stateless and independent of the VRF and core package.
Its operation codes 0..12 correspond to vsaddu, vsadd, vssubu, vssub, vaaddu,
vaadd, vasubu, vasub, vssrl, vssra, vnclipu, vnclip and vsmul. The caller supplies
legal widths: clip consumes twice the destination SEW and at most 64 source bits.
It receives the architectural VXRM value and returns a value plus saturation bit.

Rounding implements RNU, RNE, RDN and ROD using the discarded bits and retained
LSB, with a zero shift leaving the value unchanged. Saturation follows rounding
for clips and fractional multiply. Averaging subtraction wraps when necessary;
averages and scaling shifts do not set saturation. The stage contains no
combinational multiplier: vsmul requests a signed multiply from the existing
iterative engine, captures its full 128-bit product, and rounds at SEW-1 before
clamping to the signed destination range.

The multiply/divide leaf exposes `full_product` alongside `result`. The full
product is meaningful for multiply operations, signed according to the operation,
and held through response backpressure. Zero-product early completion clears it
rather than retaining an earlier product. Leaf tests independently verify all four
32-bit words of every multiply result in both early-completion modes.

The top accumulates saturation only when an active fixed-point element's VRF
write is accepted. Completion ORs that accumulated flag into VXSAT through the
existing authorized CSR execution event. Masked/prestart/tail elements cannot
contribute; zero VL, illegal instructions and pre-authorization cancellation
preserve VXSAT. The single instruction owner prevents VXRM from changing during
execution. VCSR alias reads and explicit CSR clears use the same architectural
state as other instructions. Future interruptible execution must preserve any
completed prefix's saturation along with restart state.

`fixed_reference.h` computes rounding numerically using floor quotient and
nonnegative remainder, independently of the RTL's discarded-bit implementation.
`make -C verification/vpu fixed` checks exhaustive 8-bit input pairs for
the non-clip operations across all four modes, exhaustive 16-bit clip inputs with
five boundary shift amounts across all modes, and 16/32/64-bit edge cross-products
and random cases. It supplies independently calculated full products to test the
rounding stage; the separate multiply/divide test covers product generation.

Integrated tests execute actual instructions in Spike and compare the full VRF,
VSTART, VXRM, VXSAT and VCSR. They cover all rounding modes, scalar/immediate forms,
legal SEW/LMUL, narrowing overlap,
all-zero and alternating masks, nonzero VSTART, zero VL, sticky saturation initially
clear/set, and invalid or cancelled instructions. Whole-register move encodings sharing funct6=0x27 with fractional multiply
are decoded as their own instruction family.

### Mixed-width arithmetic geometry

`rapt_vpu_geometry` derives source and destination sizes and checks each register
group independently. Arithmetic byte sizes are log2(EEW/8); EMUL is represented
by its signed power-of-two exponent. The leaf checks the ELEN/type limits,
fractional-group minimum, EMUL<=8, alignment, register extent and permitted
source/destination overlap. Mask operands retain their single-register EEW=1
rules. It is a stateless leaf with no XLEN, VLEN, ROB or core-package dependency;
it consumes instruction-class controls from the decoder. Memory retains its
own segment/index/whole-transfer geometry checks.

The top retains separate source-A and destination element sizes; source B
uses SEW. Widening arithmetic doubles destination EEW/EMUL, `.w` forms also double
source-A EEW, narrowing shifts double source-A EEW only, and integer extension
reduces source-A EEW by 2/4/8. Reads are sign/zero-extended according to each
operand's instruction-defined signedness. Mixed-sign widening MAC follows the
encoded scalar/vector operand roles, rather than assuming both sources share a
signedness. Output bytes are selected using destination EEW.

Widening multiplies reuse the iterative low-product engine at the destination
width after operand extension. Widening MAC additionally reads the old wide
destination. This is correct for the supported 16/32/64-bit results but is not
claimed to be a fully pipelined multiplier. Narrowing right shifts operate at
the wide source width (including shift-amount masking), then truncate to the
narrow destination. Integer extensions route the resized source directly to
writeback. Unsupported widths, source EMUL and overlaps trap before any access
that changes architectural state.

The redundant operand-read optimization requires equal read EEWs as well
as equal source-register numbers. Overlapping sources with different EEWs use
independent reads for compatibility with the pinned Spike build. The [ratified
V specification](https://docs.riscv.org/reference/isa/unpriv/v-st-ext)
reserves such encodings; these cases are not evidence of standard ISA coverage.
When an equal-width read is reused for mixed-sign
operations, each operand still receives its own sign/zero extension.

`test_integer.h` checks widening add/subtract, wide-source forms, widening
multiply/MAC, narrowing logical/arithmetic shifts and all six integer-extension
forms against an independent 128-bit snapshot model and Spike. It covers supported
SEW/LMUL combinations, unsigned/signed extrema, random data, policy bits, scalar
and immediate inputs, zero VL, restart boundaries, legal high/low overlaps,
same-register sources with equal EEWs, and reserved/invalid encodings.
The geometry leaf is exercised through these integrated commands; no separate
formal proof or exhaustive register-tuple proof is claimed.

### Mask results and carry/borrow

Comparisons write one result bit per active element. The mask destination is a
single register regardless of LMUL; sources retain their ordinary SEW/LMUL.
Overlapping a wider source is legal only at that source group's lowest register.
Masked comparisons may write v0. The eight mask-logical instructions instead use
single-register, EEW=1 source and destination operands and require vm=1.

`rapt_vpu_mask_write` accepts a byte address, bit position and value, reads the
old byte, writes the merged byte, waits for write acknowledgement, and holds
completion until consumed. It requires exclusive access throughout this sequence;
the top's authorized single-instruction owner provides this exclusion. This is
not an atomic primitive for arbitrated external writers. The separate leaf has
no ISA decode, core package or vector geometry dependency beyond address width.

All current mask-result operations preserve prestart, inactive and tail bits,
including agnostic modes. Tail-agnostic permits this preserved-value policy; it
does not require clearing/filling the tail. Byte read-modify-write prevents a
single active bit from corrupting neighboring inactive/prestart/tail bits. The
encoded tests compare the entire VRF with the independent snapshot model and
pinned Spike implementation, whose exercised policy also preserves those bits.

For vadc/vsbc and carry-in forms of vmadc/vmsbc, v0 supplies arithmetic data,
not execution predication: every body element executes even when its v0 bit is
zero. For the no-carry-in mask-result forms (vm=1), carry/borrow input is zero.
The ALU retains an extra bit for unsigned sum/borrow detection, including SEW=64.
Vector-result forms reject vd=v0; reserved unmasked vector-result forms and
subtract-immediate encodings trap without state updates.

`mask-write` exhaustively checks all 256 old bytes, eight bit positions and two
new values (4,096 cases), plus reset at all request/response boundaries. Its
independent ready/valid test varies request stalls, response delay and completion
backpressure. Source fingerprints are written beside the leaf run log.
Integrated tests cover every comparison encoding, all eight mask-logical
operations, carry/borrow forms, legal SEW/LMUL combinations through m8, policy bits,
mask destination v0, unaligned single-register mask destinations, valid/invalid
source overlaps, zero VL, partial final bytes and vstart boundaries.

### Integer multiply/divide and destructive multiply-add

`rapt_vpu_muldiv` is independent of the VRF, XLEN and core package. It accepts
one already-authorized element with a three-bit operation and SEW, then holds
its result until acknowledged. Its operation mapping is the low three funct6
bits of OPMVV/OPMVX `100xxx`: divu, div, remu, rem, mulhu, mul, mulhsu, mulh.
Decode legality is handled above the leaf. Signed operations use SEW-sized
magnitudes and explicit result signs. Divide-by-zero returns all ones for
quotient or the original dividend for remainder. Signed overflow follows the
architectural wrapped quotient/zero-remainder behavior without a trap.

The baseline uses SEW rounds of shift/add multiplication or restoring division;
it has no combinational multiply/divide operator. `EarlyOut=1` (default) returns
early for zero products, magnitude-smaller dividends and unit divisors, and stops
multiplication after the multiplier's last nonzero bit. `EarlyOut=0` retains the
baseline; division by zero is a direct architectural special case in both.
This is a functional and resource-conscious initial engine, not a claim of
high-throughput vector multiplication.

The top adds an old-destination read for vmacc/vnmsac/vmadd/vnmsub, routes the
appropriate multiplicands through the low-product operation, and then adds or
subtracts that product. The old destination participates in the same authorized
VRF access protocol as other operands. Every active element completes before the
next element begins, preserving legal same-width overlaps. Future instruction
chaining must account explicitly for the old-destination dependency.

`make -C verification/vpu muldiv` checks exhaustive 8-bit inputs, wider edge and
random cases, backpressure and reset. `muldiv-opt-check` compares both early-out
settings with the same input workload and records source fingerprints and
simulation-cycle counts in `verification/build/vpu/muldiv-optimization.json`.

The integrated encoded-instruction tests cover vv/vx, all supported SEWs and
fractional/integer LMUL through m8, extrema and random operands, division by zero,
masking, zero VL, writable vstart boundaries, destination/source overlaps and
equal source registers. Every command executes in Spike as well as the independent
128-bit arithmetic model. The tests explicitly check
vstart WARL truncation before computing active elements.

### Sequential memory contract and validation

The memory leaf issues naturally aligned element accesses with virtual byte
addresses. `mem_size` is log2(bytes); load responses and store data are normalized
to the low bits of the 64-bit data bus. The adapter owns translation, PMP/PMA,
cache/order semantics and final errors. Misalignment traps before request issue;
masked elements issue no accesses. Indexed offsets are zero-extended, with index
EEW limited to XLEN. Both ordered and unordered indexed forms execute serially.

Every response must echo tag, element index, field and probe phase. A matching
response may coincide with request acceptance. Mismatches are consumed without
advancing progress. This is a dedicated response channel, not permission to drain
other LSU clients' responses. A successful store response means that access can
no longer fault; a failed request must not have performed a non-idempotent effect.
After a request is accepted, its write, probe, address, size, data and identity
fields remain stable until the matching response. An assertion and an independent
request ledger check this ownership contract, including zero-cycle responses.

For multi-field segments, each field first receives a side-effect-free PMA/MMU
probe. Any non-idempotent field causes an access fault before actual field
accesses. The adapter must maintain the validated attributes through that segment.
A probe is not an atomic transaction or a guarantee against late actual-access
errors. Actual idempotent accesses can leave a partial segment before a fault;
restart repeats that segment. Single-field non-idempotent accesses execute in
order, with completed elements excluded from restart.

Normal completion clears vstart. Faults return the element/segment index and
preserve VL; FOF access/page/misalignment faults at index > 0 instead reduce VL
and clear vstart. Element zero remains the trap criterion even when masked off.
Whole-register transfers ignore vill and VL and use their effective element
count. Mask transfers use ceil(VL/8) bytes with byte-indexed vstart.

`memory_model.h` models final memory effects independently of expected vector
results. Reproducible transaction-number-based delays exercise request stalls,
response delays, zero-cycle completion and corruption of each ownership-tuple
field. `test_memory.h` computes expected transfers before issue and compares the
entire VRF and data memory. The encoded workloads cover:

- Supported SEWs and memory/index EEWs, fractional and integer LMUL through m4,
  one/three/eight-field legal combinations, mask and nonzero vstart.
- Unit, positive/negative/zero stride, ordered/unordered indexed accesses,
  and legal equal-width/narrowing/widening index/destination overlaps.
- Whole-register groups 1/2/4/8 including vill and mask transfers with partial
  final bytes; zero VL, cancellation and natural misalignment.
- Every element and field of four-element one/three-field operations faulting
  with access or synthetic page exceptions, followed by restart. These segment
  faults are injected during actual access after successful probes, so the
  compared partial segment follows the same field order in DUT and Spike.
- In the non-Spike `memory` suite, access faults, page faults and non-idempotent
  attributes at each field of two/three/eight-field probes, including successful
  earlier probes and completed earlier segments. An independent transaction and
  byte model checks the probe order, side-effect-free faulting segment and restart.
  Spike permits a different partial faulting segment, so this check is separate
  from the strict whole-register differential comparison.
- FOF faults at every field of those segments, masked element zero, PMA segment
  rejection, reserved encodings, group bounds and indexed-overlap restrictions.

This standalone suite does not exhaust all legal group/overlap combinations or
validate the platform PMA map. The whole-core suites above additionally exercise
real translation, device side effects and external AXI errors. The standalone
adapter's synthetic PMA policy rejects non-idempotent
segments in Spike as well; it does not claim to validate a platform PMA map.

### Configuration

`rapt_vpu_vtype` computes results without modifying state. The owner selects
normal AVL, `avl_max` (rs1=x0, rd!=x0), or `keep_vl` (rs1=rd=x0); a vsetivli
immediate always uses normal AVL, including immediate zero. These modes must
come from the instruction form, not from the numerical value of a scalar operand.

The supported SEW values are 8 through ELEN. Integer LMUL 1/2/4/8 and the
fractional LMUL combinations required by ELEN are supported. Unsupported types
produce only the XLEN-high `vill` bit and VL=0. Reserved keep-VL changes in
VLMAX, including an input vill state, also set vill. Tail/mask policy bits do
not affect VLMAX. A constant geometry table avoids a runtime multiplier/divider.

### Vector register file

For architectural register `r` and byte offset `o`, let
`k = (r*(VLEN/8)+o)/(BankBits/8)`. The corresponding bank is `k % Banks`, row is
`k / Banks`, and byte lane is `o % (BankBits/8)` when BankBits divides VLEN.
The general byte lane is `(r*(VLEN/8)+o) % (BankBits/8)`.

Each bank accepts exactly one read or write on `req_valid && req_ready`.
Writes complete on that edge. Reads produce a registered response the next
cycle, held until `rsp_valid && rsp_ready`. A stalled response blocks all
accesses to that bank, including writes, because a physical SRAM may change its
read output on a write cycle. An accepted response and a new request can share
an edge. Other banks remain independent.

Reset invalidates response slots but does not initialize SRAM data. Software
context initialization, debug access, operand gathers, byte/bit mask updates,
overlap handling and architectural authorization belong above this storage
module. There is no implicit debug bypass or speculative rollback.

VRF banks use the `rapt_sram_1rw` wrapper. Behavioral
SRAM/FPGA inference supports these tests; foundry macro mode is limited to the
wrapper's existing shape catalogue. Default VRF geometry is not claimed to have
a matching physical macro. A missing macro must not be counted as synthesized
storage by treating it as an unconstrained blackbox.

### Architectural CSR state

`cfg_valid`, `csr_valid`, and `exec_valid` are mutually exclusive,
already-authorized events. A request waiting for authorization must not drive
them. `csr_write` denotes an actual CSR write after resolving RW/RS/RC write
suppression; the owner resolves read-modify-write values.

The seven supported addresses are vstart (008), vxsat (009), vxrm (00a), vcsr
(00f), vl (c20), vtype (c21), and vlenb (c22), all hexadecimal. VL, VTYPE and
VLENB reject CSR writes. VSTART retains `log2(VLEN)` bits; unused writable bits
are WARL zero. VS=Off rejects CSR/configuration access. VS storage and SD
composition remain the host's responsibility; `dirty` reports a conservative
authorized state-update event.

An execution update sets VSTART to the fault index on a trap, otherwise zero;
FOF can reduce VL without a fault. Saturation accumulates into VXSAT. The
execution controller must supply only architecturally permitted updates and
handle instruction-specific vstart restrictions. The host supplies FS availability and FRM and commits the returned FFLAGS delta. Pipeline flush is deliberately not a CSR reset: completed
elements and their restart state survive a precise trap.

## Integer reductions

`rapt_vpu_reduce` owns its accumulator and ready/valid element-memory interface,
independently of the scalar core package. The top grants exclusive VRF access to
it only after command authorization. Supported instructions are `vredsum`,
`vredand`, `vredor`, `vredxor`, signed/unsigned `vredmin`/`vredmax`, and signed/
unsigned `vwredsum`, in their vector-to-scalar forms.

The seed and destination each occupy element zero of one register, regardless
of LMUL. The engine finishes all mask/source reads before writing the destination;
this permits legal overlap with the source group, seed or v0. VL=0 causes no VRF
access; an all-masked nonempty vector copies the seed. Tail data is preserved.
Nonzero vstart is rejected even for VL=0, and illegal instructions preserve the
architectural restart state. Widening sums allow source LMUL=8 because the
widened destination is a scalar, while its element width must fit ELEN.

## Floating-point reductions

The standalone top routes all six reduction encodings through the dedicated
VRF sequencer. It bypasses elementwise destination-group geometry, retains owner
authorization and exclusive VRF arbitration, and commits reduction flags plus
FP/vector dirty events only through its held instruction completion. Successful
completion updates the vector CSR execution path; illegal commands preserve
vstart and have no destination/flags/dirty effects.

Sum requests reuse the existing FP32/FP64 arithmetic pool in add mode. Min/max
requests reuse existing miscellaneous datapaths with same-cycle service
responses. No private arithmetic pool is instantiated for reductions. The
numeric request/response routing and operand muxes remain exclusive to the
current instruction's execution state.

`rapt_vpu_fp_reduce_engine.sv` combines the reduction decoder, existing
VTYPE legality/VLMAX calculation and stream controller behind an exclusive
element VRF interface. The command must already be irrevocably authorized.
The module captures instruction/configuration/FRM/enable inputs, rejects nonzero
vstart, invalid VTYPE, VL above VLMAX and misaligned/out-of-range source groups
before any VRF or numeric request. Seed/destination indices are scalar and
remain unrestricted by source LMUL alignment.

For legal nonzero VL, the sequencer reads the seed, then reads masks and active
source elements in order. Inactive entries reach the stream controller without
a source-data read or arithmetic. It writes only the destination scalar after
all inputs have completed, preserving tail bytes and allowing overlap with
vs1, vs2 and v0. VL=0 performs no VRF or numeric access. Service errors terminate
without destination write, and no more source requests are issued. Completion
flags/trap remain held under backpressure. External VRF and numeric services
must reset/drain with the engine; this module has no transaction tags.

The reduction sequencer defaults to `CacheMask=1`. It retains one predicate
byte while processing its eight elements, invalidates it at byte boundaries and
on command acceptance, and clears validity on reset. All input reads precede
the sole destination write, so destination overlap with v0 cannot invalidate a
live cached predicate. `CacheMask=0` retains the uncached baseline.

## Architectural context save, restore and restart

`TOP_SUITE=context` exercises the architectural state-transfer sequence through
encoded instructions and public interfaces.

1. Read VTYPE, VL, VSTART and VCSR, then clear VSTART.
2. Save all 32 vector registers using four `vs8r.v` instructions.
3. Emulate another context by changing VRF and vector CSRs.
4. Reload the 32 registers using four `vl8re8.v` instructions.
5. Restore VTYPE/VL using register-form `vsetvl`, then VCSR, then VSTART last.

Saving VSTART before changing it and restoring it after configuration are
essential: the whole-register operations themselves honor restart state, and
configuration clears VSTART. Whole-register transfers do not depend on the
saved VL or supported VTYPE. The test includes zero VL, vill, nonzero restart
positions, tail/mask policies and different VXRM/VXSAT values. The interruption
simulation uses host writes to create the other context; all save and restore
transfers use instructions and the memory interface, never host-port restore.

Four cases first generate a load access/page fault at element 2 of a four-byte
load. They compare the completed prefix with an independent byte model, save
and restore the partial state, remove the fault, and resume the original load.
The request scoreboard requires exactly two resumed accesses, at elements 2
and 3, and verifies that successful completion clears VSTART. Full VRF, RAM,
saved CSR values, trap metadata and Spike results are checked.

```sh
make -C verification/vpu top TOP_SUITE=context DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
```

The integrated backend supplies VS/FS gating, scalar FCSR and privileged trap
entry. The whole-core `vector-system-smoke` target also executes the context
sequence through production decode, MMU and memory paths.

## Core-side ownership and metadata adapter

`rapt_vpu_core_adapter` captures immutable metadata such as PC and physical
destination alongside `{generation, ROB slot}`. It grants authorization
while the matching ROB head is valid and `head_safe` holds. The grant is
re-evaluated until accepted. A matching kill wins before acceptance.
Early or wrong-tag responses drain while the current owner remains live.
The adapter and owner proofs check stable operands, tags and metadata
through cancellation or response acceptance.

## Core-facing numerical VPU composition

`rapt_vpu_core` packs architectural command and result fields between the
adapter and `rapt_vpu`. The memory and host interfaces pass through unchanged.
`GenerationBits`, `RobBits` and `MetadataBits` define tag and payload widths.
`busy` includes outstanding idle-host transactions. The backend asserts
`head_safe` after checking the store queue and, for memory commands, completing
the memory drain.

Use `CORE_ADAPTER=1` to test captured metadata, unsafe head gating,
backpressure and numerical behavior through the wrapper. Builds use the
`core-top-...` prefix and record `CoreAdapter` in the source manifest.

```sh
make -C verification/vpu top CORE_ADAPTER=1 TOP_SUITE=context \
  DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
python3 verification/vpu/synth_check.py --leaf top_core --build-dir verification/build/vpu/synth-core-top
```

## Store acceptance, final response and restart boundary

`rapt_lsu_sq.sv` handles `wvalid && wready && werr` after a scalar store retires
and releases the owner. The vector path preserves the instruction's ROB owner
through the final L1D write response. A fault reports the element or segment
restart position before the instruction retires.

`TOP_SUITE=store-completion` exercises this distinction through `rapt_vpu_core`.
The memory model independently accepts each request and delays actual write
responses by 0, 1, 7, 31 or 127 cycles. Throughout unfinished actual writes it
requires a busy owner and no architectural completion. Segment probes keep
their normal timing and all succeed; the selected later actual access fails.
The model's contract remains that a failed request has no effect.

## Verification and integration scope

Focused instruction suites are selected with `TOP_SUITE`: `full`, `catalog`, `catalog-matrix`,
`indexed-geometry`,
`geometry`, `geometry-overlap`, `encoding`, `config-encoding`, `memory-encoding`, `context`,
`store-completion`, `fp-mixed`, `fp-divsqrt`, `fp-misc`, `fp-wide`, `fp-convert`,
`int-fp`, `estimate`, `transfer` and `fp-reduce`. Use `CORE_ADAPTER=1` to exercise
the numerical VPU through the ownership bridge, and `DIFF=1` with the pinned
Spike build for architectural comparisons.

The independent owner and core-adapter proofs check control and ownership.
Memory proofs check response payload isolation and request ownership for
RV32/ELEN=32, RV32/ELEN=64 and RV64/ELEN=64. These
module and compositional checks do not establish full-vector ISA correctness,
external-memory drain, real MMU behavior or whole-system liveness.

```sh
python3 verification/vpu/check_acceptance.py --build-dir "$VPU_RESULTS"
python3 verification/vpu/test_check_acceptance.py --build-dir "$VPU_RESULTS"
```

Set `VPU_RESULTS` to the directory containing the completed artifacts. The
acceptance checker audits their source fingerprints, configuration, completion
markers and reference identity. It writes `acceptance.json`; it does not rerun
simulations or proofs. A result applies only to the source and configuration
recorded in its manifest. For ELEN=64, the catalog requires an accepted example
for every instruction variant except RV32's unsupported 64-bit indexed memory
encodings. The geometry differential separates mixed-EEW source overlaps into
`TOP_SUITE=geometry-overlap` for comparison with Spike.

The expanded catalog matrix covers each listed encoding and segment count across
SEW, all seven LMUL encodings, mask forms, and five VL/vstart boundary scenarios.
It compares vector registers, memory, CSR state, results and traps with Spike.
The matrix remains a finite operand sample, not a complete semantic proof. Run
and audit its shards with:

```sh
make -C verification/vpu catalog-matrix TOP_SUITE=catalog-matrix CORE_ADAPTER=1 \
  DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANKS=2
```

`MATRIX_SHARDS` controls the number of reproducible shards; `MATRIX_SEED` selects
the operand seed, and `MATRIX_POLICY` selects the two VTYPE tail/mask policy bits.
The catalog checker
rejects missing variants, shards and completion records and records source hashes.

The `indexed-geometry` suite independently sweeps every destination and index
register pair, segment count, SEW, LMUL, index width, mask form and indexed
load/store ordering against Spike. It uses VL=0 to isolate legality; it does not
by itself check active-element data transfers. Run it with:

```sh
make -C verification/vpu indexed-geometry TOP_SUITE=indexed-geometry CORE_ADAPTER=1 \
  DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANKS=2
```

`OPT_READS`, `CACHE_PREDICATE`, `SHARE_INT_FP`, `MULDIV_EARLY_OUT` and
`REDUCE_MASK_CACHE` select operand-read reuse, predicate caching, shared
integer/FP conversion, iterative early completion and reduction predicate caching.
Compare identical workloads and parameters when measuring their effect.
Structural synthesis and FPGA primitive mapping describe their measured module
scope; they do not establish routed timing or scalar-core performance.

The main element scheduler also caches one predicate byte per instruction when
`CachePredicate` is enabled. Each byte is tagged by element index, so a nonzero
vstart and a transition to the next byte require no special alignment assumption.
The cache is cleared on every newly accepted engine command. Masked operations
whose destination is v0 bypass it; compression may use it because geometry
checks forbid overlap between its selection register and destination. Reduction
and memory engines retain their own scheduling and are not accelerated by this
cache. `make -C verification/vpu predicate-cache-check` builds both settings,
checks the complete register file against an independent byte model, and compares
the same e8/m4 masked add/merge workload. Use `CORE_ADAPTER=1 DIFF=1` with the
pinned `SPIKE_BUILD` to compare the same commands through the ownership bridge.

Integer/FP conversions share one pair of numeric services per supported FP
precision across the five legal integer/FP width combinations. The shared unit
captures integer width and signedness with the request and holds the result and
flags under backpressure. `SHARE_INT_FP=0` selects the original dedicated pairs
for comparison. `int-fp-share-check` compares identical encoded workloads and
requires equal summed command latency. `int-fp INT_FP_SHARED=1` exercises each
width and precision against SoftFloat; supply `FMA_DOUBLE`, `INT_BITS` and
`SPIKE_BUILD` to that target. `fp-reduce-cache-check` runs the existing reduction
engine workload with both cache settings across four configurations and compares
their results.

For Linux userspace and guest validation, see the
[RVA23U64 userspace probe](./linux_kernel.md#rva23u64-on-linux) and the
[RVA23S64 KVM probe](./linux_kernel.md#rva23s64-on-linux).

## Specification references

- [RISC-V V 1.0 specification](https://docs.riscv.org/reference/isa/v20260120/unpriv/v-st-ext.html)
- [Frozen V 1.0 source, configuration and CSR sections](https://github.com/riscvarchive/riscv-v-spec/blob/v1.0/v-spec.adoc)
- [Spike reference implementation](https://github.com/riscv-software-src/riscv-isa-sim)
