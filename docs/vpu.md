# Standalone Raptor VPU

Status: standalone implementation and selected verification complete, 2026-09-06.
The component implements the baseline RVV 1.0 instruction families, including
integer/fixed-point/permutation, vector configuration/CSRs, memory and FP32/FP64.
Verification covers the 375-entry catalog (627 expanded variants), differential
regressions and a parameter matrix. This is a standalone component delivery;
full ISA certification, whole-VPU formal proof and scalar-core integration are
not claimed. The scalar core's ISA advertisement is unchanged.

The objective is a modular, independently testable VPU suitable for later
integration with Raptor Chip, with functional verification and measured
optimization. The architectural target is RVV 1.0 (including integer, memory,
FP32/FP64 and precise traps); intermediate instruction subsets do not constitute
completion. Optional vector extensions such as Zvfh are outside the baseline.
Initial implementation parameters are XLEN=64, VLEN=128, ELEN=64, with RV32 and
larger VLEN configurations checked as modules become available.

## Available modules

| Module | Implemented behavior | Verification |
| --- | --- | --- |
| `hdl/backend/vpu/rapt_vpu_vtype.sv` | Stateless VTYPE legality, VLMAX, deterministic `min(AVL,VLMAX)`, maximum and keep-VL modes | Exhaustive low-byte type pairs, unsupported upper bits, AVL boundaries |
| `hdl/backend/vpu/rapt_vpu_vrf.sv` | 32 architectural registers, configurable 1RW SRAM banks, byte writes, independently backpressured read responses | Byte-level reference memory, random requests/stalls, full final sweep, reset with pending reads |
| `hdl/backend/vpu/rapt_vpu_csr.sv` | Seven vector CSRs, configuration updates, restart/FOF/completion updates, VS gating and dirty events | CSR address sweep, permissions, aliases, WARL, faults, FOF and sticky saturation |
| `hdl/backend/vpu/rapt_vpu_owner.sv` | Capture, tag-matched authorization, cancellation before authorization, irrevocable issue, completion holding and stale-result drain | Tag reuse, cancellation races, issue/response stalls, zero-cycle and duplicate results; inductive public-interface proof with reachability and mutation checks |
| `hdl/backend/vpu/rapt_vpu_element.sv` | Natural-aligned 8/16/32/64-bit element accesses across VRF banks | Integrated full-array byte comparisons, all supported SEWs and multiple bank shapes |
| `hdl/backend/vpu/rapt_vpu_decode.sv` | Raw encoding admission for the implemented subset | Real instruction tests and illegal encoding tests, including Spike comparison |
| `hdl/backend/vpu/rapt_vpu_memory.sv` | Sequential unit/strided/indexed/segment/whole/mask/FOF accesses with precise restart metadata | Independent byte model, Spike, transaction scoreboard, injected access/page faults, backpressure and ownership mismatch tests |
| `hdl/backend/vpu/rapt_vpu_muldiv.sv` | Independent ready/valid SEW=8/16/32/64 iterative multiply/divide element engine, optional early completion | Exhaustive e8, wider edge/random cases, reset/backpressure, baseline/optimized comparison; integrated Spike including destructive multiply-add |
| `hdl/backend/vpu/rapt_vpu_mask_write.sv` | Exclusive byte read-modify-write for one mask result bit | All 4,096 byte/bit/value combinations, request stalls, response delays, completion backpressure and reset boundaries; integrated mask results against Spike |
| `hdl/backend/vpu/rapt_vpu_geometry.sv` | Stateless per-operand EEW/EMUL, alignment, extent and legal overlap checks for arithmetic | Integrated raw-encoding tests against Spike including mixed widths, fractional groups, mask results and illegal geometry; ELEN32/64 synthesis |
| `hdl/backend/vpu/rapt_vpu_fixed.sv` | Stateless fixed-point rounding/saturation, consuming the full signed product for vsmul | Independent numerical quotient/remainder rounding, exhaustive small inputs, wider edge/random cases; integrated VXRM/VXSAT and Spike checks |
| `hdl/backend/vpu/rapt_vpu_mask_scan.sv` | Independent byte-based vcpop/vfirst scan, predicate reuse for v0 and first-bit early completion | Exhaustive source/predicate byte and partial-byte lengths, multi-byte scans, exact request counts, backpressure and top-level Spike |
| `hdl/backend/vpu/rapt_vpu_move.sv` | Independent whole-register move sequencer with command capture, aligned groups, SEW-based restart and no-op elision | Standalone byte model with backpressure and delayed acknowledgements; integrated encoded-instruction comparison |
| `hdl/backend/vpu/rapt_vpu_reduce.sv` | Independent sequential integer sum/logical/min/max and widening-sum reduction engine; scalar seed/destination, delayed destination write | Integrated independent numeric model and Spike: masks, zero VL, arbitrary destination overlap, fractional/integer LMUL and illegal vstart/geometry |
| `hdl/backend/vpu/rapt_vpu_alu.sv` | Single-element arithmetic, logical, shift, min/max, merge, compare and carry/borrow | Independent wide-integer reference and Spike through the top |
| `hdl/backend/vpu/rapt_vpu_slide.sv` | Stateless slide/slide1 element routing, full-XLEN offsets, scalar insertion and out-of-range zero selection; integrated integer slide/slide1 scheduling | Independent signed-128-bit coordinate model, RV32/RV64 and VLEN128/512; encoded top tests and leaf synthesis |
| `hdl/backend/vpu/rapt_vpu_divsqrt.sv` | Independent runtime-precision FP32/FP64 divide/sqrt wrapper with held result/flags; integrated with top | SoftFloat result/flags comparison, precision/op capture, reset-age sweep and strict lint |
| `hdl/backend/vpu/rapt_vpu_fp_decode.sv` | FP arithmetic, widening, format conversion, divide/sqrt and miscellaneous admission/operand mapping; integrated with top | Opcode/form sweep, FRM/SEW/enable/VILL matrix and operand-bit/NaN-boxing tests |
| `hdl/backend/vpu/rapt_vpu_fp_arith.sv` | Raw FP32/FP64 add/subtract/multiply/FMA through one shared fused datapath; integrated with top | Independent SoftFloat operation references, all rounding modes, result/flags and protocol checks |
| `hdl/backend/vpu/rapt_vpu_fma.sv` | Independent FP32/FP64 fused element wrapper with backpressured result/flags and raw vector inputs; integrated with top | SoftFloat result/flags tests, request capture, stalled responses, invalid rounding and reset boundaries |
| `hdl/backend/vpu/rapt_vpu_int_fp_decode.sv` | Eighteen unary integer/FP conversion selectors, operand EEWs, signedness and resolved RTZ/FRM; integrated with top | Exhaustive encoding/SEW/FRM/enable sweeps for ELEN32/64 and encoded top differential tests |
| `hdl/backend/vpu/rapt_vpu_int_fp.sv` | Bidirectional integer16/32/64 and FP32/64 element conversion; five legal ISA width pairs integrated with top | Independent SoftFloat leaves plus encoded top results, flags, masking, restart and finite clipping |
| `hdl/backend/vpu/rapt_vpu_fp_estimate.sv` | Combinational raw FP32/FP64 reciprocal and reciprocal-square-root seven-bit estimates; integrated with top | Spike SoftFloat estimates, all exponent/table interval endpoints, normalized subnormal boundaries, signed special values and normative examples |
| `hdl/backend/vpu/rapt_vpu_fp_transfer.sv` | Stateless admission/routing for FP merge, broadcast, scalar extraction/insertion and slide1; integrated with top | Independent encoding masks, scalar boxing/raw payloads, VL/vstart/mask boundaries and parameter sweeps |
| `hdl/backend/vpu/rapt_vpu_fp_reduce.sv` | Independent numerical sum/min/max and FP32-to-FP64 widening-sum wrapper; the integrated top shares its stream control and existing arithmetic services | SoftFloat sequences, masked seed preservation, count boundaries, metadata capture, source/response stalls and reset-age sweeps |
| `hdl/backend/vpu/rapt_vpu_core_adapter.sv` | Core-side ROB head authorization and immutable retirement metadata | Owner composition tests, inductive control proof, reachable witnesses and mutation detection |
| `hdl/backend/vpu/rapt_vpu_core.sv` | Actual numerical VPU composed with core-side metadata bridge; explicit command/result packing | RV32/RV64 full Spike suites, FP64-on-RV32 and context tests, structural synthesis |
| `hdl/backend/vpu/rapt_vpu.sv` | Composition, sequential element scheduling, mask/vstart/group legality, idle host register port | Standalone encoded programs, authorization races, full VRF comparison and reference differential tests |

These modules do not import `rapt_pkg` or scalar preset macros. VLEN, ELEN,
bank geometry, XLEN and eventual owner-tag widths must remain independent.

## Relocatable RTL source export

`python3 verify/vpu/export_rtl.py /tmp/my-vpu-rtl` creates a new directory
containing 45 source/license files, a relative-path `sources.f`, a short
integration README and a SHA-256 manifest. Existing destinations are refused.
The export includes both `rapt_vpu` and `rapt_vpu_core`, shared scalar numerical
primitives, the behavioral `rapt_sram_1rw`, and required headers. It does not
depend on scalar presets, `rapt_pkg`, generated scalar decode or `sim/.config`.
Technology-specific SRAM macro libraries are not included.

From the exported directory:

```sh
verilator --lint-only --assert -Wall -DRAPT_ASSERT_EN \
  verify/vpu/fma_legacy.vlt -f sources.f --top-module rapt_vpu_core
```

`python3 verify/vpu/test_export_rtl.py` relocates a fresh export outside the
repository into a directory containing a space, then checks both tops in the
four acceptance configurations: RV32/128/32/64/1, RV64/128/64/64/2,
RV32/256/64/64/4 and RV64/512/64/128/4 (XLEN/VLEN/ELEN/BankBits/Banks).
The eight lint/elaboration checks retain the existing narrow FMA waivers;
they are not functional simulations or physical implementation checks.
The test also requires a missing shared header to fail and an existing export
destination to remain untouched. Logs and source-current evidence are recorded
under `verify/build/vpu/export-rtl/`.

## Independent tests

From the repository root:

```sh
make -C verify/vpu test
make -C verify/vpu matrix
make -C verify/vpu top-matrix
make -C verify/vpu synth
make -C verify/vpu opt-check
make -C verify/vpu muldiv-opt-check
make -C verify/vpu mask-write
make -C verify/vpu fixed
make -C verify/vpu move
make -C verify/vpu move VLEN=512
make -C verify/vpu mask-scan
make -C verify/vpu slide
make -C verify/vpu slide XLEN=32 VLEN=512
make -C verify/vpu owner-formal
make -C verify/vpu mask-scan XLEN=32 VLEN=512
make -C verify/vpu csr XLEN=32 VLEN=256 ELEN=64
make -C verify/vpu vrf VLEN=512 BANK_BITS=128 BANKS=4
```

The Makefile requires Verilator and a host C++ toolchain. It does not load the
root or simulation Makefile, rewrite `sim/.config`, generate scalar decode, or
install dependencies. Build and run logs are under `verify/build/vpu/`, separated
by module and configuration. Assertions are enabled; warnings remain fatal,
apart from narrowly annotated unused architectural bits and the shared scalar FMA waivers described below. Pipeline failures are
propagated through `tee`. The VRF random test uses seed `0x6a09e667`.

`test` runs the default leaves, owner, independent multiply/divide, mask-write, fixed-point, whole-register move, mask-scan, slide, FP-decode and integer/FP-decode tests, and top. `matrix` checks the original
configuration/CSR/VRF leaves; `top-matrix` additionally checks two tag widths and
four integrated top configurations. The integrated element adapter requires
BankBits >= 64; the storage-only VRF also supports narrower banks.

The synthesis target additionally requires Yosys with its slang plugin. It checks
the leaves, owner and top in several parameter configurations, rejects latches and
unexpected blackboxes/assertion cells, and checks VRF capacity, one write port
per bank and registered read ports after byte-port consolidation. Source SHA256
fingerprints and cell/memory summaries are in
`verify/build/vpu/synth/summary.json`.

The following records describe the earlier integer-only snapshot on 2026-09-05
(Verilator 5.050, Yosys 0.64). They are retained as historical context; current
memory-enabled results are recorded below and in source-fingerprinted build logs:

- `matrix`: 13 simulation combinations passed (five VTYPE, four VRF, four CSR).
- VTYPE cases: RV64/128/64, RV32/256/64, RV32/128/32, RV64/512/64,
  RV32/65536/64, expressed as XLEN/VLEN/ELEN.
- VRF cases: 128/64/2, 256/32/4, 128/64/1, 512/128/4, expressed as
  VLEN/BankBits/Banks. Each ran 12,000 randomized cycles plus initialization,
  drain, full-array sweep and reset checks.
- The original leaf synthesis checks passed 12 combinations. Default VRF retained two 32x64-bit memories,
  exactly 4096 data bits, with synchronous reads and byte-enabled writes.
- Expanded synthesis covers 22 distinct combinations, including baseline and
  optimized top configurations. Both top variants retain the expected SRAM
  capacity and synchronous read ports.
- Owner tests with TagBits=1 and 10 each complete 702 commands, cancel 322, and
  drain 5,441 invalid/duplicate responses. Small tags intentionally wrap often;
  responses after reuse of the exact same full tag remain excluded by the drain
  contract, not magically distinguished by these tests.
- Integrated tests cover XLEN/VLEN/ELEN = 64/128/64, 32/256/64, 32/128/32 and
  64/512/64. Integer source operands are nonuniform; destination overlap with
  either source and equal source-register groups are included. VRF is compared
  in full after each arithmetic command and after negative tests.
- These four optimized top configurations passed 23,508 executed Spike command
  comparisons in total (6,381 / 6,381 / 4,365 / 6,381). Cancelled commands are
  checked for absence of effects and are not executed by the reference. Each
  ELEN=64 configuration executes 1,584 arithmetic commands; ELEN=32 executes
  1,080. The remaining comparisons exercise configuration and CSR/control paths.

These results do not establish a formal proof, full-V conformance, FPGA
validation, technology mapping, or physical STA.

### Fixed-point integer/memory snapshot (before reductions)

On 2026-09-05, the pre-reduction source-fingerprinted workload passed:

| XLEN / VLEN / ELEN / BankBits / Banks | Fixed-point commands | Executed Spike commands | Workload hash |
| --- | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 15,888 | 227,102 | `9be45378198db94f` |
| 32 / 256 / 64 / 64 / 4 | 15,888 | 226,498 | `6a2a84885d0a98ee` |
| 32 / 128 / 32 / 64 / 1 | 10,656 | 150,426 | `2e5d4f06c13eb838` |
| 64 / 512 / 64 / 128 / 4 | 15,888 | 227,102 | `533a77cf18900cd2` |

This totals 831,128 executed command comparisons across four optimized top
configurations, including 58,320 fixed-point commands, 16,672 successful
mixed-width commands and 783 mixed-width illegal-encoding/type/overlap cases. The memory checkpoint counter
in run logs includes successful transfers and selected negative/FOF checks,
not a count of all distinct specification requirements.
In the default run the bus model accepted 22,402 requests, observed 12,229
successful actual accesses and 10,076 probe responses, injected 18,666 wrong-tuple
responses, and exercised 3,736 zero-cycle responses. Failed actual accesses explain
the difference between request and successful-effect/probe counts.

`make -C verify/vpu test` also passes without Spike, including the default VTYPE,
CSR, VRF and owner tests. `top-matrix DIFF=1` passes both additional owner tag-width
tests and the four top configurations. `synth` passes 30 distinct configurations
including fixed-point, both multiply/divide modes, ELEN32/64 geometry, three mask-writer
address widths and the
current integer/memory top. `opt-check DIFF=1` passes on the same current
sources; its measured improvement remains specific to the arithmetic workload.

The tests use no scalar preset. These results do not establish full V conformance,
real LSU/MMU integration, formal safety proofs, physical timing or FPGA operation.

### Independent Spike differential tests

```sh
make -C verify/vpu top-matrix DIFF=1 SPIKE_BUILD=/path/to/spike-source-build
make -C verify/vpu opt-check DIFF=1 SPIKE_BUILD=/path/to/spike-source-build
```

The optional adapter requires a separately built Spike source/build tree with
its static libraries and development headers, plus the libraries named in the
Makefile. `reference_manifest.py` enforces source revision
`770ce31f7543f57472b35e66600085ea81184bb2`, checks the relevant tracked source
directories for modifications, and records static-library/configuration hashes.
It does not rebuild or modify the reference tree. The tested local build reports
Spike 1.1.1-dev; the commit and library hashes identify it more precisely.

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

The additional handwritten integer model snapshots source registers before
updating destinations and remains enabled alongside Spike. The current pinned
reference preserves the inactive/tail elements exercised here, matching the
DUT's permitted undisturbed policy. The pinned reference also preserves the mask-result bits exercised here. Other
allowed reference policies, floating reductions and architecturally variable
results require explicit allowed-result comparison rules; full-byte equality is
not assumed to apply to every future instruction/reference configuration.

Build/run logs, current source SHA256 fingerprints (`sources.json`), and
reference fingerprints (`reference.json`) reside in each configuration's build
directory. Differential tests use a separate `-spike` build suffix.

### Measured operand-read optimization

`OptimizeOperandReads=1` (Makefile `OPT_READS=1`) avoids a second read when both
vector operands are the same register group. For merge it reads only the source
selected by the mask. It does not cache speculative data or change VRF layout.
`OPT_READS=0` retains the sequential baseline.

With RV64, VLEN=128, ELEN=64, BankBits=64 and Banks=2, the 1,584-instruction
arithmetic workload reduced summed command latency from 66,682 to 65,450 cycles
(1.848%). The metric runs from command acceptance to completion availability and
includes fixed test authorization delays; it excludes host VRF inspection and
is not application IPC. Both variants passed the handwritten and Spike checks.
The comparison script requires identical source fingerprints, hardware settings
apart from this switch, reference fingerprints and command/data workload hashes.
The result is recorded in `verify/build/vpu/optimization-64-128-64-64-2-spike.json`.

Word-level synthesis exposes the extra control/mux logic used by the optimization;
in the current integer/mask/carry/memory default configuration the count increases from
1,857 to 1,870 word-level
cells while preserving two 32x64-bit memories. These counts are not standard-cell
area. No Fmax, power or physical area
improvement is claimed.

## Module contracts

### Top and instruction lifecycle

`cmd_valid && cmd_ready` captures the instruction and scalar operands, including
`cmd_frs1` (64-bit FPR value), `cmd_frm` (resolved FRM), and `cmd_fp_enabled`
(FS availability). These new fields may be tied to zero when floating point is
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
VPU's architectural CSR module. The initial engine is non-speculative and accepts
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

Supported integer instructions honor the legal SEW/LMUL combinations, register
group alignment, masking and VSTART. Tail and inactive elements are preserved,
including in agnostic modes. Other vector families currently raise illegal
instruction; their implementation remains part of the target below.

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
averages and scaling shifts do not set saturation. The stage contains no new
combinational multiplier: vsmul requests a signed multiply from the existing
iterative engine, captures its full 128-bit product, and rounds at SEW-1 before
clamping to the signed destination range.

The multiply/divide leaf now exposes `full_product` alongside `result`. The full
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
`make -C verify/vpu fixed` passes 5,662,496 checks: exhaustive 8-bit input pairs for
the non-clip operations across all four modes, exhaustive 16-bit clip inputs with
five boundary shift amounts across all modes, and 16/32/64-bit edge cross-products
and random cases. It supplies independently calculated full products to test the
rounding stage; the separate multiply/divide test covers product generation.

Integrated tests execute actual instructions in Spike and compare the full VRF,
VSTART, VXRM, VXSAT and VCSR. They cover all rounding modes, scalar/immediate forms,
legal SEW/LMUL, narrowing overlap, equal source identities with different EEWs,
all-zero and alternating masks, nonzero VSTART, zero VL, sticky saturation initially
clear/set, and invalid or cancelled instructions. Whole-register move encodings
sharing funct6=0x27 with fractional multiply remain a separate unimplemented
instruction family, not reserved fractional-multiply encodings.

### Mixed-width arithmetic geometry

`rapt_vpu_geometry` derives source and destination sizes and checks each register
group independently. Arithmetic byte sizes are log2(EEW/8); EMUL is represented
by its signed power-of-two exponent. The leaf checks the ELEN/type limits,
fractional-group minimum, EMUL<=8, alignment, register extent and permitted
source/destination overlap. Mask operands retain their single-register EEW=1
rules. It is a stateless leaf with no XLEN, VLEN, ROB or core-package dependency;
it consumes instruction-class controls from the decoder. Memory retains its
own segment/index/whole-transfer geometry checks.

The top now retains separate source-A and destination element sizes; source B
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

The redundant operand-read optimization now requires equal read EEWs as well
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
The geometry leaf is validated through these integrated commands; no separate
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

`make -C verify/vpu muldiv` checks all 524,288 combinations of eight operations
and two 8-bit inputs, plus 16/32/64-bit edge cross-products, random inputs,
backpressured responses and reset during execution/held completion. In total,
each mode passes 549,832 checks. `muldiv-opt-check` executes the exact same input
hash in both modes, fingerprints its RTL/test/Makefile sources, and records
`verify/build/vpu/muldiv-optimization.json`. Simulation cycles decrease from
7,061,002 to 5,404,983 (23.453%), including identical request/response/reset
protocol overhead. Word-level synthesis of the current full-product interface grows from 133 to 170 cells and checks
that neither mode contains `$mul`, `$div`, or `$mod` cells. This is not application
IPC, standard-cell area, or physical timing evidence.

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
VLMAX, including a previous vill state, also set vill. Tail/mask policy bits do
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

The existing `rapt_sram_1rw` wrapper is used without modification. Behavioral
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
handle instruction-specific vstart restrictions. Scalar FS/FRM/FFLAGS handling
is still pending. Pipeline flush is deliberately not a CSR reset: completed
elements and their restart state survive a precise trap.

## Integer reductions

