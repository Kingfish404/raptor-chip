"""Native Arty Profile 1 diagnostics over either simulated pins or the real CPU TAP."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import sys
import time

from .client import BringupError
from .native_flash import CONTROL, END, FIRST, NativeFlash, PartitionSession, RAM, SECTOR, Sba32
from .native_links import OpenOcdTarget, ROOT, SimTarget


def integer(text):
    return int(text, 0)


def word_count(text):
    value = int(text)
    if not 1 <= value <= 1024:
        raise argparse.ArgumentTypeError("word count must be between 1 and 1024")
    return value


def output_path(path):
    path = path.resolve()
    if path == ROOT or ROOT in path.parents:
        raise ValueError("store run outputs outside the source tree")
    return path


def hardware_receipt(args, flash):
    if args.sim:
        return
    if not args.hardware_receipt:
        raise ValueError("physical boot/mutation/recovery requires the reviewed hardware receipt")
    evidence = json.loads(args.hardware_receipt.read_text())
    if (not evidence.get("native_path") or evidence.get("board_serial") != args.board_serial
            or evidence.get("probe_serial") != args.probe_serial):
        raise BringupError("hardware receipt is for a different path, board or probe")
    for key in ("bitstream_sha256", "source_manifest_sha256", "readonly_boot_sha256"):
        value = evidence.get(key, "")
        if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise BringupError(f"hardware receipt lacks {key}")
    if args.command == "boot":
        if evidence.get("boot_mode") != "rom-xip":
            raise BringupError("hardware receipt boot mode differs from the requested build")
        if hashlib.sha256(args.boot_bin.read_bytes()).hexdigest() != evidence["readonly_boot_sha256"]:
            raise BringupError("boot image differs from the preconfiguration read-only payload")
    if args.command == "scratch":
        originals = evidence.get("upper_originals", {})
        required = {FIRST, args.offset - SECTOR, args.offset, args.offset + SECTOR}
        if not required.issubset({int(key, 16) for key in originals}):
            raise BringupError("preconfiguration backups must include boot, target and neighbours")
        for address in required:
            item = originals[f"{address:08x}"]
            data = Path(item["path"]).read_bytes()
            if len(data) != SECTOR or hashlib.sha256(data).hexdigest() != item["sha256"]:
                raise BringupError("preconfiguration backup has changed")
            if flash.read(address, SECTOR) != data:
                raise BringupError("native data differs from the old-fixture backup; no erase allowed")


def fresh_boot(target, bus, flash, image, timeout):
    image = bytes(image)
    if not image or len(image) > 65536:
        raise ValueError("use the explicit read-only reset-PC payload, at most 64 KiB")
    if flash.read(FIRST, len(image)) != image:
        raise BringupError("reset-PC storage differs from the approved read-only boot payload")
    target.halt()
    if (bus.read32(0x20000000), bus.read32(0x20000004)) != (0x300002b7, 0x00028067):
        raise BringupError("reset ROM differs from the fixed XIP trampoline")
    bus.write32(RAM + 0x1f00, 0)
    bus.write32(RAM + 0x1f04, 0)
    target.reset_halt()
    if bus.read32(RAM + 0x1f04) != 0:
        raise BringupError("stale completion survived the reset-halt preflight")
    if isinstance(target, SimTarget):
        target.console()
    target.resume()
    deadline = time.monotonic() + timeout
    while bus.read32(RAM + 0x1f04) != 0x524a5332:
        if time.monotonic() >= deadline:
            raise BringupError("fresh native CPU boot timed out")
    target.halt()
    signature = bus.read32(RAM + 0x1f00)
    dpc = target.register(0x7b1)
    entry = 0x30000000
    if signature != 0x524a5331 or not entry <= dpc < entry + 0x10000:
        raise BringupError("native boot signature or payload execution address differs")
    return {"signature": signature, "completion": 0x524a5332, "dpc": dpc,
            "physical_boot_offset": FIRST, "fresh_completion": True,
            "boot_mode": "rom-xip", "reset_pc": 0x20000000, "payload_entry": entry}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    link = parser.add_mutually_exclusive_group(required=True)
    link.add_argument("--sim", type=Path)
    link.add_argument("--probe-serial")
    parser.add_argument("--board-serial")
    parser.add_argument("--image", type=Path, help="simulation boot-memory HEX file")
    parser.add_argument("--boot-bin", type=Path, help="approved read-only reset-PC BIN")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--hardware-receipt", type=Path)
    parser.add_argument("--openocd", default="openocd")
    parser.add_argument("--dmi-trace", action="store_true",
                        help="per-DMI JSON trace; disables fast OpenOCD batches")
    parser.add_argument("--console-port")
    parser.add_argument("--console-baud", type=int, default=57600)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--offset", type=integer, default=FIRST + 0x10000)
    parser.add_argument("--length", type=integer, default=256)
    parser.add_argument("--words", type=word_count, metavar="1..1024", default=1024)
    parser.add_argument("--seed", type=integer, default=0x52415054)
    parser.add_argument("--chip-serial", default="FPGA-EMULATION")
    parser.add_argument("command", choices=("probe", "boot", "scratch", "read", "recover"))
    args = parser.parse_args(argv)
    if args.sim and not args.image:
        parser.error("--sim requires the explicit --image HEX file")
    if not args.sim and not args.board_serial:
        parser.error("real hardware requires the explicitly authorized --board-serial")
    if args.command == "boot" and not args.boot_bin:
        parser.error("boot requires --boot-bin; no arbitrary existing image is executed")
    if args.command == "scratch" and (not args.backup or args.offset % SECTOR
                                     or args.offset < FIRST + SECTOR
                                     or args.offset + 2 * SECTOR > END):
        parser.error("scratch needs --backup and a sector with two upper-partition neighbours")
    if args.command == "read" and (args.length <= 0 or args.offset < FIRST
                                  or args.offset >= END or args.length > END - args.offset):
        parser.error("native reads must stay inside the mapped upper partition")
    out = output_path(args.output)
    out.mkdir(parents=True, exist_ok=False)
    if args.backup:
        args.backup = output_path(args.backup)
    target, console = None, None
    result = {"pass": False, "scope": f"native-{args.command}", "chip_serial": args.chip_serial,
              "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "conditions": {"simulation": bool(args.sim), "board_serial": args.board_serial,
                             "probe_serial": args.probe_serial, "boot_mode": "rom-xip"},
              "lower_partition_compare": "separate old-fixture readback required"}
    host_names = ("native.py", "native_links.py", "native_flash.py", "client.py")
    result["host_sources"] = {
        name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
        for name in host_names}
    if args.boot_bin:
        result["boot_binary_sha256"] = hashlib.sha256(args.boot_bin.read_bytes()).hexdigest()
    if args.sim:
        manifest = args.sim.resolve().parent.parent / "sources.json"
        result["inputs"] = {
            "simulator_sha256": hashlib.sha256(args.sim.read_bytes()).hexdigest(),
            "memory_image_sha256": hashlib.sha256(args.image.read_bytes()).hexdigest(),
            "source_manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
            "simulation_configuration": json.loads(manifest.read_text())["configuration"],
        }
    try:
        target = (SimTarget(args.sim, args.image, out / "rtl.log",
                            args.timeout, args.dmi_trace) if args.sim else
                  OpenOcdTarget(args.probe_serial, out / "openocd.log", args.openocd,
                                speed_khz=500, timeout=10, trace_dmi=args.dmi_trace))
        result["idcode"] = target.idcode()
        bus = Sba32(target, timeout=args.timeout)
        bus.require()
        flash = NativeFlash(bus)
        if args.command == "recover":
            hardware_receipt(args, flash)
            if tuple(bus.read32(CONTROL + n) for n in (0x30, 0x34, 0x38)) != (FIRST, FIRST, END):
                raise BringupError("hardware guards differ; explicit recovery refused")
            target.halt()
            result["device"] = flash.recover()
        else:
            result["device"] = flash.identify(timeout=args.timeout)
        if args.command in {"boot", "scratch"}:
            hardware_receipt(args, flash)
        if args.command == "boot":
            if args.console_port:
                import serial
                console = serial.Serial(args.console_port, args.console_baud, timeout=0)
                console.reset_input_buffer()
            result["boot"] = fresh_boot(target, bus, flash, args.boot_bin.read_bytes(), args.timeout)
            captured = target.console() if args.sim else (console.read(4096) if console else None)
            result["console"] = captured.decode(errors="replace") if captured is not None else None
            if captured is not None and b"JESD1\n" not in captured:
                raise BringupError("native UART1 console did not contain the boot signature")
        elif args.command == "scratch":
            target.halt()
            identity = {"board": args.board_serial or "SIM", "probe": args.probe_serial or "SIM",
                        "device_id": flash.identity, "guards": list(flash.guards)}
            before = target.statistics() if args.sim else None
            session = PartitionSession(flash, args.backup, [args.offset], identity)
            data = random.Random(args.seed).randbytes(args.words * 4)
            session.erase(args.offset)
            session.program(args.offset, data)
            session.erase(args.offset)
            session.compare()
            result["scratch"] = {"physical_offset": args.offset, "program_words": args.words,
                                 "seed": args.seed, "restored_blank": True,
                                 "boot_and_neighbours_preserved": True}
            if args.sim:
                after = target.statistics()
                if after["programs"] - before["programs"] != args.words:
                    raise BringupError("target-observed program count differs from host requests")
                if after["erases"] - before["erases"] != 2:
                    raise BringupError("target-observed erase count differs from host requests")
                result["model_statistics"] = after
        elif args.command == "read":
            data = flash.read(args.offset, args.length)
            (out / "flash.bin").write_bytes(data)
            result["read"] = {"physical_offset": args.offset, "length": len(data),
                              "sha256": hashlib.sha256(data).hexdigest()}
        if args.sim:
            result["model_statistics"] = target.statistics()
        result["pass"] = True
    except (BringupError, OSError, ValueError) as error:
        result["error"] = str(error)
        if isinstance(target, SimTarget) and target.process.poll() is None:
            try:
                result["model_statistics"] = target.statistics()
            except (BringupError, OSError) as diagnostic_error:
                result["model_statistics_error"] = str(diagnostic_error)
    finally:
        if console:
            console.close()
        if target:
            target.close()
        (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
