# Actual local RAM normalization checks

These proof/replay helpers target the pre-ROM peripheral source with SHA-256
`2cfb7b6ad95b7314a76b12d829d04d5cba5576c0e7647ba39e89a5cd40f02ccf`.
`export_local.py` intentionally rejects another revision. The ROM-enabled source
needs its own newly bound proof; the historical proof does not qualify it.
Helpers select at most four CPUs from the caller's allowed affinity and retain
their existing taskset, timeout and nice limits. No host-specific CPU IDs are required.

The candidate changes only the FPGA export. The accepted chip source stays
byte-identical. The8KiB local RAM originally has four asynchronous byte-read
ports and four synchronous byte-write ports. Its aligned lane addresses permit
one2048x32 word with byte write enables. RD port ordinals are3,2,1,0 by lane;
WR ordinals are0,1,2,3. Never equate their ordinal order.

The scoped pass sequence folds exactly three direct RAM address adders, runs
global dead-code/alias cleanup, then memory_share -nosat, opt_mem_widen and
memory_dff on only that RAM. It adds no no-rw-check or initialization. In the
actual design memory_dff finds no output FF; it absorbs the actual address FF
through two explicit CE/SRST muxes. data_q and the AXI FSM are retained.

`normalize_actual.py` consumes the actual full-chip pre-mapping RTLIL and audits
every pre-existing cell. It compares exact cell statements while ignoring only
statement order. The expected delta is one changed RAM, three removed address
adders and two added address CE/SRST muxes. Any other existing-cell change fails.
`map_extracted.py` preserves the actual normalized memory cell and its complete
parameters/clock/byte enables in a small top before XC7 technology mapping.

`export_local.py` elaborates the complete original rapt_axi_flash peripheral
from the accepted source, then emits gold and gate Verilog around the same
scoped sequence. Only serial wait counters are shortened in this local test;
that is not startup/physical qualification. `make_miter.py` compares every
peripheral output, including invalid-cycle rdata and serial pins. Its one-time
simulation-only initialization establishes a related nonzero memory state:

    gold.ram[4*row+lane] == gate.ram[row][8*lane+:8]

No production RAM initialization or clear loop is introduced. Warm/reset-in-
transaction tests never repeat this initialization. `miter.cpp` additionally
checks against a software8KiB byte model, exact AR-to-RVALID latency, all byte
addresses, word addresses, all16 write masks, unaligned reads, bursts, stalls,
error suppression and late-error behavior, MMIO, a serial error path and reset
retention. This simulation does not establish every possible initial state.

`prove_local.py` binds to actual original and normalized JSON. It proves the
actual13bit address adders over all11bit rows and checks actual data/enable bit
aliases. It extracts the actual original address FF and both new muxes and
proves their CE/SRST retiming by induction. A separate symbolic watched-row
invariant uses any of the2048 rows and arbitrary related initial32bit contents.
Verified address/data/enable bijections justify that abstraction. It checks
byte updates and same-row transparent write/read behavior. Negative controls
swap byte enables and remove transparency; both must produce counterexamples.

This is a scoped local relation proof and a complete-peripheral replay. It is
not a full-chip LEC, a physical BRAM proof, routed timing or board qualification.
A proper initial reset is required before architectural observations; no
claim is made about unrelated power-up states before that reset.

Example commands (put all generated output outside the source snapshot):

```sh
python3 normalize_actual.py --input <actual-unmapped.il> --out <new-normalized-dir>
python3 map_extracted.py --input <new-normalized-dir>/normalized.json --out <new-map-dir>
python3 prove_local.py --original <new-normalized-dir>/original.json \
  --normalized <new-normalized-dir>/normalized.json \
  --scope-result <new-normalized-dir>/finish.json --out <new-proof-dir>
python3 export_local.py --repo <accepted-source-snapshot> --out <new-local-dir>
python3 make_miter.py <new-local-dir>
```

Compile the emitted gold.v/gate.v/miter.sv plus miter.cpp with Verilator,
including new-local-dir for initial_inputs.inc, using at most4 compile jobs.
Exact actual commands and SHA256 inputs accompany each recorded run. The test
binary takes a deterministic integer seed; the accepted local replay uses1,7,42.


## ROM-aware peripheral replay

The separate `export_rom_local.py` pins the ROM-aware peripheral source to SHA-256
`f06b93ed114b7ba427a58f6e887db4bf7e625f07f063f5aa0eb4769bebc5b8a4`.
It does not change the historical `export_local.py` guard or extend the old proof.
It exports the complete peripheral with `BootRom=0` or `BootRom=1` around the same
RAM-only transformation. `miter_rom.cpp` adds the reset-window LUI/JALR/NOP oracle,
ROM read-only errors and RAM/ROM response-sharing checks.