The pre-whole-register-move reduction snapshot passed `test`, `top-matrix DIFF=1`, `synth`
and `opt-check DIFF=1` on 2026-09-05. The four optimized top runs use seed
`243f6a8885a308d3` and the pinned Spike described above:

| XLEN / VLEN / ELEN / BankBits / Banks | Reduction commands | Illegal reduction cases | Spike commands | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 2,120 | 22 | 242,026 | `6119ea0830837aed` |
| 32 / 256 / 64 / 64 / 4 | 2,120 | 22 | 241,422 | `abcab07539d9c035` |
| 32 / 128 / 32 / 64 / 1 | 1,420 | 22 | 160,450 | `5c161bf68417c54c` |
| 64 / 512 / 64 / 128 / 4 | 2,120 | 22 | 242,026 | `5cb098ac484405f6` |

Totals are 885,924 executed Spike comparisons, including 7,780 successful
reduction instructions and 88 illegal reduction cases. All four top source
manifests and the synthesis manifest were checked against the worktree after
completion. These tests establish the listed workload results, not complete-V
conformance, formal proofs or scalar LSU/MMU integration.

For that snapshot, the original default arithmetic latency window was 66,682 cycles with
operand-read optimization disabled and 65,450 enabled (1.848% reduction).
The optimization comparison also checks the expanded workload's functional
identity; the latency window does not measure reduction performance.


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

Word-level synthesis passes 34 distinct configurations after adding four
standalone reduction configurations. Each reduction leaf has 220 word cells;
the default top (XLEN=64, VLEN=128, ELEN=64, BankBits=64, Banks=2,
OptimizeOperandReads=1) has 2,139 word cells and retains two 32x64-bit SRAMs.
These are unmapped structural counts, not physical area or timing measurements.
The source-fingerprinted `synth/summary.json` identifies the exact inputs.

`test_reduce_top.h` uses a separate numeric fold and full-array expected state,
then compares actual encoded execution with the pinned Spike. Cases include all
10 operations, supported SEW/LMUL combinations, policy bits, VL boundaries,
masked/unmasked execution, seed/destination inside a source group, v0 destination,
and register 31. Negative cases check nonzero vstart, source misalignment and
widening beyond ELEN. VXRM and VXSAT must survive reduction unchanged.

## Whole-register moves

The pre-scalar-transfer move snapshot passed `test`, `top-matrix DIFF=1`, `synth`,
`opt-check DIFF=1`, `muldiv-opt-check`, and the extra `move VLEN=512` leaf run
on 2026-09-05. The optimized top matrix (seed `243f6a8885a308d3`) reports:

| XLEN / VLEN / ELEN / BankBits / Banks | Move commands | Illegal move cases | Spike commands | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 704 | 126 | 248,881 | `c1a90ce3691c24b4` |
| 32 / 256 / 64 / 64 / 4 | 704 | 126 | 248,277 | `c367e8ed20c2311d` |
| 32 / 128 / 32 / 64 / 1 | 480 | 126 | 165,289 | `a1619c6a130106c9` |
| 64 / 512 / 64 / 128 / 4 | 704 | 126 | 248,881 | `5165da8cd6f6f86c` |

Totals are 911,328 executed Spike comparisons, with 2,592 successful move
instructions and 504 illegal move cases. Cancelled moves are separately checked
for absence of effects and do not execute in Spike. The original default
arithmetic latency window is still 66,682 -> 65,450 cycles (1.848%), and the
multiply/divide leaf workload is still 7,061,002 -> 5,404,983 cycles (23.453%).
Neither metric measures a speedup of whole-register moves. Source fingerprints
were checked after completion; earlier tables describe their earlier snapshots.


`rapt_vpu_move` implements `vmv1r.v`, `vmv2r.v`, `vmv4r.v` and `vmv8r.v`
with an independent command/completion and element-memory interface. It captures
the instruction, SEW, VILL and vstart at acceptance. The top supplies exclusive
VRF access after owner authorization; final write acknowledgement precedes
completion. Scalar VL, LMUL and tail/mask policy do not set the transfer extent:
the engine copies NREG*VLEN/8 bytes, starting at vstart*(SEW/8), preserving earlier
bytes. Equal source/destination and start beyond the effective length generate
no VRF requests. Register groups must be aligned to NREG; masked encodings and
counts other than 1/2/4/8 are illegal. Completion clears vstart, while illegal
instructions preserve it. VXRM/VXSAT and VL/VTYPE remain unchanged.

