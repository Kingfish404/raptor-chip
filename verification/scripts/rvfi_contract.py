#!/usr/bin/env python3
"""Check RVFI effects, HINT metadata or the independent Bare PMA reference."""
import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from yosys_common import ROOT, run_yosys_check

DUT = ROOT / "rtl/backend/rapt_rvfi.sv"
REFERENCE = ROOT / "verification/formal/formal_rvfi_metadata.sv"
EFFECTS_HARNESS = ROOT / "verification/formal/formal_rvfi_metadata.sv"
HINTS_HARNESS = ROOT / "verification/formal/formal_rvfi_metadata.sv"
PLATFORM_HARNESS = ROOT / "verification/formal/formal_rvfi_metadata.sv"
PASS = "SAT proof finished - no model found: SUCCESS!"
FAIL = "SAT proof finished - model found: FAIL!"
INDUCTION = "Induction step proven: SUCCESS!"
MODEL = "SAT solving finished - model found:"


@dataclass
class Check:
    section: str
    name: str
    command: str
    expected: str
    parameters: dict
    witness: Path = None


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_effects(source, xlen, width):
    define = "-DRAPT_RV64" if xlen == 64 else ""
    return (
        "read_slang --threads 1 --single-unit -DFORMAL -DRAPT_RVFI "
        f"{define} -I{ROOT}/rtl/configs/default -I{ROOT}/rtl/include "
        f"--top formal_rvfi_effects -DRAPT_FORMAL_RVFI_EFFECTS -GXLEN={xlen} -GWidth={width} "
        f"{ROOT}/rtl/rapt_pkg.sv {source} {EFFECTS_HARNESS}; "
        "chformal -assume -lower; prep -top formal_rvfi_effects -flatten; "
        "memory_map; opt; check -assert; "
        "select -assert-none t:$anyseq t:$anyconst t:$dlatch; "
    )


def read_hints(dut, xlen, width, channel, mode, reduce_logic=True, *, abc=None):
    rv64 = "-DRAPT_RV64" if xlen == 64 else ""
    command = (
        f"read_slang --threads 1 --single-unit -DFORMAL -DRAPT_RVFI {rv64} "
        f"-I{ROOT}/rtl/configs/default -I{ROOT}/rtl/include --top formal_rvfi_hints -DRAPT_FORMAL_RVFI_HINTS "
        f"-GXLEN={xlen} -GWidth={width} -GChannel={channel} -GPassThrough={mode} "
        f"{ROOT}/rtl/rapt_pkg.sv {dut} {HINTS_HARNESS}; chformal -assume -lower; "
        "prep -top formal_rvfi_hints -flatten; memory_map; opt; check -assert; "
        "select -assert-none t:*ff* t:*latch* t:$anyseq t:$anyconst; "
    )
    if reduce_logic:
        if not abc:
            raise ValueError('yosys-abc is required for HINT proof reduction')
        command += f"techmap; opt; abc -exe {abc} -g AND; opt; check -assert; "
    return command


def read_platform(source, xlen, preset):
    define = "-DRAPT_RV64" if xlen == 64 else ""
    return (
        "read_slang --threads 1 --single-unit --top formal_rvfi_platform_pma -DRAPT_FORMAL_RVFI_PLATFORM "
        f"{define} -DRISCV_FORMAL_XLEN={xlen} "
        f"-I{ROOT}/rtl/configs/{preset} -I{ROOT}/rtl/include "
        f"{ROOT}/rtl/rapt_pkg.sv {source}; "
        "prep -top formal_rvfi_platform_pma -flatten; opt; check -assert; "
        "select -assert-none t:$dff t:$dffe t:$dlatch t:$anyseq t:$anyconst; "
    )


def mutant(source, output, name, old, new):
    text = source.read_text()
    if text.count(old) != 1:
        raise ValueError("Missing unique mutation point: " + name)
    destination = output / ("mutant-" + name + ".sv")
    destination.write_text(text.replace(old, new))
    return destination


