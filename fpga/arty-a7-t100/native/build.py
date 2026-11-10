#!/usr/bin/env python3
"""Build only the native Arty fixture, with all generated files outside its source tree."""

import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "fpga/common/scripts"))
from rtl_pack import include_dirs, rtl_sources
sys.path.insert(0, str(HERE.parent / "scripts"))
from sources import tool_environment


def run(command, directory, name):
    command = list(map(str, command))
    (directory / f"{name}-command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (directory / f"{name}.log").open("w") as log:
        result = subprocess.run(command, cwd=directory, env=tool_environment(), stdout=log,
                                stderr=subprocess.STDOUT, check=False)
    if result.returncode:
        log_path = directory / (name + ".log")
        raise RuntimeError(f"{name} failed ({result.returncode}); inspect {log_path}")


def files():
    return rtl_sources(ROOT, io25=True) + [HERE / "rtl/rapt_arty_native_top.sv"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = ("lint", "programs", "sim", "export", "clock-test", "monitor-test")
    parser.add_argument("action", choices=actions)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--config", default="chip32-small")
    parser.add_argument("--clock-hz", type=int, choices=(10000000, 20000000, 25000000,
                                                      50000000, 100000000), default=10000000)
    parser.add_argument("--jobs", type=int, choices=range(1, 5), default=2)
    parser.add_argument("--cross", default="riscv64-elf-")
    parser.add_argument("--vivado", default=os.environ.get("VIVADO", "vivado"))
    parser.add_argument("--delay-ns", type=int, default=20)
    parser.add_argument("--return-ns", type=int)
    parser.add_argument("--dq-skew-ns", type=int, default=0)
    parser.add_argument("--full-waits", action="store_true",
                        help="simulate the full >2 s startup, rather than shortened wait counters")
    args = parser.parse_args()
    if args.return_ns is None:
        args.return_ns = args.delay_ns
    if min(args.delay_ns, args.return_ns, args.return_ns + args.dq_skew_ns) < 0:
        parser.error("wire delays must be nonnegative")
    out = args.out.resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("put generated outputs outside the source tree")
    out.mkdir(parents=True, exist_ok=True)
    if args.action == "clock-test":
        vivado = Path(shutil.which(args.vivado) or args.vivado).resolve()
        support = vivado.parent.parent / "data/verilog/src"
        run(["iverilog", "-g2012", "-s", "tb_native_clocks", "-s", "glbl",
             "-y", support / "unisims", "-o", out / "clocks.vvp",
             HERE / "rtl/rapt_arty_native_clocks.v", HERE / "tests/tb_native_clocks.sv",
             support / "glbl.v"], out, "clock-compile")
        run(["vvp", out / "clocks.vvp"], out, "clock-run")
        if "NATIVE_CLOCKS_PASS:" not in (out / "clock-run.log").read_text():
            raise RuntimeError("native clock test did not report PASS")
        print("Native clock primitive test PASS: five frequencies and reset/relock")
        return
    if args.action == "monitor-test":
        for skew in (18, -25, 19):
            case = out / f"skew{skew}"
            case.mkdir(exist_ok=True)
            run(["verilator", "--binary", "--timing", "-j", args.jobs, "-Wno-fatal",
                 "--top-module", "tb_native_monitor", f"-GBaseSkewNs={skew}",
                 "--Mdir", case / "obj", HERE / "sim/rapt_native_monitor.sv",
                 HERE / "tests/tb_native_monitor.sv"], case, "compile")
            command = [str(case / "obj/Vtb_native_monitor")]
            (case / "run-command.json").write_text(json.dumps(command) + "\n")
            with (case / "run.log").open("w") as log:
                result = subprocess.run(command, cwd=case, stdout=log,
                                        stderr=subprocess.STDOUT, check=False)
            transcript = (case / "run.log").read_text()
            accepted = (result.returncode == 0 and "NATIVE_MONITOR_PASS" in transcript)
            if skew == 19:
                accepted = result.returncode != 0 and "exceeds envelope" in transcript
            receipt = {"pass": accepted, "base_skew_ns": skew,
                       "expected_rejection": skew == 19, "exit": result.returncode}
            (case / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
            if not accepted:
                raise RuntimeError(f"native monitor case {skew} failed; inspect {case}")
        print("Native pin monitor PASS: both signed bounds, both edges and expected rejection")
        return
    uart_divisor = (args.clock_hz + 8 * 57600) // (16 * 57600)
    if args.action == "programs":
        entry = 0x30000000
        run([args.cross + "gcc", "-march=rv32i_zicsr", "-mabi=ilp32", "-nostdlib",
             "-nostartfiles", f"-DNATIVE_UART_DIVISOR={uart_divisor}",
             f"-Wl,-Ttext={entry:#x},--no-relax,--build-id=none",
             "-o", out / "native-boot.elf", HERE / "sim/boot.S"], out, "firmware")
        run([args.cross + "objcopy", "-O", "binary", out / "native-boot.elf",
             out / "native-boot.bin"], out, "objcopy")
        image = (out / "native-boot.bin").read_bytes()
        (out / "native-boot.hex").write_text("@00800000\n" + "\n".join(f"{b:02x}" for b in image)
                                            + "\n")
        run([args.cross + "objdump", "-d", out / "native-boot.elf"], out, "disassembly")
        evidence = {"physical_storage_offset": 0x800000, "reset_pc": 0x20000000,
                    "boot_mode": "rom-xip", "payload_entry": entry,
                    "core_clock_hz": args.clock_hz, "uart_divisor": uart_divisor,
                    "binary_sha256": hashlib.sha256(image).hexdigest(), "bytes": len(image),
                    "source_sha256": hashlib.sha256((HERE / "sim/boot.S").read_bytes()).hexdigest()}
        (out / "firmware.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Native boot firmware: {len(image)} bytes, physical offset 0x800000")
        return
    inputs = files()
    includes = include_dirs(ROOT, ROOT / "rtl/configs" / args.config)
    flags = [f"-DRAPT_CORE_CLOCK_MHZ={args.clock_hz // 1000000}",
             "-DRAPT_MTIME_FREQ_MHZ=1", *(f"-I{p}" for p in includes)]
    if args.action in {"lint", "sim"}:
        inputs += [HERE / "sim/clocks.sv"]
        if args.action == "lint":
            command = ["verilator", "--lint-only", "--timing", "-Wno-fatal",
                       "--top-module", "rapt_arty_native_top", "--Mdir", out / "lint",
                       f"-GCoreClockHz={args.clock_hz}",
                       *flags, *inputs]
        else:
            inputs += [ROOT / "verification/models/rapt_xspi_profile1_model.sv",
                       HERE / "sim/rapt_native_monitor.sv",
                       HERE / "sim/rapt_arty_native_sim.sv"]
            command = ["verilator", "--cc", "--exe", "--build", "--timing", "-j", args.jobs,
                       "--timescale", "1ns/1ps", "-Wno-fatal", "-Wno-UNOPTFLAT",
                       "--top-module", "rapt_arty_native_sim", "--Mdir", out / "obj",
                       f"-GCoreClockHz={args.clock_hz}", f"-GBoardDelayNs={args.delay_ns}",
                       f"-GReturnDelayNs={args.return_ns}",
                       f"-GReturnDqSkewNs={args.dq_skew_ns}",
                       f"-GFullWaits={int(args.full_waits)}",
                       *flags, *inputs,
                       HERE / "sim/host.cpp", "-CFLAGS",
                       f"-O2 -DNATIVE_CORE_HZ={args.clock_hz} "
                       f"-DNATIVE_UART_DIVISOR={uart_divisor}",
                       "-o", "native-sim"]
    else:
        inputs += [HERE / "primitives.sv"]
        yosys_flags = ["--single-unit", "--unroll-limit=100000", "--allow-toplevel-iface-ports",
                       "-DSYNTHESIS", "-DRAPT_FPGA_DSP=1", "-DRAPT_FPGA_LUTRAM=1", *flags]
        script = "read_slang " + " ".join(yosys_flags)
        script += f" -G CoreClockHz={args.clock_hz} "
        script += "--top rapt_arty_native_top "
        script += " ".join(map(str, inputs)) + "\n"
        # Restore the parametric library declaration for ABC9; Slang's blackbox
        # stub has no deferred parameter AST. This changes no chip logic.
        script += f"read_verilog -sv -lib -overwrite {HERE / 'primitives.sv'}\n"
        script += "hierarchy -check -top rapt_arty_native_top\nproc\nflatten\n"
        for signal in ("ds_sync_q", "dq_meta_q", "dq_sync_q", "ds_edge", "sample_ds", "data_o"):
            selected = f"w:*u_frame.{signal}"
            script += f"select -assert-count 1 {selected}\nsetattr -set keep 1 {selected}\n"
            if signal in {"ds_sync_q", "dq_meta_q", "dq_sync_q"}:
                script += f"setattr -set keep 1 {selected} %ci1 t:$dff %i\n"
        for signal in ("u_chip.diag", "u_chip.diag_oe"):
            script += f"select -assert-count 1 w:{signal}\nsetattr -set keep 1 w:{signal}\n"
        script += "memory_collect\ntribuf -logic\nopt\nbwmuxmap\ntechmap t:$shiftx\nopt\n"
        script += "select -assert-none t:$shiftx\ncheck -assert\nwrite_rtlil unmapped.il\n"
        # Normalize only the local RAM's three byte-lane address adders. Keep
        # its synchronous write/transparent read semantics; no reset/INIT is
        # added. Global opt_clean only removes dead aliases after those adds.
        memory = "rapt_arty_native_top/c:u_chip.u_chip.u_backend.u_flash.ram"
        addresses = memory + " %ci2 t:$add %i"
        script += f"select -assert-count 1 {memory}\n"
        script += f"select -assert-count 3 {addresses}\n"
        script += f"opt_expr -fine {addresses}\nopt_clean\n"
        for command in ("memory_share -nosat", "opt_mem_widen", "memory_dff"):
            script += f"{command} {memory}\n"
        script += "synth_xilinx -family xc7 -top rapt_arty_native_top -noiopad -noclkbuf\n"
        script += "setparam -set READ_WIDTH_A 1 t:RAMB36E1 r:READ_WIDTH_A=0 %i "
        script += "r:RAM_EXTENSION_A=NONE %d\n"
        script += "setparam -set WRITE_WIDTH_B 1 t:RAMB36E1 r:WRITE_WIDTH_B=0 %i "
        script += "r:RAM_EXTENSION_B=NONE %d\n"
        script += "check -assert\nwrite_json mapped.json\n"
        captured = out / "inputs"
        captured.mkdir(exist_ok=True)
        for source, name in ((HERE / "constraints/pins.xdc", "pins.xdc"),
                             (HERE / "rtl/rapt_arty_native_clocks.v", "clocks.v"),
                             (HERE.parent / "rtl/rapt_arty_mapped_cells.v", "mapped_cells.v"),
                             (HERE / "build.tcl", "build.tcl"),
                             (HERE / "constraints/receiver.tcl", "receiver.tcl")):
            shutil.copyfile(source, captured / name)
        configuration = f"set native_core_hz {args.clock_hz}\n"
        configuration += f"set native_half_period {max(8, (args.clock_hz + 9999999) // 10000000)}\n"
        (captured / "config.tcl").write_text(configuration)
        (out / "export.ys").write_text(script)
        command = ["yosys", "-Q", "-T", "-m", "slang", "-s", out / "export.ys"]
    headers = sorted((ROOT / "rtl").rglob("*.svh"))
    headers += sorted((ROOT / "sim/include").rglob("*.svh"))
    suffixes = {".sv", ".v", ".py", ".cpp", ".S", ".tcl", ".xdc", ".mk", ".json"}
    extras = [p for p in HERE.rglob("*") if p.is_file() and p.suffix in suffixes
              and "__pycache__" not in p.parts]
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(set(inputs + headers + extras))}
    record = {"configuration": vars(args) | {"out": str(out)}, "sources": source_hashes,
              "physical_storage_offset": 0x800000, "physical_write_start": 0x800000,
              "physical_write_end": 0x1000000, "native_path": True}
    (out / "sources.json").write_text(json.dumps(record, indent=2) + "\n")
    run(command, out, args.action)
    if args.action == "export":
        run([sys.executable, HERE / "receiver_map.py", out / "mapped.json",
             out / "mapped-kept.json", out / "receiver-map.json"], out, "receiver-map")
        run([sys.executable, HERE / "io_map.py", out / "mapped-kept.json",
             out / "io-map.json"], out, "io-map")
        final_script = "read_json mapped-kept.json\ncheck -assert\nwrite_verilog design.v\n"
        (out / "preserve.ys").write_text(final_script)
        run(["yosys", "-Q", "-T", "-s", out / "preserve.ys"], out, "preserve")
    print(f"Native Arty {args.action} build PASS; evidence in {out}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from None