Whole-register **moves require VILL=0**, unlike whole-register memory transfers.
The archived `v1.0` public-review text incorrectly included moves in the list of
operations independent of VTYPE; the corrected
[vector specification](https://github.com/riscvarchive/riscv-v-spec/blob/master/v-spec.adoc#vector-type-illegal-vill)
removes that exception. The implementation follows the correction and the
pinned Spike's actual instruction semantics. The VILL negative tests are retained;
no reference instruction is skipped or patched to hide the distinction.

After adding the move engine, word-level synthesis passes 37 distinct
configurations. The move leaf has 85 word cells at VLEN=128/256/512. The default
XLEN=64, VLEN=128, ELEN=64, BankBits=64, Banks=2 top has 2,270 word cells with
operand-read optimization enabled (2,257 disabled), retaining two 32x64-bit
SRAMs. No latch or unexpected blackbox is accepted by the checker. These counts
do not establish technology-mapped area, frequency, or physical STA.

`test_move.cpp` directly instantiates the leaf without CSR, VRF SRAM, owner or
scalar core. Its byte scoreboard checks delayed read/write acknowledgements,
request backpressure, stable held completion, captured command inputs, all four
SEWs and group counts, restart boundaries, self-copy and illegal commands.
The seed is `452821e638d01377`; both VLEN=128 and 512 run 512 cases.
`test_move_top.h` additionally checks actual VTYPE/VL/VS ownership through the
public top and Spike, including fractional LMUL, VILL, reserved immediate counts,
source/destination alignment and cancelled commands.

## Integer scalar/vector transfers

The pre-VID scalar-transfer snapshot passed `test`, `top-matrix DIFF=1`,
`synth` and `opt-check DIFF=1` on 2026-09-05. The four optimized top runs use
seed `243f6a8885a308d3` and report:

| XLEN / VLEN / ELEN / BankBits / Banks | Scalar move commands | Negative cases | Spike commands | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 440 | 10 | 252,879 | `8c9af5dec876ed01` |
| 32 / 256 / 64 / 64 / 4 | 440 | 10 | 252,275 | `1c91a0accc3c0cf2` |
| 32 / 128 / 32 / 64 / 1 | 300 | 10 | 168,027 | `1a8b9695d3234f26` |
| 64 / 512 / 64 / 128 / 4 | 440 | 10 | 252,879 | `2d0c2c9f4ca8c857` |

This totals 926,060 executed Spike comparisons, including 1,620 successful
integer scalar moves. The 40 negative cases include 32 illegal instructions
and eight cancellations; cancellations are checked without executing Spike.
The original default arithmetic window remains 66,682 -> 65,450 cycles (1.848%)
with equal expanded-workload results. It does not measure scalar-move speedup.
Current-source fingerprints were checked after all runs completed.


The standalone top implements `vmv.x.s` and `vmv.s.x` with three dedicated
states and the existing element port; these one-element transfers do not require
a separate register file or a second execution engine. Decode admits only the
unmasked forms with the required zero source field. VILL or VS=Off traps.
Register numbers need no LMUL alignment because only element zero is involved.

`vmv.x.s` reads element zero even with VL=0 or vstart>=VL. It sign-extends when
SEW<XLEN and truncates when SEW>XLEN, returning the result through the existing
scalar completion field. An x0 destination returns no scalar write. `vmv.s.x`
writes element zero only when vstart<VL, sign-extending the XLEN-wide input when
SEW>XLEN. Other bytes remain undisturbed, including under agnostic policy. Both
successful operations clear vstart and preserve VL/VTYPE/VXRM/VXSAT; illegal or
cancelled commands preserve architectural state.

The scalar-transfer-enabled top passes the 37-configuration word-level
synthesis check. At XLEN=64, VLEN=128, ELEN=64, BankBits=64 and Banks=2 it
has 2,327 word cells with OptimizeOperandReads=1 (2,314 with 0), retaining
two 32x64-bit SRAMs. This remains an unmapped structure check, not a physical
area or timing result.

`test_scalar_move_top.h` tests both directions over every supported SEW/LMUL
combination, all policy bits, zero/one/maximum VL, zero/nonzero/beyond-VL vstart,
sign edges, registers 0/17/31, XLEN width conversion, reserved encodings, VILL,
VS=Off and cancellation. The expected byte/scalar model and pinned Spike execute
through the same public top command path; scalar results and full VRF contents
are checked separately.

## Vector element indices

The pre-mask-scan VID snapshot passed `test`, `top-matrix DIFF=1`, `synth` and
`opt-check DIFF=1` on 2026-09-05, using seed `243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | VID commands | Negative cases | Spike commands | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 220 | 5 | 254,878 | `615fd85d81635012` |
| 32 / 256 / 64 / 64 / 4 | 220 | 5 | 254,274 | `f0c8bfcad579d18c` |
| 32 / 128 / 32 / 64 / 1 | 150 | 5 | 169,396 | `47ef920c6100d3ba` |
| 64 / 512 / 64 / 128 / 4 | 220 | 5 | 254,878 | `26f2378f450e0c80` |

Totals are 933,426 executed Spike comparisons and 810 successful VID commands.
The 20 negative cases include 16 illegal instructions and four cancellations.
The VLEN=512 run checks 1,281 active e8 elements with indices above 255.
Cancelled commands do not execute in Spike. The original default arithmetic
window remains 66,682 -> 65,450 cycles (1.848%) with equal expanded-workload
results; this metric does not measure VID performance. Source fingerprints
were checked after all runs completed.


`vid.v` writes each active element's absolute index, truncated to SEW and
zero-extended when SEW is wider. It uses the existing element scheduler, mask
read and destination write paths; neither vector source is read and no execution
state or arithmetic unit is added. Normal destination geometry, VILL and VS
checks apply. The encoded vs2 must be zero and masked destination overlap with
v0 is rejected. Prestart and tail bytes are preserved; masked-off elements do
not renumber later active elements. Successful completion clears vstart while
preserving VL, VXRM and VXSAT.

The VID-enabled top passes 37 word-level synthesis configurations. At
XLEN=64, VLEN=128, ELEN=64, BankBits=64, Banks=2, it has 2,359 word cells with
OptimizeOperandReads=1 (2,346 disabled), retaining the two 32x64-bit SRAMs.
This check excludes latches and unexpected blackboxes; it does not establish
physical area or timing.

`test_index_top.h` checks all supported SEW/LMUL pairs, policy bits, zero/one/
maximum VL, restart at/beyond VL, unmasked v0 destination, zero/full/alternating
masks and invalid encodings/geometry/VILL/cancellation. The independent expected
byte model and pinned Spike both check the final VRF. VLEN=512 explicitly
requires coverage of e8 index truncation above 255.

## Scalar mask scans

The pre-mask-prefix scan snapshot passed `test`, `top-matrix DIFF=1`, `synth`,
`opt-check DIFF=1`, `muldiv-opt-check`, and `mask-scan XLEN=32 VLEN=512` on
2026-09-05. The optimized top matrix uses seed `243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | Scan commands | Negative cases | Spike commands | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 784 | 12 | 259,405 | `7046e6c21ed67153` |
| 32 / 256 / 64 / 64 / 4 | 1,040 | 12 | 259,057 | `db868f286c9c8e5a` |
| 32 / 128 / 32 / 64 / 1 | 616 | 12 | 172,579 | `542222d471baeb4d` |
| 64 / 512 / 64 / 128 / 4 | 1,552 | 12 | 260,173 | `57f6c4e5269149f3` |

Totals are 951,214 executed Spike comparisons, including 3,992 successful scan
instructions. The 48 negative cases include 40 illegal instructions and eight
cancellations, which do not execute in Spike. Current-source fingerprints were
checked after all runs completed. The original default arithmetic window remains
66,682 -> 65,450 cycles (1.848%); multiply/divide remains 7,061,002 -> 5,404,983
cycles (23.453%). Neither window measures mask-scan performance or application IPC.


`rapt_vpu_mask_scan` implements `vcpop.m` and `vfirst.m` independently of the
scalar core, vector element width and VRF SRAM geometry. It captures the scan
mode, source register, predicate enable, VL, VILL and restart legality when a
command is accepted. The top decodes the raw instruction and supplies exclusive
read-only VRF access after owner authorization. A six-bit top state enum now
accommodates the additional start/run states.

The source is a single mask register regardless of LMUL. VILL and nonzero vstart
are illegal (also with VL=0). VCPop returns the active set-bit count; VFirst
returns the lowest active set-bit index or XLEN-wide -1. Both return a scalar
result even for VL=0, and ignore writes to x0. Successful completion clears
vstart, preserves fixed-point CSRs and does not write the VRF.

The engine fetches one source byte and, if needed, one predicate byte per eight
mask elements. Bits beyond VL in the last byte are excluded. When vs2=v0, it
reuses the source byte because source AND predicate equals source. VFirst stops
after the first byte containing an active set bit. Each accepted read response
is consumed before completion; request and completion payloads remain stable
under backpressure. These are structural read reductions, not application IPC
measurements.

`test_mask_scan.cpp` independently counts/searches individual bits. It exhausts
all 256x256 source/predicate bytes for both modes and every VL from 0 through 8,
then tests all VL values through VLEN on multibyte data, unmasked/predicated and
v0/register-31 sources. It checks exact read counts, delayed responses, request
stalls, held completion, captured inputs and invalid controls. The default
XLEN=64/VLEN=128 run passes 1,180,688 cases; XLEN=32/VLEN=512 passes 1,183,760.
Both use seed `be5466cf34e90c6c`. `test_scan_top.h` additionally compares real
instructions with Spike over supported SEW/LMUL configurations, all possible
first-bit positions, full population counts, partial bytes, VILL, VS=Off,
nonzero vstart, reserved encodings and cancellation.

Synthesis passes 41 configurations including four standalone mask-scan leaves
at 157 word cells each. The XLEN=64/VLEN=128/ELEN=64/BankBits=64/Banks=2 top has
2,569 word cells with operand-read optimization enabled (2,556 disabled), and
retains two 32x64-bit SRAMs. This is unmapped synthesis without physical STA.

## First-bit mask prefixes

The pre-IOTA prefix snapshot passed `test`, `top-matrix DIFF=1`, `synth` and
`opt-check DIFF=1` on 2026-09-05. The optimized top matrix uses seed
`243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | Prefix commands | Negative cases | Spike commands | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 1,047 | 21 | 265,928 | `36bd416426834143` |
| 32 / 256 / 64 / 64 / 4 | 1,431 | 21 | 266,732 | `5dd6172a4cb1aab5` |
| 32 / 128 / 32 / 64 / 1 | 837 | 21 | 177,422 | `05e8b56ab555d374` |
| 64 / 512 / 64 / 128 / 4 | 2,199 | 21 | 270,152 | `f29a3f17244a4c2d` |

Totals are 980,234 executed Spike comparisons, including 5,514 successful
prefix instructions. The 84 negative cases include 72 illegal instructions
and 12 cancellations, which do not execute in Spike. Current-source fingerprints
were checked after completion. The original default arithmetic window remains
66,682 -> 65,450 cycles (1.848%) with equal expanded-workload results; it does
not measure prefix-instruction performance.


`vmsbf.m`, `vmsof.m` and `vmsif.m` reuse the top's mask-source reader,
one-bit mask writer and element scheduler. A single command-local `prefix_seen`
bit records whether an active source one has been processed. It updates only
after the mask writer acknowledges completion. Masked-off elements neither
write the destination nor affect this state. The result is respectively the
active bits before, only at, or through the first active source one. With no
active source one, BF/IF set all active destination bits and OF clears them.

Source and destination each occupy one mask register, independent of LMUL.
The destination cannot equal the source or, when masked, v0. Nonzero vstart is
illegal even with VL=0; VILL and VS=Off also trap. The retained tail/masked-off
bits implement a permitted undisturbed choice within agnostic policies.
Successful completion clears vstart and preserves VL/VXRM/VXSAT. No new SRAM,
execution engine or top state is introduced.

The prefix-enabled top passes the 41-configuration word-level synthesis
check. At XLEN=64, VLEN=128, ELEN=64, BankBits=64 and Banks=2, it has 2,622
word cells with operand-read optimization enabled (2,609 disabled), retaining
two 32x64-bit SRAMs. No physical area or timing claim follows from these counts.

`test_prefix_top.h` uses an independent first-position/relational model rather
than reproducing the RTL's state transition. Tests cover supported SEW/LMUL
pairs, all policy bits, VL boundaries, no/full/alternating masks, v0 as source
or unmasked destination, register 31, and every possible first-one position
through VLEN (including no one). Full VRF contents and CSR state are compared
with the expected model and pinned Spike; illegal overlap, nonzero vstart,
VILL, VS=Off and cancellation preserve state.

## Vector iota

The iota-enabled snapshot passed `test`, `top-matrix DIFF=1`, `synth` and
`opt-check DIFF=1` on 2026-09-05, using seed `243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | Iota commands | Negative cases | Spike commands | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 264 | 9 | 268,075 | `31b5728e22e8ba2b` |
| 32 / 256 / 64 / 64 / 4 | 264 | 9 | 268,879 | `de3ce2475e9e7640` |
| 32 / 128 / 32 / 64 / 1 | 180 | 9 | 178,897 | `b21f8d676c430775` |
| 64 / 512 / 64 / 128 / 4 | 264 | 9 | 272,299 | `e9916ca3536e9307` |

Totals are 988,150 executed Spike comparisons, including 972 successful iota
instructions. The 36 negative cases include 32 illegal instructions and four
cancellations, which do not execute in Spike. VLEN=512 checks 512 active e8
outputs with prefix counts above 255. Current-source fingerprints were checked
after all runs completed. The original default arithmetic window remains
66,682 -> 65,450 cycles (1.848%) with equal expanded-workload results; this does
not measure iota performance.


`viota.m` uses the existing element scheduler and writer with a command-local
count of prior active source ones. The count advances only after a destination
write acknowledgement; predicate-disabled elements neither write nor contribute
to the count. Each active output contains the count before its own source bit,
zero-extended or truncated to SEW. The internal count remains wide enough for
VLEN, even when e8 outputs wrap. Tail and masked-off elements are preserved.

The geometry module now distinguishes a single mask source from ordinary vector
sources: no LMUL alignment is imposed on vs2, while the destination retains its
SEW/LMUL group geometry. Any overlap of the source mask with the destination
group is illegal, including a source in the middle of the group. Masked v0
destinations and nonzero vstart are rejected, also for VL=0. VILL/VS checks and
CSR updates use the existing authorization/completion path.

The iota-enabled top passes 41 word-level synthesis configurations. At
XLEN=64, VLEN=128, ELEN=64, BankBits=64 and Banks=2 it has 2,675 word cells
with operand-read optimization enabled (2,662 disabled), retaining two 32x64-bit
SRAMs. The checks include the updated ELEN32/64 geometry module and exclude
latches/unexpected blackboxes; physical timing and area remain unmeasured.

`test_iota_top.h` calculates each output by independently counting all earlier
enabled source bits, then compares the entire VRF and CSR state with the DUT and
pinned Spike. It covers all supported SEW/LMUL combinations, VL boundaries,
policy bits, empty/full/alternating masks, unmasked v0 destination, v0/register-31
sources, destination overlap/alignment, VILL, VS=Off and cancellation. VLEN=512
requires observed e8 output truncation for counts above 255.

## Vector compression snapshot

The compression-enabled sources on 2026-09-05 implement `vcompress.vm`. The
encoded vs1 register supplies selection bits independently of v0. Source element
progress and packed destination progress are separate: only a selected element's
acknowledged write advances the destination. Unwritten destination bytes remain
undisturbed. The destination cannot overlap either source; the selection mask
may overlap the data source. Nonzero vstart is illegal, including with VL=0.

`test_compress_top.h` builds expected packed bytes from a complete pre-command
VRF snapshot and compares the full VRF with both that model and pinned Spike.
Tests cover supported SEW/LMUL pairs, VL=0/1/intermediate/maximum, all policy
bits, empty/full/alternating/random selectors, source-mask overlap, v0 operands,
alignment, prohibited destination overlap, vm=0, VILL, VS=Off and cancellation.

| XLEN / VLEN / ELEN / BankBits / Banks | Compression commands | Executed Spike commands | Workload hash |
| --- | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 220 | 269,874 | `5e6839281fd116ba` |
| 32 / 256 / 64 / 64 / 4 | 220 | 270,678 | `fe3b2ce90cadd8c3` |
| 32 / 128 / 32 / 64 / 1 | 150 | 180,136 | `b53883511846de49` |
| 64 / 512 / 64 / 128 / 4 | 220 | 274,098 | `767c71dce7538d97` |

`top-matrix DIFF=1` passes 994,786 executed Spike commands in total, including
810 positive compression commands and 40 negative/cancellation cases (nine
illegal commands and one cancellation per configuration). The seed is
`243f6a8885a308d3`; configuration/source fingerprints and reference-library hashes
are recorded in each build directory. These results supersede the earlier iota
snapshot for this workload. The default non-Spike `test` also passes.

`opt-check DIFF=1` passes for the same source fingerprints and workload hash in
the default configuration. Operand-read optimization reduces the original
arithmetic measurement window from 66,682 to 65,450 cycles (1.848%). That window
does not include compression; this is not a compression speedup or application
IPC measurement.

The compression-enabled `synth` passes 41 configurations. Default
XLEN=64/VLEN=128/ELEN=64/BankBits=64/Banks=2 uses 2,720 word cells with operand-read
optimization enabled and 2,707 disabled, retaining two 32x64-bit synchronous
SRAMs. These are word-level synthesis counts, not mapped area or timing results.
Slide/gather families, vector floating point and real scalar-core integration
remain incomplete.

## Slide routing and integer instruction integration

`rapt_vpu_slide.sv` resolves each destination element to a source element, scalar
insertion, zero, or no write. The caller supplies legal VL/VLMAX, restart index,
destination mask activity and the full unsigned scalar/immediate offset. The
addition retains an extra carry bit, so maximal XLEN offsets cannot wrap into a
valid source index. Ordinary downward slides read up to VLMAX, even beyond VL;
slide1down instead inserts scalar data at VL-1. Upward slides preserve positions
below the offset. Prestart, inactive and tail destinations cause no read/write.

The caller remains responsible for raw-encoding admission, group geometry,
forbidding upward source/destination overlap, scalar sign extension and VRF
transactions. Downward aliasing requires ascending destination execution.
The leaf has no architectural state or ready/valid transaction of its own.

On 2026-09-05, independent `slide` tests pass for XLEN/VLEN=64/128, 32/128,
64/512 and 32/512: respectively 1,179,632, 1,179,632, 2,559,472 and 2,559,472
coordinate checks. Small capacities exhaust all tested VL, restart, destination,
offset and mode combinations; larger capacities sweep every destination with
boundary offsets including the XLEN high bit and unsigned maximum. The reference
uses signed 128-bit arithmetic. Fingerprints are in the `slide-*/sources.json`
build artifacts. These tests do not yet execute encoded slide instructions.

The top now admits `vslideup.vx/vi`, `vslidedown.vx/vi`, `vslide1up.vx` and
`vslide1down.vx`. A separate routing state selects source reads, zero writes or
scalar insertion after destination masking. Ascending destination execution
supports downward in-place slides; geometry rejects upward overlap even when
VL=0. Scalar insertion uses XLEN sign extension before element truncation.
Offsets retain XLEN width and immediates are unsigned, independently of SEW.

`test_slide_top.h` computes all expected destination bytes from a pre-command
VRF snapshot with signed-128-bit source coordinates. It covers every supported
SEW/LMUL, six encodings, VL/start/policy boundaries, inactive and alternating
masks, source reads beyond VL, huge offsets, in-place downward offsets 0/1,
negative scalar insertion and unmasked v0 destinations. Ten negative cases per
configuration include forbidden overlap, group misalignment, VILL, masked v0,
reserved forms, VS=Off and cancellation.

Integrated synthesis passes 45 configurations, including four slide leaves
(32 word cells each, no memory or latches). At XLEN=64/VLEN=128/ELEN=64,
BankBits=64/Banks=2 the top has 2,810 word cells with operand-read optimization
and 2,797 without, retaining two 32x64-bit synchronous SRAMs. These are not
technology-mapped area or timing results. Earlier compression tables remain
historical snapshots. This slide snapshot predates gather integration; vector floating point remains unimplemented.

The integrated slide snapshot on 2026-09-05 passes `top-matrix DIFF=1` with
the pinned Spike reference and seed `243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | Slide commands | Executed Spike commands | Workload hash |
| --- | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 2,112 | 288,921 | `8394842e5b9627cd` |
| 32 / 256 / 64 / 64 / 4 | 2,112 | 289,725 | `d50de5dfbf2daf21` |
| 32 / 128 / 32 / 64 / 1 | 1,440 | 193,135 | `8c7c105165c7d4f6` |
| 64 / 512 / 64 / 128 / 4 | 2,112 | 293,145 | `d18592b947ee89cc` |

This totals 1,064,926 executed Spike comparisons, including 7,776 positive
slide commands and 40 negative/cancellation cases. Default `test` also passes.
`opt-check DIFF=1` passes for the same default workload and source fingerprints:
the original arithmetic window remains 66,682 cycles without operand-read
optimization and 65,450 with it (1.848% reduction). It excludes slide execution,
so it does not measure slide throughput. All six completed top run manifests
(four optimized differential configurations, default baseline differential and
default non-differential) and the 45 synthesis configurations were checked
against current source hashes. This establishes neither full-V conformance nor
real LSU/MMU integration or physical timing.

## Gather integration

The top admits `vrgather.vv/vx/vi` and `vrgatherei16.vv`. Vector forms read the
index operand before the data source; all forms compare the complete unsigned
index against VLMAX before constructing a VRF address. An out-of-range index
writes zero without a data-source read. Scalar indices preserve XLEN width and
immediates are zero-extended. An in-range source index may exceed VL.

The geometry module independently derives the ei16 index EMUL from
LMUL * 16/SEW, accepts effective groups from 1/8 through 8, checks alignment and
rejects destination overlap with either source group. The index port uses 16-bit
reads regardless of data SEW. Destination mask checks precede index/data reads;
prestart and tail bytes are retained. No new architectural state or independent
transaction owner is introduced.

`test_gather_top.h` constructs expected bytes from a complete pre-command VRF
snapshot and checks the full VRF and CSRs against the DUT and pinned Spike. It
covers all supported data SEW/LMUL combinations and legal index EMULs, four
encodings, VL/start/policy boundaries, mask patterns, reverse/random/boundary
indices, huge unsigned scalar indices, same-width source aliasing and unmasked
v0 operands. Fifteen negative/cancellation cases include VILL, both source-group
alignment checks, destination overlap (including overlap inside an ei16 index
group), excessive index EMUL, reserved forms, VS=Off and cancellation.

Gather-enabled synthesis passes 45 configurations. The default
XLEN=64/VLEN=128/ELEN=64/BankBits=64/Banks=2 top has 2,882 word cells with
operand-read optimization enabled, 2,867 disabled, and two 32x64-bit synchronous
SRAMs. These checks do not establish physical area/timing or full V conformance.

The gather-enabled snapshot on 2026-09-05 passes `top-matrix DIFF=1` with the
pinned reference and seed `243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | Gather commands | Executed Spike commands | Workload hash |
| --- | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 1,392 | 301,508 | `6a823d860152280d` |
| 32 / 256 / 64 / 64 / 4 | 1,392 | 302,312 | `877960b68256a1f9` |
| 32 / 128 / 32 / 64 / 1 | 944 | 201,690 | `915daa4b4253c20e` |
| 64 / 512 / 64 / 128 / 4 | 1,392 | 305,732 | `073655db0169088e` |

This totals 1,111,242 executed Spike comparisons, including 5,120 positive
gather commands and 60 negative/cancellation cases (56 illegal, four cancelled).
The default non-Spike `test` and `opt-check DIFF=1` also pass. The original
arithmetic window remains 66,682 versus 65,450 cycles (1.848% reduction); that
window excludes gather and does not establish gather throughput improvement.
All six completed top manifests and all 45 synthesis configuration fingerprints
were checked against the current sources. Earlier slide/compression tables
retain their historical source snapshots. Floating point, the full legality
audit, full-engine formal safety and real core/LSU/MMU integration remain open.

## Floating-point FMA element foundation (pre-integration snapshot)

`rapt_vpu_fma.sv` reuses the existing scalar `rapt_fpu_fma` datapath through a
standalone request/response boundary. `Double=0/1` selects FP32/FP64. Requests
contain raw element bits, independent product/addend sign controls and resolved
rounding mode 0..4. The wrapper internally boxes FP32 inputs for the shared
scalar unit and returns the low 32 result bits with zero upper bits. It captures
results and flags until the consumer accepts them, rejects rounding encodings
5..7 with `illegal`, and discards all local work on reset. Request operands can
change after acceptance without changing the result. The caller will own RVV
operand ordering, FRM resolution, VS/FS checks and active-element flag updates.

FP operation constants now live in `hdl/include/rapt_fp_ops.svh`; `rapt.svh`
includes that header and the shared FMA includes it directly. Numeric opcode
values and arithmetic logic are unchanged. This removes scalar preset/package
dependencies from the independently compiled element engine.

```sh
make -C verify/vpu fma FMA_DOUBLE=0 SPIKE_BUILD=/path/to/spike-source-build
make -C verify/vpu fma FMA_DOUBLE=1 SPIKE_BUILD=/path/to/spike-source-build
```

The tests use the pinned reference build's SoftFloat library directly, not host
floating-point arithmetic. Each precision passes 54,563 requests: all triples of
12 directed bit patterns across four sign combinations and five rounding modes,
20,000 random triples, and three illegal-rounding requests. Both result bits and
all five exception flags are compared; reference NaN payloads are canonicalized.
Every response is held for three cycles, unrelated requests are presented while
busy, and ten reset ages cover in-flight/held completion boundaries. The seed is
`452821e638d01377`. Source and reference-library hashes are in `fma-*/` artifacts.

The shared scalar datapath has existing width, unused-signal and filename lint
warnings, plus unselected FP64 packing expressions in FP32 elaboration.
`fma_legacy.vlt` confines WIDTH/UNUSEDSIGNAL/DECLFILENAME/SELRANGE waivers to that
shared file. New wrapper warnings remain fatal; these runs are not a clean lint
claim for the shared datapath. This leaf is not yet decoded or scheduled by the
VPU top; add/subtract, multiply, divide/sqrt, conversion, comparison, reduction,
architectural flags and scalar-FPR integration remain to be completed.

Synthesis passes 47 configurations, adding FP32 and FP64 FMA wrapper leaves at
7,188 and 15,746 word cells respectively, with no memories or latches. The large
counts include the shared prefix-adder datapath and are not technology-mapped
area or physical timing. The unconnected wrapper leaves the integer top's
resources unchanged. Both leaf simulation source manifests and all synthesis
fingerprints were checked against current files.

The shared-header change also passes the existing scalar regression
`make -C verify/xsim/fpu/fma run N=10000`: directed `FMA-UNIT PASS` and 10,000
host comparisons with zero failures. That older target uses broad warning
suppression and NaN-payload tolerance, so it is supplementary regression
evidence, not strict lint or a substitute for the new SoftFloat flag checks.
The default non-Spike integer top regression also passes with the current source
manifest. Earlier integer differential and optimization tables predate the FMA
wrapper/build changes and remain historical snapshots.

## Shared floating-point arithmetic element layer (pre-integration snapshot)

`rapt_vpu_fp_arith.sv` extends the independent FMA interface with an operation
selector: 0=FMA, 1=add, 2=subtract, 3=multiply. All use raw element bits and the
same request/held-response protocol. Add/subtract use an exact 1.0 factor;
multiply supplies a zero addend with the exact product sign so a negative zero
product remains negative. Non-FMA operations ignore the third operand and both
FMA sign controls. Rounding 5..7 remains illegal until resolved by the caller.
No scalar preset, package or extra arithmetic datapath is instantiated.

```sh
make -C verify/vpu fp-arith FMA_DOUBLE=0 SPIKE_BUILD=/path/to/spike-source-build
make -C verify/vpu fp-arith FMA_DOUBLE=1 SPIKE_BUILD=/path/to/spike-source-build
```

On 2026-09-05 each precision passes 116,732 requests against pinned SoftFloat:
54,563 FMA cases plus 20,723 each for add, subtract and multiply. For each added
operation, 720 directed operand-pair/rounding combinations, 20,000 random pairs
and three illegal-rounding requests are checked. The reference calls SoftFloat
add/sub/mul directly; it does not reproduce the fused implementation mapping.
Unused inputs are deliberately nonzero or NaNs, sign controls are varied, and
operation/input signals change while the request is in flight. Results and all
five flags must remain stable under response backpressure. Both original FMA
leaf targets are also rerun after the shared test-driver change.

Synthesis passes 49 configurations. FP32/FP64 arithmetic leaves use 7,199/15,757
word cells, respectively, 11 more than the corresponding FMA-only wrapper.
This measures the operation-select logic at word level, not physical area or
throughput; it retains the FMA's single-request execution latency. The existing
shared-FMA lint waivers remain scoped as described above. The VPU top still
needs floating-point decode, scheduling, flags/FRM and FPR integration, followed
by the remaining divide/sqrt, conversions, comparisons and reductions.

## Floating-point arithmetic decode and operand mapping (pre-integration snapshot)

`rapt_vpu_fp_decode.sv` recognizes the 23 single-width arithmetic encodings
covered by the current element engine: vfadd/vfsub/vfmul in vv/vf forms,
vfrsub.vf, and all eight destructive FMA variants in vv/vf forms. It separately
reports recognition and contextual legality. The caller supplies resolved FRM,
VILL and combined VS/FS enable; legal arithmetic requires FRM 0..4 and supported
SEW=32/64. Register geometry, mask decisions and transaction authorization remain
with the scheduler.

The mapper explicitly selects whether old vd is the multiplicand or addend,
sets both FMA signs, and swaps operands for reverse subtract. Vector inputs
remain raw bits. For FP32 scalar forms it checks the 64-bit FPR NaN box and
substitutes canonical NaN for an invalid box. FP32 output operands are truncated
to 32 bits with zero upper bits. Illegal inputs return no operand-use controls
and zero data, while recognition remains available for top-level trap routing.

```sh
make -C verify/vpu fp-decode ELEN=32
make -C verify/vpu fp-decode ELEN=64
```

Both configurations pass 557,056 independent mapping/admission checks each:
all 128 major opcodes, 64 funct6 values, eight forms and both vm values at a
valid FP32 context; all funct6/forms across SEW/FRM/enable/VILL combinations;
and bit-by-bit operand provenance with valid/invalid scalar boxes and changing
register identities. The oracle is a table of architectural operand equations,
not the implementation's encoding-bit equations. New-module lint is strict,
apart from annotated register/mask bits consumed by the future caller. These
checks do not execute vector instructions or establish integrated FP correctness.
The next gate is to connect this mapper and the arithmetic engine to top-level
VRF scheduling, FPR operands, FRM and active-element exception flags.

Synthesis now passes 51 configurations. The new ELEN32/64 mapper leaves use
62/64 word cells with no memories or latches. Both completed simulation manifests
and all 51 synthesis source fingerprints were checked against the current
worktree. These counts do not establish physical timing or area. Earlier FP
arithmetic and integer run tables retain their recorded source snapshots.

## Integrated single-width floating-point arithmetic

The current top executes vfadd/vfsub/vfmul vv/vf, vfrsub.vf and all eight
single-width destructive FMA variants vv/vf. FP32 and (when ELEN=64) FP64 element
engines share the existing sequential VRF scheduler. Scalar operand, FRM and FS
availability travel in the captured command; old destination is read before
FMA execution. The separate FP-decode mapper supplies operand order and NaN-box
checks. Mask gating precedes operand reads and flags are accumulated only after
an active write acknowledgement. Widening FP, divide/sqrt, estimates, comparison,
conversion, FP transfers and FP reduction families remain incomplete.

`test_fp_top.h` checks exact integer-valued FP arithmetic equations independently
of the RTL for all 23 encodings, supported SEW/LMUL combinations, VL/start/policy
boundaries, masks and destination/source aliasing. Additional directed cases
check all five rounding modes, NX/UF/OF/NV, invalid scalar NaN boxes and exception
suppression by mask, prestart and VL=0. Illegal cases cover VILL, unsupported
SEW, group alignment, masked v0, invalid FRM, FS=Off and pre-authorization kill.
The command driver changes FPR/FRM/FS inputs after acceptance and checks held
completion flags/dirty state. The full VRF and each command's FP exception delta
are compared against actual Spike instruction execution.

The reference adapter now initializes an independent scalar FPR input and FRM,
clears reference fflags before each instruction to compare the completion delta,
and applies the requested FS state before execution. FS is temporarily enabled
for reference CSR initialization (Spike rejects writing floating CSRs with FS
Off), then restored before fetching the tested instruction. No vector result or
DUT flags are injected. ELEN32 uses `gc_zve32f` rather than the older integer-only
`gc_zve32x`; ISA/reference-library fingerprints are retained. This does not test
real scalar-core FCSR accumulation or context switching.

The default XLEN=64/VLEN=128/ELEN=64/BankBits=64/Banks=2 top passes 307,015 Spike
instruction comparisons, including 1,442 positive FP commands and ten negative/
cancellation cases, with workload hash `48affdede754cfc7` and seed
`243f6a8885a308d3`. Synthesis passes 51 configurations. Default top word-cell
counts are 25,912 with operand-read optimization and 25,897 without, retaining
two 32x64-bit synchronous SRAMs. These include the shared FMA logic and are not
mapped PPA. All four integrated parameter runs now pass:

| XLEN / VLEN / ELEN / BankBits / Banks | FP positive commands | Executed Spike commands | Workload hash |
| --- | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 1,442 | 307,015 | `48affdede754cfc7` |
| 32 / 256 / 64 / 64 / 4 | 1,442 | 307,819 | `7c4697cd42a21505` |
| 32 / 128 / 32 / 64 / 1 | 652 | 204,187 | `88bb7ae292b6b605` |
| 64 / 512 / 64 / 128 / 4 | 1,442 | 311,239 | `6ef3957016be3f77` |

This totals 1,130,260 executed Spike comparisons, including 4,978 FP positive
commands and 40 negative/cancellation cases. The three nondefault top runs used
explicit configuration arguments to `make top DIFF=1`; this snapshot did not
rerun the separate owner simulation target through `top-matrix`. Default `test`
and `opt-check DIFF=1` pass. The original integer arithmetic measurement window
remains 66,682 versus 65,450 cycles (1.848% reduction), excluding FP execution.
All six completed top manifests and all synthesis fingerprints match current
sources. Directed exceptional top cases currently use one element at a time;
multi-element mixed-flag stress was added in the focused snapshot below. The independent
arithmetic leaf tests provide broader numeric/rounding coverage.

Ownership proofs were extended to current command/result payload sizes:
TagBits/CommandBits/ResultBits = 10/164/109 (RV32) and 10/228/205 (RV64), alongside
1/8/8 and 3/17/29. All four inductive safety proofs, 44 reachability witnesses
and four mutation detections pass. Artifacts are in
`verify/build/vpu/formal-owner-fp/`. This remains a control proof; it does not
prove full-engine arithmetic, VRF/store write safety, external drain or liveness.

## Multi-element floating-point exception stress

`test_fp_mixed_top.h` adds eight-element multiplication cases containing
underflow/inexact, overflow/inexact, signaling NaN/invalid and exact results.
It checks the precise OR of active-element flags, full destination bytes,
restart clearing, destination/source aliasing and held completion metadata.
Each mixture is immediately followed by an exact FP command that must return
zero exception delta, detecting leakage across command owners.

All five rounding modes and four rotations of the exception classes are used.
Mask `0x33` selects only two classes; vstart=6 retains only the last two elements;
VL=2 retains only the first two. Thus excluded exception types cannot be hidden
by an active occurrence of the same type. Separate cases cover all-masked,
VL=0 and vstart>=VL. The external scalar FCSR's sticky update remains the host's
responsibility; this suite validates per-command deltas and the VPU's intra-
instruction accumulation, not a real core FCSR implementation.

```sh
make -C verify/vpu top TOP_SUITE=fp-mixed DIFF=1 SPIKE_BUILD=/path/to/spike-source-build
make -C verify/vpu top TOP_SUITE=fp-mixed
```

`TOP_SUITE=fp-mixed` selects only these tests and records `suite: fp-mixed` in
the source manifest, with separate `*-fp-mixed` build directories and a
`PASS fp_mixed_top` completion marker. The default `full` suite also calls the
new tests. `opt-check` rejects a focused suite before starting work, and the
comparison script requires full-suite manifests. Focused results must not be
reported as a new full integer/FP regression or an optimization measurement.

On 2026-09-05 the focused suite passes these configurations with seed
`243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | FP commands | Executed Spike commands | Workload hash |
| --- | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 640 | 1,920 | `525e908bd74414bd` |
| 32 / 256 / 64 / 64 / 4 | 640 | 1,920 | `f0c938af64e538f6` |
| 32 / 128 / 32 / 64 / 1 | 320 | 960 | `dfac1fbcfcde0b2e` |
| 64 / 512 / 64 / 128 / 4 | 640 | 1,920 | `6722da0f80329eab` |

This totals 2,240 FP commands and 6,720 executed Spike comparisons, including
configuration and restart-CSR commands. There are 280 observed NV|OF|UF|NX
unions. Default non-Spike focused execution also passes with the same workload
hash. All five focused source manifests match current files. Production RTL is
unchanged in this test-only snapshot; the full suite, synthesis and optimization
were not rerun, and their earlier tables retain their original source snapshots.

## Floating-point divide/square-root element engine

`rapt_vpu_divsqrt.sv` wraps the existing iterative scalar divider/square-root
with raw vector element inputs and a held ready/valid response. One datapath
supports runtime FP32/FP64 selection; ELEN=32 rejects FP64 requests. The wrapper
boxes raw FP32 inputs for the shared unit, captures result precision, returns
zero upper bits for FP32, and holds result/flags/illegal until acceptance.
Rounding modes 5..7 are rejected without launching the unit. Reset aborts all
local work, including a held response. Opcode recognition, architectural flags
accumulation and vector scheduling remain outside this leaf.

The shared `rapt_fpu_divsqrt.sv` no longer imports scalar configuration. Its
unused compatibility XLEN parameter defaults to 64 and its unused destination-
precision port is retained for existing scalar instantiations. Explicit signed
integer casts and correctly sized zero padding replace implicit width
conversions, preserving the existing arithmetic. Only those unused compatibility
items are locally annotated; this path compiles with fatal warnings and no
file-wide lint waiver.

```sh
make -C verify/vpu divsqrt ELEN=32 SPIKE_BUILD=/path/to/spike-source-build
make -C verify/vpu divsqrt ELEN=64 SPIKE_BUILD=/path/to/spike-source-build
```

On 2026-09-05 the ELEN32/64 leaves pass 42,922/45,812 requests against pinned
SoftFloat. For each supported precision, all pairs of 17 directed bit patterns
are tested for both operations and all five rounding modes; there are also
40,000 random requests per configuration and 32 precision/operation/rounding
boundary requests. Square-root tests vary the ignored second operand, including
NaNs. Directed values include both zeros, subnormals, minimum normal, 1, 2, 1/2,
3, finite extrema, infinities and quiet/signaling NaNs. Results and all five flags
are checked, with reference NaN payloads canonicalized. The seed is
`082efa98ec4e6c89`.

Requests deliberately change precision, operation, operands and rounding after
acceptance. Every response is stalled for three cycles. ELEN32/64 tests cover
128/256 reset boundaries (all ages 0..63 for each supported precision/operation),
then check for late responses over 70 clocks. The existing scalar regression
`make -C verify/xsim/fpu/divsqrt run N=10000` also passes 10,000 host comparisons
with zero failures; its broad warning suppression and NaN tolerance make it
supplementary evidence, not a strict-lint claim.

Synthesis passes 53 configurations. The new ELEN32/64 leaves use 761/834 word
cells and no memories or latches; these are not mapped area or timing results.
Both completed leaf source manifests and all synthesis fingerprints were checked
against current sources. No encoded vector divide/sqrt instructions execute in
the top yet. Full top simulation/optimization were not rerun for this leaf-only
addition; earlier integrated tables retain their original snapshots.

## Owner control formal proof (original payload snapshot)

`make -C verify/vpu owner-formal` runs Yosys/slang and the built-in SAT engine;
no SMT solver, SBY installation, scalar preset or sim configuration is required.
It compiles the production `rapt_vpu_owner.sv` with `formal_owner.sv`, which keeps
an independent public-interface transaction ledger. The ledger captures commands,
authorization, issue, accepted results and retirement without reading DUT internal
state. Inputs are otherwise unconstrained, including backpressure, changing
unaccepted payloads, early/wrong-tag/duplicate results and subsequent resets.
The only external initial constraint is synchronous reset at the first edge.

Unbounded temporal-induction proofs pass TagBits/CommandBits/ResultBits of
1/8/8, 3/17/29 and 10/160/199. They check admission/busy, matching authorization,
cancellation priority, irrevocable late-kill rejection, exactly one issue/result
lifetime, captured command identity/data, dropped invalid results and held
completion identity/data. Safety includes zero-cycle engine issue plus result.
The runner requires the induction-success marker, not merely a bounded PASS.

For each parameter set, a separate 12-step reachability query produces VCD
witnesses for retirement, cancellation at capture, grant/cancel race, blocked
late kill, completion stall, zero-cycle result, wrong-tag result, duplicate
result, same-tag reuse after retirement, issue stall and reset while busy.
All 33 queries find models. Four copied RTL mutants (early issue, ignoring result
tag, accepting grant during matching kill and overwriting a held response) each
produce a bounded counterexample. Mutants are written only to the build directory;
production RTL is unchanged. This formal-only change was validated with its own
target; earlier simulation/synthesis tables retain their recorded snapshots.

Logs, proof scripts, witness/counterexample VCDs, source fingerprints and the
summary are in `verify/build/vpu/formal-owner/`. These proofs do **not** establish
full-engine VRF/store write safety, arithmetic correctness, response provenance
after exact full-tag reuse, external-memory drain or liveness. Arbitrary permanent
backpressure is allowed, so progress cannot be concluded without environmental
fairness. Tag reuse still requires the existing external drain contract.

## Integrated floating-point divide and square root

The standalone top now accepts `vfdiv.vv`, `vfdiv.vf`, `vfrdiv.vf` and
`vfsqrt.v`. One runtime-precision divider/square-root leaf serves both FP32 and
FP64; the arithmetic and divider request gates are mutually selected through
existing FP start/run states. Common mask/prestart, VRF write and flags-delta
handling is retained. No scalar core integration or ISA advertisement changes
are included.

The decoder exposes the execution class and an explicit second-source usage
bit. Square root requires the reserved `vs1` selector to be zero, uses only
`vs2`, and does not schedule a second VRF operand read. Reverse division maps
scalar/vector operands in architectural order. The leaf remains independently
testable through `make -C verify/vpu divsqrt` with a pinned `SPIKE_BUILD`.

`test_fp_divsqrt_top.h` checks real encodings against explicit bit patterns and
Spike, including all five rounding modes, signed zero, infinity, NaNs, exact
results, inexact division/square root, overflow, underflow and divide-by-zero.
Eight-element LMUL=4 programs vary masks, VL, vstart, policy bits and destination
aliasing. Negative cases cover reserved encodings, FRM, FS and cancellation.
The common driver changes accepted command inputs and stalls completion.

Focused runs use `TOP_SUITE=fp-divsqrt`, isolated build directories and suite
metadata; they are also included in the full suite. The four focused runs below
passed on this source snapshot (seed `243f6a8885a308d3`):

| XLEN / VLEN / ELEN / bank bits / banks | FP cases / negative | Spike steps | Workload hash |
| --- | --- | --- | --- |
| 64 / 128 / 64 / 64 / 2 | 640 / 8 | 2591 | `2f573ee97d8342dd` |
| 32 / 256 / 64 / 64 / 4 | 640 / 8 | 2591 | `a507eb5acb8ca25e` |
| 32 / 128 / 32 / 64 / 1 | 320 / 8 | 1311 | `2a53431c81954147` |
| 64 / 512 / 64 / 128 / 4 | 640 / 8 | 2591 | `1c3b06bcd8a1b6bd` |

The expanded standalone decoder checks pass 630,784 cases for each of ELEN=32
and ELEN=64. Source manifests include the shared scalar divider and the new
encoded test header. Legacy scoped FMA warnings remain as documented above;
the new divider path has no added warning waiver. The previous divider leaf
numerical evidence remains its own snapshot, not a rerun in this integration.

The 53-configuration synthesis check passed with current source fingerprints.
The default XLEN=64/VLEN=128/ELEN=64, 2x64-bit-bank top contains 26,763
word-level cells with operand-read optimization enabled (26,748 disabled),
retaining two synchronous SRAM banks. These are not mapped area or STA results.
The full RV32/VLEN128/ELEN32/one-bank Spike suite passed 206,458 reference steps
(206,477 commands, hash `1efcf390e49ba7ab`).
The default RV64/VLEN128/ELEN64/two-bank `make -C verify/vpu test DIFF=1`
run also passed, including its leaf targets and full top: 311,526 Spike steps,
311,545 commands, hash `a32753682cc11450`, 25,876,136 total cycles. Both full-run
manifests match the tested sources. The VLEN256/512 runs above are focused,
not full-suite reruns. The baseline-vs-optimized timing comparison was not rerun;
no new complete-engine speedup is claimed.

Remaining FP work includes widening arithmetic/FMA, comparisons/min/max/sign/
classification, conversions, reciprocal estimates, FP transfers/slides and FP
reductions. Full ISA legality, core/LSU/MMU integration, full-engine formal
safety and physical performance acceptance remain open.


## Floating-point comparison and classification element foundation (pre-integration snapshot)

`hdl/backend/vpu/rapt_vpu_fp_misc.sv` is a combinational raw-element leaf with
FP32/FP64 elaboration variants. It implements min/max, three sign-injection
operations, classification and six comparisons (eq/ne/lt/le/gt/ge). Comparisons
return a predicate in bit zero; vector mask packing, scalar NaN boxing,
architectural admission/FRM rules and active-element gating remain caller
responsibilities. The leaf is not yet connected to the top or instruction
decoder and does not expand the advertised instruction subset.

Min/max select the numerical operand when only one input is NaN, produce a
canonical NaN for two NaNs, and raise NV only for signaling NaNs. They distinguish
negative and positive zero. Equality/inequality signal only for signaling NaNs;
ordered comparisons signal for any NaN. Inequality returns true for unordered
inputs. Sign injection preserves the payload without raising NV; classification
returns a ten-bit class without exceptions and ignores the second operand.
Reserved operation selectors return illegal with zero result/flags.

Independent `test_fp_misc.cpp` checks SoftFloat comparison and classification
functions from the pinned reference build. Min/max policy is assembled from
SoftFloat classification and quiet ordering. Tests cover all pairs of 32
signed corner patterns, each NaN payload bit against each corner class in both
operand positions, and 100,000 random pairs (including identical and opposite-
sign operands), each across all sixteen selectors. FP32 tests also supply
arbitrary upper halves on the common 64-bit input interface.

Both strict `-Wall` builds and simulations passed with seed
`452821e638d01377`: FP32 1,639,936 checks; FP64 1,669,632 checks. FP32 initially
failed lint on an implicit constant truncation and intentionally unused upper
input halves. The constant now has an explicit width cast, and only the common
input port declarations carry a local unused-signal annotation. No file-wide
or fatal-warning suppression was added.

Reproduce with `make -C verify/vpu fp-misc FMA_DOUBLE=0 SPIKE_BUILD=<pinned-build>`
and repeat with `FMA_DOUBLE=1`. Source and reference manifests are stored under
`verify/build/vpu/fp-misc-{0,1}/`. Top simulation and optimization are not rerun
for this uninstantiated leaf; preceding integrated runs remain historical
snapshots. Integration must still test real encodings, mask destinations,
register overlap, scalar NaN boxes, vstart and suppression of inactive flags.

The updated 55-configuration synthesis sweep passed with current source
fingerprints. The FP32/FP64 miscellaneous leaves contain 105/105 word-level
cells in sweep order (FP64, FP32), no memories and no sequential state. This
is structural evidence, not technology-mapped area or timing.


## Integrated floating-point min/max, sign, class and comparisons

The standalone top now decodes 21 additional instruction forms: `vfmin.vv/vf`,
`vfmax.vv/vf`, `vfsgnj.vv/vf`, `vfsgnjn.vv/vf`, `vfsgnjx.vv/vf`, `vfclass.v`,
`vmfeq.vv/vf`, `vmfne.vv/vf`, `vmflt.vv/vf`, `vmfle.vv/vf`, `vmfgt.vf` and
`vmfge.vf`. The existing raw-element miscellaneous leaves are instantiated per
supported precision and do not launch the iterative arithmetic engines.

The decoder marks FP comparison destinations as masks, so geometry uses one
destination register and the existing narrowing-overlap rules. After element
execution the predicate goes through the mask bit read/modify/write unit;
FFLAGS deltas accumulate when that write completes. Ordinary results use the
existing element write path. `vfclass.v` accepts only the defined unary selector
and does not read a second VRF operand. Reserved FRM values still trap for these
operations, including VL=0 or prestart-only execution, following the existing
conservative admission policy.

`test_fp_misc_top.h` uses ten categorical raw patterns (signed infinities,
normal values, subnormals, zeros and signaling/quiet NaNs), numerical ranks and
explicit class labels as its independent expected-value model. It runs real
encodings through the public owner interface and pinned Spike adapter, checking
all VRF bytes, flags and restart CSR state. Cases vary scalar NaN boxing,
LMUL=1/4, policy bits, masks, vstart, zero VL, source/destination aliasing and
masked comparison destination `v0`. Invalid unary selectors, reserved compare
forms, bad groups/overlaps, FRM, FS and cancellation are also checked.

The focused suite is `TOP_SUITE=fp-misc`, with separate output directories and
manifest suite metadata. It is included in the full suite as well. Both ELEN32
and ELEN64 decoder tests pass 925,696 cases, including legality and operand
provenance. Leaf numerical evidence above remains its original source snapshot.

The following integrated runs passed (seed `243f6a8885a308d3`). Focused entries
are not full-suite results:

| XLEN / VLEN / ELEN / bank bits / banks | Suite | New positive / negative cases | Spike steps | Workload hash |
| --- | --- | --- | --- | --- |
| 64 / 128 / 64 / 64 / 2 | fp-misc | 2268 / 10 | 9111 | `78bba24d38400e6d` |
| 32 / 256 / 64 / 64 / 4 | fp-misc | 2268 / 10 | 9111 | `3662b69b8d351a59` |
| 64 / 512 / 64 / 128 / 4 | fp-misc | 2268 / 10 | 9111 | `05cbab1ec3533901` |
| 32 / 128 / 32 / 64 / 1 | full | 1134 / 10 | 211033 | `9b7cc8559be0b1c0` |
| 64 / 128 / 64 / 64 / 2 | full | 2268 / 10 | 320637 | `4fd99bed3dfd0252` |

The default `make -C verify/vpu test DIFF=1` run passed its leaf targets and
full RV64 suite. Both full-run and all focused-run source manifests match the
current tested sources. Remaining FP families include widening arithmetic/FMA,
conversions, estimates, FP moves/slides and reductions; full ISA legality and
core/LSU/MMU integration are still open.

All 55 synthesis configurations passed with current source fingerprints.
The default RV64/VLEN128/ELEN64/two-bank top contains 26,980 word-level cells
with optimized reads, 26,965 without. The RV32/VLEN128/ELEN32/one-bank top
contains 10,991/10,976 respectively. SRAM organization remains unchanged.
These are structural counts, not mapped area or frequency. No baseline timing
comparison or new complete-engine speedup claim is included.


## FP32-to-FP64 widening arithmetic foundation (pre-integration snapshot)

Two independently testable leaves now support the remaining widening arithmetic
work. `rapt_vpu_fp_widen.sv` expands raw FP32 operands exactly to FP64, including
normalization of subnormals. NaN sign, payload and signaling status are retained
for the consuming arithmetic unit. This is deliberately not an architectural
conversion instruction: converting an sNaN must eventually quiet it and report
NV, whereas prematurely quieting an internal operand could lose that exception.

`rapt_vpu_fp_wide_arith.sv` combines two expanders with the existing FP64
arithmetic/FMA wrapper. It accepts narrow/narrow add, subtract and multiply,
narrow products plus an FP64 FMA addend, and wide/narrow add or subtract.
Independent product/addend sign controls preserve single-rounding fused
semantics. Wide-first-input multiply/FMA shapes and invalid RM values use the
existing illegal held-response path without launching arithmetic. Scalar NaN
boxing, instruction legality and register geometry remain caller responsibilities.

`test_fp_widen.cpp` passed 34,589,484 checks, including every signed FP32
subnormal/zero and every signed NaN payload/infinity, exponent/mantissa boundary
patterns and one million random patterns. Finite results compare exactly with
SoftFloat conversion; NaNs compare independent SoftFloat classification and
payload preservation because reference conversion intentionally quiets sNaNs.
Seed: `be5466cf34e90c6c`.

`test_fp_wide_arith.cpp` passed 267,360 requests and twelve reset boundaries.
The reference converts operands with SoftFloat, retaining conversion NV, then
calls FP64 add/sub/mul or fused multiply-add and compares canonicalized result
and all flags. Tests cover all five rounding modes, both input shapes, four
sign combinations, zeros/subnormals/normals/infinities/NaNs, random inputs,
invalid shapes and RM. Every accepted request is followed by changed operands,
operation, precision selector, signs and RM while busy, plus a three-cycle
response stall. Seed: `c0ac29b7c97c50dd`.

Reproduce with `make -C verify/vpu fp-widen SPIKE_BUILD=<pinned-build>` and
`make -C verify/vpu fp-wide-arith SPIKE_BUILD=<pinned-build>`. Each target records
source and reference manifests. The expander's first strict lint attempt found
an unused normalization leading bit; the implementation now directly stores
only the fraction after removing the implicit leading one, with no waiver.
The wide arithmetic wrapper uses only the previously documented shared-FMA
warning scopes; its own RTL is checked with fatal warnings.

Neither leaf is integrated into the instruction top yet. The standalone
wrapper owns an FP64 datapath for isolated tests; top integration should reuse
the already instantiated FP64 arithmetic unit and select expanded operands,
result precision and widened VRF geometry. Encoded widening instructions,
mask/vstart behavior, EMUL/overlap rules and integration flags remain pending.
No full top simulation or optimization is rerun for these uninstantiated leaves.

The updated 57-configuration synthesis sweep passed with current source
fingerprints. The raw expander contains 38 word-level cells and no sequential
state or memory; the standalone wide arithmetic wrapper contains
15839 cells including its FP64 FMA, with no memories. These counts do not
establish mapped area, frequency or the incremental cost of future top reuse.


## Integrated FP32-to-FP64 widening arithmetic

Eighteen widening forms now execute in the standalone top: `vfwadd.vv/vf`,
`vfwsub.vv/vf`, `vfwadd.wv/wf`, `vfwsub.wv/wf`, `vfwmul.vv/vf`, and the `.vv/vf`
forms of `vfwmacc`, `vfwnmacc`, `vfwmsac`, `vfwnmsac`. They are legal only with
SEW=32 and ELEN>=64 in the current baseline. No FP16 widening or ELEN128 is
implied; all these encodings are rejected in the ELEN32 build.

The FP decoder supplies widening and wide-first-source geometry flags. FMA
retains the entire old FP64 destination, and `.w` forms retain the FP64 first
source while the scalar/vector second source remains FP32. Exact expansion is
selected only for narrow operands. Arithmetic scheduling now selects the unit
by destination element width instead of source SEW, reusing the existing FP64
arithmetic/FMA instance. The standalone wide arithmetic wrapper is not separately
instantiated in the top, avoiding another FP64 execution datapath.

`test_fp_wide_top.h` uses exact integer-valued equations for all eighteen forms,
LMUL=mf2/m1/m2/m4, varying VL, mask, vstart and policy settings. It exercises
legal high-part destination/source overlap and same-width `.w` aliasing.
Directed checks additionally test final FP64 rounding with a tiny FP32 product,
sNaN flags, invalid scalar NaN boxing and the exact product of two maximum
finite FP32 values. Five rounding modes and inactive-element suppression are
covered. Negative cases reject unsupported SEW/ELEN, oversized destination
EMUL, misalignment, unsafe overlap, FRM, FS and cancelled ownership.

Focused execution uses `TOP_SUITE=fp-wide`, isolated output paths and suite
metadata, and the same test is part of the full suite. Both standalone decoder
variants pass 1,146,880 legality/operand-provenance checks. FP64 source and old
addend upper halves are explicitly checked in the decode oracle. Existing
leaf arithmetic numeric results remain their preceding source snapshots.

Focused Spike results (seed `243f6a8885a308d3`):

| XLEN / VLEN / ELEN / bank bits / banks | Positive / negative | Spike steps | Workload hash |
| --- | --- | --- | --- |
| 64 / 128 / 64 / 64 / 2 | 512 / 81 | 2283 | `7aab7507f3be3f84` |
| 32 / 128 / 32 / 64 / 1 | 0 / 81 | 315 | `9f70f0b4777d49cd` |
| 64 / 512 / 64 / 128 / 4 | 512 / 81 | 2283 | `dac6421df0dbda99` |

These focused manifests match the tested source snapshot; the ELEN32 row
checks rejection only and does not claim FP64 arithmetic support.

The default RV64 `make -C verify/vpu test DIFF=1` run passed its leaf targets
and full top: 322,920 Spike steps, 322,949 commands, hash `a6b44e65779fc7ba`,
27,155,869 total cycles. Its source manifest matches the tested snapshot.
The full RV32/VLEN256/ELEN64/four-bank Spike run also passed with current
source fingerprints: 323,724 reference steps, 323,753 commands, hash
`a9e7451ed7694954`. This run executes the positive widening cases, unlike the
ELEN32 rejection-only focused run.
All 57 synthesis configurations passed with current source fingerprints.
Default RV64/VLEN128/ELEN64/two-bank top counts are 27,092 optimized-read cells
and 27,077 baseline cells, retaining the existing two SRAM banks. This is
112 word-level cells above the preceding integrated miscellaneous-FP snapshot,
not mapped area or a frequency estimate. No timing optimization comparison was
rerun. Conversions, estimates, FP transfers/slides and reductions, full ISA
legality and real core/LSU/MMU integration remain open.



## Floating-point format-conversion element foundation (pre-integration snapshot)

`rapt_vpu_fp_convert.sv` provides independently testable raw FP32-to-FP64
and FP64-to-FP32 conversions with held responses and reset cancellation. It
reuses the exact operand expander for widening, adding architectural canonical
NaN and signaling-NaN NV handling. Narrowing reuses
`rapt_fpu_convert_narrow.sv`; only its unused scalar configuration include was
removed, with no arithmetic changes.

The element interface accepts RM=0..4 and an internal RM=6 selector for
narrowing round-to-odd. RM=6 is not a valid architectural FRM value; a future
instruction decoder must distinguish the explicit ROD opcode from FRM legality.
Odd narrowing requests run the existing converter with round-toward-zero and
jam the retained result's low bit when NX is set, retaining OF/UF/NX flags.
Widening rejects odd and other reserved selectors. Scalar NaN boxing is not
applied to raw vector inputs. Both result precisions use a common 64-bit output,
with zero high bits for FP32.

`test_fp_convert.cpp` passed 309,856 requests and twenty reset boundaries with
seed `3f84d5b5b5470917`. It compares independent SoftFloat conversions for every
FP64 exponent, seven significand/rounding boundaries, both signs and all eight
RM selectors; FP32 exponent/class boundaries and 60,000 random requests are
also covered. Tests change operands, direction and RM after acceptance, offer
another request while busy, and stall every response for three cycles.

The initial odd-reference test passed internal selector 6 directly to
SoftFloat. The pinned library's `softfloat_round_odd` enum is 5, so that test
incorrectly expected truncation for the smallest subnormal. The test now maps
to the named enum. No reference-library modification or rebuild was required,
and DUT odd behavior was unchanged. The first strict lint attempt also found
the scalar converter's intentionally discarded upper NaN-box bits; a local
unused-signal annotation covers only that result declaration.

Reproduce with `make -C verify/vpu fp-convert SPIKE_BUILD=<pinned-build>`.
Current DUT/test and pinned-library manifests are recorded under
`verify/build/vpu/fp-convert/`. The leaf is not yet decoded by the vector top;
encoded conversions, destination EEW/EMUL, overlap, active-element suppression,
and integer/FP conversion families remain pending. No full top simulation or
optimization result is inferred from this leaf-only change.

The original scalar regression `make -C verify/xsim/fpu/convert run N=10000`
also passed 10,000 cases with zero failures (578 NaN cases). That legacy runner
uses broad warning suppression and tolerates NaN payload differences; it is
supplementary regression evidence, not a strict-lint or vector-conformance claim.

The 58-configuration synthesis sweep passed with current source
fingerprints. The conversion leaf contains 814 word-level cells and no memory.
These counts are not technology-mapped area or STA results.



## Integrated floating-point format conversions

`vfwcvt.f.f.v`, `vfncvt.f.f.w` and `vfncvt.rod.f.f.w` now execute in the
standalone top for SEW=32 and ELEN>=64. Conversion selectors are decoded as
unary operations, so no encoded `vs1` register is read. Widening uses FP32 source
and FP64 destination geometry; narrowing reads the full FP64 source and writes
FP32 elements through the existing narrow-overlap rules.

The converter shares the FP start/run completion path with existing engines,
with mutually selected requests and results. An ELEN32 top omits the conversion
instance and rejects these encodings. The explicit ROD selector maps to internal
rounding mode 6 only after the architectural FRM legality check, so invalid FRM
still traps even for the ROD instruction or VL=0. No scalar NaN-box checks are
applied to raw vector sources. Flags accumulate through the existing active-
element write completion path.

`test_fp_convert_top.h` checks explicit bit patterns and pinned Spike for all
three encodings, all five legal FRM values, LMUL=mf2/m1/m2/m4, policy bits,
varying masks, prestart, VL=0/1/max and legal aliasing. Positive overlap tests
cover the high source part for widening and low destination part for narrowing.
Patterns include two halfway cases, tiny inexact results, overflow, sNaN/qNaN,
signed zero, exact values and infinities. Negative tests cover SEW/ELEN, EMUL,
alignment, unsafe overlap, reserved forms, FS, FRM and cancellation, including
invalid FRM with VL=0. The test is both in the full suite and available through
isolated `TOP_SUITE=fp-convert` runs with suite metadata.

Both ELEN32/ELEN64 decoder variants pass 1,220,608 legality and operand-map
checks. Narrowing operand checks preserve the FP64 upper half while widening
checks preserve raw FP32 input. Prior leaf numerical tests retain their own
source snapshots; no independent leaf rerun is implied by integration tests.

The initial ELEN32 top lint run rejected `fp_odd` as unused after its conversion
instance was omitted. Only that control declaration now has a local unused-
signal annotation explaining the parameter condition. No execution logic was
changed by this fix. Final acceptance runs below use this final source snapshot;
earlier pre-annotation runs are not substituted for current-source evidence.

Final-source results (seed `243f6a8885a308d3`):

| XLEN / VLEN / ELEN / bank bits / banks | Suite | Conversion positive / negative | Spike steps | Workload hash |
| --- | --- | --- | --- | --- |
| 32 / 128 / 32 / 64 / 1 | fp-convert | 0 / 33 | 129 | `d58afeb41af26044` |
| 32 / 256 / 64 / 64 / 4 | fp-convert | 480 / 33 | 2049 | `2c276f1b2425f92d` |
| 64 / 512 / 64 / 128 / 4 | fp-convert | 480 / 33 | 2049 | `12c2a0e624075642` |
| 32 / 128 / 32 / 64 / 1 | full | 0 / 33 | 211477 | `b708a28cbbc8a9df` |
| 64 / 128 / 64 / 64 / 2 | full | 480 / 33 | 324969 | `3eef446011b5e3a2` |

The final RV64 `make -C verify/vpu test DIFF=1` run passed its leaf targets
and full top. All final full/focused source manifests match the tested sources.
The 58-configuration synthesis sweep passed with current source fingerprints.
The default RV64/VLEN128/ELEN64/two-bank top contains 27,892 optimized-read
word-level cells (27,877 baseline), retaining its two SRAM banks. ELEN32 omits
the conversion engine and its default one-bank top contains 11,123/11,108 cells.
These are structural counts, not mapped area or STA. No new complete-engine
optimization measurement is claimed. Integer/FP conversions, estimates, FP
moves/slides and reductions, complete legality audit and real core/LSU/MMU
integration remain open.



## Integer/FP conversion element foundation

`rapt_vpu_int_fp.sv` is an independent bidirectional conversion wrapper with
`FloatDouble=0/1` and supported `IntBits=16/32/64`. Widths are independent of
XLEN. It reuses the scalar integer-to-FP and FP-to-integer pipelines, adds raw
vector operand/result handling, and captures direction and signedness for held
responses. RM=0..4 is accepted; reserved selectors return illegal without
launching either arithmetic engine. Instruction-level RTZ/FRM selection and
EEW/EMUL legality belong to the instruction decoder and geometry checker.

Signed/unsigned integer sources are extended from the configured integer width.
FP32 sources are boxed internally for the scalar converter, and integer/FP32
results are zero-extended raw vector elements. FP-to-integer16 first uses the
scalar 32-bit conversion and then checks the narrower mathematical range. A
range failure clips to the specified limit and returns NV with NX cleared;
negative unsigned values which round to zero keep the scalar converter's valid
inexact behavior. This supports the required FP32/integer16 boundary for
narrowing/widening instructions. The leaf's extra FP64/integer16 combination is
tested as a generic component configuration, not an advertised RVV encoding.

Two shared scalar sources lost unused configuration includes. Strict lint also
identified unused fraction/retained/rounded high bits; those declarations and
casts now use the actual floating-point precision. The intended arithmetic,
rounding and exception semantics are unchanged. Existing scalar regressions
and all new width combinations were rerun after these changes; no new lint
waivers were introduced for the wrapper or these shared converters.

Independent SoftFloat testing in `test_int_fp.cpp` passed:

| FloatDouble | IntBits | Requests | Reset boundaries |
| --- | --- | --- | --- |
| 0 | 16 | 111200 | 20 |
| 0 | 32 | 111200 | 20 |
| 0 | 64 | 111200 | 20 |
| 1 | 16 | 397920 | 20 |
| 1 | 32 | 397920 | 20 |
| 1 | 64 | 397920 | 20 |

Seed `9216d5d98979fb1b`. Tests sweep every FP exponent, fraction boundaries,
signs, signed/unsigned integer semantics and all RM selectors; integer power-
of-two boundaries and 60,000 random requests per configuration are included.
FP32-to-integer16 uses SoftFloat's dedicated functions; the generic FP64-to-
integer16 oracle uses a 64-bit SoftFloat conversion then mathematical range
checks, independently of the DUT's 32-bit intermediate. Every response stalls
for three cycles while request metadata changes and another request is offered.
Reset tests reject late results in both directions.

Reproduce with `make -C verify/vpu int-fp FMA_DOUBLE=<0|1> INT_BITS=<16|32|64>
SPIKE_BUILD=<pinned-build>` on one command line. Each configuration records
source and reference manifests. Original scalar tests
`make -C verify/xsim/fpu/int_to_fp run N=10000` and
`make -C verify/xsim/fpu/fp_to_int run N=10000` each passed 10,000 cases with zero
failures. Their broad warning suppression makes them supplementary evidence,
not the strict-lint claim established by the new standalone builds.

At this foundation snapshot the leaf was not yet decoded by the vector top;
encoded instruction integration and current top evidence are recorded below.
Full VPU simulation and optimization were not rerun for that uninstantiated
leaf snapshot; prior integrated results remain their own source snapshots.

The foundation's 64-configuration synthesis sweep passed with source fingerprints.
The new leaf has no memories; its word-level cell counts are:

| FloatDouble | IntBits | Cells |
| --- | --- | --- |
| 1 | 16 | 1178 |
| 1 | 32 | 1164 |
| 1 | 64 | 1161 |
| 0 | 16 | 975 |
| 0 | 32 | 961 |
| 0 | 64 | 958 |

These are structural counts, not mapped area, STA or vector throughput results.


## Integer/FP instruction integration

The top now routes all 18 same-width, widening and narrowing integer/FP
conversion selectors through a dedicated stateless decoder. It validates FP32/
FP64 and integer16/32/64 operand widths independently of scalar XLEN. Integer16
is supported only with FP32 in the ISA width pairs; unsupported FP16 and EEW
above ELEN remain illegal. Explicit RTZ overrides valid FRM values but does not
admit reserved FRM values. Existing geometry checks enforce operand group
alignment, effective LMUL and overlap before execution.

Five fixed-width conversion instances cover FP32/I16, FP32/I32, FP32/I64,
FP64/I32 and FP64/I64. ELEN32 elaborates only the first two. The scheduler reads
raw source elements with the source EEW, writes using the destination EEW and
accumulates flags only for executed elements. It shares the existing ownership,
mask, restart and completion paths. This initial pool favors separately verified
numeric blocks; sharing the conversion pipelines across width pairs remains an
area optimization opportunity, not a measured optimization claim.

The dedicated decoder passed 2,359,296 cases for each of ELEN32 and ELEN64.
`test_int_fp_top.h` is included in both the full suite and `TOP_SUITE=int-fp`.
Its portable oracle covers exact integers, signed/unsigned half-way rounding,
FP precision boundaries, infinities, quiet/signaling NaNs and finite integer16
clipping (including valid unsigned zero after rounding negative fractions).
It also checks masked/prestart elements, zero VL, legal narrowing/high-part
widening overlap, fractional/integer LMUL, illegal widths/control states and
pre-authorization cancellation. Spike independently checks the encoded commands,
full vector state, flags and traps.

Reproduce the focused instruction tests with:

```sh
make -C verify/vpu top TOP_SUITE=int-fp DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
make -C verify/vpu top TOP_SUITE=int-fp DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=32 ELEN=32
make -C verify/vpu int-fp-decode ELEN=32
make -C verify/vpu int-fp-decode ELEN=64
```

The final focused source snapshot passed the following instruction-level runs
on 2026-09-05. All use seed `243f6a8885a308d3`, `OptimizeOperandReads=1`, and
the separately fingerprinted Spike reference. Each ELEN64 run includes 3,480
positive conversion commands and 174 negative/cancellation checks; ELEN32
includes 1,320 and 102 respectively. Other commands configure and inspect state.

| XLEN / VLEN / ELEN / BankBits / Banks | Executed Spike commands | Workload hash |
| --- | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 14298 | `137c9211f41dacf8` |
| 32 / 128 / 32 / 64 / 2 | 5352 | `0d625e04d11aeb3f` |
| 32 / 256 / 64 / 64 / 4 | 14298 | `83187feb3581f8d9` |
| 64 / 512 / 64 / 128 / 4 | 14298 | `36f915b9870c3f94` |

Full `make -C verify/vpu test DIFF=1 SPIKE_BUILD=...` also passed at this
snapshot for the two configurations below (the second adds `XLEN=32 ELEN=32
BANKS=1`). Each top manifest fingerprints 67 DUT/test/build files; the hashes
were checked against the final sources after completion.

| XLEN / VLEN / ELEN / BankBits / Banks | Commands | Executed Spike commands | Total cycles | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 339329 | 339267 | 28882372 | `2a12bdf2fe20daef` |
| 32 / 128 / 32 / 64 / 1 | 216873 | 216829 | 19467754 | `8f71b4af7ea0e651` |

The full tests retain earlier integer, memory, permutation and FP families and
add the new conversion suite. The integer-only measurement window remains
65,450 cycles in the RV64 optimized run; it is not a conversion throughput
measurement or a new baseline/optimized comparison. No scalar-core regression,
full-engine formal proof, physical mapping or OS test was run for this
standalone-top integration.

The 66-configuration structural synthesis sweep passed with matching source
fingerprints, no latches/unexpected blackboxes and the expected synchronous
1RW SRAM capacity. Optimized top word-level cell counts are 32,585 for
64/128/64/64/2; 13,122 for 32/128/32/64/1; 32,653 for 32/256/64/64/4;
and 32,787 for 64/512/64/128/4. These are not mapped area, timing or throughput
measurements. The newly instantiated conversion pool has not yet been optimized
for arithmetic sharing. Full-engine formal, actual scalar/LSU integration,
remaining FP instruction families and full V compliance remain outstanding.

## Reciprocal estimate element foundation

`rapt_vpu_fp_estimate.sv` implements both `vfrec7` and `vfrsqrt7` element
semantics with `Double=0/1`. It is a stateless combinational leaf, independent
of XLEN, VLEN, scalar packages and register storage. Inputs and outputs are raw
vector bits; unused FP32 upper bits are ignored and output upper bits are zero.
The caller owns masking, instruction legality and accumulation of flags.

The two 128-entry lookup functions contain the normative tables from
[vfrec7.adoc](https://raw.githubusercontent.com/riscvarchive/riscv-v-spec/master/vfrec7.adoc)
and [vfrsqrt7.adoc](https://raw.githubusercontent.com/riscvarchive/riscv-v-spec/master/vfrsqrt7.adoc).
A leading-bit encoder normalizes nonzero subnormals, retaining only the seven
fraction bits consumed by the lookup. Exponent parity additionally selects the
reciprocal-square-root interval. Reciprocal output denormalization preserves
the implied leading bit. Ordinary estimates do not raise NX or UF merely
because they are approximations. Reciprocal overflow returns infinity or the
largest finite value according to sign/RM, with OF|NX. Signed zero returns
signed infinity with DZ; signaling NaNs and negative nonzero reciprocal-square-
root inputs return canonical NaN with NV. Quiet NaNs are canonicalized without
NV. Reserved RM=5..7 returns illegal with zero result/flags at the leaf boundary.

`test_fp_estimate.cpp` compares against the separately fingerprinted Spike
SoftFloat `f32/f64_recip7` and `f32/f64_rsqrte7` functions. It covers every
exponent and lookup interval at both endpoints, both signs and all eight RM
selectors; every possible subnormal leading-bit position; 200,000 random
patterns per precision; and malformed scalar-style boxing on raw FP32 inputs.
Four FP32 examples also check literal expected results from the specification,
independently of the reference calls.

```sh
make -C verify/vpu fp-estimate FMA_DOUBLE=0 SPIKE_BUILD=/path/to/pinned/spike
make -C verify/vpu fp-estimate FMA_DOUBLE=1 SPIKE_BUILD=/path/to/pinned/spike
```

The final leaf snapshot on 2026-09-05 passed 2,645,572 FP32 and 17,403,200
FP64 comparisons with seed `7e915cd21647ab39`. Strict `-Wall` builds use no
blanket warning suppression; the only unused-bit annotation identifies raw
FP32 upper operand bits. Both leaf manifests match the final sources.

The expanded structural synthesis sweep passed all 68 configurations with
matching source fingerprints. The estimate leaves contain 75 (FP32) and 104
(FP64) word-level cells, respectively, including two fully initialized 128x7
combinational ROM cells per precision. Each ROM has one unclocked read port and
no write port; initialization contains no unknown bits. No flops or latches
were inferred in either estimate leaf. These counts include ROM cells and are
not technology-mapped area or STA. Top behavior is unchanged because this leaf
is not instantiated there; the earlier full-top functional results remain their
own source snapshots.

At this foundation snapshot the instruction selectors were not yet connected
to the top. The integration and current encoded-instruction evidence follow
below. Prior PASS records remain source snapshots; no full V claim follows
from the leaf tests.

## Reciprocal estimate instruction integration

The FP decoder now admits OP-FVV funct6=0x13 with selector 5 (`vfrec7.v`)
or 4 (`vfrsqrt7.v`) as unary, same-width vector operations. Scalar forms,
unsupported SEW, disabled FS/VS and reserved FRM remain illegal. The decoder
excludes these operations from mask-result handling and suppresses vs1/old-vd
reads. The stateless estimate leaf is instantiated per supported FP precision
and selected through the existing miscellaneous-result path. Existing element
writes, mask/vstart checks, group/overlap checks, completion ownership and flags
accumulation are retained.

`test_estimate_top.h`, included in both the full suite and `TOP_SUITE=estimate`,
uses a portable directed oracle plus independent Spike command comparison.
It covers signed zeros/infinities, quiet/signaling NaNs, positive/negative normal
values, minimal subnormals, maximal finite values and minimal normals; all five
rounding modes; fractional/integer LMUL; four tail/mask policy combinations;
zero VL, prestart/all-masked suppression, same-source/destination overlap,
illegal encodings/control/group states and authorization cancellation. Ordinary
estimates produce no NX; active reciprocal overflow produces OF|NX, zero
produces DZ and invalid reciprocal-square-root inputs produce NV. Masked and
prestart inputs do not contribute those flags.

The expanded FP decoder tests pass 1,335,296 cases for each of ELEN32 and
ELEN64. Reproduce the instruction tests with:

```sh
make -C verify/vpu top TOP_SUITE=estimate DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
make -C verify/vpu top TOP_SUITE=estimate DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=32 ELEN=32
```

Focused instruction runs on the final top sources pass the following matrix,
with seed `243f6a8885a308d3` and `OptimizeOperandReads=1`. Each ELEN64 run
executes 400 positive estimate commands; ELEN32 executes 160. Each also includes
18 negative/cancellation checks. Remaining commands configure or inspect state.

| XLEN / VLEN / ELEN / BankBits / Banks | Executed Spike commands | Workload hash |
| --- | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 1670 | `988cb898d6e8514e` |
| 32 / 128 / 32 / 64 / 2 | 710 | `2b3c35da2a0730b2` |
| 32 / 256 / 64 / 64 / 4 | 1670 | `8c9d60585bb17db5` |
| 64 / 512 / 64 / 128 / 4 | 1670 | `21628cb7f30c7706` |

Synthesis distinguishes the estimate's constant ROMs from the VRF's writable
SRAMs. It checks known ROM initialization, 128x7 shape, unclocked lookup ports
and the expected number of reads for the supported precisions. The original
VRF checks still require exactly one synchronous read/write port per bank and
exactly `32*VLEN` writable data bits. Constant ROM capacity is not counted as
architectural vector storage.

The complete top suite (`make -C verify/vpu top DIFF=1 SPIKE_BUILD=...`)
passes the following final source snapshot on 2026-09-05. The second command
adds `XLEN=32 ELEN=32 BANKS=1`. All 69 top-source manifest entries match the
current DUT/test sources after execution.

| XLEN / VLEN / ELEN / BankBits / Banks | Commands | Executed Spike commands | Total cycles | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 341001 | 340937 | 29054509 | `841605974033064c` |
| 32 / 128 / 32 / 64 / 1 | 217585 | 217539 | 19542333 | `cb6635b13c03dc89` |

All 68 structural synthesis configurations pass with final source fingerprints.
Optimized top word-level cell counts are 32,747 for 64/128/64/64/2;
13,209 for 32/128/32/64/1; 32,815 for 32/256/64/64/4; and 32,949 for
64/512/64/128/4. ELEN64 tops include four estimate ROMs and ELEN32 tops two,
in addition to their unchanged VRF SRAM banks. The integer-only optimized
measurement window remains 65,450 RV64 cycles; this is not a measured estimate
throughput improvement. Technology mapping, STA, full-engine formal and actual
scalar-core/LSU integration were not run for this instruction integration.
Remaining FP transfer/permutation/reduction families and the full instruction-
legality audit are still pending, as are the broader acceptance gates below.

## Floating-point transfer/routing foundation

`rapt_vpu_fp_transfer.sv` independently admits and routes six transfer forms:
`vfmerge.vfm`, `vfmv.v.f`, `vfmv.f.s`, `vfmv.s.f`, `vfslide1up.vf` and
`vfslide1down.vf`. The leaf is combinational and depends only on the existing
stateless slide router. ELEN and VLEN are parameters; scalar floating-point
width is explicitly FLEN=64 and does not depend on integer XLEN. It rejects
unsupported FP16/FP64 widths, illegal forms/reserved source fields, masked
scalar moves, disabled FP/vector state, VILL and reserved FRM values.

The interface separates vector writes from scalar FPR writes and returns raw
source/destination element indices. Merge uses the mask as a source selection,
not as write suppression. Broadcast requires the reserved vs2 field to be zero.
Extraction always reads element zero, including VL=0 and vstart>=VL, and boxes
FP32 into a 64-bit FPR result without changing the raw NaN payload. Insertion
writes only destination element zero when vstart<VL. Both scalar moves ignore
LMUL grouping and must be scheduled once per instruction rather than once per
element. Vector slide1 operations reuse the tested slide router and insert the
scalar only at their respective endpoint when that endpoint is active.

FP32 scalar inputs with invalid NaN boxing become canonical NaN; valid scalar
and raw vector payloads (including signaling NaNs) are copied without arithmetic
or FP exceptions. The caller still owns group alignment/overlap, source VRF
reads, scalar FPR writeback, state dirty events, successful vstart reset and
instruction ownership. Upward slide overlap must be rejected by that caller.

`test_fp_transfer.cpp` uses an independent six-row match/mask encoding oracle,
an integer coordinate model and explicit scalar/vector bit handling. Tests
sweep opcode/funct/form/mask/register fields, every type/FRM/enable combination,
VL/vstart/index boundaries and 200,000 random data/routing patterns per
configuration. The reference does not call the DUT slide implementation.

```sh
make -C verify/vpu fp-transfer ELEN=32
make -C verify/vpu fp-transfer ELEN=64
make -C verify/vpu fp-transfer ELEN=64 VLEN=256
make -C verify/vpu fp-transfer ELEN=64 VLEN=512
```

The final standalone snapshot on 2026-09-05 passes 4,432,704 cases in each
of ELEN/VLEN=32/128, 64/128, 64/256 and 64/512, with seed
`416c9fa3d72805be`. Random precision selection is independent of the operation
selector, and both source and destination register identities are varied.
All four final leaf manifests match the current source files. Strict `-Wall`
builds use no blanket warning suppression; the input instruction annotation
only excludes register bits consumed by the caller rather than this leaf.

The 72-configuration synthesis sweep passes with matching source fingerprints.
The transfer leaf has 113 word-level cells at ELEN32/VLEN128 and 115 at the
three ELEN64/VLEN128/256/512 configurations. It has no memories, flops or latches.
These are structural counts, not mapped area or timing. The scalar core and
standalone top are unchanged by this uninstantiated leaf; no full-top functional
regression, new owner proof or OS test is claimed for this foundation snapshot.

At this foundation snapshot, top integration and the scalar FPR completion
interface were pending. The following section records the subsequent connection,
encoded instruction tests and updated owner proof. Leaf tests alone do not
establish those integration properties.

## Floating-point transfer instruction integration

All six FP transfer forms now use `rapt_vpu_fp_transfer` through three dedicated
route/read/response states. Vector operations share existing group checks,
mask fetches, VRF writes and sequential completion. Broadcast does not claim a
vector source, merge treats v0 as a data choice, and slide-up rejects source/
destination overlap. Scalar moves bypass vector group alignment, target element
zero and execute once; insertion exits after one write, while extraction runs
even at zero VL or vstart>=VL. These operations copy raw values and generate no
FP exception flags.

The held completion payload now includes `rsp_fp_write` and the 64-bit
`rsp_fp_result`. When `rsp_fp_write=1`, `rsp_rd` identifies an FPR (including
f0), `rsp_result=0` and the consumer must not write a GPR. Otherwise the scalar
result contract is unchanged and the unused FP result is zero. All metadata is
captured and held by the owner, not read live from command inputs. A production
SVA checks that an FPR completion is nontrapping, FP-dirty and has zero GPR data.
This extends the standalone interface; a real scalar-core FPR/ROB adapter is
still pending.

The common command driver compares actual Spike FPR results, checks the FPR
write kind independently from the DUT using the instruction encoding, and
holds every completion for four cycles while checking the new fields. Tests
cover f0/f31, full 64-bit results on RV32, preserved NaN payloads, valid/invalid
scalar NaN boxing, scalar registers with odd indices under large LMUL, vector
aliases, zero VL and vstart below/at/above VL. Illegal type/rounding/control
states, reserved source fields, masked scalar encodings, vector alignment,
slide-up overlap and pre-authorization cancellation are also included.

```sh
make -C verify/vpu top TOP_SUITE=transfer DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
make -C verify/vpu top TOP_SUITE=transfer DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=32 ELEN=32
python3 verify/vpu/owner_formal.py --build-dir verify/build/vpu/formal-owner-transfer
```

Owner proof now covers TagBits/CommandBits/ResultBits = 10/164/174 (RV32)
and 10/228/270 (RV64), plus the original two small control configurations.
All four inductive safety proofs, 44 reachable event witnesses and four RTL
mutation detections pass. The proof covers opaque payload preservation and
ownership; it does not prove full-engine VRF/FPR architectural correctness,
external drain, full-tag reuse provenance or unconditional liveness.

The final focused transfer tests pass with seed `243f6a8885a308d3` and
`OptimizeOperandReads=1`. ELEN64 runs contain 540 positive transfer commands;
ELEN32 contains 240. Each also contains 58 negative/cancellation checks.

| XLEN / VLEN / ELEN / BankBits / Banks | Executed Spike commands | Workload hash |
| --- | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 2366 | `27e4ed521835e82a` |
| 32 / 128 / 32 / 64 / 2 | 1166 | `9a23e484abeb2326` |
| 32 / 256 / 64 / 64 / 4 | 2366 | `d352afcbbdf06df2` |
| 64 / 512 / 64 / 128 / 4 | 2366 | `bc1876d32fef347d` |

The complete top suite also passes on the final transfer-integrated sources
(`make -C verify/vpu top DIFF=1 SPIKE_BUILD=...`; the RV32 run adds
`XLEN=32 ELEN=32 BANKS=1`). The 71-file top manifests and updated owner proof
manifest were checked against current sources after completion.

| XLEN / VLEN / ELEN / BankBits / Banks | Commands | Executed Spike commands | Total cycles | Workload hash |
| --- | ---: | ---: | ---: | --- |
| 64 / 128 / 64 / 64 / 2 | 343373 | 343303 | 29300868 | `2a03b07a4ca75008` |
| 32 / 128 / 32 / 64 / 1 | 218757 | 218705 | 19669659 | `dcb4770a4f87407e` |

All 72 synthesis configurations pass with current source fingerprints. Optimized
top word-level cell counts are 32,919 for 64/128/64/64/2; 13,381 for
32/128/32/64/1; 32,987 for 32/256/64/64/4; and 33,121 for
64/512/64/128/4. The original writable VRF capacity and estimate ROM checks
continue to pass. These results do not establish mapped area, timing or a new
throughput optimization; the integer-only RV64 measurement remains 65,450
cycles. FP reductions, the full instruction-legality audit, full-engine formal,
real scalar/LSU/MMU integration and system-level acceptance remain pending.

## Floating-point reduction stream foundation

`rapt_vpu_fp_reduce.sv` accepts a seed, element count, operation, source precision,
widening control and FRM, then consumes one stream entry for each element.
Inactive entries consume count but perform no arithmetic. Operation 0 sums in
increasing element order; 1/2 implement min/max. This ordered summation is also
a permitted implementation of unordered RVV summation. Widening is accepted
only for FP32 source sum into FP64; the seed is already at destination precision.
ELEN32 excludes FP64 and widening. Reserved operation/RM and unsupported width
combinations complete as illegal without consuming any stream entries.

Command metadata is captured at acceptance. The caller must deliver exactly
`count` ready/valid entries in element order, including inactive mask entries.
A zero count completes with `write_result=0` and zero flags. Nonempty streams
with no active entries return the raw seed with `write_result=1`, preserving
NaN payload/signaling state and raising no exception. Active results accumulate
flags after each accepted numeric result; the final result, flags, illegal and
write indication remain stable until completion acceptance. The caller owns
VRF reads, register-group/overlap legality, instruction authorization, destination
write and vstart/dirty updates. In particular, instruction-level reduction
vstart restrictions are not implemented by this numeric stream interface.

The independent SoftFloat test uses per-element addition/conversion references,
quiet comparisons plus explicit NaN/signed-zero min/max rules, and a separate
running accumulator. It covers zero/all-masked/mixed masks; infinities, NaNs,
subnormals and overflow; all rounding modes; command input mutation while busy;
producer gaps and delayed readiness; four-cycle held completions; invalid
requests; 20,000 randomized commands; and counts across 255/256, 511/512 and
1023. Reset-age sweeps check that partial streams and in-flight arithmetic do
not produce a result after reset.

```sh
make -C verify/vpu fp-reduce ELEN=32 SPIKE_BUILD=/path/to/pinned/spike
make -C verify/vpu fp-reduce ELEN=64 SPIKE_BUILD=/path/to/pinned/spike
```

The final standalone tests pass 32,975 commands with 32 reset boundaries at
ELEN32 and 33,005 commands with 96 reset boundaries at ELEN64. Both use
CountBits=10 and seed `34d59127b6e80fac`. The two 12-file leaf manifests match
the final sources. Strict RTL lint uses the existing scoped scalar-FMA waivers;
no new blanket suppression was introduced for the reduction engine.

The expanded 74-configuration structural synthesis sweep passes with matching
source fingerprints. With CountBits=10, reduction word-level cell counts are
7,145 at ELEN32 and 22,445 at ELEN64, with no memories. These counts include
the private numeric datapaths and are not mapped area or STA. The scalar core
and standalone top behavior were not changed by this uninstantiated module;
full-top functional regression and new owner proofs were not rerun for this
foundation snapshot.

The standalone numeric wrapper instantiates its own FP arithmetic pool. Its
structural cost makes arithmetic sharing a priority before top integration:
separate the stream control from the numeric service, then connect sum requests
to the existing top FP datapath with explicit ownership/backpressure. The
current standalone test remains the numerical baseline for that change.
No encoded FP reduction, shared-arithmetic integration or full V conformance is
claimed by these stream tests. Prior top results remain their source snapshots.

## Floating-point reduction control/service split

The reduction stream now resides in `rapt_vpu_fp_reduce_control.sv`.
Its numeric service carries operation (sum/min/max), destination precision,
rounding mode, accumulator and captured source operand. It permits one
outstanding request, holds request metadata under backpressure, and accepts
either a same-cycle response or a later response. Masked elements issue no
numeric request. A service error suppresses destination write and terminates
the stream; completion metadata remains held until accepted.

The service has no transaction identity. Its response must belong to the
accepted request, and the integration must reset or drain the numeric service
with the controller before reuse. Ignoring a response while idle does not prove
that an old response cannot alias a later operation.

`rapt_vpu_fp_reduce.sv` retains its public stream interface as the independent
numeric wrapper. Its private FP32/FP64 adders use the service handshake;
combinational min/max returns on the acceptance cycle. Active min/max now
takes an additional issue cycle compared with the original direct FEED update.
This change enables sharing; it does not yet reduce the wrapper's private
arithmetic resources or connect encoded reductions to the top.

Validation for the split:
- ELEN32: 32,975 numerical commands and 32 reset boundaries.
- ELEN64: 33,005 numerical commands and 96 reset boundaries.
- Each ELEN additionally passes 768 mock-service requests spanning all three
  operations, request stalls of 0–7 cycles, response delays of 0–7 cycles,
  masked entries, held completions, 192 injected error commands and two reset
  boundaries. This test checks the controller contract independently of FP math.
- Builds enable assertions and strict RTL warnings with the existing scoped
  FMA waivers in the numerical wrapper.

The completed split synthesis snapshot passes 76 configurations with matching
recorded source fingerprints. At CountBits=10, the control alone contains 92
word-level cells for ELEN32 and 129 for ELEN64; the complete numerical wrappers
contain 7,138 and 22,437 respectively. These are structural counts, not mapped
area or timing. This snapshot precedes the following new decoder module.

### Floating-point reduction encoding admission

`rapt_vpu_fp_reduce_decode.sv` recognizes the six RVV 1.0 encodings for ordered/
unordered single-width sums, min/max and ordered/unordered widening sums.
It checks VS/FS enable, vill, supported SEW and resolved FRM. Outputs identify
the reduction operation, source precision, widening and the ordered-sum encoding;
all execution outputs are inert for illegal requests. Both sum encodings may
use the existing ordered stream implementation.

This decoder deliberately leaves LMUL/source-group geometry, VL and nonzero
vstart checks to its caller. Seed and destination are scalar elements, so their
register numbers must not be rejected by ordinary vector destination alignment
or overlap checks. The future sequencer must finish reading inputs and masks
before writing a potentially overlapping destination, including v0.

ELEN32 and ELEN64 each pass 311,296 independent encoding/control cases,
including all funct6/funct3 values, SEW and FRM encodings, enable/vill combinations,
both mask encodings, all opcode values and varied register fields. The decoder
is not yet instantiated in the instruction top; no encoded reduction execution
or new top-level differential pass is claimed. The default standalone test now
includes both reduction control and reduction decoder tests.

```sh
make -C verify/vpu fp-reduce-decode ELEN=32
make -C verify/vpu fp-reduce-decode ELEN=64
```

### Floating-point reduction VRF sequencer

`rapt_vpu_fp_reduce_engine.sv` now combines the reduction decoder, existing
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

Independent public-interface tests use a byte-array VRF and a mock numeric
service. They check every VRF address/size/order, every numeric operand and
accumulator, and the final complete byte array. Numerical FP correctness remains
covered separately by the SoftFloat wrapper tests; these mock-service tests do
not establish actual encoded FP instruction results.

Four configurations each pass 4,450 commands, including 64 reset boundaries:
(XLEN,VLEN,ELEN)=(64,128,64), (32,128,32), (32,256,64), (64,512,64).
Coverage includes all six encodings, fractional/integer LMUL, zero/full VL,
mask patterns, scalar/source/mask overlap, invalid parameters, randomized
request and response delays, held completion, command input mutation and early
numeric errors with unread elements remaining. The fixed seed is
`8a396cef237401bd`; all four nine-file source manifests match.

```sh
make -C verify/vpu fp-reduce-engine XLEN=64 VLEN=128 ELEN=64
make -C verify/vpu fp-reduce-engine XLEN=32 VLEN=128 ELEN=32
make -C verify/vpu fp-reduce-engine XLEN=32 VLEN=256 ELEN=64
make -C verify/vpu fp-reduce-engine XLEN=64 VLEN=512 ELEN=64
python3 verify/vpu/synth_check.py --leaf fp_reduce_engine --leaf fp_reduce_decode --leaf fp_reduce_control --build-dir verify/build/vpu/synth-fp-reduce-engine
```

The targeted structural synthesis passes eight configurations with matching
source fingerprints, no inferred memories or latches, and combinational decoder
checks. Engine counts including decode/control/widening but excluding numeric
resources and VRF are 286 word-level cells for ELEN32 and 339 for ELEN64.
These are not technology-mapped area or STA. The synthesis script now accepts
repeatable `--leaf` selections and records their scope; its default still runs
the complete matrix. Prior full-matrix results remain historical snapshots.

The engine is included in the default standalone test target. Top-level VRF
arbitration, shared FP resources, flags/CSR completion and encoded-instruction
differential execution are still pending. No scalar core integration changed.

### Floating-point reduction top integration

The standalone top now routes all six reduction encodings through the dedicated
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

The focused real-instruction differential suite passes:
- XLEN64/VLEN128/ELEN64, BankBits64/Banks2/OptimizeOperandReads1:
  460 positive, 60 negative and six cancellation cases; 1,632 Spike steps;
  workload hash `484515f4431e804d`.
- XLEN32/VLEN128/ELEN32, BankBits64/Banks1/OptimizeOperandReads1:
  160 positive, 60 negative and six cancellation cases; 732 Spike steps;
  workload hash `cc2ea0863dc8fd90`.

Tests cover all supported source widths and fractional/integer LMUL settings,
VL=0/1/VLMAX, masks, all-masked signaling-NaN seeds, active signaling NaNs,
scalar destination overlap with source/seed/v0, odd scalar register numbers,
FRM/FS/VTYPE/source-alignment/vstart failures, completion stalls and cancellation
before authorization. They compare full VRF contents and flags against explicit
expected results as well as the pinned independent reference.

The Spike adapter explicitly selects ordered reduction instructions as the
reference implementation for unordered sums. RVV 1.0 permits this choice;
Spike's native unordered path canonicalizes an all-inactive NaN seed and may
raise NV, while this DUT uses the also-permitted ordered raw-seed behavior.
Only the two unordered sum encodings are mapped, and illegal-instruction tval
is translated back to the original instruction. The test workload and DUT
still receive the original encoding; no FP mismatch is skipped.
Normative basis: [RVV 1.0 reduction specification](https://github.com/riscv/riscv-v-spec/blob/v1.0/v-spec.adoc#vector-ordered-single-width-floating-point-sum-reduction).

```sh
make -C verify/vpu top TOP_SUITE=fp-reduce DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
make -C verify/vpu top TOP_SUITE=fp-reduce XLEN=32 ELEN=32 BANKS=1 DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
```

At this integration checkpoint, the full RV32/VLEN128/ELEN32/Banks1/opt1
differential regression passes 219,495 commands and 219,437 Spike steps,
19,771,998 total cycles, hash `a8d7e491d99395e3`. Its integer-only command
window remains 54,482 cycles and does not measure FP reduction performance.
Larger-VLEN focused tests also pass: RV32/VLEN256/ELEN64/BankBits64/Banks4
and RV64/VLEN512/ELEN64/BankBits128/Banks4, both opt1, each execute 460 positive,
60 negative and six cancellation cases with 1,632 Spike steps. Their hashes are
`b4fae8a61f54fed2` and `80178dfb6c46e771`. All focused and the completed RV32
full-regression 76-file manifests match the current sources.

Eight top/operand-read-baseline structural synthesis configurations pass with
matching source hashes, no latches and the expected VRF SRAM and estimate ROM
ports. Opt1 word-level counts are 33,361 for RV64/128/64/64/2, 33,429 for
RV32/256/64/64/4, 13,759 for RV32/128/32/64/1 and 33,563 for
RV64/512/64/128/4 (XLEN/VLEN/ELEN/BankBits/Banks). Opt0 is 15 cells smaller in
each case. Compared with the preceding top structural snapshot, integration
adds 442 word-level cells at ELEN64 and 378 at ELEN32, consistent with sharing
the arithmetic pool instead of instantiating the standalone numerical wrapper.
These are structural counts, not mapped area, timing or measured throughput.
The full RV64/VLEN128/ELEN64/BankBits64/Banks2/opt1 differential regression
also passes: 345,011 commands, 344,935 Spike steps, 29,540,486 total cycles,
hash `c51891c49e7523e0`. Its 76-file manifest matches. The integer-only
command window remains 65,450 cycles; this is not a reduction-speed claim.
All launched integration checks above are terminal and passed. Actual scalar
core/LSU/MMU integration, full legality audit and complete-engine acceptance
remain open.

### Historical initial OP-V data-processing encoding audit

This paragraph records the initial narrower sweep, not the current test scope.
The current sweep includes all supported SEWs, vs2=0/16 and complete VRF
comparisons; see the source-current acceptance audit below.

`test_encoding_top.h` adds a real-top instruction-admission sweep using the
independent pinned Spike adapter. It enumerates all 64 funct6 values, seven
data-processing funct3 forms (0–6), both vm values and every 5-bit selector,
with vd=8, vs2=16, LMUL=1, VL=2 and FRM=RNE. Every case starts from freshly
initialized VRF/configuration state. Scalar inputs and FP scalar inputs are
fixed. The selector is exercised in its vector-source, scalar-source or
subopcode role according to the encoding.

Initial results, VLEN128/BankBits64/OptimizeOperandReads1:
- XLEN32/ELEN32/Banks1, SEW32: 28,672 combinations, 12,009 accepted and
  16,663 rejected; 57,344 Spike steps including configuration instructions;
  hash `7a47a20efe888173`.
- XLEN64/ELEN64/Banks2, SEW32/64: 57,344 combinations, 28,038 accepted and
  29,306 rejected; 114,688 Spike steps including configuration instructions;
  hash `cf9a16fa779054f0`.

Both complete with matching 77-file source fingerprints and the common fixed
seed `243f6a8885a308d3`. No RTL change was required by this sweep. The adapter's
documented ordered-reference choice for unordered FP reductions applies here.

The public command checker compares trap presence, cause/tval, scalar GPR/FPR
results and FP flags. It also exercises command capture, authorization,
cancellation exclusion and held completion. This sweep does not calculate or
compare every resulting vector element; existing numerical/VRF suites retain
that responsibility. It is additional admission evidence, not a complete V
compliance result. It excludes configuration funct3=7, memory opcodes, CSR
encodings, SEW8/16, other LMUL/VL/FRM choices, disabled-state permutations and
most source/destination register geometry. In particular, instructions whose
fixed field requires vs2=0 are only negatively exercised by this sweep.

```sh
make -C verify/vpu top TOP_SUITE=encoding DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
make -C verify/vpu top TOP_SUITE=encoding XLEN=32 ELEN=32 BANKS=1 DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
```

The suite is explicit and requires the independent reference; it is not added
to the default non-differential full suite. Full-top regression and synthesis
were not repeated for this test-only addition. Prior integrated RTL passes
remain evidence for their recorded source snapshots.

### Expanded encoding/VRF audit

The encoding suite has been expanded beyond the preceding completed admission
snapshot. It now tests every supported SEW (8/16/32 and ELEN64's 64), both
vs2=0 and vs2=16, all funct6/form/vm/selector combinations, and compares the
entire VRF against Spike after each instruction, including rejected encodings.
The existing command checks for trap metadata, scalar results and flags remain.
The added vs2=0 cases exercise fixed-zero-field operations that previously
received only negative coverage.

LMUL=1, VL=2, vd=8, FRM=RNE and undisturbed tail/mask policies remain fixed.
This remains a bounded configuration sweep; it does not prove all geometry,
memory/CSR behavior or full V conformance. Explicit numerical oracles in the
focused suites remain independent additional evidence.

The current runs use the existing `TOP_SUITE=encoding` entry for RV32/ELEN32
and RV64/ELEN64 at VLEN128. The RV32/ELEN32/Banks1 run has completed successfully: 172,032 combinations,
69,816 accepted and 102,216 rejected; 344,064 Spike steps including
configuration instructions; workload hash `d5eeadc6322a0d76`. Its 77-file
manifest matches current sources. The RV64/ELEN64/Banks2 run also passes: 229,376 combinations,
102,068 accepted and 127,308 rejected; 458,752 Spike steps including
configuration instructions; workload hash `980563747df8e87e`. Its 77-file
manifest also matches. Both runs are terminal and successful. The preceding admission-only counts/hashes refer
to their earlier source snapshot.

### Memory response ownership proof

`formal_memory_response.sv` contains a two-instance stale-response miter and
a separately selectable request-ledger/acceptance property. A public request
ledger records tag, element index, segment field and probe identity for a
pending request, including same-cycle request/response handshakes.

The ownership partition proves that the sequencer accepts a response exactly
when it matches the ledger's outstanding request or the request accepted on
that cycle. The ledger's pending-state and identity consistency invariants are
proved conjuncts, not environment assumptions. The only initialization
requirement is first-edge reset; subsequent requests, responses, backpressure
and reset inputs are arbitrary. A frontend limitation prevents hierarchical
enum constants, so the runner validates the RESPONSE state encoding against
current RTL before using its value in the invariant.

Unbounded SAT temporal induction passes for VLEN128 with:
- XLEN32/ELEN32/TagBits2.
- XLEN64/ELEN64/TagBits10.

Both configurations also have a reachable stale-response-while-pending witness
at depth 20. These cover searches constrain a simple valid load and a mismatched
response to obtain a readable witness; those constraints are not used in the
safety proofs. Four bounded mutation checks detect removal of the tag, element
index, segment field or probe comparison, with recorded counterexample VCDs.

```sh
python3 verify/vpu/memory_response_formal.py --ownership-only --build-dir verify/build/vpu/formal-memory-ownership
```

The successful summary records solver version, proof scope, parameters,
mutation results and four source fingerprints. No production RTL changed.

The full miter perturbs stale data, cause/tval, fault and non-idempotent
indicators in the second instance and compares later observable behavior.
Its initial monolithic attempt was deliberately interrupted after costly base
expansion. A strengthened attempt, which also proves internal state equality,
reached induction but exceeded the 180-second per-invocation limit. Neither
attempt establishes full payload isolation. The default runner retains this
uncompleted proof target, with a configurable solver timeout:
```sh
python3 verify/vpu/memory_response_formal.py --timeout 180
```

The ownership partition alone does not prove payload isolation, tag freshness
across reuse, external drain, memory ordering or liveness. The following
compositional proof closes the payload-isolation property separately. All
monolithic attempts above are terminal; none is a successful isolation proof.

### Completed compositional memory payload-isolation proof

`memory_response_isolation.py` proves stale-response payload noninterference
using the original sequential RTL plus a common-current-state induction step.
The second instance receives five **independent arbitrary** alternate inputs
(data, cause, tval, fault and non-idempotent indication) on stale responses.
Their values are not restricted to correlated bitwise inversions. Response
identity and all other external inputs remain shared.

The proof combines:
1. The request-ledger/response-acceptance induction proof and stale-pending
   reachability witness against the original sequential design.
2. A reset base check on the original two-instance design: first reset high,
   then reset low, with other inputs and pre-reset DUT registers unconstrained.
3. Normal and reset single-transition checks with corresponding current DUT
   registers shared. The normal check uses only the independently proved
   ledger invariant; it does not restrict instruction, addresses, data,
   response timing or backpressure.
4. An unconditional combinational check that equal current state yields equal
   valid observable payloads and handshake signals.

The induction projection is generated from the elaborated original netlist
after reset/enable unmapping to plain DFFs. It preserves every original D input
expression, compares all paired next-state bits, and only then removes clocks
and identifies corresponding current Q inputs. The script rejects unsupported
sequential cell types, multiple Q drivers, asymmetric constant state, unknown
state origins or incomplete coverage of DUT register bits. This prevents a
new or renamed register from silently disappearing from the proof.

At VLEN128, all proof components pass for XLEN32/ELEN32/TagBits2 and
XLEN64/ELEN64/TagBits10. The projections pair 754/1,218 total DUT register bits
across the two instances and compare 377/609 next-state bits respectively.
The ledger component detects all four removed identity comparisons. Two
additional mutations—capturing response data without acceptance and consuming
fault without acceptance—both produce counterexamples in the isolation check.

```sh
python3 verify/vpu/memory_response_isolation.py
```

The completed artifact is
`verify/build/vpu/formal-memory-isolation/summary.json`, with the independent
ledger proof in its `ledger/` subdirectory. It records parameters, solver,
projection coverage, mutations and five matching source fingerprints. The
current proof changes only formal harnesses/scripts; production RTL and its
functional behavior were not modified or re-regressed.

This establishes the stated stale-payload isolation property after reset for
the two configurations. It does not establish freshness when a finite identity
is reused before external work drains, nor memory ordering, liveness, LSU/SQ
integration or complete VPU formal verification. Those remain open.

The independent control test is available as:
```sh
make -C verify/vpu fp-reduce-control ELEN=32
make -C verify/vpu fp-reduce-control ELEN=64
```


## FP reduction mask-byte cache

The reduction sequencer now defaults to `CacheMask=1`. It retains one predicate
byte while processing its eight elements, invalidates it at byte boundaries and
on command acceptance, and clears validity on reset. All input reads precede
the sole destination write, so destination overlap with v0 cannot invalidate a
live cached predicate. `CacheMask=0` retains the uncached baseline.

The following current leaf comparison uses 4,450 cases and 64 reset boundaries
per configuration and mode, with seed `8a396cef237401bd`. Each case restores an
independent random-generator seed so changing the sequencer schedule cannot
change subsequent instruction selection or initial VRF contents. Explicit
reference checks validate requests, numeric-service operands, final VRF and
completion; the matching fingerprint additionally identifies the input/output
workload. Timing uses a mock numeric service, not the integrated FP datapath.
Backpressure is generated per case, but the two modes do not necessarily see
identical cycle-by-cycle stalls.

| XLEN / VLEN / ELEN | Cycles, cache 0 → 1 | VRF reads, cache 0 → 1 | Matching fingerprint |
| --- | ---: | ---: | --- |
| 64 / 128 / 64 | 105578 → 81998 | 12237 → 7043 | `0f2c5bcc122d6184` |
| 32 / 128 / 32 | 52740 → 41047 | 5889 → 3300 | `c99814e5b16523a9` |
| 32 / 256 / 64 | 198502 → 150079 | 23838 → 13055 | `b3ce6ddef892a023` |
| 64 / 512 / 64 | 384128 → 286736 | 46956 → 25227 | `535e27a561adcc7b` |

All eight leaf source manifests matched the worktree when this record was
written. Build directories end in `fp-reduce-engine-XLEN-VLEN-ELEN-cacheN`.
Reproduce each pair with the same parameters and `REDUCE_MASK_CACHE=0` or `1`:

```sh
make -C verify/vpu fp-reduce-engine XLEN=64 VLEN=128 ELEN=64 REDUCE_MASK_CACHE=0
make -C verify/vpu fp-reduce-engine XLEN=64 VLEN=128 ELEN=64 REDUCE_MASK_CACHE=1
python3 verify/vpu/synth_check.py --leaf fp_reduce_engine --leaf fp_reduce_engine_baseline --build-dir verify/build/vpu/synth-reduce-mask-cache
```

After all four pairs have completed, `python3 verify/vpu/check_reduce_mask_cache.py`
validates source freshness, matching tools/parameters/workloads, expected case
counts and improvements, and prints the comparison as JSON. It reads completed
artifacts and does not launch or overwrite simulations.

All eight selected synthesis configurations passed with matching source hashes.
The cache adds 21 Yosys word-level cells: ELEN32 grows from 286 to 307, and
ELEN64 from 339 to 360. This is a structural count, not mapped area or timing.
The enabled-cache top also passed the following Spike differential runs. All
four 77-file source manifests matched the worktree after completion, and all
four commands exited successfully. Bank geometry is BankBits/Banks; all use
`OPT_READS=1`, ELEN as shown and seed `243f6a8885a308d3`.

| XLEN / VLEN / ELEN | Banks | Suite | Spike steps | Workload hash |
| --- | --- | --- | ---: | --- |
| 32 / 128 / 32 | 64 / 1 | full | 219437 | `a8d7e491d99395e3` |
| 64 / 128 / 64 | 64 / 2 | full | 344935 | `c51891c49e7523e0` |
| 32 / 256 / 64 | 64 / 4 | fp-reduce | 1632 | `b4fae8a61f54fed2` |
| 64 / 512 / 64 | 128 / 4 | fp-reduce | 1632 | `80178dfb6c46e771` |

Full-suite total cycles were 19,770,750 (RV32) and 29,537,978 (RV64).
These are validation-run totals, not a controlled full-top cache comparison.
The two focused suites each covered 460 positive reduction cases, 60 negative
cases and six cancellations. Reproduce using `make -C verify/vpu top DIFF=1
SPIKE_BUILD=/path/to/pinned/spike` with explicit `XLEN`, `VLEN`, `ELEN`,
`BANK_BITS`, `BANKS`, and `TOP_SUITE=full` or `fp-reduce` as tabulated.
This closes the cache-change regression gate; it does not establish full V
conformance, real scalar-core/LSU integration or physical PPA.

## Configuration encoding and state-transition audit

`TOP_SUITE=config-encoding` adds an independently selectable Spike audit in
`test_encoding_top.h`. It sweeps all 4,096 upper instruction encodings with
OP-V funct3=7, rd=x1 and source fields 0, 2 and 31. This covers both immediate
configuration families, all register-form rs2 selectors and reserved funct7
encodings. Register operands respect x0 and aliasing: identical scalar register
identities are supplied identical values. The test also checks all 256 low-byte
register VTYPE values with AVL=0, 1, 17 and XLEN all-ones, and rd=x0/x1; every
individual unsupported VTYPE bit above bit 7; legal same-VLMAX keep-VL and
maximum-AVL forms; and four VS-off encodings.

Before each candidate, the test establishes e8,m1,VL=3 and nonzero VSTART,
VXRM and VXSAT. After execution it reads all seven vector CSRs through real
encoded CSR instructions, whose scalar results are compared with Spike, and
compares the full VRF with its unchanged explicit byte-array oracle. The common
command driver checks exceptions, result data, FP flags, authorization and
completion holding; this suite additionally checks the configuration result
destination and dirty event. Unsupported VTYPE settings can complete with vill;
the accepted count does not imply every type setting is supported.

| XLEN / VLEN / ELEN / BankBits / Banks | Candidate cases | Accepted | Traps | Spike steps | Workload hash |
| --- | ---: | ---: | ---: | ---: | --- |
| 32 / 128 / 32 / 64 / 1 | 14372 | 11392 | 2980 | 172464 | `d0f59095ceafbc8d` |
| 64 / 128 / 64 / 64 / 2 | 14404 | 11424 | 2980 | 172848 | `44148092a026f709` |

Both commands exited successfully and both 77-file manifests matched the
worktree after execution. Seed is `243f6a8885a308d3`; OPT_READS=1. No production
RTL or reference-model adaptation changed for this audit.

```sh
make -C verify/vpu top TOP_SUITE=config-encoding DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=32 VLEN=128 ELEN=32 BANK_BITS=64 BANKS=1
make -C verify/vpu top TOP_SUITE=config-encoding DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
```

This is bounded configuration evidence. It does not enumerate all immediate
AVL values, all old/new configuration transitions, reserved changing-VLMAX
keep-VL behavior or all register identities. It does not extend the arithmetic
encoding sweep to memory encodings or establish full V conformance. The earlier
full-suite records remain historical snapshots; adding this focused test does
not imply those suites were rerun.

## Vector memory encoding audit

`TOP_SUITE=memory-encoding` selects a 32,768-case sweep in
`test_encoding_top.h`: load/store, the four vector width encodings, both mew
values, all eight nf encodings, all four addressing modes, all 32 auxiliary
selectors and both vm values. Other width encodings belong to scalar floating-
point memory instructions and are outside this standalone vector interface.

Each case starts with independent nonuniform VRF and RAM fixtures and sets
SEW=8, LMUL=1, VL=2, VSTART=0 and destination v8. Indexed operands are populated
with offsets 0 and 16 at the encoded EEW, including index/destination overlap.
Scalar operands honor x0 and register aliasing; strided accesses with rs2=x2
use the same value as the x2 base and can therefore fault on a later element.
The bus model retains delayed/backpressured and mismatched-identity responses.

The candidate instruction runs through both the real VPU top and pinned Spike.
Checks compare trap metadata, complete VRF and data RAM, followed by encoded
reads of VSTART, VL and VTYPE. Illegal-instruction cases additionally require
zero bus requests (including probes), no dirty event and unchanged VRF/RAM
against the pre-instruction byte fixtures. This complements the existing
explicit arithmetic/byte oracles in the broader memory family tests.

```sh
make -C verify/vpu top TOP_SUITE=memory-encoding DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=32 VLEN=128 ELEN=32 BANK_BITS=64 BANKS=1
make -C verify/vpu top TOP_SUITE=memory-encoding DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
```

The sweep is bounded by its fixed vector configuration and destination. It
does not establish all LMUL/SEW/VSTART transitions, all destination placements,
real MMU/SQ behavior or complete V conformance. Production RTL and the reference
adapter are unchanged by this audit.

Both runs completed successfully with 77-file manifests matching the worktree:

| XLEN / VLEN / ELEN / BankBits / Banks | Successful candidates | Illegal encodings | Access faults | Spike steps |
| --- | ---: | ---: | ---: | ---: |
| 32 / 128 / 32 / 64 / 1 | 5176 | 27550 | 42 | 163840 |
| 64 / 128 / 64 / 64 / 2 | 5539 | 27184 | 45 | 163840 |

Both use OPT_READS=1, seed `243f6a8885a308d3` and input workload hash
`ed2c7eea69e0544a`. The equal hash identifies the same instruction/fixture
workload; legal results differ with XLEN/ELEN and are checked against each
configuration's reference. These focused passes do not refresh earlier
full-suite evidence after test-source changes.

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
make -C verify/vpu top TOP_SUITE=context DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
```

This validates the standalone architectural sequence. The scalar adapter still
must own VS/FS gating, scalar FCSR, privileged trap entry and context scheduling;
this test does not run an OS or change the scalar core's ISA advertisement.

All four current runs passed 32 context cases and 1,112 Spike steps each, with
OPT_READS=1 and seed `243f6a8885a308d3`. Every command exited successfully and
each 78-file manifest matched the worktree after completion:

| XLEN / VLEN / ELEN / BankBits / Banks | Workload hash |
| --- | --- |
| 32 / 128 / 32 / 64 / 1 | `56e886b4b63d9ad9` |
| 64 / 128 / 64 / 64 / 2 | `a0275772cf0c422d` |
| 32 / 256 / 64 / 64 / 4 | `62de3405f2d1f7af` |
| 64 / 512 / 64 / 128 / 4 | `633210ed3cb45d08` |

The context header is fingerprinted by the top recorder. These are focused
context passes; no production RTL changed and earlier full-suite evidence is
not refreshed by the new tests.

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

The test composes the bridge with the real `rapt_vpu_owner` and a delayed
numeric engine model. Three RobBits/GenerationBits pairs (1/1, 3/1 and 6/4)
each passed 256 command attempts: 175 completions, 81 cancellations, 569 dropped
early/wrong/duplicate responses, plus four paired reset boundaries (pending,
authorized, running and completed under backpressure). Checks include metadata
capture despite changing input payloads, wrong-generation and unsafe-head
authorization exclusion, kill/grant priority, irrevocable ownership, immediate
and delayed engine completion and repeated tag reuse. All commands exited
successfully with strict warnings and assertions enabled.

```sh
make -C verify/vpu core-adapter ADAPTER_ROB_BITS=6 ADAPTER_GENERATION_BITS=4
python3 verify/vpu/synth_check.py --leaf core_adapter --build-dir verify/build/vpu/synth-core-adapter
```

`make -C verify/vpu test` includes the adapter target. Simulation snapshots are
under `core-adapter-RobBits-GenerationBits/sources.json`. Selected synthesis
passed RobBits/GenerationBits=6/4 and 3/1 with different command/result/metadata
widths; each retained 50 Yosys word-level cells, no memories or latches. This is
structural evidence, not physical area/timing or a formal proof. The simulation
and synthesis source hashes matched the worktree after completion.

The bridge is composed with the numerical VPU by `rapt_vpu_core`, described
below. It is not yet instantiated in `rapt_core`. Scalar completion/CSR mapping,
head-safe generation and the LSU/SQ final-response contract remain integration
work. The generic payload boundary keeps core-specific types outside the
independent VPU modules.

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
`CORE_ADAPTER=0` retains the original standalone VPU. Build directories use
`core-top-...` versus `top-...`, and the source manifest records `CoreAdapter`.
The common instruction driver supplies nonuniform metadata, changes it after
command acceptance, checks an unsafe matching ROB head is not authorized, and
checks captured metadata throughout completion backpressure. Existing numerical,
CSR, memory, cancellation and Spike comparisons run through the wrapper.

```sh
make -C verify/vpu top CORE_ADAPTER=1 DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
make -C verify/vpu top CORE_ADAPTER=1 TOP_SUITE=context DIFF=1 SPIKE_BUILD=/path/to/pinned/spike
python3 verify/vpu/synth_check.py --leaf top_core --build-dir verify/build/vpu/synth-core-top
```

The wrapper supplies a concrete core-facing numerical module; it does not
connect the real Raptor ROB, CSR, MMU or SQ. In particular, `head_safe` is an
input contract, not a proof of older-store drain or memory ordering.

All five selected numerical-wrapper runs completed successfully with matching
80-file manifests, CORE_ADAPTER=1, OPT_READS=1 and seed `243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | Suite | Spike steps | Workload hash |
| --- | --- | ---: | --- |
| 32 / 128 / 32 / 64 / 1 | full | 219437 | `a8d7e491d99395e3` |
| 64 / 128 / 64 / 64 / 2 | full | 344935 | `c51891c49e7523e0` |
| 64 / 128 / 64 / 64 / 2 | context | 1112 | `a0275772cf0c422d` |
| 32 / 256 / 64 / 64 / 4 | fp-mixed | 1920 | `f0c938af64e538f6` |
| 64 / 512 / 64 / 128 / 4 | context | 1112 | `633210ed3cb45d08` |

Full-run cycle totals were 19,990,245 (RV32) and 29,882,989 (RV64). The driver
adds an intentional unsafe-head cycle per candidate, so these totals are not a
measurement of intrinsic adapter latency or a comparison with the standalone
top's performance window. The RV32/ELEN64 case checks 64-bit FP payloads through
the narrower scalar configuration, while the two context suites preserve and
restart partial architectural state through the bridge.

Four actual `rapt_vpu_core` structural synthesis configurations passed with
matching hashes and retained the expected VRF capacity and registered SRAM
ports. Word-level cell counts, in XLEN/VLEN/ELEN/BankBits/Banks order, are
33,425 (64/128/64/64/2), 33,493 (32/256/64/64/4), 13,823
(32/128/32/64/1), and 33,627 (64/512/64/128/4). These are not mapped PPA or STA
results. The simulation and synthesis evidence covers this wrapper, not an
instance inside the scalar Raptor core.

## Core adapter inductive control proof

`make -C verify/vpu core-adapter-formal` proves a public-interface transaction
ledger against `rapt_vpu_core_adapter` using Yosys SAT induction. The first
sampled edge has reset asserted; subsequent inputs, including reset, are
unconstrained. No internal DUT state is referenced and no traffic/fairness
assumptions exclude stale, premature or malformed response identities.

The ledger checks command forwarding/admission, metadata capture and ownership,
head slot/generation and safe-head gating, pre-grant cancellation priority,
post-grant kill blocking, accepted completion identity, wrong/early response
drain, and metadata retention until cancellation or retirement. It checks
result-payload passthrough against the current producer input. Payload stability
under backpressure still requires the response producer's documented holding
contract; this adapter proof does not assume or establish producer correctness.

All four configurations passed unbounded inductive safety:

| RobBits | GenerationBits | CommandBits | ResultBits | MetadataBits |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 8 | 8 | 8 |
| 3 | 1 | 17 | 29 | 37 |
| 6 | 4 | 164 | 174 | 64 |
| 6 | 4 | 228 | 270 | 64 |

The last two use the actual RV32/RV64 numerical wrapper payload widths with
its default ROB identity and metadata widths. Eleven events per configuration
have depth-12 reachable witnesses: retirement, acceptance/cancel, kill/grant
race, blocked late kill, completion stall, early response, wrong response,
unsafe head, wrong-generation head, exact-tag reuse and reset while occupied.
All 44 witnesses were found. This reachability depth does not bound the
separate inductive safety result.

Six production-RTL mutations were each detected with counterexample VCDs:
ignoring head generation, ignoring head safety, accepting premature responses,
releasing metadata on a wrong response, overwriting metadata from live inputs,
and allowing cancellation after authorization. The run exited successfully,
recorded Yosys version and source hashes in
`verify/build/vpu/formal-core-adapter/summary.json`, and those hashes matched
the worktree after completion.

This closes the adapter's selected control-safety gate. It does not prove
that the core generates `head_safe` correctly, eventual external completion,
LSU ordering/drain, identity freshness after exact tag reuse, or the entire
numerical VPU. No production RTL changed for this proof.

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

The suite sweeps all four element positions and every field in 1-, 2- and
8-field stores, compares the visible prefix with a byte model and Spike,
checks fault cause/address and VSTART, then removes the fault and restarts.
Single-field cases use the model's non-idempotent attribute; multi-field cases
use idempotent memory so replay of fields within a partial segment is permitted.
The request scoreboard excludes re-access to completed elements on restart.
Two additional e8,m8 stores have VLEN elements (128, 256 or 512 here), exceeding
the current default scalar SQ capacity of 16 entries. They fault at the last
element and resume with exactly one final access. This checks VPU streaming
progress with incremental final acknowledgements; it does not prove that the
real SQ can supply those acknowledgements without a retirement deadlock.

```sh
make -C verify/vpu top CORE_ADAPTER=1 TOP_SUITE=store-completion DIFF=1 SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
```

All four runs passed 222 fault/restart cases and 1,330 Spike steps each. All
commands exited successfully; 81-file manifests matched the worktree. Parameters
use CORE_ADAPTER=1, OPT_READS=1 and seed `243f6a8885a308d3`:

| XLEN / VLEN / ELEN / BankBits / Banks | Actual-write waiting cycles | Workload hash |
| --- | ---: | --- |
| 32 / 128 / 32 / 64 / 1 | 226207 | `4838851bebdef15e` |
| 64 / 128 / 64 / 64 / 2 | 226207 | `4838851bebdef15e` |
| 32 / 256 / 64 / 64 / 4 | 242463 | `16d5b273702e8cca` |
| 64 / 512 / 64 / 128 / 4 | 274975 | `4344175940c88e86` |

Waiting counts are coverage measurements, not performance estimates. No
production RTL changed. These focused passes do not refresh previous full
regressions after changes to the shared test memory model, and do not establish
real device failure semantics, MMU translation or scalar SQ integration.

## FPGA primitive mapping baseline

`verify/vpu/fpga_map.py` maps `rapt_vpu_core` from current RTL using
`synth_xilinx -family xcup -flatten -noiopad -noclkbuf`. UltraScale+ is a family
used by existing project board configurations; this standalone flow selects no
part, board pins or clock constraints and performs no board operations. It
retains the default ROB identity and 64-bit metadata widths, OPT_READS=1 and
the enabled FP reduction mask cache.

Both selected mappings completed with Yosys 0.64, source hashes matching the
worktree and mapped-netlist hashes recorded in their summaries:

| XLEN / VLEN / ELEN / BankBits / Banks | LUT1–6 cells | FDRE + FDSE | DSP48E2 | CARRY4 | VRF RAM primitives |
| --- | ---: | ---: | ---: | ---: | --- |
| 32 / 128 / 32 / 64 / 1 | 34647 | 5380 | 8 | 3182 | 64 × RAM64X1S |
| 64 / 128 / 64 / 64 / 2 | 60738 | 9790 | 22 | 5232 | 16 × RAM32M16 |

The LUT column excludes distributed RAM, wide muxes and inverter cells. Raw
counts for every primitive are retained in the JSON summaries. VRF data maps
to distributed RAM in both configurations; it is not flattened into a bank
of ordinary data flip-flops. These are different architectural configurations,
not an optimization before/after comparison or isolated FP64 area attribution.

```sh
python3 verify/vpu/fpga_map.py --xlen 32 --elen 32 --banks 1
python3 verify/vpu/fpga_map.py --xlen 64 --elen 64 --banks 2
python3 verify/vpu/check_fpga_map.py verify/build/vpu/fpga-map/32-128-32-1-64-1-xcup
python3 verify/vpu/check_fpga_map.py verify/build/vpu/fpga-map/64-128-64-2-64-1-xcup
```

Each output directory contains `run.ys`, `run.log`, `sources.json`,
`mapped.json`, `mapped.v` and `summary.json`. The separate artifact checker
revalidates source/netlist hashes, primitive counts and that every instantiated
cell is a finalized vendor model from Yosys's Xilinx `cells_sim.v` or
`cells_xtra.v`, rejecting residual generic cells and custom blackboxes. Both
checks passed. `primitive-check.json` records the checker fingerprint and the
library snapshots taken during that check.

The xcup flow emits CARRY4; these counts are not native CARRY8 placement counts.
AMD describes CARRY4-to-CARRY8 retargeting in its
[UltraScale migration guide](https://docs.amd.com/api/khub/documents/qKNVVbGAvClZfgot0nx9eg/content).
This run did not perform that downstream implementation step. Primitive counts
are also not occupied LUT sites after packing, mapped ASIC area, power or
timing. No post-map functional equivalence, placement/routing, Vivado part
acceptance, STA or FPGA operation is claimed by these mapping passes.

One candidate for later resource optimization is parameterizing the fixed
64/128-bit integer ALU, fixed-point and multiply/divide internal widths for
ELEN32. The current mapping is the baseline; the candidate has not been
implemented or established as the dominant resource contributor.

## ALU sign-extension wiring optimization

`rapt_vpu_alu.sv` now selects explicit e8/e16/e32/e64 masks, sign extensions
and shift-count slices. The previous expression sign-extended by a variable
left shift followed by an arithmetic right shift. Both express the same four
legal hardware widths; the explicit wiring avoids synthesizing those variable
shifters just to extend the sign. Arithmetic shifts that are actual instruction
operations remain present. No interface, instruction admission or pipeline
latency changes.

The old source is frozen as `verify/vpu/rapt_vpu_alu_baseline.sv`.
`formal_alu_equivalence.sv` compares every output bit for all binary values of
both 64-bit operands, funct6, SEW and mask controls, without assumptions.
The Yosys SAT proof passed. `alu_opt_check.py` records the proof and maps both
versions with the same xcup/no-I/O/no-clock-buffer flow. Leaf LUT1–6 counts
fell from 6,361 to 2,079 (about 67.3%); CARRY4 counts changed from 128 to 118.
These leaf numbers alone do not establish full-VPU resource savings or timing.

```sh
python3 verify/vpu/alu_opt_check.py
python3 verify/vpu/fpga_map.py --xlen 32 --elen 32 --banks 1 --build-dir verify/build/vpu/fpga-map-alu-opt
python3 verify/vpu/fpga_map.py --xlen 64 --elen 64 --banks 2 --build-dir verify/build/vpu/fpga-map-alu-opt
```

The original whole-VPU mapping artifacts remain in `fpga-map`; new artifacts
are isolated in `fpga-map-alu-opt`. `compare_alu_top_map.py BASELINE OPTIMIZED`
checks the same parameters/family/tool/flow, hashes both netlists, requires the
frozen ALU to match the old source hash, checks the current equivalence inputs,
and rejects changes to every other synthesis source. This intentionally permits
only the proven ALU change when comparing the historical baseline to current
RTL; ordinary source-freshness checks must continue rejecting stale snapshots.

Both whole-VPU mappings passed and the strict comparison accepted the ALU as
the sole synthesis-source change. Current vendor-primitive provenance checks
also passed. In the same xcup flow, with VLEN=128, BankBits=64, default core
identity/metadata widths and OPT_READS=1:

| XLEN / ELEN / Banks | LUT1–6 before → after | LUT reduction | FF before → after | DSP48E2 before → after |
| --- | ---: | ---: | ---: | ---: |
| 32 / 32 / 1 | 34647 → 31102 | 10.23% | 5380 → 5380 | 8 → 8 |
| 64 / 64 / 2 | 60738 → 57110 | 5.97% | 9790 → 9790 | 22 → 22 |

VRF remains 64 RAM64X1S in the first configuration and 16 RAM32M16 in the
second. The complete metric dictionaries and proof/netlist fingerprints are
stored in each optimized map's `alu-comparison.json`. These are primitive
resource reductions, not physical area, power or frequency improvements.

The current core-facing VPU also passed both full Spike suites after this RTL
change. Every build/run exited successfully and both 81-file manifests matched:

| XLEN / VLEN / ELEN / BankBits / Banks | Spike steps | Total cycles | Workload hash |
| --- | ---: | ---: | --- |
| 32 / 128 / 32 / 64 / 1 | 219437 | 19990245 | `a8d7e491d99395e3` |
| 64 / 128 / 64 / 64 / 2 | 344935 | 29882989 | `c51891c49e7523e0` |

Both use CORE_ADAPTER=1, OPT_READS=1 and seed `243f6a8885a308d3`. Workload hashes
and cycle totals match the previous wrapper runs, consistent with an unchanged
sequencer and combinationally equivalent ALU. The proof covers binary inputs;
four-state X propagation and post-map timing/equivalence are not claimed.

### Adapter reset and delayed-response regression

The adapter/owner composition test now injects a delayed external response
across paired reset at four stages: waiting for authorization, waiting for
engine acceptance, waiting for a numeric result, and holding completion under
backpressure. It checks that reset suppresses command, grant and response
handshakes, that the old response drains without a core completion after reset,
and that the drained identity can subsequently be admitted and cancelled in
the same cycle. This models one external reply; it does not prove that a real
memory fabric has drained or permit identity reuse before that drain.

`make -C verify/vpu core-adapter ADAPTER_ROB_BITS=6 ADAPTER_GENERATION_BITS=4`
passes with assertions enabled. The 1/1 and 3/1 width configurations also pass.
Each run completes 175 commands, cancels 81 in the main traffic loop, discards
573 injected replies, and checks four reset drains and four post-reset
admission/cancellation cases. Production RTL is unchanged by this test addition.

## Arithmetic register geometry differential suite

`TOP_SUITE=geometry DIFF=1` executes real instructions through the core-facing
VPU and pinned Spike. It sweeps all supported SEW/LMUL combinations with VL=2
(clamped to VLMAX), both mask settings, and registers
0, 1, 2, 3, 4, 7, 8, 15, 16, 23, 24, 28, 30 and 31. Each vector source is
varied against the destination independently, with the other source at v16.
Operations represent add, mask comparison, widening add, wide-source add,
narrowing shift, gather16, scalar slideup, compression and extension by two.
Unary and scalar forms omit the inapplicable second-source sweep.

Spike determines admission and output bytes independently of the RTL geometry
formula. Every candidate compares the entire VRF. Illegal candidates also
require no dirty event, unchanged VRF and preserved VSTART. Compression uses
VSTART=0; other forms use VSTART=0 when masked and VSTART=1 when unmasked.
This deliberately bounded sweep does not cover every register triple, opcode,
restart value, FP geometry or memory geometry.

For example, with a separately built pinned reference:

```sh
make -C verify/vpu top CORE_ADAPTER=1 TOP_SUITE=geometry DIFF=1 \
  SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
```

Both CORE_ADAPTER=1 configurations passed with VLEN=128, BankBits=64,
OPT_READS=1 and seed `243f6a8885a308d3`. Their 82-file manifests match the
current sources:

| XLEN / ELEN / Banks | Candidates | Accepted | Illegal | Spike steps | Workload hash |
| --- | ---: | ---: | ---: | ---: | --- |
| 32 / 32 / 1 | 94080 | 35210 | 58870 | 341110 | `11b497edd6aea48a` |
| 64 / 64 / 2 | 137984 | 58547 | 79437 | 493389 | `4a7a5dd27078f1d1` |

## Baseline instruction catalog audit

The vendored [official rv_v catalog](https://github.com/riscv/riscv-opcodes/blob/72b292677715a091a441c9a55f9d62715d3c5ba2/extensions/rv_v)
is fixed at commit `72b292677715a091a441c9a55f9d62715d3c5ba2`, with its
redistribution license retained under `verify/vpu/vendor/riscv-opcodes/`.
`generate_catalog.py` checks complete, non-overlapping encoding fields and
produces concrete operands for all 375 entries. Expanding variable NF fields
produces 627 variants, including segment operations.

The `catalog` suite executes every variant at every supported SEW, with LMUL=1,
VL=2 clamped to VLMAX, VSTART=0 and both mask settings where the encoding has
variable VM. Sources/destination use separate aligned groups. Indexed-memory
operands use zero indices so valid geometries stay in the test RAM. It compares
trap/scalar result/FP flags through the common Spike driver, every VRF byte,
all modeled RAM bytes and VSTART/VCSR/VL/VTYPE after each candidate. No expected
arithmetic result or instruction admission is derived from the DUT decoder.

| XLEN / VLEN / ELEN / BankBits / Banks | Variants | Candidates | Accepted | Illegal | Variants without execution | Spike steps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 / 128 / 32 / 64 / 1 | 627 | 3567 | 2419 | 1148 | 107 | 21402 |
| 64 / 128 / 64 / 64 / 2 | 627 | 4756 | 3882 | 874 | 0 | 28536 |

Both runs use CORE_ADAPTER=1, OPT_READS=1 and seed `243f6a8885a308d3`;
workload hashes are `201b4d6bef368ab9` and `2e1f8c3ddcfc8da5` respectively.
The 86-file source manifests matched after completion. RV64/ELEN64 requires
at least one successful execution per variant; zero-execution variants fail
that baseline test. The narrower RV32/ELEN32 run is a projection: its 107
unexecuted variants require wider data/index memory operations, wider FP
arithmetic/conversions, or eightfold integer extension. Each candidate still
compares with Spike; none is skipped.

```sh
python3 verify/vpu/generate_catalog.py --check
make -C verify/vpu top CORE_ADAPTER=1 TOP_SUITE=catalog DIFF=1 \
  SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
python3 verify/vpu/check_catalog.py \
  verify/build/vpu/core-top-64-128-64-64-2-opt1-spike-catalog
python3 verify/vpu/test_check_catalog.py
```

`catalog.json` contains every per-variant accepted/illegal count and explicitly
lists unexecuted variants. Its checker requires the exact variant set, expected
candidate count, completed top/CSR steps, pinned reference revision and current
source manifest. Isolated negative tests reject a missing variant, a baseline
variant with no successful execution, and a missing completed top result.
This establishes instruction availability and the effects of these samples;
it does not establish complete instruction legality, all operand/rounding/fault
semantics, optional vector extensions, scalar-core integration or ISA certification.

## Extended parameter acceptance

On 2026-09-06, the core-facing full, catalog, context and store-completion
suites passed for both configurations below. All eight runs have matching
86-file source manifests, CORE_ADAPTER=1, OPT_READS=1, and seed
`243f6a8885a308d3`.

| XLEN / VLEN / ELEN / BankBits / Banks | Full Spike steps | Full cycles | Full workload hash |
| --- | ---: | ---: | --- |
| 32 / 256 / 64 / 64 / 4 | 345739 | 54692786 | `b73984972b436413` |
| 64 / 512 / 64 / 128 / 4 | 349159 | 107769983 | `b882e46dc18668cf` |

These exercise FP64 with RV32 scalar operands, larger architectural register
files, four banks, and 128-bit bank byte selection. Different VLEN values change
the workloads; these cycle totals are reproducible results, not a speedup
comparison or evidence of concurrent multi-bank execution.

Each catalog run covers 627 variants and 4,756 candidates, with 28,536 Spike
steps. RV32 accepts 3,626 candidates and rejects 1,130; its 32 unexecuted
variants are the eight NF forms of each of `vluxei64.v`, `vsuxei64.v`,
`vloxei64.v` and `vsoxei64.v`. RV64 accepts 3,882 and rejects 874, with a
successful execution for every variant. Catalog hashes are
`1eed2085fb26498c` and `29581f8eeeb3a6ef`, respectively.

Both context suites pass 32 cases/1,112 Spike steps. Both delayed-store suites
pass 222 cases/1,330 steps, including LMUL=8 stores exceeding a 16-entry SQ
capacity in the modeled final-response interface. Their wait-cycle totals are
242,463 and 274,975. This does not prove progress through the real scalar SQ.

Reproduce with the pinned reference and each suite name:

```sh
make -C verify/vpu top CORE_ADAPTER=1 TOP_SUITE=full DIFF=1 \
  SPIKE_BUILD=/path/to/pinned/spike XLEN=32 VLEN=256 ELEN=64 BANK_BITS=64 BANKS=4
make -C verify/vpu top CORE_ADAPTER=1 TOP_SUITE=full DIFF=1 \
  SPIKE_BUILD=/path/to/pinned/spike XLEN=64 VLEN=512 ELEN=64 BANK_BITS=128 BANKS=4
```

Replace `full` with `catalog`, `context` or `store-completion` for the focused
suites. Build directories encode all five geometry parameters.

## Core-facing encoding legality regression

On 2026-09-06, all three encoding suites passed through `rapt_vpu_core`
(CORE_ADAPTER=1) in both baseline configurations. Every run has a matching
86-file source manifest, VLEN=128, BankBits=64, OPT_READS=1 and seed
`243f6a8885a308d3`; RV32 uses ELEN32/Banks1 and RV64 uses ELEN64/Banks2.

| XLEN | Suite | Candidates | Accepted | Illegal | Other faults | Spike steps |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 32 | encoding | 172032 | 69816 | 102216 | 0 | 344064 |
| 64 | encoding | 229376 | 102068 | 127308 | 0 | 458752 |
| 32 | config-encoding | 14372 | 11392 | 2980 | 0 | 172464 |
| 64 | config-encoding | 14404 | 11424 | 2980 | 0 | 172848 |
| 32 | memory-encoding | 32768 | 5176 | 27550 | 42 | 163840 |
| 64 | memory-encoding | 32768 | 5539 | 27184 | 45 | 163840 |

The current arithmetic scan covers every supported SEW, vs2=0/16, all funct6
values, forms 0–6, VM values and five-bit selectors, comparing the entire VRF.
It fixes LMUL=1, VL=2, vd=8 and FRM=RNE. Configuration cases cover all upper
12-bit encoding patterns at selected scalar identities, VTYPE low bytes,
unsupported upper bits, AVL boundaries and disabled-vector admission. Memory
cases cover all vector width/MEW/NF/MOP/auxiliary/VM fields at SEW8/LMUL1/VL2;
illegal cases require no requests, no dirty event and unchanged VRF/RAM.
All candidates compare trap metadata and applicable scalar/FP outputs with
Spike; memory faults are counted separately from illegal instructions.

These are bounded encoding/behavior sweeps, not exhaustive register geometry,
all rounding modes or full ISA certification. Workload hashes for arithmetic
are `d5eeadc6322a0d76`/`980563747df8e87e`, for configuration
`d0f59095ceafbc8d`/`44148092a026f709`, and for memory
`ed2c7eea69e0544a` in both configurations.

Reproduce with `make -C verify/vpu top CORE_ADAPTER=1 DIFF=1`, the pinned
`SPIKE_BUILD`, the parameters above and `TOP_SUITE=encoding`,
`TOP_SUITE=config-encoding` or `TOP_SUITE=memory-encoding`.

## Selected source-current acceptance audit

Run from the repository root:

```sh
python3 verify/vpu/check_acceptance.py
python3 verify/vpu/test_check_acceptance.py
```

The first command audits existing completed artifacts and writes
`verify/build/vpu/acceptance.json`; it does not rebuild or rerun the underlying
simulations, proofs or mappings. All 30 selected gates pass:

- CORE_ADAPTER=1 full, context, store-completion, geometry and catalog Spike suites for both
  XLEN/ELEN/Banks=32/32/1 and 64/64/2, with VLEN=128, BankBits=64 and OPT_READS=1.
- Full, catalog, context and store-completion suites for both extended
  configurations in the table above.
- Arithmetic, configuration and memory encoding suites through the
  core-facing wrapper in both VLEN128 baseline configurations.
- Owner and core-adapter inductive safety proofs and their mutation checks.
- Memory response payload isolation and its request ownership ledger proof.
- ALU RTL equivalence and leaf LUT reduction.
- Both optimized FPGA mappings, including netlist and primitive provenance checks.

Each gate checks recorded source hashes against the current workspace. Top-suite
checks also require a completed result, the expected configuration and Spike
step count, and the pinned reference revision with recorded library hashes.
Reference identity checks inspect the recorded manifest; they do not rehash the
external Spike installation. Mapping checks inspect the actual netlist counts,
netlist fingerprint, primitive checker and installed primitive library hashes.

The owner/adapter proofs and all eight previous top suites were refreshed after
the catalog-suite addition. Both new catalog runs completed successfully.
The memory isolation proof, ALU proof and optimized maps already matched
current sources. The second command passes the baseline
audit, then verifies rejection of stale source hashes, an incomplete run log,
an incorrect reference revision, wrong VLEN and wrong bank width using isolated
copies of evidence. All five negative checks pass; original artifacts are not altered.

This is a selected evidence audit, not complete V ISA compliance, whole-VPU
formal verification, scalar LSU integration or physical timing acceptance.
Other historical results below retain their original configuration and scope;
they do not become source-current merely because these 30 gates pass.

## Verification scope and subsequent integration work

| Work | Required evidence | State |
| --- | --- | --- |
| Command/authorization/completion ownership | Backpressure, pre-authorization cancellation, slot+generation reuse, stale-response tests | Implemented and simulated; owner control safety proven inductively, external-memory drain validation pending |
| Standalone instruction decode and execution top | Real encoded instruction programs through public interfaces | All baseline catalog entries exercised; arithmetic/configuration/memory encoding and geometry sweeps pass within their documented bounds |
| Integer datapath and element scheduler | Mask, old destination, LMUL/EMUL, legal overlaps, widening/narrowing, fixed-point and permutation tests | Same-width ALU, multiply/divide/MAC, compare/mask logic, carry/borrow, widening/narrowing, extension and fixed-point, integer reductions, whole-register moves and integer scalar transfers verified; VID and scalar mask scans verified; first-bit mask prefixes verified; viota and compression verified; integer slides and gathers integrated; bounded geometry and encoding sweeps pass, exhaustive operand-space proof not claimed |
| Vector memory engine | Unit/strided/indexed/segment/mask/whole-register/FOF operations and address legality | Implemented; independent encoded-instruction simulations and Spike comparisons pass; broader fault/overlap coverage remains |
| Precise memory recovery | Fault at every element/field boundary, restart, delayed errors, no duplicate non-idempotent side effects | Four-element, every-field access/page-fault sweeps and restart pass; real LSU/MMU/drain integration and exhaustive boundary coverage pending |
| FP32/FP64 baseline V | Flags, rounding, conversions, ordered/unordered reductions and independent results | Single-width and widening arithmetic, format and integer conversions, divide/sqrt/estimates, min/max/sign/class/comparison, FP transfers/slide1, single-width/widening reductions and active-element flags integrated; catalog and encoding sweeps pass, full formal ISA semantics not claimed |
| Independent ISA differential adapter | Pinned reference, architectural vector/CSR state and trap-prefix comparison | Pinned Spike adapter covers baseline instruction catalog, arithmetic, configuration, memory and FP families; trap-prefix, geometry and encoding comparisons pass within documented bounds |
| Integration adapter | Explicit scalar operands/results, opaque ROB ownership, CSR and LSU/MMU contracts; no fixed dispatch lane | Ownership/metadata bridge composed with real numerical VPU; scalar-core wiring, completion/CSR mapping and LSU/MMU integration pending |
| Formal/control safety | Non-vacuous ownership, no unauthorized writes, response stability, forward-progress assumptions | Owner inductive control proof passes four parameter sets including current FP command/result widths, 44 reachability witnesses and four detected mutations; full VPU write safety, drain and liveness proofs remain pending |
| Optimization | Fixed workload/configuration/seed baseline and measured improvement with unchanged functional results | Operand-read elimination and early completion measured; current equivalent ALU optimization reduces whole-VPU mapped LUT counts by 10.23% / 5.97% in the two baseline configurations; physical timing remains future work |
| Synthesis readiness | No latches, inferred memories, parameter elaboration, actual resource reports with limitations | Integer/memory/permutation/FP including transfers/slide1, estimates, integer/format conversions, divide/sqrt/misc/widening top plus leaves checked in 72 configurations; whole core-facing VPU mapped to FPGA primitives for two configurations; physical timing pending |

The initial execution design is one architectural vector instruction per owner
entry, expanded internally into elements/chunks. It starts architectural side
effects only after an irrevocable authorization. Larger VLEN must not consume
one scalar ROB entry per element. Vector data remains in the VRF; completion
carries identity, scalar result and state/fault metadata.

Memory requests currently carry command/element/field/probe ownership with
one outstanding request. The future scalar adapter must permit authorized store
progress to drain before the entire instruction retires, avoiding finite-SQ
deadlock. Request acceptance, translation success, store visibility and final
error response are distinct events. Accepted external transactions must drain
before identity reuse. Standalone tests enforce the final-response contract;
implementing it in the real Raptor LSU/SQ/MMU remains pending.

Performance work follows correctness: retain the sequential baseline and
verified operand-read optimization, then improve bank utilization and consider multiple
chunks, chaining and additional memory concurrency. Architectural register
renaming is a later choice requiring measured dependency pressure.

## Specification references

- [RISC-V V 1.0 specification, ISA library v20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/v-st-ext.html)
- [Frozen V 1.0 source, configuration and CSR sections](https://github.com/riscvarchive/riscv-v-spec/blob/v1.0/v-spec.adoc)
- [Spike reference implementation](https://github.com/riscv-software-src/riscv-isa-sim)

Reference tool availability is not a claim that differential tests have run.
