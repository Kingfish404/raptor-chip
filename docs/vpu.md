---
title: Standalone VPU
---

# Standalone Raptor VPU

The VPU is a standalone RVV 1.0 component in `rtl/backend/vpu/`. It implements
integer, fixed-point, permutation, configuration/CSR, vector memory and
FP32/FP64 instruction families. `rapt_vpu_core` composes the numerical VPU with
an ownership and metadata adapter; it is not instantiated in the scalar Raptor
core. Scalar ROB, CSR, LSU/MMU and trap integration are required before enabling
V in the scalar core's ISA advertisement.

The test defaults are XLEN=64, VLEN=128, ELEN=64, BankBits=64 and Banks=2.
XLEN, vector width and storage geometry are independent parameters. Optional
vector extensions such as Zvfh are outside this component's baseline.

## Available modules

| Module | Implemented behavior | Verification |
| --- | --- | --- |
| `rtl/backend/vpu/rapt_vpu_vtype.sv` | Stateless VTYPE legality, VLMAX, deterministic `min(AVL,VLMAX)`, maximum and keep-VL modes | Exhaustive low-byte type pairs, unsupported upper bits, AVL boundaries |
| `rtl/backend/vpu/rapt_vpu_vrf.sv` | 32 architectural registers, configurable 1RW SRAM banks, byte writes, independently backpressured read responses | Byte-level reference memory, random requests/stalls, full final sweep, reset with pending reads |
| `rtl/backend/vpu/rapt_vpu_csr.sv` | Seven vector CSRs, configuration updates, restart/FOF/completion updates, VS gating and dirty events | CSR address sweep, permissions, aliases, WARL, faults, FOF and sticky saturation |
| `rtl/backend/vpu/rapt_vpu_owner.sv` | Capture, tag-matched authorization, cancellation before authorization, irrevocable issue, completion holding and stale-result drain | Tag reuse, cancellation races, issue/response stalls, zero-cycle and duplicate results; inductive public-interface proof with reachability and mutation checks |
| `rtl/backend/vpu/rapt_vpu_element.sv` | Natural-aligned 8/16/32/64-bit element accesses across VRF banks | Integrated full-array byte comparisons, all supported SEWs and multiple bank shapes |
| `rtl/backend/vpu/rapt_vpu_decode.sv` | Raw encoding admission for the implemented subset | Real instruction tests and illegal encoding tests, including Spike comparison |
| `rtl/backend/vpu/rapt_vpu_memory.sv` | Sequential unit/strided/indexed/segment/whole/mask/FOF accesses with precise restart metadata | Independent byte model, Spike, transaction scoreboard, injected access/page faults, backpressure and ownership mismatch tests |
| `rtl/backend/vpu/rapt_vpu_muldiv.sv` | Independent ready/valid SEW=8/16/32/64 iterative multiply/divide element engine, optional early completion | Exhaustive e8, wider edge/random cases, reset/backpressure, baseline/optimized comparison; integrated Spike including destructive multiply-add |
| `rtl/backend/vpu/rapt_vpu_mask_write.sv` | Exclusive byte read-modify-write for one mask result bit | All 4,096 byte/bit/value combinations, request stalls, response delays, completion backpressure and reset boundaries; integrated mask results against Spike |
| `rtl/backend/vpu/rapt_vpu_geometry.sv` | Stateless per-operand EEW/EMUL, alignment, extent and legal overlap checks for arithmetic | Integrated raw-encoding tests against Spike including mixed widths, fractional groups, mask results and illegal geometry; ELEN32/64 synthesis |
| `rtl/backend/vpu/rapt_vpu_fixed.sv` | Stateless fixed-point rounding/saturation, consuming the full signed product for vsmul | Independent numerical quotient/remainder rounding, exhaustive small inputs, wider edge/random cases; integrated VXRM/VXSAT and Spike checks |
| `rtl/backend/vpu/rapt_vpu_mask_scan.sv` | Independent byte-based vcpop/vfirst scan, predicate reuse for v0 and first-bit early completion | Exhaustive source/predicate byte and partial-byte lengths, multi-byte scans, exact request counts, backpressure and top-level Spike |
| `rtl/backend/vpu/rapt_vpu_move.sv` | Independent whole-register move sequencer with command capture, aligned groups, SEW-based restart and no-op elision | Standalone byte model with backpressure and delayed acknowledgements; integrated encoded-instruction comparison |
| `rtl/backend/vpu/rapt_vpu_reduce.sv` | Independent sequential integer sum/logical/min/max and widening-sum reduction engine; scalar seed/destination, delayed destination write | Integrated independent numeric model and Spike: masks, zero VL, arbitrary destination overlap, fractional/integer LMUL and illegal vstart/geometry |
| `rtl/backend/vpu/rapt_vpu_alu.sv` | Single-element arithmetic, logical, shift, min/max, merge, compare and carry/borrow | Independent wide-integer reference and Spike through the top |
| `rtl/backend/vpu/rapt_vpu_slide.sv` | Stateless slide/slide1 element routing, full-XLEN offsets, scalar insertion and out-of-range zero selection; integrated integer slide/slide1 scheduling | Independent signed-128-bit coordinate model, RV32/RV64 and VLEN128/512; encoded top tests and leaf synthesis |
| `rtl/backend/vpu/rapt_vpu_divsqrt.sv` | Independent runtime-precision FP32/FP64 divide/sqrt wrapper with held result/flags; integrated with top | SoftFloat result/flags comparison, precision/op capture, reset-age sweep and strict lint |
| `rtl/backend/vpu/rapt_vpu_fp_decode.sv` | FP arithmetic, widening, format conversion, divide/sqrt and miscellaneous admission/operand mapping; integrated with top | Opcode/form sweep, FRM/SEW/enable/VILL matrix and operand-bit/NaN-boxing tests |
| `rtl/backend/vpu/rapt_vpu_fp_arith.sv` | Raw FP32/FP64 add/subtract/multiply/FMA through one shared fused datapath; integrated with top | Independent SoftFloat operation references, all rounding modes, result/flags and protocol checks |
| `rtl/backend/vpu/rapt_vpu_fma.sv` | Independent FP32/FP64 fused element wrapper with backpressured result/flags and raw vector inputs; integrated with top | SoftFloat result/flags tests, request capture, stalled responses, invalid rounding and reset boundaries |
| `rtl/backend/vpu/rapt_vpu_int_fp_decode.sv` | Eighteen unary integer/FP conversion selectors, operand EEWs, signedness and resolved RTZ/FRM; integrated with top | Exhaustive encoding/SEW/FRM/enable sweeps for ELEN32/64 and encoded top differential tests |
| `rtl/backend/vpu/rapt_vpu_int_fp.sv` | Bidirectional integer16/32/64 and FP32/64 element conversion; five legal ISA width pairs integrated with top | Independent SoftFloat leaves plus encoded top results, flags, masking, restart and finite clipping |
| `rtl/backend/vpu/rapt_vpu_fp_estimate.sv` | Combinational raw FP32/FP64 reciprocal and reciprocal-square-root seven-bit estimates; integrated with top | Spike SoftFloat estimates, all exponent/table interval endpoints, normalized subnormal boundaries, signed special values and normative examples |
| `rtl/backend/vpu/rapt_vpu_fp_transfer.sv` | Stateless admission/routing for FP merge, broadcast, scalar extraction/insertion and slide1; integrated with top | Independent encoding masks, scalar boxing/raw payloads, VL/vstart/mask boundaries and parameter sweeps |
| `rtl/backend/vpu/rapt_vpu_fp_reduce.sv` | Independent numerical sum/min/max and FP32-to-FP64 widening-sum wrapper; the integrated top shares its stream control and existing arithmetic services | SoftFloat sequences, masked seed preservation, count boundaries, metadata capture, source/response stalls and reset-age sweeps |
| `rtl/backend/vpu/rapt_vpu_core_adapter.sv` | Core-side ROB head authorization and immutable retirement metadata | Owner composition tests, inductive control proof, reachable witnesses and mutation detection |
| `rtl/backend/vpu/rapt_vpu_core.sv` | Actual numerical VPU composed with core-side metadata bridge; explicit command/result packing | RV32/RV64 full Spike suites, FP64-on-RV32 and context tests, structural synthesis |
| `rtl/backend/vpu/rapt_vpu.sv` | Composition, sequential element scheduling, mask/vstart/group legality, idle host register port | Standalone encoded programs, authorization races, full VRF comparison and reference differential tests |