Requirements are Linux CPU affinity, Python3, GNU timeout/taskset, Yosys with the
Slang plugin, Verilator and a C++ compiler. Run from the repository root, with the
checked-in decoder outputs present. Use paths without whitespace: the exporter
writes source paths directly into a Yosys script. Set `BUILD_DIR` to a fresh absolute
directory outside the checkout. Each ROM value needs a distinct output directory.

```sh
set -eu
: "${BUILD_DIR:?Set a fresh absolute output directory outside this checkout}"
REPO_DIR=$PWD
TEST_DIR=fpga/arty-a7-t100/native/tests/ram_opt
CPU_LIST=$(python3 - <<'PY_CPU'
import os
cpus = sorted(os.sched_getaffinity(0))[:4]
if not cpus:
    raise RuntimeError("no available CPUs")
print(",".join(map(str, cpus)))
PY_CPU
)

for BOOT_ROM in 0 1; do
    run_dir="$BUILD_DIR/rom-$BOOT_ROM"
    python3 "$TEST_DIR/export_rom_local.py" \
        --repo "$REPO_DIR" --out "$run_dir" --boot-rom "$BOOT_ROM"
    python3 "$TEST_DIR/make_miter.py" "$run_dir"
    timeout --signal=TERM --kill-after=3s 120s \
        taskset -c "$CPU_LIST" nice -n 5 \
        verilator --cc --exe --build -j 1 --top-module ram_opt_miter \
        --Mdir "$run_dir/obj" -Wno-fatal \
        --output-split 10000 --output-split-cfuncs 200 \
        --x-initial unique --x-assign unique \
        "$run_dir/gold.v" "$run_dir/gate.v" "$run_dir/miter.sv" \
        "$REPO_DIR/$TEST_DIR/miter_rom.cpp" \
        -CFLAGS "-O1 -I$run_dir -DRAM_PROOF_BOOT_ROM=$BOOT_ROM" -o ram-opt-miter
    for seed in 1 7 42; do
        timeout --signal=TERM --kill-after=3s 30s \
            taskset -c "$CPU_LIST" nice -n 5 "$run_dir/obj/ram-opt-miter" "$seed"
    done
done
```

The C++ flag `RAM_PROOF_BOOT_ROM` is mandatory and must equal the exporter's
`--boot-rom` value; otherwise the expected reset-window behavior is wrong. Keep
`control.json`, `finish.json`, the generated inputs and each seed's output. Record
tool versions and selected preset/header revisions with the source hashes. Success
is an actual zero exit plus `"pass":true`; do not
advance after a failed export or build. ROM1 must report nonzero `rom_beats`.

This replay uses Verilator's two-state model. Comparisons start only after the
initial reset; a one-time simulation initializer establishes the related nonzero
RAM contents. No production clear or INIT is added. Reset, warm-reset and retention
checks do not repeat that initializer. The clock parameter is10MHz/HalfPeriod8 and
startup/reset/recovery/poll waits are shortened to2/2/2/64 cycles. This is finite
functional coverage, not proof of every initial state, four-state behavior, full-core
equivalence, physical memory timing or board startup.

## Actual RAM relation inputs

The existing `normalize_actual.py` and `prove_local.py` also consume a fresh actual
pre-mapping export with the matching source/configuration fingerprint. Their default
contract expects top `rapt_arty_native_top` and cell
`u_chip.u_chip.u_backend.u_flash.ram`. Supply its external path as `UNMAPPED_IL`;
this command does not create or qualify a new whole-core export.

```sh
set -eu
: "${BUILD_DIR:?Set a fresh absolute output directory outside this checkout}"
TEST_DIR=fpga/arty-a7-t100/native/tests/ram_opt
: "${UNMAPPED_IL:?Set the actual pre-mapping RTLIL with its source manifest}"
python3 "$TEST_DIR/normalize_actual.py" \
    --input "$UNMAPPED_IL" --out "$BUILD_DIR/actual-normalized"
python3 "$TEST_DIR/prove_local.py" \
    --original "$BUILD_DIR/actual-normalized/original.json" \
    --normalized "$BUILD_DIR/actual-normalized/normalized.json" \
    --scope-result "$BUILD_DIR/actual-normalized/finish.json" \
    --out "$BUILD_DIR/actual-proof"
```

Do not pass the leaf `gold.json`, `gate.json` or leaf `finish.json` to this SAT entry:
they have different tops and do not contain the audited added-cell list. The actual
relation checks address/data/enable bindings, the clock/CE/SRST address cone and a
symbolic related watched row. Its three positive proofs must return0 and the two
lane/transparency negative controls must return the expected counterexamples;
`result.json` must report `all_pass=true`. That is a RAM-local relation, not full-chip
LEC or physical primitive qualification. The six ROM replays are separate finite
checks and do not enlarge this symbolic proof scope.
