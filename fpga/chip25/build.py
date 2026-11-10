#!/usr/bin/env python3
"""Build the shared 25-signal chip fixture; no hardware programming is provided."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ARTY = ROOT / "fpga/arty-a7-t100"
COMMON = ROOT / "fpga/common"
sys.path.insert(0, str(COMMON / "scripts"))
from rtl_pack import include_dirs, rtl_sources
sys.path.insert(0, str(ARTY / "scripts"))
from sources import tool_environment


def run(command, out, name):
    command = list(map(str, command))
    (out / f"{name}-command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (out / f"{name}.log").open("w") as log:
        result = subprocess.run(command, cwd=out, env=tool_environment(), stdout=log,
                                stderr=subprocess.STDOUT, check=False)
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}); see {out / (name + '.log')}")


def programs(out, cross):
    destination = out / "programs"
    destination.mkdir(exist_ok=True)
    run([sys.executable, ARTY / "native/build.py", "programs", "--out", destination,
         "--cross", cross], out, "programs")
    image = (destination / "native-boot.bin").read_bytes()
    (out / "flash.hex").write_text("@00000000\n" + "\n".join(f"{b:02x}" for b in image) + "\n")
    flags = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-nostdlib", "-Os",
             "-ffreestanding", "-fno-pic", "-fno-builtin", "-fno-stack-protector",
             "-msmall-data-limit=0", "-Wl,--no-relax,--build-id=none"]
    run([cross + "gcc", *flags, "-Wl,-T," + str(ARTY / "firmware/boot.ld"),
         "-o", destination / "mrom.elf", ARTY / "firmware/boot.S",
         ARTY / "firmware/boot.c"], out, "rom")
    run([cross + "objcopy", "-O", "binary", destination / "mrom.elf",
         destination / "mrom.bin"], out, "rom-binary")
    run([sys.executable, ARTY / "scripts/hex.py", destination / "mrom.bin", out / "mrom.hex"],
        out, "rom-hex")


def files():
    sources = rtl_sources(ROOT, io25=True)
    sources += [COMMON / "rtl" / name for name in (
        "rapt_xspi_target.sv", "rapt_xspi_flash_target.sv", "rapt_chip25_fixture.sv")]
    sources += sorted(p for p in (ARTY / "rtl").glob("*.sv") if p.name != "rapt_arty_top.sv")
    return sources


def seal_build(out):
    bitstream = out / "rapt_chip25.bit"
    metrics = (out / "metrics.txt").read_text()
    log = (out / "vivado.log").read_text(errors="replace")
    if not bitstream.is_file() or "RAPT_CHIP25_BUILD_PASS" not in log:
        raise RuntimeError("Missing successful routed bitstream evidence")
    record = {"pass": True, "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "bitstream_sha256": hashlib.sha256(bitstream.read_bytes()).hexdigest(),
              "source_manifest_sha256": hashlib.sha256(
                  (out / "sources.json").read_bytes()).hexdigest(),
              "metrics": metrics}
    (out / "artifacts.json").write_text(json.dumps(record, indent=2) + "\n")


def check_return_path(out):
    design = json.loads((out / "mapped.json").read_text())["modules"]["rapt_chip25_cu08"]
    names, cells = design["netnames"], design["cells"]
    target = names.get("u_fixture.g_flash.u_flash.ds_q", {}).get("bits", [])
    receiver = names.get(
        "u_fixture.u_chip.u_chip.u_backend.u_flash.u_nor.u_frame.ds_sync_q", {}
    ).get("bits", [])
    if len(target) != 1 or len(receiver) != 4 or not isinstance(target[0], int):
        raise RuntimeError("Flash DS return disappeared during synthesis")
    capture = [cell for cell in cells.values() if cell["type"].startswith("FD")
               and cell["connections"].get("Q") == receiver[:1]]
    if len(capture) != 1:
        raise RuntimeError("Missing unique Flash DS capture register")
    drivers = {}
    for cell in cells.values():
        for port, direction in cell["port_directions"].items():
            if direction == "output":
                for bit in cell["connections"][port]:
                    if isinstance(bit, int):
                        drivers.setdefault(bit, []).append(cell)
    visited = set()

    def reaches_target(bit):
        if bit == target[0]:
            return True
        if not isinstance(bit, int) or bit in visited:
            return False
        visited.add(bit)
        for cell in drivers.get(bit, []):
            if cell["type"].startswith("FD"):
                continue
            for port, direction in cell["port_directions"].items():
                if direction == "input" and any(
                        reaches_target(value) for value in cell["connections"][port]):
                    return True
        return False

    if not reaches_target(capture[0]["connections"]["D"][0]):
        raise RuntimeError("Flash DS capture has no path from the target's DS register")
    (out / "flash-return-path.json").write_text(json.dumps(
        {"pass": True, "target_bit": target[0], "receiver_bit": receiver[0],
         "scope": "mapped combinational path into the first DS synchronizer"}, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("programs", "target-test", "target-export", "sim",
                                          "export", "synth", "build"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--jobs", type=int, choices=range(1, 5), default=4)
    parser.add_argument("--cross", default="riscv64-elf-")
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--mode", choices=("flash", "bridge"), default="flash")
    parser.add_argument("--full-waits", action="store_true")
    args = parser.parse_args()
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("keep outputs outside the source tree")
    out.mkdir(parents=True, exist_ok=True)
    if args.action == "programs":
        programs(out, args.cross)
        return
    if args.action == "target-test":
        run(["verilator", "--binary", "--timing", "-j", args.jobs, "-Wno-fatal",
             "--timescale", "1ns/1ps", "--top-module", "tb_xspi_flash_target",
             "--Mdir", out / "obj", ROOT / "synth/configs/pin-limited/rtl/rapt_spi_nor.sv",
             ROOT / "synth/configs/pin-limited/rtl/rapt_xspi_frame.sv",
             COMMON / "rtl/rapt_xspi_flash_target.sv",
             COMMON / "tests/tb_xspi_flash_target.sv"], out, "compile")
        run([out / "obj/Vtb_xspi_flash_target"], out, "run")
        if "XSPI_FLASH_TARGET_PASS" not in (out / "run.log").read_text():
            raise RuntimeError("target simulation did not report PASS")
        print("CHIP25_TARGET_TEST_PASS")
        return
    inputs = files()
    includes = include_dirs(ROOT, ROOT / "rtl/configs/chip32-small")
    flags = ["-DRAPT_CORE_CLOCK_MHZ=10", "-DRAPT_MTIME_FREQ_MHZ=1",
             "-DRAPT_FPGA_DSP=1", "-DRAPT_FPGA_LUTRAM=1", *(f"-I{p}" for p in includes)]
    if args.action == "sim":
        if args.mode != "flash":
            parser.error("the pin JTAG adapter currently exercises the Flash composition")
        programs(out, args.cross)
        inputs += [ARTY / "native/sim/rapt_native_monitor.sv", HERE / "sim/rapt_chip25_sim.sv"]
        command = ["verilator", "--cc", "--exe", "--build", "--timing", "-j", args.jobs,
                   "--timescale", "1ns/1ps", "-Wno-fatal", "-Wno-UNOPTFLAT",
                   "--top-module", "rapt_chip25_sim", "--prefix", "Vrapt_arty_native_sim",
                   "--Mdir", out / "obj", f"-GFullWaits={int(args.full_waits)}", *flags,
                   *inputs, ARTY / "native/sim/host.cpp", "-CFLAGS", "-O2", "-o", "native-sim"]
    else:
        if args.action == "target-export":
            inputs = [COMMON / "rtl/rapt_xspi_flash_target.sv"]
            top = "rapt_xspi_flash_target"
            script = "read_slang --single-unit --unroll-limit=200000 -DSYNTHESIS "
            script += f"--top {top} {inputs[0]}\n"
        else:
            programs(out, args.cross)
            inputs += [HERE / "cu08/rapt_chip25_cu08.sv", HERE / "cu08/primitives.sv"]
            top = "rapt_chip25_cu08"
            script = "read_slang --single-unit --unroll-limit=200000 "
            script += "--allow-toplevel-iface-ports -DSYNTHESIS " + " ".join(flags)
            script += f" -G FlashMode={int(args.mode == 'flash')} --top {top} "
            script += " ".join(map(str, inputs)) + "\n"
        script += f"hierarchy -check -top {top}\nproc\nflatten\nmemory_collect\n"
        script += "tribuf -logic\nopt\nbwmuxmap\ntechmap t:$shiftx\nopt\n"
        if args.action != "target-export":
            memory = top + "/c:u_fixture.u_chip.u_chip.u_backend.u_flash.ram"
            addresses = memory + " %ci2 t:$add %i"
            script += f"select -assert-count 1 {memory}\nselect -assert-count 3 {addresses}\n"
            script += f"opt_expr -fine {addresses}\nopt_clean\n"
            for optimization in ("memory_share -nosat", "opt_mem_widen", "memory_dff"):
                script += f"{optimization} {memory}\n"
        script += f"synth_xilinx -family xcup -top {top} -noiopad -noclkbuf\n"
        script += "check -assert\nstat\nwrite_json mapped.json\nwrite_verilog design.v\n"
        (out / "export.ys").write_text(script)
        command = ["yosys", "-Q", "-T", "-m", "slang", "-s", out / "export.ys"]
        captured = out / "inputs"
        captured.mkdir(exist_ok=True)
        for source, name in ((HERE / "cu08/pins.xdc", "pins.xdc"),
                             (HERE / "cu08/rapt_chip25_clocks.v", "clocks.v"),
                             (ARTY / "rtl/rapt_arty_mapped_cells.v", "mapped_cells.v"),
                             (HERE / "cu08/build.tcl", "build.tcl")):
            shutil.copyfile(source, captured / name)
    headers = list((ROOT / "rtl").rglob("*.svh")) + list((ROOT / "sim/include").rglob("*.svh"))
    inputs += headers + [HERE / "build.py", HERE / "cu08/build.tcl", HERE / "cu08/pins.xdc",
                        HERE / "cu08/rapt_chip25_clocks.v", ARTY / "rtl/rapt_arty_mapped_cells.v",
                        ARTY / "native/sim/host.cpp", ARTY / "native/sim/boot.S",
                        ARTY / "native/build.py", COMMON / "scripts/rtl_pack.py",
                        ARTY / "scripts/sources.py", ARTY / "firmware/boot.S",
                        ARTY / "firmware/boot.c", ARTY / "firmware/boot.ld"]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(set(inputs))}
    record = {"configuration": {"action": args.action, "clock_hz": 10000000,
                                "board_clock_hz": 100000000, "config": "chip32-small",
                                "mode": args.mode, "full_waits": args.full_waits,
                                "board": "cu08-ku15p", "boot_mode": "rom-xip"},
              "sources": hashes, "emulated_flash": True,
              "source_revision": subprocess.check_output(
                  ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()}
    record["generated_images"] = {
        name: hashlib.sha256((out / name).read_bytes()).hexdigest()
        for name in ("flash.hex", "mrom.hex") if (out / name).is_file()}
    (out / "sources.json").write_text(json.dumps(record, indent=2) + "\n")
    run(command, out, "sim" if args.action == "sim" else "export")
    if args.action not in {"sim", "target-export"} and args.mode == "flash":
        check_return_path(out)
    if any(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != value
           for p, value in hashes.items()):
        raise RuntimeError("Source changed during build; retain logs and rebuild in isolation")
    if args.action in {"build", "synth"}:
        run([sys.executable, ARTY / "scripts/vivado.py", "--vivado", args.vivado,
             "--out", out, "--script", out / "inputs/build.tcl", args.action], out, "vivado")
        if args.action == "build":
            seal_build(out)
    print(f"CHIP25_{args.action.upper()}_PASS {out}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from None