These modules do not import `rapt_pkg` or scalar preset macros. VLEN, ELEN,
bank geometry, XLEN and eventual owner-tag widths must remain independent.

## Relocatable RTL source export

`python3 verification/vpu/export_rtl.py /tmp/my-vpu-rtl` creates a new directory
containing the required source/license files, a relative-path `sources.f`, a short
integration README and a SHA-256 manifest. Existing destinations are refused.
The export includes both `rapt_vpu` and `rapt_vpu_core`, shared scalar numerical
primitives, the behavioral `rapt_sram_1rw`, and required headers. It does not
depend on scalar presets, `rapt_pkg`, generated scalar decode or `sim/.config`.
Technology-specific SRAM macro libraries are not included.

From the exported directory:

```sh
verilator --lint-only --assert -Wall -DRAPT_ASSERT_EN \
  verification/vpu/fma_legacy.vlt -f sources.f --top-module rapt_vpu_core
```

`python3 verification/vpu/test_export_rtl.py` relocates a fresh export outside the
repository into a directory containing a space, then checks both tops in the
four acceptance configurations: RV32/128/32/64/1, RV64/128/64/64/2,
RV32/256/64/64/4 and RV64/512/64/128/4 (XLEN/VLEN/ELEN/BankBits/Banks).
The eight lint/elaboration checks retain the existing narrow FMA waivers;
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
make -C verification/vpu synth
make -C verification/vpu opt-check
make -C verification/vpu muldiv-opt-check
make -C verification/vpu mask-write
make -C verification/vpu fixed
make -C verification/vpu move
make -C verification/vpu move VLEN=512
make -C verification/vpu mask-scan
make -C verification/vpu slide
make -C verification/vpu slide XLEN=32 VLEN=512
make -C verification/vpu owner-formal
make -C verification/vpu mask-scan XLEN=32 VLEN=512
make -C verification/vpu csr XLEN=32 VLEN=256 ELEN=64
make -C verification/vpu vrf VLEN=512 BANK_BITS=128 BANKS=4
```

The Makefile requires Verilator and a host C++ toolchain. It does not load the
root or simulation Makefile, rewrite `sim/.config`, generate scalar decode, or
install dependencies. Build and run logs are under `verification/build/vpu/`, separated
by module and configuration. Assertions are enabled; warnings remain fatal,
apart from narrowly annotated unused architectural bits and the scoped shared scalar FMA waivers. Pipeline failures are
propagated through `tee`. The VRF random test uses seed `0x6a09e667`.

`test` runs the default leaves, core adapter, owner, multiply/divide, mask-write,
fixed-point, whole-register move, mask-scan, slide, FP-decode, integer/FP-decode,
FP-reduction control/decode/engine and top tests. `matrix` checks the
configuration/CSR/VRF leaves; `top-matrix` additionally checks two tag widths and
four integrated top configurations. The integrated element adapter requires
BankBits >= 64; the storage-only VRF also supports narrower banks.

The synthesis target additionally requires Yosys with its slang plugin. It checks
the leaves, owner and top in several parameter configurations, rejects latches and
unexpected blackboxes/assertion cells, and checks VRF capacity, one write port
per bank and registered read ports. Source SHA256
fingerprints and cell/memory summaries are in
`verification/build/vpu/synth/summary.json`.

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
including in agnostic modes. Reserved encodings, unsupported
parameter/width combinations, and optional extensions outside this baseline
raise illegal instruction.

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
legal SEW/LMUL, narrowing overlap, equal source identities with different EEWs,
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
as equal source-register numbers. A `.wv` operation can name the same register
with different widths, so register identity alone is insufficient. When an equal
width read is reused for mixed-sign operations, each operand still receives its
own sign/zero extension.

`test_wide_top.h` checks widening add/subtract, wide-source forms, widening
multiply/MAC, narrowing logical/arithmetic shifts and all six integer-extension
forms against an independent 128-bit snapshot model and Spike. It covers supported
SEW/LMUL combinations, unsigned/signed extrema, random data, policy bits, scalar
and immediate inputs, zero VL, restart boundaries, legal high/low overlaps,
same-register sources with equal/different EEWs, and reserved/invalid encodings.
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
- FOF faults at every field of those segments, masked element zero, PMA segment
  rejection, reserved encodings, group bounds and indexed-overlap restrictions.

This is not exhaustive memory verification. Probe failure after a successful
probe prefix, all legal group/overlap combinations, real cross-page translation,
physical non-idempotent devices and late errors from the Raptor SQ remain open
integration/coverage work. The adapter's synthetic PMA policy rejects non-idempotent
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

`TOP_SUITE=context` tests the state-transfer sequence needed by a future core
or OS adapter, through encoded instructions and public interfaces:

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

This tests the standalone architectural sequence. The scalar adapter still
must own VS/FS gating, scalar FCSR, privileged trap entry and context scheduling;
this test does not run an OS or change the scalar core's ISA advertisement.

## Core-side ownership and metadata adapter

`rapt_vpu_core_adapter.sv` is an independently testable control bridge for a
future Raptor composition. A command handshake forwards the complete command
payload to the VPU and captures immutable core metadata (for example PC and
physical destination) alongside `{generation, ROB slot}`. It accepts only one
command at a time. The core resolves scalar/FPR/CSR dependencies before
acceptance and supplies the architectural snapshots in the command payload.

Authorization requires `head_valid`, matching slot and generation, and
`head_safe`. The latter is a core-owned guarantee that the instruction can
execute irrevocably, including required older-memory ordering. Authorization
is a conditional grant re-evaluated until the VPU accepts it; matching kill
wins before that handshake. Afterwards kill is blocked and the metadata remains
owned until the matching response is accepted by the core.

The adapter preserves the entire result payload without interpreting it. The
core composition must pack every result field (including trap, dirty, FP flags
and FPR results), map those fields into the actual completion types, and retain
the ROB owner throughout execution. The result producer must hold valid/tag/
payload during response backpressure. Early or wrong-tag responses are drained
without releasing the live metadata; matching results become eligible in cycles
after authorization, as provided by `rapt_vpu_owner`. Reset and external drain
must be coordinated with the VPU. Identity width alone cannot protect against
late responses after exact full-tag reuse.

## Core-facing numerical VPU composition

`rapt_vpu_core.sv` instantiates the ownership/metadata bridge and actual
`rapt_vpu`. Its command and result connections explicitly pack every current
field: instruction, scalar and FPR operands, FRM/FS availability, scalar/FPR
results, trap metadata, dirty events and FP flags. The memory and idle host
interfaces pass through unchanged. `cmd_metadata`/`rsp_metadata` preserve a
core-defined immutable packet; `MetadataBits` must fit the caller's chosen PC,
physical destination and other required retirement fields.

Tags pack generation above ROB slot, parameterized by `GenerationBits` and
`RobBits`. `authorize_valid`/`authorize_tag` identify the available ROB head,
and `head_safe` supplies the core's irrevocable-execution guarantee.
`authorize_ready` reports that the conditional authorization can be accepted.
`busy` retains the numerical VPU's public meaning, including an outstanding
host-port transaction; the bridge's internal instruction occupancy is separate.
Cancellation/blocking consistency and unexpected completion drops are asserted.

Select this composition with `CORE_ADAPTER=1` in the existing top test target;
`CORE_ADAPTER=0` selects the standalone VPU. Build directories use
`core-top-...` versus `top-...`, and the source manifest records `CoreAdapter`.
The common instruction driver supplies nonuniform metadata, changes it after
command acceptance, checks an unsafe matching ROB head is not authorized, and
checks captured metadata throughout completion backpressure. Existing numerical,
CSR, memory, cancellation and Spike comparisons run through the wrapper.

```sh
make -C verification/vpu top CORE_ADAPTER=1 DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
make -C verification/vpu top CORE_ADAPTER=1 TOP_SUITE=context DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
python3 verification/vpu/synth_check.py --leaf top_core --build-dir verification/build/vpu/synth-core-top
```

The wrapper supplies a concrete core-facing numerical module; it does not
connect the real Raptor ROB, CSR, MMU or SQ. In particular, `head_safe` is an
input contract, not a proof of older-store drain or memory ordering.

## Store acceptance, final response and restart boundary

The actual scalar SQ is not yet a valid drop-in final-response adapter:
`rapt_lsu_sq.sv` handles `wvalid && wready && werr` after the scalar store has
retired, releases that owner and stops remaining split/zero beats. Its source
explicitly separates the imprecise platform error from architectural load traps.
The VPU instead retains the trapping instruction and needs a precise element
or segment restart position. A future integration must preserve that owner
through the actual write response; an SQ allocation or translation/probe
acknowledgement cannot stand in for it.

`TOP_SUITE=store-completion` exercises this distinction through `rapt_vpu_core`.
The memory model independently accepts each request and delays actual write
responses by 0, 1, 7, 31 or 127 cycles. Throughout unfinished actual writes it
requires a busy owner and no architectural completion. Segment probes keep
their normal timing and all succeed; the selected later actual access fails.
The model's contract remains that a failed request has no effect.

## Verification and integration scope

Focused instruction suites are selected with `TOP_SUITE`: `full`, `catalog`,
`geometry`, `encoding`, `config-encoding`, `memory-encoding`, `context`,
`store-completion`, `fp-mixed`, `fp-divsqrt`, `fp-misc`, `fp-wide`, `fp-convert`,
`int-fp`, `estimate`, `transfer` and `fp-reduce`. Use `CORE_ADAPTER=1` to exercise
the numerical VPU through the ownership bridge, and `DIFF=1` with the pinned
Spike build for architectural comparisons.

The independent owner and core-adapter proofs check control and ownership.
Memory proofs check response payload isolation and request ownership. These
module and compositional checks do not establish full-vector ISA correctness,
external-memory drain, real MMU behavior or whole-system liveness.

```sh
python3 verification/vpu/check_acceptance.py
python3 verification/vpu/test_check_acceptance.py
```

The acceptance checker audits completed artifacts in `verification/build/vpu/`,
including source fingerprints, configuration, completion markers and reference
identity. It writes `acceptance.json`; it does not rerun simulations or proofs.
A result applies only to the source and configuration recorded in its manifest.

`OPT_READS`, `MULDIV_EARLY_OUT` and `REDUCE_MASK_CACHE` select operand-read reuse,
iterative arithmetic early completion and reduction predicate-byte caching.
Compare identical workloads and parameters when measuring their effect.
Structural synthesis and FPGA primitive mapping describe their measured module
scope; they do not establish routed timing or scalar-core performance.

Scalar integration must resolve dependencies before accepting a command,
authorize irreversible effects at the correct ROB owner, retain precise trap
and restart state, map scalar/FPR results and flags into retirement, and drain
accepted memory requests before owner identity reuse. The scalar SQ's
post-retirement error path does not satisfy the VPU's precise final-response
contract by itself.

## Specification references

- [RISC-V V 1.0 specification, ISA library v20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/v-st-ext.html)
- [Frozen V 1.0 source, configuration and CSR sections](https://github.com/riscvarchive/riscv-v-spec/blob/v1.0/v-spec.adoc)
- [Spike reference implementation](https://github.com/riscv-software-src/riscv-isa-sim)

Reference tool availability is not a claim that differential tests have run.