def effects_checks(output, abc=None):
    for xlen in (32, 64):
        for width in (1, 2, 3, 4, 8):
            name = f"rv{xlen}-width{width}"
            base = read_effects(DUT, xlen, width)
            parameters = dict(xlen=xlen, width=width)
            yield Check("proofs", name, base + "sat -verify -tempinduct -seq 1 -maxsteps 4 "
                        "-set-def-inputs -set-assumes -set-at 1 reset 1 -prove correct 1",
                        INDUCTION, parameters)
            for event in range(9):
                label = name + f"-event{event}"
                witness = output / (label + ".vcd")
                command = (base + "sat -seq 3 -set-def-inputs -set-assumes "
                           "-set reset 0 -set-at 1 reset 1 -set-at 3 correct 1 "
                           f"-set-at 3 activated[{event}] 1 -show-inputs -show-outputs "
                           f"-dump_vcd {witness}")
                yield Check("covers", label, command, MODEL, dict(event=event, **parameters),
                            witness)
    for name, old, new in (
        ("fault-store-mask", "writes_mem && !rou_cmu.slot[c].rvfi_trap", "writes_mem"),
        ("fault-load-mask", "reads_mem && !rou_cmu.slot[c].rvfi_trap", "reads_mem"),
        ("fault-destination", "rou_cmu.slot[c].rvfi_trap ? 5'b0\n        : ", ""),
        ("zero-register-data", "rvfi_rd_addr[c*5+:5] == 0 ? '0\n        : ", ""),
        ("memory-result-from-prf", "reads_mem ? rou_cmu.slot[c].rvfi_mem_result : '0",
         "reads_mem ? rd_wdata[c] : '0"),
        ("sc-status-from-prf", "&& rou_cmu.slot[c].rvfi_mem_wen",
         "&& (!sc_op || rd_wdata[c] == 0)"),
    ):
        source = mutant(DUT, output, name, old, new)
        witness = output / ("negative-" + name + ".vcd")
        command = (read_effects(source, 32, 2) + "sat -seq 3 -set-def-inputs -set-assumes "
                   "-set reset 0 -set-at 1 reset 1 -prove correct 1 "
                   f"-show-inputs -show-outputs -dump_vcd {witness}")
        yield Check("negative_controls", "negative-" + name, command, FAIL, dict(name=name),
                    witness)


def hints_checks(output, abc=None):
    for xlen in (32, 64):
        for width in (1, 2, 3, 4, 8):
            for channel in range(width):
                for mode in (0, 1, 2):
                    name = f"rv{xlen}-w{width}-c{channel}-mode{mode}"
                    parameters = dict(xlen=xlen, width=width, channel=channel, mode=mode)
                    base = read_hints(DUT, xlen, width, channel, mode, abc=abc)
                    yield Check("proofs", name, base
                                + "sat -verify -set-def-inputs -set-assumes -prove correct 1",
                                PASS, parameters)
                    if mode:
                        continue
                    for kind in range(4):
                        label = name + f"-kind{kind}"
                        register_data = (0x7A << (24*xlen)) if channel == 0 else 0
                        controls = f"-set registers {32*xlen}'h{register_data:x} "
                        if channel:
                            controls += "-set older_valid 1 -set older_rd 24 -set older_result 122 "
                        witness = output / (label + ".vcd")
                        command = (
                            read_hints(DUT, xlen, width, channel, mode, reduce_logic=False)
                            + "sat -set-def-inputs -set-assumes -set trap 0 "
                            + f"-set kind {kind} -set register_index 24 " + controls
                            + "-show-outputs -show observed_rs1 -show observed_rs2 "
                            + "-show observed_rd -show observed_result "
                            + f"-dump_vcd {witness}")
                        fields = dict(kind=kind, xlen=xlen, width=width, channel=channel)
                        yield Check("covers", label, command, MODEL, fields, witness)
    for name, old, new, width, channel in (
        ("source-address", "c_zero_destination ? raw_c[6:2] : ", "", 2, 0),
        ("identity-destination", "identity_write ? raw_c[11:7] : ", "", 2, 0),
        ("youngest-older-forwarding", "for (int older = 0; older < c; older++) begin",
         "for (int older = c - 1; older >= 0; older--) begin", 4, 3),
    ):
        source = mutant(DUT, output, name, old, new)
        controls = "-set older_valid 7 " if name == "youngest-older-forwarding" else ""
        witness = output / ("negative-" + name + ".vcd")
        command = (read_hints(source, 32, width, channel, 0, abc=abc)
                   + "sat -set-def-inputs -set-assumes -set trap 0 " + controls
                   + "-prove correct 1 -show-outputs " + f"-dump_vcd {witness}")
        yield Check("negative_controls", "negative-" + name, command, FAIL, dict(name=name),
                    witness)


def platform_checks(output, abc=None):
    for preset in ("default", "formal"):
        for xlen in (32, 64):
            name = f"{preset}-rv{xlen}"
            base = read_platform(REFERENCE, xlen, preset)
            parameters = dict(preset=preset, xlen=xlen)
            yield Check("proofs", name, base + "sat -verify -set-def-inputs -prove correct 1",
                        PASS, parameters)
            for event in range(6 if xlen == 64 else 5):
                label = name + f"-event{event}"
                witness = output / (label + ".vcd")
                command = (base + "sat -set-def-inputs -set correct 1 "
                           f"-set activated[{event}] 1 -show-inputs -show-outputs "
                           f"-dump_vcd {witness}")
                yield Check("covers", label, command, MODEL, dict(event=event, **parameters),
                            witness)
    for name, old, new in (
        ("sdram-span", "byte_address < 33'h0a2000000", "byte_address < 33'h0a2000004"),
        ("readonly-write", "attributes = 3'b101;", "attributes = 3'b111;"),
        ("plic-width", "!plic || log2len == 2", "1'b1"),
        ("upper-alias", "address[63:32] == 32'b0 || &address[63:32]", "1'b1"),
    ):
        source = mutant(REFERENCE, output, name, old, new)
        witness = output / ("negative-" + name + ".vcd")
        command = (read_platform(source, 64, "formal")
                   + "sat -set-def-inputs -prove correct 1 -show-inputs -show-outputs "
                   + f"-dump_vcd {witness}")
        yield Check("negative_controls", "negative-" + name, command, FAIL, dict(name=name),
                    witness)


