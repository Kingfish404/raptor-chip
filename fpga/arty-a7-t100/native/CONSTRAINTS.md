# Native receiver and pin timing review

This fixture starts at Core10MHz, HalfPeriod8: measured nominal periods must be
100ns core, 800ns between either CK edge and 1600ns per CK cycle. DS is data,
never an internal clock. The MMCM/BUFG vendor-model regression independently
checks all declared core rates and reset/relock. Only the initial10MHz profile
has the following timing allocation. `constraints/budget.json` is the numeric
review input; external acceptance remains false until the fitted device and
carrier satisfy it and the routed endpoints pass.

`receiver_map.py` reads the actual Yosys mapped JSON. It rejects missing or merged
sampling cells, SRLs, inverted/different clocks, broken direct stage links, an
early DS detector, a wrong detector truth table and mismatched lane selection.
Four DS FFs plus two FFs per DQ lane must remain twenty distinct cells on the
same core clock. The late detector must be DS[3] XOR DS[2]. All128 sampled data
bits must depend on the matching DQ second stage and retained sample selector.
The export preserves these cells and assigns stable names for physical checks.
These are board/export attributes; the accepted chip source is unchanged.

`constraints/receiver.tcl` repeats the twenty-FF count, properties, common clock,
stage order, late detector and128-bit data selection checks after synthesis and
after routing. It also checks the actual generated period against configuration.
A successful small-frame mapping proves the auditor runs on real frame RTL; it
does not substitute for the full native-chip export or post-route results.

The receive bound is one total signed envelope of -25..+25ns, on both DS edges.
The following allocations apply to every lane. Their extrema sum to25ns; lane
variation must fit inside the allocations.

| Contribution | Signed allocation | Evidence status |
| --- | --- | --- |
| Target DQ relative to DS | -5..+5ns | Conservative device allocation |
| Connector/carrier lane spread | -5..+5ns | Requires measurement |
| Translation lane spread | -5..+5ns | Requires measurement |
| FPGA input buffer/route spread | -5..+5ns | Each pin-to-first-D constrained0..5ns |
| Sampling uncertainty/setup/hold reserve | -5..+5ns | Reserved in this same budget |
| Total | -25..+25ns | Zero unallocated margin at the envelope boundary |

Both DS and every DQ pin receive a0..5ns pin-to-first-capture path constraint.
The spread between any two such paths cannot exceed5ns. DS1..3 and all DQ second
stages retain normal setup/hold checks. The FPGA route budget is included above;
it must not be added again to a25ns external skew. No sampling/control path or
clock group is false-pathed. An asynchronous first capture is not a synchronous
setup/hold guarantee: CDC findings remain classified as intentional first-stage
sampling with a bounded stable bus and delayed detector. Metastability and
physical margin need separate qualification.

The DDR transmitter changes data/OE at the middle of each800ns half period,
leaving400ns nominal setup and hold at either CK edge. Output-data and OE paths
have0..10ns bounds; independent carrier/translation spread is allocated10ns and
uncertainty5ns. After the target0.4ns setup/hold requirement, the remaining
allocation is374.6ns. The RX25ns envelope is a separate receiver requirement;
it does not justify increasing any transmit or carrier allocation.

The selected MT35XU256ABA Rev. G data sheet Table47 gives the target DDR setup/hold0.4ns,
CS setup2.25ns, CS hold2ns, high interval10ns for reads/30ns otherwise and maximum
output disable6ns. The fixture must check those requirements against actual
fitted-device conditions. Reports expose CK/CS/DQ output paths and each IOBUF
I/T path separately, preserving minimum and maximum timing. Host release occurs
mid-half, before the target can drive read data; read dummy cycles add margin.
The controller holds the final CK/CS phase and a1700ns gap before another frame.
The monitor measures both ownership transitions; no simultaneous host/target
ownership is permitted at either end of the delay model. Target release6ns,
return propagation and host reacquisition must fit the measured gap, rather than
assuming output disable is instantaneous.

Physical reset is shared by the chip and target. Clock lock releases reset;
chip boot selection is controlled by the retained SBA register. Debug reset
preserves the selected target and the Flash protocol state.

The pin simulation measures actual arrival times at the real frame inputs for
each changed DQ lane, accounting for the existing+lane nanosecond delay. Legal
positive cases are+18..25ns and-25..-18ns. The historical+25..32ns case is outside
the contract. It remains negative evidence and cannot qualify the positive
boundary. Digital extrema represent the complete receive envelope; physical
route and uncertainty are not extra terms to append after those extrema.

The implementation retains timing, min/max pin and OE paths, CDC, exceptions,
I/O/bank, clocks, route status, DRC and unconstrained-endpoint reports. External
JTAG/UART/buttons are asynchronous control inputs and remain visible in those
reports; they are not silently waived. TCK on the initial board is limited to
500kHz, below core/8. Internal implementation timing and physical external-I/O
acceptance are recorded separately. No board is programmed by these build rules.

The Tcl uses ordinary max/min constraints and separately bounds the actual
`DATAPATH_DELAY` for rising and falling transitions. It rejects absent/truncated
path collections and nonfinite, negative-slack or over-budget results. Clock
insertion therefore cannot silently enlarge a pin-route allocation. Vivado's
`set_max_delay -datapath_only` creates implicit hold false paths, so it is not
used here. See the [Vivado constraint semantics](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Consequences-of-Setting-Maximum-Delay-or-Minimum-Delay-Constraints-on-a-Path)
and [timing-path properties](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/get_timing_paths).
These executable checks still need the actual assigned Vivado run; structural
Tcl syntax and small-frame mapping do not establish physical-tool success.

## DS/DIAG physical boundary

The FPGA port `flash_dqs` is bidirectional and directly connects to the real
`pad_diag`. Its original DIAG data and OE remain present. A one-way assignment
from an external input into an internal bidirectional wire does not preserve
this boundary; Slang/tri-state conversion can remove its enable. The export
therefore audits the actual full-chip DS/DIAG tri-state, data/OE truth table and
input connection to the first DS FF. The physical implementation must retain
and report its IOBUF input, output-data and T paths. The receive0..5ns and
output/OE0..10ns gates cover this port as well as DQ.

The simulation checks the actual `u_pad_diag.oe_i` through shared reset and clock
relock. Boot control releases DIAG and DQ for two clocks while changing backend.
Physical propagation and possible narrow OE hazards need routed/electrical review.
External I/O acceptance remains open.

The target AC numbers have also been checked against the selected 256 Mb descriptor.
The actual fitted device, carrier and electrical margins still require board
qualification. Keep this distinct from whole-chip logical mapping and internal routed timing.

Transmit maximum-delay constraints use 9 ns to reserve 1 ns for negative source-clock
insertion. Acceptance still checks the actual data path against the 10 ns allocation,
as well as finite positive setup/hold slack. Positive ordinary setup slack alone
cannot establish this path bound.

## Valid physical endpoints

Transmit max/min constraints end at the actual primary output/inout port. IOBUF
I and T are separate through points, not sequential data endpoints. The routed
checks distinguish both T control transitions independently of the four output
max/min rise/fall classes. Every DS/DQ IOBUF must retain an actual OBUFT leaf
with enabled tristate-enable and tristate-disable T-to-O arcs. Each returned
arc is reported separately. Missing, disabled or truncated coverage fails.

The flow saves a synthesis checkpoint and capacity report before later audits,
then a constrained checkpoint after successful constraint application. This
permits diagnosis without repeating synthesis. These artifacts do not replace
routed or external timing qualification.