PROFILES = {
    "effects": dict(
        source=DUT, harness=EFFECTS_HARNESS,
        checks=effects_checks, timeout=120,
        scope=(
            'RV32/RV64 RVFI adapter with 1/2/3/4/8 retirement lanes: faulting instructions '
            'publish no GPR write or memory access masks; rd=x0 publishes zero data; integer '
            'load/store/LR/SC/AMO mask decoding, completion result/address/write-intent '
            'passthrough independent of PRF data, and unbounded order-count/reset recurrence. '
            'Compressed HINT metadata, producer legality, execution, fault cause, memory data '
            'correctness and architectural retirement are separate.'
        ),
        assumptions=[
            'Contiguous retirement-valid prefix',
        ],
    ),
    "hints": dict(
        source=DUT, harness=HINTS_HARNESS,
        checks=hints_checks, timeout=180,
        scope=(
            'C.ADD/C.MV with x0 destination and C.ADDI identity HINT metadata; RV32/RV64, every '
            'channel of 1/2/3/4/8-lane retirement, arbitrary GPR pre-state and older writes; '
            'trap suppression and passthrough outside normalized NOPs; not complete RVFI/ISA or '
            'retirement-state proof'
        ),
        assumptions=[
            'Non-NOP HINT cases use a nonzero register index',
            'PassThrough=1 uses an uncompressed instruction encoding',
            'PassThrough=2 excludes a normalized NOP with physical rd=0',
        ],
    ),
    "platform": dict(
        source=REFERENCE, harness=PLATFORM_HARNESS,
        checks=platform_checks, timeout=120,
        scope=(
            'Default/formal platform physical R/W/X permissions, bytewise scalar spans, '
            'read-only memory, device alignment/PLIC width and RV64 upper-address aliases. All '
            'addresses and sizes 1/2/4/8 are checked; instruction fetch accepts sizes 2/4. This '
            'qualifies the Bare PMA reference only; translation, PMP and integrated fault '
            'delivery remain separate.'
        ),
        assumptions=[
        ],
    ),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", choices=PROFILES, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int)
    args = parser.parse_args()
    profile = PROFILES[args.contract]
    timeout = profile["timeout"] if args.timeout is None else args.timeout
    if timeout < 1:
        parser.error("Timeout must be positive")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty to preserve previous evidence")
    abc = shutil.which("yosys-abc") if args.contract == "hints" else None
    if args.contract == "hints" and not abc:
        parser.error("yosys-abc is required for combinational proof reduction")
    paths = [ROOT, output]
    if abc:
        paths.append(Path(abc))
    for path in paths:
        if any(c.isspace() or c in ';"' for c in str(path)):
            parser.error("Yosys paths cannot contain whitespace, quotes or semicolons")
    output.mkdir(parents=True, exist_ok=True)
    sources = [profile["source"], profile["harness"], ROOT / "rtl/rapt_pkg.sv",
               Path(__file__), Path(__file__).with_name("yosys_common.py")]
    folders = ["rtl/include", "rtl/configs/default"]
    if args.contract == "platform":
        folders.append("rtl/configs/formal")
    for folder in folders:
        sources += sorted((ROOT / folder).rglob("*.svh"))
    fingerprints = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    result = dict(complete=False, whole_rtl_signoff=False, contract=args.contract,
                  sources=fingerprints, proofs=[], covers=[], negative_controls=[],
                  scope=profile["scope"], assumptions=profile["assumptions"],
                  yosys=subprocess.check_output(
                      [os.environ.get("RAPTOR_YOSYS_REAL", "yosys"), "-V"], text=True).strip())
    if abc:
        result["abc"] = dict(path=abc, version=subprocess.check_output(
            [abc, "-c", "version"], text=True))
        result["logic_reduction"] = "techmap, ABC AND mapping and opt preserve the same property"

    def save():
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    save()
    for check in profile["checks"](output, abc):
        row = run_yosys_check(check.command, output, check.name, timeout, check.expected,
                              check.witness)
        result[check.section].append(dict(check.parameters, **row))
        save()
        if check.section == "proofs":
            print("PASS: " + check.name, flush=True)
    if fingerprints != {str(p.relative_to(ROOT)): sha(p) for p in sources}:
        raise RuntimeError("RVFI proof inputs changed during execution")
    result["complete"] = True
    save()
    print("FORMAL COMPLETE: RVFI " + args.contract, flush=True)


if __name__ == "__main__":
    main()
